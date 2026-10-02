// tb_rc6b_rdwr -- rc6 L1 on the real ngpc_stage_mem: APF flush reads
// interleaved with queued host writes (adapted from sim/tb_r6b_bench.sv).
//   Run through sim/run_rc6_hostport.sh (builds, mutants, matrix).
//   One scenario per run: +SCN=1..4 [+RDGAP=n] [+ENG=0/1] [+SEED=n].
//   Last line: "== ALL RC6B-RDWR SCENARIOS PASS" or "== N FAILURE(S) ...".
//   Run it with "vvp -N": a failing run then exits with status 1 ($stop), a
//   passing one with 0 ($finish).
//
// REAL, compiled unmodified from the worktree:
//   target/pocket/ngpc_stage_mem.sv    (rc6: L1 pending-slot claim, L3 part B)
//   target/pocket/data_loader.sv       APF delivery (+ sim/sim_dcfifo.v)
//   target/pocket/data_unloader.sv     APF flush, core_top.v:608-624 params
//                                      (READ_MEM_CLOCK_DELAY 32)
//   target/pocket/ngpc_state_cart.sv   the copier (the savestate drain)
//   target/pocket/psram.sv
//   the rc6 write-port arbiter         core_top.v "apf_save_wr .. sc_host_ready",
//                                      extracted verbatim into sim/tb_rc6b_arb.vh
//                                      by the run script and `included
//   the engine-port mux                core_top.v:678-686 (sc_rd_active ? ...)
// MODELED: the CellularRAM chip at the pins (reads and writes), the blob's
// cart section, the APF bridge (one master: reads and writes never overlap on
// it), an engine using the eng_* port as ngpc_cart_save does (samples
// eng_ready_o, one-cycle request the next clock, waits for eng_done_o), and in
// scenario 3 a raw writer on the COPIER's side of the arbiter that honours
// sc_host_ready and holds its address/data as the copier does.
//
// SCENARIOS (+SCN=n)
//   1  DRAINFLUSH  the copier drains a state into the spare bank while APF
//                  flushes the committed bank from the drain's first beat
//   2  BURSTREAD   fast APF delivery burst into the committed bank (faster
//                  than the PSRAM: the skid grows), then APF reads right
//                  behind it, overlapping the skid's tail
//   3  RANDOM      raw writer into the spare bank + random APF reads + a
//                  back-to-back engine; hunts the worst read latency
//   4  INTERLEAVE  the drain, and on the one bridge a random mix of delivery
//                  writes (some in gap-4 bursts) and flush reads, plus the
//                  engine: APF beats collide with drain beats in the arbiter
//                  while read windows open over queued writes of both
// Reads always target committed words no writer touches in the run (a read
// racing a write to the SAME word is outside this contract: the loader's own
// FIFO never ordered those either).
//
// CHECKS
//   C1 no write lost: at the end the chip holds, word for word, what the
//      writers issued -- taken at the writers (loader output, the copier or
//      raw writer, the engine), upstream of the arbiter and the skid
//   C2 every unloader sample (data_read_state == READ_MEM_COMPLETE) equals
//      the committed bank's word at that moment
//   C3 every read window is served, exactly once, and its PSRAM data is back
//      <= 30 clk after read_en rose (inside data_unloader's 32-clock window)
//   C4 every engine request completes; engine reads return the right word
//   C5 diag honest: diag_drops == beats that met a full skid (and none did),
//      diag_beats == APF beats + copier/raw beats, and the chip saw exactly
//      diag_beats - diag_drops host writes (+ the engine's): a beat lost after
//      the skid -- the rc5 L1 loss -- is a loss the counters never showed.
//      The counters need NGPC_SAVE_DIAG (the release build defines it);
//      without it C5 checks the chip saw every beat offered, once.
//   C6 coverage: a read window opened over a popped write waiting in the
//      pending slot (the rc5 L1 loss condition) at least once; scenario 4
//      also saw arbiter collisions; nothing timed out

`timescale 1ns / 1ps
`default_nettype none

module tb_rc6b_rdwr;

	reg clk_sys = 0;
	reg clk_74a = 0;
	always #10.173 clk_sys = ~clk_sys;   // 49.152 MHz
	always #6.734  clk_74a = ~clk_74a;   // 74.25 MHz

	reg reset_in = 1;
	reg mc_stage_bank = 1'b0;            // the committed bank

	integer SCEN = 1, RD_GAP = 140, ENG = 1, SEED = 1;

	// ---------------- APF bridge ------------------------------------------
	reg         bridge_wr = 0;
	reg         bridge_rd = 0;
	reg  [31:0] bridge_addr = 32'hF8000000;
	reg  [31:0] bridge_wr_data = 0;

	wire        bios_wr_raw;
	wire [27:0] bios_addr_raw;
	wire [15:0] bios_data_raw;

	data_loader #(
		.ADDRESS_MASK_UPPER_4(4'h1),
		.OUTPUT_WORD_SIZE(2)
	) bios_loader (
		.clk_74a(clk_74a), .clk_memory(clk_sys),
		.bridge_wr(bridge_wr), .bridge_endian_little(1'b0),
		.bridge_addr(bridge_addr), .bridge_wr_data(bridge_wr_data),
		.write_en(bios_wr_raw), .write_addr(bios_addr_raw), .write_data(bios_data_raw)
	);
	wire ld_is_save = bios_addr_raw[25];            // core_top.v:804

	wire        stage_host_rd;
	wire [27:0] stage_host_rd_addr;
	wire [15:0] stage_host_rd_data;
	wire [31:0] stage_bridge_rd_data;

	data_unloader #(
		.ADDRESS_MASK_UPPER_4(4'h1),
		.INPUT_WORD_SIZE(2),
		.READ_MEM_CLOCK_DELAY(32)
	) stage_drain (
		.clk_74a(clk_74a), .clk_memory(clk_sys),
		.bridge_rd(bridge_rd), .bridge_endian_little(1'b0),
		.bridge_addr(bridge_addr), .bridge_rd_data(stage_bridge_rd_data),
		.read_en(stage_host_rd), .read_addr(stage_host_rd_addr), .read_data(stage_host_rd_data)
	);

	// ---------------- copier ----------------------------------------------
	wire        sc_rd_req, sc_rd_active, sc_draining;
	wire [24:0] sc_rd_addr;
	wire        cp_host_wr;
	wire [24:0] cp_host_addr;
	wire [15:0] cp_host_data;
	wire        mc_state_apply;
	reg         mc_state_done = 0;
	wire [15:0] sc_diag_drain;
	wire        mc_capture_hold;
	wire        stage_ready, stage_done;
	wire [15:0] stage_rdata;
	wire        sc_host_ready;

	reg         cs_load_req = 0;
	wire        cs_save_done, cs_load_done, cs_load_error, cs_img_wr;
	wire [13:0] cs_img_addr, cs_img_rd_addr;
	wire [31:0] cs_img_data, cs_img_rd_data;
	reg  [31:0] blob_img [0:16383];
	reg  [13:0] b_ra = 0;
	reg  [31:0] b_rd = 0;
	always @(posedge clk_sys) begin
		b_ra <= cs_img_rd_addr;
		b_rd <= blob_img[b_ra];
	end
	assign cs_img_rd_data = b_rd;

	ngpc_state_cart state_cart (
		.clk(clk_sys), .reset(reset_in),
		.cart_save_req(1'b0), .cart_save_done(cs_save_done),
		.cart_img_wr(cs_img_wr), .cart_img_addr(cs_img_addr), .cart_img_data(cs_img_data),
		.cart_load_req(cs_load_req), .cart_load_done(cs_load_done), .cart_load_error(cs_load_error),
		.cart_img_rd_addr(cs_img_rd_addr), .cart_img_rd_data(cs_img_rd_data),
		.sc_rd_req(sc_rd_req), .sc_rd_addr(sc_rd_addr), .sc_rd_ready(stage_ready),
		.sc_rd_done(stage_done), .sc_rd_data(stage_rdata), .sc_rd_active(sc_rd_active),
		.draining_o(sc_draining),
		.sc_host_wr(cp_host_wr), .sc_host_ready(sc_host_ready),
		.sc_host_addr(cp_host_addr), .sc_host_data(cp_host_data),
		.stage_current_i(1'b1), .apply_reject_i(1'b0),
		.state_apply_o(mc_state_apply), .state_done_i(mc_state_done),
		.diag_drain_o(sc_diag_drain), .hold_o(mc_capture_hold)
	);
	// the apply: done a few clocks after it is requested
	integer ap_n = 0;
	always @(posedge clk_sys) begin
		mc_state_done <= 1'b0;
		if (mc_state_apply) ap_n = 20;
		else if (ap_n > 0) begin
			ap_n = ap_n - 1;
			if (ap_n == 0) mc_state_done <= 1'b1;
		end
	end

	// ---------------- raw writer (scenario 3), copier side ------------------
	reg         rw_mode = 0;
	reg         rw_wr = 0;
	reg  [24:0] rw_addr = 0;
	reg  [15:0] rw_data = 0;

	wire        sc_host_wr   = cp_host_wr || rw_wr;
	wire [24:0] sc_host_addr = rw_mode ? rw_addr : cp_host_addr;
	wire [15:0] sc_host_data = rw_mode ? rw_data : cp_host_data;

	// ---------------- the rc6 write-port arbiter (verbatim, or a mutant) ----
	wire        stage_host_wr;
	wire [27:0] stage_host_wr_addr;
	wire [15:0] stage_host_wr_data;
	wire        stage_wr_bank;
	wire        stage_host_ready;
	`include "tb_rc6b_arb.vh"

	// ---------------- engine port -----------------------------------------
	reg         eng_req = 0, eng_we = 0;
	reg  [24:0] eng_addr = 0;
	reg  [15:0] eng_wdata = 0;

	wire [21:16] cram_a;
	wire [15:0]  cram_dq;
	wire cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n;
	wire cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;
	wire        host_busy;
	wire [15:0] diag_beats, diag_drops;

	ngpc_stage_mem dut (
		.clk(clk_sys), .reset(reset_in),
		.active_bank_i(mc_stage_bank), .host_wr_bank_i(stage_wr_bank),
		.host_wr_i(stage_host_wr), .host_wr_addr_i(stage_host_wr_addr[24:0]),
		.host_wr_data_i(stage_host_wr_data),
		.host_rd_i(stage_host_rd), .host_rd_addr_i(stage_host_rd_addr[24:0]),
		.host_rd_data_o(stage_host_rd_data),
		.host_wr_ready_o(stage_host_ready), .host_busy_o(host_busy),
		.diag_beats_o(diag_beats), .diag_drops_o(diag_drops),
		// core_top.v:678-686
		.eng_req_i(sc_rd_active ? sc_rd_req : eng_req),
		.eng_we_i(sc_rd_active ? 1'b0 : eng_we),
		.eng_addr_i(sc_rd_active ? (sc_rd_addr | {8'd0, mc_stage_bank, 16'd0}) : eng_addr),
		.eng_wdata_i(eng_wdata),
		.eng_ready_o(stage_ready), .eng_done_o(stage_done), .eng_rdata_o(stage_rdata),
		.cram_a(cram_a), .cram_dq(cram_dq), .cram_wait(1'b0), .cram_clk(cram_clk),
		.cram_adv_n(cram_adv_n), .cram_cre(cram_cre), .cram_ce0_n(cram_ce0_n),
		.cram_ce1_n(cram_ce1_n), .cram_oe_n(cram_oe_n), .cram_we_n(cram_we_n),
		.cram_ub_n(cram_ub_n), .cram_lb_n(cram_lb_n)
	);

	// ---------------- CellularRAM chip (as tb_r6b_bench) --------------------
	reg [15:0] cmem [0:131071];
	integer    chip_wr = 0;             // write strobes at the chip
	reg [21:0] c_addr_l = 0;
	reg        p_we = 1, p_ce = 1, p_ub = 1, p_lb = 1;
	reg [15:0] p_dq = 0;
	reg [21:0] p_addr = 0;
	always @(posedge clk_sys) begin
		p_we <= cram_we_n; p_ce <= cram_ce0_n;
		p_ub <= cram_ub_n; p_lb <= cram_lb_n;
		p_dq <= cram_dq;   p_addr <= c_addr_l;
		if (!cram_ce0_n && !cram_adv_n) c_addr_l <= {cram_a, cram_dq};
		if (cram_we_n && !p_we && !p_ce) begin
			if (!p_ub) cmem[p_addr[16:0]][15:8] <= p_dq[15:8];
			if (!p_lb) cmem[p_addr[16:0]][7:0]  <= p_dq[7:0];
			chip_wr = chip_wr + 1;
		end
	end
	assign cram_dq = (!cram_oe_n && !cram_ce0_n) ? cmem[c_addr_l[16:0]] : 16'hzzzz;

	// ---------------- scoreboard ------------------------------------------
	reg [15:0] expw [0:131071];     // what the chip must hold, from the writers
	integer n_apf = 0, n_sc = 0, n_skidfull = 0, n_collide = 0, eng_wr_n = 0;
	integer eng_issued = 0, eng_done_n = 0, eng_bad = 0;
	integer smp_n = 0, smp_bad = 0, win_n = 0, win_unserved = 0;
	integer lat = 0, lat_max = 0, rd_extra = 0, skid_max = 0, cov_l1 = 0;
	integer lat_hist [0:40];
	reg     lat_wait = 0, rd_q = 0, got_one = 0, load_err_seen = 0;
	reg [15:0] eng_exp = 0;
	integer i, k;

	always @(posedge clk_sys) if (!reset_in) begin
		if (dut.skid_fill > skid_max) skid_max = dut.skid_fill;
		// C1 expectations, at the writers
		if (bios_wr_raw && ld_is_save) begin
			n_apf = n_apf + 1;
			if (bios_addr_raw[24:16] == 9'd0)
				expw[{mc_stage_bank, bios_addr_raw[15:1]}] = bios_data_raw;
		end
		if (sc_host_wr) begin
			n_sc = n_sc + 1;
			if (sc_host_addr[24:16] == 9'd0)
				expw[{~mc_stage_bank, sc_host_addr[15:1]}] = sc_host_data;
		end
		if (sc_beat && apf_save_wr) n_collide = n_collide + 1;
		if (cs_load_done && cs_load_error) load_err_seen = 1;
		if (dut.host_wr_i && dut.skid_full) n_skidfull = n_skidfull + 1;
		// C6: a read window open over a popped write still in the slot
		if (dut.host_rd_i && dut.host_pending && !dut.host_pending_rd) cov_l1 = cov_l1 + 1;
		// C2: the unloader's sample (data_read_state == READ_MEM_COMPLETE)
		if (stage_drain.data_read_state == 6'd34) begin
			smp_n = smp_n + 1;
			if (stage_host_rd_data !== expw[{mc_stage_bank, stage_host_rd_addr[15:1]}]) begin
				smp_bad = smp_bad + 1;
				if (smp_bad <= 5)
					$display("%12t   STALE flush sample: word %0d got %04h want %04h",
					         $time, stage_host_rd_addr[15:1], stage_host_rd_data,
					         expw[{mc_stage_bank, stage_host_rd_addr[15:1]}]);
			end
		end
		// C3: latency of this window's host read
		if (stage_host_rd && !rd_q) begin
			win_n = win_n + 1; lat_wait = 1; lat = 0; got_one = 0;
		end else if (lat_wait) lat = lat + 1;
		if (dut.ps_read_avail && !(dut.eng_active && dut.eng_active_rd)) begin
			if (lat_wait) begin
				lat_wait = 0; got_one = 1;
				if (lat > lat_max) lat_max = lat;
				lat_hist[lat > 40 ? 40 : lat] = lat_hist[lat > 40 ? 40 : lat] + 1;
			end else if (got_one && stage_host_rd) rd_extra = rd_extra + 1;
		end
		if (!stage_host_rd && rd_q && lat_wait) begin
			win_unserved = win_unserved + 1; lat_wait = 0;
		end
		rd_q = stage_host_rd;
	end

	// ---------------- engine (ngpc_cart_save's use of the port) -----------
	// Region: committed bank words 32600..32767 -- past the slot's 32512
	// words, so neither the flush, the delivery nor the drain touches it.
	reg        eng_run = 0;
	reg  [1:0] e_st = 0;
	reg  [7:0] e_gap = 0;
	reg [14:0] e_w;
	reg [14:0] r_w;
	always @(posedge clk_sys) begin
		eng_req <= 1'b0;
		if (reset_in) e_st <= 0;
		else case (e_st)
			0: if (e_gap != 0) e_gap <= e_gap - 8'd1;
			   else if (eng_run && stage_ready) begin
				eng_req   <= 1'b1;
				eng_we    <= $random(SEED) & 1;
				e_w        = 15'd32600 + ($unsigned($random(SEED)) % 168);
				eng_addr  <= {8'd0, mc_stage_bank, e_w, 1'b0};
				eng_wdata <= $random(SEED);
				e_st      <= 1;
			end
			1: begin   // the request is on the port this cycle
				eng_issued = eng_issued + 1;
				if (eng_we) eng_wr_n = eng_wr_n + 1;
				if (eng_we) expw[eng_addr[17:1]] = eng_wdata;
				else        eng_exp = expw[eng_addr[17:1]];
				e_st <= 2;
			end
			2: if (stage_done) begin
				eng_done_n = eng_done_n + 1;
				if (!eng_we && stage_rdata !== eng_exp) eng_bad = eng_bad + 1;
				e_gap <= (SCEN == 3) ? ($unsigned($random(SEED)) % 3) : 8'd4;
				e_st  <= 0;
			end
		endcase
	end

	// ---------------- APF helpers -----------------------------------------
	task apf_read(input [31:0] a, input integer gap);
		begin
			@(posedge clk_74a);
			bridge_addr <= a;
			bridge_rd   <= 1'b1;
			@(posedge clk_74a);
			bridge_rd   <= 1'b0;
			repeat (gap) @(posedge clk_74a);
		end
	endtask

	task apf_write(input [31:0] a, input [31:0] d, input integer gap);
		begin
			@(posedge clk_74a);
			bridge_addr    <= a;
			bridge_wr_data <= d;
			bridge_wr      <= 1'b1;
			@(posedge clk_74a);
			bridge_wr      <= 1'b0;
			repeat (gap) @(posedge clk_74a);
		end
	endtask

	integer timeouts = 0;
	task quiesce;
		integer t;
		begin
			t = 0;
			while ((!dut.skid_empty || dut.host_pending || dut.ps_busy || e_st != 0 ||
			        !bios_loader.mem_empty || bios_loader.read_state != 0 ||
			        stage_drain.data_read_state != 0 || sc_draining || sc_replay) && t < 5000000) begin
				@(posedge clk_sys); t = t + 1;
			end
			if (t >= 5000000) timeouts = timeouts + 1;
			repeat (50) @(posedge clk_sys);
		end
	endtask

	function [15:0] pat0(input integer w);
		pat0 = (w * 16'h3C5B) ^ 16'h0F0F ^ (w >> 7);
	endfunction

	// ---------------- main ------------------------------------------------
	integer failures = 0, lost = 0, t, j, n, ops, wj;
	reg     drain_done = 0;
	reg [31:0] d;

	task fail(input [8*100-1:0] what);
		begin
			failures = failures + 1;
			$display("   FAIL %0s", what);
		end
	endtask

	initial begin
		if ($value$plusargs("SCN=%d", SCEN)) ;
		if ($value$plusargs("RDGAP=%d", RD_GAP)) ;
		if ($value$plusargs("ENG=%d", ENG)) ;
		if ($value$plusargs("SEED=%d", SEED)) ;
		for (i = 0; i <= 40; i = i + 1) lat_hist[i] = 0;
		// bank 0 (committed) a pattern, bank 1 (spare) 0xDEAD, above: 0
		for (i = 0; i < 32768; i = i + 1) begin
			cmem[i] = pat0(i);          expw[i] = pat0(i);
			cmem[32768 + i] = 16'hDEAD; expw[32768 + i] = 16'hDEAD;
		end
		for (i = 65536; i < 131072; i = i + 1) begin cmem[i] = 16'h0; expw[i] = 16'h0; end
		for (i = 0; i < 16384; i = i + 1) begin
			d = (i * 32'h9E3779B1) ^ 32'h5A5A1234;
			if (d[15:0] == 16'hDEAD) d[15:0] = 16'h1111;
			if (d[31:16] == 16'hDEAD) d[31:16] = 16'h2222;
			blob_img[i] = d;
		end

`ifdef RC6B_LABEL
		$display("== RC6B-RDWR build: %0s", `RC6B_LABEL);
`endif
		$display("== RC6B-RDWR scenario %0d  RD_GAP=%0d  ENG=%0d  SEED=%0d", SCEN, RD_GAP, ENG, SEED);

		repeat (20) @(posedge clk_sys);
		reset_in <= 1'b0;
		repeat (20) @(posedge clk_sys);
		eng_run <= (ENG != 0);

		case (SCEN)
		1: begin
			// the drain into the spare bank, APF flushing the committed bank
			// from the drain's first beat to past its end
			@(posedge clk_sys); cs_load_req <= 1'b1;
			@(posedge clk_sys); cs_load_req <= 1'b0;
			t = 0;
			while (!sc_draining && t < 100000) begin @(posedge clk_sys); t = t + 1; end
			n = 5_300_000 / ((RD_GAP + 2) * 13 + 1);   // reads covering ~5.3 ms
			if (n > 16256) n = 16256;
			fork
				begin
					for (j = 0; j < n; j = j + 1) apf_read(32'h12000000 + j * 4, RD_GAP);
				end
				begin
					t = 0;
					while (!cs_load_done && t < 2000000) begin @(posedge clk_sys); t = t + 1; end
					if (!cs_load_done) timeouts = timeouts + 1;
				end
			join
			$display("   flush reads issued during/after the drain: %0d", n);
		end
		2: begin
			// a fast delivery burst (2 beats per 20 clk_74a: faster than the
			// PSRAM, so the skid grows), then reads right behind it
			for (j = 0; j < 2048; j = j + 1)
				apf_write(32'h12000000 + j * 4, (j * 32'h01000193) ^ 32'hC0DE0000, 18);
			$display("%12t   delivery burst written; skid fill %0d", $time, dut.skid_fill);
			for (j = 0; j < 400; j = j + 1) apf_read(32'h12000000 + 40000 + j * 4, RD_GAP);
		end
		3: begin
			// random raw writes into the spare bank, random APF reads
			rw_mode = 1;
			fork
				begin : wr
					for (j = 0; j < 60000; j = j + 1) begin
						@(posedge clk_sys);
						while (!sc_host_ready) @(posedge clk_sys);
						rw_wr   <= 1'b1;
						r_w      = $unsigned($random(SEED)) % 32512;
						rw_addr <= {9'd0, r_w, 1'b0};
						rw_data <= $random(SEED);
						@(posedge clk_sys);
						rw_wr   <= 1'b0;
						repeat ($unsigned($random(SEED)) % 12) @(posedge clk_sys);
					end
				end
				begin : rd
					for (k = 0; k < 2500; k = k + 1)
						apf_read(32'h12000000 + ($unsigned($random(SEED)) % 16256) * 4,
						         125 + ($unsigned($random(SEED)) % 200));
				end
			join
		end
		4: begin
			// the drain, plus one bridge carrying a random mix of delivery
			// writes (committed words 0..19999) and flush reads (committed words
			// 20000..31999, which nothing writes)
			@(posedge clk_sys); cs_load_req <= 1'b1;
			@(posedge clk_sys); cs_load_req <= 1'b0;
			t = 0;
			while (!sc_draining && t < 100000) begin @(posedge clk_sys); t = t + 1; end
			fork
				begin
					ops = 0; wj = 0;
					while ((!drain_done || ops < 3000) && ops < 40000) begin
						n = $unsigned($random(SEED)) % 10;
						if (n < 5 && wj < 10000) begin
							// a delivery word, now and then a gap-4 burst of 32
							if (n == 0) begin
								for (j = 0; j < 32 && wj < 10000; j = j + 1) begin
									apf_write(32'h12000000 + wj * 4, (wj * 32'h01000193) ^ 32'h7E570000, 4);
									wj = wj + 1;
								end
							end else begin
								apf_write(32'h12000000 + wj * 4, (wj * 32'h01000193) ^ 32'h7E570000,
								          4 + ($unsigned($random(SEED)) % 76));
								wj = wj + 1;
							end
						end else begin
							apf_read(32'h12000000 + 40000 + ($unsigned($random(SEED)) % 6000) * 4,
							         125 + ($unsigned($random(SEED)) % 200));
						end
						ops = ops + 1;
					end
					$display("   bridge ops %0d (delivery words %0d)", ops, wj);
				end
				begin
					t = 0;
					while (!cs_load_done && t < 4000000) begin @(posedge clk_sys); t = t + 1; end
					if (!cs_load_done) timeouts = timeouts + 1;
					drain_done = 1;
				end
			join
		end
		default: begin
			$display("   unknown scenario %0d", SCEN);
			failures = failures + 1;
		end
		endcase

		eng_run <= 1'b0;
		quiesce;

		// C1
		for (i = 0; i < 131072; i = i + 1)
			if (cmem[i] !== expw[i]) begin
				if (lost < 6) $display("   LOST write: word %0d (bank %0d word %0d) chip %04h want %04h",
				                       i, i[16:15], i[14:0], cmem[i], expw[i]);
				lost = lost + 1;
			end
		$display("   C1 words not as the writers left them: %0d  (APF beats %0d, copier/raw beats %0d, collisions %0d)",
		         lost, n_apf, n_sc, n_collide);
		$display("   C2 unloader samples %0d, stale %0d", smp_n, smp_bad);
		$display("   C3 read windows %0d, unserved %0d, latency max %0d clk (must be <= 30), extra reads in a window %0d",
		         win_n, win_unserved, lat_max, rd_extra);
		$write("      latency histogram:");
		for (i = 0; i <= 40; i = i + 1) if (lat_hist[i] != 0) $write(" %0d:%0d", i, lat_hist[i]);
		$write("\n");
		$display("   C4 engine requests %0d, completed %0d, bad reads %0d", eng_issued, eng_done_n, eng_bad);
		$display("   C5 diag beats %0d drops %0d (skid-full beats %0d); skid max fill %0d; copier drain beats %0d",
		         diag_beats, diag_drops, n_skidfull, skid_max, sc_diag_drain);
		$display("      chip write strobes %0d = diag_beats - diag_drops %0d + engine writes %0d ?",
		         chip_wr, diag_beats - diag_drops, eng_wr_n);
		$display("   C6 read windows opened over a popped write %0d; timeouts %0d", cov_l1, timeouts);

		if (lost != 0)                          fail("C1 writes lost");
		if (smp_bad != 0)                       fail("C2 stale or wrong flush samples");
		if (win_unserved != 0 || lat_max > 30)  fail("C3 a read window unserved or served too late");
		if (rd_extra != 0)                      fail("C3 more than one PSRAM read in a window");
		if (win_n == 0 || smp_n != win_n)       fail("C3 read windows and unloader samples disagree");
		if (eng_done_n != eng_issued || eng_bad != 0) fail("C4 engine request lost or read wrong");
		if (n_skidfull != 0)                    fail("C5 host beats dropped at a full skid");
`ifdef NGPC_SAVE_DIAG
		if (diag_drops != (n_skidfull & 16'hFFFF)) fail("C5 diag_drops != beats that met a full skid");
		if (diag_beats != ((n_apf + n_sc) & 16'hFFFF)) fail("C5 diag_beats != APF + copier/raw beats");
		// every beat the counters say was kept reached the chip, exactly once
		if (chip_wr != (diag_beats - diag_drops) + eng_wr_n)
			fail("C5 chip writes != diag_beats - diag_drops + engine writes (an uncounted loss)");
`else
		// built without the counters: every beat offered reached the chip once
		$display("   (built without NGPC_SAVE_DIAG: the diag counter checks are skipped)");
		if (chip_wr != n_apf + n_sc + eng_wr_n)
			fail("C5 chip writes != APF + copier/raw beats + engine writes");
`endif
		if (cov_l1 == 0)                        fail("C6 coverage: no read window over a queued write");
		if (SCEN == 4 && n_collide == 0)        fail("C6 coverage: no arbiter collision in scenario 4");
		if (timeouts != 0)                      fail("C6 a drain or quiesce timed out");
		if ((SCEN == 1 || SCEN == 4) && (load_err_seen || sc_diag_drain != 16'd32512))
			fail("C6 the drain did not run to its 32512 beats");

		// Pass: $finish, exit status 0. Fail: $stop, which under "vvp -N" (as
		// the run script runs it) ends the run with exit status 1.
		if (failures == 0) begin
			$display("== ALL RC6B-RDWR SCENARIOS PASS");
			$finish;
		end else begin
			$display("== %0d FAILURE(S) in RC6B-RDWR scenario %0d", failures, SCEN);
			$stop;
		end
	end

	initial begin
		#400_000_000;
		$display("   FAIL watchdog");
		$display("== %0d FAILURE(S) in RC6B-RDWR scenario %0d (watchdog)", failures + 1, SCEN);
		$stop;
	end

endmodule

`default_nettype wire
