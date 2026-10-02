// tb_rc6x_combo -- rc6 family X: the COMBINED rc6 staging behaviour and the
// T7 reproduction, on the REAL rc6 RTL with core_top's rc6 glue verbatim.
//
// Built from the scratch investigation benches tb_t7r_bench.sv (T7 sweep),
// tb_r6c_bench.sv / tb_r6x_bench.sv (+FLUSHAPPLY, +RACEOFS, +RELAUNCHMID,
// +FDFULL). Those compiled scratch copies of the engine and stage_mem and an
// rc5 glue; this one compiles only target/pocket and upstream (or, for the
// mutation checks, a mutant copy sed-made by sim/run_rc6_combo.sh).
//
// REAL, unmodified (sim/run_rc6_combo.sh):
//   target/pocket/data_loader.sv      APF save-slot delivery (clk_74a -> clk_sys)
//   target/pocket/data_unloader.sv    APF flush, READ_MEM_CLOCK_DELAY 32
//   target/pocket/ngpc_stage_mem.sv   skid FIFO, L1 read claim, L3B ready
//   target/pocket/psram.sv            the PSRAM controller, 49.152 MHz timing
//   target/pocket/ngpc_cart_save.sv   the save engine, DEFAULT QUIET_CLOCKS,
//                                     NGPC_SAVE_DIAG on (as the release build)
//   target/pocket/ngpc_state_cart.sv  the copier, default DR_WAIT_TIMEOUT
//   target/pocket/ngpc_savestate_bridge.sv + upstream savestates.sv
//   upstream/rtl/cart/ngp_cart_overlay_geometry.sv
//   sim/sim_dcfifo.v, sim/sim_synch3.v (the existing Icarus stand-ins)
//
// core_top.v (rc6) glue reproduced verbatim: the L3 part A write-port arbiter
// (apf_save_wr, sc_replay cleared by reset_in, sc_beat, sc_go, the addr/data/
// bank mux on sc_go, sc_host_ready), host_busy ALONE into the engine (L2),
// the engine's host_rd_i = stage_host_rd (data_unloader's read_en, the same
// strobe stage_mem claims on; core_top -> ngpc_machine .host_rd, rc6
// follow-up: the state commit holds on it for the two clocks before
// slot_busy_q sees the read, and the pass publish waits on it), the machine's
// save_slot_wr = bios_wr_raw && ld_is_save, the bridge's save_busy_i =
// mc_save_busy = ngpc_machine save_busy_state = the engine's boot_hold_o (rc6
// follow-up; it was busy_o), the copier's engine-port mux, slots_settled
// (SETTLE74 SHORTENED from 37,125,000 to keep runs short).
//
// MODELED: the CellularRAM chip at the PSRAM pins, the cartridge SDRAM
// background port (random 2..P2MAX latency), the flash die's reports, the
// machine behind savestates.sv, APF's bridge (delivery, flush, savestate
// commands).
//
// Session: reset, cart, APF delivers the pre-T7 file, boot apply; Memory
// captured; SAVES in-game saves of block 34; APF load command at +DELAYUS /
// +DELAYCYC after the last planned flash event; play; quit flush; optional
// relaunch. Optional mid-load whole-slot flushes:
//   +FDFULL=N       N clk after draining rises (the spare bank is poisoned
//                   with 0xDEAD first, so a lost drain beat is visible)
//   +FLUSHAPPLY=N   N clk after the copier's state_apply pulse
//   +RACEOFS=K      the first flush read when stage_mem.host_idle is K short
//                   of terminal while the accepted commit waits (L2 hold)
//   +RELAUNCHMID=1  relaunch on the mid-load file: verdict and freeze
//   +OLDW0=h        the committed bank's word 0 made to differ first, so the
//                   source of the flush's first word is visible
// Optional flush across the publish of the pass after the last save:
//   +PUBRACE=K      a flush of +MIDWORDS words starting K clk after that pass
//                   enters S_STAGE_HDR at header index +PUBHDR (default 29);
//                   the K that lands the first strobe on the clock of the
//                   publish decision is reported as 'hit' (+EXPECT_PUBHIT=1)
// FAULT INJECTION (labelled, not RTL): +FORCEDRAIN=x forces stage_current for
// one clock at pass header index x; +PAUSEDRAIN=n holds the copier's ready
// low for +PAUSELEN clocks at drain count n.
//
// MONITORS (rc6 rewrite). The rc5 'host writes lost to host reads' / 'clobber
// cycles' counters counted the CONDITION of rc5's L1 hazard (a host read
// while a popped write was pending), which with L1 is a harmless wait. They
// are replaced by two scoreboards that count real loss:
//   ARB  every APF save-slot beat and every copier drain beat must reach the
//        skid as exactly one push with its own address, data and bank, in
//        order per writer (a collision replays the copier's beat); a beat
//        still owed at the end, a push matching neither writer, or a push
//        into a full skid (diag_drops) is loss.
//   SKID every skid push must reach the PSRAM as one write with the same
//        address and data, in order; a skipped entry is loss.
// FLIPS (rc6 follow-up, every run): the committed bank never flips on a clock
//   where APF's read strobe (the engine's host_rd_i) is up, nor between a
//   flush's first read and its last.
// T7 FLAG (ngpc_cart_save diag_wr_drain, header word 23 bit 14):
//   * the flag rises iff the engine issued a staging write while draining;
//   * every engine write of header word 23 carries the flag's current value;
//   * a committed bank whose word 16/17/18 was last written by the ENGINE
//     during a drain (a T7-shaped stray) must carry bit 14 in word 23, and so
//     must its flushed file;
//   * RTL-only runs: the flag never rises, no engine write while draining,
//     and bit 14 of word 23 is never written by anyone.
//
// PASS/FAIL per run: '== RC6X SCENARIO <tag> PASS' or '... FAIL (<n>)', from
// the bench's own checks plus the expectations given by plusargs:
//   +TAG=name  +EXPECT_LOAD=1|0  +EXPECT_MID=old|new  +EXPECT_COMMIT=after|before
//   +EXPECT_RELAUNCH=1 (verdict 0001, not frozen)  +EXPECT_FILEFLAG=1
//   +EXPECT_FINAL_MEM=1 (the committed bank and flushed file equal the Memory)
//   +EXPECT_COMMIT=before means the commit is in place for the flush's first
//   claim (stage_mem latches the bank at the claim, not at the strobe)
//
// Run: wsl -e sh /mnt/c/FPGA/ngpc-rc4/sim/run_rc6_combo.sh

`timescale 1ns / 1ps
`default_nettype none

module tb_rc6x_combo;

	// ---- clocks ------------------------------------------------------------
	reg clk_sys = 0;
	reg clk_74a = 0;
	always #10.173 clk_sys = ~clk_sys;   // 49.152 MHz
	always #6.734  clk_74a = ~clk_74a;   // 74.25 MHz

	integer cyc = 0;
	// nonblocking: every block that stamps an edge reads the same value (a
	// blocking count raced the monitors, one stamp per block order)
	always @(posedge clk_sys) cyc <= cyc + 1;

	reg reset_in = 1;

	// ---- run parameters (plusargs) -------------------------------------------
	integer P_SAVES    = 1;        // in-game saves (0, 1, 2)
	integer P_GAPUS    = 0;        // save 1's last event -> save 2's start, us
	integer P_DELAYCYC = 0;        // load command, clk_sys after the last event
	integer P_SAME     = 0;        // 1: the save rewrites identical data
	integer P_FLUSH    = 1;        // 0 none, 1 first 64 words, 2 whole slot
	integer P_PAUSEDRAIN = -1;     // FAULT INJECTION (not RTL): >=0 holds sc_host_ready low
	integer P_PAUSELEN   = 5000;   // for P_PAUSELEN clocks once diag_drain reaches this count
	integer P_FORCEDRAIN = -1;     // FAULT INJECTION (not RTL): >=0 forces stage_current
	                               // high for one clock when the pass reaches this header index
	integer P_RELAUNCH = 0;        // 1: relaunch after quit and flush again
	integer P_P2MAX    = 10;       // p2 latency 2..P2MAX clocks
	integer P_SEED     = 1;
	integer P_PROGPER  = 60;       // clk_sys between byte programs
	integer P_NOERASE  = 0;        // 1: the save programs without erasing
	integer P_REDELIVER = 0;       // 1: APF re-delivers the file right before the load
	integer P_FLUSHDRAIN = 0;      // 1: APF flushes the slot while the drain runs
	integer P_QUITSAVE = 0;        // >0: a flash write this many us before quit
	integer P_PLAYUS   = 5000;     // play time between load done and quit
	integer P_FDFULL = -1;         // >=0 whole-slot flush this many clk after draining rises
	integer P_FLUSHAPPLY = -1;     // R6C: >=0 flush this many clk after state_apply
	integer P_RACEOFS    = -1;     // R6C: >=0 flush when host_idle is this short of terminal
	integer P_RELAUNCHMID = 0;     // R6C: 1 relaunch on the mid-load flushed file
	integer P_MIDWORDS = 16256;    // R6C: 32-bit words the mid-load flush reads
	integer P_OLDW0 = -1;          // rc6X: >=0 the committed bank's word 0 before the mid-load flush
	                               // (a committed bank that is not a valid image, e.g. PSRAM left over
	                               // from a session without a save) -- makes word 0's source visible
	integer P_PUBRACE = -1;        // rc6X: >=0 a flush of MIDWORDS words starts this many clk after the
	                               // pass after the last save enters S_STAGE_HDR at header index PUBHDR
	integer P_PUBHDR  = 29;        //        (lands the first read on the clock of the publish decision)
	integer P_VERBOSE  = 0;
	integer P_DGAP     = 20;       // clk_74a between delivery strobes (APF ~75)
	integer P_RGAP     = 200;      // clk_74a between flush reads
	integer seedv;
	// rc6X expectations (-1: not checked)
	reg [8*40-1:0] P_TAG = "untagged";
	integer E_LOAD = -1;           // 1 the load must succeed, 0 it must fail
	integer E_MID  = -1;           // 0 the mid-load file must be wholly old, 1 wholly new
	integer E_COMMIT = -1;         // 1 the commit must land after the mid-load flush, 0 before its first read
	integer E_RELAUNCH = 0;        // 1 the relaunch on the mid-load file: verdict 0001, not frozen
	integer E_FILEFLAG = 0;        // 1 the quit file must carry word 23 bit 14 (a T7-shaped stray)
	integer E_FINAL_MEM = -1;      // 1 committed bank and flushed file equal the Memory image
	integer E_PUBHIT = 0;          // 1 the PUBRACE flush's strobe must be up on the clock of the publish decision

	localparam integer SETTLE74 = 150000;   // ~2 ms (core_top: 37,125,000)

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
		.save_busy_i     (overlay_boot_hold),  // core_top rc6: mc_save_busy = machine save_busy_state = boot_hold_o
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

	// ---- core_top's staging glue (rc6), verbatim --------------------------------
	// core_top.v: ld_is_save, the L3 part A arbiter beside the copier, and the
	// machine's .save_slot_wr (bios_wr_raw && ld_is_save).
	wire        ld_is_save = bios_addr_raw[25];
	wire        sc_host_wr;
	wire [24:0] sc_host_addr;
	wire [15:0] sc_host_data;
	wire        mc_stage_current, mc_save_busy, mc_stage_bank;
	wire        stage_host_wr;
	wire        stage_host_ready;
	wire [27:0] stage_host_wr_addr;
	wire [15:0] stage_host_wr_data;
	wire        stage_wr_bank;
	wire        sc_host_ready;

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
	wire        save_slot_wr  = bios_wr_raw && ld_is_save;   // ngpc_machine .save_slot_wr

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
	// Write side as tb_stage_host (shadow sampling one clock back); read side
	// drives dq from the latched address while ce0_n and oe_n are low.
	reg [15:0] cmem [0:65535];
	reg [21:0] c_addr_l = 0;
	reg        p_we = 1, p_ce = 1, p_ub = 1, p_lb = 1;
	reg [15:0] p_dq = 0;
	reg [21:0] p_addr = 0;
	reg        chip_oob = 0;
	integer    n_chip_wr = 0;

	always @(posedge clk_sys) begin
		p_we <= cram0_we_n; p_ce <= cram0_ce0_n;
		p_ub <= cram0_ub_n; p_lb <= cram0_lb_n;
		p_dq <= cram0_dq;   p_addr <= c_addr_l;
		if (!cram0_ce0_n && !cram0_adv_n) c_addr_l <= {cram0_a, cram0_dq};
		if (cram0_we_n && !p_we && !p_ce) begin
			if (p_addr[21:16] != 6'd0) chip_oob <= 1'b1;
			if (!p_ub) cmem[p_addr[15:0]][15:8] <= p_dq[15:8];
			if (!p_lb) cmem[p_addr[15:0]][7:0]  <= p_dq[7:0];
			n_chip_wr = n_chip_wr + 1;
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

	// The engine: target/pocket/ngpc_cart_save.sv, or a mutant copy of it with
	// the same module name (sim/run_rc6_combo.sh mutants).
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
		.host_busy_i     (host_busy),          // core_top rc6: the staging host port alone (L2)
		.host_rd_i       (stage_host_rd),      // core_top rc6: stage_host_rd -> ngpc_machine .host_rd
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
	integer    n_p2wr = 0;
	always @(posedge clk_sys) begin
		p2_done <= 1'b0;
		if (p2_req === 1'b1 && !p2_busy) begin
			p2_busy <= 1'b1;
			p2_we_q <= p2_we;
			p2_a_q  <= p2_addr[20:1];
			p2_wd_q <= p2_wdata;
			p2_cnt  <= 2 + ($urandom % (P_P2MAX - 1));
			if (p2_we) n_p2wr = n_p2wr + 1;
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
	// Monitors
	// =========================================================================
	integer t_last_ev   = 0;      // cycle of the last flash event
	integer t_drain_up  = -1, t_drain_dn = -1;
	integer t_ldreq     = -1;
	integer n_pass_start = 0, n_publish = 0, n_defer = 0;
	integer n_pub_rd_hit = 0, t_pub_dec = -1;   // rc6X PUBRACE
	integer t_lastplan = 0;                     // the last planned flash event (set by the run)
	integer n_pass_in_drain = 0, n_hdr_in_drain = 0;
	integer n_engreq_in_drain = 0, n_engwr_in_drain = 0, n_ready_in_drain = 0, n_ready_mid_drain = 0;
	integer n_apply_rd_in_drain = 0;
	// ---- rc6X: host-write loss scoreboards --------------------------------
	// They replace rc5's 'host writes lost to host reads' counter, which
	// counted the CONDITION of the L1 hazard (a host read while a popped write
	// is pending) -- with L1 a harmless wait, kept below as n_rd_wait, info only.
	// ARB: each APF save-slot beat and each copier drain beat, in order per
	// writer, must appear at the stage port (stage_host_wr) exactly once with
	// its own {bank, word, data}. A push into a full skid is a drop.
	// SKID: each skid push must reach the PSRAM as one host write, in order.
	localparam integer QN = 131072;
	reg [31:0] qa [0:QN-1];
	reg [31:0] qc [0:QN-1];
	reg [31:0] qs [0:QN-1];
	integer qa_w = 0, qa_r = 0, qc_w = 0, qc_r = 0, qs_w = 0, qs_r = 0;
	integer arb_lost = 0, arb_bad = 0, arb_drop = 0, arb_left = 0, arb_replays = 0, arb_coll = 0;
	integer skid_lost = 0, skid_bad = 0, skid_left = 0, skid_pushes = 0, skid_issues = 0;
	integer n_rd_wait = 0;
	always @(posedge clk_sys) begin : scoreboards
		reg [31:0] v;
		integer k, hit;
		if (reset_in) begin
			arb_left  = arb_left + (qa_w - qa_r) + (qc_w - qc_r);
			skid_left = skid_left + (qs_w - qs_r);
			qa_r = qa_w; qc_r = qc_w; qs_r = qs_w;
		end else begin
			// ---- stage 1: the write-port arbiter ----
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
				// the writer's next beat; a match further on means beats were skipped (lost)
				for (k = 0; k < 8 && !hit && qa_r + k < qa_w; k = k + 1)
					if (qa[(qa_r + k) % QN] === v) begin hit = 1; arb_lost = arb_lost + k; qa_r = qa_r + k + 1; end
				for (k = 0; k < 8 && !hit && qc_r + k < qc_w; k = k + 1)
					if (qc[(qc_r + k) % QN] === v) begin hit = 1; arb_lost = arb_lost + k; qc_r = qc_r + k + 1; end
				if (!hit) begin
					arb_bad = arb_bad + 1;
					if (arb_bad <= 4) $display("   [%0d] ARB: stage-port beat %h matches neither writer's next beat (APF %0d owed, copier %0d owed)",
					                           cyc, v, qa_w - qa_r, qc_w - qc_r);
				end
			end
			// ---- stage 2: skid -> PSRAM ----
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
				for (k = 0; k < 600 && !hit && qs_r + k < qs_w; k = k + 1)
					if (qs[(qs_r + k) % QN] === v) begin hit = 1; skid_lost = skid_lost + k; qs_r = qs_r + k + 1; end
				if (!hit) begin
					skid_bad = skid_bad + 1;
					if (skid_bad <= 4) $display("   [%0d] SKID: PSRAM host write %h matches no queued skid entry", cyc, v);
				end
			end
		end
	end
	// owed beats at the end of a quiet period are lost beats
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

	// ---- rc6X: the T7 flag (diag_wr_drain, header word 23 bit 14) ----------
	integer engwr_epoch = 0;        // engine staging writes while draining since reset / cart_replace
	integer n_flag_rise = 0, n_flag_incons = 0, n_w23_eng = 0, n_w23_bad = 0, n_w23_b14 = 0;
	integer t_flag_rise = -1;
	reg     flag_q = 1'b0;
	always @(posedge clk_sys) begin : t7flag
		if ((cart_save.diag_wr_drain === 1'b1) !== (engwr_epoch > 0)) begin
			n_flag_incons = n_flag_incons + 1;
			if (n_flag_incons <= 4) $display("   [%0d] T7 FLAG: diag_wr_drain %b but %0d engine writes while draining this epoch",
			                                  cyc, cart_save.diag_wr_drain, engwr_epoch);
		end
		if (cart_save.diag_wr_drain === 1'b1 && flag_q !== 1'b1) begin
			n_flag_rise = n_flag_rise + 1;
			t_flag_rise = cyc;
			$display("   [%0d] T7 FLAG: diag_wr_drain rises (engine state %0d, hdr_idx %0d, drain %0d)",
			         cyc, est, cart_save.hdr_idx, sc_diag_drain);
		end
		flag_q = (cart_save.diag_wr_drain === 1'b1);
		if (reset_in === 1'b1 || cart_replace === 1'b1) engwr_epoch = 0;
		else if (stage_req === 1'b1 && stage_we === 1'b1 && sc_draining === 1'b1) engwr_epoch = engwr_epoch + 1;
		// every engine write of header word 23 carries the flag as it stands
		if (reset_in !== 1'b1 && stage_req === 1'b1 && stage_we === 1'b1 && sc_rd_active !== 1'b1 &&
		    stage_addr[15:1] == 15'd23) begin
			n_w23_eng = n_w23_eng + 1;
			if (stage_wdata[14] !== cart_save.diag_wr_drain) begin
				n_w23_bad = n_w23_bad + 1;
				$display("   [%0d] T7 FLAG: engine writes word 23 = %h with the flag %b", cyc, stage_wdata, cart_save.diag_wr_drain);
			end
		end
	end
	// last writer of each header word 16..31, per bank: 1 = the engine while draining
	reg lw_stray0 [16:31];
	reg lw_stray1 [16:31];
	initial begin : lw_init
		integer k2;
		for (k2 = 16; k2 < 32; k2 = k2 + 1) begin lw_stray0[k2] = 1'b0; lw_stray1[k2] = 1'b0; end
	end
	function integer bank_stray(input integer b);
		if (b == 0) bank_stray = lw_stray0[16] || lw_stray0[17] || lw_stray0[18];
		else        bank_stray = lw_stray1[16] || lw_stray1[17] || lw_stray1[18];
	endfunction
	integer n_hdrwr_log = 0, n_eng_hdrwr_in_drain = 0;
	integer n_drain_beats = 0, n_state_apply = 0;
	integer max_skid = 0;
	integer n_flips = 0;
	// R6C monitors
	// R6C: cycle-level view of the L2 hold around the cycle host_busy falls (VERBOSE>=3)
	always @(posedge clk_sys) if (P_VERBOSE >= 3 && cart_save.in_apply === 1'b1 && cart_save.from_state === 1'b1 &&
	                              stage_mem.host_idle >= 20'd499996)
		$display("   [%0d] GATE host_idle %0d host_busy %b state %0d verify %b bank %b slot_busy_q %b", cyc, stage_mem.host_idle, host_busy,
		         cart_save.state, cart_save.verify_pass, mc_stage_bank, cart_save.slot_busy_q);
	integer t_commit = -1, t_sapply = -1, t_mf_start = -1, t_mf_end = -1, t_rd_first = -1;
	integer t_mf_done = -1, t_last_drain = -1;
	reg     sfa_q = 1'b0;
	integer pay_len = 0;
	reg     mf_live = 0;
	// rc6X: the bank each mid-load flush read is claimed from (ngpc_stage_mem
	// latches active_bank_i into the pending read at the claim)
	integer mf_bank0 = 0, mf_claims_old = 0, mf_claims_new = 0, mf_first_claim_bank = -1;
	integer t_claim_first = -1;    // sample of the mid-load flush's first claim (it latches the bank seen here)
	always @(posedge clk_sys) if (mf_live && stage_mem.host_pending === 1'b0 && stage_mem.host_rd_claim === 1'b1) begin
		if (mf_first_claim_bank < 0) begin
			mf_first_claim_bank = mc_stage_bank;
			t_claim_first = cyc;
			$display("   [%0d] first mid-load flush read claimed from bank %0d (word %0d); engine state %0d, slot_busy_q %b, host_busy %b",
			         cyc, mc_stage_bank, stage_host_rd_addr[15:1], est, cart_save.slot_busy_q, host_busy);
		end
		if (mc_stage_bank == mf_bank0) mf_claims_old = mf_claims_old + 1;
		else                           mf_claims_new = mf_claims_new + 1;
	end
	// rc6X follow-up: the committed bank never flips on a clock where APF's
	// read strobe is up (the engine's host_rd_i: a claim on that clock would
	// latch the old bank while every later read sees the new one), nor at all
	// once a flush has issued its first read and until its last one returned
	// (a file of two images). Every run, every flush (mid-load, quit,
	// relaunch). A flip seen at sample t was made at the edge before it, where
	// the engine saw the strobe as sampled at t-1.
	reg     fl_live = 1'b0, fl_rd_seen = 1'b0;   // apf_flush in progress / it has read
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
	always @(posedge clk_sys) begin
		if (mf_live && stage_host_rd === 1'b1 && t_rd_first < 0) t_rd_first = cyc;
		if (mc_state_done === 1'b1) t_mf_done = cyc;
		if (mc_state_apply === 1'b1) t_sapply = cyc;
		if (sc_host_wr === 1'b1) t_last_drain = cyc;
	end
	reg     bank_q = 1'b0;
	reg     drn_q = 1'b0;
	reg     mc_state_done_seen = 1'b0;   // a state apply has been requested since draining rose
	reg [4:0] st_q = 5'd0;
	reg     pub_live = 0;
	reg [15:0] cnt_seen [0:4095];   // counter values written into header words
	integer n_cnt_seen = 0;

	wire [4:0] est = cart_save.state;
	wire       pass_active = (est != 5'd0) && !cart_save.in_apply;
	wire       hdr_phase   = (est == 5'd6) || (est == 5'd7);

	always @(posedge clk_sys) begin
		if (!reset_in) begin
			if (event0 === 1'b1) t_last_ev = cyc;
			if (sc_draining === 1'b1 && drn_q !== 1'b1) begin
				t_drain_up = cyc;
				if (P_VERBOSE) $display("   [%0d] draining rises (engine state %0d, bank %0d, drain %0d, beats %0d)",
				                        cyc, est, mc_stage_bank, sc_diag_drain, stage_diag_beats);
			end
			if (sc_draining !== 1'b1 && drn_q === 1'b1) t_drain_dn = cyc;
			drn_q = (sc_draining === 1'b1);
			if (cs_load_req === 1'b1) t_ldreq = cyc;
			if (mc_state_apply === 1'b1) begin n_state_apply = n_state_apply + 1; mc_state_done_seen = 1'b1; end
			if (sc_draining === 1'b1 && drn_q !== 1'b1) mc_state_done_seen = 1'b0;
			if (sc_host_wr === 1'b1) n_drain_beats = n_drain_beats + 1;
			if (stage_mem.skid_fill > max_skid) max_skid = stage_mem.skid_fill;

			// pass start / publish / defer
			if (st_q == 5'd0 && est == 5'd1) begin
				n_pass_start = n_pass_start + 1;
				if (P_VERBOSE) $display("   [%0d] pass starts (draining %b, host_busy %b, rel %0d)",
				                        cyc, sc_draining, host_busy, cyc - t_last_ev);
			end
			if (est == 5'd7 && stage_done === 1'b1 && cart_save.hdr_idx == 6'd31) begin
				// rc6X: a publish the strobe alone holds off (the follow-up's
				// !host_rd_i): every other condition is met on this clock
				if (stage_host_rd === 1'b1 && !cart_save.stage_pending && cart_save.flash_quiet &&
				    host_busy !== 1'b1 && sc_draining !== 1'b1 && !cart_save.refused_q && !cart_save.saw_save_wr) begin
					n_pub_rd_hit = n_pub_rd_hit + 1;
					$display("   [%0d] the pass's publish decision falls on a clock where APF's read strobe is up and the port is otherwise idle", cyc);
				end
				if (t_pub_dec < 0 && cyc > t_lastplan) t_pub_dec = cyc;
				if (!cart_save.stage_pending && cart_save.flash_quiet && !(host_busy || sc_draining) &&
				    stage_host_rd !== 1'b1 && !cart_save.refused_q && !cart_save.saw_save_wr) begin
					n_publish = n_publish + 1;
					if (P_VERBOSE) $display("   [%0d] pass publishes bank %0d (rel %0d)", cyc, ~mc_stage_bank, cyc - t_last_ev);
				end else begin
					n_defer = n_defer + 1;
					if (P_VERBOSE) $display("   [%0d] pass deferred (pending %b quiet %b hb %b drn %b) rel %0d",
					                        cyc, cart_save.stage_pending, cart_save.flash_quiet, host_busy,
					                        sc_draining, cyc - t_last_ev);
				end
			end
			st_q = est;

			if (sc_draining === 1'b1) begin
				if (pass_active) n_pass_in_drain = n_pass_in_drain + 1;
				if (hdr_phase)   n_hdr_in_drain  = n_hdr_in_drain + 1;
				if (stage_req === 1'b1 && sc_rd_active !== 1'b1) begin
					if (cart_save.in_apply) n_apply_rd_in_drain = n_apply_rd_in_drain + 1;
					else n_engreq_in_drain = n_engreq_in_drain + 1;
					if (stage_we === 1'b1) n_engwr_in_drain = n_engwr_in_drain + 1;
				end
				if (stage_ready === 1'b1 && !cart_save.in_apply && !mc_state_done_seen) begin
					n_ready_in_drain = n_ready_in_drain + 1;
					if (state_cart.st != 4'd13 && sc_diag_drain > 16'd16 && state_cart.st != 4'd11 && state_cart.st != 4'd12)
						n_ready_mid_drain = n_ready_mid_drain + 1;
				end
			end
			if ((mc_stage_bank ^ bank_q) === 1'b1) begin
				n_flips = n_flips + 1;
				// R6C: the state apply's commit (ngpc_cart_save.sv:1189)
				// (the flip is seen one sample after the edge that made it, when
				// in_apply has already cleared: sfa_q is the previous sample)
				if (sfa_q) t_commit = cyc;
				if (P_VERBOSE) $display("   [%0d] committed bank -> %0d%0s", cyc, mc_stage_bank,
				                        sfa_q ? " (state apply commit)" : "");
			end
			bank_q = mc_stage_bank;
			sfa_q  = (cart_save.in_apply === 1'b1) && (cart_save.from_state === 1'b1);
		end
	end

	// FAULT INJECTION, off by default: let the copier see stage_current for one
	// clock while a pass is in its header walk (what a glitch on that path, or
	// any RTL route to M1, would do). Labelled in the log; not a RTL finding.
	reg fd_done = 0;
	always @(posedge clk_sys) begin
		if (P_FORCEDRAIN >= 0 && !fd_done && est == 5'd6 && cart_save.hdr_idx == P_FORCEDRAIN &&
		    state_cart.st == 4'd13) begin
			fd_done = 1;
			$display("   [%0d] FAULT INJECTION: stage_current forced high for one clock at pass header index %0d", cyc, P_FORCEDRAIN);
			force state_cart.stage_current_i = 1'b1;
			@(negedge clk_sys); @(posedge clk_sys); #1;
			release state_cart.stage_current_i;
		end
	end

	// FAULT INJECTION, off by default: the copier's skid backpressure is held
	// low for P_PAUSELEN clocks once the drain count reaches P_PAUSEDRAIN, so
	// the skid can empty mid-drain. Labelled in the log; not a RTL finding.
	reg pd_done = 0;
	always @(posedge clk_sys) begin
		// An odd count is taken only while the copier waits between the two
		// halves of a word (I_DR_WR_HI, real ready low): the copier is then held
		// THERE, which the real backpressure can never do with an emptying skid.
		if ((P_PAUSEDRAIN >= 0 && !pd_done && sc_draining === 1'b1 && sc_diag_drain == P_PAUSEDRAIN &&
		    (P_PAUSEDRAIN % 2 == 0)) || (P_PAUSEDRAIN >= 0 && !pd_done && sc_draining === 1'b1 && P_PAUSEDRAIN % 2 == 1 &&
		    sc_diag_drain == P_PAUSEDRAIN - 1 && state_cart.st == 4'd9 && stage_mem.host_wr_ready_o === 1'b1)) begin
			pd_done = 1;
			$display("   [%0d] FAULT INJECTION: drain paused %0d clocks at drain count %0d (copier st %0d)", cyc, P_PAUSELEN, sc_diag_drain, state_cart.st);
			@(negedge clk_sys);   // after this edge's copier step, race-free
			force state_cart.sc_host_ready = 1'b0;
			repeat (P_PAUSELEN) @(posedge clk_sys);
			#1 release state_cart.sc_host_ready;
		end
	end

	// Every PSRAM write that lands on a header word, at the moment the
	// controller starts it (stage_mem's ps_write_en), with its source.
	always @(posedge clk_sys) begin
		if (!reset_in && stage_mem.ps_write_en === 1'b1 && stage_mem.ps_addr[14:0] < 15'd32) begin : hw
			reg is_eng;
			integer idx;
			is_eng = (stage_mem.eng_active === 1'b1) && (stage_mem.eng_active_rd !== 1'b1);
			idx = stage_mem.ps_addr[4:0];
			n_hdrwr_log = n_hdrwr_log + 1;
			if (is_eng && (idx >= 16 && idx <= 18) && n_cnt_seen < 4096) begin
				cnt_seen[n_cnt_seen] = stage_mem.ps_data_in;
				n_cnt_seen = n_cnt_seen + 1;
			end
			if (is_eng && sc_draining === 1'b1) n_eng_hdrwr_in_drain = n_eng_hdrwr_in_drain + 1;
			if (idx >= 16) begin
				if (stage_mem.ps_addr[15]) lw_stray1[idx] = is_eng && (sc_draining === 1'b1);
				else                       lw_stray0[idx] = is_eng && (sc_draining === 1'b1);
			end
			if (idx == 23 && stage_mem.ps_data_in[14] === 1'b1) begin
				n_w23_b14 = n_w23_b14 + 1;
				if (n_w23_b14 <= 4) $display("   [%0d] T7 FLAG: word 23 = %h written to bank %0d by %0s", cyc,
				                             stage_mem.ps_data_in, stage_mem.ps_addr[15], is_eng ? "ENGINE" : "HOST");
			end
			if (P_VERBOSE >= 2 || (P_VERBOSE && (idx == 16 || idx == 18 || idx == 22)) ||
			    (is_eng && sc_draining === 1'b1))
				$display("   [%0d] HDRWR bank %0d word %0d = %h by %0s  draining %b  beats %0d drops %0d drain %0d  eng st %0d hdr_idx %0d",
				         cyc, stage_mem.ps_addr[15], idx, stage_mem.ps_data_in, is_eng ? "ENGINE" : "HOST",
				         sc_draining, stage_diag_beats, stage_diag_drops, sc_diag_drain, est, cart_save.hdr_idx);
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

	// Block content for a generation: literals in 0xAxxx (never 0xFFFF and
	// never 0x2005), the rest erased.
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
	reg [15:0] deliv [0:SLOTW-1];
	reg [15:0] oldimg [0:SLOTW-1];    // R6C: committed bank at the state_apply pulse
	reg [15:0] midf   [0:SLOTW-1];    // R6C: the file flushed during the apply
	reg [15:0] primg  [0:SLOTW-1];    // rc6X PUBRACE: the build bank at the end of the flush
	integer    pr_diff = 0, pr_old = 0, pr_new = 0, pr_neither = 0;
	reg        pr_mixed = 0, pr_ran = 0, pr_done = 0;
	integer    mf_old = 0, mf_new = 0, mf_neither = 0, mf_diff = 0;
	integer    mf_first_new = -1, mf_last_old = -1;
	reg        mf_mixed = 0, mf_ran = 0;
	reg [15:0] rl_verdict = 16'hxxxx;
	reg        rl_frozen = 1'bx;
	integer    img_pk;
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

	// ---- errors ---------------------------------------------------------------
	integer errors = 0;
	task fail(input string msg);
		begin
			errors = errors + 1;
			$display("   FAIL %0s", msg);
		end
	endtask

	// =========================================================================
	// APF tasks
	// =========================================================================
	task apf_deliver_img;
		integer k;
		reg [31:0] d;
		begin
			for (k = 0; k < SLOTW; k = k + 1) deliv[k] = img[k];
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
			fl_rd_seen = 1'b0; fl_live = 1'b1;
			for (k = 0; k < nw32; k = k + 1) begin
				@(posedge clk_74a); bridge_addr <= SAVEBASE + k*4; bridge_rd <= 1;
				@(posedge clk_74a); bridge_rd <= 0;
				repeat (P_RGAP) @(posedge clk_74a);
				d = stage_bridge_rd_data;
				flushed[2*k]   = {d[23:16], d[31:24]};
				flushed[2*k+1] = {d[7:0],   d[15:8]};
			end
			fl_live = 1'b0;
			@(posedge clk_74a); bridge_addr <= 32'hF8000000;
		end
	endtask

	reg [31:0] image [0:WORDS-1];
	reg sv_ok, sv_done;
	task apf_save;
		integer k, n;
		begin
			sv_ok = 0; sv_done = 0;
			@(posedge clk_74a); ss_start_req <= 1;
			n = 0;
			while (start_ack !== 1'b1 && n < 10000) begin @(posedge clk_74a); n = n + 1; end
			if (start_ack !== 1'b1) fail("APF: no savestate_start_ack");
			@(posedge clk_74a); ss_start_req <= 0;
			n = 0;
			while (start_ok !== 1'b1 && start_err !== 1'b1 && n < SAVE_MAX74) begin @(posedge clk_74a); n = n + 1; end
			sv_done = (start_ok === 1'b1 || start_err === 1'b1);
			sv_ok   = (start_ok === 1'b1);
			if (!sv_done) fail("APF: the capture never reported ok or err");
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

	reg ld_ok = 0, ld_done = 0;
	task apf_load;
		integer n;
		begin
			ld_ok = 0; ld_done = 0;
			@(posedge clk_74a); ss_load_req <= 1;
			n = 0;
			while (load_ack !== 1'b1 && n < 10000) begin @(posedge clk_74a); n = n + 1; end
			if (load_ack !== 1'b1) fail("APF: no savestate_load_ack");
			@(posedge clk_74a); ss_load_req <= 0;
			n = 0;
			while (load_ok !== 1'b1 && load_err !== 1'b1 && n < LOAD_MAX74) begin @(posedge clk_74a); n = n + 1; end
			ld_done = (load_ok === 1'b1 || load_err === 1'b1);
			ld_ok   = (load_ok === 1'b1);
			if (!ld_done) fail("APF: the load never reported ok or err");
			repeat (8) @(posedge clk_74a);
			repeat (4) @(posedge clk_sys);
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
	reg save_abort = 0;
	reg abort_arm  = 0;   // armed only while the in-game saves run
	always @(posedge clk_sys) if (abort_arm && overlay_boot_hold === 1'b1 && !reset_in) save_abort <= 1'b1;

	// wait until an absolute cycle, abort-aware; returns 1 when aborted
	task wait_until(input integer t, output reg ab);
		begin
			ab = 0;
			while (cyc < t && !save_abort) @(posedge clk_sys);
			if (save_abort) ab = 1;
		end
	endtask

	// Planned duration of one save, start to its last dirty pulse.
	function integer save_len(input integer dummy);
		integer nb;
		begin
			nb = 2 * 3100;   // byte programs of block 34's literal words
			save_len = (P_NOERASE ? 0 : ERASE_CYC34) + nb * P_PROGPER;
		end
	endfunction

	integer n_events = 0;
	task pulse_event(input [5:0] blk);
		begin
			@(posedge clk_sys); block0 <= blk; event0 <= 1'b1; die_busy <= 2'b00;
			@(posedge clk_sys); event0 <= 1'b0;
			n_events = n_events + 1;
		end
	endtask

	// One in-game save of block 34, generation gen, started at absolute t0:
	// erase (die busy, then one report), then two byte programs per literal
	// word, one every P_PROGPER clocks (die busy ~18 clk, then one report).
	task do_save(input integer t0, input integer gen);
		integer w, bsel, k, tp, i;
		reg ab;
		reg [15:0] v;
		begin
			wait_until(t0, ab);
			if (!ab && !P_NOERASE) begin
				@(posedge clk_sys); die_busy <= 2'b01;
				wait_until(t0 + ERASE_CYC34 - 1, ab);
				if (!ab) begin
					for (i = 0; i < bn(34); i = i + 1) sdram[bw(34) + i] = 16'hFFFF;
					pulse_event(6'd34);
				end
			end
			k = 0;
			for (w = 0; w < bn(34) && !ab; w = w + 1) begin
				v = cval(gen, 34, w);
				if (v != 16'hFFFF) begin
					for (bsel = 0; bsel < 2 && !ab; bsel = bsel + 1) begin
						k = k + 1;
						tp = t0 + (P_NOERASE ? 0 : ERASE_CYC34) + k * P_PROGPER;
						wait_until(tp - 20, ab);
						if (!ab) begin
							@(posedge clk_sys); die_busy <= 2'b01;
							wait_until(tp - 1, ab);
							if (!ab) begin
								if (bsel == 0) sdram[bw(34) + w][7:0]  = sdram[bw(34) + w][7:0]  & v[7:0];
								else           sdram[bw(34) + w][15:8] = sdram[bw(34) + w][15:8] & v[15:8];
								pulse_event(6'd34);
							end
						end
					end
				end
			end
			if (ab) begin
				@(posedge clk_sys); die_busy <= 2'b00; event0 <= 1'b0;
				if (P_VERBOSE) $display("   [%0d] the save (gen %0d) was cut off by the apply's machine hold", cyc, gen);
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

	// the final comparison, word classes reported apart
	integer d_hdr, d_pay, d_crc, d_18;
	task cmp_vs_mimg(input string what, input integer use_flushed, input integer b);
		integer k;
		reg [15:0] v;
		begin
			d_hdr = 0; d_pay = 0; d_crc = 0; d_18 = 0;
			for (k = 0; k < SLOTW; k = k + 1) begin
				v = use_flushed ? flushed[k] : cmem[b*BANKW + k];
				if (v !== mimg[k]) begin
					if (k == 19 || k == 20) d_crc = d_crc + 1;
					else if (k < 256) d_hdr = d_hdr + 1;
					else d_pay = d_pay + 1;
					if (k == 18) d_18 = 1;
					if (k < 32 || (d_pay < 4 && k >= 256))
						$display("   DIFF %0s word %0d = %h, Memory image %h%0s", what, k, v, mimg[k],
						         cnt_hit(v) ? "  (equals a diag counter value written into a header)" : "");
				end
			end
			$display("   %0s vs Memory image: header %0d, payload %0d, crc %0d words differ", what, d_hdr, d_pay, d_crc);
		end
	endtask

	function integer cnt_hit(input [15:0] v);
		integer i;
		begin
			cnt_hit = 0;
			for (i = 0; i < n_cnt_seen; i = i + 1) if (cnt_seen[i] === v) cnt_hit = 1;
		end
	endfunction

	// =========================================================================
	// The run
	// =========================================================================
	integer i, n, t_save1, t_save2, t_load, t_ldone, b_after;   // t_lastplan: with the monitors
	integer n_hdr_final_diff, n_pay_final_diff, n_crc_final_diff;
	reg     w18_bad;
	reg     is_fi;
	reg     res_load_ok;
	integer flush_words;
	integer n_hdr_file_diff = -1, n_pay_file_diff = -1, n_crc_file_diff = -1;
	integer q_bank = 0, q_stray = 0;
	reg     q_flag = 1'bx, q_frozen = 1'bx;
	reg [15:0] q_w23 = 16'hxxxx, q_fw23 = 16'hxxxx, q_verdict = 16'hxxxx, q_applies = 16'hxxxx;
	integer nf = 0;
	task chk(input ok, input string what);
		begin
			if (ok !== 1'b1) begin
				nf = nf + 1;
				$display("   CHECK FAIL: %0s", what);
			end
		end
	endtask
	integer fd_n;

	initial begin
		if ($value$plusargs("SAVES=%d", P_SAVES)) ;
		if ($value$plusargs("GAPUS=%d", P_GAPUS)) ;
		if ($value$plusargs("DELAYCYC=%d", P_DELAYCYC)) ;
		begin : dus
			integer du;
			if ($value$plusargs("DELAYUS=%d", du)) P_DELAYCYC = $rtoi((du) * 49.152);
		end
		if ($value$plusargs("SAME=%d", P_SAME)) ;
		if ($value$plusargs("FLUSH=%d", P_FLUSH)) ;
		if ($value$plusargs("RELAUNCH=%d", P_RELAUNCH)) ;
		if ($value$plusargs("P2MAX=%d", P_P2MAX)) ;
		if ($value$plusargs("SEED=%d", P_SEED)) ;
		if ($value$plusargs("PROGPER=%d", P_PROGPER)) ;
		if ($value$plusargs("NOERASE=%d", P_NOERASE)) ;
		if ($value$plusargs("REDELIVER=%d", P_REDELIVER)) ;
		if ($value$plusargs("FLUSHDRAIN=%d", P_FLUSHDRAIN)) ;
		if ($value$plusargs("QUITSAVE=%d", P_QUITSAVE)) ;
		if ($value$plusargs("PLAYUS=%d", P_PLAYUS)) ;
		if ($value$plusargs("VERBOSE=%d", P_VERBOSE)) ;
		if ($value$plusargs("DGAP=%d", P_DGAP)) ;
		if ($value$plusargs("RGAP=%d", P_RGAP)) ;
		if ($value$plusargs("FORCEDRAIN=%d", P_FORCEDRAIN)) ;
		if ($value$plusargs("PAUSEDRAIN=%d", P_PAUSEDRAIN)) ;
		if ($value$plusargs("PAUSELEN=%d", P_PAUSELEN)) ;
		if ($value$plusargs("FLUSHAPPLY=%d", P_FLUSHAPPLY)) ;
		if ($value$plusargs("FDFULL=%d", P_FDFULL)) ;
		if ($value$plusargs("RACEOFS=%d", P_RACEOFS)) ;
		if ($value$plusargs("RELAUNCHMID=%d", P_RELAUNCHMID)) ;
		if ($value$plusargs("MIDWORDS=%d", P_MIDWORDS)) ;
		if ($value$plusargs("OLDW0=%h", P_OLDW0)) ;
		if ($value$plusargs("TAG=%s", P_TAG)) ;
		if ($value$plusargs("EXPECT_LOAD=%d", E_LOAD)) ;
		begin : emid
			reg [8*8-1:0] ms;
			if ($value$plusargs("EXPECT_MID=%s", ms)) E_MID = (ms == "new") ? 1 : 0;
			if ($value$plusargs("EXPECT_COMMIT=%s", ms)) E_COMMIT = (ms == "after") ? 1 : 0;
		end
		if ($value$plusargs("EXPECT_RELAUNCH=%d", E_RELAUNCH)) ;
		if ($value$plusargs("EXPECT_FILEFLAG=%d", E_FILEFLAG)) ;
		if ($value$plusargs("EXPECT_FINAL_MEM=%d", E_FINAL_MEM)) ;
		if ($value$plusargs("PUBRACE=%d", P_PUBRACE)) ;
		if ($value$plusargs("PUBHDR=%d", P_PUBHDR)) ;
		if ($value$plusargs("EXPECT_PUBHIT=%d", E_PUBHIT)) ;
		seedv = $urandom(P_SEED);

		$display("== T7R saves=%0d gapus=%0d delaycyc=%0d (%0d us) same=%0d noerase=%0d progper=%0d p2max=%0d seed=%0d redeliver=%0d flushdrain=%0d quitsave=%0d",
		         P_SAVES, P_GAPUS, P_DELAYCYC, $rtoi((P_DELAYCYC) / 49.152), P_SAME, P_NOERASE, P_PROGPER,
		         P_P2MAX, P_SEED, P_REDELIVER, P_FLUSHDRAIN, P_QUITSAVE);

		for (i = 0; i < 65536; i = i + 1) cmem[i] = 16'hDEAD;
		for (i = 0; i < 1048576; i = i + 1) sdram[i] = 16'hFFFF;   // ROM: save blocks erased
		for (i = 0; i <= N_INT; i = i + 1) internals[i] = 64'hDEADBEEF_DEADBEEF;
		for (i = 0; i < SZ0; i = i + 1) mem0[i] = 8'hFF;
		for (i = 0; i < SZ1; i = i + 1) mem1[i] = 8'hFF;
		for (i = 0; i < SZ2; i = i + 1) mem2[i] = 8'hFF;
		for (i = 0; i < WORDS; i = i + 1) image[i] = 32'd0;

		// ---- T7 launch: reset, cartridge, delivery of the pre-T7 file ---------
		repeat (20) @(posedge clk_sys);
		reset_in <= 0;
		repeat (4) @(posedge clk_sys); cart_replace <= 1;
		@(posedge clk_sys); cart_replace <= 0;
		repeat (8) @(posedge clk_sys); cart_ready <= 1;
		build_img(1, 1, 1, 16'h7F00, 16'h0000);
		pay_len = img_pk;   // R6C: packed payload words (every generation packs alike)
		apf_deliver_img;
		repeat (20) @(posedge clk_sys);
		if (bank_vs_img(cbank(0)) != 0) fail("(setup) the delivery did not land in the committed bank");
		// Continue: slots settle, boot apply
		wait_idle(20000000);
		if (cart_save.diag_applies !== 16'd1 || cart_save.diag_verdict !== 16'h0001 || cart_save.diag_p2wr !== 16'h4000)
			fail($sformatf("(setup) boot apply: applies %h verdict %h p2wr %h",
			     cart_save.diag_applies, cart_save.diag_verdict, cart_save.diag_p2wr));
		if (stage_diag_beats !== 16'h7F00) fail($sformatf("(setup) beats after the delivery = %h", stage_diag_beats));
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
		for (i = 0; i < SLOTW; i = i + 1) if (mimg[i] !== deliv[i]) n = n + 1;
		if (n != 0) fail($sformatf("(setup) the Memory's image differs from the delivered file in %0d words", n));
		$display("   [%0d] Memory captured: word 16 %h, word 18 %h, words 22-24 %h %h %h",
		         cyc, mimg[16], mimg[18], mimg[22], mimg[23], mimg[24]);
		// APF keeps it; the load will write it back
		apf_write_blob;

		// ---- in-game save(s), then the load at the chosen time ---------------
		t_save1 = cyc + 5000;
		t_save2 = t_save1 + save_len(0) + $rtoi((P_GAPUS) * 49.152);
		if (P_SAVES == 0)      t_lastplan = t_save1;
		else if (P_SAVES == 1) t_lastplan = t_save1 + save_len(0);
		else                   t_lastplan = t_save2 + save_len(0);
		t_load = t_lastplan + P_DELAYCYC;
		t_last_ev = t_lastplan;
		$display("   [%0d] saves planned: save1 %0d, save2 %0d, last event %0d, load command %0d",
		         cyc, t_save1, (P_SAVES == 2) ? t_save2 : -1, t_lastplan, t_load);

		save_abort = 0; abort_arm = 1;
		fork
			begin : game
				if (P_SAVES >= 1) do_save(t_save1, P_SAME ? 1 : 2);
				if (P_SAVES >= 2) do_save(t_save2, P_SAME ? 1 : 3);
			end
			// rc6X PUBRACE: a flush whose first read lands on the clock of the
			// pass's publish decision (the pass after the last save). The
			// follow-up holds the publish on the strobe: the file is wholly the
			// old image or wholly the published one, never word 0 of one and
			// the rest of the other. With +OLDW0 the committed bank's word 0 is
			// made to differ first, so word 0's source is visible.
			begin : pubrace
				if (P_PUBRACE >= 0) begin : pr
					integer k, pr_n;
					pr_n = 0;
					while (!(cyc > t_lastplan && est == 5'd6 && cart_save.in_apply !== 1'b1 &&
					         cart_save.hdr_idx == P_PUBHDR) && pr_n < 50000000) begin
						@(posedge clk_sys); pr_n = pr_n + 1;
					end
					if (pr_n >= 50000000) fail("PUBRACE: the pass after the last save never reached its header walk");
					repeat (P_PUBRACE) @(posedge clk_sys);
					mf_bank0 = cbank(0);
					for (k = 0; k < SLOTW; k = k + 1) oldimg[k] = cmem[mf_bank0*BANKW + k];
					if (P_OLDW0 >= 0 && t_pub_dec < 0) begin
						cmem[mf_bank0*BANKW] = P_OLDW0[15:0];
						oldimg[0] = P_OLDW0[15:0];
					end
					t_mf_start = cyc;
					mf_live = 1;
					$display("   [%0d] PUBRACE: APF flushes %0d words, %0d clk after the pass entered header index %0d (engine state %0d, hdr_idx %0d, host_idle %0d, bank %0d)",
					         cyc, P_MIDWORDS, P_PUBRACE, P_PUBHDR, est, cart_save.hdr_idx, stage_mem.host_idle, mc_stage_bank);
					apf_flush(P_MIDWORDS);
					mf_live = 0;
					t_mf_end = cyc;
					pr_ran = 1;
					for (k = 0; k < SLOTW; k = k + 1) primg[k] = cmem[(1 - mf_bank0)*BANKW + k];
					for (k = 0; k < SLOTW && k < 2*P_MIDWORDS; k = k + 1) if (k < 32 || (k >= 256 && k < 256 + pay_len)) begin
						if (oldimg[k] !== primg[k]) begin
							pr_diff = pr_diff + 1;
							if (flushed[k] === oldimg[k])      pr_old = pr_old + 1;
							else if (flushed[k] === primg[k])  pr_new = pr_new + 1;
							else                               pr_neither = pr_neither + 1;
						end else if (flushed[k] !== oldimg[k]) pr_neither = pr_neither + 1;
					end
					pr_mixed = (pr_old > 0 && pr_new > 0) || (pr_neither > 0);
					$display("   [%0d] PUBRACE: flush %0d..%0d, first strobe %0d, first claim %0d (bank %0d), publish decision %0d; words differing between the images %0d: old %0d new %0d neither %0d -> %0s",
					         cyc, t_mf_start, t_mf_end, t_rd_first, t_claim_first, mf_first_claim_bank, t_pub_dec,
					         pr_diff, pr_old, pr_new, pr_neither,
					         pr_mixed ? "MIXED FILE" : (pr_new == 0 ? "whole old image" : "whole published image"));
					if (pr_mixed) fail("PUBRACE: the file flushed across the pass's publish mixes two images");
				end
				pr_done = 1;
			end
			begin : loader
				while (cyc < t_load || !pr_done) @(posedge clk_sys);
				if (P_REDELIVER) begin
					// APF re-sends the file it holds (the pre-T7 file) first
					build_img(1, 1, 1, 16'h7F00, 16'h0000);
					$display("   [%0d] APF re-delivers the save slot before the load", cyc);
					apf_deliver_img;
				end
				$display("   [%0d] APF load command (rel %0d clk after the last planned event; engine state %0d, stage_pending %b, quiet %0d)",
				         cyc, cyc - t_lastplan, est, cart_save.stage_pending, cart_save.quiet);
				fork
					apf_load;
					begin
						if (P_FLUSHDRAIN) begin
							fd_n = 0;
							while (sc_draining !== 1'b1 && fd_n < 50000000) begin @(posedge clk_sys); fd_n = fd_n + 1; end
							repeat (2000) @(posedge clk_sys);
							$display("   [%0d] APF reads the save slot during the drain", cyc);
							apf_flush(256);
						end
						// R6C: APF flushes the whole slot while the state apply runs
						if (P_FLUSHAPPLY >= 0 || P_RACEOFS >= 0 || P_FDFULL >= 0) begin : r6c_mid
							integer k, fa_n;
							fa_n = 0;
							if (P_FDFULL >= 0) begin
								// poison the spare bank so a lost drain beat is visible (as tb_t7p mode 9)
								for (k = 0; k < BANKW; k = k + 1) cmem[(1 - cbank(0))*BANKW + k] = 16'hDEAD;
								while (sc_draining !== 1'b1 && fa_n < 50000000) begin @(posedge clk_sys); fa_n = fa_n + 1; end
							end else
							while (mc_state_apply !== 1'b1 && fa_n < 50000000) begin @(posedge clk_sys); fa_n = fa_n + 1; end
							t_sapply = cyc;
							for (k = 0; k < SLOTW; k = k + 1) oldimg[k] = cmem[cbank(0)*BANKW + k];
							if (P_OLDW0 >= 0) begin
								cmem[cbank(0)*BANKW] = P_OLDW0[15:0];
								oldimg[0] = P_OLDW0[15:0];
							end
							mf_bank0 = cbank(0);
							if (P_RACEOFS >= 0) begin
								// the gated commit is waiting; land the first read around
								// the cycle host_busy_o falls
								fa_n = 0;
								while (!(est == 5'd15 && cart_save.in_apply === 1'b1 && cart_save.from_state === 1'b1 &&
								         stage_mem.host_idle == 20'd500000 - P_RACEOFS) && fa_n < 50000000) begin
									@(posedge clk_sys); fa_n = fa_n + 1;
								end
								if (fa_n >= 50000000) fail("R6C: the gated commit never waited (RACEOFS needs the fixed build)");
							end else begin
								repeat ((P_FDFULL >= 0) ? P_FDFULL : P_FLUSHAPPLY) @(posedge clk_sys);
							end
							t_mf_start = cyc;
							mf_live = 1;
							$display("   [%0d] R6C: APF flushes the whole slot during the state apply (%0d clk after state_apply; engine state %0d, host_idle %0d, bank %0d)",
							         cyc, cyc - t_sapply, est, stage_mem.host_idle, mc_stage_bank);
							apf_flush(P_MIDWORDS);
							mf_live = 0;
							t_mf_end = cyc;
							mf_ran = 1;
							for (k = 0; k < SLOTW; k = k + 1) midf[k] = flushed[k];
							// word by word: old committed image or the state's image
							// only the words a boot apply reads: header 0-31, payload
							// 256 .. 256+pay_len-1 (the rest is stale bank content)
							for (k = 0; k < SLOTW; k = k + 1) if ((k < 32 || (k >= 256 && k < 256 + pay_len)) && k < 2*P_MIDWORDS) begin
								if (oldimg[k] !== mimg[k]) begin
									mf_diff = mf_diff + 1;
									if (midf[k] === oldimg[k]) begin mf_old = mf_old + 1; mf_last_old = k; end
									else if (midf[k] === mimg[k]) begin
										mf_new = mf_new + 1;
										if (mf_first_new < 0) mf_first_new = k;
									end else mf_neither = mf_neither + 1;
								end else if (midf[k] !== oldimg[k]) mf_neither = mf_neither + 1;
							end
							mf_mixed = (mf_old > 0 && mf_new > 0) || (mf_neither > 0);
							$display("   [%0d] R6C: mid-load flush %0d..%0d, first read %0d, commit %0d (%0s the flush), state_done %0d; words differing between the images %0d: old %0d new %0d neither %0d; first new word %0d, last old word %0d -> %0s",
							         cyc, t_mf_start, t_mf_end, t_rd_first, t_commit,
							         (t_commit < 0) ? "no commit yet at the end of" :
							         (t_claim_first >= 0 && t_commit <= t_claim_first) ? "BEFORE" : (t_commit > t_mf_end) ? "AFTER" : "DURING",
							         t_mf_done, mf_diff, mf_old, mf_new, mf_neither, mf_first_new, mf_last_old,
							         mf_mixed ? "MIXED FILE" : (mf_new == 0 ? "whole old image" : "whole state image"));
							if (mf_mixed) fail("R6C: the file flushed during the state apply mixes two images");
						end
					end
				join
				t_ldone = cyc;
				$display("   [%0d] load %0s (cart_load_req at %0d, drain %0d..%0d, rel to last event: req %0d, drain start %0d)",
				         cyc, ld_ok ? "OK" : "FAILED", t_ldreq, t_drain_up, t_drain_dn,
				         t_ldreq - t_lastplan, t_drain_up - t_lastplan);
			end
		join
		res_load_ok = ld_ok;
		abort_arm = 0;
		$display("   [%0d] after load: applies %0d verdict %h p2wr %h beats %h drops %h drain %h bank %0d frozen %b apply_reject %b",
		         cyc, cart_save.diag_applies, cart_save.diag_verdict, cart_save.diag_p2wr,
		         stage_diag_beats, stage_diag_drops, sc_diag_drain, mc_stage_bank, mc_frozen, mc_apply_reject);

		// ---- play, quit --------------------------------------------------------
		if (P_QUITSAVE > 0) begin
			n = P_PLAYUS - P_QUITSAVE; if (n < 0) n = 0;
			repeat ($rtoi((n) * 49.152)) @(posedge clk_sys);
			@(posedge clk_sys); die_busy <= 2'b01;
			repeat (18) @(posedge clk_sys);
			sdram[bw(34) + 7000] = 16'hA5A5;
			pulse_event(6'd34);
			$display("   [%0d] a flash write %0d us before quit", cyc, P_QUITSAVE);
			repeat ($rtoi((P_QUITSAVE) * 49.152)) @(posedge clk_sys);
		end else begin
			repeat ($rtoi((P_PLAYUS) * 49.152)) @(posedge clk_sys);
		end
		b_after = cbank(0);
		$display("   [%0d] quit: committed bank %0d, engine state %0d, pass active %b", cyc, b_after, est, pass_active);
		cmp_vs_mimg("committed bank at quit", 0, b_after);
		n_hdr_final_diff = d_hdr; n_pay_final_diff = d_pay; n_crc_final_diff = d_crc; w18_bad = d_18;
		begin : snap
			for (i = 0; i < SLOTW; i = i + 1) img[i] = cmem[b_after*BANKW + i];
		end
		flush_words = (P_FLUSH == 2) ? SLOTW/2 : (P_FLUSH == 1) ? 32 : 0;
		if (flush_words > 0) begin
			apf_flush(flush_words);
			n = 0;
			for (i = 0; i < 2*flush_words; i = i + 1) if (flushed[i] !== img[i]) begin
				n = n + 1;
				if (n <= 8) $display("   FLUSH word %0d = %h, bank held %h", i, flushed[i], img[i]);
			end
			if (n != 0) fail($sformatf("the flushed file differs from the committed bank (snapshot at quit) in %0d words", n));
			if (mc_stage_bank !== b_after) fail("the committed bank flipped during the flush");
			if (P_FLUSH == 2) cmp_vs_mimg("flushed file", 1, 0);
			if (P_FLUSH == 2) begin
				n_hdr_file_diff = d_hdr; n_pay_file_diff = d_pay; n_crc_file_diff = d_crc;
			end
		end
		// rc6X: the session's T7 flag state and the quit file, before any relaunch
		q_bank   = b_after;
		q_flag   = cart_save.diag_wr_drain;
		q_stray  = bank_stray(b_after);
		q_w23    = cmem[b_after*BANKW + 23];
		q_fw23   = (flush_words > 0) ? flushed[23] : 16'hxxxx;
		q_verdict = cart_save.diag_verdict;
		q_applies = cart_save.diag_applies;
		q_frozen = mc_frozen;
		sb_settle_check("quit");
		$display("   [%0d] T7 flag at quit: diag_wr_drain %b, committed bank %0d word 23 = %h (file %h), T7-shaped stray in it %0d",
		         cyc, q_flag, q_bank, q_w23, q_fw23, q_stray);

		// ---- relaunch -> Continue -> quit ----------------------------------------
		if (P_RELAUNCH && P_FLUSH == 2) begin
			@(posedge clk_sys); reset_in <= 1; cart_ready <= 0;
			repeat (20) @(posedge clk_sys);
			reset_in <= 0;
			for (i = 0; i < 1048576; i = i + 1) sdram[i] = 16'hFFFF;
			repeat (4) @(posedge clk_sys); cart_replace <= 1;
			@(posedge clk_sys); cart_replace <= 0;
			repeat (8) @(posedge clk_sys); cart_ready <= 1;
			for (i = 0; i < SLOTW; i = i + 1) img[i] = flushed[i];
			apf_deliver_img;
			wait_idle(20000000);
			$display("   [%0d] relaunch boot apply: applies %0d verdict %h p2wr %h", cyc,
			         cart_save.diag_applies, cart_save.diag_verdict, cart_save.diag_p2wr);
			repeat ((20000 * 49152) / 1000) @(posedge clk_sys);
			b_after = cbank(0);
			apf_flush(SLOTW/2);
			n = 0;
			for (i = 0; i < SLOTW; i = i + 1) if (flushed[i] !== img[i]) n = n + 1;
			if (n != 0) fail($sformatf("relaunch: the second flush differs from the file delivered in %0d words", n));
			cmp_vs_mimg("relaunch flushed file", 1, 0);
		end

		// ---- R6C: relaunch on the file flushed during the state apply -----------
		if (P_RELAUNCHMID && mf_ran) begin
			@(posedge clk_sys); reset_in <= 1; cart_ready <= 0;
			repeat (20) @(posedge clk_sys);
			reset_in <= 0;
			for (i = 0; i < 1048576; i = i + 1) sdram[i] = 16'hFFFF;
			repeat (4) @(posedge clk_sys); cart_replace <= 1;
			@(posedge clk_sys); cart_replace <= 0;
			repeat (8) @(posedge clk_sys); cart_ready <= 1;
			for (i = 0; i < SLOTW; i = i + 1) img[i] = midf[i];
			apf_deliver_img;
			wait_idle(20000000);
			rl_verdict = cart_save.diag_verdict;
			rl_frozen  = mc_frozen;
			$display("   [%0d] R6C relaunch on the mid-load file: applies %0d verdict %h p2wr %h frozen %b save_present %b",
			         cyc, cart_save.diag_applies, cart_save.diag_verdict, cart_save.diag_p2wr, mc_frozen, save_present);
			if (rl_verdict !== 16'h0001 || rl_frozen !== 1'b0)
				fail("R6C: the next boot refused the file flushed during the state apply");
		end

		if (chip_oob) fail("a PSRAM access beyond the two staging banks");
		if (stage_diag_drops !== 16'd0) fail($sformatf("%0d host beats dropped by the skid", stage_diag_drops));

		sb_settle_check("end");

		// ---- rc6X verdict -------------------------------------------------------
		is_fi = (P_FORCEDRAIN >= 0) || (P_PAUSEDRAIN >= 0);
		chk(errors == 0, $sformatf("%0d bench error(s) (FAIL lines above)", errors));
		chk(host_loss(0) == 0, $sformatf("host-write loss: ARB lost %0d, unmatched %0d, drops %0d, owed %0d; SKID lost %0d, unmatched %0d, owed %0d",
		                                 arb_lost, arb_bad, arb_drop, arb_left, skid_lost, skid_bad, skid_left));
		chk(n_flag_incons == 0, "the T7 flag disagreed with the engine's writes while draining");
		chk(n_w23_bad == 0, "an engine header word 23 did not carry the T7 flag as it stood");
		if (q_stray) begin
			chk(q_w23[14] === 1'b1, $sformatf("the committed bank holds a T7-shaped stray header but word 23 = %h lacks bit 14", q_w23));
			if (flush_words > 0)
				chk(q_fw23[14] === 1'b1, $sformatf("the quit file holds a T7-shaped stray header but word 23 = %h lacks bit 14", q_fw23));
		end
		if (!is_fi) begin
			chk(n_flag_rise == 0, $sformatf("RTL-only run: the T7 flag rose %0d time(s)", n_flag_rise));
			chk(n_engwr_in_drain == 0 && n_eng_hdrwr_in_drain == 0,
			    $sformatf("RTL-only run: %0d engine staging write(s), %0d header write(s), while draining", n_engwr_in_drain, n_eng_hdrwr_in_drain));
			chk(n_w23_b14 == 0, $sformatf("RTL-only run: header word 23 written with bit 14 set %0d time(s)", n_w23_b14));
			chk(q_stray == 0, "RTL-only run: the committed bank holds an engine header written while draining");
		end
		if (E_FILEFLAG == 1)
			chk(flush_words > 0 && q_fw23[14] === 1'b1, $sformatf("the quit file's word 23 = %h does not carry the T7 flag (bit 14)", q_fw23));
		if (E_LOAD >= 0)
			chk(res_load_ok == E_LOAD[0], $sformatf("the load %0s, expected it to %0s", res_load_ok ? "succeeded" : "FAILED",
			                                        E_LOAD ? "succeed" : "fail"));
		if (E_FINAL_MEM == 1 || (E_FINAL_MEM < 0 && !is_fi && P_QUITSAVE == 0 && res_load_ok)) begin
			chk(n_hdr_final_diff == 0 && n_pay_final_diff == 0 && n_crc_final_diff == 0,
			    $sformatf("the committed bank at quit differs from the Memory image (hdr %0d payload %0d crc %0d)",
			              n_hdr_final_diff, n_pay_final_diff, n_crc_final_diff));
			if (P_FLUSH == 2)
				chk(n_hdr_file_diff == 0 && n_pay_file_diff == 0 && n_crc_file_diff == 0,
				    $sformatf("the quit file differs from the Memory image (hdr %0d payload %0d crc %0d)",
				              n_hdr_file_diff, n_pay_file_diff, n_crc_file_diff));
		end
		if (E_MID == 0)
			chk(mf_ran && !mf_mixed && mf_new == 0 && mf_old > 0 && mf_old == mf_diff,
			    $sformatf("the mid-load file is not wholly the old image (old %0d new %0d neither %0d of %0d)", mf_old, mf_new, mf_neither, mf_diff));
		if (E_MID == 1)
			chk(mf_ran && !mf_mixed && mf_old == 0 && mf_new > 0 && mf_new == mf_diff,
			    $sformatf("the mid-load file is not wholly the state's image (old %0d new %0d neither %0d of %0d)", mf_old, mf_new, mf_neither, mf_diff));
		if (E_COMMIT == 1)
			chk(t_commit >= 0 && t_commit > t_mf_end, $sformatf("the commit (%0d) did not land after the mid-load flush (%0d..%0d)", t_commit, t_mf_start, t_mf_end));
		if (E_COMMIT == 0)
			// a flip seen at sample t is in place for a claim made at sample t
			chk(t_commit >= 0 && t_claim_first >= 0 && t_commit <= t_claim_first,
			    $sformatf("the commit (%0d) did not land before the flush's first claim (%0d; first strobe %0d)", t_commit, t_claim_first, t_rd_first));
		if (P_PUBRACE >= 0)
			chk(pr_ran && !pr_mixed, $sformatf("PUBRACE: the file flushed across the publish is not one whole image (old %0d new %0d neither %0d of %0d)",
			                                   pr_old, pr_new, pr_neither, pr_diff));
		if (E_PUBHIT == 1)
			chk(n_pub_rd_hit > 0, $sformatf("PUBRACE: the flush's strobe missed the publish decision (first strobe %0d, decision %0d): the probe tested nothing",
			                                t_rd_first, t_pub_dec));
		// rc6X follow-up (every run): no committed-bank flip under APF's read
		// strobe, none inside a flush
		chk(n_flip_in_rd == 0, $sformatf("the committed bank flipped %0d time(s) on a clock where APF's read strobe was up", n_flip_in_rd));
		chk(n_flip_in_flush == 0, $sformatf("the committed bank flipped %0d time(s) in the middle of an APF flush", n_flip_in_flush));
		if (E_RELAUNCH == 1)
			chk(rl_verdict === 16'h0001 && rl_frozen === 1'b0, $sformatf("relaunch on the mid-load file: verdict %h frozen %b, want 0001 / 0", rl_verdict, rl_frozen));

		$display("== T7R RESULT saves=%0d gapus=%0d delayus=%0d same=%0d redeliver=%0d flushdrain=%0d quitsave=%0d | load=%0s req_rel_us=%0d drain_rel_us=%0d | passes=%0d published=%0d deferred=%0d | pass_in_drain=%0d hdr_in_drain=%0d engreq_in_drain=%0d engwr_in_drain=%0d eng_hdrwr_in_drain=%0d ready_in_drain=%0d ready_mid_drain=%0d forcedrain=%0d pausedrain=%0d | final_vs_memory hdr=%0d payload=%0d crc=%0d w18=%0s | applies=%0d verdict=%h max_skid=%0d | host_loss=%0d arb_coll=%0d replays=%0d rd_wait=%0d | t7flag=%b rises=%0d w23_eng=%0d w23_b14=%0d stray=%0d quit_w23=%h file_w23=%h | errors=%0d",
		         P_SAVES, P_GAPUS, $rtoi((P_DELAYCYC) / 49.152), P_SAME, P_REDELIVER, P_FLUSHDRAIN, P_QUITSAVE,
		         res_load_ok ? "ok" : "FAIL",
		         $rtoi((t_ldreq - t_lastplan) / 49.152), $rtoi((t_drain_up - t_lastplan) / 49.152),
		         n_pass_start, n_publish, n_defer,
		         n_pass_in_drain, n_hdr_in_drain, n_engreq_in_drain, n_engwr_in_drain, n_eng_hdrwr_in_drain,
		         n_ready_in_drain, n_ready_mid_drain, P_FORCEDRAIN, P_PAUSEDRAIN,
		         n_hdr_final_diff, n_pay_final_diff, n_crc_final_diff, w18_bad ? "DIFF" : "same",
		         q_applies, q_verdict, max_skid,
		         host_loss(0), arb_coll, arb_replays, n_rd_wait,
		         q_flag, n_flag_rise, n_w23_eng, n_w23_b14, q_stray, q_w23, q_fw23, errors);
		if (mf_ran)
			$display("   mid-load flush reads claimed from the bank committed at its start: %0d, from the other bank: %0d",
			         mf_claims_old, mf_claims_new);
		$display("== R6C RESULT build=rc6 flushapply=%0d raceofs=%0d fdfull=%0d rgap=%0d | load=%0s | mid_flush=%0s commit_vs_flush=%0s commit_after_sapply=%0d commit_after_last_drain_beat=%0d first_rd_minus_commit=%0d first_claim_minus_commit=%0d | old=%0d new=%0d neither=%0d | relaunch verdict=%h frozen=%b | flips_under_strobe=%0d flips_in_flush=%0d | errors=%0d",
		         P_FLUSHAPPLY, P_RACEOFS, P_FDFULL, P_RGAP, res_load_ok ? "ok" : "FAIL",
		         !mf_ran ? "none" : mf_mixed ? "MIXED" : (mf_new == 0) ? "old" : "new",
		         (t_commit < 0) ? "none" : !mf_ran ? "noflush" :
		         (t_claim_first >= 0 && t_commit <= t_claim_first) ? "before" : (t_commit > t_mf_end) ? "after" : "DURING",
		         (t_commit < 0) ? -1 : t_commit - t_sapply,
		         (t_commit < 0) ? -1 : t_commit - t_last_drain,
		         (t_commit < 0 || t_rd_first < 0) ? 0 : t_rd_first - t_commit,
		         (t_commit < 0 || t_claim_first < 0) ? 0 : t_claim_first - t_commit,
		         mf_old, mf_new, mf_neither, rl_verdict, rl_frozen, n_flip_in_rd, n_flip_in_flush, errors);
		if (P_PUBRACE >= 0)
			$display("== PUBRACE RESULT pubrace=%0d pubhdr=%0d oldw0=%0d | file=%0s old=%0d new=%0d neither=%0d | first_strobe_minus_decision=%0d hit=%0d | passes=%0d published=%0d deferred=%0d | flips_under_strobe=%0d flips_in_flush=%0d",
			         P_PUBRACE, P_PUBHDR, P_OLDW0, !pr_ran ? "none" : pr_mixed ? "MIXED" : (pr_new == 0) ? "old" : "published",
			         pr_old, pr_new, pr_neither, (t_rd_first < 0 || t_pub_dec < 0) ? 99999 : t_rd_first - t_pub_dec,
			         n_pub_rd_hit, n_pass_start, n_publish, n_defer, n_flip_in_rd, n_flip_in_flush);
		if (nf == 0) $display("== RC6X SCENARIO %0s %0s PASS", P_TAG, is_fi ? "(fault injection)" : "(rtl)");
		else         $display("== RC6X SCENARIO %0s %0s FAIL (%0d check(s))", P_TAG, is_fi ? "(fault injection)" : "(rtl)", nf);
		$finish;
	end

	initial begin
		repeat (3000) #1_000_000;
		$display("== T7R WATCHDOG at cycle %0d", cyc);
		$display("== RC6X SCENARIO %0s FAIL (watchdog)", P_TAG);
		$finish;
	end

endmodule

`default_nettype wire
