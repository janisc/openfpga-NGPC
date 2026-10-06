// RC6A: the rc6 follow-up's program/erase classifier against the REAL die.
//
// ngpc_cart_save tells a program from an erase by the length of the die's
// busy window (busy_cnt0/1, saturating at 4095; prog_event = an event whose
// window did not saturate), and R1 refuses a no-image load once a PROGRAM
// has landed since the last publish (prog_since_publish). That rests on
// flash_die's timing alone -- its program read-modify-write and its paced
// erase -- so this bench drives the REAL upstream/rtl/cart/flash_die.sv (a
// 4 Mbit die, 0xAB, default ERASE_WORD_PERIOD) through its pins with AMD
// command sequences, behind a backing store of configurable latency, into
// the REAL target/pocket/ngpc_cart_save.sv (or a sim/tb_rc6a_mut_*.sv
// mutant), and reads the engine's own prog_event at every completion event.
// The engine runs no pass here (cart_ready low): only the classifier and
// prog_since_publish are under test, the latter cleared by an engine reset
// between scenarios.
//
//   PROG-L3     byte program, store latency 3 clk            -> program
//   PROG-L8     byte program, store latency 8 clk            -> program
//   PROG-L64    byte program, store latency 64 clk (stress)  -> program
//   ERASE-8K    erase of block 8 (8 KB, the smallest block)  -> erase
//   ERASE-16K   erase of block 10 (16 KB, the BIOS's block)  -> erase
//   PROG-CUT    an erase cut by a die reset (no event, the count left
//               saturated), then a program                   -> program
//   PROG-AFTER  a program straight after an erase completed  -> program
//
// Each scenario also bounds the window it measured, so a change to
// flash_die's timing that eats into the classifier's margin shows here
// before it flips a verdict: a program must be busy < 1024 clocks, an
// erase > 16,380 (four times the threshold).
//
// Run: sim/run_rc6_r1.sh (bench). Last line "== ALL RC6A CLASSIFY SCENARIOS
// PASS" or "== N FAILURE(S): ...", and a failure exits 1 under vvp -N.
`timescale 1ns / 1ps
`default_nettype none

module tb_rc6a_classify;

	reg clk = 0;
	always #10.173 clk = ~clk;

	reg die_reset = 1, eng_reset = 1;

	// ---- the die's pins ---------------------------------------------------------
	reg  [20:0] A = 0;
	reg   [7:0] DQ = 8'hFF;
	reg         nCE = 1, nOE = 1, nWE = 1;

	wire        mem_req, mem_we, mem_lane, mem_tag;
	wire [20:0] mem_addr;
	wire [15:0] mem_wdata;
	wire  [1:0] mem_be;
	reg  [15:0] mem_rdata = 16'hFFFF;
	reg         mem_rvalid = 0, mem_done = 0;
	wire        die_busy, dirty_pulse;
	wire  [5:0] dirty_block;

	flash_die die0 (
		.clk(clk), .ce(1'b1), .reset(die_reset), .force_read_i(1'b0),
		.present(1'b1), .cfg_device_id(8'hAB), .cfg_size_mask(21'h07FFFF),
		.A(A), .DQ_in(DQ), .DQ_out(), .DQ_oe(), .rd_ready(),
		.nCE(nCE), .nOE(nOE), .nWE(nWE),
		.mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
		.mem_be(mem_be), .mem_lane(mem_lane), .mem_tag(mem_tag),
		.mem_rdata(mem_rdata), .mem_rvalid(mem_rvalid), .mem_done(mem_done),
		.busy(die_busy), .dirty_pulse(dirty_pulse), .dirty_block(dirty_block),
		.ss_bus_adr(10'd0), .ss_bus_din(64'd0), .ss_bus_wren(1'b0), .ss_bus_rst(1'b0),
		.ss_bus_dout(), .ss_restore_is_rewind(1'b0), .pause_req(1'b0), .pause_ready()
	);

	// ---- backing store: held-request mailbox, LAT clocks per transaction ----------
	reg [15:0] sto [0:262143];
	integer    LAT = 3;
	reg        st_busy = 0, last_tag = 0;
	integer    st_cnt = 0;
	always @(posedge clk) begin
		mem_done   <= 1'b0;
		mem_rvalid <= 1'b0;
		if (!st_busy) begin
			if (mem_req && mem_tag != last_tag) begin
				st_busy <= 1'b1; st_cnt <= LAT;
			end
		end else if (st_cnt > 1) begin
			st_cnt <= st_cnt - 1;
		end else begin
			st_busy  <= 1'b0;
			last_tag <= mem_tag;
			mem_done <= 1'b1;
			if (!mem_we) begin
				mem_rdata  <= sto[mem_addr[20:1]];
				mem_rvalid <= 1'b1;
			end else begin
				if (mem_be[0]) sto[mem_addr[20:1]][7:0]  <= mem_wdata[7:0];
				if (mem_be[1]) sto[mem_addr[20:1]][15:8] <= mem_wdata[15:8];
			end
		end
		if (die_reset) begin st_busy <= 1'b0; last_tag <= 1'b0; end
	end

	// ---- the engine: only its classifier is exercised -------------------------------
	ngpc_cart_save #(.QUIET_CLOCKS(20'd25000)) u_save (
		.psram_report_i (32'h9D1F108F),   // 1.1.1
		.clk(clk), .reset(eng_reset),
		.cart_ready_i(1'b0), .cart_replace_i(1'b0),
		.cart_crc32_i(32'h21E8CC15), .cart_bytes_i(25'h0080000),
		.cart_title_i(96'h2020202020204E414D434150), .cart_catalog_i(16'h0001),
		.cart_subcat_i(8'h80), .size_code0_i(2'd1), .size_code1_i(2'd0),
		.event0_i(dirty_pulse), .block0_i(dirty_block), .event1_i(1'b0), .block1_i(6'd0),
		.die_busy_i({1'b0, die_busy}),
		.host_busy_i(1'b0), .host_rd_i(1'b0),
		.state_apply_i(1'b0), .draining_i(1'b0),
		.state_frozen_i(1'b0), .state_fail_i(1'b0), .frozen_o(),
		.save_slot_wr_i(1'b0), .apply_reject_o(), .state_done_o(),
		.slots_settled_i(1'b0),
		.diag_beats_i(16'd0), .diag_drops_i(16'd0), .diag_drain_i(16'd0),
		.boot_hold_o(), .busy_o(), .save_present_o(), .stage_current_o(), .stage_bank_o(),
		.p2_req_o(), .p2_we_o(), .p2_addr_o(), .p2_wdata_o(), .p2_be_o(),
		.p2_ready_i(1'b1), .p2_done_i(1'b0), .p2_rdata_i(16'd0),
		.stage_req_o(), .stage_we_o(), .stage_addr_o(), .stage_wdata_o(),
		.stage_ready_i(1'b1), .stage_done_i(1'b0), .stage_rdata_i(16'd0)
	);

	// ---- monitor: every completion event, its window and its verdict ---------------
	integer t = 0, t_rise = -1, win = -1, n_ev = 0;
	reg     ev_prog = 0;
	reg [5:0] ev_blk = 0;
	reg     busy_q = 0;
	always @(posedge clk) begin
		t = t + 1;
		if (die_busy && !busy_q) t_rise = t;
		if (dirty_pulse) begin
			n_ev    = n_ev + 1;
			ev_prog = (u_save.prog_event === 1'b1);
			ev_blk  = dirty_block;
			win     = (t_rise >= 0) ? (t - t_rise) : -1;
		end
		busy_q = die_busy;
	end

	// ---- bookkeeping --------------------------------------------------------------
	integer errors = 0, n_scn = 0, n_scn_fail = 0, e0 = 0;
	string  scn = "setup", fail_list = "";
	task fail(input string msg);
		begin errors = errors + 1; $display("   FAIL [%0s] %0s", scn, msg); end
	endtask
	task begin_scn(input string id, input string what);
		begin scn = id; e0 = errors; $display("== %0s  %0s", id, what); end
	endtask
	task end_scn;
		begin
			n_scn = n_scn + 1;
			if (errors == e0) $display("   PASS %0s", scn);
			else begin
				n_scn_fail = n_scn_fail + 1;
				fail_list = $sformatf("%0s %0s", fail_list, scn);
				$display("   FAIL %0s (%0d check(s))", scn, errors - e0);
			end
			$fflush;
		end
	endtask

	// ---- the CPU's side: AMD write cycles on the pins --------------------------------
	task wr(input [20:0] a, input [7:0] d);
		begin
			@(posedge clk); A <= a; DQ <= d; nCE <= 1'b0; nWE <= 1'b0;
			repeat (8) @(posedge clk);
			nWE <= 1'b1;
			@(posedge clk); nCE <= 1'b1;
			repeat (8) @(posedge clk);
		end
	endtask
	task cmd_program(input [20:0] a, input [7:0] d);
		begin wr(21'h05555, 8'hAA); wr(21'h02AAA, 8'h55); wr(21'h05555, 8'hA0); wr(a, d); end
	endtask
	task cmd_erase(input [20:0] a);
		begin
			wr(21'h05555, 8'hAA); wr(21'h02AAA, 8'h55); wr(21'h05555, 8'h80);
			wr(21'h05555, 8'hAA); wr(21'h02AAA, 8'h55); wr(a, 8'h30);
		end
	endtask

	// fresh engine session: prog_since_publish cleared (the busy counters are
	// not reset-scoped, as in the core)
	task eng_session;
		begin
			@(posedge clk); eng_reset <= 1'b1;
			repeat (4) @(posedge clk); eng_reset <= 1'b0;
			repeat (4) @(posedge clk);
			if (u_save.prog_since_publish !== 1'b0) fail("(setup) prog_since_publish not cleared by the engine reset");
		end
	endtask

	integer n0;
	task wait_event(input integer max);
		integer n;
		begin
			n = 0;
			while (n_ev == n0 && n < max) begin @(posedge clk); n = n + 1; end
			repeat (4) @(posedge clk);
			if (n_ev == n0) fail("no completion event");
			else if (n_ev != n0 + 1) fail($sformatf("%0d completion events, want 1", n_ev - n0));
		end
	endtask

	task expect_program(input [5:0] blk, input [20:0] a, input [7:0] d);
		reg [15:0] w;
		begin
			$display("   event: block %0d, busy window %0d clk, prog_event %b, prog_since_publish %b",
			         ev_blk, win, ev_prog, u_save.prog_since_publish);
			if (ev_blk !== blk) fail($sformatf("event for block %0d, want %0d", ev_blk, blk));
			if (!ev_prog) fail("the PROGRAM was classified as an erase (prog_event low)");
			if (u_save.prog_since_publish !== 1'b1) fail("prog_since_publish not set by the program");
			if (win < 0 || win >= 1024) fail($sformatf("program busy window %0d clk, want < 1024 (classifier margin)", win));
			w = sto[a[20:1]];
			if ((a[0] ? w[15:8] : w[7:0]) !== d) fail("the byte was not programmed");
		end
	endtask

	task expect_erase(input [5:0] blk, input [20:0] base, input integer words);
		integer k, nb;
		begin
			$display("   event: block %0d, busy window %0d clk, prog_event %b, prog_since_publish %b",
			         ev_blk, win, ev_prog, u_save.prog_since_publish);
			if (ev_blk !== blk) fail($sformatf("event for block %0d, want %0d", ev_blk, blk));
			if (ev_prog) fail("the ERASE was classified as a program (prog_event high)");
			if (u_save.prog_since_publish !== 1'b0) fail("prog_since_publish set by an erase");
			if (win <= 16380) fail($sformatf("erase busy window %0d clk, want > 16380 (classifier margin)", win));
			nb = 0;
			for (k = 0; k < words; k = k + 1) if (sto[base[20:1] + k] !== 16'hFFFF) nb = nb + 1;
			if (nb != 0) fail($sformatf("%0d words not erased", nb));
		end
	endtask

	integer i;
	initial begin
		for (i = 0; i < 262144; i = i + 1) sto[i] = i[15:0] ^ 16'hBEEF;
		repeat (8) @(posedge clk);
		die_reset <= 1'b0; eng_reset <= 1'b0;
		repeat (8) @(posedge clk);

		begin_scn("PROG-L3", "byte program into block 10, store latency 3 clk");
		LAT = 3; eng_session; n0 = n_ev;
		cmd_program(21'h7C123, 8'h00); wait_event(100000);
		expect_program(6'd10, 21'h7C123, 8'h00);
		end_scn;

		begin_scn("PROG-L8", "byte program into block 8, store latency 8 clk");
		LAT = 8; eng_session; n0 = n_ev;
		cmd_program(21'h78010, 8'h00); wait_event(100000);
		expect_program(6'd8, 21'h78010, 8'h00);
		end_scn;

		begin_scn("PROG-L64", "byte program into block 9, store latency 64 clk (stress)");
		LAT = 64; eng_session; n0 = n_ev;
		cmd_program(21'h7A201, 8'h00); wait_event(100000);
		expect_program(6'd9, 21'h7A201, 8'h00);
		end_scn;

		begin_scn("ERASE-8K", "erase of block 8 (8 KB, the smallest block), store latency 3 clk");
		LAT = 3; eng_session; n0 = n_ev;
		cmd_erase(21'h78000); wait_event(2000000);
		expect_erase(6'd8, 21'h78000, 4096);
		end_scn;

		begin_scn("ERASE-16K", "erase of block 10 (16 KB, the BIOS's power-up block), store latency 8 clk");
		LAT = 8; eng_session; n0 = n_ev;
		cmd_erase(21'h7C000); wait_event(2000000);
		expect_erase(6'd10, 21'h7C000, 8192);
		end_scn;

		begin_scn("PROG-CUT", "an erase cut by a die reset (no event, count saturated), then a program");
		LAT = 3; eng_session; n0 = n_ev;
		cmd_erase(21'h7A000);
		repeat (10000) @(posedge clk);
		if (die_busy !== 1'b1 || u_save.busy_cnt0 !== 12'hFFF)
			fail($sformatf("(setup) the erase was not in flight with the count saturated (busy %b count %0d)",
			               die_busy, u_save.busy_cnt0));
		@(posedge clk); die_reset <= 1'b1;
		repeat (4) @(posedge clk); die_reset <= 1'b0;
		repeat (16) @(posedge clk);
		if (n_ev != n0) fail("(setup) the cut erase reported an event");
		cmd_program(21'h7A311, 8'h00); wait_event(100000);
		expect_program(6'd9, 21'h7A311, 8'h00);
		end_scn;

		begin_scn("PROG-AFTER", "a program straight after an erase completed");
		LAT = 3; eng_session; n0 = n_ev;
		cmd_erase(21'h78000); wait_event(2000000);
		expect_erase(6'd8, 21'h78000, 4096);
		n0 = n_ev;
		cmd_program(21'h78002, 8'h5A); wait_event(100000);
		expect_program(6'd8, 21'h78002, 8'h5A);
		end_scn;

		$display("== %0d scenario(s) run, %0d failed, %0d check(s) failed", n_scn, n_scn_fail, errors);
		if (errors == 0) begin
			$display("== ALL RC6A CLASSIFY SCENARIOS PASS");
			$finish;
		end else begin
			if (n_scn_fail == 0) fail_list = " setup";
			$display("== %0d FAILURE(S):%0s", (n_scn_fail > 0) ? n_scn_fail : errors, fail_list);
			$stop;
		end
	end

	initial begin
		#(200_000_000.0);
		$display("== 1 FAILURE(S): WATCHDOG in %0s", scn);
		$stop;
	end

endmodule

`default_nettype wire
