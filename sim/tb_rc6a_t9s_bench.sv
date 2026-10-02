// RC6A copy of sim/tb_t9s_bench.sv (the T9 bench) with the rc6 core_top glue:
//   * the engine's host_busy_i is the staging host port alone (rc6 L2; the
//     rc5 glue was host_busy || sc_draining),
//   * the staging host write port goes through core_top's rc6 L3 arbiter
//     (sc_replay / sc_go; no APF save delivery in these sessions, so the APF
//     leg is tied off), and host_wr_ready_o is the arbiter's input,
//   * the bridge's save_busy_i is connected (rc6 diagnostic) -- to the
//     engine's boot_hold_o since the rc6 follow-up (ngpc_machine
//     save_busy_state = overlay_boot_hold),
//   * the engine's host_rd_i (rc6 follow-up, core_top stage_host_rd) is the
//     staging port's host_rd_i, tied 0: no APF flush read in these sessions,
//   * the follow-up's program/erase classifier is checked against the REAL
//     flash_die: this game only erases, so every completion event the
//     engine takes must read as an erase (prog_event low) -- a wake or
//     capture with a program-classified event fails "RC6A FAIL: classifier",
//
//   * files go to +DIR (default sim/tb_rc6a_t9s_out); a wake reads its
//     capture from +CAPDIR (default +DIR), so rc5 captures in sim/tb_t9s_out
//     can be woken on rc6 read-only,
//   * each wake prints an "== RC6A T9S PASS|FAIL" verdict line (see the end of
//     the file); every run ends with "== ALL RC6A T9S SCENARIOS PASS (...)" or
//     "== N FAILURE(S): ..." and $stop, so vvp -N exits 1 on a failure (the
//     driver runs vvp -n and reads the verdict lines).
// Everything else, including the CPU program and every model, is unchanged.
// Run: sim/run_rc6_r1.sh
//
// T9 simulation: Pac-Man (no .sav) slept in its opening credits, woke as a
// cold start. Two kinds of run, one session per vvp run:
//
//   +WAKE=0  CAPTURE run: new core launch, no save delivered, the "game"
//            erases block 10 of its 4 Mbit die at start (the real flash_die
//            behind the real ngp_cart), the background stager publishes, and
//            APF captures a sleep state at a chosen moment. The blob, the
//            PSRAM staging contents and the machine's own view at the
//            capture (T0) are written to sim/tb_t9s_out/<TAG>_*.hex.
//   +WAKE=1  WAKE run: a NEW core launch (fresh FPGA: every initial value,
//            stage_bank 0) with the PSRAM kept from the capture run, no save
//            delivered, the same game erasing block 10 again, and APF's
//            savestate load at a chosen moment. Verdicts, rejects, what the
//            restored CPU reads from flash, and the flash it sees are
//            compared against the capture run's T0 view.
//
// REAL, compiled unmodified (sim/run_t9s.sh):
//   upstream/rtl/Savestates/savestates.sv        the savestate engine
//   target/pocket/ngpc_savestate_bridge.sv       identity, blob store
//   target/pocket/ngpc_state_cart.sv             the copier
//   target/pocket/ngpc_cart_save.sv              the save engine (default
//                                                QUIET_CLOCKS, NGPC_SAVE_DIAG)
//   target/pocket/ngpc_stage_mem.sv + psram.sv   staging (HOST_IDLE 10 ms)
//   upstream/rtl/cart/ngp_cart.sv + flash_die.sv the cartridge and its dies,
//                                                with their savestate slice
//                                                (internals 96..103) and
//                                                pause drain
//   upstream/rtl/cart/ngp_cart_overlay_geometry.sv, sim/sim_synch3.v
//
// GLUE reproduced from ngpc_machine.sv / ngp_mainboard.sv / core_top.v:
//   machine reset = hard reset | cart download | boot_hold (overlay)
//   ngp_cart reset = machine reset | restore_reset (engine reset_ss)
//   cart_config_load = loader config | re-strap after reset / eng reset_ss
//   pause: pause_req = eng sleep_savestate | copier hold_o;
//          cart_pause_req = pause_req && soc_ready;
//          machine_ready = loading_savestate || (pause_req && soc_ready && cart_ready)
//          engine `paused` = pause_req && machine_ready
//   internals bus: 96..103 -> ngp_cart, 0/1 -> the CPU model, rest a pattern
//   staging: host_busy || sc_draining into the engine; copier borrows the
//            engine port while sc_rd_active; drain -> spare bank
//   slots_settled: core_top's counter, SHORTENED (SETTLE74 = ~2 ms)
//
// MODELED: the CPU (a bus master issuing 32-clk cart cycles on 8-clk ticks,
// honouring the pause only at instruction boundaries, with its registers in
// internals words 0/1), running a Pac-Man-shaped program:
//   power-up ID read (AA/55/90, read 98/AB, F0), a BIOS phase of ROM reads,
//   the game's start, a read of block 10, the AMD erase of block 10
//   (AA 5555, 55 2AAA, 80 5555, AA 5555, 55 2AAA, 30 7C000), status polling
//   (+POLL: 0 DQ7 data polling with DQ5 check, 1 DQ6 toggle, 2 an immediate
//   read-back that expects busy status and then DQ7 polling), a 256-sample
//   verify that block 10 is erased, optionally a second erase, then
//   "credits/gameplay" ROM reads with a periodic block-10 read.
//   The cart backing store (a behavioral dual-port array: die port with
//   3..8 clk latency, save-engine p2 port 2..10 clk), the CellularRAM chip,
//   and APF (bridge bus, lag-1 blob writes, 0xA0/0xA4 handshakes).
//   K2GE/sound re-park is a fixed +PARK clocks before the SoC reports ready.
//
// Run: wsl -e sh sim/run_t9s.sh

`timescale 1ns / 1ps
`default_nettype none

module tb_rc6a_t9s;

	reg clk_sys = 0;
	reg clk_74a = 0;
	always #10.173 clk_sys = ~clk_sys;   // 49.152 MHz
	always #6.734  clk_74a = ~clk_74a;   // 74.25 MHz

	integer cyc = 0;
	always @(posedge clk_sys) cyc = cyc + 1;

	reg reset_in = 1;

	// ---- plusargs ----------------------------------------------------------
	integer P_WAKE     = 0;
	reg [8*64-1:0] P_TAG = "t9s_default";
	integer P_CAPREF   = 1;     // 0 first unlock write of erase P_CAPERASE,
	                            // 1 die busy rise, 2 die busy fall (event),
	                            // 3 pass start, 4 publish, 5 absolute from boot release,
	                            // 6 first poll read commit
	integer P_CAPCYC   = 0;     // clk_sys after the reference
	integer P_CAPERASE = 1;
	integer P_LOADREF  = 0;     // 0 from the last slot write, 1 wake busy rise,
	                            // 2 wake busy fall, 3 wake pass start, 4 wake publish,
	                            // 5 from boot release
	integer P_LOADCYC  = 25000;
	integer P_POLL     = 0;
	integer P_ROMFF    = 1;     // block 10 ROM content: 1 erased, 0 a pattern
	integer P_ERASES   = 1;     // block-10 erases the game makes
	integer P_BIOSUS   = 3000;  // BIOS phase (boot animation), us
	integer P_SNKUS    = 1000;  // game start -> erase, us
	integer P_GAPUS    = 3000;  // erase 1 -> erase 2, us
	integer P_POSTUS   = 30000; // run after the capture / after the restore, us
	integer P_PARK     = 200;   // SoC re-park clocks
	integer P_IDREAD   = 1;
	integer P_WERASE   = 1;     // wake session: 0 = the game never gets to erase
	integer P_SEED     = 1;
	integer P_VERBOSE  = 0;
	// the capture session's own self-check code after T0 (its post_fail), given
	// by the driver: a game whose program fails a check by itself (POLL=2 does)
	// ends with that code whether or not a state was loaded
	integer P_CAPFAIL  = 0;
	reg [8*160-1:0] P_DIR    = "sim/tb_rc6a_t9s_out";
	reg [8*160-1:0] P_CAPDIR = "";

	localparam integer SETTLE74 = 150000;   // ~2 ms (core_top: 37,125,000)

	// ---- geometry ----------------------------------------------------------
	localparam integer N_INT    = 112;
	localparam integer SZ0      = 12288;
	localparam integer SZ1      = 4096;
	localparam integer SZ2      = 16384;
	localparam integer CARTB    = 8424;
	localparam integer CARTW    = 16256;
	localparam integer WORDS    = CARTB + CARTW;
	localparam [31:0]  BLOBBASE = 32'h40000000;
	localparam integer SLOTW    = 32512;
	localparam integer BANKW    = 32768;
	localparam integer GAP      = 4;
	localparam integer LOAD_MAX74 = 12000000;
	localparam integer SAVE_MAX74 = 12000000;
	localparam [31:0]  CART_CRC   = 32'h21E8CC15;
	localparam [31:0]  CF_CRC     = 32'h94B63A97;   // Card Fighters (the previous session)
	localparam [24:0]  CART_BYTES = 25'h0080000;
	localparam [95:0]  CART_TITLE = 96'h202020202020_4E414D434150;  // "PACMAN      "
	localparam [15:0]  CART_CAT   = 16'h0031;
	localparam [7:0]   CART_SUB   = 8'h00;
	localparam [20:0]  B10        = 21'h07C000;     // block 10, 16 KB, die 0
	localparam integer B10W       = 21'h07C000 >> 1;

	// =========================================================================
	// The cartridge backing store (512 KB die 0) and the ROM image
	// =========================================================================
	reg [15:0] flash [0:262143];

	function [15:0] rom_word(input integer w);
		reg [17:0] a;
		begin
			a = w;
			if (a >= B10W && P_ROMFF) rom_word = 16'hFFFF;
			else rom_word = {a[7:0] ^ 8'hA5 ^ a[17:10], a[15:8] ^ a[7:0] ^ 8'h3C};
		end
	endfunction
	function [7:0] rom_byte(input [20:0] a);
		reg [15:0] w;
		begin
			w = rom_word(a[18:1]);
			rom_byte = a[0] ? w[15:8] : w[7:0];
		end
	endfunction

	// =========================================================================
	// Machine glue
	// =========================================================================
	reg  cart_download = 0;     // held across the cartridge transfer
	reg  cart_replace  = 0;     // cart_download_start
	reg  cart_ready    = 0;
	reg  loader_config = 0;

	wire overlay_boot_hold;
	wire m_reset = reset_in | cart_download | (overlay_boot_hold === 1'b1);

	wire eng_reset_ss;
	wire restore_reset = (eng_reset_ss === 1'b1);

	reg [3:0] cart_reconfig_q = 0;
	always @(posedge clk_sys) begin
		if (m_reset || restore_reset) cart_reconfig_q <= 4'd8;
		else if (cart_reconfig_q != 4'd0) cart_reconfig_q <= cart_reconfig_q - 4'd1;
	end
	wire cart_config_load = loader_config || (!m_reset && (cart_reconfig_q != 4'd0));

	// =========================================================================
	// Savestate engine and the internals bus
	// =========================================================================
	reg [63:0] internals [0:N_INT];
	reg  [7:0] mem0 [0:SZ0-1];
	reg  [7:0] mem1 [0:SZ1-1];
	reg  [7:0] mem2 [0:SZ2-1];

	wire [63:0] eng_bus_din;
	wire  [9:0] eng_bus_adr;
	wire        eng_bus_wren;
	wire        eng_bus_rst;
	wire [63:0] cart_ss_dout;
	wire [63:0] cpu_w0, cpu_w1;
	wire [63:0] eng_bus_dout = (eng_bus_adr >= 10'd96 && eng_bus_adr < 10'd104) ? cart_ss_dout :
	                           (eng_bus_adr == 10'd0) ? cpu_w0 :
	                           (eng_bus_adr == 10'd1) ? cpu_w1 : internals[eng_bus_adr];

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
		if (eng_bus_wren && !(eng_bus_adr >= 10'd96 && eng_bus_adr < 10'd104) &&
		    eng_bus_adr > 10'd1) internals[eng_bus_adr] <= eng_bus_din;
	end

	wire       eng_pause_req;
	wire       mc_capture_hold;
	wire       ss_save, ss_load, ss_busy, ss_loading, ss_saving;
	wire [63:0] bus_out_Din, bus_out_Dout;
	wire [25:0] bus_out_Adr;
	wire        bus_out_rnw, bus_out_ena, bus_out_done;
	wire  [7:0] bus_out_be;

	// ---- the pause tree ------------------------------------------------------
	wire pause_req_m = (eng_pause_req === 1'b1) || (mc_capture_hold === 1'b1);
	reg  [15:0] park_cnt = 0;
	always @(posedge clk_sys) begin
		if (!pause_req_m) park_cnt <= 16'd0;
		else if (park_cnt != 16'hFFFF) park_cnt <= park_cnt + 16'd1;
	end
	wire cpu_busy_w;
	wire soc_pause_ready = pause_req_m && !cpu_busy_w && (park_cnt >= P_PARK);
	wire cart_pause_req  = pause_req_m && soc_pause_ready;
	wire cart_pause_ready;
	wire machine_pause_ready = (ss_loading === 1'b1) ||
	                           (pause_req_m && soc_pause_ready && (cart_pause_ready === 1'b1));
	wire paused = pause_req_m && machine_pause_ready;

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
		.reset_ss                (eng_reset_ss),
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
		.saving_savestate        (ss_saving),
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
	// The cartridge: REAL ngp_cart and its two flash_die instances
	// =========================================================================
	reg  [20:0] cpu_a = 0;
	reg   [7:0] cpu_d = 0;
	reg         cpu_nce = 1, cpu_noe = 1, cpu_nwe = 1;
	wire  [7:0] cart_d_out;
	wire        cart_d_oe, cart_rd_ready;

	wire        cart_mem_req;
	wire        cart_mem_we;
	wire [24:0] cart_mem_addr;
	wire [15:0] cart_mem_wdata;
	wire  [1:0] cart_mem_be;
	wire        cart_mem_lane, cart_mem_tag, cart_mem_flash;
	reg  [15:0] cart_mem_rdata = 0;
	reg         cart_mem_rvalid = 0, cart_mem_done = 0;

	wire        cart_dirty0_event, cart_dirty1_event;
	wire  [5:0] cart_dirty0_block, cart_dirty1_block;
	wire  [1:0] cart_die_busy;
	wire  [1:0] cart_size_code0, cart_size_code1;

	ngp_cart cart (
		.clk              (clk_sys),
		.ce               (1'b1),
		.reset            (m_reset | restore_reset),
		.image_bytes      (CART_BYTES),
		.config_load      (cart_config_load),
		.force_8m_die0    (1'b0),
		.force_flash_read (1'b0),
		.size_code0       (cart_size_code0),
		.size_code1       (cart_size_code1),
		.cart_bytes       (),
		.cart_present     (),
		.A                (cpu_a),
		.d_in             (cpu_d),
		.nCE0             (cpu_nce),
		.nCE1             (1'b1),
		.nOE              (cpu_noe),
		.nWE              (cpu_nwe),
		.d_out            (cart_d_out),
		.d_oe             (cart_d_oe),
		.rd_ready         (cart_rd_ready),
		.mem_req          (cart_mem_req),
		.mem_we           (cart_mem_we),
		.mem_addr         (cart_mem_addr),
		.mem_wdata        (cart_mem_wdata),
		.mem_be           (cart_mem_be),
		.mem_lane         (cart_mem_lane),
		.mem_tag          (cart_mem_tag),
		.mem_flash        (cart_mem_flash),
		.mem_rdata        (cart_mem_rdata),
		.mem_rvalid       (cart_mem_rvalid),
		.mem_done         (cart_mem_done),
		.dirty_pulse      (),
		.dirty0           (),
		.dirty1           (),
		.dirty0_event     (cart_dirty0_event),
		.dirty0_block     (cart_dirty0_block),
		.dirty1_event     (cart_dirty1_event),
		.dirty1_block     (cart_dirty1_block),
		.dirty_clear      (1'b0),
		.flash_busy       (),
		.die_busy         (cart_die_busy),
		.ss_bus_adr       (eng_bus_adr),
		.ss_bus_din       (eng_bus_din),
		.ss_bus_wren      (eng_bus_wren),
		.ss_bus_rst       (eng_bus_rst),
		.ss_bus_dout      (cart_ss_dout),
		.ss_restore_is_rewind(1'b0),
		.pause_req        (cart_pause_req),
		.pause_ready      (cart_pause_ready)
	);

	// die port of the backing store: held request, one transaction per req
	reg        m_busy = 0, m_served = 0;
	reg  [3:0] m_cnt = 0;
	always @(posedge clk_sys) begin
		cart_mem_done   <= 1'b0;
		cart_mem_rvalid <= 1'b0;
		if (cart_mem_req !== 1'b1) m_served <= 1'b0;
		if (cart_mem_req === 1'b1 && !m_busy && !m_served) begin
			m_busy <= 1'b1;
			m_cnt  <= 3 + ($urandom % 6);
		end else if (m_busy) begin
			if (m_cnt == 4'd0) begin
				m_busy   <= 1'b0;
				m_served <= 1'b1;
				cart_mem_done <= 1'b1;
				if (cart_mem_we) begin
					if (cart_mem_be[0]) flash[cart_mem_addr[18:1]][7:0]  = cart_mem_wdata[7:0];
					if (cart_mem_be[1]) flash[cart_mem_addr[18:1]][15:8] = cart_mem_wdata[15:8];
				end else begin
					cart_mem_rdata  <= flash[cart_mem_addr[18:1]];
					cart_mem_rvalid <= 1'b1;
				end
			end else m_cnt <= m_cnt - 4'd1;
		end
	end

	// =========================================================================
	// APF bridge, the copier, the staging region and the save engine
	// =========================================================================
	reg         bridge_wr = 0, bridge_rd = 0;
	reg  [31:0] bridge_addr = 32'hF8000000;
	reg  [31:0] bridge_wr_data = 0;
	wire [31:0] savestate_rd_data;

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
		.save_busy_i     (overlay_boot_hold),   // core_top: mc_save_busy = save_busy_state = overlay_boot_hold (rc6 follow-up)
		.cart_img_rd_addr(cs_img_rd_addr),
		.cart_img_rd_data(cs_img_rd_data),
		.bus_out_Din(bus_out_Din), .bus_out_Dout(bus_out_Dout),
		.bus_out_Adr(bus_out_Adr), .bus_out_rnw(bus_out_rnw),
		.bus_out_ena(bus_out_ena), .bus_out_be(bus_out_be),
		.bus_out_done(bus_out_done)
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

	// staging glue (no APF save delivery and no flush in these sessions)
	wire        sc_host_wr;
	wire [24:0] sc_host_addr;
	wire [15:0] sc_host_data;
	wire        mc_stage_current, mc_save_busy, mc_stage_bank;
	// core_top.v rc6 L3 write-port arbiter, reproduced. APF delivers no save
	// slot in these sessions, so its leg (bios_wr_raw && ld_is_save) is 0.
	wire        apf_save_wr = 1'b0;
	reg         sc_replay   = 1'b0;
	wire        sc_beat     = sc_host_wr || sc_replay;
	wire        sc_go       = sc_beat && !apf_save_wr;
	always @(posedge clk_sys) sc_replay <= !reset_in && sc_beat && apf_save_wr;
	wire        stage_host_wr      = apf_save_wr || sc_beat;
	wire [24:0] stage_host_wr_addr = sc_go ? sc_host_addr : 25'd0;
	wire [15:0] stage_host_wr_data = sc_go ? sc_host_data : 16'd0;
	wire        stage_wr_bank      = sc_go ? ~mc_stage_bank : mc_stage_bank;
	wire        stage_host_ready;

	wire        stage_req, stage_we;
	wire [24:0] stage_addr;
	wire [15:0] stage_wdata;
	wire        stage_ready, stage_done;
	wire [15:0] stage_rdata;
	wire        host_busy;
	wire [15:0] stage_diag_beats, stage_diag_drops;
	wire        sc_rd_req, sc_rd_active, sc_draining;
	wire [24:0] sc_rd_addr;
	wire        sc_host_ready = stage_host_ready && !sc_replay && !(sc_host_wr && apf_save_wr);

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
		.host_wr_addr_i(stage_host_wr_addr),
		.host_wr_data_i(stage_host_wr_data),
		.host_rd_i     (1'b0),
		.host_rd_addr_i(25'd0),
		.host_rd_data_o(),
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

	// behavioral CellularRAM (async mode) at the pins, as tb_t7r_bench
	reg [15:0] cmem [0:65535];
	reg [21:0] c_addr_l = 0;
	reg        p_we = 1, p_ce = 1, p_ub = 1, p_lb = 1;
	reg [15:0] p_dq = 0;
	reg [21:0] p_addr = 0;
	always @(posedge clk_sys) begin
		p_we <= cram0_we_n; p_ce <= cram0_ce0_n;
		p_ub <= cram0_ub_n; p_lb <= cram0_lb_n;
		p_dq <= cram0_dq;   p_addr <= c_addr_l;
		if (!cram0_ce0_n && !cram0_adv_n) c_addr_l <= {cram0_a, cram0_dq};
		if (cram0_we_n && !p_we && !p_ce) begin
			if (!p_ub) cmem[p_addr[15:0]][15:8] <= p_dq[15:8];
			if (!p_lb) cmem[p_addr[15:0]][7:0]  <= p_dq[7:0];
		end
	end
	assign cram0_dq = (!cram0_ce0_n && !cram0_oe_n && cram0_we_n) ? cmem[c_addr_l[15:0]] : 16'hZZZZ;

	wire        mc_apply_reject, mc_state_done, mc_state_apply;
	wire        save_present;
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
		.size_code0_i    (2'd1),
		.size_code1_i    (2'd0),
		.event0_i        (cart_dirty0_event),
		.block0_i        (cart_dirty0_block),
		.event1_i        (cart_dirty1_event),
		.block1_i        (cart_dirty1_block),
		.die_busy_i      (cart_die_busy),
		.host_busy_i     (host_busy),
		.host_rd_i       (1'b0),          // core_top stage_host_rd: no APF flush read here (rc6 follow-up)
		.state_apply_i   (mc_state_apply),
		.draining_i      (sc_draining),
		.state_frozen_i  (ss_load_frozen),
		.state_fail_i    (ss_load_fail),
		.frozen_o        (mc_frozen),
		.save_slot_wr_i  (1'b0),
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
		.busy_o          (mc_save_busy),
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

	// the save engine's p2 port on the same backing store
	reg  [3:0] p2_cnt = 0;
	reg        p2_we_q = 0;
	reg [17:0] p2_a_q = 0;
	reg [15:0] p2_wd_q = 0;
	integer    n_p2wr = 0;
	always @(posedge clk_sys) begin
		p2_done <= 1'b0;
		if (p2_req === 1'b1 && !p2_busy) begin
			p2_busy <= 1'b1;
			p2_we_q <= p2_we;
			p2_a_q  <= p2_addr[18:1];
			p2_wd_q <= p2_wdata;
			p2_cnt  <= 2 + ($urandom % 9);
			if (p2_we) n_p2wr = n_p2wr + 1;
		end else if (p2_busy) begin
			if (p2_cnt == 4'd0) begin
				p2_busy <= 1'b0;
				p2_done <= 1'b1;
				if (p2_we_q) flash[p2_a_q] = p2_wd_q;
				else         p2_rdata <= flash[p2_a_q];
			end else p2_cnt <= p2_cnt - 4'd1;
		end
	end

	// =========================================================================
	// The CPU model
	// =========================================================================
	localparam [15:0] PC_INIT = 0,  PC_BIOS = 1,  PC_SNK = 2,  PC_CHK = 3,
	                  PC_E1   = 4,  PC_E2   = 5,  PC_E3  = 6,  PC_E4  = 7,
	                  PC_E5   = 8,  PC_E6   = 9,  PC_POLL = 10, PC_POLL2 = 11,
	                  PC_VFY  = 12, PC_GAP  = 13, PC_PLAY = 14, PC_ERR  = 15,
	                  PC_ID1  = 20, PC_ID2  = 21, PC_ID3  = 22, PC_IDR0 = 23,
	                  PC_IDR1 = 24, PC_IDX  = 25;
	localparam integer POLL_LIMIT = 100000;

	// architectural registers: internals word 0 = {pc, acc, prev, fail, nerase, seq},
	// word 1 = {cnt, vcnt}
	reg [15:0] pc = 0;
	reg  [7:0] acc = 0, prev = 0, fail = 0, nerase = 0;
	reg [15:0] seq = 0;
	reg [31:0] cnt = 0, vcnt = 0;
	assign cpu_w0 = {pc, acc, prev, fail, nerase, seq};
	assign cpu_w1 = {cnt, vcnt};

	reg        cpu_busy = 0;
	reg  [5:0] ic = 0;
	reg        i_bus = 0, i_we = 0;
	reg [20:0] i_a = 0;
	reg  [7:0] i_d = 0, i_v = 0;
	reg  [2:0] tph = 0;
	wire       tick = (tph == 3'd0);
	always @(posedge clk_sys) tph <= tph + 3'd1;
	assign cpu_busy_w = cpu_busy;

	wire cpu_hold = pause_req_m || (ss_loading === 1'b1);

	integer N_BIOS, N_SNK, N_GAP;   // instructions (one per 32..40 clk)

	function [20:0] rom_addr(input [15:0] s);
		reg [31:0] x;
		begin
			x = s * 32'd40503;
			rom_addr = {3'd0, x[17:0]} % 21'h070000;
		end
	endfunction

	// the instruction the program issues next
	reg        op_bus, op_we;
	reg [20:0] op_a;
	reg  [7:0] op_d;
	always @* begin
		op_bus = 1'b1; op_we = 1'b0; op_a = 21'd0; op_d = 8'd0;
		case (pc)
			PC_INIT, PC_ERR: op_bus = 1'b0;
			PC_ID1:  begin op_we = 1'b1; op_a = 21'h005555; op_d = 8'hAA; end
			PC_ID2:  begin op_we = 1'b1; op_a = 21'h002AAA; op_d = 8'h55; end
			PC_ID3:  begin op_we = 1'b1; op_a = 21'h005555; op_d = 8'h90; end
			PC_IDR0: op_a = B10;
			PC_IDR1: op_a = B10 + 21'd1;
			PC_IDX:  begin op_we = 1'b1; op_a = B10; op_d = 8'hF0; end
			PC_BIOS, PC_SNK, PC_GAP: op_a = rom_addr(seq);
			PC_PLAY: op_a = (seq[5:0] == 6'd0) ? (B10 + {7'd0, seq[13:6], 6'd0}) : rom_addr(seq);
			PC_CHK, PC_POLL, PC_POLL2: op_a = B10;
			PC_E1:   begin op_we = 1'b1; op_a = 21'h005555; op_d = 8'hAA; end
			PC_E2:   begin op_we = 1'b1; op_a = 21'h002AAA; op_d = 8'h55; end
			PC_E3:   begin op_we = 1'b1; op_a = 21'h005555; op_d = 8'h80; end
			PC_E4:   begin op_we = 1'b1; op_a = 21'h005555; op_d = 8'hAA; end
			PC_E5:   begin op_we = 1'b1; op_a = 21'h002AAA; op_d = 8'h55; end
			PC_E6:   begin op_we = 1'b1; op_a = B10;         op_d = 8'h30; end
			PC_VFY:  op_a = (vcnt == 32'd255) ? 21'h07FFFF : (B10 + {5'd0, vcnt[7:0], 6'd0});
			default: op_bus = 1'b0;
		endcase
	end

	// commit strobe for the monitors
	reg        c_stb = 0, c_we = 0, c_bus = 0;
	reg [15:0] c_pc = 0;
	reg [20:0] c_a = 0;
	reg  [7:0] c_v = 0;
	reg  [3:0] c_die = 0;
	reg        i_start = 0;    // an instruction started this cycle
	reg [15:0] i_start_pc = 0;

	always @(posedge clk_sys) begin
		c_stb   <= 1'b0;
		i_start <= 1'b0;
		if (m_reset || restore_reset) begin
			pc <= PC_INIT; acc <= 0; prev <= 0; fail <= 0; nerase <= 0; seq <= 0;
			cnt <= 0; vcnt <= 0;
			cpu_busy <= 1'b0; ic <= 0;
			cpu_nce <= 1'b1; cpu_noe <= 1'b1; cpu_nwe <= 1'b1;
		end else if (eng_bus_wren === 1'b1 && eng_bus_adr == 10'd0) begin
			{pc, acc, prev, fail, nerase, seq} <= eng_bus_din;
		end else if (eng_bus_wren === 1'b1 && eng_bus_adr == 10'd1) begin
			{cnt, vcnt} <= eng_bus_din;
		end else if (!cpu_busy) begin
			if (tick && !cpu_hold) begin
				cpu_busy <= 1'b1; ic <= 6'd0;
				i_bus <= op_bus; i_we <= op_we; i_a <= op_a; i_d <= op_d;
				cpu_a <= op_a; cpu_d <= op_d;
				i_start <= 1'b1; i_start_pc <= pc;
			end
		end else begin
			if (ic != 6'd63) ic <= ic + 6'd1;
			if (i_bus) begin
				if (ic == 6'd5) begin
					cpu_nce <= 1'b0;
					if (i_we) cpu_nwe <= 1'b0; else cpu_noe <= 1'b0;
				end
				if (i_we && ic == 6'd29) begin cpu_nwe <= 1'b1; cpu_nce <= 1'b1; end
				if (!i_we && ic >= 6'd29 && !cpu_noe && cart_rd_ready === 1'b1) begin
					i_v <= cart_d_out; cpu_noe <= 1'b1; cpu_nce <= 1'b1;
					c_die <= cart.die0.state;
				end
			end
			if (tick && ic >= 6'd31 && cpu_nce && cpu_noe && cpu_nwe) begin
				cpu_busy <= 1'b0;
				c_stb <= 1'b1; c_pc <= pc; c_a <= i_a; c_v <= i_v; c_we <= i_we; c_bus <= i_bus;
				case (pc)
					PC_INIT: begin cnt <= N_BIOS; pc <= P_IDREAD ? PC_ID1 : PC_BIOS; end
					PC_ID1:  pc <= PC_ID2;
					PC_ID2:  pc <= PC_ID3;
					PC_ID3:  pc <= PC_IDR0;
					PC_IDR0: begin if (i_v != 8'h98 && fail == 0) fail <= 8'h05; pc <= PC_IDR1; end
					PC_IDR1: begin if (i_v != 8'hAB && fail == 0) fail <= 8'h06; pc <= PC_IDX; end
					PC_IDX:  pc <= PC_BIOS;
					PC_BIOS, PC_SNK, PC_GAP: begin
						if (i_v != rom_byte(i_a) && fail == 0) fail <= 8'h10;
						seq <= seq + 16'd1;
						if (cnt <= 32'd1) begin
							if (pc == PC_BIOS) begin cnt <= N_SNK; pc <= PC_SNK; end
							else pc <= PC_CHK;
						end else cnt <= cnt - 32'd1;
					end
					PC_CHK:  begin acc <= i_v; pc <= PC_E1; end
					PC_E1, PC_E2, PC_E3, PC_E4, PC_E5: pc <= pc + 16'd1;
					PC_E6:   begin pc <= PC_POLL; cnt <= 32'd0; prev <= 8'h00; end
					PC_POLL: begin
						acc <= i_v; cnt <= cnt + 32'd1; prev <= i_v;
						if (P_POLL == 2 && cnt == 32'd0 && i_v[7] && fail == 0)
							fail <= 8'h08;   // the immediate read-back found no busy status
						if (P_POLL == 1) begin
							if (cnt != 32'd0 && i_v[6] == prev[6]) begin pc <= PC_VFY; vcnt <= 32'd0; end
							else if (cnt != 32'd0 && i_v[5]) pc <= PC_POLL2;
							else if (cnt > POLL_LIMIT) begin if (fail == 0) fail <= 8'h21; pc <= PC_ERR; end
						end else begin
							if (i_v[7]) begin pc <= PC_VFY; vcnt <= 32'd0; end
							else if (i_v[5]) pc <= PC_POLL2;
							else if (cnt > POLL_LIMIT) begin if (fail == 0) fail <= 8'h21; pc <= PC_ERR; end
						end
					end
					PC_POLL2: begin
						prev <= i_v;
						if ((P_POLL == 1) ? (i_v[6] == prev[6]) : i_v[7]) begin pc <= PC_VFY; vcnt <= 32'd0; end
						else begin if (fail == 0) fail <= 8'h22; pc <= PC_ERR; end
					end
					PC_VFY: begin
						if (i_v != 8'hFF && fail == 0) fail <= 8'h30;
						if (vcnt == 32'd255) begin
							nerase <= nerase + 8'd1;
							if (nerase + 8'd1 < P_ERASES) begin cnt <= N_GAP; pc <= PC_GAP; end
							else pc <= PC_PLAY;
						end else vcnt <= vcnt + 32'd1;
					end
					PC_PLAY: begin
						if (seq[5:0] == 6'd0) begin
							if (i_v != 8'hFF && fail == 0) fail <= 8'h40;
						end else if (i_v != rom_byte(i_a) && fail == 0) fail <= 8'h11;
						seq <= seq + 16'd1;
					end
					default: ;
				endcase
			end
		end
	end

	// =========================================================================
	// Monitors
	// =========================================================================
	integer t_boot_rel = -1;       // machine reset released after the boot apply
	integer t_busy_rise [1:2];
	integer t_busy_fall [1:2];
	integer t_e1 [1:2];
	integer t_first_poll = -1;
	integer t_pass_start = -1, t_publish = -1;
	integer n_erase_started = 0, n_busy_rise = 0, n_busy_fall = 0, n_abort = 0;
	integer n_pass = 0, n_pub = 0;
	reg     busy_q = 0, bank_q = 0, mres_q = 1;
	reg [4:0] est_q = 0;
	wire [4:0] est = cart_save.state;

	always @(posedge clk_sys) begin
		if (!reset_in) begin
			// the boot apply's release: boot_hold falls (the download's end
			// leaves a 1-2 clk reset gap before boot_hold rises; not that)
			if (overlay_boot_hold !== 1'b1 && mres_q && t_boot_rel < 0 && cart_ready) t_boot_rel = cyc;
			mres_q = (overlay_boot_hold === 1'b1);
			if (cart_die_busy[0] === 1'b1 && !busy_q) begin
				n_busy_rise = n_busy_rise + 1;
				if (n_busy_rise <= 2) t_busy_rise[n_busy_rise] = cyc;
				if (P_VERBOSE) $display("   [%0d] die0 busy rises (die state %0d)", cyc, cart.die0.state);
			end
			if (cart_die_busy[0] !== 1'b1 && busy_q && (m_reset || restore_reset)) begin
				n_abort = n_abort + 1;   // cut off by a reset: no completion event
				if (P_VERBOSE) $display("   [%0d] die0 erase ABORTED by the machine reset (boot_hold %b, restore_reset %b)",
				                        cyc, overlay_boot_hold, restore_reset);
			end
			if (cart_die_busy[0] !== 1'b1 && busy_q) begin
				n_busy_fall = n_busy_fall + 1;
				if (n_busy_fall <= 2) t_busy_fall[n_busy_fall] = cyc;
				if (P_VERBOSE) $display("   [%0d] die0 busy falls", cyc);
			end
			busy_q = (cart_die_busy[0] === 1'b1);
			if (i_start === 1'b1 && i_start_pc == PC_E1) begin
				n_erase_started = n_erase_started + 1;
				if (n_erase_started <= 2) t_e1[n_erase_started] = cyc;
			end
			if (c_stb === 1'b1 && c_pc == PC_POLL && t_first_poll < 0) t_first_poll = cyc;
			if (est_q == 5'd0 && est == 5'd1) begin
				n_pass = n_pass + 1;
				if (t_pass_start < 0) t_pass_start = cyc;
				if (P_VERBOSE) $display("   [%0d] pass starts", cyc);
			end
			est_q = est;
			if ((mc_stage_bank ^ bank_q) === 1'b1) begin
				n_pub = n_pub + 1;
				if (t_publish < 0) t_publish = cyc;
				if (P_VERBOSE) $display("   [%0d] committed bank -> %0d", cyc, mc_stage_bank);
			end
			bank_q = mc_stage_bank;
		end
	end

	// ---- capture instrumentation (capture run) ----
	reg        t0_taken = 0;
	integer    t_t0 = -1;
	reg [63:0] t0_w0, t0_w1, t0_die0a, t0_die0b;
	reg [15:0] t0_b10 [0:8191];
	integer    t0_flash_sum = 0;
	reg        t0_busy = 0;
	integer    gap_instr = 0;
	reg [15:0] gap_pc = 16'hFFFF;
	reg        in_gap = 0;
	integer    t_eng_end = -1, t_hold_up = -1;
	reg        cap_copy_seen = 0;
	reg        cap_copy_busy = 0, cap_copy_pend = 0;
	integer    t_cap_copy = -1;
	reg        sv_q = 0, hold_q = 0;
	integer    k0;

	always @(posedge clk_sys) begin
		if (!reset_in) begin
			if (ss_saving === 1'b1 && !t0_taken) begin
				t0_taken = 1; t_t0 = cyc;
				t0_w0 = cpu_w0; t0_w1 = cpu_w1;
				t0_die0a = cart.die0.ss_word0; t0_die0b = cart.die0.ss_word1;
				t0_busy = (cart_die_busy[0] === 1'b1);
				for (k0 = 0; k0 < 8192; k0 = k0 + 1) t0_b10[k0] = flash[B10W + k0];
			end
			// the gap between the engine's release and the copier's hold
			if (sv_q && eng_pause_req !== 1'b1 && t0_taken && t_eng_end < 0) begin
				t_eng_end = cyc; in_gap = 1;
			end
			sv_q = (eng_pause_req === 1'b1);
			if (in_gap && i_start === 1'b1) begin
				gap_instr = gap_instr + 1; gap_pc = i_start_pc;
			end
			if (in_gap && mc_capture_hold === 1'b1 && !hold_q) begin
				in_gap = 0; t_hold_up = cyc;
			end
			hold_q = (mc_capture_hold === 1'b1);
			if (!cap_copy_seen && sc_rd_active === 1'b1) begin
				cap_copy_seen = 1; t_cap_copy = cyc;
				cap_copy_busy = (cart_die_busy[0] === 1'b1);
				cap_copy_pend = cart_save.stage_pending;
			end
		end
	end

	// ---- read log: from T0 (capture run) / from the end of the restore (wake run)
	// entry = {15'd0, we, pc[14:0], die state at the read [3:0] (F for a write), a[20:0], v[7:0]}
	reg        log_on = 0;
	integer    n_log = 0;
	reg [63:0] rlog [0:63];
	always @(posedge clk_sys) begin
		if (log_on && c_stb === 1'b1 && c_bus && n_log < 64) begin
			rlog[n_log] = {15'd0, c_we, c_pc[14:0], c_we ? 4'hF : c_die, c_a, c_we ? 8'h00 : c_v};
			n_log = n_log + 1;
		end
	end
	function [15:0] le_pc(input [63:0] e);  le_pc  = {1'b0, e[47:33]}; endfunction
	function [3:0]  le_die(input [63:0] e); le_die = e[32:29];          endfunction
	function [20:0] le_a(input [63:0] e);   le_a   = e[28:8];           endfunction
	function [7:0]  le_v(input [63:0] e);   le_v   = e[7:0];            endfunction
	function        le_we(input [63:0] e);  le_we  = e[48];             endfunction

	// =========================================================================
	// APF tasks
	// =========================================================================
	reg [31:0] image [0:WORDS-1];
	reg sv_ok = 0, sv_done = 0;
	task apf_save;
		integer k, n;
		begin
			sv_ok = 0; sv_done = 0;
			@(posedge clk_74a); ss_start_req <= 1;
			n = 0;
			while (start_ack !== 1'b1 && n < 10000) begin @(posedge clk_74a); n = n + 1; end
			@(posedge clk_74a); ss_start_req <= 0;
			n = 0;
			while (start_ok !== 1'b1 && start_err !== 1'b1 && n < SAVE_MAX74) begin @(posedge clk_74a); n = n + 1; end
			sv_done = (start_ok === 1'b1 || start_err === 1'b1);
			sv_ok   = (start_ok === 1'b1);
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
	integer t_ld_cmd = -1, t_ld_end = -1;
	task apf_load;
		integer n;
		begin
			ld_ok = 0; ld_done = 0;
			@(posedge clk_74a); ss_load_req <= 1;
			t_ld_cmd = cyc;
			n = 0;
			while (load_ack !== 1'b1 && n < 10000) begin @(posedge clk_74a); n = n + 1; end
			@(posedge clk_74a); ss_load_req <= 0;
			n = 0;
			while (load_ok !== 1'b1 && load_err !== 1'b1 && n < LOAD_MAX74) begin @(posedge clk_74a); n = n + 1; end
			ld_done = (load_ok === 1'b1 || load_err === 1'b1);
			ld_ok   = (load_ok === 1'b1);
			t_ld_end = cyc;
			repeat (8) @(posedge clk_74a);
		end
	endtask

	// APF delivers the data slots (BIOS, cartridge): nibble-1 strobes; the
	// machine is held in reset for the cartridge transfer.
	integer t_last_slot = -1;
	task apf_slots;
		integer k;
		begin
			@(posedge clk_sys); cart_download <= 1; cart_replace <= 1;
			@(posedge clk_sys); cart_replace <= 0;
			for (k = 0; k < 262144; k = k + 1) flash[k] = rom_word(k);   // the image as downloaded
			for (k = 0; k < 200; k = k + 1) begin
				@(posedge clk_74a); bridge_addr <= 32'h11000000 + k*4; bridge_wr_data <= k; bridge_wr <= 1;
				@(posedge clk_74a); bridge_wr <= 0;
				repeat (300) @(posedge clk_74a);
			end
			@(posedge clk_74a); bridge_addr <= 32'hF8000000;
			t_last_slot = cyc;
			@(posedge clk_sys); cart_download <= 0; cart_ready <= 1; loader_config <= 1;
			@(posedge clk_sys); loader_config <= 0;
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
	// Files
	// =========================================================================
	reg [8*160-1:0] fn;
	reg [63:0] meta [0:15];
	reg [15:0] t0f [0:8191];
	reg [63:0] clog [0:63];

	// =========================================================================
	// The run
	// =========================================================================
	integer rc6a_nf;
	integer i, n, t_ref, t_cap, t_restore_end, b10_diff, b10_ff, rom_bad, reg_match, log_match, n_clog;
	reg     ref_seen;
	reg [63:0] w0_after, w1_after;
	reg [15:0] v16;
	integer    b10r_diff = -1;
	reg        at_hold = 0, at_busy = 0, at_dirty = 0, at_pend = 0;
	reg [15:0] at_pc = 0;
	integer    t_apply = -1, t_apply_end = -1, t_drain = -1;
	reg        apply_in_busy = 0, drain_q = 0, ap_q = 0;
	// RC6A: what the engine saw when the copier's state request arrived --
	// the flash-idle guard applies to a request with no boot apply pending
	integer    t_sreq = -1, n_sreq = 0;
	reg        sreq_boot_pend = 0, sreq_die_busy = 0;
	always @(posedge clk_sys) begin
		if (mc_state_apply === 1'b1) begin
			n_sreq = n_sreq + 1;
			t_sreq = cyc;
			sreq_boot_pend = (cart_save.apply_pending === 1'b1);
			sreq_die_busy  = (cart_die_busy !== 2'b00);
		end
	end
	// ...and what it held when it decided (S_FINISH, the cycle before
	// state_done): the terms of saveless_erased and the dirty bitmap
	reg        dec_pend = 0, dec_data = 0, dec_ovf = 0, dec_base = 0, dec_deliv = 0, dec_prog = 0;
	reg [63:0] dec_dirty0 = 0;
	always @(posedge clk_sys) begin
		if (mc_state_done === 1'b1) begin
			dec_pend   = cart_save.stage_pending;
			dec_data   = cart_save.image_has_data;
			dec_ovf    = cart_save.pack_overflow;
			dec_base   = cart_save.base_q;
			dec_deliv  = cart_save.apf_delivered | cart_save.pre_delivered;
			dec_prog   = cart_save.prog_since_publish;
			dec_dirty0 = cart_save.dirty0;
		end
	end
	// The follow-up's program/erase classifier against the REAL flash_die and
	// ngp_cart: this game only erases, so every completion event the engine
	// takes must read as an erase (prog_event low).
	integer n_ev_seen = 0, n_ev_prog = 0;
	always @(posedge clk_sys) begin
		if (cart_dirty0_event === 1'b1 || cart_dirty1_event === 1'b1) begin
			n_ev_seen = n_ev_seen + 1;
			if (cart_save.prog_event !== 1'b0) begin
				n_ev_prog = n_ev_prog + 1;
				$display("   [%0d] RC6A: flash event %0d classified as a PROGRAM (busy_cnt0 %0d)",
				         cyc, n_ev_seen, cart_save.busy_cnt0);
			end
		end
	end
	always @(posedge clk_sys) begin
		if (sc_draining === 1'b1 && !drain_q && t_drain < 0) t_drain = cyc;
		drain_q = (sc_draining === 1'b1);
		if (cart_save.in_apply === 1'b1 && cart_save.from_state === 1'b1 && !ap_q) begin
			t_apply = cyc;
			apply_in_busy = (cart_die_busy[0] === 1'b1) || (cart.die0.state == 4'd7);
		end
		if (ap_q && !(cart_save.in_apply === 1'b1 && cart_save.from_state === 1'b1)) t_apply_end = cyc;
		ap_q = (cart_save.in_apply === 1'b1 && cart_save.from_state === 1'b1);
	end

	// wait for a reference event; returns its cycle (or -1 on timeout)
	task wait_ref(input integer rsel, input integer which, output integer t);
		integer lim;
		begin
			t = -1; lim = 0;
			while (t < 0 && lim < 20000000) begin
				@(posedge clk_sys); lim = lim + 1;
				case (rsel)
					0: if (n_erase_started >= which) t = t_e1[which];
					1: if (n_busy_rise >= which) t = t_busy_rise[which];
					2: if (n_busy_fall >= which) t = t_busy_fall[which];
					3: if (t_pass_start >= 0) t = t_pass_start;
					4: if (t_publish >= 0) t = t_publish;
					5: if (t_boot_rel >= 0) t = t_boot_rel;
					6: if (t_first_poll >= 0) t = t_first_poll;
					7: if (t_last_slot >= 0) t = t_last_slot;
					default: t = cyc;
				endcase
			end
		end
	endtask

	initial begin
		if ($value$plusargs("WAKE=%d", P_WAKE)) ;
		if ($value$plusargs("TAG=%s", P_TAG)) ;
		if ($value$plusargs("CAPREF=%d", P_CAPREF)) ;
		if ($value$plusargs("CAPCYC=%d", P_CAPCYC)) ;
		if ($value$plusargs("CAPERASE=%d", P_CAPERASE)) ;
		if ($value$plusargs("LOADREF=%d", P_LOADREF)) ;
		if ($value$plusargs("LOADCYC=%d", P_LOADCYC)) ;
		if ($value$plusargs("POLL=%d", P_POLL)) ;
		if ($value$plusargs("ROMFF=%d", P_ROMFF)) ;
		if ($value$plusargs("ERASES=%d", P_ERASES)) ;
		if ($value$plusargs("BIOSUS=%d", P_BIOSUS)) ;
		if ($value$plusargs("SNKUS=%d", P_SNKUS)) ;
		if ($value$plusargs("GAPUS=%d", P_GAPUS)) ;
		if ($value$plusargs("POSTUS=%d", P_POSTUS)) ;
		if ($value$plusargs("PARK=%d", P_PARK)) ;
		if ($value$plusargs("IDREAD=%d", P_IDREAD)) ;
		if ($value$plusargs("WERASE=%d", P_WERASE)) ;
		if ($value$plusargs("SEED=%d", P_SEED)) ;
		if ($value$plusargs("VERBOSE=%d", P_VERBOSE)) ;
		if ($value$plusargs("CAPFAIL=%h", P_CAPFAIL)) ;
		if ($value$plusargs("DIR=%s", P_DIR)) ;
		if (!$value$plusargs("CAPDIR=%s", P_CAPDIR)) P_CAPDIR = P_DIR;
		i = $urandom(P_SEED);

		N_BIOS = (P_BIOSUS * 49152) / 1000 / 40;
		N_SNK  = (P_SNKUS  * 49152) / 1000 / 40;
		N_GAP  = (P_GAPUS  * 49152) / 1000 / 40;
		if (N_SNK < 2) N_SNK = 2;
		if (N_GAP < 2) N_GAP = 2;

		for (i = 0; i < 262144; i = i + 1) flash[i] = rom_word(i);
		for (i = 0; i <= N_INT; i = i + 1) internals[i] = {32'h5A5A0000 + i, 32'h12340000 + i};
		for (i = 0; i < SZ0; i = i + 1) mem0[i] = i[7:0] ^ 8'h3C;
		for (i = 0; i < SZ1; i = i + 1) mem1[i] = i[7:0] + 8'h11;
		for (i = 0; i < SZ2; i = i + 1) mem2[i] = i[7:0] ^ i[13:6];
		for (i = 0; i < WORDS; i = i + 1) image[i] = 32'd0;
		for (i = 0; i < 64; i = i + 1) clog[i] = 64'd0;
		cart_download = 1;   // the machine is held until the cartridge slot has landed

		if (!P_WAKE) begin
			// ================= CAPTURE RUN =================
			// PSRAM as the Card Fighters session left it: bank 0 holds a CF
			// image (magic, CF CRC), bank 1 junk.
			for (i = 0; i < 65536; i = i + 1) cmem[i] = 16'hDEAD ^ i[15:0];
			cmem[0] = 16'h4E47; cmem[1] = 16'h5043; cmem[2] = 16'h5341; cmem[3] = 16'h5634;
			cmem[4] = CF_CRC[15:0]; cmem[5] = CF_CRC[31:16];
			$display("== T9S CAPTURE tag=%0s capref=%0d capcyc=%0d caperase=%0d poll=%0d romff=%0d erases=%0d park=%0d idread=%0d",
			         P_TAG, P_CAPREF, P_CAPCYC, P_CAPERASE, P_POLL, P_ROMFF, P_ERASES, P_PARK, P_IDREAD);

			repeat (20) @(posedge clk_sys);
			reset_in <= 0;
			repeat (8) @(posedge clk_sys);
			apf_slots;

			wait_ref(P_CAPREF, P_CAPERASE, t_ref);
			if (t_ref < 0) begin
				$display("== T9S CAPTURE RESULT tag=%0s NOREF", P_TAG);
				$display("== 1 FAILURE(S): RC6A T9S capture %0s: the reference event never came", P_TAG);
				$stop;
			end
			while (cyc < t_ref + P_CAPCYC) @(posedge clk_sys);
			t_cap = cyc;
			if (P_VERBOSE) $display("   [%0d] APF capture command (ref %0d, pc %0d, die state %0d busy %b, engine state %0d pending %b quiet %0d)",
			         cyc, t_ref, pc, cart.die0.state, cart_die_busy[0], est, cart_save.stage_pending, cart_save.quiet);
			fork
				apf_save;
				begin
					while (!t0_taken) @(posedge clk_sys);
					log_on = 1;
				end
			join
			if (P_VERBOSE) $display("   [%0d] capture %0s: T0 %0d, engine end %0d, hold %0d, copier start %0d",
			         cyc, sv_ok ? "OK" : "FAILED", t_t0, t_eng_end, t_hold_up, t_cap_copy);

			// continue the session: what the machine reads after the capture
			repeat ((P_POSTUS * 49152) / 1000) @(posedge clk_sys);

			// files
			$sformat(fn, "%0s/%0s_blob.hex", P_DIR, P_TAG);   $writememh(fn, image);
			$sformat(fn, "%0s/%0s_psram.hex", P_DIR, P_TAG);   $writememh(fn, cmem);
			$sformat(fn, "%0s/%0s_t0b10.hex", P_DIR, P_TAG);   $writememh(fn, t0_b10);
			for (i = 0; i < 64; i = i + 1) clog[i] = (i < n_log) ? rlog[i] : 64'hFFFFFFFF_FFFFFFFF;
			$sformat(fn, "%0s/%0s_reads.hex", P_DIR, P_TAG);   $writememh(fn, clog);
			meta[0] = t0_w0; meta[1] = t0_w1; meta[2] = t0_die0a; meta[3] = t0_die0b;
			meta[4] = n_log;
			for (i = 5; i < 16; i = i + 1) meta[i] = 64'd0;
			$sformat(fn, "%0s/%0s_meta.hex", P_DIR, P_TAG);   $writememh(fn, meta);

			// the embedded image
			n = 0;
			for (i = 0; i < 8192; i = i + 1) if (t0_b10[i] !== 16'hFFFF) n = n + 1;
			$display("   T0 at %0d (capture command %0d, ref %0d): cpu pc=%0d cnt=%0d vcnt=%0d nerase=%0d fail=%h | die0 state=%0d cmd=%h busy=%b | block10 non-FF words at T0=%0d",
			         t_t0, t_cap, t_ref, t0_w0[63:48], t0_w1[63:32], t0_w1[31:0], t0_w0[23:16], t0_w0[31:24],
			         t0_die0a[3:0], t0_die0a[11:4], t0_busy, n);
			$display("   gap: engine released %0d, hold %0d, instructions started in the gap %0d (pc %0d) | copier start %0d: die busy %b, stage_pending %b",
			         t_eng_end, t_hold_up, gap_instr, gap_pc, t_cap_copy, cap_copy_busy, cap_copy_pend);
			$display("   image: magic %h%h%h%h crc %h%h dirty0 %h%h%h%h w21 %h w22 %h w23 %h w24 %h payload[256..259] %h %h %h %h",
			         secw(0), secw(1), secw(2), secw(3), secw(5), secw(4), secw(11), secw(10), secw(9), secw(8),
			         secw(21), secw(22), secw(23), secw(24), secw(256), secw(257), secw(258), secw(259));
			$display("   id block: %h %h %h %h", image[8420], image[8421], image[8422], image[8423]);
			$display("   session after the capture: pc=%0d fail=%h nerase=%0d, passes %0d, publishes %0d, first pass %0d, first publish %0d, reads logged %0d",
			         pc, fail, nerase, n_pass, n_pub, t_pass_start, t_publish, n_log);
			for (i = 0; i < 12 && i < n_log; i = i + 1)
				$display("     %0s %0d: pc %0d a %h v %h die %0d", le_we(rlog[i]) ? "write" : "read ", i,
				         le_pc(rlog[i]), le_a(rlog[i]), le_v(rlog[i]), le_die(rlog[i]));
			// consistency: a block the machine had already changed at T0 must be
			// in the image, or a wake cannot put it back
			n = 0;
			for (i = 0; i < 8192; i = i + 1) if (t0_b10[i] !== rom_word(B10W + i)) n = n + 1;
			v16 = secw(8);
			$display("== T9S CAPTURE RESULT tag=%0s ok=%0d t0_pc=%0d t0_die=%0d t0_busy=%0d t0_b10_changed=%0d img_is_pacman=%0d img_has_b10=%0d gap_instr=%0d gap_pc=%0d copy_busy=%0d copy_pend=%0d img_crc=%h%h img_dirty0=%h%h%h%h img_w23=%h rel_t0_ref=%0d post_fail=%h",
			         P_TAG, sv_ok, t0_w0[63:48], t0_die0a[3:0], t0_busy, n,
			         ({secw(5), secw(4)} == CART_CRC), ({secw(5), secw(4)} == CART_CRC) && v16[10],
			         gap_instr, gap_pc, cap_copy_busy, cap_copy_pend,
			         secw(5), secw(4), secw(11), secw(10), secw(9), secw(8), secw(23), t_t0 - t_ref, fail);
			$display("   RC6A classifier: %0d flash event(s), %0d read as a program", n_ev_seen, n_ev_prog);
			if (n_ev_prog != 0)
				$display("   RC6A FAIL: classifier: %0d of the real flash_die's erase event(s) read as a program", n_ev_prog);
			if (sv_ok && n_ev_prog == 0) begin
				$display("== ALL RC6A T9S SCENARIOS PASS (capture %0s)", P_TAG);
				$finish;
			end else begin
				$display("== 1 FAILURE(S): RC6A T9S capture %0s %0s", P_TAG,
				         sv_ok ? "classified an erase as a program" : "did not complete");
				$stop;
			end
		end else begin
			// ================= WAKE RUN =================
			$sformat(fn, "%0s/%0s_psram.hex", P_CAPDIR, P_TAG);   $readmemh(fn, cmem);
			$sformat(fn, "%0s/%0s_blob.hex", P_CAPDIR, P_TAG);   $readmemh(fn, image);
			$sformat(fn, "%0s/%0s_t0b10.hex", P_CAPDIR, P_TAG);   $readmemh(fn, t0f);
			$sformat(fn, "%0s/%0s_reads.hex", P_CAPDIR, P_TAG);   $readmemh(fn, clog);
			$sformat(fn, "%0s/%0s_meta.hex", P_CAPDIR, P_TAG);   $readmemh(fn, meta);
			n_clog = meta[4];
			$display("== T9S WAKE tag=%0s loadref=%0d loadcyc=%0d werase=%0d poll=%0d romff=%0d park=%0d",
			         P_TAG, P_LOADREF, P_LOADCYC, P_WERASE, P_POLL, P_ROMFF, P_PARK);
			if (!P_WERASE) begin
				N_BIOS = 50000000;   // the wake session never leaves its BIOS phase
			end

			repeat (20) @(posedge clk_sys);
			reset_in <= 0;
			repeat (8) @(posedge clk_sys);
			// APF: the blob, then the slots (a new core launch)
			apf_write_blob;
			apf_slots;

			wait_ref(P_LOADREF == 0 ? 7 : (P_LOADREF == 5 ? 5 : P_LOADREF), 1, t_ref);
			if (t_ref < 0) begin
				$display("== T9S WAKE RESULT tag=%0s loadref=%0d loadcyc=%0d NOREF", P_TAG, P_LOADREF, P_LOADCYC);
				$display("== RC6A T9S FAIL NOREF tag=%0s", P_TAG);
				$display("== 1 FAILURE(S): RC6A T9S wake %0s: the reference event never came", P_TAG);
				$stop;
			end
			while (cyc < t_ref + P_LOADCYC) @(posedge clk_sys);
			at_hold = overlay_boot_hold; at_busy = cart_die_busy[0]; at_dirty = cart_save.dirty0[10];
			at_pend = cart_save.stage_pending; at_pc = pc;
			if (P_VERBOSE) $display("   [%0d] APF load command (ref %0d; boot_hold %b, pc %0d, die state %0d busy %b, engine state %0d pending %b, dirty0 %h, slots_settled %b)",
			         cyc, t_ref, overlay_boot_hold, pc, cart.die0.state, cart_die_busy[0], est,
			         cart_save.stage_pending, cart_save.dirty0, slots_settled);
			fork
				apf_load;
				begin : watch_restore
					// the restore ends when loading_savestate falls
					n = 0;
					while (ss_loading !== 1'b1 && n < 30000000 && !(ld_done)) begin @(posedge clk_sys); n = n + 1; end
					while (ss_loading === 1'b1) @(posedge clk_sys);
					if (!ld_done || ld_ok) begin
						t_restore_end = cyc;
						w0_after = cpu_w0; w1_after = cpu_w1;
						n_log = 0; log_on = 1;
						// the flash the restored CPU finds, at the instant it resumes
						b10r_diff = 0;
						for (i = 0; i < 8192; i = i + 1) if (flash[B10W + i] !== t0f[i]) b10r_diff = b10r_diff + 1;
					end
				end
			join
			if (!ld_ok) begin
				t_restore_end = -1; w0_after = cpu_w0; w1_after = cpu_w1;
				n_log = 0; log_on = 1;   // what the cold session reads next
			end
			repeat ((P_POSTUS * 49152) / 1000) @(posedge clk_sys);

			// flash block 10 against the capture's T0 view
			b10_diff = 0; b10_ff = 0;
			for (i = 0; i < 8192; i = i + 1) begin
				if (flash[B10W + i] !== t0f[i]) b10_diff = b10_diff + 1;
				if (flash[B10W + i] === 16'hFFFF) b10_ff = b10_ff + 1;
			end
			rom_bad = 0;
			for (i = 0; i < B10W; i = i + 1) if (flash[i] !== rom_word(i)) rom_bad = rom_bad + 1;
			reg_match = (w0_after === meta[0]) && (w1_after === meta[1]);
			log_match = 0;
			for (i = 0; i < 64 && i < n_log && i < n_clog; i = i + 1)
				if (rlog[i] === clog[i]) log_match = log_match + 1;

			$display("   load %0s at %0d (command %0d, ref %0d): verdict %h applies %0d p2wr %h apply_reject %b frozen %b save_present %b dirty0 %h bank %0d | copier st %0d",
			         ld_ok ? "OK" : "FAILED", t_ld_end, t_ld_cmd, t_ref, cart_save.diag_verdict, cart_save.diag_applies,
			         cart_save.diag_p2wr, mc_apply_reject, mc_frozen, save_present, cart_save.dirty0, mc_stage_bank, state_cart.st);
			$display("   capture T0 regs  pc=%0d cnt=%0d vcnt=%0d nerase=%0d fail=%h | die0 at T0 state %0d",
			         meta[0][63:48], meta[1][63:32], meta[1][31:0], meta[0][23:16], meta[0][31:24], meta[2][3:0]);
			$display("   after restore    pc=%0d cnt=%0d vcnt=%0d nerase=%0d fail=%h | regs match T0: %0d | die0 now state %0d",
			         w0_after[63:48], w1_after[63:32], w1_after[31:0], w0_after[23:16], w0_after[31:24], reg_match, cart.die0.state);
			$display("   block 10 now vs T0 view: %0d words differ (%0d erased) | ROM below block 10 damaged words: %0d",
			         b10_diff, b10_ff, rom_bad);
			$display("   reads after the restore vs the capture session's reads after T0: %0d of %0d/%0d identical",
			         log_match, n_log, n_clog);
			for (i = 0; i < 12 && i < n_log; i = i + 1)
				$display("     %0s %0d: pc %0d a %h v %h die %0d   | capture session: pc %0d a %h v %h die %0d%0s",
				         le_we(rlog[i]) ? "write" : "read ", i,
				         le_pc(rlog[i]), le_a(rlog[i]), le_v(rlog[i]), le_die(rlog[i]),
				         le_pc(clog[i]), le_a(clog[i]), le_v(clog[i]), le_die(clog[i]),
				         (rlog[i] === clog[i]) ? "" : "   <-- differs");
			$display("   end: pc=%0d fail=%h nerase=%0d | passes %0d publishes %0d | drains %0d | host drops %0d",
			         pc, fail, nerase, n_pass, n_pub, sc_diag_drain, stage_diag_drops);
			$display("   at the load command: boot_hold %b, die busy %b, dirty0[10] %b, pass owed %b, wake pc %0d | drain starts %0d, state apply %0d..%0d (die mid-erase when it began: %b)",
			         at_hold, at_busy, at_dirty, at_pend, at_pc, t_drain, t_apply, t_apply_end, apply_in_busy);
			$display("== T9S WAKE RESULT tag=%0s loadref=%0d loadcyc=%0d werase=%0d | at_cmd: hold=%0d busy=%0d dirty10=%0d owed=%0d pc=%0d | load=%0s verdict=%h reject=%0d frozen=%0d cs_err=%0d apply_aborted_erase=%0d aborts=%0d | regs_match=%0d b10_at_resume_vs_T0=%0d b10_vs_T0=%0d rom_bad=%0d reads_match=%0d/%0d | end_pc=%0d end_fail=%h | wake_busy_rises=%0d boot_rel=%0d cmd_rel_boot=%0d",
			         P_TAG, P_LOADREF, P_LOADCYC, P_WERASE, at_hold, at_busy, at_dirty, at_pend, at_pc,
			         ld_ok ? "ok" : "FAIL", cart_save.diag_verdict, mc_apply_reject,
			         mc_frozen, cs_load_error, apply_in_busy, n_abort, reg_match, b10r_diff, b10_diff, rom_bad, log_match, (n_log < n_clog) ? n_log : n_clog,
			         pc, fail, n_busy_rise, t_boot_rel, t_ld_cmd - t_boot_rel);

			// ---- RC6A verdict ------------------------------------------------
			// Every wake must load. Where the flash-idle guard applies (the
			// state request found no boot apply pending) the apply must not
			// have begun with the die mid-erase, and no erase may have been
			// cut by a reset. A loaded state must restore the CPU exactly, the
			// ROM below block 10 must be intact, and the game's own flash
			// self-checks must end as they did in the capture session.
			rc6a_nf = 0;
			if (!ld_ok) begin
				rc6a_nf = rc6a_nf + 1;
				$display("   RC6A FAIL: the load was refused (a wake cold-boots): verdict %h", cart_save.diag_verdict);
			end
			if (ld_ok && !reg_match) begin
				rc6a_nf = rc6a_nf + 1;
				$display("   RC6A FAIL: the restored CPU registers differ from the capture's T0");
			end
			if (rom_bad != 0) begin
				rc6a_nf = rc6a_nf + 1;
				$display("   RC6A FAIL: %0d ROM words below block 10 damaged", rom_bad);
			end
			if (fail != 8'h00 && fail != P_CAPFAIL[7:0]) begin
				rc6a_nf = rc6a_nf + 1;
				$display("   RC6A FAIL: the game's flash self-check failed (code %h; the capture session ended with %h)",
				         fail, P_CAPFAIL[7:0]);
			end
			if (n_sreq > 0 && !sreq_boot_pend && (apply_in_busy || n_abort != 0)) begin
				rc6a_nf = rc6a_nf + 1;
				$display("   RC6A FAIL: flash-idle guard: the state apply began with the die mid-erase (%b) / %0d erase(s) cut by a reset",
				         apply_in_busy, n_abort);
			end
			if (n_ev_prog != 0) begin
				rc6a_nf = rc6a_nf + 1;
				$display("   RC6A FAIL: classifier: %0d of %0d flash event(s) (the real flash_die's erases) read as a program",
				         n_ev_prog, n_ev_seen);
			end
			$display("   RC6A at the decision: dirty0 %h pass-owed %b programmed-since-publish %b image_has_data %b overflow %b base %b delivered %b | flash events %0d, read as a program %0d",
			         dec_dirty0, dec_pend, dec_prog, dec_data, dec_ovf, dec_base, dec_deliv, n_ev_seen, n_ev_prog);
			$display("== RC6A T9S %0s tag=%0s w=%0d/%0d | guard=%0d (state request at %0d: boot apply pending %b, die busy %b; apply began %0d, wait %0d clk) | load=%0s verdict=%h aborted_erase=%0d aborts=%0d regs=%0d rom_bad=%0d end_fail=%h b10_resume_vs_T0=%0d",
			         (rc6a_nf == 0) ? "PASS" : "FAIL", P_TAG, P_LOADREF, P_LOADCYC,
			         (n_sreq > 0 && !sreq_boot_pend), t_sreq, sreq_boot_pend, sreq_die_busy, t_apply,
			         (t_apply >= 0 && t_sreq >= 0) ? (t_apply - t_sreq) : -1,
			         ld_ok ? "ok" : "REFUSED", cart_save.diag_verdict, apply_in_busy, n_abort,
			         reg_match, rom_bad, fail, b10r_diff);
			if (rc6a_nf == 0) begin
				$display("== ALL RC6A T9S SCENARIOS PASS (wake %0s %0d/%0d)", P_TAG, P_LOADREF, P_LOADCYC);
				$finish;
			end else begin
				$display("== %0d FAILURE(S): RC6A T9S wake %0s %0d/%0d", rc6a_nf, P_TAG, P_LOADREF, P_LOADCYC);
				$stop;                      // vvp -N: exit status 1
			end
		end
	end

	initial begin
		repeat (4000) #1_000_000;
		$display("== RC6A T9S FAIL WATCHDOG tag=%0s", P_TAG);
		$display("== T9S WATCHDOG at cycle %0d (pc %0d, engine %0d, copier %0d, bridge %0d)", cyc, pc, est, state_cart.st, savestate_bridge.state);
		$display("== 1 FAILURE(S): RC6A T9S WATCHDOG %0s", P_TAG);
		$stop;
	end

endmodule

`default_nettype wire
