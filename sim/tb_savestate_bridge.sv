// Testbench: the savestate transport, end to end, against the real engine.
//
// WHY THIS EXISTS. Five transport defects were found on hardware, one build
// and one human test at a time: a FIFO where the engine needs a memory, a
// 3x-too-large size, edge-gated writes dropping contiguous first strobes, a
// store index that halved every address, and a quiet-restart that re-fired
// mid-transfer on SD stalls. Every one of them would have fallen out of this
// bench in seconds. From now on the transport does not change unless this
// bench passes.
//
// WHAT IS REAL AND WHAT IS MODELED.
//   Real: ngpc_savestate_bridge.sv (the DUT) and upstream savestates.sv (the
//   engine), compiled unmodified.
//   Modeled: the machine behind the engine (internals bus + three byte
//   memories with known patterns), and APF's bridge bus.
//
// THE APF BUS MODEL is scripted from measurements, not from documentation:
//   - one bridge_wr strobe per 32-bit word, gaps between words
//   - THE ADDRESS LAGS THE DATA BY ONE STROBE on write bursts ("uniform lag"):
//     strobe k carries data word k with the ADDRESS of word k-1, and the
//     first strobe carries the pre-burst address. Measured twice on hardware:
//     a probe capturing "data seen while address==0" recorded file word 1,
//     and arrival pointers recorded file words 1,2 at slots 0,1.
//   - mid-burst stalls of milliseconds (SD streaming), measured via a
//     pointer-restart corruption they triggered
//   - reads: address presented, data sampled a few cycles later (the DUT's
//     registered RAM read needs >=2 clk_74a; APF is far slower than that)
//   The bench can also drive a NO-LAG bus (addr+data aligned) so a fix can be
//   judged against both readings of the world.
//
// SCENARIOS
//   S1  save -> readout -> corrupt machine -> write back (lagged bus) -> load
//       -> machine must equal the original, byte for byte.  Before the
//       header-recognition fix this reproduced the hardware "Loading failed"
//       (first word rejected by the nibble gate, blob[0]=file[1]); it now
//       passes, and stays here as the regression for exactly that bug.
//   S2  same with a foreign-region write immediately before the burst.
//   S3  same with a ~2 ms stall in the middle of the write burst.
//   S4  same on a NO-LAG bus (documents behavior if the lag model is wrong).
//   S5  save readout with duplicate and repeated reads (APF re-reads words).
//
// PASS = every scenario's verdict matches EXPECT_* below -- currently all
// five expect a working, byte-exact load.

`timescale 1ns / 1ps
`default_nettype none

module tb;

	// ---- clocks: 49.152 MHz core, 74.25 MHz bridge -------------------------
	reg clk_sys = 0;
	reg clk_74a = 0;
	always #10.173 clk_sys = ~clk_sys;   // 20.345 ns period
	always #6.734  clk_74a = ~clk_74a;   // 13.468 ns period

	reg reset = 1;

	// ---- state geometry (mirror of ngpc_machine's engine config) -----------
	localparam integer N_INT   = 112;     // 64-bit internals
	localparam integer SZ0     = 12288;
	localparam integer SZ1     = 4096;
	localparam integer SZ2     = 16384;
	localparam integer WORDS   = 8424;    // 8418 state + 2 pad + 4 probe words
	localparam [31:0]  BLOBBASE = 32'h40000000;

	// ---- the machine model -------------------------------------------------
	reg [63:0] internals [0:N_INT];      // one spare, engine walks 0..N_INT-1
	reg [63:0] internals_gold [0:N_INT];
	reg [7:0]  mem0 [0:SZ0-1];  reg [7:0] mem0_gold [0:SZ0-1];
	reg [7:0]  mem1 [0:SZ1-1];  reg [7:0] mem1_gold [0:SZ1-1];
	reg [7:0]  mem2 [0:SZ2-1];  reg [7:0] mem2_gold [0:SZ2-1];

	// ---- engine <-> machine wiring ----------------------------------------
	wire [63:0] eng_bus_din;
	wire  [9:0] eng_bus_adr;
	wire        eng_bus_wren;
	wire        eng_bus_rst;
	wire [63:0] eng_bus_dout = internals[eng_bus_adr];

	wire [24:0] ram_addr;
	wire        ram_rden, ram_wren;
	wire  [7:0] ram_wdata;
	wire  [2:0] ram_type;
	reg   [7:0] ram_rdata_q, ram_rdata_q2;
	wire  [7:0] ram_rdata = ram_rdata_q2;   // 2-cycle latency like the k2ge tap

	always @(posedge clk_sys) begin
		case (ram_type)
			3'd0: ram_rdata_q <= mem0[ram_addr[13:0]];
			3'd1: ram_rdata_q <= mem1[ram_addr[11:0]];
			default: ram_rdata_q <= mem2[ram_addr[13:0]];
		endcase
		ram_rdata_q2 <= ram_rdata_q;

		if (ram_wren) begin
			case (ram_type)
				3'd0: mem0[ram_addr[13:0]] <= ram_wdata;
				3'd1: mem1[ram_addr[11:0]] <= ram_wdata;
				default: mem2[ram_addr[13:0]] <= ram_wdata;
			endcase
		end

		if (eng_bus_wren) begin
			internals[eng_bus_adr] <= eng_bus_din;
		end
	end

	// pause: the machine parks a few cycles after the engine asks
	wire eng_pause_req;
	reg  [2:0] pause_pipe = 0;
	always @(posedge clk_sys) pause_pipe <= {pause_pipe[1:0], eng_pause_req};
	wire paused = pause_pipe[2];

	// ---- engine <-> bridge wiring ------------------------------------------
	wire [63:0] bus_out_Din, bus_out_Dout;
	wire [25:0] bus_out_Adr;
	wire        bus_out_rnw, bus_out_ena, bus_out_done;
	wire  [7:0] bus_out_be;
	wire        ss_save, ss_load, ss_busy, ss_loading;

	savestates #(
		.STATESIZE_PARAM      (8416),
		.SETTLECOUNT_PARAM    (16),
		.INTERNALSCOUNT_PARAM (N_INT),
		.SAVETYPESCOUNT_PARAM (3),
		.SAVETYPE0_SIZE       (SZ0),
		.SAVETYPE1_SIZE       (SZ1),
		.SAVETYPE2_SIZE       (SZ2),
		.SAVETYPE3_SIZE       (0)
	) engine (
		.clk                     (clk_sys),
		.reset_in                (reset),
		.reset_ss                (),
		.reset_delay             (),
		.restore_begin           (),
		.load_done               (),
		.restore_prepare_ready_i (1'b1),
		.restore_prepare_failed_i(1'b0),
		.increaseSSHeaderCount   (1'b0),
		.save                    (ss_save),
		.load                    (ss_load),
		.state_size_i            (32'd8416),
		.savetype3_size_i        (25'd0),
		.is_rewind_i             (1'b0),
		.savestate_address       (0),
		.savestate_busy          (ss_busy),
		.paused                  (paused),

		.BUS_Din                 (eng_bus_din),
		.BUS_Adr                 (eng_bus_adr),
		.BUS_wren                (eng_bus_wren),
		.BUS_rst                 (eng_bus_rst),
		.BUS_Dout                (eng_bus_dout),

		.loading_savestate       (ss_loading),
		.saving_savestate        (),
		.sleep_savestate         (eng_pause_req),

		.Save_RAMAddr            (ram_addr),
		.Save_RAMRdEn            (ram_rden),
		.Save_RAMWrEn            (ram_wren),
		.Save_RAMWriteData       (ram_wdata),
		.Save_RAMReadData        (ram_rdata),
		.Save_RAMReady           (1'b1),
		.Save_RAMType            (ram_type),

		.bus_out_Din             (bus_out_Din),
		.bus_out_Dout            (bus_out_Dout),
		.bus_out_Adr             (bus_out_Adr),
		.bus_out_rnw             (bus_out_rnw),
		.bus_out_ena             (bus_out_ena),
		.bus_out_be              (bus_out_be),
		.bus_out_done            (bus_out_done)
	);

	// ---- APF-side bus ------------------------------------------------------
	reg         bridge_wr = 0, bridge_rd = 0;
	reg  [31:0] bridge_addr = 32'hF8000000;
	reg  [31:0] bridge_wr_data = 0;
	wire [31:0] bridge_rd_data;

	reg  ss_start_req = 0, ss_load_req = 0;
	wire start_ack, start_busy, start_ok, start_err;
	wire load_ack,  load_busy,  load_ok,  load_err;

	ngpc_savestate_bridge dut (
		.clk_sys(clk_sys), .clk_74a(clk_74a), .reset(reset),

		.savestate_start     (ss_start_req),
		.savestate_start_ack (start_ack),
		.savestate_start_busy(start_busy),
		.savestate_start_ok  (start_ok),
		.savestate_start_err (start_err),

		.savestate_load     (ss_load_req),
		.savestate_load_ack (load_ack),
		.savestate_load_busy(load_busy),
		.savestate_load_ok  (load_ok),
		.savestate_load_err (load_err),

		.bridge_wr(bridge_wr), .bridge_rd(bridge_rd),
		.bridge_addr(bridge_addr), .bridge_wr_data(bridge_wr_data),
		.bridge_rd_data(bridge_rd_data),

		.ss_save(ss_save), .ss_load(ss_load),
		.ss_busy(ss_busy), .ss_loading(ss_loading),

		.bus_out_Din(bus_out_Din), .bus_out_Dout(bus_out_Dout),
		.bus_out_Adr(bus_out_Adr), .bus_out_rnw(bus_out_rnw),
		.bus_out_ena(bus_out_ena), .bus_out_be(bus_out_be),
		.bus_out_done(bus_out_done)
	);

	// ---- helpers -----------------------------------------------------------
	reg [31:0] image [0:WORDS-1];
	integer errors;

	task machine_init;
		integer i;
		begin
			for (i = 0; i <= N_INT; i = i + 1) begin
				internals[i] = {8'hA5, i[7:0], 8'h5A, ~i[7:0], i[15:0], ~i[15:0]};
				internals_gold[i] = internals[i];
			end
			for (i = 0; i < SZ0; i = i + 1) begin mem0[i] = i[7:0] ^ 8'hC3; mem0_gold[i] = mem0[i]; end
			for (i = 0; i < SZ1; i = i + 1) begin mem1[i] = (i[7:0] * 7) + 8'h11; mem1_gold[i] = mem1[i]; end
			for (i = 0; i < SZ2; i = i + 1) begin mem2[i] = i[7:0] + i[11:4]; mem2_gold[i] = mem2[i]; end
		end
	endtask

	task machine_corrupt;
		integer i;
		begin
			for (i = 0; i <= N_INT; i = i + 1) internals[i] = 64'hDEADBEEF_DEADBEEF;
			for (i = 0; i < SZ0; i = i + 1) mem0[i] = 8'hFF;
			for (i = 0; i < SZ1; i = i + 1) mem1[i] = 8'hFF;
			for (i = 0; i < SZ2; i = i + 1) mem2[i] = 8'hFF;
		end
	endtask

	task machine_check(output integer errs);
		integer i;
		begin
			errs = 0;
			for (i = 0; i < N_INT; i = i + 1)
				if (internals[i] !== internals_gold[i]) begin
					if (errs < 4) $display("    internals[%0d] %h != %h", i, internals[i], internals_gold[i]);
					errs = errs + 1;
				end
			for (i = 0; i < SZ0; i = i + 1) if (mem0[i] !== mem0_gold[i]) errs = errs + 1;
			for (i = 0; i < SZ1; i = i + 1) if (mem1[i] !== mem1_gold[i]) errs = errs + 1;
			for (i = 0; i < SZ2; i = i + 1) if (mem2[i] !== mem2_gold[i]) errs = errs + 1;
		end
	endtask

	// APF host command: request a save, wait for ok, read the region out.
	task apf_save(input integer read_quirks);
		integer k, r;
		begin
			@(posedge clk_74a); ss_start_req <= 1;
			wait (start_ack);  @(posedge clk_74a); ss_start_req <= 0;
			wait (start_ok || start_err);
			if (start_err) $display("    !! save reported err");
			// linear readout; the DUT's read is continuous, data valid 2 clk after addr
			for (k = 0; k < WORDS; k = k + 1) begin
				@(posedge clk_74a); bridge_addr <= BLOBBASE | (k*4); bridge_rd <= 1;
				repeat (3) @(posedge clk_74a);
				image[k] = bridge_rd_data;
				bridge_rd <= 0;
				if (read_quirks && (k % 97 == 0)) begin
					// APF re-reads a word it already took
					repeat (2) @(posedge clk_74a);
					r = bridge_rd_data;
					if (r !== image[k]) $display("    !! re-read of %0d changed: %h -> %h", k, image[k], r);
				end
			end
			@(posedge clk_74a); bridge_rd <= 0; bridge_addr <= 32'hF8000000;
		end
	endtask

	// One write strobe. In lag mode the ADDRESS presented is the previous
	// strobe's word address (the measured APF behavior); the first strobe of a
	// burst therefore carries the pre-burst address.
	task apf_write_burst(input integer lag, input integer gap,
	                     input integer stall_at, input integer stall_len,
	                     input integer foreign_first);
		integer k;
		reg [31:0] a;
		begin
			if (foreign_first) begin
				@(posedge clk_74a);
				bridge_addr <= 32'hF8001000; bridge_wr_data <= 32'h6E6F7065; bridge_wr <= 1;
				@(posedge clk_74a); bridge_wr <= 0;
				repeat (6) @(posedge clk_74a);
			end
			// settle: the stale address a lagged first strobe carries is whatever
			// the bus held before the burst -- model it explicitly rather than
			// racing the previous task's trailing assignment
			@(posedge clk_74a);
			for (k = 0; k < WORDS; k = k + 1) begin
				if (k == stall_at && stall_len > 0) repeat (stall_len) @(posedge clk_74a);
				if (lag) a = (k == 0) ? 32'hF8000050 : (BLOBBASE | ((k-1)*4));
				else     a = BLOBBASE | (k*4);
				@(posedge clk_74a);
				bridge_addr <= a; bridge_wr_data <= image[k]; bridge_wr <= 1;
				@(posedge clk_74a); bridge_wr <= 0;
				repeat (gap) @(posedge clk_74a);
			end
			@(posedge clk_74a); bridge_addr <= 32'hF8000000;
		end
	endtask

	// APF host command: the blob is already written; issue load, await verdict.
	task apf_load(output integer ok);
		begin
			@(posedge clk_74a); ss_load_req <= 1;
			wait (load_ack); @(posedge clk_74a); ss_load_req <= 0;
			wait (load_ok || load_err);
			ok = load_ok ? 1 : 0;
			// release: the DUT leaves S_DONE when the request is long gone
			repeat (8) @(posedge clk_74a);
		end
	endtask

	task scenario(input [8*60:1] name,
	              input integer lag, input integer gap,
	              input integer stall_at, input integer stall_len,
	              input integer foreign_first, input integer read_quirks,
	              input integer expect_ok);
		integer ok, errs;
		begin
			$display("== %0s", name);
			machine_init;
			apf_save(read_quirks);
			if (image[1] !== 32'hE0200000)
				$display("    !! image word1 = %h, expected E0200000 (bswapped 8416)", image[1]);
			machine_corrupt;
			apf_write_burst(lag, gap, stall_at, stall_len, foreign_first);
			apf_load(ok);
			if (ok) begin
				machine_check(errs);
				if (errs == 0 && expect_ok) $display("   PASS (loaded, machine byte-exact)");
				else if (errs == 0)         $display("   UNEXPECTED PASS (expected failure)");
				else begin
					$display("   FAIL: load ok but %0d bytes wrong", errs);
					errors = errors + 1;
				end
			end else begin
				$display("   load rejected (arrival[0]=%h arrival[1]=%h, file[1]=%h file[2]=%h)",
				         dut.blob[0], dut.blob[1], image[1], image[2]);
				if (expect_ok) begin
					$display("   FAIL: expected a working load");
					errors = errors + 1;
				end else begin
					$display("   EXPECTED-FAIL confirmed%0s",
					         (dut.blob[0] === image[1]) ? " -- hardware signature reproduced (blob[0]=file[1])" : "");
				end
			end
		end
	endtask

	initial begin
		errors = 0;
		repeat (20) @(posedge clk_sys);
		reset = 0;
		repeat (40) @(posedge clk_sys);

		//        name                                  lag gap stall@  len   foreign quirks expect_ok
		scenario("S1 lagged bus (measured APF model)  ", 1,  8,  -1,     0,     0,      0,     1);
		scenario("S2 lagged + foreign pre-burst write ", 1,  8,  -1,     0,     1,      0,     1);
		scenario("S3 lagged + 2ms mid-burst SD stall  ", 1,  8,  4211, 150000,  0,      0,     1);
		scenario("S4 clean bus (no lag)               ", 0,  8,  -1,     0,     0,      0,     1);
		scenario("S5 clean + read quirks              ", 0,  4,  -1,     0,     0,      1,     1);

		if (errors == 0) $display("== ALL SCENARIOS MATCHED EXPECTATIONS");
		else             $display("== %0d SCENARIO(S) DEVIATED", errors);
		$finish;
	end

	// global watchdog
	initial begin
		#80_000_000;   // 80 ms of sim time
		$display("== WATCHDOG TIMEOUT");
		$finish;
	end

endmodule

`default_nettype wire
