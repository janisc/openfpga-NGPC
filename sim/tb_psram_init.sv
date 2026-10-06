// 1.1.1: the PSRAM set-up in ngpc_stage_mem (with psram.sv's cfg/wake).
//
// A two-die CellularRAM model that knows the configuration registers: CRE
// high when ADV# latches selects a register access (A[19:18]: 00 RCR, 10
// BCR, 01 DIDR); a register WRITE loads the latched address bits [15:0] on
// the rising edge of WE# (or CE#); a register READ drives the register.
// Die 0 starts in synchronous mode with refresh off (RCR "refresh none");
// with -DDPD die 1 starts in deep power-down, which it leaves only after
// CE# has been LOW for 10 us, then answers nothing for 150 us.
//
// Checks: both dies end at BCR 9D1Fh / RCR 0010h; the report word says what
// was found and that it read back; CRE is held from ADV# through WE#; every
// die gets >= 10 us of CE# LOW before any access; no array access during
// the set-up; neither client is served before psram_ready_o; APF writes that
// arrive during the set-up wait in the skid and land intact; ordinary
// traffic works afterwards.
`timescale 1ns/1ps
module tb_psram_init;
	reg clk = 0;
	always #10.172 clk = ~clk;              // 49.152 MHz
	reg reset = 1;

	// ---- DUT ----------------------------------------------------------------
	reg         host_wr = 0;
	reg  [24:0] host_wr_addr = 0;
	reg  [15:0] host_wr_data = 0;
	reg         host_rd = 0;
	reg  [24:0] host_rd_addr = 0;
	wire [15:0] host_rd_data;
	reg         eng_req = 0, eng_we = 0;
	reg  [24:0] eng_addr = 0;
	reg  [15:0] eng_wdata = 0;
	wire        eng_ready, eng_done;
	wire [15:0] eng_rdata;
	wire        ps_ready;
	wire [31:0] ps_report;
	wire [15:0] beats, drops;
	wire [21:16] cram_a;
	wire [15:0]  cram_dq;
	wire cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n;
	wire cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;

	ngpc_stage_mem dut (
		.clk(clk), .reset(reset),
		.active_bank_i(1'b0), .host_wr_bank_i(1'b0),
		.host_wr_i(host_wr), .host_wr_addr_i(host_wr_addr), .host_wr_data_i(host_wr_data),
		.host_rd_i(host_rd), .host_rd_addr_i(host_rd_addr), .host_rd_data_o(host_rd_data),
		.host_wr_ready_o(), .host_busy_o(),
		.diag_beats_o(beats), .diag_drops_o(drops),
		.psram_ready_o(ps_ready), .psram_report_o(ps_report),
		.eng_req_i(eng_req), .eng_we_i(eng_we), .eng_addr_i(eng_addr), .eng_wdata_i(eng_wdata),
		.eng_ready_o(eng_ready), .eng_done_o(eng_done), .eng_rdata_o(eng_rdata),
		.cram_a(cram_a), .cram_dq(cram_dq), .cram_wait(1'b0), .cram_clk(cram_clk),
		.cram_adv_n(cram_adv_n), .cram_cre(cram_cre), .cram_ce0_n(cram_ce0_n),
		.cram_ce1_n(cram_ce1_n), .cram_oe_n(cram_oe_n), .cram_we_n(cram_we_n),
		.cram_ub_n(cram_ub_n), .cram_lb_n(cram_lb_n)
	);

	// ---- the model ------------------------------------------------------------
	reg [15:0] mem0 [0:65535];
	reg [15:0] mem1 [0:65535];
	reg [15:0] bcr [0:1];
	reg [15:0] rcr [0:1];
	reg        dpd [0:1];
	time       dpd_ready [0:1];
	reg [21:0] a_l [0:1];
	reg        cre_l [0:1];
	reg        latched [0:1];
	time       ce_fall [0:1];
	time       wake_max [0:1];
	reg        prev_ce [0:1];
	reg        prev_we = 1;
	integer    errors = 0, cre_hold_err = 0, early_access = 0, arr_wr_in_init = 0, arr_rd_in_init = 0;
	integer    dpd_ignored = 0, reg_writes = 0;
	reg  [15:0] dq_drive;
	reg         dq_en;
	assign cram_dq = dq_en ? dq_drive : 16'hzzzz;

	wire [1:0] ce_n = {cram_ce1_n, cram_ce0_n};
	integer d;

	initial begin
		bcr[0] = 16'h181F; rcr[0] = 16'h0014;      // synchronous, refresh none of the array
		bcr[1] = 16'h9D1F; rcr[1] = 16'h0010;
		dpd[0] = 0; dpd[1] = 0;
`ifdef DPD
		dpd[1] = 1; rcr[1] = 16'h0000;             // die 1 in deep power-down
`endif
		dpd_ready[0] = 0; dpd_ready[1] = 0;
		for (d = 0; d < 2; d = d + 1) begin
			latched[d] = 0; prev_ce[d] = 1; wake_max[d] = 0; ce_fall[d] = 0;
		end
		dq_en = 0; dq_drive = 0;
	end

	// Clock-sampled, like the other benches: psram.sv drives every pin from a
	// register, so at each edge the model sees the previous cycle's pins.
	reg        p_we = 1, p_oe = 1, p_adv = 1;
	reg  [1:0] p_ce = 2'b11;
	reg [15:0] p_dq = 0;
	time       t_now;
	wire in_init = !ps_ready;

	always @(posedge clk) begin
		t_now = $time;
		for (d = 0; d < 2; d = d + 1) begin
			// CE# LOW time without an access (the wake), and the DPD exit
			if (!ce_n[d] && p_ce[d]) ce_fall[d] = t_now;
			if (ce_n[d] && !p_ce[d]) begin
				if (!latched[d] && t_now - ce_fall[d] > wake_max[d]) wake_max[d] = t_now - ce_fall[d];
				if (dpd[d] && t_now - ce_fall[d] >= 10000) begin
					dpd[d] = 0;
					dpd_ready[d] = t_now + 150000;
				end
			end
			// ADV# LOW with the die selected latches the address and CRE
			if (!ce_n[d] && !cram_adv_n) begin
				if (dpd[d] || t_now < dpd_ready[d]) begin
					if (!p_adv || p_ce[d]) ; else ;
					dpd_ignored = dpd_ignored + (p_adv ? 1 : 0);
				end else begin
					if (!latched[d] && wake_max[d] < 10000) early_access = early_access + 1;
					a_l[d] = {cram_a, cram_dq};
					cre_l[d] = cram_cre;
					latched[d] = 1;
				end
			end
			// WRITE commits on the rising edge of WE# or CE#, whichever first
			if (latched[d] && !p_we && !p_ce[d] && (cram_we_n || ce_n[d])) begin
				if (cre_l[d]) begin
					if (!cram_cre) cre_hold_err = cre_hold_err + 1;
					reg_writes = reg_writes + 1;
					case (a_l[d][19:18])
						2'b00: rcr[d] = a_l[d][15:0];
						2'b10: bcr[d] = a_l[d][15:0];
						default: ;
					endcase
				end else begin
					if (in_init) arr_wr_in_init = arr_wr_in_init + 1;
					if (d == 0) mem0[a_l[d][15:0]] = p_dq; else mem1[a_l[d][15:0]] = p_dq;
				end
			end
			if (ce_n[d]) latched[d] = 0;
		end
		// READ: drive once OE# is LOW (sampled), until it rises
		dq_en = 0;
		for (d = 0; d < 2; d = d + 1)
			if (!ce_n[d] && latched[d] && !cram_oe_n && cram_we_n && cram_adv_n) begin
				dq_en = 1;
				if (cre_l[d])
					dq_drive = (a_l[d][19:18] == 2'b10) ? bcr[d] : (a_l[d][19:18] == 2'b00) ? rcr[d] : 16'h0002;
				else
					dq_drive = (d == 0) ? mem0[a_l[d][15:0]] : mem1[a_l[d][15:0]];
				if (in_init && !cre_l[d] && p_oe) arr_rd_in_init = arr_rd_in_init + 1;
			end
		p_we = cram_we_n; p_oe = cram_oe_n; p_adv = cram_adv_n; p_ce = ce_n; p_dq = cram_dq;
	end

	// ---- monitors -----------------------------------------------------------
	integer eng_ready_early = 0;
	always @(posedge clk) if (eng_ready && !ps_ready) eng_ready_early = eng_ready_early + 1;

	task automatic check(input cond, input [8*64-1:0] what);
		if (!cond) begin
			$display("FAIL %0s", what);
			errors = errors + 1;
		end else $display("ok   %0s", what);
	endtask

	// ---- stimulus -----------------------------------------------------------
	integer i;
	time t_ready;
	initial begin
		repeat (200) @(posedge clk);
		reset <= 0;
		// APF starts writing before the set-up is done: 40 words to bank 0
		repeat (2000) @(posedge clk);
		for (i = 0; i < 40; i = i + 1) begin
			@(posedge clk) begin host_wr <= 1; host_wr_addr <= 25'h100 + 2 * i; host_wr_data <= 16'hA500 + i; end
			@(posedge clk) host_wr <= 0;
			repeat (40) @(posedge clk);
		end
		wait (ps_ready);
		t_ready = $time;
		repeat (2000) @(posedge clk);

		$display("set-up done at %0t us", t_ready / 1000);
		$display("die 0: BCR %h RCR %h   die 1: BCR %h RCR %h   report %h", bcr[0], rcr[0], bcr[1], rcr[1], ps_report);
		check(bcr[0] == 16'h9D1F && rcr[0] == 16'h0010, "die 0 set to BCR 9D1F / RCR 0010");
		check(bcr[1] == 16'h9D1F && rcr[1] == 16'h0010, "die 1 set to BCR 9D1F / RCR 0010");
		check(wake_max[0] >= 10000 && wake_max[1] >= 10000, "each die had >= 10 us of CE# LOW first");
		check(early_access == 0, "no access before a die's wake");
		check(cre_hold_err == 0, "CRE held from ADV# through WE#");
		check(reg_writes == 4, "exactly four register writes");
		check(arr_wr_in_init == 0, "no array write during the set-up");
		check(eng_ready_early == 0, "the engine was not served before psram_ready");
		check(ps_report[0] && ps_report[1] && ps_report[2] && ps_report[3], "report: present, done, both dies read back");
`ifdef DPD
		check(ps_report[31:16] == 16'h181F && ps_report[15:8] == 8'h14, "report: die 0 as found (181F / 14)");
		check(ps_report[6:4] == 3'b000, "report: die 1 refresh as found (DPD die read as RCR 0000)");
		check(dpd_ignored == 0, "no access reached a die still in deep power-down");
`else
		check(ps_report[31:16] == 16'h181F && ps_report[15:8] == 8'h14 &&
		      ps_report[7] == 1'b1 && ps_report[6:4] == 3'b000, "report: die 0 181F/14, die 1 async, full refresh");
`endif
		check(t_ready < 400_000, "set-up within 0.4 ms of reset release");

		// The APF words that arrived during the set-up
		begin : apf_check
			integer bad; bad = 0;
			for (i = 0; i < 40; i = i + 1) if (mem0[16'h80 + i] !== 16'hA500 + i) bad = bad + 1;
			check(bad == 0 && drops == 0, "APF writes during the set-up landed intact, none dropped");
		end

		// Ordinary engine traffic afterwards
		begin : eng_check
			integer bad; bad = 0;
			for (i = 0; i < 16; i = i + 1) begin
				wait (eng_ready); @(posedge clk);
				eng_req <= 1; eng_we <= 1; eng_addr <= 25'h1000 + 2 * i; eng_wdata <= 16'h5A00 + i;
				@(posedge clk) eng_req <= 0;
				wait (eng_done); @(posedge clk);
			end
			for (i = 0; i < 16; i = i + 1) begin
				wait (eng_ready); @(posedge clk);
				eng_req <= 1; eng_we <= 0; eng_addr <= 25'h1000 + 2 * i;
				@(posedge clk) eng_req <= 0;
				wait (eng_done); #1;
				if (eng_rdata !== 16'h5A00 + i) bad = bad + 1;
				@(posedge clk);
			end
			check(bad == 0, "engine write/read back after the set-up");
		end

		if (errors == 0) $display("== PSRAM SET-UP: ALL PASS"); else $display("== PSRAM SET-UP: %0d FAIL", errors);
		$finish;
	end

	initial begin #5_000_000; $display("== PSRAM SET-UP: TIMEOUT"); $finish; end
endmodule
