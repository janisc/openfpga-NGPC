// NGPC for Analogue Pocket -- cartridge flash persistence.
//
// HOW SAVING WORKS HERE, AND WHY IT LOOKS NOTHING LIKE MiSTer'S
//
// Saves on this machine are cartridge flash: a game writes progress into the
// cartridge, so persistence means remembering which physical erase blocks it
// changed and putting those bytes somewhere that survives a power cycle.
//
// MiSTer's core drives the SD card itself, so it needs a moment to decide when
// to write -- hence its manual and menu-triggered saves. The Pocket does not
// work that way. A data slot marked `nonvolatile` is loaded into the core by
// APF at start and read back out at exit or power-off. The core simply owns a
// region of memory; the host owns the file.
//
// Two earlier designs here failed for exactly the reasons that model removes.
// The first ported upstream's ngp_cart_overlay and did not fit: 21,599 ALMs
// against 18,480. The second wrote sectors itself through APF target commands,
// which meant a state machine that could stall (it did, holding the machine
// paused and freezing the console) and a file that had to be created before it
// could be written (it never was, so nothing reached the card). Neither failure
// is possible now, because neither mechanism exists.
//
// THE LAYOUT
//
//   staging[0]                 header: magic, cartridge CRC32 and size, and
//                              the dirty-block bitmap
//   staging[512 ...]           the dirty blocks themselves, in the fixed order
//                              both directions walk, so no directory is needed
//
// The header's CRC32 and byte count are what stop one game's save reaching
// another's flash: a staged image is applied only if both match the cartridge
// actually loaded.
//
// WHEN THE COPY HAPPENS
//
// APF reads our memory at exit without announcing it, so staging has to be
// current by then. It cannot wait for a trigger and it must not pause the
// machine -- a visible stutter every time a game saves would be worse than the
// problem it solves.
//
// So blocks are staged in the background, on flash quiescence. Games write
// flash in bursts; once the dies have been idle for QUIET_CLOCKS the pending
// blocks are copied one at a time. If the game writes a block while it is being
// staged, that block is simply marked pending again and re-copied later, so a
// torn copy corrects itself rather than persisting. No pause, no handshake with
// the machine at all.
//
// Restoring is the one place the machine is held: at cartridge-ready the staged
// blocks are applied while reset is still asserted, so the BIOS and the game
// only ever observe restored flash.

`default_nettype none

module ngpc_cart_save #(
	// Payload capacity of the staging region. A die's four top blocks come to
	// 64 KB, so this holds those plus three 64 KB blocks -- far beyond what NGP
	// saves use. It costs no FPGA resource, only slot transfer time at core
	// start and exit.
	parameter [24:0] STAGE_BYTES = 25'h0040000,
	// Flash idle time before staging starts. ~20 ms at 49.152 MHz: long enough
	// that a burst of block writes is over, short enough that a save is staged
	// well before anyone reaches for the power switch. A parameter so the
	// simulation bench can shrink it.
	parameter [19:0] QUIET_CLOCKS = 20'd1_000_000
) (
	input  wire        clk,
	input  wire        reset,

	// ---- Cartridge identity ----------------------------------------------
	input  wire        cart_ready_i,
	input  wire        cart_replace_i,     // cart_download_start
	input  wire [31:0] cart_crc32_i,
	input  wire [24:0] cart_bytes_i,

	// The cartridge's OWN identity, as a real NGPC reads it from the cart
	// header. Stamped into the save so an orphaned file -- one whose ROM was
	// renamed or moved, which is all it takes for APF to stop finding it --
	// says in plain text which game it belongs to.
	input  wire [95:0] cart_title_i,
	input  wire [15:0] cart_catalog_i,
	input  wire  [7:0] cart_subcat_i,
	input  wire  [1:0] size_code0_i,
	input  wire  [1:0] size_code1_i,

	// ---- Flash write reports ----------------------------------------------
	input  wire        event0_i,
	input  wire  [5:0] block0_i,
	input  wire        event1_i,
	input  wire  [5:0] block1_i,
	input  wire  [1:0] die_busy_i,

	// ---- Host activity -----------------------------------------------------
	// While APF is moving the slot in or out it owns the staging region, and
	// background staging stands aside.
	input  wire        host_busy_i,

	// Savestate restore: the copier has rewritten staging with the state's
	// embedded image; re-arm the boot apply for it. Same validation, same
	// hold, same bitmap restore as at power-on.
	input  wire        state_apply_i,

	// APF is writing the save slot's staging region this cycle. Watching
	// the delivery directly is what makes the apply self-healing: if the
	// slot arrives after the settle window already fired the apply, the
	// burst re-arms it (issue #3 -- the 500 ms settle timer is a bet that
	// the cart-to-save delivery gap stays short; on slow cards it loses).
	input  wire        save_slot_wr_i,

	// The last apply refused to run: the staged bitmap omits blocks that
	// are dirty right now, and the original ROM bytes for those blocks
	// exist nowhere on the device. Loading such a state would silently
	// leave them un-rewound, so the load is rejected instead -- explicit
	// limits over haunted edge cases.
	output reg         apply_reject_o,

	// APF has delivered every data slot: no loader region has seen a bridge
	// write for a long settle window. The apply MUST wait for this. Slots
	// stream in id order, so at cartridge-ready the save slot has not even
	// begun to arrive -- an apply fired at cart_ready reads power-up garbage,
	// fails the magic check, consumes its one chance, and the real save data
	// lands moments later with nobody listening. That race is why in-game
	// saves never restored in any earlier build.
	input  wire        slots_settled_i,

	// Ingestion diagnostics from ngpc_stage_mem, stamped verbatim into header
	// words 16-18 of every staged save so the flushed file carries them out.
	input  wire [15:0] diag_beats_i,
	input  wire [15:0] diag_drops_i,


	// ---- Machine control ---------------------------------------------------
	output reg         boot_hold_o,        // holds reset while a save is applied
	output reg         busy_o,
	// A save exists for this cartridge -- some block is dirty, either because
	// the game wrote flash this session or because a staged image was applied
	// at boot. This is what the core reports to APF's data-slot size table:
	// present -> the slot flushes 0x40200 bytes at shutdown, absent -> zero
	// bytes and no file is created for games that never save.
	output wire        save_present_o,
	output wire        stage_current_o,   // idle with nothing left to stage

	// ---- Cartridge SDRAM, background port ----------------------------------
	output reg         p2_req_o,
	output reg         p2_we_o,
	output reg  [24:0] p2_addr_o,
	output reg  [15:0] p2_wdata_o,
	output wire  [1:0] p2_be_o,
	input  wire        p2_ready_i,
	input  wire        p2_done_i,
	input  wire [15:0] p2_rdata_i,

	// ---- Staging region, in PSRAM ------------------------------------------
	output reg         stage_req_o,
	output reg         stage_we_o,
	output reg  [24:0] stage_addr_o,
	output reg  [15:0] stage_wdata_o,
	input  wire        stage_ready_i,
	input  wire        stage_done_i,
	input  wire [15:0] stage_rdata_i
);

	assign p2_be_o = 2'b11;

	localparam [15:0] MAGIC0 = 16'h4E47;  // "NG"
	localparam [15:0] MAGIC1 = 16'h5043;  // "PC"
	localparam [15:0] MAGIC2 = 16'h5341;  // "SA"
	localparam [15:0] MAGIC3 = 16'h5632;  // "V2" -- layout differs from the
	                                      // sector-based version that preceded it

	// ---- Dirty and pending bitmaps -----------------------------------------
	//
	// `dirty` is what the save contains. `pending` is what still needs copying
	// into staging. A write sets both; a completed copy clears only pending.

	reg [63:0] dirty0,   dirty1;
	reg [63:0] pending0, pending1;

	wire pending_any = |pending0 || |pending1;

	// The staged image is complete and current: nothing pending and the
	// walker parked. The savestate capture waits on this with the machine
	// paused, so it converges instead of chasing.
	assign stage_current_o = (state == S_IDLE) && !pending_any && cart_ready_i;

	// A SAVE MUST CONTAIN SOMETHING. A dirty bit alone is not a save: a game
	// that merely erases a block during startup -- Card Fighters does exactly
	// this when it finds no save -- dirties it with nothing in it. Claiming
	// the slot for that image makes APF write a 65 KB file of erased flash,
	// and if a real save file was already on the card, IT IS OVERWRITTEN AND
	// GONE. One missed apply then costs the player everything, permanently
	// (issue #3: a good save destroyed on the relaunch that failed to
	// restore it, then frozen because an already-erased block is never
	// erased again). So the claim also requires that some word we have
	// moved this session -- staged out of flash, or applied into it -- was
	// not erased. An all-0xFF image is indistinguishable from no save.
	assign save_present_o = (|dirty0 || |dirty1) && image_has_data;

	// ---- Block geometry -----------------------------------------------------

	reg        geo_die;
	reg  [5:0] geo_block;
	wire [1:0] geo_size_code = geo_die ? size_code1_i : size_code0_i;
	wire        geo_valid;
	wire [20:0] geo_base;
	wire [15:0] geo_words;

	ngp_cart_overlay_geometry geometry
	(
		.size_code_i (geo_size_code),
		.block_i     (geo_block),
		.valid_o     (geo_valid),
		.base_o      (geo_base),
		.bytes_o     (),
		.words_o     (geo_words)
	);

	wire block_dirty = geo_valid &&
		(geo_die ? dirty1[geo_block] : dirty0[geo_block]);
	wire block_pending = geo_valid &&
		(geo_die ? pending1[geo_block] : pending0[geo_block]);

	// Linear cartridge byte address, die1 starting at 2 MiB -- the mapping
	// ngp_cart_overlay_mover uses.
	wire [24:0] block_base_addr = {geo_die ? 4'd1 : 4'd0, geo_base};

	// Where this block sits in the staging payload: blocks are laid out in walk
	// order, so the offset is the running total of the dirty blocks before it.
	reg [24:0] stage_offset;

	// ---- State --------------------------------------------------------------

	localparam S_IDLE        = 4'd0;
	localparam S_STAGE_SCAN  = 4'd1;
	localparam S_STAGE_RD    = 4'd2;
	localparam S_STAGE_RD_W  = 4'd3;
	localparam S_STAGE_WR    = 4'd4;
	localparam S_STAGE_WR_W  = 4'd5;
	localparam S_STAGE_HDR   = 4'd6;
	localparam S_STAGE_HDR_W = 4'd7;
	localparam S_APPLY_HDR   = 4'd8;
	localparam S_APPLY_HDR_W = 4'd9;
	localparam S_APPLY_SCAN  = 4'd10;
	localparam S_APPLY_RD    = 4'd11;
	localparam S_APPLY_RD_W  = 4'd12;
	localparam S_APPLY_WR    = 4'd13;
	localparam S_APPLY_WR_W  = 4'd14;
	localparam S_FINISH      = 4'd15;


	reg [63:0] img0, img1;      // staged bitmap, held apart from dirty
	                            // until the reject check passes
	reg        apply_decide;    // first S_APPLY_SCAN cycle runs the check
	reg        saw_save_wr;     // save-slot writes since the apply began
	reg [19:0] save_wr_quiet;
	reg        image_has_data;   // a non-erased word passed through this session
	reg  [3:0] state;
	reg        copy_dirtied;    // the block being copied was rewritten mid-copy

	// Apply diagnostics, stamped into header words 22-24 of every staged save:
	// how many applies ran since reset, the last apply's verdict (1 = header
	// accepted, 2 = rejected), and how many p2 writes COMPLETED during the
	// last apply. Delivery is proven complete on hardware and the header
	// provably passes, yet the game sees unchanged flash -- these words say
	// whether the writes themselves are being acknowledged.
	reg [15:0] diag_applies;
	reg [15:0] diag_verdict;
	reg [15:0] diag_p2wr;

	reg [15:0] block_word;      // position within the block being copied
	reg [15:0] xfer_data;       // the word in flight
	reg  [4:0] hdr_idx;         // position within the header
	reg [19:0] quiet;
	reg        apply_pending;   // apply the staged image once the cart is ready
	reg        apply_ok;        // the header matched this cartridge

	wire flash_quiet = (die_busy_i == 2'b00) && !event0_i && !event1_i;

	// A write event aimed at the very block currently being walked.
	wire ev_this_block = (event0_i && !geo_die && block0_i == geo_block) ||
	                     (event1_i &&  geo_die && block1_i == geo_block);

	// The header as a function of its index, so it needs no storage of its own.
	reg [15:0] hdr_word;

	always @* begin
		case (hdr_idx)
			5'd0:  hdr_word = MAGIC0;
			5'd1:  hdr_word = MAGIC1;
			5'd2:  hdr_word = MAGIC2;
			5'd3:  hdr_word = MAGIC3;
			5'd4:  hdr_word = cart_crc32_i[15:0];
			5'd5:  hdr_word = cart_crc32_i[31:16];
			5'd6:  hdr_word = {7'd0, cart_bytes_i[24:16]};
			5'd7:  hdr_word = cart_bytes_i[15:0];
			5'd8:  hdr_word = dirty0[15:0];
			5'd9:  hdr_word = dirty0[31:16];
			5'd10: hdr_word = dirty0[47:32];
			5'd11: hdr_word = dirty0[63:48];
			5'd12: hdr_word = dirty1[15:0];
			5'd13: hdr_word = dirty1[31:16];
			5'd14: hdr_word = dirty1[47:32];
			5'd15: hdr_word = dirty1[63:48];
			5'd16: hdr_word = diag_beats_i;
			5'd17: hdr_word = diag_drops_i;
			// 18 retired with 19-21: high-water read zero through every
			// test; drops alone detect an overrun.
			// 19-21 retired: delivery completeness and the no-verify-reads
			// question were answered for good; the words stay zero so the
			// header layout is stable.
			5'd21: hdr_word = {8'd0, cart_subcat_i};
			5'd22: hdr_word = diag_applies;
			5'd23: hdr_word = diag_verdict;
			5'd24: hdr_word = diag_p2wr;
			// The cartridge's own header identity, 12 ASCII characters of title
			// plus the catalogue numbers, so the file is self-describing.
			5'd25: hdr_word = cart_title_i[15:0];
			5'd26: hdr_word = cart_title_i[31:16];
			5'd27: hdr_word = cart_title_i[47:32];
			5'd28: hdr_word = cart_title_i[63:48];
			5'd29: hdr_word = cart_title_i[79:64];
			5'd30: hdr_word = cart_title_i[95:80];
			5'd31: hdr_word = cart_catalog_i;
			default: hdr_word = 16'd0;
		endcase
	end

	always @(posedge clk) begin
		p2_req_o    <= 1'b0;
		stage_req_o <= 1'b0;

		// Flash reports are taken at all times, including mid-copy: a block
		// written while it is being staged is marked pending again, so the torn
		// copy is replaced rather than kept.
		if (event0_i) begin dirty0[block0_i] <= 1'b1; pending0[block0_i] <= 1'b1; end
		if (event1_i) begin dirty1[block1_i] <= 1'b1; pending1[block1_i] <= 1'b1; end

		if (ev_this_block && (state == S_STAGE_RD  || state == S_STAGE_RD_W ||
		                      state == S_STAGE_WR  || state == S_STAGE_WR_W)) begin
			copy_dirtied <= 1'b1;
		end

		if (flash_quiet && quiet != QUIET_CLOCKS) quiet <= quiet + 20'd1;
		else if (!flash_quiet)                    quiet <= 20'd0;

		if (reset || cart_replace_i) begin
			diag_applies  <= 16'd0;
			diag_verdict  <= 16'd0;
			diag_p2wr     <= 16'd0;
			state         <= S_IDLE;
			boot_hold_o   <= 1'b0;
			busy_o        <= 1'b0;
			dirty0        <= 64'd0;
			dirty1        <= 64'd0;
			pending0      <= 64'd0;
			pending1      <= 64'd0;
			quiet         <= 20'd0;
			apply_pending <= 1'b1;
			apply_ok      <= 1'b0;
			image_has_data <= 1'b0;
			apply_reject_o <= 1'b0;
			saw_save_wr   <= 1'b0;
			save_wr_quiet <= 20'd0;
		end else begin
			if (state_apply_i) begin
				apply_pending <= 1'b1;
			end

			// Save-slot delivery seen after the apply started means the apply
			// ran too early (or mid-delivery): once the burst goes quiet,
			// re-arm and run it again on the now-complete image. A normal
			// boot never trips this -- delivery fully precedes the settled
			// apply, so saw_save_wr is clear by the time the apply starts.
			if (save_slot_wr_i) begin
				saw_save_wr   <= 1'b1;
				save_wr_quiet <= 20'd0;
			end else if (save_wr_quiet != QUIET_CLOCKS) begin
				save_wr_quiet <= save_wr_quiet + 20'd1;
			end
			if (saw_save_wr && (save_wr_quiet == QUIET_CLOCKS) &&
			    (state == S_IDLE) && !apply_pending) begin
				saw_save_wr   <= 1'b0;
				apply_pending <= 1'b1;
			end

			case (state)
				S_IDLE: begin
					if (cart_ready_i && apply_pending) begin
						// Hold the machine in reset from cartridge-ready until
						// the apply has run, and do not run the apply until APF
						// has finished delivering slots -- the save slot streams
						// AFTER the cartridge, so at this moment it is still in
						// flight. The hold covers the wait, so the BIOS and the
						// game still only ever observe restored flash.
						boot_hold_o <= 1'b1;
						busy_o      <= 1'b1;
						if (slots_settled_i) begin
							apply_pending <= 1'b0;
							apply_reject_o <= 1'b0;
							saw_save_wr   <= 1'b0;
							hdr_idx       <= 4'd0;
							apply_ok      <= 1'b1;
`ifdef NGPC_SAVE_DIAG
							diag_applies  <= diag_applies + 16'd1;
							diag_verdict  <= 16'd0;
							diag_p2wr     <= 16'd0;
`endif
							state         <= S_APPLY_HDR;
						end
					end else if (cart_ready_i && pending_any && !host_busy_i &&
					             quiet == QUIET_CLOCKS) begin
						boot_hold_o <= 1'b0;
						busy_o       <= 1'b1;
						geo_die      <= 1'b0;
						geo_block    <= 6'd0;
						stage_offset <= 25'd0;
						state        <= S_STAGE_SCAN;
					end else begin
						boot_hold_o <= 1'b0;
						busy_o      <= 1'b0;
					end
				end

				// ---------------- stage: cartridge -> staging ----------------
				S_STAGE_SCAN: begin
					if (block_pending) begin
						block_word   <= 16'd0;
						copy_dirtied <= 1'b0;
						state        <= S_STAGE_RD;
					end else begin
						// Dirty-but-not-pending blocks still occupy their slot
						// in the payload, so the offset advances for them too.
						if (block_dirty) stage_offset <= stage_offset + {9'd0, geo_words, 1'b0};

						if (geo_block == 6'd63) begin
							if (geo_die) begin
								hdr_idx <= 4'd0;
								state   <= S_STAGE_HDR;
							end else begin
								geo_die   <= 1'b1;
								geo_block <= 6'd0;
							end
						end else begin
							geo_block <= geo_block + 6'd1;
						end
					end
				end

				S_STAGE_RD: begin
					if (p2_ready_i) begin
						p2_req_o  <= 1'b1;
						p2_we_o   <= 1'b0;
						p2_addr_o <= block_base_addr + {8'd0, block_word, 1'b0};
						state     <= S_STAGE_RD_W;
					end
				end

				S_STAGE_RD_W: begin
					if (p2_done_i) begin
						if (p2_rdata_i != 16'hFFFF) image_has_data <= 1'b1;
						xfer_data <= p2_rdata_i;
						state     <= S_STAGE_WR;
					end
				end

				S_STAGE_WR: begin
					if (stage_ready_i) begin
						stage_req_o   <= 1'b1;
						stage_we_o    <= 1'b1;
						stage_addr_o  <= 25'd512 + stage_offset +
						                 {8'd0, block_word, 1'b0};
						stage_wdata_o <= xfer_data;
						state         <= S_STAGE_WR_W;
					end
				end

				S_STAGE_WR_W: begin
					if (stage_done_i) begin
						if (block_word + 16'd1 >= geo_words) begin
							// The block is staged. Clear pending -- UNLESS the
							// game rewrote it while the copy was in flight. The
							// event handler above re-marks the bit, but this
							// assignment runs later in the block and would
							// overwrite that re-mark, so the mid-copy history
							// has to be carried explicitly: the first version
							// of this line wiped the re-mark and a torn copy
							// stayed torn (caught by sim/tb_cart_save.sv, D).
							if (geo_die) pending1[geo_block] <= copy_dirtied || ev_this_block;
							else         pending0[geo_block] <= copy_dirtied || ev_this_block;

							stage_offset <= stage_offset + {9'd0, geo_words, 1'b0};

							if (geo_block == 6'd63) begin
								if (geo_die) begin
									hdr_idx <= 4'd0;
									state   <= S_STAGE_HDR;
								end else begin
									geo_die   <= 1'b1;
									geo_block <= 6'd0;
									state     <= S_STAGE_SCAN;
								end
							end else begin
								geo_block <= geo_block + 6'd1;
								state     <= S_STAGE_SCAN;
							end
						end else begin
							block_word <= block_word + 16'd1;
							state      <= S_STAGE_RD;
						end
					end
				end

				// The header goes last, so a staging pass interrupted by a
				// power cut leaves the previous header describing the previous
				// payload rather than a half-written one.
				S_STAGE_HDR: begin
					if (stage_ready_i) begin
						stage_req_o   <= 1'b1;
						stage_we_o    <= 1'b1;
						stage_addr_o  <= {19'd0, hdr_idx, 1'b0};
						stage_wdata_o <= hdr_word;
						state         <= S_STAGE_HDR_W;
					end
				end

				S_STAGE_HDR_W: begin
					if (stage_done_i) begin
						if (hdr_idx == 5'd31) state   <= S_FINISH;
						else begin
							hdr_idx <= hdr_idx + 5'd1;
							state   <= S_STAGE_HDR;
						end
					end
				end

				// ---------------- apply: staging -> cartridge ----------------
				S_APPLY_HDR: begin
					if (stage_ready_i) begin
						stage_req_o  <= 1'b1;
						stage_we_o   <= 1'b0;
						stage_addr_o <= {19'd0, hdr_idx, 1'b0};
						state        <= S_APPLY_HDR_W;
					end
				end

				S_APPLY_HDR_W: begin
					if (stage_done_i) begin
						case (hdr_idx)
							5'd0:  if (stage_rdata_i != MAGIC0) apply_ok <= 1'b0;
							5'd1:  if (stage_rdata_i != MAGIC1) apply_ok <= 1'b0;
							5'd2:  if (stage_rdata_i != MAGIC2) apply_ok <= 1'b0;
							5'd3:  if (stage_rdata_i != MAGIC3) apply_ok <= 1'b0;
							5'd4:  if (stage_rdata_i != cart_crc32_i[15:0])  apply_ok <= 1'b0;
							5'd5:  if (stage_rdata_i != cart_crc32_i[31:16]) apply_ok <= 1'b0;
							5'd8:  img0[15:0]  <= stage_rdata_i;
							5'd9:  img0[31:16] <= stage_rdata_i;
							5'd10: img0[47:32] <= stage_rdata_i;
							5'd11: img0[63:48] <= stage_rdata_i;
							5'd12: img1[15:0]  <= stage_rdata_i;
							5'd13: img1[31:16] <= stage_rdata_i;
							5'd14: img1[47:32] <= stage_rdata_i;
							5'd15: img1[63:48] <= stage_rdata_i;
							default: ;
						endcase

						if (hdr_idx == 5'd15) begin
							apply_decide <= 1'b1;
							geo_die      <= 1'b0;
							geo_block    <= 6'd0;
							stage_offset <= 25'd0;
`ifdef NGPC_SAVE_DIAG
							diag_verdict <= apply_ok ? 16'd1 : 16'd2;
`endif
							state        <= apply_ok ? S_APPLY_SCAN : S_FINISH;
						end else begin
							hdr_idx <= hdr_idx + 5'd1;
							state   <= apply_ok ? S_APPLY_HDR : S_FINISH;
						end
					end
				end

				S_APPLY_SCAN: begin
					// First cycle after the header: commit or reject. dirty is
					// only overwritten once the staged bitmap is known to cover
					// every block that is dirty right now; at boot dirty is
					// empty, so boot applies can never reject.
					if (apply_decide) begin
						apply_decide <= 1'b0;
						if (|(dirty0 & ~img0) || |(dirty1 & ~img1)) begin
							apply_reject_o <= 1'b1;
							apply_ok       <= 1'b0;
							state          <= S_FINISH;
						end else begin
							dirty0 <= img0;
							dirty1 <= img1;
						end
					end else
					if (block_dirty) begin
						block_word <= 16'd0;
						state      <= S_APPLY_RD;
					end else if (geo_block == 6'd63) begin
						if (geo_die) state <= S_FINISH;
						else begin
							geo_die   <= 1'b1;
							geo_block <= 6'd0;
						end
					end else begin
						geo_block <= geo_block + 6'd1;
					end
				end

				S_APPLY_RD: begin
					if (stage_ready_i) begin
						stage_req_o  <= 1'b1;
						stage_we_o   <= 1'b0;
						stage_addr_o <= 25'd512 + stage_offset +
						                {8'd0, block_word, 1'b0};
						state        <= S_APPLY_RD_W;
					end
				end

				S_APPLY_RD_W: begin
					if (stage_done_i) begin
						if (stage_rdata_i != 16'hFFFF) image_has_data <= 1'b1;
						xfer_data <= stage_rdata_i;
						state     <= S_APPLY_WR;
					end
				end

				S_APPLY_WR: begin
					if (p2_ready_i) begin
						p2_req_o   <= 1'b1;
						p2_we_o    <= 1'b1;
						p2_addr_o  <= block_base_addr + {8'd0, block_word, 1'b0};
						p2_wdata_o <= xfer_data;
						state      <= S_APPLY_WR_W;
					end
				end

				S_APPLY_WR_W: begin
					if (p2_done_i) begin
`ifdef NGPC_SAVE_DIAG
						diag_p2wr <= diag_p2wr + 16'd1;
`endif
						if (block_word + 16'd1 >= geo_words) begin
							stage_offset <= stage_offset + {9'd0, geo_words, 1'b0};

							if (geo_block == 6'd63) begin
								if (geo_die) state <= S_FINISH;
								else begin
									geo_die   <= 1'b1;
									geo_block <= 6'd0;
									state     <= S_APPLY_SCAN;
								end
							end else begin
								geo_block <= geo_block + 6'd1;
								state     <= S_APPLY_SCAN;
							end
						end else begin
							block_word <= block_word + 16'd1;
							state      <= S_APPLY_RD;
						end
					end
				end

				S_FINISH: begin
					boot_hold_o <= 1'b0;
					busy_o      <= 1'b0;
					quiet       <= 20'd0;
					state       <= S_IDLE;
				end

				default: state <= S_IDLE;
			endcase
		end
	end

	wire unused_ok = &{1'b0, STAGE_BYTES, 1'b0};

endmodule

`default_nettype wire
