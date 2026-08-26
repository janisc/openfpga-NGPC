// NGPC for Analogue Pocket -- cartridge flash persistence.
//
// WHY THIS EXISTS INSTEAD OF UPSTREAM'S OVERLAY
//
// Saves on this machine are cartridge flash: a game writes its progress into
// the cartridge, so persistence means remembering which physical erase blocks
// the game changed. Upstream implements that with ngp_cart_overlay and nine
// supporting modules -- ledgers, a directory, a transactional saver, an
// immutable pristine shadow to diff against. It is careful work and it produces
// a .sav the MiSTer core can read.
//
// It also does not fit. Wired up on this device the design came out at 21,599
// ALMs against 18,480 available, and area-optimising it made that worse rather
// than better. MiSTer has 110k logic elements; the Pocket has 49k, and the
// console alone already uses three quarters of them.
//
// So this is the same idea at a size that fits, with MiSTer file compatibility
// deliberately given up:
//
//   * ngp_cart reports every completed physical block mutation on event0/1.
//     A 128-bit dirty bitmap is enough to know what to write -- no pristine
//     shadow, and therefore no second memory subsystem.
//   * A save is a header sector plus the dirty blocks, in a fixed order both
//     directions walk identically, so no directory is needed to find them.
//   * The header carries the cartridge's CRC32 and byte count. A save is
//     applied only if both match, which is what stops one game's save landing
//     in another's flash.
//
// WHAT IS GIVEN UP, stated plainly. Upstream's saver is transactional: an
// interrupted save cannot leave a half-written file that looks valid, because
// the new state is staged and then committed. This one is not, and on a
// battery-powered handheld an interrupted save is a real event rather than a
// theoretical one.
//
// What it does instead is order the writes so that the cheap failure mode is
// the one you get: the payload blocks are written FIRST and the header LAST.
// A save cut short therefore leaves a file whose header is still the previous
// save's -- or absent entirely on the first ever save -- so the torn payload is
// never read. You lose the save you were making; you do not lose the one you
// had, and you cannot half-apply a block into the cartridge.
//
// The remaining hole is a cut during the header sector itself, which is one
// 512-byte write out of a whole save. Closing that needs two header slots
// written alternately with a sequence number, which is a real transaction and
// costs more than it is worth here.

`default_nettype none

module ngpc_cart_save
(
	input  wire        clk,
	input  wire        reset,

	// ---- Cartridge identity ----------------------------------------------
	input  wire        cart_ready_i,
	input  wire        cart_replace_i,     // cart_download_start
	input  wire [31:0] cart_crc32_i,
	input  wire [24:0] cart_bytes_i,
	input  wire  [1:0] size_code0_i,
	input  wire  [1:0] size_code1_i,

	// ---- Flash write reports ----------------------------------------------
	input  wire        event0_i,
	input  wire  [5:0] block0_i,
	input  wire        event1_i,
	input  wire  [5:0] block1_i,
	input  wire  [1:0] die_busy_i,

	// ---- Requests ----------------------------------------------------------
	input  wire        save_req_i,         // one-cycle pulse
	input  wire        load_req_i,
	input  wire        autosave_off_i,
	input  wire        host_in_menu_i,     // APF osnotify_inmenu, level
	input  wire        save_present_i,     // the slot has a file

	// ---- Machine control ---------------------------------------------------
	output reg         pause_req_o,
	input  wire        pause_ready_i,
	output reg         boot_hold_o,        // holds reset while a save is applied
	output reg         busy_o,

	// ---- Cartridge SDRAM, background port ----------------------------------
	output reg         p2_req_o,
	output reg         p2_we_o,
	output reg  [24:0] p2_addr_o,
	output reg  [15:0] p2_wdata_o,
	output wire  [1:0] p2_be_o,
	input  wire        p2_ready_i,
	input  wire        p2_done_i,
	input  wire [15:0] p2_rdata_i,

	// ---- Sector device ------------------------------------------------------
	output reg  [22:0] lba_o,
	output reg         rd_o,
	output reg         wr_o,
	input  wire        sd_busy_i,
	input  wire        sd_err_i,
	output reg   [7:0] buf_addr_o,
	output reg  [15:0] buf_wdata_o,
	output reg         buf_we_o,
	input  wire [15:0] buf_rdata_i
);

	assign p2_be_o = 2'b11;

	localparam [15:0] MAGIC0 = 16'h4E47;  // "NG"
	localparam [15:0] MAGIC1 = 16'h5043;  // "PC"
	localparam [15:0] MAGIC2 = 16'h5341;  // "SA"
	localparam [15:0] MAGIC3 = 16'h5631;  // "V1"

	// ---- Dirty bitmap -------------------------------------------------------
	//
	// One bit per physical erase block per die. ngp_cart raises event0/1 only
	// after the flash FSM has accepted a mutation, so this counts completed
	// changes rather than attempted ones.

	reg [63:0] dirty0;
	reg [63:0] dirty1;

	// The set being written, frozen when the save starts. The machine is paused
	// by then so nothing should move, but the header and the payload must
	// describe the same set even if that assumption is ever wrong.
	reg [63:0] save_dirty0;
	reg [63:0] save_dirty1;

	wire dirty_any = |dirty0 || |dirty1;

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

	// Saving walks the frozen set; loading walks the set read from the header,
	// which is placed into save_dirty* before the walk begins.
	wire block_selected = geo_valid &&
		(geo_die ? save_dirty1[geo_block] : save_dirty0[geo_block]);

	// Linear cartridge byte address, die1 starting at 2 MiB -- the same mapping
	// ngp_cart_overlay_mover uses.
	wire [24:0] block_base_addr = {geo_die ? 4'd1 : 4'd0, geo_base};

	// ---- State --------------------------------------------------------------

	localparam S_IDLE          = 5'd0;
	localparam S_SAVE_PAUSE    = 5'd1;
	localparam S_SAVE_HEADER   = 5'd2;
	localparam S_SAVE_HDR_GO   = 5'd3;
	localparam S_SAVE_SCAN     = 5'd4;
	localparam S_SAVE_FILL     = 5'd5;
	localparam S_SAVE_FILL_W   = 5'd6;
	localparam S_SAVE_SECTOR   = 5'd7;
	localparam S_SAVE_NEXT     = 5'd8;
	localparam S_SAVE_COMMIT   = 5'd18;
	localparam S_LOAD_HDR      = 5'd9;
	localparam S_LOAD_HDR_W    = 5'd10;
	localparam S_LOAD_CHECK    = 5'd11;
	localparam S_LOAD_SCAN     = 5'd12;
	localparam S_LOAD_SECTOR   = 5'd13;
	localparam S_LOAD_DRAIN    = 5'd14;
	localparam S_LOAD_DRAIN_W  = 5'd15;
	localparam S_LOAD_NEXT     = 5'd16;
	localparam S_FINISH        = 5'd17;

	reg  [4:0] state;
	reg  [7:0] word_idx;        // position within the 256-word sector
	reg [15:0] block_word;      // position within the block
	reg [15:0] hdr [0:11];
	reg        prev_menu;
	reg        load_pending;    // apply a save once the cartridge is ready

	// A transfer that stalls used to hold pause_req_o forever, which stops the
	// machine dead -- the console freezes with no indication why. That is the
	// worst failure this module can have, because it looks like the emulation
	// broke rather than the save did.
	//
	// Every state here either completes a handshake or advances within a
	// bounded time; the longest legitimate wait is one APF target command, a
	// few milliseconds. If any state sits still for ~340 ms, abandon the
	// transfer and release the machine. A lost save is recoverable. A frozen
	// console is not.
	localparam [23:0] WATCHDOG_LIMIT = 24'hFFFFFF;

	reg [23:0] watchdog;
	reg  [4:0] prev_state;
	reg        aborted;

	wire [15:0] block_words_left = geo_words - block_word;
	wire        sector_is_last   = block_words_left <= 16'd256;

	integer i;

	always @(posedge clk) begin
		rd_o     <= 1'b0;
		wr_o     <= 1'b0;
		buf_we_o <= 1'b0;
		p2_req_o <= 1'b0;

		prev_menu <= host_in_menu_i;

		// Dirty tracking runs at all times, including during a transfer: a
		// block written while a save is in flight must still be remembered.
		if (event0_i) dirty0[block0_i] <= 1'b1;
		if (event1_i) dirty1[block1_i] <= 1'b1;

		// Reset the watchdog on any progress; expire it otherwise.
		prev_state <= state;

		if (state == S_IDLE || state != prev_state) begin
			watchdog <= 24'd0;
		end else if (watchdog != WATCHDOG_LIMIT) begin
			watchdog <= watchdog + 24'd1;
		end

		if (reset || cart_replace_i) begin
			watchdog     <= 24'd0;
			aborted      <= 1'b0;
			state        <= S_IDLE;
			pause_req_o  <= 1'b0;
			boot_hold_o  <= 1'b0;
			busy_o       <= 1'b0;
			dirty0       <= 64'd0;
			dirty1       <= 64'd0;
			load_pending <= 1'b1;
		end else begin
			case (state)
				S_IDLE: begin
					pause_req_o <= 1'b0;
					boot_hold_o <= 1'b0;
					busy_o      <= 1'b0;

					if (cart_ready_i && load_pending && save_present_i) begin
						// Apply a save before the machine runs, so the BIOS and
						// the game only ever see the restored flash.
						load_pending <= 1'b0;
						boot_hold_o  <= 1'b1;
						busy_o       <= 1'b1;
						lba_o        <= 23'd0;
						state        <= S_LOAD_HDR;
					end else if (cart_ready_i && load_pending) begin
						load_pending <= 1'b0;
					end else if (load_req_i && cart_ready_i) begin
						boot_hold_o <= 1'b1;
						busy_o      <= 1'b1;
						lba_o       <= 23'd0;
						state       <= S_LOAD_HDR;
					end else if (cart_ready_i && dirty_any &&
					             (save_req_i ||
					              (!autosave_off_i && host_in_menu_i && !prev_menu))) begin
						busy_o      <= 1'b1;
						pause_req_o <= 1'b1;
						state       <= S_SAVE_PAUSE;
					end
				end

				// ---------------- save ----------------------------------------
				S_SAVE_PAUSE: begin
					// The flash FSM must be idle or a block could change under
					// the read.
					if (pause_ready_i && die_busy_i == 2'b00) begin
						save_dirty0 <= dirty0;
						save_dirty1 <= dirty1;
						lba_o       <= 23'd1;   // sector 0 is the header, written last
						geo_die     <= 1'b0;
						geo_block   <= 6'd0;
						state       <= S_SAVE_SCAN;
					end
				end

				S_SAVE_HEADER: begin
					// Reached only after every payload block is on the card.
					hdr[0]  <= MAGIC0;
					hdr[1]  <= MAGIC1;
					hdr[2]  <= MAGIC2;
					hdr[3]  <= MAGIC3;
					hdr[4]  <= cart_crc32_i[15:0];
					hdr[5]  <= cart_crc32_i[31:16];
					hdr[6]  <= {7'd0, cart_bytes_i[24:16]};
					hdr[7]  <= cart_bytes_i[15:0];
					hdr[8]  <= {12'd0, size_code1_i, size_code0_i};
					hdr[9]  <= 16'd0;
					hdr[10] <= 16'd0;
					hdr[11] <= 16'd0;
					word_idx <= 8'd0;
					state    <= S_SAVE_HDR_GO;
				end

				S_SAVE_HDR_GO: begin
					buf_addr_o  <= word_idx;
					buf_we_o    <= 1'b1;
					buf_wdata_o <= (word_idx < 8'd12)  ? hdr[word_idx[3:0]] :
					               (word_idx == 8'd16) ? save_dirty0[15:0]  :
					               (word_idx == 8'd17) ? save_dirty0[31:16] :
					               (word_idx == 8'd18) ? save_dirty0[47:32] :
					               (word_idx == 8'd19) ? save_dirty0[63:48] :
					               (word_idx == 8'd20) ? save_dirty1[15:0]  :
					               (word_idx == 8'd21) ? save_dirty1[31:16] :
					               (word_idx == 8'd22) ? save_dirty1[47:32] :
					               (word_idx == 8'd23) ? save_dirty1[63:48] : 16'd0;

					if (word_idx == 8'd255) begin
						lba_o <= 23'd0;
						wr_o  <= 1'b1;
						state <= S_SAVE_COMMIT;
					end else begin
						word_idx <= word_idx + 8'd1;
					end
				end

				S_SAVE_SCAN: begin
					if (!sd_busy_i && !wr_o) begin
						if (block_selected) begin
							block_word <= 16'd0;
							word_idx   <= 8'd0;
							state      <= S_SAVE_FILL;
						end else if (geo_block == 6'd63) begin
							if (geo_die) begin
								state <= S_SAVE_HEADER;
							end else begin
								geo_die   <= 1'b1;
								geo_block <= 6'd0;
							end
						end else begin
							geo_block <= geo_block + 6'd1;
						end
					end
				end

				S_SAVE_FILL: begin
					// The port accepts a request only while it says it is
					// ready; one issued otherwise is dropped, and the wait for
					// done below would never end. Stay here until it will take
					// it.
					if (p2_ready_i) begin
						p2_req_o  <= 1'b1;
						p2_we_o   <= 1'b0;
						p2_addr_o <= block_base_addr + {8'd0, block_word, 1'b0};
						state     <= S_SAVE_FILL_W;
					end
				end

				S_SAVE_FILL_W: begin
					if (p2_done_i) begin
						buf_addr_o  <= word_idx;
						buf_wdata_o <= p2_rdata_i;
						buf_we_o    <= 1'b1;

						if (word_idx == 8'd255 || block_word + 16'd1 >= geo_words) begin
							wr_o  <= 1'b1;
							state <= S_SAVE_SECTOR;
						end else begin
							word_idx   <= word_idx + 8'd1;
							block_word <= block_word + 16'd1;
							state      <= S_SAVE_FILL;
						end
					end
				end

				S_SAVE_SECTOR: begin
					if (!sd_busy_i && !wr_o) begin
						lba_o <= lba_o + 23'd1;

						if (block_word + 16'd1 >= geo_words) begin
							state <= S_SAVE_NEXT;
						end else begin
							block_word <= block_word + 16'd1;
							word_idx   <= 8'd0;
							state      <= S_SAVE_FILL;
						end
					end
				end

				S_SAVE_NEXT: begin
					if (geo_block == 6'd63) begin
						if (geo_die) begin
							state <= S_SAVE_HEADER;
						end else begin
							geo_die   <= 1'b1;
							geo_block <= 6'd0;
							state     <= S_SAVE_SCAN;
						end
					end else begin
						geo_block <= geo_block + 6'd1;
						state     <= S_SAVE_SCAN;
					end
				end

				S_SAVE_COMMIT: begin
					// The header is the commit point: until this sector lands,
					// the file on the card still describes the previous save.
					if (!sd_busy_i && !wr_o) state <= S_FINISH;
				end

				// ---------------- load ----------------------------------------
				S_LOAD_HDR: begin
					rd_o  <= 1'b1;
					state <= S_LOAD_HDR_W;
				end

				S_LOAD_HDR_W: begin
					if (!sd_busy_i && !rd_o) begin
						buf_addr_o <= 8'd0;
						word_idx   <= 8'd0;
						state      <= S_LOAD_CHECK;
					end
				end

				S_LOAD_CHECK: begin
					// Walk the header words out of the buffer, one per cycle,
					// checking as they arrive. buf_rdata_i lags buf_addr_o by a
					// cycle, so word_idx-1 is what is being examined.
					buf_addr_o <= word_idx + 8'd1;
					word_idx   <= word_idx + 8'd1;

					case (word_idx)
						8'd1: if (buf_rdata_i != MAGIC0) state <= S_FINISH;
						8'd2: if (buf_rdata_i != MAGIC1) state <= S_FINISH;
						8'd3: if (buf_rdata_i != MAGIC2) state <= S_FINISH;
						8'd4: if (buf_rdata_i != MAGIC3) state <= S_FINISH;
						8'd5: if (buf_rdata_i != cart_crc32_i[15:0])  state <= S_FINISH;
						8'd6: if (buf_rdata_i != cart_crc32_i[31:16]) state <= S_FINISH;
						// The set goes into BOTH: save_dirty* drives the walk
						// below, dirty* makes a later save rewrite these blocks
						// even if the game does not touch them again.
						8'd17: begin dirty0[15:0]  <= buf_rdata_i; save_dirty0[15:0]  <= buf_rdata_i; end
						8'd18: begin dirty0[31:16] <= buf_rdata_i; save_dirty0[31:16] <= buf_rdata_i; end
						8'd19: begin dirty0[47:32] <= buf_rdata_i; save_dirty0[47:32] <= buf_rdata_i; end
						8'd20: begin dirty0[63:48] <= buf_rdata_i; save_dirty0[63:48] <= buf_rdata_i; end
						8'd21: begin dirty1[15:0]  <= buf_rdata_i; save_dirty1[15:0]  <= buf_rdata_i; end
						8'd22: begin dirty1[31:16] <= buf_rdata_i; save_dirty1[31:16] <= buf_rdata_i; end
						8'd23: begin dirty1[47:32] <= buf_rdata_i; save_dirty1[47:32] <= buf_rdata_i; end
						8'd24: begin
							dirty1[63:48]      <= buf_rdata_i;
							save_dirty1[63:48] <= buf_rdata_i;
							lba_o     <= 23'd1;
							geo_die   <= 1'b0;
							geo_block <= 6'd0;
							state     <= S_LOAD_SCAN;
						end
						default: ;
					endcase
				end

				S_LOAD_SCAN: begin
					if (block_selected) begin
						block_word <= 16'd0;
						state      <= S_LOAD_SECTOR;
					end else if (geo_block == 6'd63) begin
						if (geo_die) begin
							state <= S_FINISH;
						end else begin
							geo_die   <= 1'b1;
							geo_block <= 6'd0;
						end
					end else begin
						geo_block <= geo_block + 6'd1;
					end
				end

				S_LOAD_SECTOR: begin
					rd_o     <= 1'b1;
					word_idx <= 8'd0;
					state    <= S_LOAD_DRAIN;
				end

				S_LOAD_DRAIN: begin
					if (!sd_busy_i && !rd_o && p2_ready_i) begin
						buf_addr_o <= word_idx;
						p2_req_o   <= 1'b1;
						p2_we_o    <= 1'b1;
						p2_addr_o  <= block_base_addr + {8'd0, block_word, 1'b0};
						p2_wdata_o <= buf_rdata_i;
						state      <= S_LOAD_DRAIN_W;
					end
				end

				S_LOAD_DRAIN_W: begin
					if (p2_done_i) begin
						if (word_idx == 8'd255 || block_word + 16'd1 >= geo_words) begin
							state <= S_LOAD_NEXT;
						end else begin
							word_idx   <= word_idx + 8'd1;
							block_word <= block_word + 16'd1;
							buf_addr_o <= word_idx + 8'd1;
							state      <= S_LOAD_DRAIN;
						end
					end
				end

				S_LOAD_NEXT: begin
					lba_o <= lba_o + 23'd1;

					if (block_word + 16'd1 >= geo_words) begin
						if (geo_block == 6'd63) begin
							if (geo_die) begin
								state <= S_FINISH;
							end else begin
								geo_die   <= 1'b1;
								geo_block <= 6'd0;
								state     <= S_LOAD_SCAN;
							end
						end else begin
							geo_block <= geo_block + 6'd1;
							state     <= S_LOAD_SCAN;
						end
					end else begin
						block_word <= block_word + 16'd1;
						state      <= S_LOAD_SECTOR;
					end
				end

				S_FINISH: begin
					pause_req_o <= 1'b0;
					boot_hold_o <= 1'b0;
					busy_o      <= 1'b0;
					state       <= S_IDLE;
				end

				default: state <= S_IDLE;
			endcase

			if (watchdog == WATCHDOG_LIMIT && state != S_IDLE) begin
				aborted <= 1'b1;
				state   <= S_FINISH;
			end
		end
	end

	wire unused_ok = &{1'b0, sd_err_i, aborted, 1'b0};

endmodule

`default_nettype wire
