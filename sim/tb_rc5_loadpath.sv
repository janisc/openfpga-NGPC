// Testbench: the rc5 savestate load path with the REAL bridge.
//
// Written from rc5_spec.md (items B1-B3, S1, S2, S6, S7, S8, S10, S11), not
// from the implementation. It is the integration the per-module benches
// cannot give: the bridge's identity block (layout 2 / 3), its failure pulse
// and its load_frozen level all reach the save engine through the real
// copier, and what the engine does with them is checked on ports, on PSRAM
// and SDRAM contents, and on the machine the savestate engine restores.
//
// REAL, compiled unmodified:
//   upstream/rtl/Savestates/savestates.sv       the savestate engine
//   target/pocket/ngpc_savestate_bridge.sv      identity stamp/check, blob store
//   target/pocket/ngpc_state_cart.sv            the copier
//   target/pocket/ngpc_cart_save.sv             the save engine (QUIET_CLOCKS 200)
//   upstream/rtl/cart/ngp_cart_overlay_geometry.sv
//   sim/sim_synch3.v                            synch_3, as sim/run.sh uses it
//
// WIRING (core_top.v / ngpc_machine.sv, rc5):
//   bridge  cart_* <-> copier cart_*        (save/load req/done/error, image port)
//   bridge  ss_save/ss_load -> savestates save/load; ss_busy/ss_loading back
//   bridge  cart_crc32 = the engine's cart_crc32_i (cart_image_crc32)
//   engine  frozen_o      -> bridge frozen_i                        [rc5]
//   bridge  load_frozen_o -> engine state_frozen_i                  [rc5]
//   bridge  load_fail_o   -> engine state_fail_i                    [rc5]
//   copier  draining_o    -> engine draining_i (rc6: no longer ORed into host_busy_i)
//   copier  state_apply_o -> engine state_apply_i; state_done_o/apply_reject_o
//           and stage_current_o back; diag_drain_o -> diag_drain_i
//   copier  hold_o        -> the machine's pause request (capture_hold)
//   staging engine port: the copier borrows it while sc_rd_active and reads
//     the COMMITTED bank (sc_rd_addr | stage_bank << 16)
//   staging host writes: APF delivery -> the committed bank, and it is the
//     engine's save_slot_wr_i; the copier's drain -> the SPARE bank, not a
//     delivery
//   every module's reset is the one reset net (core_top reset_in)
//
// MODELED: the machine behind the savestate engine (internals bus and three
// byte memories, a pattern per seed, as tb_savestate_bridge does); the APF
// bridge bus (measured lagged write bursts, reads, the 0xA0/0xA4 handshakes);
// APF's save-slot delivery into the committed bank and slots_settled; the
// cartridge SDRAM (p2 port); the staging PSRAM with its host-write skid and
// host_busy tail (as tb_rc4_loadpath); the game (flash writes, die_busy).
//
// SESSIONS. A new core launch -- a wake from sleep included -- is modelled as
// "reconfigure": the one reset net pulses, the cartridge is downloaded again
// (SDRAM = ROM, cart_replace, cart_ready), the machine model goes cold, and
// the PSRAM model KEEPS its contents. stage_bank_o is not touched by reset
// (S2); the bench does not force it to its power-up 0, it follows the
// convention that a delivered image goes into the committed bank, whichever
// that is, which is what bank 0 is after a real reconfiguration. A wake
// either has no delivery (the committed bank still holds the file, the task's
// "reset of everything except PSRAM") or APF re-delivers the file it flushed
// at sleep (the committed bank), with the slots settling in the middle of the
// state's drain -- the order hardware produces, where one state apply serves
// the pending boot apply too (S8).
//
// SCENARIOS (spec items in brackets)
//   FZV-CAP   a delivered V3-tagged file is refused at boot and freezes the
//             session; the game's save does not publish; a capture stamps
//             layout 3 and embeds the refused file byte-exact.   [S1a, B1]
//   L3-SAME   that layout-3 blob loaded in the same frozen session: load ok,
//             machine restored, load_frozen held at 1 from the check until
//             the machine restore ends, no flash write and no staging read,
//             dirty and the committed bank unchanged, apply_reject 0, still
//             frozen, verdict 7.
//                                                  [B2, S11, S1d, S10]
//   FZV-WAKE  reconfigure with no delivery (boot apply: nothing delivered, not
//             frozen), then the layout-3 blob: load ok, machine restored, no
//             flash write, frozen again, verdict 7; a later game save does not
//             publish and the committed bank stays byte-identical to the
//             delivered file.                     [S11, S1d, B2, S1, S2]
//   FZM-CAP   the same for a file with a BAD MAGIC (word 1).       [S1a, B1]
//   FZM-WAKE  as FZV-WAKE; then the next sleep's capture is layout 3 again.
//                                                        [S11, S1d, B1]
//   FZM-WAKE2 the hardware-shaped wake: APF re-delivers the flushed file, the
//             slots settle mid-drain, ONE state apply serves the boot apply
//             too (S8) and it is S11: no flash write at all, frozen, the last
//             verdict is 7 (no separate boot apply after it), a later save
//             does not publish, the bank is the file.   [S8, S11, S1d, S10]
//   LP2-CAP   a good file is accepted at boot (no freeze), the game saves and
//             publishes, a capture stamps layout 2 and embeds the committed
//             bank, whose word 21 is {05, subcat}.        [S1, B1, S10]
//   LP2-SAME  rc4 regression in-session: the layout-2 blob rewinds flash, dirty
//             = the image bitmap, the drained bank is committed, load_frozen 0,
//             no failure pulse, a later save publishes.   [B2, S4, S2, B3]
//   L3-MID    the FZV layout-3 blob loaded into this healthy session: load ok,
//             machine restored, nothing written or read (its bitmap misses a
//             dirty block, so S5 must not run), dirty and bank unchanged, and
//             the session freezes -- S1(d) has no wake-shape condition.
//                                                        [S11, S1d, B2]
//   L2-FROZEN the layout-2 blob right after it, in the now frozen session:
//             load_frozen 0 (B2 follows each load's layout word), flash
//             rewound, dirty = the image bitmap, but no drained bank is
//             committed and the freeze stays (no state apply clears it).
//                                                    [B2, S1, S2, S4]
//   LP2-WAKE  rc4 regression at a hardware-shaped wake: an OLD layout-2 blob
//             (its image's word 21 = 0x0001, writer rev 0) with the flushed
//             file re-delivered and the slots settling mid-drain: one state
//             apply, exactly the state's 16384 flash writes, none before the
//             state pulse, committed = drained, not frozen.  [B2, S8, S2, S4]
//   OG-CAP    a cart-B session publishes; then a cart-A session with no file
//             and no pass captures cart B's image (layout 2).       [B1]
//   OG-WAKE   that blob at a cart-A wake: magic ok, cart CRC not this cart's:
//             no image (S6), dirty empty -> accepted no-op, machine restored,
//             no flash write, no bank change, not frozen; a later save
//             publishes with word 23 = 0x8406.              [S6, S10, S1]
//   OG-DIRTY  the same blob once that session has saved (dirty non-empty):
//             S6 reject, load_err with one load_fail pulse, machine untouched,
//             nothing written, NOT frozen (S6 never freezes, and the session
//             is not wake-shaped), verdict 6 / fail_idx 4.
//                                                [S6, B3, S1c, S10]
//   BF-ID     wake-shaped session, identity CRC of another cart: load_err,
//             one load_fail pulse, the copier never started, machine
//             untouched, frozen; a later save does not publish.   [B3, S1c]
//   BF-INC    the same for an incomplete blob (20000 of 24680 words). [B3, S1c]
//   BF-LAY    the same for layout word 4.                   [B2, B3, S1c]
//   BF-TO     the same for a copier I_DR_WAIT timeout (cart not ready at
//             the load; draining_o never rose); the nothing-delivered boot
//             apply that follows does not clear the freeze.
//                                                      [B3, S1c, C1, S1]
//   BF-S7     wake, layout 2, the embedded image's tag is V3: the engine
//             refuses (S7), load_err with ONE load_fail pulse, frozen.
//                                                  [B3, S7, S1b, S1c]
//   BF-ID-ACC identity failure after an accepted boot apply: load_err, one
//             pulse, NOT frozen; a later save publishes.            [S1c]
//   BF-ID-DIRTY identity failure in a session with no file whose game has
//             saved (dirty non-empty, no apply accepted): NOT frozen.  [S1c]
//   BF-INC-ACC0 incomplete blob after an accepted boot apply of an image with
//             an EMPTY bitmap (base set, dirty empty): NOT frozen.  [S1c]
//   BF-PEND   identity failure while the delivered file's boot apply is still
//             pending (wake-shaped): frozen; the boot apply then accepts the
//             file and lifts the freeze.                       [S1c, S1]
//   BF-HDR    the savestate engine rejects the blob's header (no-lag bus,
//             word 1 != 8416) after the state apply was accepted: load_err,
//             one pulse, flash = the state, NOT frozen.          [B3, S1c]
//   RPL-MID   cart_replace (cartridge reload, no core reset) while the state
//             apply is writing flash: the engine answers state_done with
//             apply_reject (S8), the real copier is released and the bridge
//             reports the load failed with one load_fail pulse; the reload
//             left the session wake-shaped, so that pulse freezes it (S1c),
//             and the nothing-delivered boot apply after the reload does not
//             clear it.                              [S8, B3, S1c, S1]
//   GLOBAL    protocol monitors: one load_fail pulse per load_err edge, each
//             one cycle wide; state_done == state_apply; staging port, skid,
//             drain and capture-hold rules as in tb_rc4_loadpath.
//
// Every S11 load also checks that the save engine made no staging read of
// its own (S11 "reads nothing"; in FZM-WAKE2 also that no boot apply ran
// after it), and every frozen-session save waits long enough for a whole
// pass (later_save_blocked), not just QUIET.
//
// Internal signals read: u_save.dirty0 (pre-rc5, also read by
// tb_rc4_loadpath) and, under NGPC_SAVE_DIAG, u_save.diag_verdict for the
// verdicts of loads that leave no published header (S11, L2-FROZEN,
// OG-DIRTY). Define RC5LP_NO_PROBES to drop the diag_verdict probe.
//
// Stimulus follows tb_rc4_loadpath / tb_savestate_bridge: DUT-facing regs
// change with <= at a clock edge.
//
// Run: wsl -e sh /mnt/c/FPGA/ngpc-rc4/sim/run_rc5_loadpath.sh
// Passes when the last line is "== ALL RC5 LOAD-PATH SCENARIOS PASS".

`timescale 1ns / 1ps
`default_nettype none

`define FAIL(a) begin errors = errors + 1; $write("   FAIL [%0s] ", scn); $display a ; end

module tb_rc5_loadpath;

	// ---- clocks: 49.152 MHz core, 74.25 MHz bridge -------------------------
	reg clk_sys = 0;
	reg clk_74a = 0;
	always #10.173 clk_sys = ~clk_sys;   // 20.345 ns
	always #6.734  clk_74a = ~clk_74a;   // 13.468 ns

	reg reset = 1;

	// ---- geometry ----------------------------------------------------------
	localparam integer N_INT    = 112;     // 64-bit internals (ngpc_machine)
	localparam integer SZ0      = 12288;
	localparam integer SZ1      = 4096;
	localparam integer SZ2      = 16384;
	localparam integer CARTB    = 8424;    // blob word of the cart section
	localparam integer CARTW    = 16256;   // section words (32-bit) = 0xFE00 bytes
	localparam integer WORDS    = CARTB + CARTW;   // 24,680 blob words
	localparam [31:0]  BLOBBASE = 32'h40000000;
	localparam [31:0]  ID_MAGIC = 32'h4E475053;    // "NGPS"
	localparam [31:0]  HDR_W1   = 32'hE0200000;    // blob word 1: bswap32(8416)
	localparam integer SLOTW    = 32512;   // .sav words (16-bit)
	localparam integer BANKW    = 32768;   // staging bank, 16-bit words
	localparam integer FLASHW   = 262144;  // one 4 Mbit die, 16-bit words
	localparam integer QUIET    = 200;     // = QUIET_CLOCKS below
	localparam integer DRW_TO   = 150000;  // copier DR_WAIT_TIMEOUT
	localparam integer HOST_IDLE  = 100;   // stage_mem's host_busy tail (< QUIET)
	localparam integer SKID_DEPTH = 32;
	localparam integer PS_LAT   = 3;       // PSRAM clocks per access
	localparam integer GAP      = 4;       // clk_74a between APF write strobes
	localparam integer LOAD_MAX74 = 4000000;
	localparam integer SAVE_MAX74 = 4000000;
	localparam [31:0]  CRC_A    = 32'h600DCA57;   // the cartridge under test
	localparam [31:0]  CRC_B    = 32'h0B0EF00D;   // another cartridge
	localparam [15:0]  TAG_V4   = 16'h5634;
	localparam [15:0]  TAG_V3   = 16'h5633;       // the PR #5 test build's tag

	// ---- cartridge / game / APF save slot (clk_sys) --------------------------
	reg         cart_ready = 0, cart_replace = 0;
	reg  [31:0] cart_crc   = CRC_A;
	reg  [24:0] cart_bytes = 25'h0080000;
	reg   [1:0] size_code0 = 2'd1;           // one 4 Mbit die
	reg   [1:0] size_code1 = 2'd0;           // second die absent
	reg         event0 = 0;
	reg   [5:0] block0 = 0;
	reg   [1:0] die_busy = 0;
	reg         slots_settled = 0;
	reg         apf_wr = 0;                  // APF save-slot write (delivery)
	reg  [24:0] apf_addr = 0;
	reg  [15:0] apf_data = 0;

	// =========================================================================
	// The machine behind the savestate engine
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
	wire  [7:0] ram_rdata = ram_rdata_q2;   // 2-cycle latency like the k2ge tap

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

	// ngpc_machine: pause_req = seed | engine | capture_hold; the machine
	// parks a few cycles after it is asked.
	wire       eng_pause_req;
	wire       sc_hold;
	reg  [2:0] pause_pipe = 3'd0;
	always @(posedge clk_sys) pause_pipe <= {pause_pipe[1:0], (eng_pause_req === 1'b1) || (sc_hold === 1'b1)};
	wire       paused = pause_pipe[2];

	// ---- savestate engine <-> bridge ----------------------------------------
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

	// =========================================================================
	// The bridge
	// =========================================================================
	reg         bridge_wr = 0, bridge_rd = 0;
	reg  [31:0] bridge_addr = 32'hF8000000;
	reg  [31:0] bridge_wr_data = 0;
	wire [31:0] bridge_rd_data;

	reg         ss_start_req = 0, ss_load_req = 0;
	wire        start_ack, start_busy, start_ok, start_err;
	wire        load_ack,  load_busy,  load_ok,  load_err;

	wire        br_save_req, br_save_done, br_load_req, br_load_done, br_load_error;
	wire        br_img_wr;
	wire [13:0] br_img_addr, br_img_rd_addr;
	wire [31:0] br_img_data, br_img_rd_data;

	wire        frozen;        // engine frozen_o      -> bridge frozen_i
	wire        load_frozen;   // bridge load_frozen_o -> engine state_frozen_i
	wire        load_fail;     // bridge load_fail_o   -> engine state_fail_i

	ngpc_savestate_bridge u_bridge (
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
		.cart_crc32(cart_crc),

		.cart_save_req   (br_save_req),
		.cart_save_done  (br_save_done),
		.cart_img_wr     (br_img_wr),
		.cart_img_addr   (br_img_addr),
		.cart_img_data   (br_img_data),
		.cart_load_req   (br_load_req),
		.cart_load_done  (br_load_done),
		.cart_load_error (br_load_error),
		.frozen_i        (frozen),
		.load_frozen_o   (load_frozen),
		.load_fail_o     (load_fail),
		.save_busy_i     (boot_hold),   // as ngpc_machine wires it
		.cart_img_rd_addr(br_img_rd_addr),
		.cart_img_rd_data(br_img_rd_data),

		.bus_out_Din(bus_out_Din), .bus_out_Dout(bus_out_Dout),
		.bus_out_Adr(bus_out_Adr), .bus_out_rnw(bus_out_rnw),
		.bus_out_ena(bus_out_ena), .bus_out_be(bus_out_be),
		.bus_out_done(bus_out_done)
	);

	// =========================================================================
	// The save engine and the copier
	// =========================================================================
	wire        boot_hold, busy, save_present, stage_current, stage_bank;
	wire        apply_reject, state_done;
	wire        p2_req, p2_we;
	wire [24:0] p2_addr;
	wire [15:0] p2_wdata;
	wire  [1:0] p2_be;
	reg         p2_done = 0;
	reg  [15:0] p2_rdata = 0;
	reg         p2_pend = 0;
	wire        cs_st_req, cs_st_we;
	wire [24:0] cs_st_addr;
	wire [15:0] cs_st_wdata;

	wire        sc_rd_req, sc_rd_active, sc_draining;
	wire [24:0] sc_rd_addr;
	wire        sc_host_wr;
	wire [24:0] sc_host_addr;
	wire [15:0] sc_host_data;
	wire        sc_state_apply;
	wire [15:0] diag_drain;

	wire        eng_ready;
	reg         eng_done = 0;
	reg  [15:0] eng_rdata = 0;
	wire        host_ready, host_busy, stage_host_ready;
	reg  [15:0] diag_beats = 0, diag_drops = 0;

	ngpc_cart_save #(
		.QUIET_CLOCKS (20'd200)
	) u_save (
		.clk             (clk_sys),
		.reset           (reset),
		.cart_ready_i    (cart_ready),
		.cart_replace_i  (cart_replace),
		.cart_crc32_i    (cart_crc),
		.cart_bytes_i    (cart_bytes),
		.cart_title_i    (96'h54524143545345544350474E),
		.cart_catalog_i  (16'h0042),
		.cart_subcat_i   (8'h01),
		.size_code0_i    (size_code0),
		.size_code1_i    (size_code1),
		.event0_i        (event0),
		.block0_i        (block0),
		.event1_i        (1'b0),
		.block1_i        (6'd0),
		.die_busy_i      (die_busy),
		.host_busy_i     (host_busy),
		.host_rd_i       (1'b0),         // no APF flush read modelled here
		.state_apply_i   (sc_state_apply),
		.draining_i      (sc_draining),
		.state_frozen_i  (load_frozen),
		.state_fail_i    (load_fail),
		.frozen_o        (frozen),
		.save_slot_wr_i  (apf_wr),
		.apply_reject_o  (apply_reject),
		.state_done_o    (state_done),
		.slots_settled_i (slots_settled),
		.diag_beats_i    (diag_beats),
		.diag_drops_i    (diag_drops),
		.diag_drain_i    (diag_drain),
		.boot_hold_o     (boot_hold),
		.busy_o          (busy),
		.save_present_o  (save_present),
		.stage_current_o (stage_current),
		.stage_bank_o    (stage_bank),
		.p2_req_o        (p2_req),
		.p2_we_o         (p2_we),
		.p2_addr_o       (p2_addr),
		.p2_wdata_o      (p2_wdata),
		.p2_be_o         (p2_be),
		.p2_ready_i      (1'b1),
		.p2_done_i       (p2_done),
		.p2_rdata_i      (p2_rdata),
		.stage_req_o     (cs_st_req),
		.stage_we_o      (cs_st_we),
		.stage_addr_o    (cs_st_addr),
		.stage_wdata_o   (cs_st_wdata),
		.stage_ready_i   (eng_ready),
		.stage_done_i    (eng_done),
		.stage_rdata_i   (eng_rdata)
	);

	ngpc_state_cart #(
		.DR_WAIT_TIMEOUT (DRW_TO)
	) u_copier (
		.clk             (clk_sys),
		.reset           (reset),
		.cart_save_req   (br_save_req),
		.cart_save_done  (br_save_done),
		.cart_img_wr     (br_img_wr),
		.cart_img_addr   (br_img_addr),
		.cart_img_data   (br_img_data),
		.cart_load_req   (br_load_req),
		.cart_load_done  (br_load_done),
		.cart_load_error (br_load_error),
		.cart_img_rd_addr(br_img_rd_addr),
		.cart_img_rd_data(br_img_rd_data),
		.sc_rd_req       (sc_rd_req),
		.sc_rd_addr      (sc_rd_addr),
		.sc_rd_ready     (eng_ready),
		.sc_rd_done      (eng_done),
		.sc_rd_data      (eng_rdata),
		.sc_rd_active    (sc_rd_active),
		.draining_o      (sc_draining),
		.sc_host_ready   (host_ready),
		.sc_host_wr      (sc_host_wr),
		.sc_host_addr    (sc_host_addr),
		.sc_host_data    (sc_host_data),
		.stage_current_i (stage_current),
		.apply_reject_i  (apply_reject),
		.state_apply_o   (sc_state_apply),
		.state_done_i    (state_done),
		.diag_drain_o    (diag_drain),
		.hold_o          (sc_hold)
	);

	// =========================================================================
	// Staging PSRAM (one memory, two banks) behind core_top's muxes
	// =========================================================================
	wire        eng_req   = sc_rd_active ? sc_rd_req : cs_st_req;
	wire        eng_we    = sc_rd_active ? 1'b0      : cs_st_we;
	wire [24:0] eng_addr  = sc_rd_active ? (sc_rd_addr | {8'd0, stage_bank, 16'd0})
	                                     : cs_st_addr;
	wire [15:0] eng_wdata = cs_st_wdata;

	// core_top's rc6 write-port arbiter (L3): APF takes the cycle, a clashing
	// drain beat is replayed on the next one and the copier is held off.
	reg         sc_replay = 1'b0;
	wire        sc_beat   = sc_host_wr || sc_replay;
	wire        sc_go     = sc_beat && !(apf_wr === 1'b1);
	always @(posedge clk_sys) sc_replay <= !reset && sc_beat && (apf_wr === 1'b1);
	wire        host_wr   = (apf_wr === 1'b1) || sc_beat;
	wire [24:0] host_addr = sc_go ? sc_host_addr : apf_addr;
	wire [15:0] host_data = sc_go ? sc_host_data : apf_data;
	wire        host_bank = sc_go ? ~stage_bank : stage_bank;
	assign      host_ready = stage_host_ready && !sc_replay &&
	                         !(sc_host_wr && (apf_wr === 1'b1));

	// Each access (engine or host) holds the memory PS_LAT clocks. A pending
	// engine request is served before the skid (M1: a request issued the
	// cycle after eng_ready was high is never dropped); eng_ready also
	// requires the skid empty.
	reg [15:0] psram [0:2*BANKW-1];
	reg [15:0] skid_w [0:SKID_DEPTH-1];
	reg [15:0] skid_d [0:SKID_DEPTH-1];
	reg  [7:0] skid_wp = 0, skid_rp = 0;
	wire [7:0] skid_fill  = skid_wp - skid_rp;
	wire       skid_empty = (skid_fill == 8'd0);
	wire       skid_full  = (skid_fill == SKID_DEPTH);
	assign     stage_host_ready = (skid_fill < SKID_DEPTH - 3);
	reg  [3:0] ps_cnt = 0;
	reg        ps_eng = 0;
	wire       ps_idle = (ps_cnt == 4'd0);
	assign     eng_ready = ps_idle && skid_empty && (eng_req !== 1'b1);

	reg eng_drop = 0, eng_oob = 0, skid_overrun = 0, host_clash = 0, p2_oob = 0;

	always @(posedge clk_sys) begin
		eng_done <= 1'b0;
		if (ps_cnt != 4'd0) ps_cnt <= ps_cnt - 4'd1;
		if (ps_cnt == 4'd1 && ps_eng) eng_done <= 1'b1;
		if (reset) begin
			skid_rp <= 8'd0;
			ps_cnt  <= 4'd0;
			ps_eng  <= 1'b0;
		end else if (eng_req === 1'b1) begin
			if (!ps_idle) eng_drop <= 1'b1;
			if (eng_addr[24:17] != 8'd0) eng_oob <= 1'b1;
			if (eng_we) psram[eng_addr[16:1]] <= eng_wdata;
			else        eng_rdata <= psram[eng_addr[16:1]];
			ps_cnt <= PS_LAT;
			ps_eng <= 1'b1;
		end else if (ps_idle && !skid_empty) begin
			psram[skid_w[skid_rp[4:0]]] <= skid_d[skid_rp[4:0]];
			skid_rp <= skid_rp + 8'd1;
			ps_cnt  <= PS_LAT;
			ps_eng  <= 1'b0;
		end
	end

	reg [15:0] host_idle = HOST_IDLE;
	assign host_busy = (host_idle != HOST_IDLE);
	always @(posedge clk_sys) begin
		if (reset) begin
			skid_wp    <= 8'd0;
			diag_beats <= 16'd0;
			diag_drops <= 16'd0;
			host_idle  <= HOST_IDLE;
		end else begin
			if (host_wr === 1'b1) begin
				host_idle  <= 16'd0;
				diag_beats <= diag_beats + 16'd1;
				if (skid_full) begin
					diag_drops   <= diag_drops + 16'd1;
					skid_overrun <= 1'b1;
				end else if (host_addr[24:16] == 9'd0) begin
					skid_w[skid_wp[4:0]] <= {host_bank, host_addr[15:1]};
					skid_d[skid_wp[4:0]] <= host_data;
					skid_wp <= skid_wp + 8'd1;
				end
			end else if (host_idle != HOST_IDLE) begin
				host_idle <= host_idle + 16'd1;
			end
			if (apf_wr === 1'b1 && sc_host_wr === 1'b1) host_clash <= 1'b1;
		end
	end

	// The copier samples host_ready and writes the cycle after.
	reg hr_q = 1'b1, wr_not_ready = 1'b0;
	always @(posedge clk_sys) begin
		if (sc_host_wr === 1'b1 && hr_q !== 1'b1) wr_not_ready <= 1'b1;
		hr_q <= host_ready;
	end

	// ---- cartridge SDRAM (die0, 512 KB) --------------------------------------
	reg [15:0] sdram [0:FLASHW-1];
	reg [15:0] gold  [0:FLASHW-1];      // what flash must hold
	always @(posedge clk_sys) begin
		p2_done <= 1'b0;
		if (p2_req === 1'b1) begin
			if (p2_addr[24:19] != 6'd0) p2_oob <= 1'b1;
			if (p2_we) sdram[p2_addr[18:1]] <= p2_wdata;
			else       p2_rdata <= sdram[p2_addr[18:1]];
			p2_pend <= 1'b1;
		end else if (p2_pend) begin
			p2_pend <= 1'b0;
			p2_done <= 1'b1;
		end
	end

	// =========================================================================
	// Monitors
	// =========================================================================
	integer n_p2wr = 0, n_flips = 0, n_apply = 0, n_sdone = 0, n_drain = 0;
	integer n_ldreq = 0, n_ldone = 0, n_lfail = 0, n_engwr = 0, n_lerr = 0;
	// the save engine's own staging reads (the copier's borrowed reads are
	// excluded): S11 says a frozen state's apply reads nothing
	integer n_engrd = 0;
	// draining_o seen high since the last mark (C1)
	reg     drn_seen = 0;
	reg     bank_q = 1'b0;
	reg     busy_seen = 0, wr_outside_drain = 0, hold_gap = 0;
	reg     lfail_q = 0, lfail_wide = 0, lfail_x = 0;
	reg     sd_rej = 0;                  // apply_reject_o at the last state_done_o
	// load_frozen_o from the bridge's hand-over (cart_load_req, the cycle
	// the check succeeded) until the load finishes: B2 says it is held from
	// the check until the load ends, S11 needs it from before state_apply_i
	// until state_done_o. The load ends at the copier's done when that
	// reports an error, else when the machine restore that follows it ends
	// (the savestate engine's busy falls, the cycle the bridge reports).
	reg     lfw_on = 0, lfw_run = 0, lfw_ssb = 0;
	reg     lfw_saw0 = 0, lfw_saw1 = 0, lfw_sawx = 0;
	// per-load window (armed by do_load)
	reg     lw_arm = 0, lw_apply_seen = 0, lw_p2_before_apply = 0;

	always @(posedge clk_sys) begin
		if (p2_req === 1'b1 && p2_we === 1'b1) begin
			n_p2wr = n_p2wr + 1;
			if (lw_arm && !lw_apply_seen) lw_p2_before_apply = 1;
		end
		if (sc_state_apply === 1'b1) begin
			n_apply = n_apply + 1;
			lw_apply_seen = 1;
		end
		if (state_done === 1'b1) begin
			n_sdone = n_sdone + 1;
			sd_rej  = apply_reject;
		end
		if ((stage_bank ^ bank_q) === 1'b1) n_flips = n_flips + 1;
		bank_q = stage_bank;
		if (sc_host_wr === 1'b1) begin
			n_drain = n_drain + 1;
			if (sc_draining !== 1'b1) wr_outside_drain = 1;
		end
		if (cs_st_req === 1'b1 && cs_st_we === 1'b1) n_engwr = n_engwr + 1;
		if (cs_st_req === 1'b1 && cs_st_we !== 1'b1 && sc_rd_active !== 1'b1) n_engrd = n_engrd + 1;
		if (sc_draining === 1'b1) drn_seen = 1;
		if (br_load_req === 1'b1)  n_ldreq = n_ldreq + 1;
		if (br_load_done === 1'b1) n_ldone = n_ldone + 1;
		if (busy === 1'b1) busy_seen = 1;
		if (sc_rd_req === 1'b1 && sc_hold !== 1'b1) hold_gap = 1;

		if (load_fail === 1'b1) begin
			n_lfail = n_lfail + 1;
			if (lfail_q) lfail_wide = 1;
		end
		if (load_fail !== 1'b0 && load_fail !== 1'b1 && !reset) lfail_x = 1;
		lfail_q = (load_fail === 1'b1);

		if (br_load_req === 1'b1) begin lfw_on = 1; lfw_run = 0; end
		if (lfw_on) begin
			if (load_frozen === 1'b1)      lfw_saw1 = 1;
			else if (load_frozen === 1'b0) lfw_saw0 = 1;
			else                           lfw_sawx = 1;
		end
		if (br_load_done === 1'b1) begin
			if (br_load_error === 1'b1) lfw_on = 0;
			else                        lfw_run = 1;
		end else if (lfw_run && lfw_ssb && ss_busy !== 1'b1) begin
			lfw_on = 0; lfw_run = 0;
		end
		lfw_ssb = (ss_busy === 1'b1);
	end

	reg lerr_q = 1'b0;
	always @(posedge clk_74a) begin
		if (load_err === 1'b1 && lerr_q !== 1'b1) n_lerr = n_lerr + 1;
		lerr_q = (load_err === 1'b1);
	end

	// =========================================================================
	// Bookkeeping
	// =========================================================================
	integer errors = 0;
	string  scn = "setup";
	integer scn_e0 = 0, scn_bal0 = 0, n_scn = 0, n_scn_fail = 0;

	task fail(input string msg);
		begin
			errors = errors + 1;
			$display("   FAIL [%0s] %0s", scn, msg);
		end
	endtask

	task begin_scn(input string id, input string what);
		begin
			scn      = id;
			scn_e0   = errors;
			scn_bal0 = n_sdone - n_apply;
			$display("== %0s  %0s", id, what);
		end
	endtask

	// S8: state_done_o pulses exactly once per state_apply_i pulse.
	task end_scn;
		begin
			repeat (4) @(posedge clk_sys);
			if (n_sdone - n_apply != scn_bal0)
				`FAIL(("S8: state_done minus state_apply = %0d in this scenario", n_sdone - n_apply - scn_bal0))
			n_scn = n_scn + 1;
			if (errors == scn_e0) $display("   PASS %0s", scn);
			else begin
				n_scn_fail = n_scn_fail + 1;
				$display("   FAIL %0s (%0d check(s))", scn, errors - scn_e0);
			end
		end
	endtask

	// counter snapshot taken before an operation
	integer c_p2, c_apply, c_sdone, c_drain, c_ldreq, c_lfail, c_lerr, c_flips, c_engwr, c_engrd;
	task mark;
		begin
			c_p2 = n_p2wr; c_apply = n_apply; c_sdone = n_sdone; c_drain = n_drain;
			c_ldreq = n_ldreq; c_lfail = n_lfail; c_lerr = n_lerr; c_flips = n_flips;
			c_engwr = n_engwr; c_engrd = n_engrd;
			lfw_saw0 = 0; lfw_saw1 = 0; lfw_sawx = 0;
			lfw_on = 0; lfw_run = 0;
			drn_seen = 0;
		end
	endtask

	// =========================================================================
	// The machine model's contents
	// =========================================================================
	function [63:0] int_pat(input [7:0] s, input integer i);
		int_pat = {s, i[7:0], 8'h5A ^ s, ~i[7:0], i[15:0], ~i[15:0]};
	endfunction
	function [7:0] m_pat(input integer which, input [7:0] s, input integer i);
		begin
			case (which)
				0:       m_pat = i[7:0] ^ 8'hC3 ^ s;
				1:       m_pat = (i[7:0] * 8'd7) + 8'h11 + s;
				default: m_pat = i[7:0] + i[11:4] + {s[6:0], 1'b0};
			endcase
		end
	endfunction

	task machine_init(input [7:0] s);
		integer i;
		begin
			for (i = 0; i <= N_INT; i = i + 1) internals[i] = int_pat(s, i);
			for (i = 0; i < SZ0; i = i + 1) mem0[i] = m_pat(0, s, i);
			for (i = 0; i < SZ1; i = i + 1) mem1[i] = m_pat(1, s, i);
			for (i = 0; i < SZ2; i = i + 1) mem2[i] = m_pat(2, s, i);
		end
	endtask

	// a cold-booted machine: nothing restored
	task machine_cold;
		integer i;
		begin
			for (i = 0; i <= N_INT; i = i + 1) internals[i] = 64'hDEADBEEF_DEADBEEF;
			for (i = 0; i < SZ0; i = i + 1) mem0[i] = 8'hFF;
			for (i = 0; i < SZ1; i = i + 1) mem1[i] = 8'hFF;
			for (i = 0; i < SZ2; i = i + 1) mem2[i] = 8'hFF;
		end
	endtask

	function integer machine_bad(input [7:0] s);
		integer i, n;
		begin
			n = 0;
			for (i = 0; i < N_INT; i = i + 1) if (internals[i] !== int_pat(s, i)) n = n + 1;
			for (i = 0; i < SZ0; i = i + 1) if (mem0[i] !== m_pat(0, s, i)) n = n + 1;
			for (i = 0; i < SZ1; i = i + 1) if (mem1[i] !== m_pat(1, s, i)) n = n + 1;
			for (i = 0; i < SZ2; i = i + 1) if (mem2[i] !== m_pat(2, s, i)) n = n + 1;
			machine_bad = n;
		end
	endfunction

	function integer machine_touched(input integer dummy);
		integer i, n;
		begin
			n = 0;
			for (i = 0; i < N_INT; i = i + 1) if (internals[i] !== 64'hDEADBEEF_DEADBEEF) n = n + 1;
			for (i = 0; i < SZ0; i = i + 1) if (mem0[i] !== 8'hFF) n = n + 1;
			for (i = 0; i < SZ1; i = i + 1) if (mem1[i] !== 8'hFF) n = n + 1;
			for (i = 0; i < SZ2; i = i + 1) if (mem2[i] !== 8'hFF) n = n + 1;
			machine_touched = n;
		end
	endfunction

	task chk_restored(input [7:0] s);
		integer n;
		begin
			n = machine_bad(s);
			if (n != 0) `FAIL(("load ok but %0d machine entries not restored", n))
		end
	endtask

	task chk_untouched;
		integer n;
		begin
			n = machine_touched(0);
			if (n != 0) `FAIL(("the load failed but %0d machine entries were written", n))
		end
	endtask

	// =========================================================================
	// Flash (cartridge SDRAM) contents
	// =========================================================================
	function [15:0] rom(input integer i);
		rom = i[15:0] ^ 16'hBEEF;
	endfunction

	// size code 1 (4 Mbit): blocks 8/9 are 8 KB at 0x78000/0x7A000,
	// block 10 is 16 KB at 0x7C000 -- where real NGP saves live
	function integer bw(input integer blk);
		case (blk)
			8:       bw = 32'h3C000;
			9:       bw = 32'h3D000;
			10:      bw = 32'h3E000;
			default: bw = 0;
		endcase
	endfunction
	function integer bn(input integer blk);
		case (blk)
			8:       bn = 4096;
			9:       bn = 4096;
			10:      bn = 8192;
			default: bn = 0;
		endcase
	endfunction

	// Block content for a seed: a few literals in an otherwise erased block,
	// as a real save is. Seeds stay below 0xF0 so a literal is never 0xFFFF.
	function [15:0] cval(input [7:0] seed, input integer b, input integer w);
		begin
			if (seed == 8'h00)   cval = 16'hFFFF;
			else if (w < 16)     cval = {seed, b[3:0], w[3:0]};
			else if (w == 1000)  cval = {seed, 8'hE8};
			else                 cval = 16'hFFFF;
		end
	endfunction

	// the game writes a block (SDRAM and expectation)
	task blk_seed(input integer b, input [7:0] seed);
		integer i;
		begin
			for (i = 0; i < bn(b); i = i + 1) begin
				sdram[bw(b) + i] = cval(seed, b, i);
				gold[bw(b) + i]  = cval(seed, b, i);
			end
		end
	endtask

	// what an apply must leave in a block (expectation only)
	task gold_seed(input integer b, input [7:0] seed);
		integer i;
		begin
			for (i = 0; i < bn(b); i = i + 1) gold[bw(b) + i] = cval(seed, b, i);
		end
	endtask

	task flash_write(input [5:0] blk);
		begin
			@(posedge clk_sys); die_busy <= 2'b01;
			@(posedge clk_sys); block0 <= blk; event0 <= 1;
			@(posedge clk_sys); event0 <= 0;
			repeat (4) @(posedge clk_sys); die_busy <= 2'b00;
		end
	endtask

	function integer sdram_diff(input integer dummy);
		integer i, n;
		begin
			n = 0;
			for (i = 0; i < FLASHW; i = i + 1) if (sdram[i] !== gold[i]) n = n + 1;
			sdram_diff = n;
		end
	endfunction

	task chk_flash(input string what);
		integer n;
		begin
			n = sdram_diff(0);
			if (n != 0) `FAIL(("%0d flash words differ: %0s", n, what))
		end
	endtask

	// flash of blocks 8..10 (words 0x3C000..0x3FFFF) when BL2 was captured
	reg [15:0] bl2_gold [0:16383];
	task gold_from_bl2;
		integer j;
		begin
			for (j = 0; j < 16384; j = j + 1) gold[32'h3C000 + j] = bl2_gold[j];
		end
	endtask

	// =========================================================================
	// Staging images
	// =========================================================================
	reg [15:0] img   [0:BANKW-1];     // the file being built / delivered
	reg [15:0] deliv [0:SLOTW-1];     // the last file APF delivered
	reg [15:0] keep  [0:2*BANKW-1];   // a PSRAM snapshot
	reg  [7:0] seed_of [0:63];
	integer    img_pk;
	reg [31:0] img_c;

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

	task seeds_clear;
		integer b;
		begin
			for (b = 0; b < 64; b = b + 1) seed_of[b] = 8'h00;
		end
	endtask

	task emit(input [15:0] v);
		begin
			img[256 + img_pk] = v;
			img_c  = crc32_word_tb(img_c, v);
			img_pk = img_pk + 1;
		end
	endtask

	// A V4 file as an older (rev 0) writer leaves one: header, each listed
	// block in walk order, literals passed through and erased runs as 0xFFFF
	// plus a length, runs stopping at block boundaries; payload CRC in 19/20.
	task build_img(input [63:0] bmp, input [15:0] tag, input [31:0] ccrc);
		integer b, w, run, k;
		reg [15:0] v;
		reg [31:0] c;
		begin
			for (k = 0; k < BANKW; k = k + 1) img[k] = 16'h0000;
			img_pk = 0; img_c = 32'hFFFFFFFF;
			for (b = 0; b < 64; b = b + 1) if (bmp[b]) begin
				run = 0;
				for (w = 0; w < bn(b); w = w + 1) begin
					v = cval(seed_of[b], b, w);
					if (v == 16'hFFFF) run = run + 1;
					else begin
						if (run != 0) begin emit(16'hFFFF); emit(run[15:0]); run = 0; end
						emit(v);
					end
				end
				if (run != 0) begin emit(16'hFFFF); emit(run[15:0]); end
			end
			c = ~img_c;
			img[0]  = 16'h4E47; img[1] = 16'h5043; img[2] = 16'h5341; img[3] = tag;
			img[4]  = ccrc[15:0]; img[5] = ccrc[31:16];
			img[6]  = {7'd0, cart_bytes[24:16]}; img[7] = cart_bytes[15:0];
			img[8]  = bmp[15:0];  img[9]  = bmp[31:16];
			img[10] = bmp[47:32]; img[11] = bmp[63:48];
			img[19] = c[15:0];    img[20] = c[31:16];
			img[21] = 16'h0001;   // subcat 01, writer rev 0
		end
	endtask

	function integer cbank(input integer dummy);     // committed bank, 0/1
		cbank = (stage_bank === 1'b1) ? 1 : 0;
	endfunction

	function [15:0] hdr(input integer w);            // committed header word
		hdr = psram[cbank(0) * BANKW + w];
	endfunction

	task img_from_committed;
		integer k;
		begin
			for (k = 0; k < BANKW; k = k + 1) img[k] = psram[cbank(0) * BANKW + k];
		end
	endtask

	task snap_psram;
		integer k;
		begin
			for (k = 0; k < 2*BANKW; k = k + 1) keep[k] = psram[k];
		end
	endtask

	function integer bank_vs_keep(input integer b);
		integer k, n;
		begin
			n = 0;
			for (k = 0; k < BANKW; k = k + 1)
				if (psram[b * BANKW + k] !== keep[b * BANKW + k]) n = n + 1;
			bank_vs_keep = n;
		end
	endfunction

	function integer bank_vs_deliv(input integer dummy);
		integer k, n;
		begin
			n = 0;
			for (k = 0; k < SLOTW; k = k + 1)
				if (psram[cbank(0) * BANKW + k] !== deliv[k]) n = n + 1;
			bank_vs_deliv = n;
		end
	endfunction

	task chk_bank_is_file(input string when);
		integer n;
		begin
			n = bank_vs_deliv(0);
			if (n != 0) `FAIL(("the committed bank differs from the delivered file in %0d words %0s", n, when))
		end
	endtask

	// APF delivers img[] into the committed bank, as a save-slot burst.
	task apf_deliver;
		integer k, n;
		begin
			for (k = 0; k < SLOTW; k = k + 1) begin
				deliv[k] = img[k];
				@(posedge clk_sys); apf_wr <= 1'b1; apf_addr <= k * 2; apf_data <= img[k];
				@(posedge clk_sys); apf_wr <= 1'b0;
				repeat (4) @(posedge clk_sys);
			end
			repeat (8) @(posedge clk_sys);
			n = bank_vs_deliv(0);
			if (n != 0) `FAIL(("(setup) the delivery did not land in the committed bank (%0d words)", n))
		end
	endtask

	// =========================================================================
	// Blobs
	// =========================================================================
	reg [31:0] image [0:WORDS-1];      // the blob APF holds (read out / written)

	localparam integer NBLOB = 5;
	localparam integer B_V3 = 0, B_BM = 1, B_BM2 = 2, B_L2 = 3, B_OG = 4;
	reg [31:0] bstore [0:NBLOB*WORDS-1];
	reg  [7:0] bseed  [0:NBLOB-1];     // the machine pattern each one carries

	task blob_keep(input integer id, input [7:0] s);
		integer k;
		begin
			for (k = 0; k < WORDS; k = k + 1) bstore[id*WORDS + k] = image[k];
			bseed[id] = s;
		end
	endtask

	task blob_take(input integer id);
		integer k;
		begin
			for (k = 0; k < WORDS; k = k + 1) image[k] = bstore[id*WORDS + k];
		end
	endtask

	// 16-bit word k of the .sav image embedded in image[]
	function [15:0] secw(input integer k);
		reg [31:0] v;
		begin
			v = image[CARTB + (k >> 1)];
			secw = k[0] ? v[31:16] : v[15:0];
		end
	endfunction

	task set_secw(input integer k, input [15:0] v);
		begin
			if (k[0]) image[CARTB + (k >> 1)][31:16] = v;
			else      image[CARTB + (k >> 1)][15:0]  = v;
		end
	endtask

	// the committed bank (b) against the image embedded in image[]
	function integer bank_vs_image(input integer b);
		integer k, n;
		begin
			n = 0;
			for (k = 0; k < SLOTW; k = k + 1)
				if (psram[b * BANKW + k] !== secw(k)) n = n + 1;
			bank_vs_image = n;
		end
	endfunction

	function integer image_vs_deliv(input integer dummy);
		integer k, n;
		begin
			n = 0;
			for (k = 0; k < SLOTW; k = k + 1) if (secw(k) !== deliv[k]) n = n + 1;
			image_vs_deliv = n;
		end
	endfunction

	// ---- APF host commands (clk_74a) -----------------------------------------
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
			// linear readout; data valid a few clk after the address
			for (k = 0; k < WORDS; k = k + 1) begin
				@(posedge clk_74a); bridge_addr <= BLOBBASE | (k*4); bridge_rd <= 1;
				repeat (3) @(posedge clk_74a);
				image[k] = bridge_rd_data;
				bridge_rd <= 0;
			end
			@(posedge clk_74a); bridge_rd <= 0; bridge_addr <= 32'hF8000000;
			// words nobody writes read back X from the uninitialised simulation
			// RAM; the device's block RAM powers up as zeros
			for (k = 0; k < WORDS; k = k + 1)
				if (^image[k] === 1'bx) image[k] = 32'd0;
			repeat (8) @(posedge clk_74a);
		end
	endtask

	// A save and B1's checks on what it produced.
	task capture(input [31:0] layout, input [31:0] crc);
		integer n;
		begin
			apf_save;
			if (!sv_ok) fail("APF: the capture did not report ok");
			if (image[1] !== HDR_W1)
				`FAIL(("blob word 1 = %h, want %h (bswapped 8416)", image[1], HDR_W1))
			if (image[8420] !== ID_MAGIC || image[8421] !== crc || image[8423] !== ~crc)
				`FAIL(("identity block wrong: %h %h %h %h", image[8420], image[8421], image[8422], image[8423]))
			if (image[8422] !== layout)
				`FAIL(("B1: layout word %0d, want %0d (frozen_o = %b)", image[8422], layout, frozen))
			n = bank_vs_image(cbank(0));
			if (n != 0) `FAIL(("the capture's cart section differs from the committed bank in %0d words", n))
		end
	endtask

	// One write strobe per word. lag = 1 is the measured APF bus: the ADDRESS
	// is the previous strobe's, and the first strobe carries the pre-burst
	// address. lag = 0 is a clean bus.
	integer burst_limit = WORDS;
	task apf_write_burst(input integer lag);
		integer k;
		reg [31:0] a;
		begin
			@(posedge clk_74a);
			for (k = 0; k < burst_limit; k = k + 1) begin
				if (lag) a = (k == 0) ? 32'hF8000050 : (BLOBBASE | ((k-1)*4));
				else     a = BLOBBASE | (k*4);
				@(posedge clk_74a);
				bridge_addr <= a; bridge_wr_data <= image[k]; bridge_wr <= 1;
				@(posedge clk_74a); bridge_wr <= 0;
				repeat (GAP) @(posedge clk_74a);
			end
			@(posedge clk_74a); bridge_addr <= 32'hF8000000;
		end
	endtask

	reg ld_ok, ld_done;
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
			// release: the bridge leaves S_DONE once the request is gone
			repeat (8) @(posedge clk_74a);
			repeat (4) @(posedge clk_sys);
		end
	endtask

	// Write image[] (limit words of it) and issue the load. The caller has
	// called mark. B3: one load_fail pulse per reported failure, none for a
	// success.
	task do_load(input integer lag, input integer limit);
		begin
			burst_limit = limit;
			apf_write_burst(lag);
			burst_limit = WORDS;
			lw_apply_seen = 0; lw_p2_before_apply = 0; lw_arm = 1;
			apf_load;
			lw_arm = 0;
			if (ld_done) begin
				if (n_lerr - c_lerr != (ld_ok ? 0 : 1))
					`FAIL(("%0d savestate_load_err rising edges for one load", n_lerr - c_lerr))
				if (n_lfail - c_lfail != (ld_ok ? 0 : 1))
					`FAIL(("B3: %0d load_fail_o pulse(s) for a load reported %0s", n_lfail - c_lfail, ld_ok ? "ok" : "failed"))
			end
		end
	endtask

	// The wake order hardware produces: the delivered file's boot apply is
	// still pending (slots not settled) when the load arrives, and the slots
	// settle while the copier drains the state.
	task do_load_settle_mid_drain(input integer lag);
		begin
			if (boot_hold !== 1'b1) fail("(setup) no boot apply pending before the load");
			fork
				do_load(lag, WORDS);
				begin : settle_mid
					integer n;
					n = 0;
					while (n_drain < c_drain + 4000 && n < 6000000) begin @(posedge clk_sys); n = n + 1; end
					if (sc_draining !== 1'b1) fail("(setup) the copier was not draining when the slots settled");
					@(posedge clk_sys); slots_settled <= 1'b1;
				end
			join
		end
	endtask

	// the bridge handed the section over once and the engine served one apply;
	// load_frozen_o held at `lf` from the check until the load finished
	task chk_served(input lf);
		begin
			if (n_ldreq - c_ldreq != 1)
				`FAIL(("%0d cart_load_req pulses from the bridge, want 1", n_ldreq - c_ldreq))
			if (n_apply - c_apply != 1)
				`FAIL(("%0d state_apply pulses, want 1", n_apply - c_apply))
			if (n_sdone - c_sdone != 1)
				`FAIL(("%0d state_done pulses, want 1", n_sdone - c_sdone))
			if (lfw_on)
				fail("(bench) the load never finished: no copier error and no end of the machine restore");
			if (lfw_sawx)
				fail("B2: load_frozen_o was X during the load");
			if (lf && (!lfw_saw1 || lfw_saw0))
				fail("B2: load_frozen_o not held at 1 from the check until the load finished (layout 3)");
			if (!lf && (!lfw_saw0 || lfw_saw1))
				fail("B2: load_frozen_o not 0 throughout a layout-2 load");
		end
	endtask

	// the bridge refused the blob before the copier or the engine moved
	task chk_not_served;
		begin
			if (n_ldreq != c_ldreq) fail("the copier was handed the section of a refused blob");
			if (n_drain != c_drain) fail("staging was drained for a refused blob");
			if (n_apply != c_apply || n_sdone != c_sdone) fail("a state apply ran for a refused blob");
		end
	endtask

	task chk_frozen(input v, input string why);
		begin
			if (frozen !== v) `FAIL(("frozen_o = %b, want %b: %0s", frozen, v, why))
		end
	endtask

	// S10 word 23 of the last apply, a state apply: {1, 0, fail_idx, v}.
	// idx < 0: fail_idx is not specified for this verdict (S11), not checked.
	task chk_verdict(input [7:0] v, input integer idx);
		begin
`ifdef NGPC_SAVE_DIAG
`ifndef RC5LP_NO_PROBES
			if (u_save.diag_verdict[7:0] !== v || u_save.diag_verdict[15:14] !== 2'b10 ||
			    (idx >= 0 && u_save.diag_verdict[13:8] !== idx[5:0]))
				`FAIL(("S10: verdict word %h, want {1, 0, fail_idx %0d (-1 = any), verdict %0d}",
				       u_save.diag_verdict, idx, v))
`endif
`endif
		end
	endtask

	task chk_verdict7;
		chk_verdict(8'd7, -1);
	endtask

	// S11: the frozen state's apply read nothing from staging -- nor did a
	// separate boot apply after it (S8: the one state apply served both)
	task chk_no_engine_read;
		begin
			if (n_engrd != c_engrd)
				`FAIL(("S11: the save engine read staging %0d time(s) during a frozen state's load", n_engrd - c_engrd))
		end
	endtask

	// ---- engine idle / publish helpers ---------------------------------------
	task wait_idle(input integer max);
		integer n, q;
		begin
			n = 0; q = 0;
			while (q < 64 && n < max) begin
				@(posedge clk_sys); n = n + 1;
				if (busy === 1'b0 && boot_hold === 1'b0) q = q + 1; else q = 0;
			end
			if (q < 64) fail("the save engine never went idle");
		end
	endtask

	reg flip_ok;
	task wait_flip(input integer f0, input integer max);
		integer n;
		begin
			n = 0;
			while (n_flips <= f0 && n < max) begin @(posedge clk_sys); n = n + 1; end
			flip_ok = (n_flips > f0);
			repeat (8) @(posedge clk_sys);
		end
	endtask

	task settle;
		begin
			@(posedge clk_sys); slots_settled <= 1'b1;
			wait_idle(600000);
		end
	endtask

	// The game saves a block; the image must be published.
	task later_save_publishes(input integer b, input [7:0] seed);
		integer f0;
		begin
			wait_idle(600000);
			f0 = n_flips;
			blk_seed(b, seed);
			flash_write(b[5:0]);
			wait_flip(f0, 800000);
			if (!flip_ok) `FAIL(("a later game save (block %0d) did not publish", b))
			else begin
				if (save_present !== 1'b1) fail("save_present low after a published save");
				if (hdr(4) !== cart_crc[15:0] || hdr(5) !== cart_crc[31:16])
					fail("the published image does not carry this cartridge's CRC");
			end
		end
	endtask

	// The game saves a block in a frozen session: no pass starts, nothing is
	// published, staging is untouched, no claim; the engine reports current.
	task later_save_blocked(input integer b, input [7:0] seed);
		integer f0, e0;
		begin
			wait_idle(600000);
			snap_psram;
			f0 = n_flips; e0 = n_engwr;
			busy_seen = 0;
			blk_seed(b, seed);
			flash_write(b[5:0]);
			repeat (QUIET + 150000) @(posedge clk_sys);
			if (n_flips != f0)  fail("a later game save published in a frozen session");
			if (n_engwr != e0)  fail("a staging pass wrote PSRAM in a frozen session");
			if (busy_seen)      fail("a staging pass started in a frozen session");
			if (save_present !== 1'b0) fail("save_present high in a frozen session");
			if (stage_current !== 1'b1) fail("stage_current low while frozen and idle");
			if (bank_vs_keep(0) != 0 || bank_vs_keep(1) != 0) fail("staging changed in a frozen session");
			if (frozen !== 1'b1) fail("the freeze did not hold");
		end
	endtask

	// A new core launch: the one reset net pulses, the cartridge is
	// downloaded again, the machine is cold. PSRAM keeps its contents.
	// S2: the committed bank survives both reset and cart_replace.
	reg     bank_before;
	reg     s2_saw_one = 0;
	task reconfigure(input [31:0] crc, input integer ready);
		integer i;
		begin
			wait_idle(600000);
			bank_before = stage_bank;
			if (bank_before === 1'b1) s2_saw_one = 1;
			@(posedge clk_sys);
			reset <= 1; cart_ready <= 0; slots_settled <= 0; die_busy <= 2'b00;
			event0 <= 0; apf_wr <= 0;
			repeat (10) @(posedge clk_sys);
			cart_crc <= crc;
			reset <= 0;
			for (i = 0; i < FLASHW; i = i + 1) begin sdram[i] = rom(i); gold[i] = rom(i); end
			machine_cold;
			@(posedge clk_sys); cart_replace <= 1;
			@(posedge clk_sys); cart_replace <= 0;
			repeat (4) @(posedge clk_sys);
			if (ready) cart_ready <= 1;
			repeat (4) @(posedge clk_sys);
			if (stage_bank !== bank_before) fail("S2: stage_bank changed by reset / cart_replace");
			if (frozen !== 1'b0) fail("S1: frozen_o not cleared by reset");
		end
	endtask

	// =========================================================================
	// The run
	// =========================================================================
	integer i, bank0, n;
	reg [63:0] dirty_q;

	initial begin
		for (i = 0; i < FLASHW; i = i + 1) begin sdram[i] = rom(i); gold[i] = rom(i); end
		for (i = 0; i < 2*BANKW; i = i + 1) psram[i] = 16'hDEAD;
		for (i = 0; i < WORDS; i = i + 1) image[i] = 32'd0;
		machine_cold;
		repeat (20) @(posedge clk_sys);

		// ==== a delivered V3-tagged file ========================================
		begin_scn("FZV-CAP", "V3-tagged file refused at boot; a capture stamps layout 3 [S1a, B1]");
		reconfigure(CRC_A, 1);
		seeds_clear; seed_of[8] = 8'h21; seed_of[10] = 8'h22;
		build_img(64'h500, TAG_V3, CRC_A);
		apf_deliver;
		mark;
		settle;
		chk_frozen(1'b1, "S1a: a refused V3-tagged file did not freeze the session");
		if (n_p2wr != c_p2) fail("flash written by a refused file");
		if (save_present !== 1'b0) fail("save_present high after the refusal");
		// the cold-booted game saves; the freeze keeps it off the card (a
		// full pass takes far longer than QUIET, so the wait is the helper's)
		later_save_blocked(8, 8'h23);
		if (n_flips != c_flips) fail("a pass published in the frozen session");
		machine_init(8'h11);
		capture(32'd3, CRC_A);
		n = image_vs_deliv(0);
		if (n != 0) `FAIL(("the capture's cart section differs from the refused file in %0d words", n))
		blob_keep(B_V3, 8'h11);
		end_scn;

		// ---- the layout-3 blob loaded in the same session ---------------------
		begin_scn("L3-SAME", "layout-3 blob in the same frozen session: S11, machine restored [B2, S11, S1d]");
		wait_idle(600000);
		dirty_q = u_save.dirty0;
		if (dirty_q !== 64'h100) fail("(setup) dirty is not the game's block 8");
		snap_psram; bank0 = stage_bank;
		machine_cold;
		blob_take(B_V3);
		mark;
		do_load(1, WORDS);
		if (!ld_ok) fail("a layout-3 state did not load in a frozen session");
		else chk_restored(bseed[B_V3]);
		chk_served(1'b1);
		if (sd_rej !== 1'b0) fail("S11: apply_reject_o high with state_done_o");
		if (n_p2wr != c_p2) fail("S11: flash written");
		chk_flash("S11 must leave flash as the session had it");
		if (u_save.dirty0 !== dirty_q)
			`FAIL(("S11: dirty0 = %h, want it unchanged (%h)", u_save.dirty0, dirty_q))
		if (stage_bank !== bank0) fail("S11: the committed bank changed");
		if (bank_vs_keep(bank0) != 0) fail("S11: committed bank contents changed");
		chk_frozen(1'b1, "S11/S1d: frozen after a layout-3 state");
		chk_no_engine_read;
		chk_verdict7;
		end_scn;

		// ==== wake: reconfigure, no delivery, the layout-3 blob =================
		begin_scn("FZV-WAKE", "reset-only wake, layout-3 blob: loads, flash untouched, frozen again [S11, S1d]");
		reconfigure(CRC_A, 1);
		mark;
		settle;
		chk_frozen(1'b0, "(setup) a boot with nothing delivered froze");
		if (n_p2wr != c_p2) fail("(setup) a boot apply with nothing delivered wrote flash");
		chk_bank_is_file("(setup: PSRAM kept across the reconfigure)");
		bank0 = stage_bank;
		machine_cold;
		blob_take(B_V3);
		mark;
		do_load(1, WORDS);
		if (!ld_ok) fail("the frozen session's savestate did not load at wake");
		else chk_restored(bseed[B_V3]);
		chk_served(1'b1);
		if (sd_rej !== 1'b0) fail("S11: apply_reject_o high with state_done_o");
		if (n_p2wr != c_p2) fail("S11: flash written at wake");
		chk_flash("flash must stay the ROM");
		if (stage_bank !== bank0) fail("the committed bank changed");
		chk_frozen(1'b1, "S1d: the wake must come back frozen");
		if (u_save.dirty0 !== 64'd0)
			`FAIL(("S11: dirty0 = %h, want it unchanged (empty)", u_save.dirty0))
		chk_no_engine_read;
		chk_verdict7;
		chk_bank_is_file("after the load");
		later_save_blocked(10, 8'h24);
		chk_bank_is_file("after a later game save");
		end_scn;

		// ==== a delivered file with a bad magic =================================
		begin_scn("FZM-CAP", "bad-magic file refused at boot; a capture stamps layout 3 [S1a, B1]");
		reconfigure(CRC_A, 1);
		seeds_clear; seed_of[8] = 8'h41; seed_of[10] = 8'h42;
		build_img(64'h500, TAG_V4, CRC_A);
		img[1] = 16'h5058;                 // "PX": the magic fails at word 1
		apf_deliver;
		mark;
		settle;
		chk_frozen(1'b1, "S1a: a refused bad-magic file did not freeze the session");
		if (n_p2wr != c_p2) fail("flash written by a refused file");
		if (save_present !== 1'b0) fail("save_present high after the refusal");
		later_save_blocked(10, 8'h43);
		if (n_flips != c_flips) fail("a pass published in the frozen session");
		machine_init(8'h12);
		capture(32'd3, CRC_A);
		n = image_vs_deliv(0);
		if (n != 0) `FAIL(("the capture's cart section differs from the refused file in %0d words", n))
		blob_keep(B_BM, 8'h12);
		end_scn;

		begin_scn("FZM-WAKE", "reset-only wake, layout-3 blob; the next sleep is layout 3 again [S11, S1d, B1]");
		reconfigure(CRC_A, 1);
		mark;
		settle;
		chk_frozen(1'b0, "(setup) a boot with nothing delivered froze");
		chk_bank_is_file("(setup)");
		bank0 = stage_bank;
		machine_cold;
		blob_take(B_BM);
		mark;
		do_load(1, WORDS);
		if (!ld_ok) fail("the frozen session's savestate did not load at wake");
		else chk_restored(bseed[B_BM]);
		chk_served(1'b1);
		if (sd_rej !== 1'b0) fail("S11: apply_reject_o high with state_done_o");
		if (n_p2wr != c_p2) fail("S11: flash written at wake");
		chk_flash("flash must stay the ROM");
		if (stage_bank !== bank0) fail("the committed bank changed");
		chk_frozen(1'b1, "S1d: the wake must come back frozen (S6 would have unfrozen it)");
		if (u_save.dirty0 !== 64'd0)
			`FAIL(("S11: dirty0 = %h, want it unchanged (empty)", u_save.dirty0))
		chk_no_engine_read;
		chk_verdict7;
		later_save_blocked(8, 8'h44);
		chk_bank_is_file("after a later game save");
		// the next sleep
		machine_init(8'h13);
		capture(32'd3, CRC_A);
		n = image_vs_deliv(0);
		if (n != 0) `FAIL(("the second capture's section differs from the file in %0d words", n))
		blob_keep(B_BM2, 8'h13);
		end_scn;

		begin_scn("FZM-WAKE2", "file re-delivered, slots settle mid-drain: one S11 apply serves both [S8, S11]");
		reconfigure(CRC_A, 1);
		img_from_committed;                // what APF flushed at the sleep
		apf_deliver;
		bank0 = stage_bank;
		machine_cold;
		blob_take(B_BM2);
		mark;
		do_load_settle_mid_drain(1);
		if (!ld_ok) fail("the frozen session's savestate did not load at wake");
		else chk_restored(bseed[B_BM2]);
		chk_served(1'b1);
		if (sd_rej !== 1'b0) fail("S11: apply_reject_o high with state_done_o");
		if (lw_p2_before_apply) fail("S8: flash written before the state pulse (a boot apply ran under draining)");
		wait_idle(600000);
		repeat (2000) @(posedge clk_sys);
		if (n_p2wr != c_p2) fail("flash written: the pending boot apply was not served by the S11 apply");
		if (n_sdone - c_sdone != 1) fail("a further state_done after the load");
		chk_flash("flash must stay the ROM");
		if (stage_bank !== bank0) fail("the committed bank changed");
		chk_frozen(1'b1, "S1d: frozen after the wake");
		if (u_save.dirty0 !== 64'd0)
			`FAIL(("S11: dirty0 = %h, want it unchanged (empty)", u_save.dirty0))
		// the last apply was the S11 one: no separate boot apply ran after it,
		// which would have read the committed bank's header
		chk_no_engine_read;
		chk_verdict7;
		chk_bank_is_file("after the load");
		later_save_blocked(10, 8'h45);
		chk_bank_is_file("after a later game save");
		end_scn;

		// ==== a healthy session: layout 2 ======================================
		begin_scn("LP2-CAP", "good file accepted, save published, capture stamps layout 2 [S1, B1, S10]");
		reconfigure(CRC_A, 1);
		seeds_clear; seed_of[8] = 8'h31; seed_of[10] = 8'h32;
		build_img(64'h500, TAG_V4, CRC_A);
		apf_deliver;
		mark;
		settle;
		chk_frozen(1'b0, "a good file froze the session");
		if (n_p2wr - c_p2 != 12288)
			`FAIL(("(setup) the boot apply wrote %0d flash words, want 12288", n_p2wr - c_p2))
		gold_seed(8, 8'h31); gold_seed(10, 8'h32);
		chk_flash("the delivered save was not restored");
		later_save_publishes(9, 8'h33);
		if (hdr(8) !== 16'h0700) `FAIL(("(setup) published bitmap %h, want 0700", hdr(8)))
		if (hdr(21) !== 16'h0601) `FAIL(("S10: published word 21 = %h, want 0601 (rev 06, subcat 01)", hdr(21)))
		machine_init(8'h14);
		capture(32'd2, CRC_A);
		if (secw(21) !== 16'h0601) `FAIL(("S10: captured image word 21 = %h, want 0601", secw(21)))
		for (i = 0; i < 16384; i = i + 1) bl2_gold[i] = gold[32'h3C000 + i];
		blob_keep(B_L2, 8'h14);
		// the game saves over it: that is what a load has to rewind
		later_save_publishes(8, 8'h34);
		end_scn;

		begin_scn("LP2-SAME", "layout-2 blob in the same session: the rc4 path [B2, S4, S2, B3]");
		wait_idle(600000);
		machine_cold;
		blob_take(B_L2);
		mark;
		do_load(1, WORDS);
		if (!ld_ok) fail("a layout-2 state did not load");
		else chk_restored(bseed[B_L2]);
		chk_served(1'b0);
		if (sd_rej !== 1'b0) fail("apply_reject_o high for an accepted state");
		if (n_p2wr - c_p2 != 16384)
			`FAIL(("%0d flash writes, want the state's 16384", n_p2wr - c_p2))
		gold_from_bl2;
		chk_flash("flash not rewound to the state");
		if (u_save.dirty0 !== 64'h700)
			`FAIL(("S4: dirty0 = %h, want the image bitmap 0700", u_save.dirty0))
		if (n_flips - c_flips != 1) fail("S2: the drained bank was not committed");
		if (bank_vs_image(cbank(0)) != 0) fail("the committed bank does not hold the state's image");
		chk_frozen(1'b0, "a layout-2 load froze a healthy session");
		if (save_present !== 1'b1) fail("save_present low after an accepted state with data");
		later_save_publishes(10, 8'h35);
		if (hdr(8) !== 16'h0700) `FAIL(("published bitmap %h, want 0700", hdr(8)))
		end_scn;

		begin_scn("L3-MID", "the layout-3 blob into a healthy session: S11 freezes it [S11, S1d, B2]");
		wait_idle(600000);
		dirty_q = u_save.dirty0;
		snap_psram; bank0 = stage_bank;
		machine_cold;
		blob_take(B_V3);
		mark;
		do_load(1, WORDS);
		if (!ld_ok) fail("a layout-3 state did not load");
		else chk_restored(bseed[B_V3]);
		chk_served(1'b1);
		if (sd_rej !== 1'b0) fail("S11: apply_reject_o high with state_done_o");
		if (n_p2wr != c_p2) fail("S11: flash written");
		chk_flash("S11 must leave flash as the session had it");
		if (u_save.dirty0 !== dirty_q)
			`FAIL(("S11: dirty0 = %h, want it unchanged (%h)", u_save.dirty0, dirty_q))
		if (stage_bank !== bank0) fail("S11: the committed bank changed");
		if (bank_vs_keep(bank0) != 0) fail("S11: committed bank contents changed");
		chk_frozen(1'b1, "S1d: a frozen state freezes any session");
		// the V3 file's bitmap (0500) omits dirty block 9: an S11 apply that
		// looked at the image would see a coverage miss (S5)
		chk_no_engine_read;
		chk_verdict7;
		later_save_blocked(9, 8'h36);
		end_scn;

		// ---- a layout-2 state loaded into the now frozen session ---------------
		// B2: load_frozen_o follows each load's own layout word, so it is 0
		// here right after a layout-3 load. The state apply is an ordinary
		// accepted one: flash rewound, dirty := its bitmap (S4). But no state
		// apply clears the freeze (S1), and a frozen session commits no
		// drained bank (S1, S2).
		begin_scn("L2-FROZEN", "layout-2 blob right after the layout-3 load: rewinds, stays frozen, no commit [B2, S1, S2, S4]");
		wait_idle(600000);
		if (u_save.dirty0 !== 64'h700) `FAIL(("(setup) dirty0 = %h, want 0700", u_save.dirty0))
		snap_psram; bank0 = stage_bank;
		machine_cold;
		blob_take(B_L2);
		mark;
		do_load(1, WORDS);
		if (!ld_ok) fail("a layout-2 state did not load in a frozen session");
		else chk_restored(bseed[B_L2]);
		chk_served(1'b0);
		if (sd_rej !== 1'b0) fail("apply_reject_o high for an accepted state");
		if (n_p2wr - c_p2 != 16384)
			`FAIL(("%0d flash writes, want the state's 16384", n_p2wr - c_p2))
		gold_from_bl2;
		chk_flash("flash not rewound to the state");
		if (u_save.dirty0 !== 64'h700)
			`FAIL(("S4: dirty0 = %h, want the image bitmap 0700", u_save.dirty0))
		if (stage_bank !== bank0 || n_flips != c_flips)
			fail("S1/S2: a frozen session committed the drained bank");
		if (bank_vs_keep(bank0) != 0) fail("S1: committed bank contents changed");
		chk_frozen(1'b1, "S1: no state apply clears the freeze");
		if (save_present !== 1'b0) fail("S1: save_present high in a frozen session");
		chk_verdict(8'd1, -1);
		later_save_blocked(10, 8'h38);
		end_scn;

		begin_scn("LP2-WAKE", "old (rev 0) layout-2 blob, file re-delivered, settle mid-drain [B2, S8, S2, S4]");
		reconfigure(CRC_A, 1);
		img_from_committed;
		apf_deliver;
		blob_take(B_L2);
		set_secw(21, 16'h0001);            // written by an rc4 engine
		machine_cold;
		mark;
		do_load_settle_mid_drain(1);
		if (!ld_ok) fail("an old layout-2 state did not load at wake");
		else chk_restored(bseed[B_L2]);
		chk_served(1'b0);
		if (sd_rej !== 1'b0) fail("apply_reject_o high for an accepted state");
		if (lw_p2_before_apply) fail("S8: flash written before the state pulse (a boot apply ran under draining)");
		wait_idle(600000);
		repeat (2000) @(posedge clk_sys);
		if (n_p2wr - c_p2 != 16384)
			`FAIL(("%0d flash writes, want exactly the state's 16384 (one apply)", n_p2wr - c_p2))
		gold_from_bl2;
		chk_flash("flash is not the state's");
		if (u_save.dirty0 !== 64'h700)
			`FAIL(("S4: dirty0 = %h, want the image bitmap 0700", u_save.dirty0))
		if (bank_vs_image(cbank(0)) != 0) fail("the committed bank is not the drained state image");
		chk_frozen(1'b0, "an old layout-2 state froze the wake");
		later_save_publishes(9, 8'h37);
		end_scn;

		// ==== another game's image left in PSRAM ================================
		begin_scn("OG-CAP", "cart B publishes; a cart-A session with no file and no pass captures it [B1]");
		reconfigure(CRC_B, 1);
		settle;
		chk_frozen(1'b0, "(setup) cart B's boot froze");
		later_save_publishes(8, 8'h51);
		if (hdr(4) !== CRC_B[15:0] || hdr(5) !== CRC_B[31:16]) fail("(setup) cart B's image lacks cart B's CRC");
		reconfigure(CRC_A, 1);
		mark;
		settle;
		chk_frozen(1'b0, "(setup) a boot with nothing delivered froze");
		if (n_p2wr != c_p2 || n_flips != c_flips) fail("(setup) the cart-A session wrote flash or published");
		machine_init(8'h15);
		capture(32'd2, CRC_A);
		if (secw(0) !== 16'h4E47 || secw(1) !== 16'h5043 || secw(2) !== 16'h5341 ||
		    secw(4) !== CRC_B[15:0] || secw(5) !== CRC_B[31:16])
			fail("(setup) the captured section is not cart B's image");
		blob_keep(B_OG, 8'h15);
		end_scn;

		begin_scn("OG-WAKE", "stale other-game image at wake: S6 no-op, not frozen, saving works [S6, S10]");
		reconfigure(CRC_A, 1);
		mark;
		settle;
		chk_frozen(1'b0, "(setup) a boot with nothing delivered froze");
		snap_psram; bank0 = stage_bank;
		machine_cold;
		blob_take(B_OG);
		mark;
		do_load(1, WORDS);
		if (!ld_ok) fail("S6: another game's image with dirty empty must load as a no-op");
		else chk_restored(bseed[B_OG]);
		chk_served(1'b0);
		if (sd_rej !== 1'b0) fail("S6: apply_reject_o high for a no-op");
		if (n_p2wr != c_p2) fail("S6: flash written");
		chk_flash("flash must stay the ROM");
		if (stage_bank !== bank0) fail("S6: bank changed");
		if (bank_vs_keep(bank0) != 0) fail("S6: committed bank contents changed");
		if (u_save.dirty0 !== 64'd0) `FAIL(("S6: dirty0 = %h, want empty", u_save.dirty0))
		chk_frozen(1'b0, "S6 never freezes");
		if (save_present !== 1'b0) fail("save_present high after a no-op");
		later_save_publishes(8, 8'h52);
		if (hdr(8) !== 16'h0100) `FAIL(("published bitmap %h, want 0100", hdr(8)))
`ifdef NGPC_SAVE_DIAG
		if (hdr(23) !== 16'h8406)
			`FAIL(("S10: word 23 = %h, want 8406 (state, fail_idx 4, no image)", hdr(23)))
`endif
		end_scn;

		// ---- the same blob once this session has saved -------------------------
		// S6 with dirty non-empty: a reject, so the load fails and the bridge
		// pulses load_fail. S6 never freezes, not through that pulse either:
		// the session is not wake-shaped (dirty).
		begin_scn("OG-DIRTY", "stale other-game image after a save: S6 reject, load_fail, not frozen [S6, B3, S1c, S10]");
		wait_idle(600000);
		dirty_q = u_save.dirty0;
		if (dirty_q !== 64'h100) `FAIL(("(setup) dirty0 = %h, want 0100", dirty_q))
		snap_psram; bank0 = stage_bank;
		machine_cold;
		blob_take(B_OG);
		mark;
		do_load(1, WORDS);
		if (ld_ok) fail("S6: another game's image with dirty non-empty was reported loaded");
		chk_served(1'b0);
		if (sd_rej !== 1'b1) fail("S6: apply_reject_o low with dirty non-empty");
		chk_untouched;
		if (n_p2wr != c_p2) fail("S6: flash written");
		chk_flash("flash must stay the session's");
		if (stage_bank !== bank0 || n_flips != c_flips) fail("S6: bank changed");
		if (bank_vs_keep(bank0) != 0) fail("S6: committed bank contents changed");
		if (u_save.dirty0 !== dirty_q)
			`FAIL(("S6: dirty0 = %h, want it unchanged (%h)", u_save.dirty0, dirty_q))
		chk_frozen(1'b0, "S6 never freezes, nor does the load_fail it causes (not wake-shaped)");
		chk_verdict(8'd6, 4);
		later_save_publishes(9, 8'h53);
		if (hdr(8) !== 16'h0300) `FAIL(("published bitmap %h, want 0300", hdr(8)))
		end_scn;

		// ==== bridge-level failures ============================================
		begin_scn("BF-ID", "identity mismatch at a wake-shaped session: load_fail, frozen [B3, S1c]");
		reconfigure(CRC_A, 1);
		settle;
		chk_frozen(1'b0, "(setup)");
		snap_psram; bank0 = stage_bank;
		blob_take(B_L2);
		image[8421] = CRC_B; image[8423] = ~CRC_B;   // a state of cart B
		mark;
		do_load(1, WORDS);
		if (ld_ok) fail("a state of another cartridge was accepted");
		chk_not_served;
		chk_untouched;
		if (n_p2wr != c_p2) fail("flash written");
		chk_frozen(1'b1, "S1c: a failed load in a wake-shaped session must freeze");
		if (stage_bank !== bank0 || bank_vs_keep(bank0) != 0) fail("the committed bank changed");
		later_save_blocked(8, 8'h61);
		end_scn;

		begin_scn("BF-INC", "incomplete blob at a wake-shaped session: load_fail, frozen [B3, S1c]");
		reconfigure(CRC_A, 1);
		settle;
		snap_psram; bank0 = stage_bank;
		blob_take(B_L2);
		mark;
		do_load(1, 20000);
		if (ld_ok) fail("an incomplete blob was loaded");
		chk_not_served;
		chk_untouched;
		chk_frozen(1'b1, "S1c: a failed load in a wake-shaped session must freeze");
		if (stage_bank !== bank0 || bank_vs_keep(bank0) != 0) fail("the committed bank changed");
		later_save_blocked(10, 8'h62);
		end_scn;

		begin_scn("BF-LAY", "layout word 4 at a wake-shaped session: rejected, frozen [B2, B3, S1c]");
		reconfigure(CRC_A, 1);
		settle;
		blob_take(B_L2);
		image[8422] = 32'd4;
		mark;
		do_load(1, WORDS);
		if (ld_ok) fail("B2: a layout-4 state was accepted");
		chk_not_served;
		chk_untouched;
		chk_frozen(1'b1, "S1c: a failed load in a wake-shaped session must freeze");
		later_save_blocked(8, 8'h63);
		end_scn;

		begin_scn("BF-TO", "copier timeout at a wake (cart not ready): load_fail, frozen [B3, S1c, C1]");
		reconfigure(CRC_A, 0);             // the cartridge is not ready at the load
		@(posedge clk_sys); slots_settled <= 1'b1;
		repeat (100) @(posedge clk_sys);
		blob_take(B_L2);
		mark;
		do_load(1, WORDS);
		if (ld_ok) fail("a load passed a copier that never drained");
		if (n_ldreq - c_ldreq != 1) fail("(setup) the bridge did not hand the section to the copier");
		if (n_drain != c_drain) fail("C1: staging drained on the timeout path");
		if (drn_seen) fail("C1: draining_o rose although the drain never started");
		if (n_apply != c_apply) fail("a state apply ran on the timeout path");
		chk_untouched;
		chk_frozen(1'b1, "S1c: a copier timeout in a wake-shaped session must freeze");
		@(posedge clk_sys); cart_ready <= 1'b1;
		mark;
		wait_idle(600000);
		if (n_p2wr != c_p2) fail("the boot apply with nothing delivered wrote flash");
		chk_frozen(1'b1, "S1: a boot apply with nothing delivered is not an accepted one");
		later_save_blocked(8, 8'h64);
		end_scn;

		begin_scn("BF-S7", "engine refuses the image at wake (tag V3): one load_fail, frozen [B3, S7, S1b, S1c]");
		reconfigure(CRC_A, 1);
		settle;
		snap_psram; bank0 = stage_bank;
		blob_take(B_L2);
		set_secw(3, TAG_V3);
		machine_cold;
		mark;
		do_load(1, WORDS);
		if (ld_ok) fail("S7: a V3-tagged state image was accepted");
		chk_served(1'b0);
		if (sd_rej !== 1'b1) fail("S7: apply_reject_o low with state_done_o");
		chk_untouched;
		if (n_p2wr != c_p2) fail("S7: flash written");
		chk_flash("flash must stay the ROM");
		if (stage_bank !== bank0 || bank_vs_keep(bank0) != 0) fail("S7: the committed bank changed");
		chk_frozen(1'b1, "S1b/S1c: a refused state in a wake-shaped session must freeze");
		later_save_blocked(9, 8'h65);
		end_scn;

		begin_scn("BF-ID-ACC", "identity mismatch after an accepted boot apply: not frozen [S1c]");
		reconfigure(CRC_A, 1);
		seeds_clear; seed_of[8] = 8'h71; seed_of[10] = 8'h72;
		build_img(64'h500, TAG_V4, CRC_A);
		apf_deliver;
		mark;
		settle;
		chk_frozen(1'b0, "(setup) a good file froze the session");
		if (n_p2wr - c_p2 != 12288) fail("(setup) the delivered file was not applied");
		blob_take(B_L2);
		image[8421] = CRC_B; image[8423] = ~CRC_B;
		machine_cold;
		mark;
		do_load(1, WORDS);
		if (ld_ok) fail("a state of another cartridge was accepted");
		chk_not_served;
		chk_untouched;
		chk_frozen(1'b0, "S1c: the session had an accepted apply, it is not wake-shaped");
		later_save_publishes(9, 8'h73);
		end_scn;

		begin_scn("BF-ID-DIRTY", "identity mismatch in a session with no file that has saved: not frozen [S1c]");
		reconfigure(CRC_A, 1);
		settle;                            // nothing delivered: no apply accepted
		chk_frozen(1'b0, "(setup)");
		later_save_publishes(10, 8'h75);   // dirty non-empty, base_q still clear
		blob_take(B_L2);
		image[8421] = CRC_B; image[8423] = ~CRC_B;
		machine_cold;
		mark;
		do_load(1, WORDS);
		if (ld_ok) fail("a state of another cartridge was accepted");
		chk_not_served;
		chk_untouched;
		if (n_p2wr != c_p2) fail("flash written");
		chk_frozen(1'b0, "S1c: dirty is not empty, the session is not wake-shaped");
		later_save_publishes(8, 8'h76);
		end_scn;

		begin_scn("BF-INC-ACC0", "incomplete blob after an accepted EMPTY-bitmap boot apply: not frozen [S1c]");
		reconfigure(CRC_A, 1);
		seeds_clear;
		build_img(64'h0, TAG_V4, CRC_A);    // accepted, applies nothing: base set, dirty empty
		apf_deliver;
		mark;
		settle;
		chk_frozen(1'b0, "(setup) an empty-bitmap file was refused");
		if (n_p2wr != c_p2) fail("(setup) an empty-bitmap file wrote flash");
		if (u_save.dirty0 !== 64'd0) fail("(setup) dirty not empty after an empty-bitmap file");
		blob_take(B_L2);
		machine_cold;
		mark;
		do_load(1, 20000);
		if (ld_ok) fail("an incomplete blob was loaded");
		chk_not_served;
		chk_untouched;
		chk_frozen(1'b0, "S1c: an apply was accepted (base_q), the session is not wake-shaped");
		later_save_publishes(8, 8'h74);
		end_scn;

		begin_scn("BF-PEND", "identity mismatch before the boot apply: frozen, then the file lifts it [S1c, S1]");
		reconfigure(CRC_A, 1);
		seeds_clear; seed_of[8] = 8'h81; seed_of[10] = 8'h82;
		build_img(64'h500, TAG_V4, CRC_A);
		apf_deliver;                       // the slots have not settled
		if (boot_hold !== 1'b1) fail("(setup) no boot apply pending");
		blob_take(B_L2);
		image[8421] = CRC_B; image[8423] = ~CRC_B;
		mark;
		do_load(1, WORDS);
		if (ld_ok) fail("a state of another cartridge was accepted");
		chk_not_served;
		if (n_p2wr != c_p2) fail("flash written before the slots settled");
		chk_frozen(1'b1, "S1c: nothing applied yet, the session is wake-shaped");
		mark;
		settle;
		if (n_p2wr - c_p2 != 12288) fail("the delivered file was not applied after the failed load");
		gold_seed(8, 8'h81); gold_seed(10, 8'h82);
		chk_flash("flash is not the delivered save");
		chk_frozen(1'b0, "S1: an accepted boot apply lifts the freeze");
		later_save_publishes(9, 8'h83);
		end_scn;

		begin_scn("BF-HDR", "engine header rejected after an accepted state apply: one load_fail, not frozen [B3, S1c]");
		reconfigure(CRC_A, 1);
		settle;
		blob_take(B_L2);
		image[1] = 32'hE1200000;           // bswap32(8417): the engine's size check fails
		machine_cold;
		mark;
		do_load(0, WORDS);                 // clean bus: word 1 is no longer the lag marker
		if (ld_ok) fail("a blob whose engine header is wrong was reported loaded");
		chk_served(1'b0);
		if (sd_rej !== 1'b0) fail("(setup) the state's image was refused");
		if (n_p2wr - c_p2 != 16384) `FAIL(("(setup) %0d flash writes, want the state's 16384", n_p2wr - c_p2))
		gold_from_bl2;
		chk_flash("flash is not the state's");
		chk_untouched;
		if (bank_vs_image(cbank(0)) != 0) fail("the committed bank is not the accepted state image");
		chk_frozen(1'b0, "S1c: the state apply was accepted, the session is not wake-shaped");
		later_save_publishes(10, 8'h84);
		end_scn;

		// ---- a cartridge reload while the state apply writes flash --------------
		// S8 [rc5]: the request is dropped and state_done_o pulses with
		// apply_reject_o = 1, so the REAL copier is released (never stranded)
		// and the bridge reports the load failed, with one load_fail pulse.
		// cart_replace has just cleared the session (base_q 0, dirty empty),
		// so that pulse lands in a wake-shaped session: S1(c) freezes it.
		begin_scn("RPL-MID", "cart reload mid state apply: copier released, load fails, S1c freezes [S8, B3, S1c]");
		reconfigure(CRC_A, 1);
		settle;
		blob_take(B_L2);
		machine_cold;
		mark;
		fork
			do_load(1, WORDS);
			begin : reload_mid
				integer n;
				n = 0;
				while (n_p2wr - c_p2 < 2000 && n < 6000000) begin @(posedge clk_sys); n = n + 1; end
				if (n_p2wr - c_p2 < 2000) fail("(setup) the state apply never wrote flash");
				if (n_apply - c_apply != 1 || n_sdone != c_sdone)
					fail("(setup) the reload did not land while the state apply was in flight");
				@(posedge clk_sys); cart_ready <= 1'b0; cart_replace <= 1'b1;
				@(posedge clk_sys); cart_replace <= 1'b0;
			end
		join
		if (ld_ok) fail("a load whose apply was dropped by a cartridge reload was reported loaded");
		chk_served(1'b0);
		if (sd_rej !== 1'b1) fail("S8: state_done_o without apply_reject_o for a dropped state apply");
		chk_untouched;
		chk_frozen(1'b1, "S1c: the failed load lands in the reloaded, wake-shaped session");
		// the reload completes: flash is the ROM again, the cartridge ready
		for (i = 0; i < FLASHW; i = i + 1) begin sdram[i] = rom(i); gold[i] = rom(i); end
		@(posedge clk_sys); cart_ready <= 1'b1;
		mark;
		wait_idle(600000);
		if (n_p2wr != c_p2) fail("the boot apply after the reload (nothing delivered) wrote flash");
		chk_flash("flash must be the reloaded ROM");
		chk_frozen(1'b1, "S1: a boot apply with nothing delivered does not clear the freeze");
		later_save_blocked(8, 8'h85);
		end_scn;

		// ---- global ------------------------------------------------------------
		begin_scn("GLOBAL", "protocol monitors");
		if (lfail_wide)       fail("B3: load_fail_o high for more than one cycle");
		if (lfail_x)          fail("load_fail_o X outside reset");
		if (n_lfail != n_lerr)
			`FAIL(("B3: %0d load_fail_o pulses for %0d load_err reports", n_lfail, n_lerr))
		if (n_sdone != n_apply)
			`FAIL(("S8: %0d state_done pulses for %0d state_apply pulses", n_sdone, n_apply))
		if (n_ldone != n_ldreq)
			`FAIL(("C2: %0d copier dones for %0d bridge hand-overs", n_ldone, n_ldreq))
		if (eng_drop)         fail("a staging-port request arrived while the port was busy");
		if (eng_oob)          fail("a staging-port address outside the two banks");
		if (skid_overrun)     fail("a host write into a full skid");
		if (host_clash)       fail("an APF write and a drain write in the same cycle");
		if (p2_oob)           fail("a p2 access outside die 0");
		if (wr_outside_drain) fail("a drain write while draining_o was low");
		if (hold_gap)         fail("a copier staging read without hold_o");
		if (wr_not_ready)     fail("a drain write whose sampled host_ready was low");
		if (!s2_saw_one)      fail("(bench) S2 was never checked with the committed bank at 1");
		end_scn;

		$display("== %0d scenario(s), %0d failed, %0.1f ms simulated", n_scn, n_scn_fail, $realtime / 1.0e6);
		if (errors == 0) $display("== ALL RC5 LOAD-PATH SCENARIOS PASS");
		else             $display("== %0d FAILURE(S)", errors);
		$finish;
	end

	// ---- watchdog ------------------------------------------------------------
	initial begin
		repeat (25) #100_000_000;          // 2.5 s of simulated time
		$display("== WATCHDOG TIMEOUT in %0s", scn);
		$display("== %0d FAILURE(S)", errors + 1);
		$finish;
	end

	wire unused = &{1'b0, p2_be, eng_bus_rst, ram_rden, start_busy, load_busy, host_clash, 1'b0};

endmodule

`default_nettype wire
