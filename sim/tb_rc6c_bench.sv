// RC6C bench -- rc6 family C (issue L2): an accepted state's commit waits for
// the staging host port, port-free.
//
// Everything on the staging path is the REAL rc6 RTL from target/pocket and
// upstream, compiled unmodified (sim/run_rc6_l2.sh), wired the way rc6
// core_top.v and ngpc_machine.sv wire it:
//
//   target/pocket/ngpc_cart_save.sv   the engine, default QUIET_CLOCKS,
//                                     NGPC_SAVE_DIAG on (the release build)
//       host_busy_i = ngpc_stage_mem host_busy_o, plain   (core_top .host_busy)
//       host_rd_i   = data_unloader read_en, the SAME     (core_top .host_rd
//                     net as ngpc_stage_mem's host_rd_i    (stage_host_rd),
//                                                          machine .host_rd_i)
//       draining_i  = the copier's draining_o             (core_top .draining)
//   target/pocket/ngpc_stage_mem.sv   rc6 L1 (read claim) and L3 part B (ready)
//   core_top.v's rc6 write-port arbiter (L3 part A), VERBATIM between the
//   RC6C-GLUE markers below; run_rc6_l2.sh diffs it against core_top.v
//   target/pocket/ngpc_state_cart.sv, ngpc_savestate_bridge.sv (save_busy_i =
//   the engine's boot_hold_o, as ngpc_machine's save_busy_state, core_top's
//   mc_save_busy, since the rc6 follow-up), data_loader.sv,
//   data_unloader.sv (READ_MEM_CLOCK_DELAY 32), psram.sv,
//   upstream savestates.sv and ngp_cart_overlay_geometry.sv,
//   sim/sim_dcfifo.v and sim/sim_synch3.v (the existing Icarus stand-ins)
//
// MODELED (as tb_t7r_bench.sv / tb_r6c_bench.sv, from which this is adapted):
// the CellularRAM chip at the PSRAM pins, the cartridge SDRAM background port
// (p2, random 2..P2MAX latency), the flash die's reports, the machine behind
// savestates.sv, APF's bridge. slots_settled's counter is SHORTENED.
//
// Session (one per vvp run, chosen with plusargs): reset, cartridge, APF
// delivers a rev-05 file, boot apply; capture a Memory; an in-game save of
// block 34 that a pass publishes; 30 ms later APF loads the Memory: drain
// into the spare bank, state apply, COMMIT (the bank flip this bench is
// about); play; quit (optional flush); optional relaunches.
//
// Scenario knobs:
//   +FLUSHAPPLY=N  APF flushes the WHOLE slot starting N clk_sys after the
//                  copier's state_apply pulse (the drain is over, the apply
//                  runs). Valid only if the flush's reads straddle the point
//                  where the commit would have happened without the rc6 wait
//                  (the first S_FINISH sample of the accepted state apply,
//                  t_fin) -- checked, a non-straddling run fails. On rc6 with
//                  SEED=7, t_fin is state_apply + 447644 (the r6c runs saw rc5
//                  commit at +450977; its skid still held ~500 drain beats
//                  when the apply began, rc6 holds the copier below 32).
//   +HOLDFLUSH=1   with FLUSHAPPLY: the flush is meant to start while the
//                  commit already holds (checked instead of the straddle)
//   +RACEOFS=K     the flush's first bridge read is started when the engine
//                  is holding in S_FINISH and stage_mem.host_idle is K short
//                  of its terminal count: a sweep of the cycle where the
//                  commit and the first read meet.
//   +RACEJ=J       with RACEOFS: J more clk_74a before the flush starts (a
//                  finer phase between the two clocks)
//   +JUNK=1        the Memory is loaded in a NEW session after a power cycle:
//                  no .sav delivered, the PSRAM holding no image, so the
//                  committed bank the state's image replaces is not an image
//                  (word 0 is not the magic); no in-game save
//   +RELAUNCHMID=1 after the session: reset, deliver the file flushed during
//                  the load, boot apply; its verdict must be 0001, unfrozen.
//                  Except a JUNK flush that is wholly the old (junk) bank:
//                  no image, so no boot accepts it (0006, refused and kept),
//                  and none reaches the card -- save_present was low when
//                  the flush began (checked), so core_top never raised the
//                  slot's size and APF writes no file. Skipped ("skip").
//   +FLUSH=2 +RELAUNCH=1  the quit flush and a relaunch on it (verdict 0001).
//   +PUBOFS=K      a different session, the PASS PUBLISH race (no Memory
//                  load): a JUNK power-on session (committed bank no image)
//                  where the game saves block 34 and a pass publishes its
//                  first image over the junk bank. APF flushes the first
//                  MIDWORDS words starting K clk_sys after the pass begins
//                  header word PUBIDX (default 30), so that the first read
//                  strobe meets the pass's publish decision (header word 31
//                  done, host_busy still low). Valid only if it does -- the
//                  strobe is first seen high on the decision edge (checked;
//                  +PUBANY=1 drops the check, for finding K). Then: the flush
//                  is wholly one image, from one bank; the publish happens
//                  (deferred while the port is busy) and the committed bank
//                  is the pass's image.
//
// CHECKS (each failure is a "FAIL" line and counts):
//   load OK, the state apply accepted (word-23 verdict 8001), no reject/freeze
//   exactly one state commit, and only with the host port quiet: host_busy
//     was low where the engine's slot_busy_q sampled it (2 samples before
//     the flip is seen); after a hold, within 2 cycles of host_busy falling
//   no deadlock: the S_FINISH hold never persists 5 samples with host_busy
//     low, and state_done follows state_apply within 200 ms
//   a mid-load flush is wholly one image: every header/payload word that
//     differs between the old committed image and the state's image is the
//     old one throughout or the new one throughout, none neither
//   and it is served from ONE bank: no host read of it from the old bank
//     and another from the new one (split). Failed since the rc6 follow-up
//     (the read strobe in the hold); before it, a first read in the 2 clocks
//     before the flip came from the old bank -- invisible in the content
//     when word 0 is the magic in both images, MIXED in a JUNK session (JR7)
//   the relaunch on it: verdict 0001, not frozen
//   the committed bank at quit is the Memory's image; the quit flush is the
//     committed bank; no skid drops; no PSRAM access past the two banks
//   no mid-load flush: the commit waited for the drain's own host tail --
//     reported as hold_cyc (rc5 committed at t_fin), 0.25..2 ms expected
// REPORTED: the bank each host read of the flush was served from (rd_banks,
// old_last_w = the last word read from the old bank).
//
// OUTPUT: one "== RC6C RESULT" line, then the summary line
// "== ALL RC6C SCENARIOS PASS" or "== N FAILURE(S) ...". Run it with
// vvp -n -N: a failed run ends in $stop, which -N turns into exit code 1.
//
// Run: wsl -e sh sim/run_rc6_l2.sh

`timescale 1ns / 1ps
`default_nettype none

module tb_rc6c;

	// ---- clocks ------------------------------------------------------------
	reg clk_sys = 0;
	reg clk_74a = 0;
	always #10.173 clk_sys = ~clk_sys;   // 49.152 MHz
	always #6.734  clk_74a = ~clk_74a;   // 74.25 MHz

	// Non-blocking, so every monitor at an edge reads the same count.
	integer cyc = 0;
	always @(posedge clk_sys) cyc <= cyc + 1;

	reg reset_in = 1;

	// ---- run parameters (plusargs) -------------------------------------------
	integer P_SAVES    = 1;        // in-game saves before the load (0, 1)
	integer P_DELAYCYC = 0;        // load command, clk_sys after the last event
	integer P_FLUSH    = 0;        // quit flush: 0 none, 1 first 32 words, 2 whole slot
	integer P_RELAUNCH = 0;        // 1: relaunch on the quit flush (needs FLUSH=2)
	integer P_P2MAX    = 10;       // p2 latency 2..P2MAX clocks
	integer P_SEED     = 1;
	integer P_PROGPER  = 60;       // clk_sys between byte programs
	integer P_PLAYUS   = 5000;     // play time between load done and quit
	integer P_FLUSHAPPLY = -1;     // >=0: flush this many clk after state_apply
	integer P_RACEOFS    = -1;     // >=0: flush when host_idle is this short of terminal
	integer P_RELAUNCHMID = 0;     // 1: relaunch on the mid-load flushed file
	integer P_MIDWORDS = 16256;    // 32-bit words the mid-load flush reads
	integer P_RACEJ    = 0;        // RACEOFS: J more clk_74a before the flush starts
	integer P_HOLDFLUSH = 0;       // FLUSHAPPLY: 1 = the flush starts while the commit holds
	integer P_JUNK     = 0;        // 1: load in a fresh power-on session, no .sav delivered,
	                               //    the committed bank holding no image (see below)
	integer P_PUBOFS   = -1;       // >=0: the pass publish race session (see above)
	integer P_PUBIDX   = 30;       // PUBOFS counts from the pass's header word PUBIDX
	integer P_PUBANY   = 0;        // 1: PUBOFS need not meet the publish decision
	integer P_VERBOSE  = 0;
	integer P_DGAP     = 20;       // clk_74a between delivery strobes
	integer P_RGAP     = 200;      // clk_74a between flush reads
	string  P_SCN      = "adhoc";
	string  P_BUILD    = "rtl";
	integer seedv;

	localparam integer SETTLE74 = 150000;   // ~2 ms (core_top: 37,125,000)
	localparam integer HOST_TAIL = 500000;  // ngpc_stage_mem HOST_IDLE_CLOCKS
	localparam integer SD_MAX = 200 * 49152; // state_done within 200 ms of state_apply

	// ---- geometry ------------------------------------------------------------
	localparam integer N_INT    = 112;
	localparam integer SZ0      = 12288;
	localparam integer SZ1      = 4096;
	localparam integer SZ2      = 16384;
	localparam integer CARTB    = 8424;
	localparam integer CARTW    = 16256;
	localparam integer WORDS    = CARTB + CARTW;
	localparam [31:0]  BLOBBASE = 32'h40000000;
	localparam [31:0]  SAVEBASE = 32'h12000000;
	localparam integer SLOTW    = 32512;
	localparam integer BANKW    = 32768;
	localparam integer GAP      = 4;
	localparam integer LOAD_MAX74 = 20000000;
	localparam integer SAVE_MAX74 = 8000000;
	localparam [31:0]  CART_CRC = 32'h94B63A97;
	localparam [24:0]  CART_BYTES = 25'h0200000;
	localparam [95:0]  CART_TITLE = 96'h53524554_48474946_44524143;  // "CARDFIGHTERS"
	localparam [15:0]  CART_CAT   = 16'h0023;
	localparam [7:0]   CART_SUB   = 8'h03;
	localparam integer ERASE_CYC34 = 8192 * 75;   // 16 KB block at 75 clk/word

	// =========================================================================
	// The machine behind the savestate engine (as tb_rc5_loadpath)
	// =========================================================================
	reg [63:0] internals [0:N_INT];
	reg  [7:0] mem0 [0:SZ0-1];
	reg  [7:0] mem1 [0:SZ1-1];
	reg  [7:0] mem2 [0:SZ2-1];

	wire [63:0] eng_bus_din;
	wire  [9:0] eng_bus_adr;
	wire        eng_bus_wren;
	wire        eng_bus_rst;
	wire [63:0] eng_bus_dout = internals[eng_bus_adr];

	wire [24:0] ram_addr;
	wire        ram_rden, ram_wren;
	wire  [7:0] ram_wdata;
	wire  [2:0] ram_type;
	reg   [7:0] ram_rdata_q = 0, ram_rdata_q2 = 0;
	wire  [7:0] ram_rdata = ram_rdata_q2;

	always @(posedge clk_sys) begin
		case (ram_type)
			3'd0:    ram_rdata_q <= mem0[ram_addr[13:0]];
			3'd1:    ram_rdata_q <= mem1[ram_addr[11:0]];
			default: ram_rdata_q <= mem2[ram_addr[13:0]];
		endcase
		ram_rdata_q2 <= ram_rdata_q;
		if (ram_wren) begin
			case (ram_type)
				3'd0:    mem0[ram_addr[13:0]] <= ram_wdata;
				3'd1:    mem1[ram_addr[11:0]] <= ram_wdata;
				default: mem2[ram_addr[13:0]] <= ram_wdata;
			endcase
		end
		if (eng_bus_wren) internals[eng_bus_adr] <= eng_bus_din;
	end

	wire       eng_pause_req;
	wire       mc_capture_hold;
	reg  [2:0] pause_pipe = 3'd0;
	always @(posedge clk_sys) pause_pipe <= {pause_pipe[1:0], (eng_pause_req === 1'b1) || (mc_capture_hold === 1'b1)};
	wire       paused = pause_pipe[2];

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
	) u_ss (
		.clk                     (clk_sys),
		.reset_in                (reset_in),
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

	// =========================================================================
	// APF bridge
	// =========================================================================
	reg         bridge_wr = 0, bridge_rd = 0;
	reg  [31:0] bridge_addr = 32'hF8000000;
	reg  [31:0] bridge_wr_data = 0;
	wire [31:0] savestate_rd_data;
	wire [31:0] stage_bridge_rd_data;

	reg         ss_start_req = 0, ss_load_req = 0;
	wire        start_ack, start_busy, start_ok, start_err;
	wire        load_ack,  load_busy,  load_ok,  load_err;

	wire        cs_save_req, cs_save_done, cs_load_req, cs_load_done, cs_load_error;
	wire        cs_img_wr;
	wire [13:0] cs_img_addr, cs_img_rd_addr;
	wire [31:0] cs_img_data, cs_img_rd_data;
	wire        mc_frozen, ss_load_frozen, ss_load_fail;
	wire        mc_stage_current, mc_save_busy, mc_stage_bank;

	ngpc_savestate_bridge savestate_bridge (
		.clk_sys(clk_sys), .clk_74a(clk_74a), .reset(reset_in),
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
		.bridge_rd_data(savestate_rd_data),
		.ss_save(ss_save), .ss_load(ss_load),
		.ss_busy(ss_busy), .ss_loading(ss_loading),
		.cart_crc32(CART_CRC),
		.cart_save_req   (cs_save_req),
		.cart_save_done  (cs_save_done),
		.cart_img_wr     (cs_img_wr),
		.cart_img_addr   (cs_img_addr),
		.cart_img_data   (cs_img_data),
		.cart_load_req   (cs_load_req),
		.cart_load_done  (cs_load_done),
		.cart_load_error (cs_load_error),
		.frozen_i        (mc_frozen),
		.load_frozen_o   (ss_load_frozen),
		.load_fail_o     (ss_load_fail),
		.save_busy_i     (mc_save_busy),   // core_top: diagnostic only (rc6)
		.cart_img_rd_addr(cs_img_rd_addr),
		.cart_img_rd_data(cs_img_rd_data),
		.bus_out_Din(bus_out_Din), .bus_out_Dout(bus_out_Dout),
		.bus_out_Adr(bus_out_Adr), .bus_out_rnw(bus_out_rnw),
		.bus_out_ena(bus_out_ena), .bus_out_be(bus_out_be),
		.bus_out_done(bus_out_done)
	);

	// ---- the slot loader and the flush unloader, as core_top -----------------
	wire        bios_wr_raw;
	wire [27:0] bios_addr_raw;
	wire [15:0] bios_data_raw;

	data_loader #(
		.ADDRESS_MASK_UPPER_4(4'h1),
		.OUTPUT_WORD_SIZE(2)
	) bios_loader (
		.clk_74a   (clk_74a),
		.clk_memory(clk_sys),
		.bridge_wr          (bridge_wr),
		.bridge_endian_little(1'b0),
		.bridge_addr        (bridge_addr),
		.bridge_wr_data     (bridge_wr_data),
		.write_en  (bios_wr_raw),
		.write_addr(bios_addr_raw),
		.write_data(bios_data_raw)
	);

	wire        stage_host_rd;
	wire [27:0] stage_host_rd_addr;
	wire [15:0] stage_host_rd_data;

	data_unloader #(
		.ADDRESS_MASK_UPPER_4(4'h1),
		.INPUT_WORD_SIZE(2),
		.READ_MEM_CLOCK_DELAY(32)
	) stage_drain (
		.clk_74a   (clk_74a),
		.clk_memory(clk_sys),
		.bridge_rd           (bridge_rd),
		.bridge_endian_little(1'b0),
		.bridge_addr         (bridge_addr),
		.bridge_rd_data      (stage_bridge_rd_data),
		.read_en  (stage_host_rd),
		.read_addr(stage_host_rd_addr),
		.read_data(stage_host_rd_data)
	);

	// slots_settled: core_top's counter, shortened
	wire slot_wr_any = bridge_wr && (bridge_addr[31:28] == 4'h1);
	reg [25:0] slot_idle = 26'd0;
	always @(posedge clk_74a) begin
		if (slot_wr_any)                  slot_idle <= 26'd0;
		else if (slot_idle != SETTLE74)   slot_idle <= slot_idle + 26'd1;
	end
	wire slots_settled_74 = (slot_idle == SETTLE74);
	wire slots_settled;
	synch_3 settle_sync (slots_settled_74, slots_settled, clk_sys);

	// ---- core_top's staging glue ------------------------------------------------
	wire        ld_is_save = bios_addr_raw[25];
	wire        sc_host_wr;
	wire [24:0] sc_host_addr;
	wire [15:0] sc_host_data;
	wire        sc_host_ready;
	wire        stage_host_wr;
	wire        stage_host_ready;
	wire [27:0] stage_host_wr_addr;
	wire [15:0] stage_host_wr_data;
	wire        stage_wr_bank;

	// ---- RC6C-GLUE-BEGIN (core_top.v, rc6 L3 part A; verbatim, diffed by run_rc6_l2.sh)
	wire        apf_save_wr = bios_wr_raw && ld_is_save;
	reg         sc_replay   = 1'b0;
	wire        sc_beat     = sc_host_wr || sc_replay;
	wire        sc_go       = sc_beat && !apf_save_wr;
	always @(posedge clk_sys) sc_replay <= !reset_in && sc_beat && apf_save_wr;
	assign stage_host_wr      = apf_save_wr || sc_beat;
	assign stage_host_wr_addr = sc_go ? {3'd0, sc_host_addr}
	                                  : {3'd0, bios_addr_raw[24:0]};
	assign stage_host_wr_data = sc_go ? sc_host_data : bios_data_raw;
	assign stage_wr_bank      = sc_go ? ~mc_stage_bank : mc_stage_bank;
	assign sc_host_ready      = stage_host_ready && !sc_replay &&
	                            !(sc_host_wr && apf_save_wr);
	// ---- RC6C-GLUE-END

	// core_top: .save_slot_wr(bios_wr_raw && ld_is_save)
	wire        save_slot_wr = bios_wr_raw && ld_is_save;

	wire        stage_req, stage_we;
	wire [24:0] stage_addr;
	wire [15:0] stage_wdata;
	wire        stage_ready, stage_done;
	wire [15:0] stage_rdata;
	wire        host_busy;
	wire [15:0] stage_diag_beats, stage_diag_drops;
	wire        sc_rd_req, sc_rd_active, sc_draining;
	wire [24:0] sc_rd_addr;

	wire [21:16] cram0_a;
	wire [15:0]  cram0_dq;
	wire cram0_clk, cram0_adv_n, cram0_cre, cram0_ce0_n, cram0_ce1_n;
	wire cram0_oe_n, cram0_we_n, cram0_ub_n, cram0_lb_n;

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
		.eng_addr_i (sc_rd_active ? (sc_rd_addr | {8'd0, mc_stage_bank, 16'd0})
		                          : stage_addr),
		.eng_wdata_i(stage_wdata),
		.eng_ready_o(stage_ready),
		.eng_done_o (stage_done),
		.eng_rdata_o(stage_rdata),
		.cram_a    (cram0_a),
		.cram_dq   (cram0_dq),
		.cram_wait (1'b0),
		.cram_clk  (cram0_clk),
		.cram_adv_n(cram0_adv_n),
		.cram_cre  (cram0_cre),
		.cram_ce0_n(cram0_ce0_n),
		.cram_ce1_n(cram0_ce1_n),
		.cram_oe_n (cram0_oe_n),
		.cram_we_n (cram0_we_n),
		.cram_ub_n (cram0_ub_n),
		.cram_lb_n (cram0_lb_n)
	);

	// ---- behavioral CellularRAM (async mode) at the pins ----------------------
	reg [15:0] cmem [0:65535];
	reg [21:0] c_addr_l = 0;
	reg        p_we = 1, p_ce = 1, p_ub = 1, p_lb = 1;
	reg [15:0] p_dq = 0;
	reg [21:0] p_addr = 0;
	reg        chip_oob = 0;

	always @(posedge clk_sys) begin
		p_we <= cram0_we_n; p_ce <= cram0_ce0_n;
		p_ub <= cram0_ub_n; p_lb <= cram0_lb_n;
		p_dq <= cram0_dq;   p_addr <= c_addr_l;
		if (!cram0_ce0_n && !cram0_adv_n) c_addr_l <= {cram0_a, cram0_dq};
		if (cram0_we_n && !p_we && !p_ce) begin
			if (p_addr[21:16] != 6'd0) chip_oob <= 1'b1;
			if (!p_ub) cmem[p_addr[15:0]][15:8] <= p_dq[15:8];
			if (!p_lb) cmem[p_addr[15:0]][7:0]  <= p_dq[7:0];
		end
	end
	assign cram0_dq = (!cram0_ce0_n && !cram0_oe_n && cram0_we_n) ? cmem[c_addr_l[15:0]] : 16'hZZZZ;

	// =========================================================================
	// The save engine and the copier
	// =========================================================================
	reg         cart_ready = 0, cart_replace = 0;
	reg         event0 = 0;
	reg   [5:0] block0 = 0;
	reg   [1:0] die_busy = 0;

	wire        overlay_boot_hold, save_busy, save_present;
	wire        mc_apply_reject, mc_state_done, mc_state_apply;
	wire [15:0] sc_diag_drain;

	wire        p2_req, p2_we;
	wire [24:0] p2_addr;
	wire [15:0] p2_wdata;
	wire  [1:0] p2_be;
	reg         p2_done = 0;
	reg  [15:0] p2_rdata = 0;
	reg         p2_busy = 0;
	wire        p2_ready = !p2_busy;

	ngpc_cart_save cart_save (
		.clk             (clk_sys),
		.reset           (reset_in),
		.cart_ready_i    (cart_ready),
		.cart_replace_i  (cart_replace),
		.cart_crc32_i    (CART_CRC),
		.cart_bytes_i    (CART_BYTES),
		.cart_title_i    (CART_TITLE),
		.cart_catalog_i  (CART_CAT),
		.cart_subcat_i   (CART_SUB),
		.size_code0_i    (2'd3),
		.size_code1_i    (2'd0),
		.event0_i        (event0),
		.block0_i        (block0),
		.event1_i        (1'b0),
		.block1_i        (6'd0),
		.die_busy_i      (die_busy),
		.host_busy_i     (host_busy),   // RC6C-WIRE core_top: .host_busy(host_busy) (rc6, L2)
		.host_rd_i       (stage_host_rd),   // RC6C-RDWIRE core_top: .host_rd(stage_host_rd), the data_unloader read_en that drives stage_mem.host_rd_i (rc6 follow-up)
		.state_apply_i   (mc_state_apply),
		.draining_i      (sc_draining),
		.state_frozen_i  (ss_load_frozen),
		.state_fail_i    (ss_load_fail),
		.frozen_o        (mc_frozen),
		.save_slot_wr_i  (save_slot_wr),
		.apply_reject_o  (mc_apply_reject),
		.state_done_o    (mc_state_done),
		.stage_current_o (mc_stage_current),
		.stage_bank_o    (mc_stage_bank),
		.slots_settled_i (slots_settled),
		.diag_beats_i    (stage_diag_beats),
		.diag_drops_i    (stage_diag_drops),
		.diag_drain_i    (sc_diag_drain),
		.boot_hold_o     (overlay_boot_hold),
		.save_present_o  (save_present),
		.busy_o          (save_busy),
		.p2_req_o        (p2_req),
		.p2_we_o         (p2_we),
		.p2_addr_o       (p2_addr),
		.p2_wdata_o      (p2_wdata),
		.p2_be_o         (p2_be),
		.p2_ready_i      (p2_ready),
		.p2_done_i       (p2_done),
		.p2_rdata_i      (p2_rdata),
		.stage_req_o     (stage_req),
		.stage_we_o      (stage_we),
		.stage_addr_o    (stage_addr),
		.stage_wdata_o   (stage_wdata),
		.stage_ready_i   (stage_ready),
		.stage_done_i    (stage_done),
		.stage_rdata_i   (stage_rdata)
	);

	// ngpc_machine: save_busy_state = the engine's boot_hold_o (core_top
	// mc_save_busy; the rc6 follow-up, was busy_o)
	assign mc_save_busy = overlay_boot_hold;   // RC6C-BUSYWIRE

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

	// ---- cartridge SDRAM background port (die 0, 2 MB) ------------------------
	reg [15:0] sdram [0:1048575];
	reg  [3:0] p2_cnt = 0;
	reg        p2_we_q = 0;
	reg [19:0] p2_a_q = 0;
	reg [15:0] p2_wd_q = 0;
	always @(posedge clk_sys) begin
		p2_done <= 1'b0;
		if (p2_req === 1'b1 && !p2_busy) begin
			p2_busy <= 1'b1;
			p2_we_q <= p2_we;
			p2_a_q  <= p2_addr[20:1];
			p2_wd_q <= p2_wdata;
			p2_cnt  <= 2 + ($urandom % (P_P2MAX - 1));
		end else if (p2_busy) begin
			if (p2_cnt == 4'd0) begin
				p2_busy <= 1'b0;
				p2_done <= 1'b1;
				if (p2_we_q) sdram[p2_a_q] <= p2_wd_q;
				else         p2_rdata <= sdram[p2_a_q];
			end else p2_cnt <= p2_cnt - 4'd1;
		end
	end

	// =========================================================================
	// Errors and the end of a run
	// =========================================================================
	integer errors = 0;
	string  first_fail = "";
	task fail(input string msg);
		begin
			errors = errors + 1;
			if (errors == 1) first_fail = msg;
			$display("   FAIL [%0d] %0s", cyc, msg);
		end
	endtask

	// =========================================================================
	// Monitors
	// =========================================================================
	wire [4:0] est = cart_save.state;
	// The engine is in S_FINISH for an accepted state apply, its verify pass
	// over: the step that commits (rc5) or holds for the host port (rc6).
	wire hold_now = (est == 5'd15) && (cart_save.in_apply === 1'b1) &&
	                (cart_save.from_state === 1'b1) && (cart_save.apply_ok === 1'b1) &&
	                (cart_save.refused_q === 1'b0) && (cart_save.verify_pass === 1'b0);

	integer t_last_ev   = 0;
	integer t_drain_up  = -1, t_drain_dn = -1, t_ldreq = -1;
	integer t_sapply = -1, t_sdone = -1, t_last_drain = -1;
	integer t_fin = -1;          // first hold_now sample: where rc5 committed
	integer t_commit = -1;       // the sample the state commit's flip is seen
	integer t_hb_fall = -1;      // last sample host_busy was seen falling
	integer n_state_apply = 0, n_state_done = 0, n_state_commits = 0, n_flips = 0;
	integer max_skid = 0;
	reg     commit_hb = 1'bx;    // host_busy where slot_busy_q sampled it for the commit
	integer commit_hbfall = 0;   // t_commit - t_hb_fall at the commit
	reg     hb_h0 = 1'b1, hb_h1 = 1'b1, hb_h2 = 1'b1;
	reg     bank_q = 1'b0, drn_q = 1'b0, sfa_q = 1'b0;
	reg [4:0] st_q = 5'd0;

	always @(posedge clk_sys) begin
		if (!reset_in) begin
			hb_h2 = hb_h1; hb_h1 = hb_h0; hb_h0 = (host_busy === 1'b1);
			if (hb_h1 && !hb_h0) t_hb_fall = cyc;
			if (event0 === 1'b1) t_last_ev = cyc;
			if (sc_draining === 1'b1 && !drn_q) begin
				t_drain_up = cyc;
				if (P_VERBOSE) $display("   [%0d] draining rises (engine state %0d, bank %0d)", cyc, est, mc_stage_bank);
			end
			if (sc_draining !== 1'b1 && drn_q) t_drain_dn = cyc;
			drn_q = (sc_draining === 1'b1);
			if (cs_load_req === 1'b1) t_ldreq = cyc;
			if (sc_host_wr === 1'b1) t_last_drain = cyc;
			if (mc_state_apply === 1'b1) begin
				n_state_apply = n_state_apply + 1; t_sapply = cyc;
				if (P_VERBOSE) $display("   [%0d] state_apply", cyc);
			end
			if (mc_state_done === 1'b1) begin
				n_state_done = n_state_done + 1; t_sdone = cyc;
				if (P_VERBOSE) $display("   [%0d] state_done (reject %b)", cyc, mc_apply_reject);
			end
			if (hold_now && t_fin < 0) begin
				t_fin = cyc;
				if (P_VERBOSE) $display("   [%0d] S_FINISH of the accepted state apply (rc5 would commit here); host_busy %b host_idle %0d",
				                        cyc, host_busy, stage_mem.host_idle);
			end
			if (stage_mem.skid_fill > max_skid) max_skid = stage_mem.skid_fill;
			if (P_VERBOSE && st_q == 5'd0 && est == 5'd1)
				$display("   [%0d] pass starts (draining %b host_busy %b)", cyc, sc_draining, host_busy);
			st_q = est;
			if ((mc_stage_bank ^ bank_q) === 1'b1) begin
				n_flips = n_flips + 1;
				// the flip is seen one sample after the edge that made it, when
				// in_apply has already cleared: sfa_q is the previous sample
				if (sfa_q) begin
					n_state_commits = n_state_commits + 1;
					t_commit      = cyc;
					commit_hb     = hb_h2;   // slot_busy_q's view at the committing edge
					commit_hbfall = cyc - t_hb_fall;
				end
				if (P_VERBOSE) $display("   [%0d] committed bank -> %0d%0s", cyc, mc_stage_bank,
				                        sfa_q ? " (state apply commit)" : "");
			end
			bank_q = mc_stage_bank;
			sfa_q  = (cart_save.in_apply === 1'b1) && (cart_save.from_state === 1'b1);
		end
	end

	// the word 0 every apply reads (its magic check), VERBOSE
	always @(posedge clk_sys)
		if (P_VERBOSE && !reset_in && est == 5'd9 && stage_done === 1'b1 && cart_save.hdr_idx == 6'd0)
			$display("   [%0d] %0s apply reads word 0 of bank %0d = %h (apf_delivered %b pre_delivered %b)",
			         cyc, cart_save.from_state ? "state" : "boot", cart_save.apply_bank, stage_rdata,
			         cart_save.apf_delivered, cart_save.pre_delivered);

	// ---- the mid-load flush: which bank each of its host reads was served from
	reg     mf_live = 0;
	reg     old_bank = 1'b0;     // the committed bank at the state_apply pulse
	integer t_rd_first = -1;
	integer rd_old = 0, rd_new = 0, rd_old_last_w = -1, rd_new_first_w = -1;
	always @(posedge clk_sys) begin
		if (mf_live && stage_host_rd === 1'b1 && t_rd_first < 0) t_rd_first = cyc;
		// a host read is issued with ps_read_en and eng_active low (ngpc_stage_mem)
		if (!reset_in && mf_live && stage_mem.ps_read_en === 1'b1 && stage_mem.eng_active === 1'b0) begin
			if (stage_mem.ps_addr[15] === old_bank) begin
				rd_old = rd_old + 1; rd_old_last_w = stage_mem.ps_addr[14:0];
			end else begin
				rd_new = rd_new + 1;
				if (rd_new_first_w < 0) rd_new_first_w = stage_mem.ps_addr[14:0];
			end
		end
	end

	// ---- PUBOFS: the pass's publish decision --------------------------------------
	// The edge where the pass's header word 31 is done (S_STAGE_HDR_W, hdr_idx
	// 31, stage_done_i): ngpc_cart_save publishes here or owes the pass. A hit
	// is the flush's read strobe first seen high on this very edge, the port
	// otherwise quiet (host_busy_o still low): ngpc_stage_mem claims that read
	// with the bank as it stands before the edge.
	// (host_busy low on that edge also makes the strobe the flush's first: any
	// earlier read would have raised it for 10 ms.)
	integer t_pubtrig = -1, t_pubdec = -1, t_pubflip = -1;
	reg     pub_seen = 0, pub_hit = 0, pub_hb = 1'bx, pub_rd = 1'bx, pub_bank0 = 1'bx;
	always @(posedge clk_sys) begin
		if (!reset_in && P_PUBOFS >= 0) begin
			if (pub_seen && t_pubflip < 0 && (mc_stage_bank ^ pub_bank0) === 1'b1) t_pubflip = cyc;
			if (!pub_seen && est == 5'd7 && cart_save.hdr_idx == 6'd31 && stage_done === 1'b1) begin
				pub_seen  = 1; t_pubdec = cyc;
				pub_bank0 = mc_stage_bank;
				pub_rd    = (stage_host_rd === 1'b1);
				pub_hb    = (host_busy === 1'b1);
				pub_hit   = pub_rd && !pub_hb;
				if (P_VERBOSE) $display("   [%0d] the pass's publish decision: read strobe %b host_busy %b stage_pending %b bank %0d",
				                        cyc, stage_host_rd, host_busy, cart_save.stage_pending, mc_stage_bank);
			end
		end
	end

	// ---- deadlock watchdogs ------------------------------------------------------
	// The S_FINISH hold must end within 2 samples of host_busy falling (the
	// slot_busy_q flop); 5 samples of hold with the port quiet is a deadlock.
	// And a state_apply must see its state_done within SD_MAX.
	reg     deadlock = 0;
	integer dl_quiet = 0;
	string  dl_why = "";
	always @(posedge clk_sys) begin
		if (!reset_in && !deadlock) begin
			if (hold_now && host_busy === 1'b0) dl_quiet = dl_quiet + 1;
			else                                dl_quiet = 0;
			if (dl_quiet >= 5)
				dl_why = $sformatf("the state commit holds in S_FINISH with the host port quiet for %0d samples (host_busy low since %0d, draining %b)",
				                   dl_quiet, t_hb_fall, sc_draining);
			else if (t_sapply >= 0 && t_sdone < t_sapply && cyc - t_sapply > SD_MAX)
				dl_why = $sformatf("no state_done %0d clk after state_apply (engine state %0d, host_busy %b, draining %b)",
				                   cyc - t_sapply, est, host_busy, sc_draining);
			if (dl_why != "") begin
				deadlock = 1;
				fail({"DEADLOCK: ", dl_why});
				end_run;
			end
		end
	end

	// =========================================================================
	// Images and flash content
	// =========================================================================
	function [31:0] crc32_word_tb(input [31:0] c, input [15:0] w);
		integer b;
		reg [31:0] v;
		begin
			v = c;
			for (b = 0; b < 16; b = b + 1)
				v = (v[0] ^ w[b]) ? ((v >> 1) ^ 32'hEDB88320) : (v >> 1);
			crc32_word_tb = v;
		end
	endfunction

	// die-0 word address and word count of blocks 32/33/34 (size code 3)
	function integer bw(input integer blk);
		case (blk)
			32: bw = 32'hFC000;
			33: bw = 32'hFD000;
			34: bw = 32'hFE000;
			default: bw = 0;
		endcase
	endfunction
	function integer bn(input integer blk);
		case (blk)
			32: bn = 4096;
			33: bn = 4096;
			34: bn = 8192;
			default: bn = 0;
		endcase
	endfunction

	// Block content for a generation: literals in 0xAxxx, the rest erased.
	function [15:0] cval(input integer gen, input integer blk, input integer w);
		reg lit;
		begin
			case (blk)
				32: lit = (w < 1500);
				33: lit = (w < 200);
				34: lit = (w < 3000) || (w >= 5000 && w < 5100);
				default: lit = 0;
			endcase
			if (lit) cval = {4'hA, gen[3:0] ^ w[11:8], w[7:0] ^ blk[7:0]};
			else     cval = 16'hFFFF;
		end
	endfunction

	reg [15:0] img   [0:BANKW-1];
	reg [15:0] mimg  [0:SLOTW-1];     // the Memory's embedded image
	reg [15:0] flushed [0:SLOTW-1];
	reg [15:0] oldimg [0:SLOTW-1];    // committed bank at the state_apply pulse (PUBOFS: before the publish)
	reg [15:0] newimg [0:SLOTW-1];    // the image that replaces it (the Memory's; PUBOFS: the pass's)
	reg [15:0] midf   [0:SLOTW-1];    // the file flushed during the load
	integer    mf_old = 0, mf_new = 0, mf_neither = 0, mf_diff = 0;
	integer    t_mf_start = -1, t_mf_end = -1;
	reg        mf_mixed = 0, mf_ran = 0, mf_hold_at_start = 0;
	// save_present_o when the flush began: core_top raises APF's size entry for
	// the slot only while it is high, so with it low (and nothing delivered)
	// APF writes no file at all -- "a game with no save leaves no file behind"
	reg        mf_sp_start = 1'bx;
	reg        rl_skip = 0;          // RELAUNCHMID skipped: the file is a save-less junk bank
	reg [15:0] rl_verdict = 16'hxxxx;
	reg        rl_frozen = 1'bx;
	integer    img_pk, pay_len = 0;
	reg [31:0] img_c;

	task emit(input [15:0] v);
		begin
			img[256 + img_pk] = v;
			img_c  = crc32_word_tb(img_c, v);
			img_pk = img_pk + 1;
		end
	endtask

	// A rev-05 V4 image of blocks 32..34, the gen of each block given.
	task build_img(input integer g32, input integer g33, input integer g34,
	               input [15:0] beats, input [15:0] drain);
		integer b, w, run, k, g;
		reg [15:0] v;
		reg [31:0] c;
		begin
			for (k = 0; k < BANKW; k = k + 1) img[k] = 16'h0000;
			img_pk = 0; img_c = 32'hFFFFFFFF;
			for (b = 32; b <= 34; b = b + 1) begin
				g = (b == 32) ? g32 : (b == 33) ? g33 : g34;
				run = 0;
				for (w = 0; w < bn(b); w = w + 1) begin
					v = cval(g, b, w);
					if (v == 16'hFFFF) run = run + 1;
					else begin
						if (run != 0) begin emit(16'hFFFF); emit(run[15:0]); run = 0; end
						emit(v);
					end
				end
				if (run != 0) begin emit(16'hFFFF); emit(run[15:0]); end
			end
			c = ~img_c;
			img[0]  = 16'h4E47; img[1] = 16'h5043; img[2] = 16'h5341; img[3] = 16'h5634;
			img[4]  = CART_CRC[15:0]; img[5] = CART_CRC[31:16];
			img[6]  = {7'd0, CART_BYTES[24:16]}; img[7] = CART_BYTES[15:0];
			img[8]  = 16'h0000; img[9] = 16'h0000; img[10] = 16'h0007; img[11] = 16'h0000;
			img[12] = 16'h0000; img[13] = 16'h0000; img[14] = 16'h0000; img[15] = 16'h0000;
			img[16] = beats; img[17] = 16'h0000; img[18] = drain;
			img[19] = c[15:0];    img[20] = c[31:16];
			img[21] = {8'h05, CART_SUB};
			img[22] = 16'h0001; img[23] = 16'h0001; img[24] = 16'h4000;
			img[25] = CART_TITLE[15:0];  img[26] = CART_TITLE[31:16];
			img[27] = CART_TITLE[47:32]; img[28] = CART_TITLE[63:48];
			img[29] = CART_TITLE[79:64]; img[30] = CART_TITLE[95:80];
			img[31] = CART_CAT;
		end
	endtask

	function integer cbank(input integer dummy);
		cbank = (mc_stage_bank === 1'b1) ? 1 : 0;
	endfunction

	// =========================================================================
	// APF tasks
	// =========================================================================
	task apf_deliver_img;
		integer k;
		reg [31:0] d;
		begin
			for (k = 0; k < SLOTW/2; k = k + 1) begin
				d = {img[2*k][7:0], img[2*k][15:8], img[2*k+1][7:0], img[2*k+1][15:8]};
				@(posedge clk_74a); bridge_addr <= SAVEBASE + k*4; bridge_wr_data <= d; bridge_wr <= 1;
				@(posedge clk_74a); bridge_wr <= 0;
				repeat (P_DGAP) @(posedge clk_74a);
			end
			@(posedge clk_74a); bridge_addr <= 32'hF8000000;
		end
	endtask

	task apf_flush(input integer nw32);
		integer k;
		reg [31:0] d;
		begin
			for (k = 0; k < SLOTW; k = k + 1) flushed[k] = 16'hxxxx;
			for (k = 0; k < nw32; k = k + 1) begin
				@(posedge clk_74a); bridge_addr <= SAVEBASE + k*4; bridge_rd <= 1;
				@(posedge clk_74a); bridge_rd <= 0;
				repeat (P_RGAP) @(posedge clk_74a);
				d = stage_bridge_rd_data;
				flushed[2*k]   = {d[23:16], d[31:24]};
				flushed[2*k+1] = {d[7:0],   d[15:8]};
			end
			@(posedge clk_74a); bridge_addr <= 32'hF8000000;
		end
	endtask

	reg [31:0] image [0:WORDS-1];
	reg sv_ok;
	task apf_save;
		integer k, n;
		begin
			sv_ok = 0;
			@(posedge clk_74a); ss_start_req <= 1;
			n = 0;
			while (start_ack !== 1'b1 && n < 10000) begin @(posedge clk_74a); n = n + 1; end
			if (start_ack !== 1'b1) fail("APF: no savestate_start_ack");
			@(posedge clk_74a); ss_start_req <= 0;
			n = 0;
			while (start_ok !== 1'b1 && start_err !== 1'b1 && n < SAVE_MAX74) begin @(posedge clk_74a); n = n + 1; end
			sv_ok = (start_ok === 1'b1);
			if (start_ok !== 1'b1 && start_err !== 1'b1) fail("APF: the capture never reported ok or err");
			for (k = 0; k < WORDS; k = k + 1) begin
				@(posedge clk_74a); bridge_addr <= BLOBBASE | (k*4); bridge_rd <= 1;
				repeat (3) @(posedge clk_74a);
				image[k] = savestate_rd_data;
				bridge_rd <= 0;
			end
			@(posedge clk_74a); bridge_rd <= 0; bridge_addr <= 32'hF8000000;
			for (k = 0; k < WORDS; k = k + 1)
				if (^image[k] === 1'bx) image[k] = 32'd0;
			repeat (8) @(posedge clk_74a);
		end
	endtask

	task apf_write_blob;   // lag-1 bus, as measured
		integer k;
		reg [31:0] a;
		begin
			@(posedge clk_74a);
			for (k = 0; k < WORDS; k = k + 1) begin
				a = (k == 0) ? 32'hF8000050 : (BLOBBASE | ((k-1)*4));
				@(posedge clk_74a);
				bridge_addr <= a; bridge_wr_data <= image[k]; bridge_wr <= 1;
				@(posedge clk_74a); bridge_wr <= 0;
				repeat (GAP) @(posedge clk_74a);
			end
			@(posedge clk_74a); bridge_addr <= 32'hF8000000;
		end
	endtask

	reg ld_ok = 0, ld_fin = 0;
	task apf_load;
		integer n;
		begin
			ld_ok = 0; ld_fin = 0;
			@(posedge clk_74a); ss_load_req <= 1;
			n = 0;
			while (load_ack !== 1'b1 && n < 10000) begin @(posedge clk_74a); n = n + 1; end
			if (load_ack !== 1'b1) fail("APF: no savestate_load_ack");
			@(posedge clk_74a); ss_load_req <= 0;
			n = 0;
			while (load_ok !== 1'b1 && load_err !== 1'b1 && n < LOAD_MAX74) begin @(posedge clk_74a); n = n + 1; end
			ld_ok = (load_ok === 1'b1);
			if (load_ok !== 1'b1 && load_err !== 1'b1) fail("APF: the load never reported ok or err");
			repeat (8) @(posedge clk_74a);
			repeat (4) @(posedge clk_sys);
			ld_fin = 1;
		end
	endtask

	function [15:0] secw(input integer k);
		reg [31:0] v;
		begin
			v = image[CARTB + (k >> 1)];
			secw = k[0] ? v[31:16] : v[15:0];
		end
	endfunction

	// =========================================================================
	// The game's flash writes
	// =========================================================================
	// automatic: the game and the loader wait at the same time
	task automatic wait_until(input integer t);
		begin
			while (cyc < t) @(posedge clk_sys);
		end
	endtask

	function integer save_len(input integer dummy);
		save_len = ERASE_CYC34 + 2 * 3100 * P_PROGPER;
	endfunction

	task pulse_event(input [5:0] blk);
		begin
			@(posedge clk_sys); block0 <= blk; event0 <= 1'b1; die_busy <= 2'b00;
			@(posedge clk_sys); event0 <= 1'b0;
		end
	endtask

	// One in-game save of block 34, generation gen, started at absolute t0:
	// erase (die busy, then one report), then two byte programs per literal
	// word, one every P_PROGPER clocks (die busy ~18 clk, then one report).
	task do_save(input integer t0, input integer gen);
		integer w, bsel, k, tp, i;
		reg [15:0] v;
		begin
			wait_until(t0);
			@(posedge clk_sys); die_busy <= 2'b01;
			wait_until(t0 + ERASE_CYC34 - 1);
			for (i = 0; i < bn(34); i = i + 1) sdram[bw(34) + i] = 16'hFFFF;
			pulse_event(6'd34);
			k = 0;
			for (w = 0; w < bn(34); w = w + 1) begin
				v = cval(gen, 34, w);
				if (v != 16'hFFFF) begin
					for (bsel = 0; bsel < 2; bsel = bsel + 1) begin
						k = k + 1;
						tp = t0 + ERASE_CYC34 + k * P_PROGPER;
						wait_until(tp - 20);
						@(posedge clk_sys); die_busy <= 2'b01;
						wait_until(tp - 1);
						if (bsel == 0) sdram[bw(34) + w][7:0]  = sdram[bw(34) + w][7:0]  & v[7:0];
						else           sdram[bw(34) + w][15:8] = sdram[bw(34) + w][15:8] & v[15:8];
						pulse_event(6'd34);
					end
				end
			end
		end
	endtask

	// =========================================================================
	// Helpers
	// =========================================================================
	task wait_idle(input integer max);
		integer n, q;
		begin
			n = 0; q = 0;
			while (q < 64 && n < max) begin
				@(posedge clk_sys); n = n + 1;
				if (save_busy === 1'b0 && overlay_boot_hold === 1'b0) q = q + 1; else q = 0;
			end
			if (q < 64) fail("the save engine never went idle");
		end
	endtask

	function integer bank_vs_img(input integer b);
		integer k, n;
		begin
			n = 0;
			for (k = 0; k < SLOTW; k = k + 1) if (cmem[b*BANKW + k] !== img[k]) n = n + 1;
			bank_vs_img = n;
		end
	endfunction

	// the committed bank (or the flushed file) vs the Memory's image
	integer d_hdr, d_pay, d_crc;
	task cmp_vs_mimg(input string what, input integer use_flushed, input integer b);
		integer k;
		reg [15:0] v;
		begin
			d_hdr = 0; d_pay = 0; d_crc = 0;
			for (k = 0; k < SLOTW; k = k + 1) begin
				v = use_flushed ? flushed[k] : cmem[b*BANKW + k];
				if (v !== mimg[k]) begin
					if (k == 19 || k == 20) d_crc = d_crc + 1;
					else if (k < 256) d_hdr = d_hdr + 1;
					else d_pay = d_pay + 1;
					if (k < 32 || (d_pay < 4 && k >= 256))
						$display("   DIFF %0s word %0d = %h, Memory image %h", what, k, v, mimg[k]);
				end
			end
			$display("   %0s vs Memory image: header %0d, payload %0d, crc %0d words differ", what, d_hdr, d_pay, d_crc);
		end
	endtask

	// A new launch streams the cartridge through nibble 1 before cart_ready,
	// which restarts core_top's slots_settled count: the boot apply then
	// waits for the save slot that follows. One cartridge-slot write (bit 24,
	// never staged) stands for the stream. Without it slots_settled would still
	// be high from the last session and the apply would run before the file.
	task apf_cart_stream;
		integer n;
		begin
			@(posedge clk_74a); bridge_addr <= 32'h11000000; bridge_wr_data <= 32'h0; bridge_wr <= 1;
			@(posedge clk_74a); bridge_wr <= 0;
			@(posedge clk_74a); bridge_addr <= 32'hF8000000;
			n = 0;
			while (slots_settled !== 1'b0 && n < 1000) begin @(posedge clk_sys); n = n + 1; end
			if (slots_settled !== 1'b0) fail("(setup) slots_settled did not restart on the cartridge stream");
		end
	endtask

	// relaunch: reset, erased flash, a new cartridge epoch, deliver img, boot apply
	task relaunch_on_img;
		integer i;
		begin
			@(posedge clk_sys); reset_in <= 1; cart_ready <= 0;
			repeat (20) @(posedge clk_sys);
			reset_in <= 0;
			for (i = 0; i < 1048576; i = i + 1) sdram[i] = 16'hFFFF;
			apf_cart_stream;
			repeat (4) @(posedge clk_sys); cart_replace <= 1;
			@(posedge clk_sys); cart_replace <= 0;
			repeat (8) @(posedge clk_sys); cart_ready <= 1;
			apf_deliver_img;
			repeat (20) @(posedge clk_sys);
			i = bank_vs_img(cbank(0));
			$display("   [%0d] relaunch: file delivered into bank %0d, %0d words differ from the file (bank words 0-1 %h %h)",
			         cyc, cbank(0), i, cmem[cbank(0)*BANKW], cmem[cbank(0)*BANKW + 1]);
			if (i != 0) fail($sformatf("relaunch: the delivery left %0d words of the committed bank different from the file", i));
			wait_idle(20000000);
		end
	endtask

	// A flush judged word by word over the words a boot apply reads (header
	// 0-31, payload): each word that differs between the old committed image
	// and the image replacing it must be the old one throughout or the new one
	// throughout, none neither. And every host read of it must have been
	// served from one bank: a flip between two of its reads is the defect L2
	// closes, even where the words it split happen to agree.
	task judge_flush(input string what);
		integer k;
		begin
			for (k = 0; k < SLOTW; k = k + 1) midf[k] = flushed[k];
			for (k = 0; k < SLOTW; k = k + 1)
				if ((k < 32 || (k >= 256 && k < 256 + pay_len)) && k < 2*P_MIDWORDS) begin
					if (oldimg[k] !== newimg[k]) begin
						mf_diff = mf_diff + 1;
						if (midf[k] === oldimg[k])      mf_old = mf_old + 1;
						else if (midf[k] === newimg[k]) mf_new = mf_new + 1;
						else                            mf_neither = mf_neither + 1;
						if (midf[k] !== newimg[k] && mf_old + mf_neither <= 4)
							$display("   %0s file word %0d = %h: old image %h, new image %h", what, k, midf[k], oldimg[k], newimg[k]);
					end else if (midf[k] !== oldimg[k]) mf_neither = mf_neither + 1;
				end
			mf_mixed = (mf_old > 0 && mf_new > 0) || (mf_neither > 0);
			$display("   %0s flush: %0d words differ between the images: old %0d new %0d neither %0d; host reads from old bank %0d (last word %0d), new bank %0d (first word %0d) -> %0s",
			         what, mf_diff, mf_old, mf_new, mf_neither, rd_old, rd_old_last_w, rd_new, rd_new_first_w,
			         mf_mixed ? "MIXED FILE" : (mf_new == 0 ? "whole old image" : "whole new image"));
			if (mf_mixed) fail($sformatf("the file flushed %0s mixes two images (old %0d, new %0d, neither %0d)",
			                             what, mf_old, mf_new, mf_neither));
			if (rd_old > 0 && rd_new > 0)
				fail($sformatf("the %0s flush was served from both banks: %0d read(s) from the old bank (last word %0d), %0d from the new (first word %0d)",
				               what, rd_old, rd_old_last_w, rd_new, rd_new_first_w));
		end
	endtask

	// =========================================================================
	// The result and the end of a run
	// =========================================================================
	integer res_verdict = -1;
	reg     res_frozen = 1'bx, res_reject = 1'bx;
	integer hold_cyc = -1;

	function string fstr(input integer dummy);
		fstr = !mf_ran ? "none" : mf_mixed ? "MIXED" : (mf_new == 0) ? "old" : "new";
	endfunction

	string rl_vs, rl_fs;
	task end_run;
		begin
			hold_cyc = (t_commit >= 0 && t_fin >= 0) ? t_commit - t_fin - 1 : -1;
			if (rl_skip) begin rl_vs = "skip"; rl_fs = "-"; end
			else begin rl_vs = $sformatf("%h", rl_verdict); rl_fs = $sformatf("%b", rl_frozen); end
			$display("== RC6C RESULT scn=%0s build=%0s flushapply=%0d raceofs=%0d racej=%0d junk=%0d | load=%0s verdict=%h reject=%b frozen=%b state_commits=%0d | commit_after_sapply=%0d commit_after_last_drain_beat=%0d hold_cyc=%0d hold_us=%0d commit_hb=%b commit_minus_hbfall=%0d | mid_flush=%0s straddle=%0s commit_vs_flush=%0s first_rd_minus_commit=%0d old=%0d new=%0d neither=%0d sp_at_flush=%b | rd_banks old=%0d new=%0d split=%0s old_last_w=%0d new_first_w=%0d | relaunch verdict=%0s frozen=%0s | drops=%0d max_skid=%0d deadlock=%0s | errors=%0d",
			         P_SCN, P_BUILD, P_FLUSHAPPLY, P_RACEOFS, P_RACEJ, P_JUNK,
			         ld_ok ? "ok" : "FAIL", res_verdict[15:0], res_reject, res_frozen, n_state_commits,
			         (t_commit < 0 || t_sapply < 0) ? -1 : t_commit - t_sapply,
			         (t_commit < 0 || t_last_drain < 0) ? -1 : t_commit - t_last_drain,
			         hold_cyc, (hold_cyc < 0) ? -1 : $rtoi(hold_cyc / 49.152),
			         commit_hb, (t_commit < 0) ? -1 : commit_hbfall,
			         fstr(0),
			         !mf_ran ? "n.a." : (P_PUBOFS >= 0) ? "pub" : (P_RACEOFS >= 0) ? "race" :
			         P_HOLDFLUSH ? (mf_hold_at_start ? "hold" : "NO") :
			         (t_rd_first >= 0 && t_fin >= 0 && t_rd_first <= t_fin && t_fin <= t_mf_end) ? "yes" : "NO",
			         (t_commit < 0) ? "none" : !mf_ran ? "noflush" :
			         (t_commit < t_rd_first) ? "before" : (t_commit > t_mf_end) ? "after" : "during",
			         (t_commit < 0 || t_rd_first < 0) ? 0 : t_rd_first - t_commit,
			         mf_old, mf_new, mf_neither, mf_sp_start,
			         rd_old, rd_new, (rd_old > 0 && rd_new > 0) ? "YES" : "no", rd_old_last_w, rd_new_first_w,
			         rl_vs, rl_fs, stage_diag_drops, max_skid, deadlock ? "YES" : "no", errors);
			if (P_PUBOFS >= 0)
				$display("== RC6C PUBRACE scn=%0s build=%0s pubofs=%0d pubidx=%0d | trig_to_dec=%0d rd_minus_dec=%0d pub_hit=%0s rd_at_dec=%b hb_at_dec=%b | flip_minus_dec=%0d | mid_flush=%0s old=%0d new=%0d neither=%0d sp_at_flush=%b | rd_banks old=%0d new=%0d split=%0s old_last_w=%0d | errors=%0d",
				         P_SCN, P_BUILD, P_PUBOFS, P_PUBIDX,
				         (t_pubdec < 0 || t_pubtrig < 0) ? -1 : t_pubdec - t_pubtrig,
				         (t_pubdec < 0 || t_rd_first < 0) ? -999999 : t_rd_first - t_pubdec,
				         pub_hit ? "YES" : "no", pub_rd, pub_hb,
				         (t_pubflip < 0 || t_pubdec < 0) ? -1 : t_pubflip - t_pubdec,
				         fstr(0), mf_old, mf_new, mf_neither, mf_sp_start,
				         rd_old, rd_new, (rd_old > 0 && rd_new > 0) ? "YES" : "no", rd_old_last_w, errors);
			if (errors == 0) begin
				$display("== ALL RC6C SCENARIOS PASS");
				$finish;
			end else begin
				$display("== %0d FAILURE(S) (scenario %0s, build %0s; first: %0s)", errors, P_SCN, P_BUILD, first_fail);
				$stop;   // vvp -N: exit code 1
			end
		end
	endtask

	// =========================================================================
	// The run
	// =========================================================================
	integer i, n, t_save1, t_lastplan, t_load, b_after, flush_words;

	initial begin
		if ($value$plusargs("SAVES=%d", P_SAVES)) ;
		if ($value$plusargs("DELAYCYC=%d", P_DELAYCYC)) ;
		begin : dus
			integer du;
			if ($value$plusargs("DELAYUS=%d", du)) P_DELAYCYC = $rtoi((du) * 49.152);
		end
		if ($value$plusargs("FLUSH=%d", P_FLUSH)) ;
		if ($value$plusargs("RELAUNCH=%d", P_RELAUNCH)) ;
		if ($value$plusargs("P2MAX=%d", P_P2MAX)) ;
		if ($value$plusargs("SEED=%d", P_SEED)) ;
		if ($value$plusargs("PROGPER=%d", P_PROGPER)) ;
		if ($value$plusargs("PLAYUS=%d", P_PLAYUS)) ;
		if ($value$plusargs("VERBOSE=%d", P_VERBOSE)) ;
		if ($value$plusargs("DGAP=%d", P_DGAP)) ;
		if ($value$plusargs("RGAP=%d", P_RGAP)) ;
		if ($value$plusargs("FLUSHAPPLY=%d", P_FLUSHAPPLY)) ;
		if ($value$plusargs("RACEOFS=%d", P_RACEOFS)) ;
		if ($value$plusargs("RELAUNCHMID=%d", P_RELAUNCHMID)) ;
		if ($value$plusargs("MIDWORDS=%d", P_MIDWORDS)) ;
		if ($value$plusargs("RACEJ=%d", P_RACEJ)) ;
		if ($value$plusargs("HOLDFLUSH=%d", P_HOLDFLUSH)) ;
		if ($value$plusargs("JUNK=%d", P_JUNK)) ;
		if (P_JUNK) P_SAVES = 0;
		if ($value$plusargs("PUBOFS=%d", P_PUBOFS)) ;
		if ($value$plusargs("PUBIDX=%d", P_PUBIDX)) ;
		if ($value$plusargs("PUBANY=%d", P_PUBANY)) ;
		if (P_PUBOFS >= 0) begin
			// the publish race: a JUNK session with one in-game save, no load
			P_JUNK = 1; P_SAVES = 1;
			if (!$value$plusargs("MIDWORDS=%d", P_MIDWORDS)) P_MIDWORDS = 160;
		end
		if ($value$plusargs("SCN=%s", P_SCN)) ;
		if ($value$plusargs("BUILD=%s", P_BUILD)) ;
		seedv = $urandom(P_SEED);

		$display("== RC6C scn=%0s build=%0s saves=%0d delay=%0d us flushapply=%0d raceofs=%0d midwords=%0d relaunchmid=%0d flush=%0d relaunch=%0d seed=%0d",
		         P_SCN, P_BUILD, P_SAVES, $rtoi((P_DELAYCYC) / 49.152), P_FLUSHAPPLY, P_RACEOFS, P_MIDWORDS,
		         P_RELAUNCHMID, P_FLUSH, P_RELAUNCH, P_SEED);

		for (i = 0; i < 65536; i = i + 1) cmem[i] = 16'hDEAD;
		for (i = 0; i < 1048576; i = i + 1) sdram[i] = 16'hFFFF;   // ROM: save blocks erased
		for (i = 0; i <= N_INT; i = i + 1) internals[i] = 64'hDEADBEEF_DEADBEEF;
		for (i = 0; i < SZ0; i = i + 1) mem0[i] = 8'hFF;
		for (i = 0; i < SZ1; i = i + 1) mem1[i] = 8'hFF;
		for (i = 0; i < SZ2; i = i + 1) mem2[i] = 8'hFF;
		for (i = 0; i < WORDS; i = i + 1) image[i] = 32'd0;

		// ---- launch: reset, cartridge, delivery of a rev-05 file ------------
		repeat (20) @(posedge clk_sys);
		reset_in <= 0;
		repeat (4) @(posedge clk_sys); cart_replace <= 1;
		@(posedge clk_sys); cart_replace <= 0;
		repeat (8) @(posedge clk_sys); cart_ready <= 1;
		build_img(1, 1, 1, 16'h7F00, 16'h0000);
		pay_len = img_pk;   // packed payload words (every generation packs alike)
		// PUBOFS needs neither the delivered session nor a Memory: straight to JUNK
		if (P_PUBOFS < 0) begin : first_session
		apf_deliver_img;
		repeat (20) @(posedge clk_sys);
		if (bank_vs_img(cbank(0)) != 0) fail("(setup) the delivery did not land in the committed bank");
		wait_idle(20000000);
		if (cart_save.diag_applies !== 16'd1 || cart_save.diag_verdict !== 16'h0001 || cart_save.diag_p2wr !== 16'h4000)
			fail($sformatf("(setup) boot apply: applies %h verdict %h p2wr %h",
			     cart_save.diag_applies, cart_save.diag_verdict, cart_save.diag_p2wr));
		n = 0;
		for (i = 0; i < 4096; i = i + 1) if (sdram[bw(32) + i] !== cval(1, 32, i)) n = n + 1;
		for (i = 0; i < 4096; i = i + 1) if (sdram[bw(33) + i] !== cval(1, 33, i)) n = n + 1;
		for (i = 0; i < 8192; i = i + 1) if (sdram[bw(34) + i] !== cval(1, 34, i)) n = n + 1;
		if (n != 0) fail($sformatf("(setup) the boot apply left %0d flash words wrong", n));
		$display("   [%0d] boot apply done: applies %0d verdict %h p2wr %h beats %h bank %0d",
		         cyc, cart_save.diag_applies, cart_save.diag_verdict, cart_save.diag_p2wr,
		         stage_diag_beats, mc_stage_bank);

		// the game runs; create a Memory
		for (i = 0; i <= N_INT; i = i + 1) internals[i] = {32'h5A5A0000 + i, 32'h12340000 + i};
		for (i = 0; i < SZ0; i = i + 1) mem0[i] = i[7:0] ^ 8'h3C;
		for (i = 0; i < SZ1; i = i + 1) mem1[i] = i[7:0] + 8'h11;
		for (i = 0; i < SZ2; i = i + 1) mem2[i] = i[7:0] ^ i[13:6];
		repeat (1000) @(posedge clk_sys);
		apf_save;
		if (!sv_ok) fail("the capture did not report ok");
		for (i = 0; i < SLOTW; i = i + 1) mimg[i] = secw(i);
		n = 0;
		for (i = 0; i < SLOTW; i = i + 1) if (mimg[i] !== cmem[cbank(0)*BANKW + i]) n = n + 1;
		if (n != 0) fail($sformatf("(setup) the Memory's image differs from the committed bank in %0d words", n));
		$display("   [%0d] Memory captured", cyc);
		end   // first_session

		// ---- JUNK: the Memory is loaded in a new session after a power cycle ---
		// The PSRAM lost its content (both banks hold a pattern that is no
		// image: never the magic), the game has no .sav so APF delivers
		// nothing, and the flash is the ROM's (save blocks erased). The boot
		// apply finds nothing delivered (verdict 0005); the state's image is
		// then this session's only save, and the committed bank it replaces
		// holds no image.
		if (P_JUNK) begin
			@(posedge clk_sys); reset_in <= 1; cart_ready <= 0;
			repeat (20) @(posedge clk_sys);
			for (i = 0; i < 65536; i = i + 1) cmem[i] = 16'h0BAD ^ i[15:0];
			for (i = 0; i < 1048576; i = i + 1) sdram[i] = 16'hFFFF;
			reset_in <= 0;
			apf_cart_stream;
			repeat (4) @(posedge clk_sys); cart_replace <= 1;
			@(posedge clk_sys); cart_replace <= 0;
			repeat (8) @(posedge clk_sys); cart_ready <= 1;
			wait_idle(20000000);
			$display("   [%0d] JUNK session: boot apply with nothing delivered: applies %0d verdict %h frozen %b bank %0d",
			         cyc, cart_save.diag_applies, cart_save.diag_verdict, mc_frozen, mc_stage_bank);
			if (cart_save.diag_verdict !== 16'h0005 || mc_frozen !== 1'b0)
				fail($sformatf("(setup) JUNK: the boot apply's verdict is %h (frozen %b), expected 0005", cart_save.diag_verdict, mc_frozen));
		end

		// ---- PUBOFS: a flush meets the pass's publish -------------------------
		// The game saves block 34 (its first save: the committed bank is junk);
		// the pass stages it into the spare bank and decides on header word
		// 31's done. The flush's first read strobe is aimed at that edge. The
		// rc6 follow-up owes the pass there (the strobe is up, host_busy not
		// yet) instead of flipping under the read ngpc_stage_mem claims with
		// the old bank on the same edge.
		if (P_PUBOFS >= 0) begin
			t_save1 = cyc + 5000;
			t_last_ev = t_save1 + save_len(0);
			fork
				do_save(t_save1, 2);
				begin : pubrace
					integer pn;
					pn = 0;
					while (!(est == 5'd7 && cart_save.hdr_idx == P_PUBIDX) && pn < 150000000) begin
						@(posedge clk_sys); pn = pn + 1;
					end
					if (pn >= 150000000) fail("PUBOFS: the pass never reached its header word PUBIDX");
					t_pubtrig = cyc;
					old_bank  = mc_stage_bank;   // the junk bank, before any publish
					repeat (P_PUBOFS) @(posedge clk_sys);
					t_mf_start = cyc;
					mf_live    = 1;
					mf_sp_start = (save_present === 1'b1);
					$display("   [%0d] APF flushes %0d words, %0d clk after the pass began header word %0d (bank %0d, host_idle %0d)",
					         cyc, P_MIDWORDS, cyc - t_pubtrig, P_PUBIDX, mc_stage_bank, stage_mem.host_idle);
					apf_flush(P_MIDWORDS);
					mf_live  = 0;
					t_mf_end = cyc;
					mf_ran   = 1;
				end
			join
			// the junk bank the flush started on, and the image the pass staged
			// beside it (untouched until a pass runs again, >= 10 ms later)
			for (i = 0; i < SLOTW; i = i + 1) begin
				oldimg[i] = cmem[(old_bank ? 1 : 0)*BANKW + i];
				newimg[i] = cmem[(old_bank ? 0 : 1)*BANKW + i];
			end
			$display("   [%0d] publish-race flush %0d..%0d, first read %0d, publish decision %0d (strobe %b host_busy %b), bank flip seen %0d; staged image words 0-3 %h %h %h %h",
			         cyc, t_mf_start, t_mf_end, t_rd_first, t_pubdec, pub_rd, pub_hb, t_pubflip,
			         newimg[0], newimg[1], newimg[2], newimg[3]);
			if (!P_PUBANY && !pub_hit)
				fail($sformatf("scenario invalid: the flush's first read strobe did not meet the publish decision (first read %0d, decision %0d, strobe %b host_busy %b at it)",
				               t_rd_first, t_pubdec, pub_rd, pub_hb));
			if (newimg[0] !== 16'h4E47 || newimg[1] !== 16'h5043)
				fail($sformatf("(setup) PUBOFS: the pass staged no image (words 0-1 %h %h)", newimg[0], newimg[1]));
			if (pub_hit && t_pubflip == t_pubdec + 1)
				fail("the pass published on the edge the flush's first read was claimed (that read latched the old bank)");
			judge_flush("publish-race");
			// the pass the race owed runs once the port is quiet again
			n = 0;
			while (mc_stage_bank === old_bank && n < 4000000) begin @(posedge clk_sys); n = n + 1; end
			if (mc_stage_bank === old_bank)
				fail("the pass never published (still the junk bank 80 ms after the flush)");
			repeat (100) @(posedge clk_sys);
			n = 0;
			for (i = 0; i < SLOTW; i = i + 1)
				if (cmem[cbank(0)*BANKW + i] !== newimg[i]) begin
					n = n + 1;
					if (n <= 4) $display("   DIFF published word %0d = %h, staged at the race %h", i, cmem[cbank(0)*BANKW + i], newimg[i]);
				end
			$display("   [%0d] published: bank %0d (%0d clk after the flush), %0d words differ from the image staged at the race; flips %0d, stage_pending %b",
			         cyc, mc_stage_bank, (t_pubflip < 0) ? -1 : t_pubflip - t_mf_end, n, n_flips, cart_save.stage_pending);
			if (n != 0) fail($sformatf("the published bank differs from the pass's image in %0d words", n));
			if (n_flips != 1) fail($sformatf("%0d bank flips, expected the one publish", n_flips));
			if (chip_oob) fail("a PSRAM access beyond the two staging banks");
			if (stage_diag_drops !== 16'd0) fail($sformatf("%0d host beats dropped by the skid", stage_diag_drops));
			end_run;
		end

		apf_write_blob;

		// ---- an in-game save (a pass publishes it), then the load -------------
		t_save1 = cyc + 5000;
		t_lastplan = (P_SAVES == 0) ? t_save1 : t_save1 + save_len(0);
		t_load = t_lastplan + P_DELAYCYC;
		t_last_ev = t_lastplan;
		fork
			begin : game
				if (P_SAVES >= 1) do_save(t_save1, 2);
			end
			begin : loader
				wait_until(t_load);
				$display("   [%0d] APF load command (engine state %0d, bank %0d, stage_pending %b)",
				         cyc, est, mc_stage_bank, cart_save.stage_pending);
				fork
					apf_load;
					begin : mid
						integer k, fa_n;
						while (mc_state_apply !== 1'b1 && !ld_fin) @(posedge clk_sys);
						if (mc_state_apply === 1'b1) begin
							old_bank = mc_stage_bank;
							for (k = 0; k < SLOTW; k = k + 1) oldimg[k] = cmem[cbank(0)*BANKW + k];
						end
						if ((P_FLUSHAPPLY >= 0 || P_RACEOFS >= 0) && !ld_fin) begin
							if (P_RACEOFS >= 0) begin
								// the commit is holding; land the first read around the
								// cycle host_busy_o falls
								fa_n = 0;
								while (!(hold_now && stage_mem.host_idle == HOST_TAIL - P_RACEOFS) &&
								       t_commit < 0 && fa_n < 50000000) begin
									@(posedge clk_sys); fa_n = fa_n + 1;
								end
								if (t_commit >= 0 || fa_n >= 50000000)
									fail("RACEOFS: the state commit never held for the host port");
								repeat (P_RACEJ) @(posedge clk_74a);
							end else begin
								repeat (P_FLUSHAPPLY) @(posedge clk_sys);
							end
							t_mf_start = cyc;
							mf_hold_at_start = hold_now;
							mf_sp_start = (save_present === 1'b1);
							mf_live = 1;
							$display("   [%0d] APF flushes the slot during the load (%0d clk after state_apply; engine state %0d, host_idle %0d, bank %0d)",
							         cyc, cyc - t_sapply, est, stage_mem.host_idle, mc_stage_bank);
							apf_flush(P_MIDWORDS);
							mf_live = 0;
							t_mf_end = cyc;
							mf_ran = 1;
							// the old committed image or the state's image, from one bank
							for (k = 0; k < SLOTW; k = k + 1) newimg[k] = mimg[k];
							$display("   [%0d] mid-load flush %0d..%0d, first read %0d, t_fin %0d, commit %0d",
							         cyc, t_mf_start, t_mf_end, t_rd_first, t_fin, t_commit);
							judge_flush("mid-load");
							if (P_FLUSHAPPLY >= 0 && !P_HOLDFLUSH &&
							    !(t_rd_first >= 0 && t_fin >= 0 && t_rd_first <= t_fin && t_fin <= t_mf_end))
								fail($sformatf("scenario invalid: the flush (reads %0d..%0d) did not straddle the hold-free commit point %0d",
								               t_rd_first, t_mf_end, t_fin));
							if (P_FLUSHAPPLY >= 0 && P_HOLDFLUSH && !mf_hold_at_start)
								fail("scenario invalid: HOLDFLUSH, but the commit was not holding when the flush started");
						end
					end
				join
				$display("   [%0d] load %0s (drain %0d..%0d)", cyc, ld_ok ? "OK" : "FAILED", t_drain_up, t_drain_dn);
			end
		join

		res_verdict = cart_save.diag_verdict;
		res_frozen  = mc_frozen;
		res_reject  = mc_apply_reject;
		$display("   [%0d] after load: applies %0d verdict %h p2wr %h beats %h drops %h drain %h bank %0d frozen %b reject %b",
		         cyc, cart_save.diag_applies, cart_save.diag_verdict, cart_save.diag_p2wr,
		         stage_diag_beats, stage_diag_drops, sc_diag_drain, mc_stage_bank, mc_frozen, mc_apply_reject);
		if (!ld_ok) fail("the Memory load did not report ok");
		if (cart_save.diag_verdict !== 16'h8001) fail($sformatf("the state apply's verdict is %h, not 8001 (state, accepted)", cart_save.diag_verdict));
		if (mc_apply_reject !== 1'b0 || mc_frozen !== 1'b0) fail("the state apply rejected or froze");
		if (n_state_apply != 1 || n_state_done != 1) fail($sformatf("%0d state_apply / %0d state_done pulses, expected 1 / 1", n_state_apply, n_state_done));
		if (n_state_commits != 1) fail($sformatf("%0d state commits, expected 1", n_state_commits));
		if (t_commit >= 0) begin
			// L2: slot_busy_q (host_busy one clock late) was low for the commit
			if (commit_hb !== 1'b0)
				fail($sformatf("the state commit flipped the bank while the host port was busy (commit %0d, host_busy high at the committing edge's slot_busy_q sample)", t_commit));
			hold_cyc = t_commit - t_fin - 1;
			if (hold_cyc > 0 && commit_hbfall > 2)
				fail($sformatf("the held commit came %0d samples after host_busy fell (at most 2)", commit_hbfall));
			// no mid-load flush: the commit waits out the drain's own host tail
			if (!mf_ran && (hold_cyc < 12288 || hold_cyc > 98304))
				fail($sformatf("no flush: the commit held %0d clk after S_FINISH, expected 0.25..2 ms (the drain's host tail)", hold_cyc));
		end
		$display("   [%0d] commit: %0d clk after state_apply, %0d after the last drain beat, %0d after S_FINISH (%0d us)",
		         cyc, t_commit - t_sapply, t_commit - t_last_drain, t_commit - t_fin - 1, $rtoi((t_commit - t_fin - 1) / 49.152));

		// ---- play, quit ----------------------------------------------------------
		repeat ($rtoi((P_PLAYUS) * 49.152)) @(posedge clk_sys);
		b_after = cbank(0);
		$display("   [%0d] quit: committed bank %0d, engine state %0d", cyc, b_after, est);
		cmp_vs_mimg("committed bank at quit", 0, b_after);
		if (d_hdr != 0 || d_pay != 0 || d_crc != 0) fail("the committed bank at quit is not the loaded Memory's image");
		for (i = 0; i < SLOTW; i = i + 1) img[i] = cmem[b_after*BANKW + i];
		flush_words = (P_FLUSH == 2) ? SLOTW/2 : (P_FLUSH == 1) ? 32 : 0;
		if (flush_words > 0) begin
			apf_flush(flush_words);
			n = 0;
			for (i = 0; i < 2*flush_words; i = i + 1) if (flushed[i] !== img[i]) n = n + 1;
			if (n != 0) fail($sformatf("the quit flush differs from the committed bank in %0d words", n));
			if (mc_stage_bank !== b_after) fail("the committed bank flipped during the quit flush");
		end

		// ---- relaunch on the quit flush ------------------------------------------
		if (P_RELAUNCH && P_FLUSH == 2) begin
			for (i = 0; i < SLOTW; i = i + 1) img[i] = flushed[i];
			relaunch_on_img;
			$display("   [%0d] relaunch on the quit flush: applies %0d verdict %h frozen %b", cyc,
			         cart_save.diag_applies, cart_save.diag_verdict, mc_frozen);
			if (cart_save.diag_verdict !== 16'h0001 || mc_frozen !== 1'b0)
				fail($sformatf("the relaunch refused the quit flush (verdict %h, frozen %b)", cart_save.diag_verdict, mc_frozen));
		end

		// ---- relaunch on the file flushed during the load --------------------------
		// A JUNK session's flush that is wholly the old committed bank is that
		// bank's junk: no image, so no relaunch can accept it (a delivered
		// non-image is refused and kept, verdict 0006, frozen). Nor does such a
		// file exist on the card: nothing was delivered and save_present was
		// low when the flush began, so core_top never raised the slot's size
		// and APF writes nothing. That premise is checked; the relaunch is
		// skipped (reported as relaunch verdict=skip).
		if (P_RELAUNCHMID && mf_ran && !mf_mixed && mf_new == 0 && oldimg[0] !== 16'h4E47) begin
			rl_skip = 1;
			$display("   [%0d] relaunch on the mid-load file skipped: it is wholly the old committed bank, which holds no image (words 0-1 %h %h); save_present was %b when the flush began, so APF would have written no file",
			         cyc, midf[0], midf[1], mf_sp_start);
			if (mf_sp_start !== 1'b0)
				fail("the flush of a save-less session's junk bank began with save_present high: APF would write that junk as the .sav");
		end else if (P_RELAUNCHMID && mf_ran) begin
			if (P_MIDWORDS != SLOTW/2) fail("RELAUNCHMID needs the whole slot flushed (MIDWORDS=16256)");
			for (i = 0; i < SLOTW; i = i + 1) img[i] = midf[i];
			relaunch_on_img;
			rl_verdict = cart_save.diag_verdict;
			rl_frozen  = mc_frozen;
			$display("   [%0d] relaunch on the mid-load file (words 0-3 %h %h %h %h): applies %0d verdict %h p2wr %h frozen %b save_present %b",
			         cyc, midf[0], midf[1], midf[2], midf[3],
			         cart_save.diag_applies, cart_save.diag_verdict, cart_save.diag_p2wr, mc_frozen, save_present);
			if (rl_verdict !== 16'h0001 || rl_frozen !== 1'b0)
				fail($sformatf("the next boot refused the file flushed during the load (verdict %h, frozen %b)", rl_verdict, rl_frozen));
		end

		if (chip_oob) fail("a PSRAM access beyond the two staging banks");
		if (stage_diag_drops !== 16'd0) fail($sformatf("%0d host beats dropped by the skid", stage_diag_drops));
		end_run;
	end

	initial begin
		repeat (3000) #1_000_000;
		fail($sformatf("WATCHDOG at cycle %0d (3 s simulated)", cyc));
		end_run;
	end

endmodule

`default_nettype wire
