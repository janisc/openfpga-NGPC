// tb_rc6x_t7s -- rc6 family X: tb_t7s_inv's T7 invariants on the REAL rc6
// staging path, with the REAL T7 Memory image as the drained data
// (sim/tb_rc6x_t7s_img.hex, a copy of sim/tb_t7s_img.hex =
// T7_memory_104537_embedded.sav's cart section).
//
// Ported from sim/tb_t7s_inv.sv (rc5 glue: the priority mux and
// host_busy || sc_draining). Here core_top.v rc6 verbatim: the L3 part A
// write-port arbiter (APF never writes in this bench), stage_mem's
// host_wr_ready_o as stage_host_ready, host_busy ALONE into the engine, and
// the engine's host_rd_i = the quit flush's read strobe (rc6 follow-up).
//
// REAL, unmodified: ngpc_stage_mem, psram, ngpc_state_cart, ngpc_cart_save,
// ngp_cart_overlay_geometry (or a mutant copy, sim/run_rc6_combo.sh mutants).
// MODELED: the CellularRAM chip, the bridge's port-A read of the blob, a
// 3-clock p2 port, the quit flush with data_unloader's mem-side timing.
//
// MODES (+MODE=n, +BANK=b = the committed bank before the load):
//   0  RTL baseline: engine idle, load the Memory, flush. I1: no stage_ready
//      between the first drain beat and the last one reaching PSRAM. I2: no
//      engine op served mid-drain. The file equals the Memory image, and the
//      T7 flag never rises.
//   1  FAULT INJECTION (counterfactual A): 100 beats into the drain the engine
//      is put in S_STAGE_HDR at hdr_idx 18 with its CRC/diag registers set so
//      words 19..31 equal the file's. It then writes words 18..31 while
//      draining: the T7 flag must rise, and a stray header that reaches the
//      committed bank and the file must carry word 23 bit 14.
//   2  mode 1 plus a copier stall at diag_drain 8197 (a HYPOTHETICAL fault):
//      the T7 signature, word 18 = 0x2005 -- now with word 23 bit 14.
//   3  FAULT INJECTION: a rogue engine-PORT write (word 18 = diag_drain) at
//      diag_drain 8197 that the ENGINE did not issue: the flag records only
//      the engine's own requests, so it must stay clear.
// Each run ends '== RC6X SCENARIO t7s_mode<n>_bank<b> ... PASS' or '... FAIL'.
// Run: wsl -e sh sim/run_rc6_combo.sh

`timescale 1ns / 1ps
`default_nettype none

module tb_rc6x_t7s;

	reg clk_sys = 0;
	always #10.173 clk_sys = ~clk_sys;   // 49.152 MHz

	integer cyc = 0;
	always @(posedge clk_sys) cyc <= cyc + 1;

	reg reset_in = 1;

	integer MODE = 0;
	integer BANK = 1;

	localparam integer SLOTW = 32512;
	localparam integer CARTW = 16256;

	// =====================================================================
	// Blob cart section (bridge port A: seq_pa_addr register, then a_q)
	// =====================================================================
	reg  [31:0] blob [0:CARTW-1];
	wire [13:0] cs_img_rd_addr;
	reg  [13:0] seq_pa_addr_q = 0;
	reg  [31:0] a_q = 0;
	wire        cs_img_wr;
	wire [13:0] cs_img_addr;
	wire [31:0] cs_img_data;
	always @(posedge clk_sys) begin
		seq_pa_addr_q <= cs_img_rd_addr;
		a_q           <= blob[seq_pa_addr_q];
		if (cs_img_wr) blob[cs_img_addr] <= cs_img_data;
	end

	// =====================================================================
	// Staging: stage_mem + psram + chip model
	// =====================================================================
	wire        stage_req, stage_we;
	wire [24:0] stage_addr;
	wire [15:0] stage_wdata;
	wire        stage_ready, stage_done;
	wire [15:0] stage_rdata;
	wire        host_busy;
	wire [15:0] stage_diag_beats, stage_diag_drops;

	reg         apf_wr = 0;         // unused here: no delivery
	reg  [24:0] apf_wr_addr = 0;
	reg  [15:0] apf_wr_data = 0;
	reg         host_rd = 0;
	reg  [24:0] host_rd_addr = 0;
	wire [15:0] host_rd_data;

	wire        sc_rd_req, sc_rd_active, sc_draining;
	wire [24:0] sc_rd_addr;
	wire        sc_host_wr;
	wire        sc_host_ready_mem;
	wire [24:0] sc_host_addr;
	wire [15:0] sc_host_data;
	wire        mc_stage_current, mc_stage_bank;
	wire        mc_state_apply, mc_state_done, mc_apply_reject;
	wire [15:0] sc_diag_drain;

	// ---- core_top.v (rc6) glue, verbatim: the L3 part A write-port arbiter ----
	wire        apf_save_wr = apf_wr;
	reg         sc_replay   = 1'b0;
	wire        sc_beat     = sc_host_wr || sc_replay;
	wire        sc_go       = sc_beat && !apf_save_wr;
	always @(posedge clk_sys) sc_replay <= !reset_in && sc_beat && apf_save_wr;
	wire        stage_host_wr      = apf_save_wr || sc_beat;
	wire [24:0] stage_host_wr_addr = sc_go ? sc_host_addr : apf_wr_addr;
	wire [15:0] stage_host_wr_data = sc_go ? sc_host_data : apf_wr_data;
	wire        stage_wr_bank      = sc_go ? ~mc_stage_bank : mc_stage_bank;

	// ---- bench-only fault injection (modes 2, 3) ----
	reg         stall = 0;          // mode 2: hypothetical copier stall
	reg         rogue_req = 0;      // mode 3: a request that ignores ready
	wire        sc_host_ready = sc_host_ready_mem && !sc_replay && !(sc_host_wr && apf_save_wr) && !stall;

	wire        eng_req_mux  = rogue_req ? 1'b1 : (sc_rd_active ? sc_rd_req : stage_req);
	wire        eng_we_mux   = rogue_req ? 1'b1 : (sc_rd_active ? 1'b0 : stage_we);
	wire [24:0] eng_addr_mux = rogue_req ? {8'd0, ~mc_stage_bank, 16'd36}
	                         : (sc_rd_active ? (sc_rd_addr | {8'd0, mc_stage_bank, 16'd0}) : stage_addr);
	wire [15:0] eng_wdata_mux = rogue_req ? sc_diag_drain : stage_wdata;

	wire [21:16] cram_a;
	wire [15:0]  cram_dq;
	wire cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n;
	wire cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;

	ngpc_stage_mem u_mem (
		.clk            (clk_sys),
		.reset          (reset_in),
		.active_bank_i  (mc_stage_bank),
		.host_wr_bank_i (stage_wr_bank),
		.host_wr_i      (stage_host_wr),
		.host_wr_addr_i (stage_host_wr_addr),
		.host_wr_data_i (stage_host_wr_data),
		.host_rd_i      (host_rd),
		.host_rd_addr_i (host_rd_addr),
		.host_rd_data_o (host_rd_data),
		.host_wr_ready_o(sc_host_ready_mem),
		.host_busy_o    (host_busy),
		.diag_beats_o   (stage_diag_beats),
		.diag_drops_o   (stage_diag_drops),
		.eng_req_i      (eng_req_mux),
		.eng_we_i       (eng_we_mux),
		.eng_addr_i     (eng_addr_mux),
		.eng_wdata_i    (eng_wdata_mux),
		.eng_ready_o    (stage_ready),
		.eng_done_o     (stage_done),
		.eng_rdata_o    (stage_rdata),
		.cram_a    (cram_a),
		.cram_dq   (cram_dq),
		.cram_wait (1'b0),
		.cram_clk  (cram_clk),
		.cram_adv_n(cram_adv_n),
		.cram_cre  (cram_cre),
		.cram_ce0_n(cram_ce0_n),
		.cram_ce1_n(cram_ce1_n),
		.cram_oe_n (cram_oe_n),
		.cram_we_n (cram_we_n),
		.cram_ub_n (cram_ub_n),
		.cram_lb_n (cram_lb_n)
	);

	// ---- CellularRAM, async mode ----
	reg [15:0] cmem [0:65535];
	reg [21:0] c_addr_l = 0;
	reg        p_we = 1, p_ce = 1, p_ub = 1, p_lb = 1;
	reg [15:0] p_dq = 0;
	reg [21:0] p_addr = 0;
	assign cram_dq = (!cram_ce0_n && !cram_oe_n && cram_we_n) ? cmem[c_addr_l[15:0]] : 16'hzzzz;

	integer hdr_wr_log = 0;
	always @(posedge clk_sys) begin
		p_we <= cram_we_n; p_ce <= cram_ce0_n;
		p_ub <= cram_ub_n; p_lb <= cram_lb_n;
		p_dq <= cram_dq;   p_addr <= c_addr_l;
		if (!cram_ce0_n && !cram_adv_n) begin
			c_addr_l <= {cram_a, cram_dq};
			if ({cram_a, cram_dq} == 22'h002005 || {cram_a, cram_dq} == 22'h00A005)
				$display("   [addr phase] t=%0d dq=%04h (a=%0h) draining=%0d diag_drain=%0d",
				         cyc, cram_dq, cram_a, sc_draining, sc_diag_drain);
		end
		if (cram_we_n && !p_we && !p_ce) begin
			if (!p_ub) cmem[p_addr[15:0]][15:8] <= p_dq[15:8];
			if (!p_lb) cmem[p_addr[15:0]][7:0]  <= p_dq[7:0];
			if (p_addr[14:0] < 15'd32 && p_addr[14:0] >= 15'd16) begin
				if (hdr_wr_log < 200)
					$display("   [hdr write] t=%0d bank=%0d word=%0d val=%04h draining=%0d diag_drain=%0d diag_beats=%0d eng_active=%0d",
					         cyc, p_addr[15], p_addr[14:0], p_dq, sc_draining, sc_diag_drain,
					         stage_diag_beats, u_mem.eng_active);
				hdr_wr_log = hdr_wr_log + 1;
			end
		end
	end

	// =====================================================================
	// Copier
	// =====================================================================
	reg  cs_save_req = 0, cs_load_req = 0;
	wire cs_save_done, cs_load_done, cs_load_error, mc_capture_hold;

	ngpc_state_cart u_sc (
		.clk             (clk_sys),
		.reset           (reset_in),
		.cart_save_req   (cs_save_req),
		.cart_save_done  (cs_save_done),
		.cart_img_wr     (cs_img_wr),
		.cart_img_addr   (cs_img_addr),
		.cart_img_data   (cs_img_data),
		.cart_load_req   (cs_load_req),
		.cart_load_done  (cs_load_done),
		.cart_load_error (cs_load_error),
		.cart_img_rd_addr(cs_img_rd_addr),
		.cart_img_rd_data(a_q),
		.sc_rd_req       (sc_rd_req),
		.sc_rd_addr      (sc_rd_addr),
		.sc_rd_ready     (stage_ready),
		.sc_rd_done      (stage_done),
		.sc_rd_data      (stage_rdata),
		.sc_rd_active    (sc_rd_active),
		.draining_o      (sc_draining),
		.sc_host_ready   (sc_host_ready),
		.sc_host_wr      (sc_host_wr),
		.sc_host_addr    (sc_host_addr),
		.sc_host_data    (sc_host_data),
		.stage_current_i (mc_stage_current),
		.apply_reject_i  (mc_apply_reject),
		.state_apply_o   (mc_state_apply),
		.state_done_i    (mc_state_done),
		.diag_drain_o    (sc_diag_drain),
		.hold_o          (mc_capture_hold)
	);

	// =====================================================================
	// Save engine
	// =====================================================================
	wire        p2_req, p2_we;
	wire [24:0] p2_addr;
	wire [15:0] p2_wdata;
	wire  [1:0] p2_be;
	reg  [2:0]  p2_cnt = 0;
	reg         p2_done = 0;
	wire        p2_ready = (p2_cnt == 0) && !p2_req;
	integer     p2_writes = 0;
	always @(posedge clk_sys) begin
		p2_done <= 1'b0;
		if (p2_req) begin
			p2_cnt <= 3'd3;
			if (p2_we) p2_writes = p2_writes + 1;
		end else if (p2_cnt != 0) begin
			p2_cnt <= p2_cnt - 3'd1;
			if (p2_cnt == 3'd1) p2_done <= 1'b1;
		end
	end

	wire boot_hold, save_busy, save_present, frozen;

	ngpc_cart_save u_save (
		.clk            (clk_sys),
		.reset          (reset_in),
		.cart_ready_i   (1'b1),
		.cart_replace_i (1'b0),
		.cart_crc32_i   (32'h94B63A97),
		.cart_bytes_i   (25'h0200000),
		.cart_title_i   ({16'h4520, 16'h5448, 16'h4749, 16'h4620, 16'h4452, 16'h4143}),
		.cart_catalog_i (16'h0067),
		.cart_subcat_i  (8'h03),
		.size_code0_i   (2'd3),
		.size_code1_i   (2'd0),
		.event0_i       (1'b0),
		.block0_i       (6'd0),
		.event1_i       (1'b0),
		.block1_i       (6'd0),
		.die_busy_i     (2'b00),
		.host_busy_i    (host_busy),                 // core_top rc6: the host port alone (L2)
		.host_rd_i      (host_rd),                   // core_top rc6: the flush's read strobe (stage_host_rd)
		.state_apply_i  (mc_state_apply),
		.draining_i     (sc_draining),
		.state_frozen_i (1'b0),
		.state_fail_i   (1'b0),
		.frozen_o       (frozen),
		.save_slot_wr_i (1'b0),
		.apply_reject_o (mc_apply_reject),
		.state_done_o   (mc_state_done),
		.slots_settled_i(1'b1),
		.diag_beats_i   (stage_diag_beats),
		.diag_drops_i   (stage_diag_drops),
		.diag_drain_i   (sc_diag_drain),
		.boot_hold_o    (boot_hold),
		.busy_o         (save_busy),
		.save_present_o (save_present),
		.stage_current_o(mc_stage_current),
		.stage_bank_o   (mc_stage_bank),
		.p2_req_o       (p2_req),
		.p2_we_o        (p2_we),
		.p2_addr_o      (p2_addr),
		.p2_wdata_o     (p2_wdata),
		.p2_be_o        (p2_be),
		.p2_ready_i     (p2_ready),
		.p2_done_i      (p2_done),
		.p2_rdata_i     (16'hFFFF),
		.stage_req_o    (stage_req),
		.stage_we_o     (stage_we),
		.stage_addr_o   (stage_addr),
		.stage_wdata_o  (stage_wdata),
		.stage_ready_i  (stage_ready),
		.stage_done_i   (stage_done),
		.stage_rdata_i  (stage_rdata)
	);

	// =====================================================================
	// Monitors
	// =====================================================================
	integer first_beat_cyc = -1, last_beat_cyc = -1;
	integer rdy_before = 0, rdy_mid = 0, rdy_after = 0;
	integer served_mid = 0, served_total_drain = 0;
	integer max_fill = 0;
	integer eng_state_busy_drain = 0;
	reg     beats_done = 0;

	wire eng_served = eng_req_mux && !u_mem.ps_busy && !u_mem.ps_write_en &&
	                  !u_mem.ps_read_en && !u_mem.host_pending;

	always @(posedge clk_sys) begin
		if (sc_draining) begin
			if (u_mem.skid_fill > max_fill) max_fill = u_mem.skid_fill;
			if (u_save.state != 5'd0) eng_state_busy_drain = eng_state_busy_drain + 1;
			if (stage_ready) begin
				if (first_beat_cyc < 0)                     rdy_before = rdy_before + 1;
				else if (!beats_done || !u_mem.skid_empty || u_mem.host_pending || u_mem.ps_busy)
				                                            rdy_mid = rdy_mid + 1;
				else                                        rdy_after = rdy_after + 1;
			end
			if (eng_served) begin
				served_total_drain = served_total_drain + 1;
				if (first_beat_cyc >= 0 && !(beats_done && u_mem.skid_empty)) begin
					served_mid = served_mid + 1;
					$display("   [eng served mid-drain] t=%0d we=%0d addr=%h data=%04h diag_drain=%0d",
					         cyc, eng_we_mux, eng_addr_mux, eng_wdata_mux, sc_diag_drain);
				end
			end
			// rc6X: the first beat is on the port in this clock and reaches the skid
			// at its end; ready in this clock is 'before', not 'mid-drain' (the
			// original classified it after setting first_beat_cyc: rdy_mid = 1)
			if (sc_host_wr && first_beat_cyc < 0) first_beat_cyc = cyc;
			if (sc_diag_drain == 16'd32512 && !beats_done) begin
				beats_done = 1;
				last_beat_cyc = cyc;
			end
		end
	end

	// =======================================================================
	// rc6X monitors: host-write loss scoreboards and the T7 flag
	// =======================================================================
	// ARB: each APF save-slot beat and each copier drain beat, in order per
	// writer, must appear at the stage port (stage_host_wr) exactly once with
	// its own {bank, word, data} (a collision replays the copier's beat on the
	// next clock); a push into a full skid is a drop.
	// SKID: each skid push must reach the PSRAM as one host write, in order.
	localparam integer QN = 131072;
	reg [31:0] qa [0:QN-1];
	reg [31:0] qc [0:QN-1];
	reg [31:0] qs [0:QN-1];
	integer qa_w = 0, qa_r = 0, qc_w = 0, qc_r = 0, qs_w = 0, qs_r = 0;
	integer arb_lost = 0, arb_bad = 0, arb_drop = 0, arb_left = 0, arb_replays = 0, arb_coll = 0;
	integer skid_lost = 0, skid_bad = 0, skid_left = 0, skid_pushes = 0, skid_issues = 0;
	integer n_rd_wait = 0;   // info: clocks a host read waited behind a pending write (rc5's hazard condition)
	always @(posedge clk_sys) begin : scoreboards
		reg [31:0] v;
		integer kk, hit;
		if (reset_in) begin
			arb_left  = arb_left + (qa_w - qa_r) + (qc_w - qc_r);
			skid_left = skid_left + (qs_w - qs_r);
			qa_r = qa_w; qc_r = qc_w; qs_r = qs_w;
		end else begin
			if (apf_save_wr === 1'b1) begin
				qa[qa_w % QN] = {mc_stage_bank, apf_wr_addr[15:1], apf_wr_data};
				qa_w = qa_w + 1;
			end
			if (sc_host_wr === 1'b1) begin
				qc[qc_w % QN] = {~mc_stage_bank, sc_host_addr[15:1], sc_host_data};
				qc_w = qc_w + 1;
			end
			if (sc_replay === 1'b1) arb_replays = arb_replays + 1;
			if (sc_host_wr === 1'b1 && apf_save_wr === 1'b1) arb_coll = arb_coll + 1;
			if (stage_host_wr === 1'b1) begin
				v = {stage_wr_bank, stage_host_wr_addr[15:1], stage_host_wr_data};
				if (u_mem.skid_full === 1'b1) arb_drop = arb_drop + 1;
				hit = 0;
				for (kk = 0; kk < 8 && !hit && qa_r + kk < qa_w; kk = kk + 1)
					if (qa[(qa_r + kk) % QN] === v) begin hit = 1; arb_lost = arb_lost + kk; qa_r = qa_r + kk + 1; end
				for (kk = 0; kk < 8 && !hit && qc_r + kk < qc_w; kk = kk + 1)
					if (qc[(qc_r + kk) % QN] === v) begin hit = 1; arb_lost = arb_lost + kk; qc_r = qc_r + kk + 1; end
				if (!hit) begin
					arb_bad = arb_bad + 1;
					if (arb_bad <= 4) $display("   [%0d] ARB: stage-port beat %h matches neither writer's next beat (APF %0d owed, copier %0d owed)",
					                           cyc, v, qa_w - qa_r, qc_w - qc_r);
				end
			end
			if (u_mem.host_wr_i === 1'b1 && u_mem.skid_full !== 1'b1 && u_mem.host_wr_in_bank === 1'b1) begin
				qs[qs_w % QN] = {u_mem.host_wr_word[15:0], u_mem.host_wr_data_i};
				qs_w = qs_w + 1;
				skid_pushes = skid_pushes + 1;
			end
			if (u_mem.host_pending === 1'b1 && u_mem.host_pending_rd === 1'b0 && host_rd === 1'b1)
				n_rd_wait = n_rd_wait + 1;
			if (u_mem.ps_busy === 1'b0 && u_mem.ps_write_en === 1'b0 && u_mem.ps_read_en === 1'b0 &&
			    u_mem.host_pending === 1'b1 && u_mem.host_pending_rd === 1'b0) begin
				v = {u_mem.host_pending_addr[15:0], u_mem.host_pending_data};
				skid_issues = skid_issues + 1;
				hit = 0;
				for (kk = 0; kk < 600 && !hit && qs_r + kk < qs_w; kk = kk + 1)
					if (qs[(qs_r + kk) % QN] === v) begin hit = 1; skid_lost = skid_lost + kk; qs_r = qs_r + kk + 1; end
				if (!hit) begin
					skid_bad = skid_bad + 1;
					if (skid_bad <= 4) $display("   [%0d] SKID: PSRAM host write %h matches no queued skid entry", cyc, v);
				end
			end
		end
	end
	// beats still owed at the end of a quiet period were lost
	task sb_settle_check(input string when);
		begin
			if (qa_w != qa_r || qc_w != qc_r || qs_w != qs_r)
				$display("   [%0d] SCOREBOARD at %0s: APF beats owed %0d, copier beats owed %0d, skid entries owed %0d",
				         cyc, when, qa_w - qa_r, qc_w - qc_r, qs_w - qs_r);
			arb_left  = arb_left + (qa_w - qa_r) + (qc_w - qc_r);
			skid_left = skid_left + (qs_w - qs_r);
			qa_r = qa_w; qc_r = qc_w; qs_r = qs_w;
		end
	endtask
	function integer host_loss(input integer dummy);
		host_loss = arb_lost + arb_bad + arb_drop + arb_left + skid_lost + skid_bad + skid_left;
	endfunction

	// ---- the T7 flag (diag_wr_drain, header word 23 bit 14) ----------------
	integer engwr_epoch = 0;        // engine staging writes while draining since reset / cart_replace
	integer n_flag_rise = 0, n_flag_incons = 0, n_w23_eng = 0, n_w23_bad = 0, n_w23_b14 = 0;
	integer n_eng_wr_drain = 0;
	reg     flag_q = 1'b0;
	always @(posedge clk_sys) begin : t7flag
		if ((u_save.diag_wr_drain === 1'b1) !== (engwr_epoch > 0)) begin
			n_flag_incons = n_flag_incons + 1;
			if (n_flag_incons <= 4) $display("   [%0d] T7 FLAG: diag_wr_drain %b but %0d engine writes while draining this epoch",
			                                  cyc, u_save.diag_wr_drain, engwr_epoch);
		end
		if (u_save.diag_wr_drain === 1'b1 && flag_q !== 1'b1) begin
			n_flag_rise = n_flag_rise + 1;
			$display("   [%0d] T7 FLAG: diag_wr_drain rises (engine state %0d, hdr_idx %0d, drain %0d)",
			         cyc, u_save.state, u_save.hdr_idx, sc_diag_drain);
		end
		flag_q = (u_save.diag_wr_drain === 1'b1);
		if (reset_in === 1'b1 || 1'b0) engwr_epoch = 0;
		else if (stage_req === 1'b1 && stage_we === 1'b1 && sc_draining === 1'b1) begin
			engwr_epoch = engwr_epoch + 1;
			n_eng_wr_drain = n_eng_wr_drain + 1;
		end
		if (reset_in !== 1'b1 && stage_req === 1'b1 && stage_we === 1'b1 && sc_rd_active !== 1'b1 &&
		    stage_addr[15:1] == 15'd23) begin
			n_w23_eng = n_w23_eng + 1;
			if (stage_wdata[14] !== u_save.diag_wr_drain) begin
				n_w23_bad = n_w23_bad + 1;
				$display("   [%0d] T7 FLAG: engine writes word 23 = %h with the flag %b", cyc, stage_wdata, u_save.diag_wr_drain);
			end
		end
		// anyone writing header word 23 with bit 14 set, at the PSRAM
		if (reset_in !== 1'b1 && u_mem.ps_write_en === 1'b1 && u_mem.ps_addr[14:0] == 15'd23 &&
		    u_mem.ps_data_in[14] === 1'b1) begin
			n_w23_b14 = n_w23_b14 + 1;
			if (n_w23_b14 <= 4) $display("   [%0d] T7 FLAG: word 23 = %h written to bank %0d by %0s", cyc,
			                             u_mem.ps_data_in, u_mem.ps_addr[15],
			                             (u_mem.eng_active === 1'b1 && u_mem.eng_active_rd !== 1'b1) ? "ENGINE" : "HOST");
		end
	end

	// last writer of header words 16..18 per bank: 1 = the engine while draining
	reg lw_stray0 [16:18];
	reg lw_stray1 [16:18];
	initial begin : lw_init
		integer k2;
		for (k2 = 16; k2 <= 18; k2 = k2 + 1) begin lw_stray0[k2] = 1'b0; lw_stray1[k2] = 1'b0; end
	end
	always @(posedge clk_sys) if (reset_in !== 1'b1 && u_mem.ps_write_en === 1'b1 &&
	                              u_mem.ps_addr[14:0] >= 15'd16 && u_mem.ps_addr[14:0] <= 15'd18) begin
		if (u_mem.ps_addr[15]) lw_stray1[u_mem.ps_addr[4:0]] = (u_mem.eng_active === 1'b1 && u_mem.eng_active_rd !== 1'b1 && sc_draining === 1'b1);
		else                   lw_stray0[u_mem.ps_addr[4:0]] = (u_mem.eng_active === 1'b1 && u_mem.eng_active_rd !== 1'b1 && sc_draining === 1'b1);
	end
	function integer bank_stray(input integer b);
		if (b == 0) bank_stray = lw_stray0[16] || lw_stray0[17] || lw_stray0[18];
		else        bank_stray = lw_stray1[16] || lw_stray1[17] || lw_stray1[18];
	endfunction

	// ---- mode 1/2: put the engine mid-header once 100 beats are in ----
	reg deposited = 0;
	always @(posedge clk_sys) begin
		if ((MODE == 1 || MODE == 2) && !deposited && sc_draining && sc_diag_drain == 16'd100) begin
			deposited = 1;
			#1;
			u_save.state         = 5'd6;          // S_STAGE_HDR
			u_save.hdr_idx       = 6'd18;
			u_save.busy_o        = 1'b1;
			u_save.crc_acc       = ~32'hE4988519;
			u_save.diag_applies  = 16'd1;
			u_save.diag_verdict  = 16'h0001;
			u_save.diag_p2wr     = 16'h4000;
			$display("   [deposit] t=%0d engine -> S_STAGE_HDR idx 18 (diag_drain=%0d)", cyc, sc_diag_drain);
		end
	end

	// ---- mode 2: hypothetical copier stall at diag_drain == 8197 ----
	reg stalled_once = 0;
	integer stall_left = 0;
	always @(posedge clk_sys) begin
		if (MODE == 2 && !stalled_once && sc_diag_drain == 16'd8197) begin
			stalled_once <= 1;
			stall <= 1;
			stall_left = 6000;
			$display("   [stall] t=%0d copier held for 6000 clocks at diag_drain=%0d", cyc, sc_diag_drain);
		end else if (stall) begin
			stall_left = stall_left - 1;
			if (stall_left == 0) stall <= 0;
		end
	end

	// ---- mode 3: a rogue request at diag_drain == 8197 ----
	reg rogue_once = 0;
	always @(posedge clk_sys) begin
		rogue_req <= 1'b0;
		if (MODE == 3 && !rogue_once && sc_diag_drain == 16'd8197) begin
			rogue_once <= 1;
			rogue_req  <= 1'b1;
			$display("   [rogue] t=%0d engine-port write request (word 18, data %04h), skid_fill=%0d host_pending=%0d",
			         cyc, sc_diag_drain, u_mem.skid_fill, u_mem.host_pending);
		end
	end

	// =====================================================================
	// Flush at quit: data_unloader mem-side timing
	// =====================================================================
	reg [15:0] flushed [0:SLOTW-1];
	task flush_slot;
		integer i, k;
		begin
			for (i = 0; i < SLOTW; i = i + 1) begin
				@(posedge clk_sys);
				host_rd      <= 1'b1;
				host_rd_addr <= i * 2;
				for (k = 0; k < 31; k = k + 1) @(posedge clk_sys);
				@(negedge clk_sys);
				flushed[i] = host_rd_data;
				@(posedge clk_sys);
				host_rd <= 1'b0;
				repeat (3) @(posedge clk_sys);
			end
		end
	endtask

	// =====================================================================
	// The run
	// =====================================================================
	integer i, ndiff, err;
	integer nf = 0, q_stray = 0;
	string  tag = "";   // +TAG, else t7s_mode<n>_bank<b>
	reg     ld_err = 1'bx;
	reg [15:0] ld_verdict = 16'hxxxx;
	task chk(input ok, input string what);
		begin
			if (ok !== 1'b1) begin
				nf = nf + 1;
				$display("   CHECK FAIL: %0s", what);
			end
		end
	endtask
	reg [15:0] imgw;

	initial begin
		if (!$value$plusargs("MODE=%d", MODE)) MODE = 0;
		if (!$value$plusargs("BANK=%d", BANK)) BANK = 1;
		if (!$value$plusargs("TAG=%s", tag)) tag = $sformatf("t7s_mode%0d_bank%0d", MODE, BANK);
		$readmemh("sim/tb_rc6x_t7s_img.hex", blob);
		for (i = 0; i < 65536; i = i + 1) cmem[i] = 16'hA5A5;
		// the committed bank holds the delivered file (= the Memory image)
		for (i = 0; i < SLOTW; i = i + 1)
			cmem[(BANK ? 32768 : 0) + i] = (i & 1) ? blob[i/2][31:16] : blob[i/2][15:0];

		$display("== tb_t7s MODE=%0d committed bank before the load=%0d (drain -> bank %0d)",
		         MODE, BANK, !BANK);
		repeat (20) @(posedge clk_sys);
		reset_in <= 0;
		// stage_bank_o is not reset (power-up 0); model the committed bank
		u_save.stage_bank_o = BANK[0];
		// let the reset-time boot apply (nothing delivered: F_NODELV) finish
		wait (u_save.state == 5'd0 && !u_save.apply_pending);
		repeat (100) @(posedge clk_sys);

		// ---- load the Memory ----
		@(posedge clk_sys) cs_load_req <= 1'b1;
		@(posedge clk_sys) cs_load_req <= 1'b0;
		wait (cs_load_done);
		@(posedge clk_sys);
		ld_err = cs_load_error; ld_verdict = u_save.diag_verdict;
		$display("   load done t=%0d error=%0d  committed bank now %0d  verdict=%04h applies=%0d",
		         cyc, cs_load_error, mc_stage_bank, u_save.diag_verdict, u_save.diag_applies);
		$display("   drain: first beat t=%0d, 32512th beat counted t=%0d (%0d clocks), skid max fill %0d, drops %0d",
		         first_beat_cyc, last_beat_cyc, last_beat_cyc - first_beat_cyc, max_fill, stage_diag_drops);
		$display("   I1 stage_ready while draining: before first beat %0d, mid-drain %0d, after skid empty %0d",
		         rdy_before, rdy_mid, rdy_after);
		$display("   I2 engine ops served while draining: %0d (mid-drain %0d); clocks the engine was not in S_IDLE while draining: %0d",
		         served_total_drain, served_mid, eng_state_busy_drain);

		// ---- quit: flush the committed bank ----
		flush_slot();
		ndiff = 0;
		for (i = 0; i < SLOTW; i = i + 1) begin
			imgw = (i & 1) ? blob[i/2][31:16] : blob[i/2][15:0];
			if (flushed[i] !== imgw) begin
				if (ndiff < 12) $display("   flushed word %0d = %04h, Memory image %04h", i, flushed[i], imgw);
				ndiff = ndiff + 1;
			end
		end
		$display("== RESULT MODE=%0d BANK=%0d: flushed file differs from the Memory image in %0d word(s); word18=%04h word23=%04h; rdy_mid=%0d served_mid=%0d",
		         MODE, BANK, ndiff, flushed[18], flushed[23], rdy_mid, served_mid);
		sb_settle_check("end");
		q_stray = bank_stray(mc_stage_bank);
		$display("   T7 flag: diag_wr_drain %b, rises %0d, engine writes while draining %0d, engine word-23 writes %0d (bad %0d), word 23 bit 14 written %0d; stray header in the committed bank %0d",
		         u_save.diag_wr_drain, n_flag_rise, n_eng_wr_drain, n_w23_eng, n_w23_bad, n_w23_b14, q_stray);
		$display("   host-write loss %0d (ARB lost %0d unmatched %0d drops %0d owed %0d; SKID lost %0d unmatched %0d owed %0d); diag_drops %0d",
		         host_loss(0), arb_lost, arb_bad, arb_drop, arb_left, skid_lost, skid_bad, skid_left, stage_diag_drops);
		chk(host_loss(0) == 0 && stage_diag_drops === 16'd0, "host-write loss or skid drops");
		chk(n_flag_incons == 0 && n_w23_bad == 0, "the T7 flag disagreed with the engine's writes while draining");
		if (q_stray) chk(flushed[23][14] === 1'b1, $sformatf("a T7-shaped stray header reached the file but word 23 = %04h lacks bit 14", flushed[23]));
		if (MODE == 0) begin
			chk(ld_err === 1'b0 && ld_verdict === 16'h8001, $sformatf("the load: error %b verdict %04h, want accepted (8001)", ld_err, ld_verdict));
			chk(ndiff == 0, $sformatf("the flushed file differs from the Memory image in %0d words", ndiff));
			chk(rdy_mid == 0 && served_mid == 0, $sformatf("I1/I2: stage_ready mid-drain %0d, engine ops served mid-drain %0d", rdy_mid, served_mid));
			chk(n_flag_rise == 0 && n_w23_b14 == 0 && n_eng_wr_drain == 0,
			    $sformatf("RTL-only: T7 flag rises %0d, word-23 bit-14 writes %0d, engine writes while draining %0d", n_flag_rise, n_w23_b14, n_eng_wr_drain));
			chk(q_stray == 0, "RTL-only: an engine header written while draining is in the committed bank");
		end
		if (MODE == 1 || MODE == 2) begin
			chk(n_eng_wr_drain > 0 && n_flag_rise == 1 && u_save.diag_wr_drain === 1'b1,
			    $sformatf("the injected mid-drain header walk: engine writes while draining %0d, flag rises %0d, flag %b",
			              n_eng_wr_drain, n_flag_rise, u_save.diag_wr_drain));
			chk(q_stray == 1 && flushed[23][14] === 1'b1, $sformatf("the stray header should reach the file with word 23 bit 14 (stray %0d, word 23 %04h)", q_stray, flushed[23]));
		end
		// T7's word 18 was the live drain count, 0x2005; with rc6's shallower skid
		// the injected stall lands one beat later here, so any count near it
		if (MODE == 2) chk(flushed[18] >= 16'h2000 && flushed[18] <= 16'h2010,
		                   $sformatf("mode 2 reproduces T7's word 18 = a live drain count near 0x2005 (got %04h)", flushed[18]));
		if (MODE == 3) chk(n_flag_rise == 0 && u_save.diag_wr_drain !== 1'b1 && n_eng_wr_drain == 0,
		                   $sformatf("a write the engine did not issue must not raise the flag (rises %0d)", n_flag_rise));
		if (nf == 0) $display("== RC6X SCENARIO %0s %0s PASS", tag, MODE == 0 ? "(rtl)" : "(fault injection)");
		else         $display("== RC6X SCENARIO %0s %0s FAIL (%0d check(s))", tag, MODE == 0 ? "(rtl)" : "(fault injection)", nf);
		$finish;
	end

	initial begin
		#400_000_000;
		$display("== WATCHDOG t=%0d state=%0d copier st=%0d", cyc, u_save.state, u_sc.st);
		$display("== RC6X SCENARIO %0s FAIL (watchdog)", tag);
		$finish;
	end

endmodule

`default_nettype wire
