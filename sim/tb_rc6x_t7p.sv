// tb_rc6x_t7p -- rc6 family X: tb_t7p_flush's T7 replays (hardware test T7,
// 2026-09-30) through the REAL rc6 staging path, with core_top's rc6 glue.
//
// Ported from sim/tb_t7p_flush.sv (which wired rc5's glue: the OR/priority
// mux, host_busy || sc_draining). Here, verbatim from core_top.v rc6: the
// L3 part A write-port arbiter (apf_save_wr, sc_replay cleared by reset_in,
// sc_beat, sc_go, addr/data/bank on sc_go, sc_host_ready), stage_mem's
// host_wr_ready_o as stage_host_ready, host_busy ALONE into the engine (L2),
// the engine's host_rd_i = stage_host_rd (data_unloader's read_en; rc6
// follow-up, via ngpc_machine .host_rd), save_slot_wr = bios_wr_raw && ld_is_save.
// rc6 follow-up monitor, every mode: the committed bank never flips on a
// clock where the read strobe is up, nor between a flush's first read and
// its last.
//
// REAL, unmodified: data_loader, data_unloader, ngpc_stage_mem, psram,
// ngpc_state_cart, ngpc_cart_save (QUIET_CLOCKS 600,000 as the original),
// ngp_cart_overlay_geometry. Or, for the mutation checks, a mutant copy of
// stage_mem or the engine (sim/run_rc6_combo.sh mutants).
//
// MODELED: the CellularRAM chip at the pins, the savestate blob's cart section
// (the bridge's two-register port-A read), the cartridge SDRAM background
// port, the game's flash writes, APF's bridge strobes, slots_settled (shorter
// window), a core reconfiguration (reset_in pulse, stage_bank_o back to its
// power-up 0, PSRAM kept).
//
// Modes (+V=n), as the original:
//   0   prep: produce the pre-T7 file F0 (sim/tb_rc6x_t7p_F0.hex and the
//       PSRAM image sim/tb_rc6x_t7p_psram.hex; the other modes read them)
//   1   one in-game save, Memory loaded after the pass published
//   2   two saves back to back, Memory loaded after everything settled
//   3   Memory load requested right after the save
//   4   Memory load requested while the pass writes header word 17
//   5   the game writes flash again DURING the drain (drain beat 8000)
//   6   APF re-delivers the save slot during the drain (L3: collisions); with
//       +WRGAP=2 +WRBURST=128 +WRPAUSE=3000 in 512-byte bursts at the fastest
//       rate data_loader accepts (a word per 4 clk_74a: WRGAP=1 restarts its
//       shift before the second half is out, and loses it)
//   7   APF flushes (reads) the save slot during the drain (L1)
//   8   flush while a pass writes the build bank, and while an apply reads
//   9   mode 7 with the spare bank poisoned with 0xDEAD (L1: lost drain beats)
//   10  mode 9 with slow single reads (one per 20 us)
//
// rc6 rewrite of the monitors: rc5's 'host writes lost to host reads' counted
// a host read arriving while a popped write was pending -- the rc5 L1 HAZARD
// CONDITION, which with L1 is a harmless wait (kept as rd_wait, info only).
// Real loss is now counted by two scoreboards (ARB: every APF and copier beat
// reaches the skid exactly once; SKID: every skid entry reaches the PSRAM),
// plus the diag_drops counter. The T7 flag (diag_wr_drain, word 23 bit 14) is
// watched as in tb_rc6x_combo; every mode here is RTL-only, so the flag must
// never rise and word 23 bit 14 must never be written.
//
// Each run ends '== RC6X SCENARIO t7p_mode<n> (rtl) PASS' or '... FAIL (n)'.
// Run: wsl -e sh /mnt/c/FPGA/ngpc-rc4/sim/run_rc6_combo.sh

`timescale 1ns / 1ps
`default_nettype none

module tb_rc6x_t7p;

	reg clk_sys = 0;
	reg clk_74a = 0;
	always #10.173 clk_sys = ~clk_sys;   // 49.152 MHz
	always #6.734  clk_74a = ~clk_74a;   // 74.25 MHz

	reg reset_in = 1;

	integer cyc = 0;
	always @(posedge clk_sys) cyc <= cyc + 1;   // nonblocking: one stamp per edge in every block

	localparam integer SLOTW  = 32512;    // .sav, 16-bit words
	localparam integer CARTW  = 16256;    // .sav, 32-bit words
	integer            WR_GAP = 75;       // clk_74a between APF write strobes (+WRGAP)
	// rc6X: +WRBURST=n +WRPAUSE=p delivers in bursts of n 32-bit words at
	// WR_GAP, p clk_74a apart -- APF's measured delivery ran faster than its
	// documented ~1 us per word, and the skid is sized to ride out ~1 KB bursts
	integer            WR_BURST = 0;
	integer            WR_PAUSE = 0;
	integer            RD_GAP = 140;      // clk_74a between APF read strobes
	localparam [19:0]  QUIETP = 20'd600_000;   // > stage_mem HOST_IDLE (500k)
	localparam integer P2_LAT = 6;

	// ---------------- APF bridge ------------------------------------------
	reg         bridge_wr = 0;
	reg         bridge_rd = 0;
	reg  [31:0] bridge_addr = 32'hF8000000;
	reg  [31:0] bridge_wr_data = 0;

	// ---------------- slot loader (core_top bios_loader) ------------------
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

	wire ld_is_save = bios_addr_raw[25];

	// ---------------- flush unloader (core_top stage_drain) ---------------
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

	// ---------------- copier / engine nets --------------------------------
	wire        sc_rd_req, sc_rd_active, sc_draining;
	wire [24:0] sc_rd_addr;
	wire        sc_host_wr, sc_host_ready, stage_host_ready;
	wire [24:0] sc_host_addr;
	wire [15:0] sc_host_data;
	wire        mc_stage_current, mc_stage_bank, mc_state_apply, mc_state_done;
	wire        mc_apply_reject, mc_capture_hold;
	wire [15:0] sc_diag_drain;
	wire        stage_req, stage_we;
	wire [24:0] stage_addr;
	wire [15:0] stage_wdata;
	wire        stage_ready, stage_done;
	wire [15:0] stage_rdata;
	wire        host_busy;
	wire [15:0] stage_diag_beats, stage_diag_drops;

	// core_top.v (rc6), verbatim: the L3 part A write-port arbiter
	wire        apf_save_wr = bios_wr_raw && ld_is_save;
	reg         sc_replay   = 1'b0;
	wire        sc_beat     = sc_host_wr || sc_replay;
	wire        sc_go       = sc_beat && !apf_save_wr;
	always @(posedge clk_sys) sc_replay <= !reset_in && sc_beat && apf_save_wr;
	wire        stage_host_wr      = apf_save_wr || sc_beat;
	wire [27:0] stage_host_wr_addr = sc_go ? {3'd0, sc_host_addr}
	                                       : {3'd0, bios_addr_raw[24:0]};
	wire [15:0] stage_host_wr_data = sc_go ? sc_host_data : bios_data_raw;
	wire        stage_wr_bank      = sc_go ? ~mc_stage_bank : mc_stage_bank;
	assign      sc_host_ready      = stage_host_ready && !sc_replay &&
	                                 !(sc_host_wr && apf_save_wr);

	wire [21:16] cram_a;
	wire [15:0]  cram_dq;
	wire cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n;
	wire cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;

	ngpc_stage_mem stage_mem (
		.active_bank_i (mc_stage_bank),
		.host_wr_bank_i(stage_wr_bank),
		.clk  (clk_sys),
		.reset(reset_in),
		.host_wr_i     (stage_host_wr),
		.host_wr_addr_i(stage_host_wr_addr[24:0]),
		.host_wr_data_i(stage_host_wr_data),
		.host_rd_i     (stage_host_rd),
		.host_rd_addr_i(stage_host_rd_addr[24:0]),
		.host_rd_data_o(stage_host_rd_data),
		.host_busy_o(host_busy),
		.host_wr_ready_o(stage_host_ready),
		.diag_beats_o(stage_diag_beats),
		.diag_drops_o(stage_diag_drops),
		.eng_req_i  (sc_rd_active ? sc_rd_req : stage_req),
		.eng_we_i   (sc_rd_active ? 1'b0 : stage_we),
		.eng_addr_i (sc_rd_active ? (sc_rd_addr | {8'd0, mc_stage_bank, 16'd0}) : stage_addr),
		.eng_wdata_i(stage_wdata),
		.eng_ready_o(stage_ready),
		.eng_done_o (stage_done),
		.eng_rdata_o(stage_rdata),
		.cram_a(cram_a), .cram_dq(cram_dq), .cram_wait(1'b0), .cram_clk(cram_clk),
		.cram_adv_n(cram_adv_n), .cram_cre(cram_cre), .cram_ce0_n(cram_ce0_n),
		.cram_ce1_n(cram_ce1_n), .cram_oe_n(cram_oe_n), .cram_we_n(cram_we_n),
		.cram_ub_n(cram_ub_n), .cram_lb_n(cram_lb_n)
	);

	// ---------------- CellularRAM chip (async mode) ------------------------
	// Writes as tb_stage_host models them (commit on we_n rising with the
	// previous cycle's values); reads drive dq while oe_n and ce0_n are low.
	reg [15:0] cmem [0:131071];
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
		end
	end
	assign cram_dq = (!cram_oe_n && !cram_ce0_n) ? cmem[c_addr_l[16:0]] : 16'hzzzz;

	// ---------------- savestate blob cart section (bridge stand-in) --------
	reg         cs_save_req = 0, cs_load_req = 0;
	wire        cs_save_done, cs_load_done, cs_load_error, cs_img_wr;
	wire [13:0] cs_img_addr, cs_img_rd_addr;
	wire [31:0] cs_img_data, cs_img_rd_data;

	reg [31:0] blob_img [0:16383];   // the state being loaded
	reg [31:0] cap_img  [0:16383];   // the last capture
	reg [13:0] b_ra = 0;
	reg [31:0] b_rd = 0;
	always @(posedge clk_sys) begin
		b_ra <= cs_img_rd_addr;          // bridge: seq_pa_addr register
		b_rd <= blob_img[b_ra];          // bridge: a_q register
		if (cs_img_wr) cap_img[cs_img_addr] <= cs_img_data;
	end
	assign cs_img_rd_data = b_rd;

	ngpc_state_cart state_cart (
		.clk  (clk_sys),
		.reset(reset_in),
		.cart_save_req   (cs_save_req),
		.cart_save_done  (cs_save_done),
		.cart_img_wr     (cs_img_wr),
		.cart_img_addr   (cs_img_addr),
		.cart_img_data   (cs_img_data),
		.cart_load_req   (cs_load_req),
		.cart_load_done  (cs_load_done),
		.cart_load_error (cs_load_error),
		.cart_img_rd_addr(cs_img_rd_addr),
		.cart_img_rd_data(cs_img_rd_data),
		.sc_rd_req   (sc_rd_req),
		.sc_rd_addr  (sc_rd_addr),
		.sc_rd_ready (stage_ready),
		.sc_rd_done  (stage_done),
		.sc_rd_data  (stage_rdata),
		.sc_rd_active(sc_rd_active),
		.draining_o  (sc_draining),
		.sc_host_wr  (sc_host_wr),
		.sc_host_ready(sc_host_ready),
		.sc_host_addr(sc_host_addr),
		.sc_host_data(sc_host_data),
		.stage_current_i(mc_stage_current),
		.apply_reject_i (mc_apply_reject),
		.state_apply_o  (mc_state_apply),
		.state_done_i   (mc_state_done),
		.diag_drain_o   (sc_diag_drain),
		.hold_o         (mc_capture_hold)
	);

	// ---------------- cartridge SDRAM background port ----------------------
	reg  [15:0] flash [0:1048575];     // die0, 16 Mbit
	wire        p2_req, p2_we;
	wire [24:0] p2_addr;
	wire [15:0] p2_wdata;
	wire  [1:0] p2_be;
	reg         p2_ready = 1, p2_done = 0;
	reg  [15:0] p2_rdata = 0;
	reg   [3:0] p2_cnt = 0;
	reg         p2_we_q = 0;
	reg  [19:0] p2_a_q = 0;
	reg  [15:0] p2_wd_q = 0;
	integer     n_p2wr = 0;
	always @(posedge clk_sys) begin
		p2_done <= 1'b0;
		if (p2_req) begin
			p2_ready <= 1'b0;
			p2_cnt   <= P2_LAT;
			p2_we_q  <= p2_we;
			p2_a_q   <= p2_addr[20:1];
			p2_wd_q  <= p2_wdata;
			if (p2_we) n_p2wr = n_p2wr + 1;
		end else if (p2_cnt != 0) begin
			p2_cnt <= p2_cnt - 4'd1;
			if (p2_cnt == 4'd1) begin
				if (p2_we_q) flash[p2_a_q] <= p2_wd_q;
				else         p2_rdata      <= flash[p2_a_q];
				p2_done  <= 1'b1;
				p2_ready <= 1'b1;
			end
		end
	end

	// ---------------- slots_settled (core_top logic, shorter window) -------
	localparam [25:0] SETTLE = 26'd100_000;
	reg [25:0] slot_idle = 0;
	always @(posedge clk_74a) begin
		if (bridge_wr && bridge_addr[31:28] == 4'h1) slot_idle <= 26'd0;
		else if (slot_idle != SETTLE)                slot_idle <= slot_idle + 26'd1;
	end
	reg ss1 = 0, ss2 = 0, slots_settled = 0;
	always @(posedge clk_sys) begin
		ss1 <= (slot_idle == SETTLE); ss2 <= ss1; slots_settled <= ss2;
	end

	// ---------------- the save engine --------------------------------------
	reg        cart_ready = 0, cart_replace = 0;
	reg        event0 = 0;
	reg  [5:0] block0 = 0;
	reg  [1:0] die_busy = 0;
	wire       boot_hold, save_busy, save_present, frozen;

	ngpc_cart_save #(
		.QUIET_CLOCKS(QUIETP)
	) cart_save (
		.clk  (clk_sys),
		.reset(reset_in),
		.cart_ready_i  (cart_ready),
		.cart_replace_i(cart_replace),
		.cart_crc32_i  (32'h94B63A97),
		.cart_bytes_i  (25'h0200000),
		.cart_title_i  (96'h5F434F4F5243435347494643),
		.cart_catalog_i(16'h0027),
		.cart_subcat_i (8'h03),
		.size_code0_i  (2'd3),
		.size_code1_i  (2'd0),
		.event0_i      (event0),
		.block0_i      (block0),
		.event1_i      (1'b0),
		.block1_i      (6'd0),
		.die_busy_i    (die_busy),
		.host_busy_i   (host_busy),                      // core_top rc6: the host port alone (L2)
		.host_rd_i     (stage_host_rd),                  // core_top rc6: stage_host_rd -> ngpc_machine .host_rd
		.state_apply_i (mc_state_apply),
		.draining_i    (sc_draining),
		.state_frozen_i(1'b0),
		.state_fail_i  (1'b0),
		.frozen_o      (frozen),
		.save_slot_wr_i(bios_wr_raw && ld_is_save),       // core_top: .save_slot_wr
		.apply_reject_o(mc_apply_reject),
		.state_done_o  (mc_state_done),
		.slots_settled_i(slots_settled),
		.diag_beats_i  (stage_diag_beats),
		.diag_drops_i  (stage_diag_drops),
		.diag_drain_i  (sc_diag_drain),
		.boot_hold_o   (boot_hold),
		.busy_o        (save_busy),
		.save_present_o(save_present),
		.stage_current_o(mc_stage_current),
		.stage_bank_o  (mc_stage_bank),
		.p2_req_o  (p2_req),
		.p2_we_o   (p2_we),
		.p2_addr_o (p2_addr),
		.p2_wdata_o(p2_wdata),
		.p2_be_o   (p2_be),
		.p2_ready_i(p2_ready),
		.p2_done_i (p2_done),
		.p2_rdata_i(p2_rdata),
		.stage_req_o  (stage_req),
		.stage_we_o   (stage_we),
		.stage_addr_o (stage_addr),
		.stage_wdata_o(stage_wdata),
		.stage_ready_i(stage_ready),
		.stage_done_i (stage_done),
		.stage_rdata_i(stage_rdata)
	);

	// =======================================================================
	// Monitors
	// =======================================================================
	integer errors = 0;
	integer eng_ready_mid_drain = 0;   // eng_ready while drain beats 8..32504
	integer eng_req_mid_drain   = 0;
	integer skid_max            = 0;
	integer hdr18_samples       = 0;
	integer hdr18_in_drain      = 0;
	integer drain_rise_not_idle = 0;
	integer rd_lat_max          = 0;   // host_rd_i rise -> host data landed
	integer rd_lat_cnt          = 0;
	integer rd_stale            = 0;   // unloader sampled before the data landed
	reg     rd_wait             = 0;
	reg     rd_q                = 0;
	reg     drn_q               = 0;
	reg     bank_q              = 0;
	integer foreign_in_drained  = 0;   // non-drain writes into the bank being drained
	reg     drain_bank          = 0;
	reg     drain_window        = 0;   // draining, or the skid still flushing it
	integer p2wr_mark           = 0;
	wire [4:0] est = cart_save.state;

	always @(posedge clk_sys) begin
		if (!reset_in) begin
			if (stage_mem.skid_fill > skid_max) skid_max = stage_mem.skid_fill;

			if (sc_draining && sc_diag_drain > 16'd8 && sc_diag_drain < 16'd32504) begin
				if (stage_ready) eng_ready_mid_drain = eng_ready_mid_drain + 1;
				if (stage_req && !sc_rd_active) eng_req_mid_drain = eng_req_mid_drain + 1;
			end

			// Every S_STAGE_HDR sample of word 18 (the value it will write).
			if (cart_save.state == 5'd6 && stage_ready && cart_save.hdr_idx == 6'd18) begin
				hdr18_samples = hdr18_samples + 1;
				if (sc_draining) hdr18_in_drain = hdr18_in_drain + 1;
				$display("%10t   engine samples hdr word 18 = 0x%04h (drain=%0d beats=%0d draining=%b build_bank=%0d)",
				         $time, sc_diag_drain, sc_diag_drain, stage_diag_beats, sc_draining, !mc_stage_bank);
			end

			if (sc_draining && !drn_q) begin
				drain_bank   = !mc_stage_bank;
				drain_window = 1;
				if (cart_save.state != 5'd0) drain_rise_not_idle = drain_rise_not_idle + 1;
				$display("%10t   draining rises: engine state=%0d stage_pending=%b spare(drain) bank=%0d",
				         $time, cart_save.state, cart_save.stage_pending, !mc_stage_bank);
			end
			if (!sc_draining && drn_q)
				$display("%10t   draining falls (drain beats=%0d)", $time, sc_diag_drain);
			drn_q = sc_draining;
			if (drain_window && !sc_draining && stage_mem.skid_empty && !stage_mem.host_pending)
				drain_window = 0;

			if (mc_stage_bank != bank_q)
				$display("%10t   stage_bank %0d -> %0d (engine state=%0d, from_state=%b)",
				         $time, bank_q, mc_stage_bank, cart_save.state, cart_save.from_state);
			bank_q = mc_stage_bank;

			// PSRAM write issue, by source: any engine write into the bank the
			// drain is filling, while the drain owns it.
			if (!stage_mem.ps_busy && !stage_mem.ps_write_en && !stage_mem.ps_read_en &&
			    !stage_mem.host_pending && stage_mem.eng_req_i && stage_mem.eng_we_i &&
			    drain_window && stage_mem.eng_addr_i[16] == drain_bank) begin
				foreign_in_drained = foreign_in_drained + 1;
				$display("%10t   ENGINE WRITE into the drained bank: word %0d = 0x%04h",
				         $time, stage_mem.eng_addr_i[15:1], stage_mem.eng_wdata_i);
			end


			// Flush-read latency against the unloader's fixed 32-clock sample.
			if (stage_host_rd && !rd_q) begin rd_wait = 1; rd_lat_cnt = 0; end
			if (rd_wait) begin
				rd_lat_cnt = rd_lat_cnt + 1;
				if (stage_mem.ps_read_avail && !(stage_mem.eng_active && stage_mem.eng_active_rd)) begin
					rd_wait = 0;
					if (rd_lat_cnt > rd_lat_max) rd_lat_max = rd_lat_cnt;
				end
			end
			if (!stage_host_rd && rd_q && rd_wait) begin
				rd_stale = rd_stale + 1;
				rd_wait  = 0;
			end
			rd_q = stage_host_rd;
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
				qa[qa_w % QN] = {mc_stage_bank, bios_addr_raw[15:1], bios_data_raw};
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
				if (stage_mem.skid_full === 1'b1) arb_drop = arb_drop + 1;
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
			if (stage_mem.host_wr_i === 1'b1 && stage_mem.skid_full !== 1'b1 && stage_mem.host_wr_in_bank === 1'b1) begin
				qs[qs_w % QN] = {stage_mem.host_wr_word[15:0], stage_mem.host_wr_data_i};
				qs_w = qs_w + 1;
				skid_pushes = skid_pushes + 1;
			end
			if (stage_mem.host_pending === 1'b1 && stage_mem.host_pending_rd === 1'b0 && stage_host_rd === 1'b1)
				n_rd_wait = n_rd_wait + 1;
			if (stage_mem.ps_busy === 1'b0 && stage_mem.ps_write_en === 1'b0 && stage_mem.ps_read_en === 1'b0 &&
			    stage_mem.host_pending === 1'b1 && stage_mem.host_pending_rd === 1'b0) begin
				v = {stage_mem.host_pending_addr[15:0], stage_mem.host_pending_data};
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
		if ((cart_save.diag_wr_drain === 1'b1) !== (engwr_epoch > 0)) begin
			n_flag_incons = n_flag_incons + 1;
			if (n_flag_incons <= 4) $display("   [%0d] T7 FLAG: diag_wr_drain %b but %0d engine writes while draining this epoch",
			                                  cyc, cart_save.diag_wr_drain, engwr_epoch);
		end
		if (cart_save.diag_wr_drain === 1'b1 && flag_q !== 1'b1) begin
			n_flag_rise = n_flag_rise + 1;
			$display("   [%0d] T7 FLAG: diag_wr_drain rises (engine state %0d, hdr_idx %0d, drain %0d)",
			         cyc, est, cart_save.hdr_idx, sc_diag_drain);
		end
		flag_q = (cart_save.diag_wr_drain === 1'b1);
		if (reset_in === 1'b1 || cart_replace === 1'b1) engwr_epoch = 0;
		else if (stage_req === 1'b1 && stage_we === 1'b1 && sc_draining === 1'b1) begin
			engwr_epoch = engwr_epoch + 1;
			n_eng_wr_drain = n_eng_wr_drain + 1;
		end
		if (reset_in !== 1'b1 && stage_req === 1'b1 && stage_we === 1'b1 && sc_rd_active !== 1'b1 &&
		    stage_addr[15:1] == 15'd23) begin
			n_w23_eng = n_w23_eng + 1;
			if (stage_wdata[14] !== cart_save.diag_wr_drain) begin
				n_w23_bad = n_w23_bad + 1;
				$display("   [%0d] T7 FLAG: engine writes word 23 = %h with the flag %b", cyc, stage_wdata, cart_save.diag_wr_drain);
			end
		end
		// anyone writing header word 23 with bit 14 set, at the PSRAM
		if (reset_in !== 1'b1 && stage_mem.ps_write_en === 1'b1 && stage_mem.ps_addr[14:0] == 15'd23 &&
		    stage_mem.ps_data_in[14] === 1'b1) begin
			n_w23_b14 = n_w23_b14 + 1;
			if (n_w23_b14 <= 4) $display("   [%0d] T7 FLAG: word 23 = %h written to bank %0d by %0s", cyc,
			                             stage_mem.ps_data_in, stage_mem.ps_addr[15],
			                             (stage_mem.eng_active === 1'b1 && stage_mem.eng_active_rd !== 1'b1) ? "ENGINE" : "HOST");
		end
	end

	// ---- rc6 follow-up: no committed-bank flip under APF's read strobe ------
	// A flip seen at sample t was made at the edge before it, where the engine
	// saw the strobe as sampled at t-1. Nor any flip between a flush's first
	// read and its last (a file of two images).
	reg     fl_live = 1'b0, fl_rd_seen = 1'b0;
	reg     fm_bank_q = 1'b0, fm_rd_q = 1'b0, fm_live_q = 1'b0;
	integer n_flip_in_rd = 0, n_flip_in_flush = 0;
	always @(posedge clk_sys) begin : flipmon
		if (reset_in !== 1'b1 && fm_bank_q !== mc_stage_bank && mc_stage_bank !== 1'bx) begin
			if (fm_rd_q) begin
				n_flip_in_rd = n_flip_in_rd + 1;
				$display("   [%0d] FLIP MONITOR: committed bank -> %0d on a clock where APF's read strobe was up (engine state %0d)",
				         cyc, mc_stage_bank, est);
			end
			if (fm_live_q) begin
				n_flip_in_flush = n_flip_in_flush + 1;
				$display("   [%0d] FLIP MONITOR: committed bank -> %0d in the middle of an APF flush (engine state %0d)",
				         cyc, mc_stage_bank, est);
			end
		end
		if (fl_live && stage_host_rd === 1'b1) fl_rd_seen = 1'b1;
		fm_bank_q = mc_stage_bank;
		fm_rd_q   = (stage_host_rd === 1'b1);
		fm_live_q = fl_live && fl_rd_seen;
	end

	// =======================================================================
	// Stimulus helpers
	// =======================================================================
	reg [15:0] f0    [0:SLOTW-1];   // the pre-T7 file (from mode 0)
	reg [15:0] mimg  [0:SLOTW-1];   // the T7 Memory's embedded image
	reg [15:0] fout  [0:SLOTW-1];   // a flushed file
	reg [15:0] s0    [0:16383];     // save data, blocks 32..34 of die0
	integer rf_diff = -1, rf_ndiag = -1, cb_diff = -1;
	integer mid_bad = -1, dead_drained = -1, dead_any = -1, fl1_diff = -1, fl2_diff = -1;
	integer lat1 = -1, stale1 = -1, lat2 = -1, stale2 = -1;
	reg [15:0] ld_verdict = 16'hxxxx, ap_verdict = 16'hxxxx;
	reg        dr_bank = 0;
	integer nf = 0;
	string  tag = "";   // +TAG (the run script's scenario name), else t7p_mode<n>
	task chk(input ok, input string what);
		begin
			if (ok !== 1'b1) begin
				nf = nf + 1;
				$display("   CHECK FAIL: %0s", what);
			end
		end
	endtask
	integer i, k, mode;

	function [15:0] sdat(input integer n);
		reg [15:0] v;
		begin
			v = (n * 16'h9E37) ^ 16'h1234;
			if (v == 16'hFFFF || v == 16'h2005) v = 16'h0101;
			sdat = v;
		end
	endfunction

	task make_save_data;
		begin
			for (k = 0; k < 16384; k = k + 1) begin
				if (((k % 64) < 40) && ((k < 6000) || (k >= 8192 && k < 9000) ||
				                        (k >= 12288 && k < 14000)))
					s0[k] = sdat(k);
				else
					s0[k] = 16'hFFFF;
			end
		end
	endtask

	task reconfigure;   // a new core launch: every register cold, PSRAM kept
		begin
			reset_in <= 1'b1;
			cart_ready <= 1'b0;
			repeat (20) @(posedge clk_sys);
			cart_save.stage_bank_o = 1'b0;        // its power-up value
			slot_idle = 26'd0;
			// the cartridge image arrives pristine: the save blocks erased
			for (k = 0; k < 16384; k = k + 1) flash[20'hFC000 + k] = 16'hFFFF;
			repeat (5) @(posedge clk_sys);
			reset_in <= 1'b0;
			repeat (5) @(posedge clk_sys);
			cart_replace <= 1'b1;
			@(posedge clk_sys);
			cart_replace <= 1'b0;
			repeat (50) @(posedge clk_sys);
			cart_ready <= 1'b1;
		end
	endtask

	task apf_deliver;   // the save slot, as APF streams it (data_loader)
		integer j;
		begin
			for (j = 0; j < CARTW; j = j + 1) begin
				@(posedge clk_74a);
				bridge_addr    <= 32'h12000000 + j*4;
				bridge_wr_data <= {f0[2*j][7:0], f0[2*j][15:8], f0[2*j+1][7:0], f0[2*j+1][15:8]};
				bridge_wr      <= 1'b1;
				@(posedge clk_74a);
				bridge_wr      <= 1'b0;
				repeat (WR_GAP) @(posedge clk_74a);
				if (WR_BURST > 0 && ((j + 1) % WR_BURST) == 0) repeat (WR_PAUSE) @(posedge clk_74a);
			end
			@(posedge clk_74a);
			bridge_addr <= 32'hF8000000;
		end
	endtask

	task apf_flush;     // the exit flush, as APF reads it (data_unloader)
		integer j;
		reg [31:0] r;
		begin
			fl_rd_seen = 1'b0; fl_live = 1'b1;
			for (j = 0; j < CARTW; j = j + 1) begin
				@(posedge clk_74a);
				bridge_addr <= 32'h12000000 + j*4;
				bridge_rd   <= 1'b1;
				@(posedge clk_74a);
				bridge_rd   <= 1'b0;
				repeat (RD_GAP) @(posedge clk_74a);
				r = stage_bridge_rd_data;
				fout[2*j]   = {r[23:16], r[31:24]};
				fout[2*j+1] = {r[7:0],   r[15:8]};
			end
			fl_live = 1'b0;
			@(posedge clk_74a);
			bridge_addr <= 32'hF8000000;
		end
	endtask

	task wait_settled_and_apply;
		integer t;
		begin
			t = 0;
			while (!slots_settled && t < 4000000) begin @(posedge clk_sys); t = t + 1; end
			// the boot apply runs now; wait for the engine to go idle again
			repeat (20) @(posedge clk_sys);
			t = 0;
			while ((save_busy || boot_hold) && t < 8000000) begin @(posedge clk_sys); t = t + 1; end
			repeat (20) @(posedge clk_sys);
		end
	endtask

	task game_save(input integer tweak);   // one in-game save of s0 (+tweak)
		integer b;
		begin
			die_busy <= 2'b01;
			repeat (400) @(posedge clk_sys);
			for (k = 0; k < 16384; k = k + 1) flash[20'hFC000 + k] = s0[k];
			if (tweak != 0) flash[20'hFC000 + 100] = 16'h4242 + tweak[15:0];
			die_busy <= 2'b00;
			for (b = 32; b <= 34; b = b + 1) begin
				@(posedge clk_sys);
				event0 <= 1'b1; block0 <= b[5:0];
				@(posedge clk_sys);
				event0 <= 1'b0;
				repeat (200) @(posedge clk_sys);
			end
		end
	endtask

	task wait_stager_current(input integer max);
		integer t;
		begin
			t = 0;
			while (!(mc_stage_current && !save_busy) && t < max) begin @(posedge clk_sys); t = t + 1; end
			repeat (5) @(posedge clk_sys);
		end
	endtask

	task capture_memory;
		integer t;
		begin
			@(posedge clk_sys); cs_save_req <= 1'b1;
			@(posedge clk_sys); cs_save_req <= 1'b0;
			t = 0;
			while (!cs_save_done && t < 4000000) begin @(posedge clk_sys); t = t + 1; end
			if (!cs_save_done) begin $display("   FAIL capture never finished"); errors = errors + 1; end
			repeat (5) @(posedge clk_sys);
			for (k = 0; k < CARTW; k = k + 1) begin
				mimg[2*k]   = cap_img[k][15:0];
				mimg[2*k+1] = cap_img[k][31:16];
				blob_img[k] = cap_img[k];
			end
			$display("%10t   Memory captured: image w16=%04h w18=%04h w22=%04h w23=%04h w24=%04h",
			         $time, mimg[16], mimg[18], mimg[22], mimg[23], mimg[24]);
		end
	endtask

	// cs_load_done is a one-clock pulse; a wait that starts after it (mode 7
	// waits after its flush) must still see it.
	reg ld_seen = 0, ld_err = 0;
	always @(posedge clk_sys) if (cs_load_done) begin ld_seen <= 1'b1; ld_err <= cs_load_error; end

	task load_memory_req;
		begin
			ld_seen = 0; ld_err = 0;
			@(posedge clk_sys); cs_load_req <= 1'b1;
			@(posedge clk_sys); cs_load_req <= 1'b0;
			$display("%10t   Memory load requested (engine state=%0d stage_pending=%b hdr_idx=%0d)",
			         $time, cart_save.state, cart_save.stage_pending, cart_save.hdr_idx);
		end
	endtask

	task wait_load_done;
		integer t;
		begin
			t = 0;
			while (!ld_seen && t < 20000000) begin @(posedge clk_sys); t = t + 1; end
			if (!ld_seen) begin $display("   FAIL load never finished"); errors = errors + 1; end
			else $display("%10t   Memory load done, error=%b, verdict=%04h applies=%0d",
			              $time, ld_err, cart_save.diag_verdict, cart_save.diag_applies);
			ld_verdict = cart_save.diag_verdict;
			@(posedge clk_sys);
		end
	endtask

	task report_file(input string what, input integer vs_m);
		integer d, first;
		begin
			d = 0; first = -1;
			for (k = 0; k < SLOTW; k = k + 1)
				if ((vs_m ? mimg[k] : f0[k]) !== fout[k]) begin
					if (first < 0) first = k;
					if (d < 6) $display("      word %0d: file %04h, expected %04h", k,
					                    fout[k], vs_m ? mimg[k] : f0[k]);
					d = d + 1;
				end
			rf_diff = d;
			rf_ndiag = 0;
			for (k = 0; k < SLOTW; k = k + 1)
				if (!(k == 16 || k == 17 || k == 18 || k == 22 || k == 23 || k == 24) &&
				    (vs_m ? mimg[k] : f0[k]) !== fout[k]) rf_ndiag = rf_ndiag + 1;
			$display("   %0s: w16=%04h w17=%04h w18=%04h w19=%04h w20=%04h w22=%04h w23=%04h w24=%04h; %0d words differ from the %0s",
			         what, fout[16], fout[17], fout[18], fout[19], fout[20], fout[22], fout[23], fout[24],
			         d, vs_m ? "Memory image" : "pre-T7 file");
		end
	endtask

	task compare_bank_to_m(input integer bank, input string what);
		integer d;
		begin
			d = 0;
			for (k = 0; k < SLOTW; k = k + 1)
				if (cmem[bank*32768 + k] !== mimg[k]) begin
					if (d < 4) $display("      bank %0d word %0d: %04h, Memory %04h", bank, k,
					                    cmem[bank*32768 + k], mimg[k]);
					d = d + 1;
				end
			cb_diff = d;
			$display("   %0s: PSRAM bank %0d vs Memory image: %0d words differ (w18=%04h)",
			         what, bank, d, cmem[bank*32768 + 18]);
		end
	endtask

	task monitors_summary;
		begin
			$display("   monitors: skid max fill %0d; eng_ready mid-drain %0d cycles; engine requests mid-drain %0d;",
			         skid_max, eng_ready_mid_drain, eng_req_mid_drain);
			$display("             hdr18 samples %0d (%0d while draining); draining rose with engine not idle %0d;",
			         hdr18_samples, hdr18_in_drain, drain_rise_not_idle);
			$display("             engine writes into the drained bank %0d; flush read latency max %0d clk (unloader samples at 32); stale samples %0d",
			         foreign_in_drained, rd_lat_max, rd_stale);
			$display("             counters: beats=%0d drops=%0d drain=%0d applies=%0d verdict=%04h p2wr=%0d",
			         stage_diag_beats, stage_diag_drops, sc_diag_drain, cart_save.diag_applies,
			         cart_save.diag_verdict, cart_save.diag_p2wr);
			$display("             host-write loss %0d (ARB lost %0d unmatched %0d drops %0d owed %0d; SKID lost %0d unmatched %0d owed %0d); collisions %0d, replays %0d; reads that waited behind a pending write %0d clk (info)",
			         host_loss(0), arb_lost, arb_bad, arb_drop, arb_left, skid_lost, skid_bad, skid_left, arb_coll, arb_replays, n_rd_wait);
			$display("             T7 flag: diag_wr_drain %b, rises %0d, engine word-23 writes %0d (bad %0d), word 23 bit 14 written %0d, inconsistencies %0d",
			         cart_save.diag_wr_drain, n_flag_rise, n_w23_eng, n_w23_bad, n_w23_b14, n_flag_incons);
			$display("             committed-bank flips under the read strobe %0d, inside a flush %0d",
			         n_flip_in_rd, n_flip_in_flush);
		end
	endtask

	// A T7 session up to the Memory capture: launch, delivery, boot apply.
	task t7_boot_and_capture;
		begin
			reconfigure;
			$display("%10t   APF delivers the pre-T7 file", $time);
			apf_deliver;
			wait_settled_and_apply;
			$display("%10t   boot apply done: verdict=%04h applies=%0d p2wr=%0d beats=%0d",
			         $time, cart_save.diag_verdict, cart_save.diag_applies, cart_save.diag_p2wr,
			         stage_diag_beats);
			capture_memory;
		end
	endtask

	task quit_and_flush(input string what);
		begin
			$display("%10t   quit: APF flushes the committed bank %0d", $time, mc_stage_bank);
			apf_flush;
			report_file(what, 1);
			compare_bank_to_m(mc_stage_bank, "  committed");
			monitors_summary;
		end
	endtask

	// =======================================================================
	// Main
	// =======================================================================
	integer t, bad;

	initial begin
		if (!$value$plusargs("V=%d", mode)) mode = 1;
		if (!$value$plusargs("TAG=%s", tag)) tag = $sformatf("t7p_mode%0d", mode);
		if ($value$plusargs("RDGAP=%d", t)) RD_GAP = t;
		if ($value$plusargs("WRGAP=%d", t)) WR_GAP = t;
		if ($value$plusargs("WRBURST=%d", t)) WR_BURST = t;
		if ($value$plusargs("WRPAUSE=%d", t)) WR_PAUSE = t;
		for (k = 0; k < 131072; k = k + 1) cmem[k] = 16'hCCCC;
		for (k = 0; k < 1048576; k = k + 1) flash[k] = 16'hFFFF;
		for (k = 0; k < 16384; k = k + 1) blob_img[k] = 32'd0;
		make_save_data;

		if (mode == 0) begin
			// ---- prep: produce the pre-T7 file ----------------------------
			$display("== mode 0: produce the pre-T7 file");
			reconfigure;
			repeat (200) @(posedge clk_sys);
			wait_settled_and_apply;          // nothing delivered
			game_save(0);
			wait_stager_current(6000000);
			for (k = 0; k < SLOTW; k = k + 1) f0[k] = 16'h0;
			apf_flush;
			for (k = 0; k < SLOTW; k = k + 1) f0[k] = fout[k];
			$display("   F0a: w16=%04h w18=%04h w22=%04h w23=%04h w24=%04h", f0[16], f0[18], f0[22], f0[23], f0[24]);
			reconfigure;
			apf_deliver;
			wait_settled_and_apply;
			game_save(0);
			wait_stager_current(6000000);
			apf_flush;
			for (k = 0; k < SLOTW; k = k + 1) f0[k] = fout[k];
			$display("   F0 : w0..3=%04h %04h %04h %04h w10=%04h w16=%04h w18=%04h w19=%04h w20=%04h w21=%04h w22=%04h w23=%04h w24=%04h",
			         f0[0], f0[1], f0[2], f0[3], f0[10], f0[16], f0[18], f0[19], f0[20], f0[21], f0[22], f0[23], f0[24]);
			// +NOWRITE=1 (the mutation runs): leave the real build's prep files alone
			if (!$test$plusargs("NOWRITE")) begin
				$writememh("sim/tb_rc6x_t7p_F0.hex", f0);
				$writememh("sim/tb_rc6x_t7p_psram.hex", cmem);
			end
			monitors_summary;
			$display("== mode 0 done");
			chk(f0[0] === 16'h4E47 && f0[1] === 16'h5043 && f0[2] === 16'h5341 && f0[3] === 16'h5634, "F0 lacks the magic");
			chk(f0[21] === 16'h0603, $sformatf("F0 word 21 = %04h, want 0603 (writer rev 06)", f0[21]));
			chk(f0[23] === 16'h0001, $sformatf("F0 word 23 = %04h, want 0001 (accepted, no T7 flag)", f0[23]));
			common_checks;
			verdict_line;
			$finish;
		end

		$readmemh("sim/tb_rc6x_t7p_F0.hex", f0);
		$readmemh("sim/tb_rc6x_t7p_psram.hex", cmem);   // PSRAM as the last session left it
		$display("== mode %0d (RD_GAP %0d)", mode, RD_GAP);

		case (mode)
		1: begin
			$display("-- T7: one in-game save, Memory loaded after the pass published");
			t7_boot_and_capture;
			game_save(0);
			wait_stager_current(6000000);
			$display("%10t   pass published; committed bank %0d", $time, mc_stage_bank);
			repeat (20000) @(posedge clk_sys);
			load_memory_req;
			wait_load_done;
			repeat (300000) @(posedge clk_sys);   // play
			quit_and_flush("T7-1 quit file");
		end
		2: begin
			$display("-- T7: two saves back to back (second while pass 1 writes its header)");
			t7_boot_and_capture;
			game_save(0);
			t = 0;
			while (!(cart_save.state == 5'd6 && cart_save.hdr_idx == 6'd10) && t < 6000000) begin @(posedge clk_sys); t = t + 1; end
			$display("%10t   pass 1 at header word 10: second save", $time);
			game_save(0);
			wait_stager_current(8000000);
			$display("%10t   stager current; committed bank %0d", $time, mc_stage_bank);
			repeat (20000) @(posedge clk_sys);
			load_memory_req;
			wait_load_done;
			repeat (300000) @(posedge clk_sys);
			quit_and_flush("T7-2 quit file");
		end
		3: begin
			$display("-- T7: Memory load requested right after the save");
			t7_boot_and_capture;
			game_save(0);
			repeat (1000) @(posedge clk_sys);
			load_memory_req;
			wait_load_done;
			repeat (300000) @(posedge clk_sys);
			quit_and_flush("T7-3 quit file");
		end
		4: begin
			$display("-- T7: Memory load requested while the pass writes header word 17");
			t7_boot_and_capture;
			game_save(0);
			t = 0;
			while (!(cart_save.state == 5'd6 && cart_save.hdr_idx == 6'd17) && t < 6000000) begin @(posedge clk_sys); t = t + 1; end
			load_memory_req;
			wait_load_done;
			repeat (300000) @(posedge clk_sys);
			quit_and_flush("T7-4 quit file");
		end
		5: begin
			$display("-- T7: the game writes flash again during the drain (at drain beat 8000)");
			t7_boot_and_capture;
			game_save(0);
			wait_stager_current(6000000);
			repeat (20000) @(posedge clk_sys);
			load_memory_req;
			t = 0;
			while (sc_diag_drain < 16'd8000 && t < 6000000) begin @(posedge clk_sys); t = t + 1; end
			fork
				game_save(0);
				wait_load_done;
			join
			repeat (1600000) @(posedge clk_sys);   // long enough for a pass to run
			quit_and_flush("T7-5 quit file");
		end
		6: begin
			$display("-- T7: APF re-delivers the save slot during the drain");
			t7_boot_and_capture;
			game_save(0);
			wait_stager_current(6000000);
			repeat (20000) @(posedge clk_sys);
			load_memory_req;
			t = 0;
			while (!sc_draining && t < 6000000) begin @(posedge clk_sys); t = t + 1; end
			fork
				apf_deliver;
				wait_load_done;
			join
			wait_settled_and_apply;
			repeat (300000) @(posedge clk_sys);
			quit_and_flush("T7-6 quit file");
		end
		7: begin
			$display("-- T7: APF flushes the save slot while the drain runs");
			t7_boot_and_capture;
			game_save(0);
			wait_stager_current(6000000);
			repeat (20000) @(posedge clk_sys);
			load_memory_req;
			t = 0;
			while (!sc_draining && t < 6000000) begin @(posedge clk_sys); t = t + 1; end
			rd_stale = 0;
			apf_flush;          // overlaps the drain for its first ~5 ms
			bad = 0;
			for (k = 0; k < SLOTW; k = k + 1) if (fout[k] !== mimg[k]) bad = bad + 1;
			$display("   flush during the drain: %0d of %0d words wrong, %0d stale unloader samples; w18=%04h",
			         bad, SLOTW, rd_stale, fout[18]);
			mid_bad = bad; stale1 = rd_stale;
			wait_load_done;
			repeat (300000) @(posedge clk_sys);
			rd_stale = 0;
			quit_and_flush("T7-7 quit file");
		end
		8: begin
			$display("-- flush under engine contention: during a pass, and during an apply");
			t7_boot_and_capture;
			game_save(3);      // different data: a pass that publishes a new image
			t = 0;
			while (!(cart_save.state == 5'd4 || cart_save.state == 5'd23) && t < 6000000) begin @(posedge clk_sys); t = t + 1; end
			$display("%10t   pass running (state %0d); APF flush starts", $time, cart_save.state);
			for (k = 0; k < SLOTW; k = k + 1) mimg[k] = cmem[mc_stage_bank*32768 + k];
			rd_stale = 0; rd_lat_max = 0;
			apf_flush;
			report_file("flush during a pass (vs committed bank at start)", 1);
			$display("   flush read latency max %0d clk, stale %0d", rd_lat_max, rd_stale);
			fl1_diff = rf_diff; lat1 = rd_lat_max; stale1 = rd_stale;
			wait_stager_current(8000000);
			// an apply reading the committed bank: re-arm via a short delivery
			reconfigure;
			apf_deliver;
			t = 0;
			while (!slots_settled && t < 4000000) begin @(posedge clk_sys); t = t + 1; end
			t = 0;
			while (!(cart_save.state == 5'd11 || cart_save.state == 5'd12) && t < 4000000) begin @(posedge clk_sys); t = t + 1; end
			$display("%10t   apply running (state %0d); APF flush starts", $time, cart_save.state);
			for (k = 0; k < SLOTW; k = k + 1) mimg[k] = cmem[mc_stage_bank*32768 + k];
			rd_stale = 0; rd_lat_max = 0;
			apf_flush;
			report_file("flush during an apply (vs committed bank at start)", 1);
			$display("   flush read latency max %0d clk, stale %0d; apply verdict %04h", rd_lat_max, rd_stale,
			         cart_save.diag_verdict);
			fl2_diff = rf_diff; lat2 = rd_lat_max; stale2 = rd_stale;
			wait_settled_and_apply;
			ap_verdict = cart_save.diag_verdict;
		end
		9: begin
			$display("-- mode 7 with the spare bank pre-filled with 0xDEAD: what a flush during the drain deletes");
			t7_boot_and_capture;
			game_save(0);
			wait_stager_current(6000000);
			repeat (20000) @(posedge clk_sys);
			for (k = 0; k < 32768; k = k + 1) cmem[(!mc_stage_bank)*32768 + k] = 16'hDEAD;
			load_memory_req;
			t = 0;
			while (!sc_draining && t < 6000000) begin @(posedge clk_sys); t = t + 1; end
			dr_bank = !mc_stage_bank;
			fork
				begin
					apf_flush;
					mid_bad = 0;
					for (k = 0; k < SLOTW; k = k + 1) if (fout[k] !== mimg[k]) mid_bad = mid_bad + 1;
					$display("   flush during the drain: %0d of %0d words differ from the committed image", mid_bad, SLOTW);
				end
				begin
					t = 0;
					while (!ld_seen && t < 20000000) begin @(posedge clk_sys); t = t + 1; end
					$display("%10t   Memory load done, error=%b (apply_reject), verdict=%04h",
					         $time, ld_err, cart_save.diag_verdict);
					ld_verdict = cart_save.diag_verdict;
				end
			join
			bad = 0;
			for (k = 0; k < SLOTW; k = k + 1) if (cmem[dr_bank*32768 + k] == 16'hDEAD) bad = bad + 1;
			$display("   drained bank %0d (committed bank now %0d): %0d words still 0xDEAD, i.e. drain beats lost", dr_bank, mc_stage_bank, bad);
			dead_drained = bad;
			bad = 0;
			for (k = 0; k < SLOTW; k = k + 1) if (cmem[dr_bank*32768 + k] !== mimg[k]) bad = bad + 1;
			$display("   drained bank %0d vs Memory image: %0d words differ", dr_bank, bad);
			if (bad > dead_drained) dead_drained = bad;
			bad = 0;
			for (k = 0; k < SLOTW; k = k + 1) if (cmem[mc_stage_bank*32768 + k] == 16'hDEAD) bad = bad + 1;
			$display("   committed bank %0d: %0d words 0xDEAD", mc_stage_bank, bad);
			monitors_summary;
		end
		10: begin
			$display("-- T7 while APF reads the slot in slow single strobes during the drain (one read per 20 us)");
			t7_boot_and_capture;
			game_save(0);
			wait_stager_current(6000000);
			repeat (20000) @(posedge clk_sys);
			for (k = 0; k < 32768; k = k + 1) cmem[(!mc_stage_bank)*32768 + k] = 16'hDEAD;
			load_memory_req;
			t = 0;
			while (!sc_draining && t < 6000000) begin @(posedge clk_sys); t = t + 1; end
			RD_GAP = 1500;
			fork
				apf_flush;
				begin
					t = 0;
					while (!ld_seen && t < 40000000) begin @(posedge clk_sys); t = t + 1; end
					$display("%10t   Memory load done, error=%b (apply_reject), verdict=%04h",
					         $time, ld_err, cart_save.diag_verdict);
					ld_verdict = cart_save.diag_verdict;
				end
			join
			RD_GAP = 140;
			bad = 0;
			for (k = 0; k < SLOTW; k = k + 1) if (cmem[k] == 16'hDEAD || cmem[32768 + k] == 16'hDEAD) bad = bad + 1;
			$display("   words still 0xDEAD in either bank: %0d", bad);
			dead_any = bad;
			monitors_summary;
		end
		default: $display("unknown mode");
		endcase

		$display("== mode %0d done, %0d bench errors", mode, errors);
		common_checks;
		case (mode)
		1, 2, 3, 4, 6, 7: begin
			chk(ld_seen && !ld_err && ld_verdict === 16'h8001, $sformatf("the load: done %b error %b verdict %04h, want accepted (8001)", ld_seen, ld_err, ld_verdict));
			chk(rf_diff == 0, $sformatf("the quit file differs from the Memory image in %0d words", rf_diff));
			chk(cb_diff == 0, $sformatf("the committed bank differs from the Memory image in %0d words", cb_diff));
		end
		5: begin
			chk(ld_seen && !ld_err && ld_verdict === 16'h8001, $sformatf("the load: done %b error %b verdict %04h, want accepted (8001)", ld_seen, ld_err, ld_verdict));
			chk(rf_ndiag == 0, $sformatf("the quit file differs from the Memory image in %0d non-diagnostic words", rf_ndiag));
			chk(fout[23][14] === 1'b0, "the quit file's word 23 carries the T7 flag");
		end
		8: begin
			chk(fl1_diff == 0 && fl2_diff == 0, $sformatf("a flush under contention differs from the committed bank at its start (pass %0d, apply %0d words)", fl1_diff, fl2_diff));
			chk(lat1 < 32 && lat2 < 32 && stale1 == 0 && stale2 == 0,
			    $sformatf("flush read latency %0d / %0d clk, stale %0d / %0d (the unloader samples at 32)", lat1, lat2, stale1, stale2));
			chk(ap_verdict === 16'h0001, $sformatf("the apply under the flush: verdict %04h, want 0001", ap_verdict));
		end
		9: begin
			chk(ld_seen && !ld_err && ld_verdict === 16'h8001, $sformatf("the load: done %b error %b verdict %04h, want accepted (8001)", ld_seen, ld_err, ld_verdict));
			chk(dead_drained == 0, $sformatf("the drained bank lost %0d words", dead_drained));
			chk(mid_bad == 0, $sformatf("the flush during the drain differs from the committed image in %0d words", mid_bad));
		end
		10: begin
			chk(ld_seen && !ld_err && ld_verdict === 16'h8001, $sformatf("the load: done %b error %b verdict %04h, want accepted (8001)", ld_seen, ld_err, ld_verdict));
			chk(dead_any == 0, $sformatf("%0d words still 0xDEAD", dead_any));
		end
		endcase
		if (mode == 7) chk(mid_bad == 0 && stale1 == 0, $sformatf("the flush during the drain: %0d words wrong, %0d stale", mid_bad, stale1));
		if (mode == 6) chk(stage_diag_beats === 16'd32000,
		                   $sformatf("diag_beats %0d, want 32000 (delivery + drain + re-delivery = 97536 beats, mod 65536)", stage_diag_beats));
		verdict_line;
		$finish;
	end

	// RTL-only invariants, every mode
	task common_checks;
		begin
			sb_settle_check("end");
			chk(errors == 0, $sformatf("%0d bench error(s)", errors));
			chk(host_loss(0) == 0, "host-write loss (see the monitors line)");
			chk(stage_diag_drops === 16'd0, $sformatf("diag_drops = %0d", stage_diag_drops));
			chk(n_flag_rise == 0 && n_w23_b14 == 0 && n_flag_incons == 0 && n_w23_bad == 0,
			    $sformatf("T7 flag: rises %0d, word-23 bit-14 writes %0d, inconsistencies %0d, bad word-23 writes %0d", n_flag_rise, n_w23_b14, n_flag_incons, n_w23_bad));
			chk(foreign_in_drained == 0 && eng_req_mid_drain == 0, $sformatf("engine writes into the drained bank %0d, engine requests mid-drain %0d",
			                                                               foreign_in_drained, eng_req_mid_drain));
			chk(drain_rise_not_idle == 0, "draining rose with the engine not idle");
			chk(rd_stale == 0, $sformatf("%0d stale unloader samples", rd_stale));
			chk(n_flip_in_rd == 0 && n_flip_in_flush == 0,
			    $sformatf("committed-bank flips under APF's read strobe %0d, inside a flush %0d", n_flip_in_rd, n_flip_in_flush));
		end
	endtask

	task verdict_line;
		begin
			if (nf == 0) $display("== RC6X SCENARIO %0s (rtl) PASS", tag);
			else         $display("== RC6X SCENARIO %0s (rtl) FAIL (%0d check(s))", tag, nf);
		end
	endtask

	initial begin
		#2_000_000_000;
		$display("== WATCHDOG");
		$display("== RC6X SCENARIO %0s (rtl) FAIL (watchdog)", tag);
		$finish;
	end

endmodule

`default_nettype wire
