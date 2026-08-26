// NGPC for Analogue Pocket -- savestates, and therefore sleep.
//
// On the Pocket these are one feature. Closing the lid makes APF issue host
// command 0x00A0: the core must serialise its entire state, and on wake 0x00A4
// hands it back. There is no separate "sleep" to implement -- a core that can
// produce and consume a state blob can sleep, and one that cannot, cannot.
//
// WHY THIS IS A MEMORY AND NOT A FIFO.
//
// The obvious reading of savestates.sv is that it emits a stream: it hands over
// 64-bit words one at a time through a request/done mailbox and never learns
// what is on the other side. Two things make that reading wrong, and both were
// found on hardware rather than in the RTL.
//
// The blob is not written in the order it is read. Saving starts at
// savestate_address + HEADERCOUNT and writes the header LAST, back at offset 0
// (ST_SAVE_WAIT_SETTLE, ST_SAVE_HEADER). Loading reads that header FIRST
// (ST_LOAD_HEADER) and validates it before touching anything. Production order
// is internals, memories, header; consumption order is header, internals,
// memories. No queue can serve both -- the header is produced last and needed
// first. A FIFO-backed save produces a file with its header at the end, which
// then fails its own header check on restore, which is a cold boot on wake.
//
// And the two sides run at their own speeds. APF reads the region over the
// bridge at 74 MHz once it sees an ok; the engine produces slowly, waiting on
// Save_RAMReady and a settle count for every byte. The host finishes reading
// long before the engine finishes writing, stops, and the engine then stalls
// forever on a full queue -- with sleep_savestate still asserted, which holds
// the machine paused. That is a frozen game after a successful-looking save.
//
// So the blob lives in block RAM, which is what the engine has always assumed:
// on MiSTer its bus_out port talks to DDR3. bus_out_Adr is honoured, the header
// lands at offset 0 where the loader expects it, and neither side has to wait
// for the other. The device has the memory to spare -- 33,672 bytes of state
// against 136 unused M10K blocks.
//
// CARTRIDGE FLASH is not in here. savetype3_size is 0, so the state does not
// contain it; ngpc_cart_save stages dirty blocks to the nonvolatile slot
// independently. On wake the cartridge is reloaded from its own file, the
// staged blocks are applied while the machine is held in reset, and only then
// is the state restored.
//
// A state blob is only coherent with the save staged at the same moment.
// Nothing here detects a mismatched pair, which is worth fixing before this is
// relied upon.

`default_nettype none

module ngpc_savestate_bridge #(
	// Where APF reads and writes the blob in the core's bridge address space.
	parameter [3:0] BLOB_ADDR_NIBBLE = 4'h4
) (
	input  wire        clk_sys,
	input  wire        clk_74a,
	input  wire        reset,

	// ---- APF savestate handshake, clk_74a ---------------------------------
	input  wire        savestate_start,
	output wire        savestate_start_ack,
	output wire        savestate_start_busy,
	output wire        savestate_start_ok,
	output wire        savestate_start_err,

	input  wire        savestate_load,
	output wire        savestate_load_ack,
	output wire        savestate_load_busy,
	output wire        savestate_load_ok,
	output wire        savestate_load_err,

	// ---- APF bridge -------------------------------------------------------
	input  wire        bridge_wr,
	input  wire        bridge_rd,
	input  wire [31:0] bridge_addr,
	input  wire [31:0] bridge_wr_data,
	output wire [31:0] bridge_rd_data,

	// ---- The engine (savestates.sv), clk_sys ------------------------------
	output reg         ss_save,
	output reg         ss_load,
	input  wire        ss_busy,
	input  wire        ss_loading,   // engine accepted the blob's header

	input  wire [63:0] bus_out_Din,     // engine -> here, on a save
	output wire [63:0] bus_out_Dout,    // here -> engine, on a restore
	input  wire [25:0] bus_out_Adr,
	input  wire        bus_out_rnw,     // 1 = read (restore), 0 = write (save)
	input  wire        bus_out_ena,
	input  wire  [7:0] bus_out_be,
	output reg         bus_out_done
);

	// ---- APF-side status, crossed back to clk_74a -------------------------

	reg start_ack_q, start_busy_q, start_ok_q, start_err_q;
	reg load_ack_q,  load_busy_q,  load_ok_q,  load_err_q;

	synch_3 #(
		.WIDTH(8)
	) status_sync (
		{start_ack_q, start_busy_q, start_ok_q, start_err_q,
		 load_ack_q,  load_busy_q,  load_ok_q,  load_err_q},
		{savestate_start_ack, savestate_start_busy, savestate_start_ok, savestate_start_err,
		 savestate_load_ack,  savestate_load_busy,  savestate_load_ok,  savestate_load_err},
		clk_74a
	);

	wire start_s, load_s;

	synch_3 #(
		.WIDTH(2)
	) req_sync (
		{savestate_start, savestate_load},
		{start_s, load_s},
		clk_sys
	);

	// ---- The blob store ----------------------------------------------------
	//
	// 16384 x 32 bits = 64 KB, against a state of 33,672 bytes. Sized to a power
	// of two so the address decode is a slice rather than a comparison; the
	// spare space costs M10K blocks the design is not using.
	//
	// True dual port with two clocks: the engine on clk_sys, APF on clk_74a.
	// The two never touch the same word at the same time -- APF reads only after
	// it has been told the save is complete, and writes only before it asks for
	// a load -- so no arbitration is needed between them.

	localparam integer BLOB_WORDS = 16384;   // 32-bit words

	// no_rw_check: the two ports never touch the same word at the same time, so
	// what a read returns during a simultaneous write to that word is not a
	// question this design asks. Without it Quartus declines to infer block RAM
	// at all -- it cannot guarantee read-during-write semantics across two
	// clocks -- and tries to build 16384 words out of registers instead.
	(* ramstyle = "no_rw_check, M10K" *)
	reg [31:0] blob [0:BLOB_WORDS-1];

	// ---- Engine side (clk_sys) ---------------------------------------------
	//
	// bus_out_Adr counts 32-bit words, and a 64-bit access spans Adr and Adr+1:
	// Din[31:0] at Adr, Din[63:32] at Adr+1. Each access is therefore two RAM
	// cycles, which costs nothing -- the engine spends far longer than that per
	// word waiting on Save_RAMReady.
	//
	// bus_out_be is honoured by simply not writing the half whose enables are
	// clear. The engine only ever uses 8'hff or 8'hf0 (the header write, which
	// preserves the header count in the low half), so per-byte masking inside a
	// half is never asked for.

	function automatic [31:0] bswap32(input [31:0] w);
		bswap32 = {w[7:0], w[15:8], w[23:16], w[31:24]};
	endfunction

	localparam [1:0] E_IDLE = 2'd0;
	localparam [1:0] E_LO   = 2'd1;
	localparam [1:0] E_HI   = 2'd2;
	localparam [1:0] E_DONE = 2'd3;

	reg [1:0]  e_state;
	reg [31:0] e_lo_captured;

	// ---- PROBE ---------------------------------------------------------
	//
	// TEMPORARY. The save side is proven correct -- the state files on the
	// device carry bswap32(8416) at payload word 1, exactly where
	// ST_LOAD_HEADER looks. The load side rejects that same blob, and every
	// explanation left needs to know what the store actually CONTAINED when
	// the engine read it. Reasoning has been wrong about this path three
	// times; this reads it out instead.
	//
	// savestate_size is extended by 16 bytes and the four words past the end
	// of the real state are served from these registers rather than from RAM.
	// A state saved after a failed load therefore carries, in its last 16
	// bytes: what word 0 and word 1 held when the header was read, how many
	// blob writes APF has made, and the last address it wrote.
	//
	// Remove this once the load path works.
	reg [31:0] dbg_a0;   // bus data seen at blob word 0
	reg [31:0] dbg_a1;   // bus data seen at blob word 1

	// The port itself. ONE address, ONE access per cycle -- both ports have to
	// look like this or Quartus will not infer block RAM, and 16384 words of
	// registers does not fit in anything.
	reg [13:0] a_addr;
	reg        a_we;
	reg [31:0] a_din;
	reg [31:0] a_q;

	always @(posedge clk_sys) begin
		if (a_we) begin
			blob[a_addr] <= a_din;
		end
		a_q <= blob[a_addr];
	end

	wire [13:0] e_word0 = bus_out_Adr[14:1];
	wire [13:0] e_word1 = bus_out_Adr[14:1] + 14'd1;

	// The 64-bit view the engine sees on a restore, reassembled from the two
	// halves and unswizzled. The swizzle is its own inverse, so the save and
	// load paths use the same function.
	assign bus_out_Dout = {bswap32(a_q), bswap32(e_lo_captured)};

	always @(posedge clk_sys) begin
		bus_out_done <= 1'b0;
		a_we         <= 1'b0;

		case (e_state)
			E_IDLE: begin
				if (bus_out_ena) begin
					a_addr  <= e_word0;
					a_we    <= !bus_out_rnw && (bus_out_be[3:0] != 4'd0);
					a_din   <= bswap32(bus_out_Din[31:0]);
					e_state <= E_LO;
				end
			end

			// The low half is being accessed this cycle; queue the high half.
			E_LO: begin
				a_addr  <= e_word1;
				a_we    <= !bus_out_rnw && (bus_out_be[7:4] != 4'd0);
				a_din   <= bswap32(bus_out_Din[63:32]);
				e_state <= E_HI;
			end

			// a_q now holds the low half; the high half is being accessed.
			E_HI: begin
				e_lo_captured <= a_q;
				e_state       <= E_DONE;
			end

			// a_q now holds the high half, and a_addr is not disturbed again, so
			// both halves stay valid through the cycle the engine sees done in.
			E_DONE: begin
				bus_out_done <= 1'b1;
				e_state      <= E_IDLE;
			end

			default: e_state <= E_IDLE;
		endcase

		if (reset) begin
			e_state <= E_IDLE;
			a_we    <= 1'b0;
		end
	end

	// Has APF finished writing the blob?
	//
	// The load command and the transfer are not ordered by anything this module
	// can see. The reference core sidesteps the question by starting the moment
	// data appears and treating the command as a trailing acknowledgement; that
	// works for a queue, but a memory has to be COMPLETE before the engine reads
	// its header, not merely started.
	//
	// So the engine waits for the transfer to go quiet. If the data came first
	// the wait is already satisfied when the command arrives; if the command
	// came first, this is what stops the engine reading an empty store, failing
	// the header check, and reporting a success that restores nothing.
	localparam [16:0] BLOB_QUIET = 17'd100_000;   // ~1.35 ms at 74.25 MHz

	reg [16:0] blob_quiet_cnt = BLOB_QUIET;

	always @(posedge clk_74a) begin
		if (blob_sel && bridge_wr) begin
			blob_quiet_cnt <= 17'd0;
		end else if (blob_quiet_cnt != BLOB_QUIET) begin
			blob_quiet_cnt <= blob_quiet_cnt + 17'd1;
		end
	end

	wire blob_quiet_74 = (blob_quiet_cnt == BLOB_QUIET);
	wire blob_quiet_s;

	synch_3 quiet_sync (blob_quiet_74, blob_quiet_s, clk_sys);

	// ---- APF side (clk_74a) -------------------------------------------------
	//
	// A plain window into the store. APF reads it after a save and writes it
	// before a load; there is no handshake here because the sequencing below
	// guarantees it never overlaps the engine.


	// PROBE: how much APF has written, and where it last wrote. If the count is
	// zero when a load fails, the blob never reached this core and the fault is
	// in the transfer rather than anywhere in this module.
	reg [31:0] dbg_wr_count;
	reg [13:0] dbg_last_addr;

	localparam [13:0] DBG_BASE = 14'd8420;   // past the state, 4-aligned for the decode

	reg [31:0] blob_q;
	reg [31:0] dbg_q;
	reg        dbg_hit;

	wire        blob_sel  = bridge_addr[31:28] == BLOB_ADDR_NIBBLE;
	wire [13:0] blob_word = bridge_addr[15:2];

	// WRITES GO WHERE THEY ARRIVE, NOT WHERE THE ADDRESS SAYS.
	//
	// bridge_addr is not trustworthy per word during a write burst. Two probe
	// rounds from the device showed the blob arriving complete and in order --
	// 8424 words, addresses running 0 to 8423 -- but every word paired with the
	// address one place behind it: at address 0 the bus carried payload word 1.
	//
	// Both working openFPGA cores that implement savestates ignore the address
	// on this path entirely. The NES reference and the GBA core each gate a FIFO
	// on nothing but `bridge_wr && bridge_addr[31:28] == 4'h4` and rely on
	// arrival order. A FIFO cannot serve this engine -- it reads the header back
	// first and writes it last -- but the ORDER it relies on is sound, so a
	// write pointer gets the same guarantee into a memory.
	//
	// The pointer restarts on the first write after a quiet period, which is
	// what separates one transfer from the next.
	reg prev_bridge_wr;
	reg [13:0] wr_ptr;
	wire blob_wr_stb = blob_sel && bridge_wr && !prev_bridge_wr;

	// True on the first write of a burst: the quiet counter has not been reset
	// by this write yet, so it still reads saturated.
	wire wr_first = blob_quiet_74;
	wire [13:0] wr_at = wr_first ? 14'd0 : wr_ptr;

	// ONE address expression for this port. Quartus will not infer block RAM
	// from a process that indexes the array two different ways, and APF never
	// reads and writes in the same cycle, so the write pointer and the read
	// address can share the port. A read issued during a write returns nothing
	// meaningful, and nothing asks for one.
	wire [13:0] b_addr = blob_wr_stb ? wr_at : blob_word;

	always @(posedge clk_74a) begin
		prev_bridge_wr <= bridge_wr;

		if (blob_wr_stb) begin
			blob[b_addr]    <= bridge_wr_data;
			wr_ptr          <= wr_at + 14'd1;
			dbg_wr_count    <= dbg_wr_count + 32'd1;
			dbg_last_addr   <= wr_at;

			// PROBE, second round. The first round proved the blob arrives
			// complete (8424 words, last address 8423) but lands one word out.
			// Rising-edge capture did not change that, so the strobe width is
			// not the cause and the question is now what the BUS carries: this
			// keeps the data seen at address 0 and at address 1, to be compared
			// against the loaded file's payload words 0 and 1.
			if (wr_at == 14'd0) dbg_a0 <= bridge_wr_data;
			if (wr_at == 14'd1) dbg_a1 <= bridge_wr_data;
		end

		blob_q <= blob[b_addr];

		// Exact compares rather than a range plus a subtract: four equalities
		// against a constant are a handful of LUTs, and this is temporary.
		dbg_hit <= blob_sel && (blob_word[13:2] == DBG_BASE[13:2])
		                    && (blob_word[13:2] != 12'd0);
		case (blob_word[1:0])
			2'd0:    dbg_q <= dbg_a0;
			2'd1:    dbg_q <= dbg_a1;
			2'd2:    dbg_q <= dbg_wr_count;
			default: dbg_q <= {18'd0, dbg_last_addr};
		endcase
	end

	// The probe registers live entirely on clk_74a -- written by the bridge write
	// strobe, read by the bridge read -- so nothing here crosses a clock domain.
	// The previous round captured engine-side values on clk_sys and did need
	// care about that; this one does not.

	assign bridge_rd_data = dbg_hit ? dbg_q : blob_q;


	// ---- Sequencing --------------------------------------------------------
	//
	// With a memory behind it this is the straightforward reading of the
	// protocol, and the straightforward reading is now the correct one: APF
	// polls 0x00A0 for a result code and reads the region once it sees ok, so
	// ok means the blob is complete and sitting at savestate_addr. On a load
	// APF has already written the whole region before it issues the command.

	localparam S_IDLE      = 3'd0;
	localparam S_SAVE_RUN  = 3'd1;
	localparam S_LOAD_WAIT = 3'd2;
	localparam S_LOAD_RUN  = 3'd3;
	localparam S_DONE      = 3'd4;

	reg [2:0]  state;
	reg        prev_start, prev_load, prev_ss_busy;
	reg        saw_loading;      // the engine accepted the header this run

	always @(posedge clk_sys) begin
		ss_save <= 1'b0;
		ss_load <= 1'b0;

		prev_start   <= start_s;
		prev_load    <= load_s;
		prev_ss_busy <= ss_busy;

		if (reset) begin
			state        <= S_IDLE;
			saw_loading  <= 1'b0;
			start_ack_q  <= 1'b0; start_busy_q <= 1'b0;
			start_ok_q   <= 1'b0; start_err_q  <= 1'b0;
			load_ack_q   <= 1'b0; load_busy_q  <= 1'b0;
			load_ok_q    <= 1'b0; load_err_q   <= 1'b0;
		end else begin
			case (state)
				S_IDLE: begin
					start_ack_q <= 1'b0;
					load_ack_q  <= 1'b0;

					if (start_s && !prev_start) begin
						start_ack_q  <= 1'b1;
						start_busy_q <= 1'b1;
						start_ok_q   <= 1'b0;
						start_err_q  <= 1'b0;
						ss_save      <= 1'b1;
						state        <= S_SAVE_RUN;
					end else if (load_s && !prev_load) begin
						load_ack_q    <= 1'b1;
						load_busy_q   <= 1'b1;
						load_ok_q     <= 1'b0;
						load_err_q    <= 1'b0;
						saw_loading   <= 1'b0;
						state         <= S_LOAD_WAIT;
					end
				end

				S_SAVE_RUN: begin
					start_ack_q <= 1'b0;
					if (prev_ss_busy && !ss_busy) begin
						start_busy_q <= 1'b0;
						start_ok_q   <= 1'b1;
						state        <= S_DONE;
					end
				end

				// Hold until the transfer is quiet, then start the engine.
				//
				// No timeout guards this, and none is needed: the quiet counter
				// starts SATISFIED, so a load command with no transfer behind it
				// starts the engine at once, fails the header check and reports
				// the failure. The only way to wait here is for writes to be
				// actively arriving, and those stop.
				S_LOAD_WAIT: begin
					load_ack_q <= 1'b0;

					if (blob_quiet_s) begin
						ss_load <= 1'b1;
						state   <= S_LOAD_RUN;
					end
				end

				S_LOAD_RUN: begin
					load_ack_q <= 1'b0;

					if (ss_loading) begin
						saw_loading <= 1'b1;
					end

					if (prev_ss_busy && !ss_busy) begin
						load_busy_q <= 1'b0;
						// The engine raises loading_savestate only after the
						// header check passes. Without it the blob was rejected
						// and nothing was restored -- which must be reported as a
						// failure, not as a success that silently does nothing.
						load_ok_q   <=  saw_loading;
						load_err_q  <= !saw_loading;
						state       <= S_DONE;
					end
				end

				S_DONE: begin
					if (!start_s && !load_s) begin
						state <= S_IDLE;
					end
				end

				default: state <= S_IDLE;
			endcase
		end
	end

	wire unused_ok = &{1'b0, bus_out_Adr[25:15], bridge_rd, 1'b0};

endmodule

`default_nettype wire
