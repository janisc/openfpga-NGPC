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
// LAYOUT 2: the blob carries an embedded cart image (a full .sav, header and
// payload) at CART_BASE, so a savestate alone reconstructs both machine and
// cartridge flash. The bridge hands the section to a copier over a small
// port; here the copier is MODELED (like the APF bus is) -- the real
// ngpc_state_cart gets its own bench. The model also polices ordering: on a
// load the cart section must be drained (and by implication applied) BEFORE
// the engine is allowed to restore the machine.
//
// WHAT IS REAL AND WHAT IS MODELED.
//   Real: ngpc_savestate_bridge.sv (the DUT) and upstream savestates.sv (the
//   engine), compiled unmodified.
//   Modeled: the machine behind the engine (internals bus + three byte
//   memories with known patterns), APF's bridge bus, and the cart copier.
//
// THE APF BUS MODEL is scripted from measurements, not from documentation:
//   - one bridge_wr strobe per 32-bit word, gaps between words
//   - THE ADDRESS LAGS THE DATA BY ONE STROBE on write bursts ("uniform lag"):
//     strobe k carries data word k with the ADDRESS of word k-1, and the
//     first strobe carries the pre-burst address. Measured twice on hardware.
//   - mid-burst stalls of milliseconds (SD streaming)
//   - reads: address presented, data sampled a few cycles later
//
// SCENARIOS
//   S1  save -> readout -> corrupt -> write back (lagged bus) -> load ->
//       machine AND cart image byte-exact.
//   S2  same with a foreign-region write immediately before the burst.
//   S3  same with a ~2 ms stall in the middle of the write burst.
//   S4  same on a NO-LAG bus.
//   S5  save readout with duplicate reads (APF re-reads words).
//   S6  cross-cartridge load rejected before the engine or copier touch
//       anything.
//   S7  old-layout state (ID_LAYOUT=1) rejected cleanly: no engine start,
//       no cart handoff, machine untouched. The format-break honesty test.
//
// PASS = every scenario's verdict matches EXPECT_* below.

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
	localparam integer CARTB   = 8424;    // cart section base, words
	localparam integer CARTW   = 16256;   // 0xFE00 bytes: the .sav slot size
	localparam integer WORDS   = CARTB + CARTW;   // 24,680 words = 98,720 B
	localparam [31:0]  BLOBBASE = 32'h40000000;

	// ---- the machine model -------------------------------------------------
	reg [63:0] internals [0:N_INT];      // one spare, engine walks 0..N_INT-1
	reg [63:0] internals_gold [0:N_INT];
	reg [7:0]  mem0 [0:SZ0-1];  reg [7:0] mem0_gold [0:SZ0-1];
	reg [7:0]  mem1 [0:SZ1-1];  reg [7:0] mem1_gold [0:SZ1-1];
	reg [7:0]  mem2 [0:SZ2-1];  reg [7:0] mem2_gold [0:SZ2-1];

	// ---- the cart image model ----------------------------------------------
	reg [31:0] sav_img  [0:CARTW-1];     // what the copier would capture
	reg [31:0] sav_gold [0:CARTW-1];
	reg [31:0] sav_rd   [0:CARTW-1];     // what the copier drained on load

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
	reg  [31:0] tb_cart_crc = 32'hC0FFEE01;
	wire start_ack, start_busy, start_ok, start_err;
	wire load_ack,  load_busy,  load_ok,  load_err;

	// ---- copier port -------------------------------------------------------
	wire        cart_save_req, cart_load_req;
	reg         cart_save_done = 0, cart_load_done = 0;
	reg         cart_img_wr = 0;
	reg  [13:0] cart_img_addr = 0;
	reg  [31:0] cart_img_data = 0;
	reg  [13:0] cart_img_rd_addr = 0;
	wire [31:0] cart_img_rd_data;

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
		.cart_crc32(tb_cart_crc),

		.cart_save_req   (cart_save_req),
		.cart_save_done  (cart_save_done),
		.cart_img_wr     (cart_img_wr),
		.cart_img_addr   (cart_img_addr),
		.cart_img_data   (cart_img_data),
		.cart_load_req   (cart_load_req),
		.cart_load_done  (cart_load_done),
		.cart_img_rd_addr(cart_img_rd_addr),
		.cart_img_rd_data(cart_img_rd_data),

		.bus_out_Din(bus_out_Din), .bus_out_Dout(bus_out_Dout),
		.bus_out_Adr(bus_out_Adr), .bus_out_rnw(bus_out_rnw),
		.bus_out_ena(bus_out_ena), .bus_out_be(bus_out_be),
		.bus_out_done(bus_out_done)
	);

	// ---- the copier model --------------------------------------------------
	// Responds to the DUT's pulses the way ngpc_state_cart will: on save it
	// streams sav_img[] in with gaps; on load it drains the section into
	// sav_rd[] before signalling done. Also the ordering monitor: the engine
	// must not start restoring while the drain (and by implication the flash
	// apply) is still running.
	reg        copier_draining = 0;
	reg        order_violation = 0;
	reg        saw_load_req = 0;
	integer    ci;

	always @(posedge clk_sys) begin
		if (ss_load && copier_draining) begin
			order_violation <= 1;
		end
		if (cart_load_req) begin
			saw_load_req <= 1;
		end
	end

	always @(posedge clk_sys) begin : copier
		cart_save_done <= 0;
		cart_load_done <= 0;
		cart_img_wr    <= 0;
		if (cart_save_req) begin
			// stream the image in, one word per 3 cycles
			for (ci = 0; ci < CARTW; ci = ci + 1) begin
				@(posedge clk_sys);
				cart_img_wr   <= 1;
				cart_img_addr <= ci[13:0];
				cart_img_data <= sav_img[ci];
				@(posedge clk_sys);
				cart_img_wr <= 0;
				@(posedge clk_sys);
			end
			@(posedge clk_sys);
			cart_img_wr    <= 0;
			cart_save_done <= 1;
		end
		if (cart_load_req) begin
			copier_draining <= 1;
			for (ci = 0; ci < CARTW; ci = ci + 1) begin
				@(posedge clk_sys);
				cart_img_rd_addr <= ci[13:0];
				repeat (3) @(posedge clk_sys);
				sav_rd[ci] = cart_img_rd_data;
			end
			@(posedge clk_sys);
			copier_draining <= 0;
			cart_load_done  <= 1;
		end
	end

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
			// a recognizable "sav": magic-ish first words, hashy payload
			sav_img[0] = 32'h4E475043;   // NGPC
			sav_img[1] = 32'h53415632;   // SAV2
			for (i = 2; i < CARTW; i = i + 1) begin
				sav_img[i] = {i[15:0], ~i[15:0]} ^ 32'h5A5A00FF;
			end
			for (i = 0; i < CARTW; i = i + 1) begin
				sav_gold[i] = sav_img[i];
				sav_rd[i]   = 32'hCCCCCCCC;
			end
		end
	endtask

	task machine_corrupt;
		integer i;
		begin
			for (i = 0; i <= N_INT; i = i + 1) internals[i] = 64'hDEADBEEF_DEADBEEF;
			for (i = 0; i < SZ0; i = i + 1) mem0[i] = 8'hFF;
			for (i = 0; i < SZ1; i = i + 1) mem1[i] = 8'hFF;
			for (i = 0; i < SZ2; i = i + 1) mem2[i] = 8'hFF;
			for (i = 0; i < CARTW; i = i + 1) begin
				sav_img[i] = 32'hFFFFFFFF;   // capture source gone too
				sav_rd[i]  = 32'hCCCCCCCC;
			end
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

	task cart_check(output integer errs);
		integer i;
		begin
			errs = 0;
			for (i = 0; i < CARTW; i = i + 1)
				if (sav_rd[i] !== sav_gold[i]) begin
					if (errs < 4) $display("    sav_rd[%0d] %h != %h", i, sav_rd[i], sav_gold[i]);
					errs = errs + 1;
				end
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
				if (read_quirks && (k % 997 == 0)) begin
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
		integer ok, errs, cerrs, k;
		begin
			$display("== %0s", name);
			machine_init;
			order_violation = 0;
			apf_save(read_quirks);
			if (image[1] !== 32'hE0200000)
				$display("    !! image word1 = %h, expected E0200000 (bswapped 8416)", image[1]);
			if (image[8420] !== 32'h4E475053 || image[8421] !== tb_cart_crc
			    || image[8422] !== 32'd2 || image[8423] !== ~tb_cart_crc)
				$display("    !! identity tail wrong: %h %h %h %h",
				         image[8420], image[8421], image[8422], image[8423]);
			errs = 0;
			for (k = 0; k < CARTW; k = k + 1)
				if (image[CARTB+k] !== sav_gold[k]) errs = errs + 1;
			if (errs != 0) begin
				$display("    !! cart section in readout: %0d words wrong (e.g. [%0d]=%h want %h)",
				         errs, CARTB, image[CARTB], sav_gold[0]);
				errors = errors + 1;
			end
			machine_corrupt;
			apf_write_burst(lag, gap, stall_at, stall_len, foreign_first);
			apf_load(ok);
			if (ok) begin
				machine_check(errs);
				cart_check(cerrs);
				if (order_violation) begin
					$display("   FAIL: engine restored before the cart drain finished");
					errors = errors + 1;
				end else if (errs == 0 && cerrs == 0 && expect_ok)
					$display("   PASS (machine and cart image byte-exact, cart first)");
				else if (errs == 0 && cerrs == 0)
					$display("   UNEXPECTED PASS (expected failure)");
				else begin
					$display("   FAIL: load ok but machine %0d / cart %0d wrong", errs, cerrs);
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
		scenario("S3 lagged + 2ms mid-burst SD stall  ", 1,  8,  9211, 150000,  0,      0,     1);
		scenario("S4 clean bus (no lag)               ", 0,  8,  -1,     0,     0,      0,     1);
		scenario("S5 clean + read quirks              ", 0,  4,  -1,     0,     0,      1,     1);

		// S6: the state was taken on one cartridge, the load happens on another.
		// The check must reject BEFORE the engine or the copier touch anything.
		begin : s6
			integer ok, i, still;
			$display("== S6 cross-cartridge load rejected      ");
			machine_init;
			saw_load_req = 0;
			apf_save(0);
			machine_corrupt;
			apf_write_burst(1, 8, -1, 0, 0);
			tb_cart_crc = 32'hBAD0CA57;         // a different cartridge now
			apf_load(ok);
			tb_cart_crc = 32'hC0FFEE01;
			if (ok) begin
				$display("   FAIL: cross-cartridge load was accepted");
				errors = errors + 1;
			end else begin
				still = 1;
				for (i = 0; i < 64; i = i + 1)
					if (mem0[i] !== 8'hFF) still = 0;
				if (internals[0] !== 64'hDEADBEEF_DEADBEEF) still = 0;
				if (saw_load_req) begin
					$display("   FAIL: rejected but the cart copier was started");
					errors = errors + 1;
				end else if (still) $display("   PASS (rejected, machine untouched)");
				else begin
					$display("   FAIL: rejected but machine was modified");
					errors = errors + 1;
				end
			end
		end

		// S7: a state from the old layout (ID_LAYOUT=1, machine-only) must be
		// rejected cleanly -- no engine start, no cart handoff.
		begin : s7
			integer ok, i, still;
			$display("== S7 old-layout state rejected          ");
			machine_init;
			saw_load_req = 0;
			apf_save(0);
			image[8422] = 32'd1;                // forge the previous layout id
			machine_corrupt;
			apf_write_burst(1, 8, -1, 0, 0);
			apf_load(ok);
			if (ok) begin
				$display("   FAIL: old-layout state was accepted");
				errors = errors + 1;
			end else begin
				still = 1;
				for (i = 0; i < 64; i = i + 1)
					if (mem0[i] !== 8'hFF) still = 0;
				if (internals[0] !== 64'hDEADBEEF_DEADBEEF) still = 0;
				if (saw_load_req) begin
					$display("   FAIL: rejected but the cart copier was started");
					errors = errors + 1;
				end else if (still) $display("   PASS (rejected, machine untouched, copier idle)");
				else begin
					$display("   FAIL: rejected but machine was modified");
					errors = errors + 1;
				end
			end
		end

		if (errors == 0) $display("== ALL SCENARIOS MATCHED EXPECTATIONS");
		else             $display("== %0d SCENARIO(S) DEVIATED", errors);
		$finish;
	end

	// global watchdog
	initial begin
		#900_000_000;   // 900 ms of sim time -- seven scenarios on a 3x blob
		$display("== WATCHDOG TIMEOUT");
		$finish;
	end

endmodule

`default_nettype wire
