// Testbench: the rc5 language gate and automatic power press
// (rc5_spec.md G1, G2), around the real BIOS setup seed.
//
// Written from the specification, not from the implementation.
//
// ngpc_machine is too large to simulate whole, so this bench runs
//   - the REAL upstream/rtl/soc/ngp_setup_seed.sv, unmodified, and
//   - a VERBATIM copy of four pieces of target/pocket/ngpc_machine.sv, which
//     sim/run_seed_gate.sh cuts out at run time into seed_gate_extract.svh,
//     in file order:
//       1. the machine reset net        wire reset = ... ;
//       2. the automatic power press    // ---- auto power begin ----
//                                       // ---- auto power end ----
//                                       (unmarked: localparam PWR_HOLD_CLKS
//                                       through wire power_btn = ... ;)
//       3. the settings gate            // ---- settings gate begin ----
//                                       // ---- settings gate end ----
//       4. the setup seed instance      ngp_setup_seed setup_seed ( ... );
//     They are compiled inside one generate scope (seed_gate_dut.g), so
//     whatever they declare stays theirs. The nets they only use are
//     declared around them with ngpc_machine's names and driven by the
//     glue after them, which therefore drives a piece's own declaration
//     when it has one (bios_setup_ready, cart_ready, ...) and the outer net
//     otherwise.
//
// Modeled around it:
//   - the BIOS: out of machine reset it runs a cold init (COLD clocks),
//     then sits in standby -- bios_setup_ready -- until it has seen the
//     power button for PWR_SEEN clocks while not paused. It then boots the
//     game, which reads the Language and Palette bytes of the setup record
//     in work RAM at that moment. That read is what every G1 scenario
//     checks: the BIOS byte is 0x00 for JP and 0x01 for EN.
//   - work RAM: the seed's ss_mem writes land in it. Power-up and a
//     cartridge download (the work-RAM clear) leave no record (0xEE); menu
//     Reset leaves it alone, as on hardware.
//   - the pause tree: pause_ready follows the seed's pause_req a clock
//     later.
//   - APF: the settings (Language, Palette) as ngpc_machine gets them,
//     already synchronised; apf_reset_exit as the synchronised reset_n
//     LEVEL (Reset Exit raises it, Reset Enter lowers it); a cartridge
//     download, which holds the machine in reset; menu Reset on reset_in.
//   - a savestate restore: the save engine's boot_hold (overlay_boot_hold)
//     held for 100 clocks, after which the machine is the restored game --
//     running, not in standby.
//
// Each scenario runs in its own copy of the DUT, so each starts at
// power-up: apf_run_seen_q has a power-up value only, by design.
//
// What the bench cannot see, the run script checks statically before it
// compiles: core_top connects apf_reset_exit to reset_n through a synch_3
// into clk_sys, and the rc4 settings_ready logic is gone from core_top
// (G1, Wiring).
//
// SCENARIOS (spec items in brackets)
//   T1 DOC-ORDER     APF's documented order: Language and Palette written
//                    during the cartridge load, Reset Exit, then the BIOS
//                    reaches standby. The seed runs within 3 clocks of
//                    standby, the automatic press follows, the game reads
//                    JP and the chosen palette. settings_wait_q never
//                    moved [G1]
//   T2 LATE-SETTINGS the BIOS is in standby before APF has written
//                    anything: no seed, no press, settings_ready low for 20k
//                    clocks while settings_wait_q counts them one by one. JP
//                    written: still held. Reset Exit: the seed within 4
//                    clocks, the game reads JP [G1]
//   T3 NO-EXIT       no Reset Exit ever. JP written in standby, held until
//                    2^27 standby clocks (fast-forwarded, see below), then
//                    settings_late_q, the seed, the press; the game reads
//                    JP. settings_wait_q is 27 bits wide [G1]
//   T4 STICKY        booted after a Reset Exit. An unpaired Reset Enter
//                    leaves settings_ready high. Language changed to EN,
//                    menu Reset: the BIOS re-seeds at standby without
//                    waiting and the game reads EN. Then JP, and a
//                    cartridge reload with no Reset Exit after it: the same,
//                    the game reads JP [G1]
//   T5 SLOW-LOAD     no Reset Exit. A cartridge load holds the machine in
//                    reset for 200k clocks and the BIOS then cold-inits:
//                    settings_wait_q stays 0 throughout (and I3 holds). JP
//                    arrives 2000 clocks into standby, the fallback still
//                    takes 2^27 standby clocks, the game reads JP [G1]
//   T6 G2-HOLD       the press the gate delayed (Reset Exit after standby)
//                    is still being held when a savestate restore raises
//                    boot_hold: pwr_hold_q clears within 2 clocks, power
//                    stays released through the reset, and the restored
//                    game never sees the button [G2]
//   T7 G2-PENDING    the cartridge is not ready: the seed completes and the
//                    press is pending (auto_pwr_pending_q). A restore clears
//                    it, and no press follows when the cartridge becomes
//                    ready [G2]
//   T8 MANUAL        automatic power off. A manual press made and released
//                    while the cartridge load holds the machine reset net
//                    is gone when the load ends [G2]. Reset Exit before
//                    standby, the seed runs at standby, no press. 30k clocks
//                    of standby do not move settings_wait_q (it counts only
//                    until apf_run_seen_q). A manual press boots JP [G1]
//
// INVARIANTS, checked on every clock of every scenario (reported once each)
//   I1 the seed never starts while settings_ready is low [G1]
//   I2 apf_run_seen_q and settings_late_q never fall [G1]
//   I3 settings_wait_q advances by one at a time, only after standby
//      clocks, and never once apf_run_seen_q is set [G1]
//
// FAST AND FULL. 2^27 clocks are 2.7 s of clk_sys. By default T3 and T5
// watch settings_wait_q count standby clocks one by one, then write it to
// 2^27-1-256 (at a falling edge) and let it carry by itself. The check is
// on the effective count: the standby clocks seen before the seed started
// plus the clocks skipped must come to 2^27 .. 2^27+4. A wider counter
// never carries, and I3 would see any step other than +1. With
// +define+SEED_GATE_FULL (run_seed_gate.sh full) T3 skips nothing and
// counts all 2^27 standby clocks; T5 still fast-forwards.
//
// Internal names read (all named by the spec, all required inside the
// pieces): settings_ready, apf_run_seen_q, settings_late_q, settings_wait_q
// (also written, for the fast-forward), pwr_hold_q, auto_pwr_pending_q; and
// power_btn, the press the BIOS sees.
//
// Run: wsl -e sh /mnt/c/FPGA/ngpc-rc4/sim/run_seed_gate.sh [full]

`timescale 1ns / 1ps
`default_nettype none

`define FAIL(a) begin errors = errors + 1; $write("   FAIL [%0s] ", scn); $display a ; end

// ============================================================================
// DUT: ngpc_machine's own text around the real ngp_setup_seed
// ============================================================================
module seed_gate_dut
(
	// ngpc_machine ports, same names
	input  wire        clk_sys,
	input  wire        reset_in,
	input  wire        apf_reset_exit,
	input  wire        opt_language_jp,
	input  wire  [2:0] opt_palette,
	input  wire        opt_skip_anim,
	input  wire        opt_use_host_rtc,
	input  wire        opt_auto_power,
	input  wire        bios_downloading,
	input  wire  [7:0] joystick,

	// ngpc_machine internals that come from logic outside the pieces
	input  wire        tb_cart_download,
	input  wire        tb_cart_download_start,
	input  wire        tb_overlay_boot_hold,    // the save engine's boot_hold_o
	input  wire        tb_cart_present,
	input  wire        tb_cart_ready,
	input  wire        tb_bios_setup_ready,     // mainboard: the BIOS is in standby
	input  wire        tb_pause_ready,

	// observed
	output wire        o_reset,                 // the machine reset net
	output wire        o_settings_ready,
	output wire        o_power_btn,             // what the BIOS reads as power
	output wire        o_pause_req,
	output wire        o_seed_done,
	output wire        o_mem_wr,
	output wire [13:0] o_mem_addr,
	output wire  [7:0] o_mem_wdata,
	output wire        o_run_seen,              // apf_run_seen_q
	output wire        o_late,                  // settings_late_q
	output wire        o_pending,               // auto_pwr_pending_q
	output wire        o_hold                   // pwr_hold_q != 0
);

	// Nets of ngpc_machine that the pieces use without owning them. A piece
	// that declares one shadows it inside g.
	wire        hard_reset, bios_reset, base_reset, strap_reset;
	wire        cart_download, cart_download_start, wram_clear_busy;
	wire        overlay_boot_hold;
	wire        cart_present, cart_ready, bios_setup_ready, pause_ready;
	wire        bios_mono_active, cart_header_valid;
	wire [15:0] cart_header_catalog;
	wire  [7:0] cart_header_subcatalog;
	wire [95:0] cart_header_title;
	wire [64:0] host_rtc;

	// Driven inside the pieces; declared here too in case a piece only
	// assigns them.
	wire        settings_ready, power_btn, seed_done, seed_busy;
	wire        seed_pause_req;
	wire  [9:0] seed_ss_bus_adr;
	wire [63:0] seed_ss_bus_din;
	wire        seed_ss_bus_wren;
	wire  [1:0] seed_ss_mem_type;
	wire        seed_ss_mem_active;
	wire [13:0] seed_ss_mem_addr;
	wire  [7:0] seed_ss_mem_wdata;
	wire        seed_ss_mem_wren;
	wire        seed_ss_mem_rden;

	if (1) begin : g

`include "seed_gate_extract.svh"

		// ---- glue: after the pieces, so every name below resolves to a
		// piece's own declaration when there is one -----------------------
		assign hard_reset             = reset_in;
		assign bios_reset             = bios_downloading;
		assign base_reset             = hard_reset | bios_reset;
		assign strap_reset            = 1'b0;
		assign cart_download          = tb_cart_download;
		assign cart_download_start    = tb_cart_download_start;
		assign wram_clear_busy        = 1'b0;   // the load window covers it
		assign overlay_boot_hold      = tb_overlay_boot_hold;
		assign cart_present           = tb_cart_present;
		assign cart_ready             = tb_cart_ready;
		assign bios_setup_ready       = tb_bios_setup_ready;
		assign pause_ready            = tb_pause_ready;
		assign bios_mono_active       = 1'b0;   // colour BIOS: Palette is seeded
		assign cart_header_valid      = 1'b0;
		assign cart_header_catalog    = 16'd0;
		assign cart_header_subcatalog = 8'd0;
		assign cart_header_title      = 96'd0;
		// weekday 2, 2026-09-29 12:00:00, BCD, toggle bit steady
		assign host_rtc               = 65'h0_0002_2609_2912_0000;

		assign o_reset          = reset;
		assign o_settings_ready = settings_ready;
		assign o_power_btn      = power_btn;
		assign o_pause_req      = seed_pause_req;
		assign o_seed_done      = seed_done;
		assign o_mem_wr         = seed_ss_mem_active && seed_ss_mem_wren;
		assign o_mem_addr       = seed_ss_mem_addr;
		assign o_mem_wdata      = seed_ss_mem_wdata;
		assign o_run_seen       = apf_run_seen_q;
		assign o_late           = settings_late_q;
		assign o_pending        = auto_pwr_pending_q;
		assign o_hold           = (pwr_hold_q != 0);
	end

endmodule

// ============================================================================
// One scenario: its own DUT, BIOS model, clock and checks
// ============================================================================
module seed_gate_harness #(parameter integer ID = 1)
(
	input  wire go,
	output reg  done = 1'b0
);

	localparam real    HALF      = 10.173;      // clk_sys, 49.152 MHz
	localparam integer COLD      = 3000;        // BIOS cold init, reset to standby
	localparam integer PWR_SEEN  = 64;          // power held this long wakes the BIOS
	localparam integer LOAD      = 4000;        // a cartridge download
	localparam integer FF_MARGIN = 256;         // the fast-forward stops this short
	localparam integer WAIT_BITS = 27;          // G1
	localparam integer FALLBACK  = 1 << WAIT_BITS;
	localparam integer LONG      = 200_000;     // T5's slow cartridge load
`ifdef SEED_GATE_FULL
	localparam bit     T3_REAL   = 1'b1;        // T3 counts all 2^27 clocks
`else
	localparam bit     T3_REAL   = 1'b0;
`endif

	// ngp_setup_seed's work-RAM offsets and the BIOS bytes
	localparam [13:0] W_LANG = 14'h2F87;
	localparam [13:0] W_PAL  = 14'h2F94;
	localparam [13:0] W_CSUM = 14'h2C14;
	localparam [7:0]  JP     = 8'h00;
	localparam [7:0]  EN     = 8'h01;
	localparam [7:0]  NONE   = 8'hEE;           // no setup record

	string  scn    = "";
	integer errors = 0;

	reg clk = 1'b0;
	always begin
		wait (go && !done);
		#HALF clk = ~clk;
	end

	// ---- stimulus --------------------------------------------------------
	reg        reset_in       = 1'b1;          // power-up
	reg        apf_reset_exit = 1'b0;
	reg        lang_jp        = 1'b0;          // power-up default: EN
	reg  [2:0] palette        = 3'd0;
	reg        auto_power     = 1'b1;
	reg        pwr_pad        = 1'b0;
	reg        cart_download  = 1'b0;
	reg        cart_dl_start  = 1'b0;
	reg        boot_hold      = 1'b0;
	reg        cart_present   = 1'b1;
	reg        cart_ready     = 1'b0;
	reg        pause_ready    = 1'b0;

	wire        bios_setup_ready;
	wire        o_reset, o_settings_ready, o_power_btn, o_pause_req, o_seed_done;
	wire        o_mem_wr;
	wire [13:0] o_mem_addr;
	wire  [7:0] o_mem_wdata;
	wire        o_run_seen, o_late, o_pending, o_hold;

	seed_gate_dut dut
	(
		.clk_sys                (clk),
		.reset_in               (reset_in),
		.apf_reset_exit         (apf_reset_exit),
		.opt_language_jp        (lang_jp),
		.opt_palette            (palette),
		.opt_skip_anim          (1'b0),        // core_top ties it low
		.opt_use_host_rtc       (1'b1),
		.opt_auto_power         (auto_power),
		.bios_downloading       (1'b0),
		.joystick               ({pwr_pad, 7'd0}),
		.tb_cart_download       (cart_download),
		.tb_cart_download_start (cart_dl_start),
		.tb_overlay_boot_hold   (boot_hold),
		.tb_cart_present        (cart_present),
		.tb_cart_ready          (cart_ready),
		.tb_bios_setup_ready    (bios_setup_ready),
		.tb_pause_ready         (pause_ready),
		.o_reset                (o_reset),
		.o_settings_ready       (o_settings_ready),
		.o_power_btn            (o_power_btn),
		.o_pause_req            (o_pause_req),
		.o_seed_done            (o_seed_done),
		.o_mem_wr               (o_mem_wr),
		.o_mem_addr             (o_mem_addr),
		.o_mem_wdata            (o_mem_wdata),
		.o_run_seen             (o_run_seen),
		.o_late                 (o_late),
		.o_pending              (o_pending),
		.o_hold                 (o_hold)
	);

	// ---- the BIOS, work RAM and the pause tree ----------------------------
	localparam [1:0] M_OFF = 2'd0, M_COLD = 2'd1, M_STBY = 2'd2, M_RUN = 2'd3;

	reg  [1:0] mst          = M_OFF;
	integer    cold_cnt     = 0;
	integer    pwr_cnt      = 0;
	reg        restore_next = 1'b0;             // the next reset is a savestate restore
	reg        restored     = 1'b0;
	integer    run_power    = 0;                // clocks the restored game saw power
	reg  [7:0] wram_lang = NONE, wram_pal = NONE, wram_csum = NONE;
	integer    boots = 0;
	reg  [7:0] boot_lang = NONE, boot_pal = NONE, boot_csum = NONE;

	assign bios_setup_ready = (mst == M_STBY);

	always @(posedge clk) begin
		pause_ready <= o_pause_req;

		if (o_mem_wr) begin
			if (o_mem_addr == W_LANG) wram_lang <= o_mem_wdata;
			if (o_mem_addr == W_PAL)  wram_pal  <= o_mem_wdata;
			if (o_mem_addr == W_CSUM) wram_csum <= o_mem_wdata;
		end
		if (cart_dl_start) begin                // the work-RAM clear
			wram_lang <= NONE;
			wram_pal  <= NONE;
			wram_csum <= NONE;
		end

		if (o_reset) begin
			mst     <= M_OFF;
			pwr_cnt <= 0;
		end else begin
			case (mst)
				M_OFF:
					if (restore_next) begin
						mst          <= M_RUN;
						restore_next <= 1'b0;
						restored     <= 1'b1;
					end else begin
						mst      <= M_COLD;
						cold_cnt <= COLD;
					end
				M_COLD:
					if (cold_cnt <= 1) mst <= M_STBY;
					else               cold_cnt <= cold_cnt - 1;
				M_STBY:
					if (o_power_btn === 1'b1 && !o_pause_req && !pause_ready) begin
						if (pwr_cnt == PWR_SEEN - 1) begin
							mst       <= M_RUN;
							boots     <= boots + 1;
							boot_lang <= wram_lang;
							boot_pal  <= wram_pal;
							boot_csum <= wram_csum;
						end
						pwr_cnt <= pwr_cnt + 1;
					end else begin
						pwr_cnt <= 0;
					end
				M_RUN:
					if (restored && o_power_btn === 1'b1) run_power <= run_power + 1;
			endcase
		end
	end

	// ---- monitor and invariants -------------------------------------------
	integer cyc = 0, sb_cnt = 0, pb_clks = 0;
	integer seed_starts = 0, seed_dones = 0, presses = 0, mem_wr_cnt = 0;
	integer t_standby = 0, t_seed = 0, t_exit = 0, sb_at_seed = 0;
	integer dep_cnt = 0, dep_seen = 0;
	integer i1_n = 0, i2_n = 0, i3_n = 0;
	reg        sp_d = 1'b0, sr_d = 1'b0, sb_d = 1'b0, ex_d = 1'b0, pb_d = 1'b0;
	reg        seen_hi = 1'b0, late_hi = 1'b0;
	reg  [2:0] sb_h = 3'b000, rs_h = 3'b000;
	reg [31:0] wq_prev = 0;

	always @(posedge clk) begin : monitor
		reg [31:0] wq;
		wq = dut.g.settings_wait_q;

		cyc  <= cyc + 1;
		sp_d <= (o_pause_req === 1'b1);
		sr_d <= (o_settings_ready === 1'b1);
		sb_d <= bios_setup_ready;
		ex_d <= apf_reset_exit;
		pb_d <= (o_power_btn === 1'b1);

		if (bios_setup_ready)                      sb_cnt     <= sb_cnt + 1;
		if (o_power_btn === 1'b1)                  pb_clks    <= pb_clks + 1;
		if (o_power_btn === 1'b1 && !pb_d)         presses    <= presses + 1;
		if (o_mem_wr === 1'b1)                     mem_wr_cnt <= mem_wr_cnt + 1;
		if (o_seed_done === 1'b1)                  seed_dones <= seed_dones + 1;
		if (bios_setup_ready && !sb_d)             t_standby  <= cyc;
		if (apf_reset_exit && !ex_d)               t_exit     <= cyc;

		if (o_pause_req === 1'b1 && !sp_d) begin
			seed_starts <= seed_starts + 1;
			t_seed      <= cyc;
			sb_at_seed  <= sb_cnt;
			// I1: the seed saw setup_ready in the clock before this one.
			if (!sr_d) begin
				i1_n = i1_n + 1;
				if (i1_n == 1) `FAIL(("I1: the seed started while settings_ready was low (G1)"))
			end
		end

		// I2
		if (o_run_seen === 1'b1) seen_hi <= 1'b1;
		else if (seen_hi) begin
			i2_n = i2_n + 1;
			if (i2_n == 1) `FAIL(("I2: apf_run_seen_q fell; it has a power-up value only and is never cleared (G1)"))
		end
		if (o_late === 1'b1) late_hi <= 1'b1;
		else if (late_hi) begin
			i2_n = i2_n + 1;
			if (i2_n == 1) `FAIL(("I2: settings_late_q fell (G1)"))
		end

		// I3. An increase seen now happened at the previous edge; it must
		// have followed standby (registered or not) and preceded the Exit.
		sb_h     <= {sb_h[1:0], bios_setup_ready};
		rs_h     <= {rs_h[1:0], (o_run_seen === 1'b1)};
		wq_prev  <= wq;
		dep_seen <= dep_cnt;
		if (dep_seen == dep_cnt && cyc > 3 && wq > wq_prev) begin
			if (wq != wq_prev + 1) begin
				i3_n = i3_n + 1;
				if (i3_n == 1) `FAIL(("I3: settings_wait_q went from %0d to %0d in one clock", wq_prev, wq))
			end
			if (sb_h == 3'b000) begin
				i3_n = i3_n + 1;
				if (i3_n == 1) `FAIL(("I3: settings_wait_q advanced (to %0d) with the BIOS out of standby (G1: it counts only in standby)", wq))
			end
			if (rs_h == 3'b111) begin
				i3_n = i3_n + 1;
				if (i3_n == 1) `FAIL(("I3: settings_wait_q advanced (to %0d) after the Reset Exit (G1: it counts only until apf_run_seen_q)", wq))
			end
		end
	end

	// ---- helpers ----------------------------------------------------------
	function string lname(input [7:0] b);
		lname = (b == JP) ? "JP" : (b == EN) ? "EN" : (b == NONE) ? "no setup record" : "?";
	endfunction

	task automatic step(input integer n);
		repeat (n) @(posedge clk);
	endtask

	task automatic begin_scn(input string name, input string what);
		begin
			scn = name;
			$display("== %0s  %0s", name, what);
		end
	endtask

	task automatic power_up;
		begin
			@(posedge clk); reset_in <= 1'b1;
			step(16);
			@(posedge clk); reset_in <= 1'b0;
		end
	endtask

	// APF loads the cartridge: the machine is held in reset for the whole
	// transfer (cart_download is part of the reset net) and work RAM is
	// cleared at its start. cart_ready is the scenario's business.
	task automatic cart_load(input integer clks);
		begin
			@(posedge clk); cart_dl_start <= 1'b1; cart_download <= 1'b1; cart_ready <= 1'b0;
			@(posedge clk); cart_dl_start <= 1'b0;
			step(clks);
			@(posedge clk); cart_download <= 1'b0;
		end
	endtask

	task automatic apf_settings(input jp, input [2:0] pal);
		begin
			@(posedge clk); lang_jp <= jp; palette <= pal;
		end
	endtask

	task automatic apf_exit;
		begin
			@(posedge clk); apf_reset_exit <= 1'b1;
		end
	endtask

	task automatic apf_enter;
		begin
			@(posedge clk); apf_reset_exit <= 1'b0;
		end
	endtask

	task automatic menu_reset(input integer clks);
		begin
			@(posedge clk); reset_in <= 1'b1;
			step(clks);
			@(posedge clk); reset_in <= 1'b0;
		end
	endtask

	task automatic wait_standby(input integer max);
		integer n;
		begin
			n = 0;
			while (!bios_setup_ready && n < max) begin @(posedge clk); n = n + 1; end
			if (!bios_setup_ready) `FAIL(("the BIOS never reached standby within %0d clocks", max))
		end
	endtask

	task automatic wait_seed(input integer s0, input integer max, input string what);
		integer n;
		begin
			n = 0;
			while (seed_starts == s0 && n < max) begin @(posedge clk); n = n + 1; end
			if (seed_starts == s0) `FAIL(("%0s: the seed did not start within %0d clocks", what, max))
		end
	endtask

	task automatic wait_seed_done(input integer s0, input integer max);
		integer n;
		begin
			n = 0;
			while (seed_dones == s0 && n < max) begin @(posedge clk); n = n + 1; end
			if (seed_dones == s0) `FAIL(("the seed did not finish within %0d clocks", max))
		end
	endtask

	task automatic wait_boot(input integer b0, input integer max, input string what);
		integer n;
		begin
			n = 0;
			while (boots == b0 && n < max) begin @(posedge clk); n = n + 1; end
			if (boots == b0) `FAIL(("%0s: the BIOS never left standby for the game within %0d clocks (no power press)", what, max))
		end
	endtask

	task automatic check_boot(input [7:0] lang, input [7:0] pal, input string what);
		reg [7:0] csum;
		begin
			csum = 8'hDC + lang + pal;
			if (boot_lang !== lang)
				`FAIL(("%0s: the game read Language %h (%0s), expected %h (%0s)",
				       what, boot_lang, lname(boot_lang), lang, lname(lang)))
			if (boot_pal !== pal)
				`FAIL(("%0s: the game read Palette %h, expected %h", what, boot_pal, pal))
			if (boot_csum !== csum)
				`FAIL(("%0s: the setup checksum is %h, expected %h", what, boot_csum, csum))
		end
	endtask

	// The gate is closed and the BIOS waits in standby: for n clocks no
	// settings_ready, no seed, no work-RAM write, no press, and
	// settings_wait_q counts every one of them.
	task automatic gate_closed_window(input integer n, input string what);
		integer k, b_ready, b_seed, b_press, b_stby, m0;
		reg [31:0] w0, w1;
		begin
			b_ready = 0; b_seed = 0; b_press = 0; b_stby = 0;
			@(negedge clk);
			w0 = dut.g.settings_wait_q;
			m0 = mem_wr_cnt;
			for (k = 0; k < n; k = k + 1) begin
				@(negedge clk);
				if (o_settings_ready !== 1'b0) b_ready = b_ready + 1;
				if (o_pause_req      !== 1'b0) b_seed  = b_seed + 1;
				if (o_power_btn      !== 1'b0) b_press = b_press + 1;
				if (!bios_setup_ready)         b_stby  = b_stby + 1;
			end
			w1 = dut.g.settings_wait_q;
			if (b_ready != 0)
				`FAIL(("%0s: settings_ready high for %0d of %0d clocks (G1: closed until a Reset Exit or 2^27 standby clocks)",
				       what, b_ready, n))
			if (b_seed != 0)
				`FAIL(("%0s: the seed ran (pause_req for %0d clocks) with the gate closed", what, b_seed))
			if (mem_wr_cnt != m0)
				`FAIL(("%0s: the seed wrote work RAM %0d times with the gate closed", what, mem_wr_cnt - m0))
			if (b_press != 0)
				`FAIL(("%0s: power pressed for %0d clocks with the gate closed", what, b_press))
			if (b_stby != 0)
				`FAIL(("%0s: the BIOS left standby for %0d clocks", what, b_stby))
			if (w1 - w0 != n)
				`FAIL(("%0s: settings_wait_q advanced %0d in %0d standby clocks (G1: one per standby clock)",
				       what, w1 - w0, n))
		end
	endtask

	// settings_wait_q jumps to 2^27-1-FF_MARGIN; `skipped` is how many
	// standby clocks that stands for. With real_count nothing is skipped.
	task automatic fast_forward(input bit real_count, output integer skipped);
		reg [31:0] c;
		begin
			if ($bits(dut.g.settings_wait_q) != WAIT_BITS)
				`FAIL(("settings_wait_q is %0d bits wide, the spec says %0d", $bits(dut.g.settings_wait_q), WAIT_BITS))
			if (real_count) begin
				skipped = 0;
			end else begin
				@(negedge clk);
				c = dut.g.settings_wait_q;
				dut.g.settings_wait_q = FALLBACK - 1 - FF_MARGIN;
				dep_cnt = dep_cnt + 1;
				skipped = (FALLBACK - 1 - FF_MARGIN) - c;
			end
		end
	endtask

	// After the fallback fired: the standby clocks it took, all told. A seed
	// that never started (s0 unchanged) was already reported by wait_seed.
	task automatic check_fallback(input integer skipped, input integer s0, input string what);
		integer eff;
		begin
			if (seed_starts != s0) begin
				eff = sb_at_seed + skipped;
				if (eff < FALLBACK || eff > FALLBACK + 4)
					`FAIL(("%0s: the seed started after %0d standby clocks (%0d seen + %0d skipped), expected 2^27 = %0d .. +4",
					       what, eff, sb_at_seed, skipped, FALLBACK))
				if (o_late !== 1'b1)
					`FAIL(("%0s: the seed ran but settings_late_q is %b", what, o_late))
			end
			if (o_run_seen !== 1'b0)
				`FAIL(("%0s: apf_run_seen_q is %b without any Reset Exit", what, o_run_seen))
		end
	endtask

	// A savestate restore, as the machine sees it: the save engine's
	// boot_hold for `clks`, then the restored game, running.
	task automatic restore_start;
		begin
			@(posedge clk); restore_next <= 1'b1; boot_hold <= 1'b1;
		end
	endtask

	task automatic restore_end;
		begin
			@(posedge clk); boot_hold <= 1'b0;
		end
	endtask

	// ---- scenarios --------------------------------------------------------
	integer s0, d0, b0, p0, pc0, skip;

	task automatic t1_doc_order;
		begin
			begin_scn("T1 DOC-ORDER", "settings during the load, Reset Exit, then standby [G1]");
			s0 = seed_starts; b0 = boots;
			power_up;
			fork
				cart_load(LOAD);
				begin step(1000); apf_settings(1'b1, 3'd3); end
			join
			@(posedge clk); cart_ready <= 1'b1;
			step(500);
			if (o_settings_ready !== 1'b0) `FAIL(("settings_ready is %b before any Reset Exit", o_settings_ready))
			apf_exit;
			wait_standby(COLD + 1000);
			wait_seed(s0, 20, "standby after the Reset Exit");
			if (t_seed - t_standby > 3)
				`FAIL(("the seed started %0d clocks after standby, the gate was open", t_seed - t_standby))
			wait_boot(b0, 2000, "automatic power-on");
			check_boot(JP, 8'h03, "first boot");
			step(5000);
			if (seed_starts - s0 != 1) `FAIL(("%0d seed runs, expected 1", seed_starts - s0))
			if (boots - b0 != 1)       `FAIL(("%0d boots, expected 1", boots - b0))
			if (dut.g.settings_wait_q != 0)
				`FAIL(("settings_wait_q = %0d; the Reset Exit came before standby, so it never counts", dut.g.settings_wait_q))
		end
	endtask

	task automatic t2_late_settings;
		begin
			begin_scn("T2 LATE-SETTINGS", "standby first, settings late, then Reset Exit [G1]");
			s0 = seed_starts; b0 = boots;
			power_up;
			cart_load(LOAD);
			@(posedge clk); cart_ready <= 1'b1;
			wait_standby(COLD + 1000);
			step(8);
			gate_closed_window(20000, "standby, nothing from APF yet");
			apf_settings(1'b1, 3'd2);
			gate_closed_window(5000, "JP written, no Reset Exit yet");
			d0 = seed_starts;                   // only a seed after the Exit counts
			apf_exit;
			wait_seed(d0, 20, "Reset Exit");
			if (t_seed - t_exit > 4)
				`FAIL(("the seed started %0d clocks after the Reset Exit", t_seed - t_exit))
			wait_boot(b0, 2000, "automatic power-on");
			check_boot(JP, 8'h02, "after the Reset Exit");
			step(1000);
			if (seed_starts - s0 != 1) `FAIL(("%0d seed runs, expected 1", seed_starts - s0))
			if (o_late !== 1'b0) `FAIL(("settings_late_q = %b after 25k standby clocks", o_late))
		end
	endtask

	task automatic t3_no_exit;
		begin
			begin_scn("T3 NO-EXIT", "no Reset Exit ever: the fallback after 2^27 standby clocks [G1]");
			s0 = seed_starts; b0 = boots;
			power_up;
			cart_load(LOAD);
			@(posedge clk); cart_ready <= 1'b1;
			wait_standby(COLD + 1000);
			step(8);
			gate_closed_window(3000, "standby, nothing from APF");
			apf_settings(1'b1, 3'd1);
			gate_closed_window(10000, "JP written, no Reset Exit");
			fast_forward(T3_REAL, skip);
			gate_closed_window(FF_MARGIN - 8, "the last clocks before the fallback");
			wait_seed(s0, T3_REAL ? FALLBACK + 20000 : 64, "the fallback");
			check_fallback(skip, s0, "no Reset Exit");
			wait_boot(b0, 2000, "automatic power-on after the fallback");
			check_boot(JP, 8'h01, "after the fallback");
			if (seed_starts - s0 != 1) `FAIL(("%0d seed runs, expected 1", seed_starts - s0))
		end
	endtask

	task automatic t4_sticky;
		begin
			begin_scn("T4 STICKY", "an unpaired Reset Enter keeps the gate open; menu Reset and a reload boot [G1]");
			s0 = seed_starts; b0 = boots;
			power_up;
			fork
				cart_load(LOAD);
				begin step(1000); apf_settings(1'b1, 3'd0); end
			join
			@(posedge clk); cart_ready <= 1'b1;
			step(200);
			apf_exit;
			wait_standby(COLD + 1000);
			wait_seed(s0, 20, "first standby");
			wait_boot(b0, 2000, "first automatic power-on");
			check_boot(JP, 8'h00, "first boot");
			step(1000);

			apf_enter;                          // no Reset Exit follows
			step(5000);
			if (o_settings_ready !== 1'b1)
				`FAIL(("settings_ready = %b after an unpaired Reset Enter (G1: sticky)", o_settings_ready))
			if (o_run_seen !== 1'b1) `FAIL(("apf_run_seen_q = %b after a Reset Enter", o_run_seen))

			apf_settings(1'b0, 3'd4);           // the player picks English
			step(1000);
			s0 = seed_starts; b0 = boots;
			menu_reset(200);
			if (o_settings_ready !== 1'b1)
				`FAIL(("settings_ready = %b after menu Reset (G1: menu Reset keeps it)", o_settings_ready))
			wait_standby(COLD + 1000);
			wait_seed(s0, 20, "standby after menu Reset");
			if (t_seed - t_standby > 3)
				`FAIL(("after menu Reset the seed waited %0d clocks in standby", t_seed - t_standby))
			wait_boot(b0, 2000, "automatic power-on after menu Reset");
			check_boot(EN, 8'h04, "after menu Reset");
			if (seed_starts - s0 != 1) `FAIL(("%0d seed runs after menu Reset, expected 1", seed_starts - s0))
			step(1000);

			// A cartridge reload in the same session (the work-RAM clear, the
			// machine held in reset, reset_n still low from the unpaired
			// Enter) does not close the gate either: apf_run_seen_q is never
			// cleared.
			apf_settings(1'b1, 3'd1);           // back to Japanese, red
			step(1000);
			s0 = seed_starts; b0 = boots;
			cart_load(LOAD);
			if (o_settings_ready !== 1'b1)
				`FAIL(("settings_ready = %b after a cartridge reload (G1: apf_run_seen_q is never cleared)", o_settings_ready))
			@(posedge clk); cart_ready <= 1'b1;
			wait_standby(COLD + 1000);
			wait_seed(s0, 20, "standby after a cartridge reload");
			if (t_seed - t_standby > 3)
				`FAIL(("after a cartridge reload the seed waited %0d clocks in standby", t_seed - t_standby))
			wait_boot(b0, 2000, "automatic power-on after a cartridge reload");
			check_boot(JP, 8'h01, "after a cartridge reload");
			if (seed_starts - s0 != 1) `FAIL(("%0d seed runs after the reload, expected 1", seed_starts - s0))
		end
	endtask

	task automatic t5_slow_load;
		begin
			begin_scn("T5 SLOW-LOAD", "a long load and cold init do not use up the fallback [G1]");
			s0 = seed_starts; b0 = boots;
			power_up;
			cart_load(LONG);
			if (dut.g.settings_wait_q != 0 || o_late !== 1'b0)
				`FAIL(("settings_wait_q = %0d, settings_late_q = %b after a %0d-clock load held in reset",
				       dut.g.settings_wait_q, o_late, LONG))
			@(posedge clk); cart_ready <= 1'b1;
			step(COLD - 500);
			if (bios_setup_ready) `FAIL(("model: standby during the cold init"))
			if (dut.g.settings_wait_q != 0)
				`FAIL(("settings_wait_q = %0d during the BIOS cold init (not standby)", dut.g.settings_wait_q))
			wait_standby(COLD);
			step(8);
			gate_closed_window(2000, "standby after a slow load, nothing from APF yet");
			apf_settings(1'b1, 3'd4);
			gate_closed_window(10000, "JP written, no Reset Exit");
			fast_forward(1'b0, skip);
			gate_closed_window(FF_MARGIN - 8, "the last clocks before the fallback");
			wait_seed(s0, 64, "the fallback");
			check_fallback(skip, s0, "slow load, no Reset Exit");
			wait_boot(b0, 2000, "automatic power-on after the fallback");
			check_boot(JP, 8'h04, "after a slow load");
		end
	endtask

	task automatic t6_g2_hold;
		begin
			begin_scn("T6 G2-HOLD", "a restore clears the stretched press it lands on [G2]");
			s0 = seed_starts; b0 = boots;
			power_up;
			cart_load(LOAD);
			@(posedge clk); cart_ready <= 1'b1;
			wait_standby(COLD + 1000);
			step(8);
			gate_closed_window(3000, "standby, waiting for APF");
			apf_settings(1'b1, 3'd0);
			step(500);
			d0 = seed_starts;
			apf_exit;
			wait_seed(d0, 20, "Reset Exit");
			wait_boot(b0, 2000, "the delayed automatic press");
			check_boot(JP, 8'h00, "after the Reset Exit");
			step(2000);
			if (o_hold !== 1'b1 || o_power_btn !== 1'b1)
				`FAIL(("model: the press is not being held 2000 clocks after the boot (hold %b, power %b)", o_hold, o_power_btn))

			restore_start;                      // boot_hold: the reset net rises now
			@(posedge clk);                     // first edge with reset high
			@(posedge clk); @(negedge clk);
			if (o_reset !== 1'b1) `FAIL(("boot_hold did not raise the machine reset net"))
			if (o_hold !== 1'b0)
				`FAIL(("pwr_hold_q still counting 2 clocks into the restore's reset (G2)"))
			if (o_pending !== 1'b0)
				`FAIL(("auto_pwr_pending_q = %b 2 clocks into the restore's reset (G2)", o_pending))
			if (o_power_btn !== 1'b0) `FAIL(("power still pressed 2 clocks into the restore's reset (G2)"))
			pc0 = pb_clks; p0 = presses;
			step(97);
			restore_end;
			step(20000);
			if (!restored || mst != M_RUN) `FAIL(("model: the restored game is not running"))
			if (pb_clks != pc0)
				`FAIL(("power pressed for %0d clocks after the restore's reset began (G2)", pb_clks - pc0))
			if (run_power != 0) `FAIL(("the restored game saw the power button for %0d clocks (G2)", run_power))
			if (presses != p0) `FAIL(("%0d presses after the restore", presses - p0))
		end
	endtask

	task automatic t7_g2_pending;
		begin
			begin_scn("T7 G2-PENDING", "a restore clears a pending automatic press [G2]");
			s0 = seed_starts; d0 = seed_dones; b0 = boots;
			power_up;
			fork
				cart_load(LOAD);
				begin step(1000); apf_settings(1'b1, 3'd0); end
			join
			// cart_ready stays low: the loader has not finished
			step(200);
			apf_exit;
			wait_standby(COLD + 1000);
			wait_seed_done(d0, 500);
			step(4);
			if (o_pending !== 1'b1)
				`FAIL(("model: no pending automatic press after the seed with the cartridge not ready"))
			if (o_hold !== 1'b0 || o_power_btn !== 1'b0)
				`FAIL(("pressed although the cartridge is not ready"))
			step(1000);
			if (o_pending !== 1'b1) `FAIL(("model: the pending press went away by itself"))

			restore_start;
			@(posedge clk);
			@(posedge clk); @(negedge clk);
			if (o_reset !== 1'b1) `FAIL(("boot_hold did not raise the machine reset net"))
			if (o_pending !== 1'b0)
				`FAIL(("auto_pwr_pending_q still set 2 clocks into the restore's reset (G2)"))
			pc0 = pb_clks; p0 = presses;
			step(97);
			restore_end;
			step(2000);
			@(posedge clk); cart_ready <= 1'b1;
			step(5000);
			if (!restored || mst != M_RUN) `FAIL(("model: the restored game is not running"))
			if (o_pending !== 1'b0) `FAIL(("auto_pwr_pending_q = %b after the restore (G2)", o_pending))
			if (pb_clks != pc0) `FAIL(("power pressed for %0d clocks after the restore (G2)", pb_clks - pc0))
			if (run_power != 0) `FAIL(("the restored game saw the power button for %0d clocks (G2)", run_power))
			if (boots != b0) `FAIL(("model: %0d boots, expected none", boots - b0))
		end
	endtask

	task automatic t8_manual;
		integer k, bad_press, bad_stby;
		reg [31:0] w0;
		begin
			begin_scn("T8 MANUAL", "auto power off: the counter stays still after the Exit [G1, G2]");
			s0 = seed_starts; d0 = seed_dones; b0 = boots;
			@(posedge clk); auto_power <= 1'b0;
			power_up;
			fork
				cart_load(LOAD);
				begin step(1000); apf_settings(1'b1, 3'd2); end
				// G2 on a reset-net term other than boot_hold: a manual press
				// made and released while the load holds the machine in reset
				begin
					step(2000);
					@(posedge clk); pwr_pad <= 1'b1;
					step(100);
					@(posedge clk); pwr_pad <= 1'b0;
				end
			join
			@(negedge clk);
			if (o_hold !== 1'b0 || o_power_btn !== 1'b0)
				`FAIL(("a power press made and released during the cartridge load is still held after it (hold %b, power %b; G2: the machine reset net clears pwr_hold_q)",
				       o_hold, o_power_btn))
			@(posedge clk); cart_ready <= 1'b1;
			step(200);
			apf_exit;
			wait_standby(COLD + 1000);
			wait_seed(s0, 20, "standby after the Reset Exit");
			if (t_seed - t_standby > 3)
				`FAIL(("the seed started %0d clocks after standby, the gate was open", t_seed - t_standby))
			wait_seed_done(d0, 500);
			step(10);
			bad_press = 0; bad_stby = 0;
			@(negedge clk); w0 = dut.g.settings_wait_q;
			for (k = 0; k < 30000; k = k + 1) begin
				@(negedge clk);
				if (o_power_btn !== 1'b0) bad_press = bad_press + 1;
				if (!bios_setup_ready)    bad_stby  = bad_stby + 1;
			end
			if (bad_press != 0) `FAIL(("automatic power is off, yet power was pressed for %0d clocks", bad_press))
			if (bad_stby != 0)  `FAIL(("model: the BIOS left standby for %0d clocks", bad_stby))
			if (dut.g.settings_wait_q != w0)
				`FAIL(("settings_wait_q moved %0d -> %0d in 30k standby clocks after the Reset Exit (G1: only until apf_run_seen_q)",
				       w0, dut.g.settings_wait_q))
			if (o_late !== 1'b0) `FAIL(("settings_late_q = %b after the Reset Exit", o_late))
			if (seed_starts - s0 != 1) `FAIL(("%0d seed runs, expected 1", seed_starts - s0))

			@(posedge clk); pwr_pad <= 1'b1;
			step(100);
			@(posedge clk); pwr_pad <= 1'b0;
			wait_boot(b0, 2000, "manual power press");
			check_boot(JP, 8'h02, "manual power-on");
		end
	endtask

	initial begin
		wait (go);
		case (ID)
			1: t1_doc_order;
			2: t2_late_settings;
			3: t3_no_exit;
			4: t4_sticky;
			5: t5_slow_load;
			6: t6_g2_hold;
			7: t7_g2_pending;
			8: t8_manual;
			default: `FAIL(("no scenario %0d", ID))
		endcase
		step(4);
		if (i1_n > 1) $display("   note [%0s] I1 violated on %0d clocks in all", scn, i1_n);
		if (i2_n > 1) $display("   note [%0s] I2 violated on %0d clocks in all", scn, i2_n);
		if (i3_n > 1) $display("   note [%0s] I3 violated on %0d clocks in all", scn, i3_n);
		if (errors == 0) $display("   PASS %0s", scn);
		else             $display("   FAIL %0s (%0d check(s))", scn, errors);
		done = 1'b1;
	end

endmodule

// ============================================================================
// Top: the scenarios one after another, each from its own power-up
// ============================================================================
module tb_seed_gate;

	localparam integer N = 8;

	reg  [N:1] go = {N{1'b0}};
	wire [N:1] done;

	seed_gate_harness #(.ID(1)) t1 (.go(go[1]), .done(done[1]));
	seed_gate_harness #(.ID(2)) t2 (.go(go[2]), .done(done[2]));
	seed_gate_harness #(.ID(3)) t3 (.go(go[3]), .done(done[3]));
	seed_gate_harness #(.ID(4)) t4 (.go(go[4]), .done(done[4]));
	seed_gate_harness #(.ID(5)) t5 (.go(go[5]), .done(done[5]));
	seed_gate_harness #(.ID(6)) t6 (.go(go[6]), .done(done[6]));
	seed_gate_harness #(.ID(7)) t7 (.go(go[7]), .done(done[7]));
	seed_gate_harness #(.ID(8)) t8 (.go(go[8]), .done(done[8]));

	function integer errs(input integer k);
		case (k)
			1: errs = t1.errors;
			2: errs = t2.errors;
			3: errs = t3.errors;
			4: errs = t4.errors;
			5: errs = t5.errors;
			6: errs = t6.errors;
			7: errs = t7.errors;
			8: errs = t8.errors;
			default: errs = 1;
		endcase
	endfunction

	integer i = 0, errors = 0, n_fail = 0;

	initial begin
`ifdef SEED_GATE_FULL
		$display("== seed gate bench, FULL: T3 counts all 2^27 standby clocks, T5 fast-forwards");
`else
		$display("== seed gate bench, fast: settings_wait_q fast-forwarded to its last %0d clocks", 256);
`endif
		for (i = 1; i <= N; i = i + 1) begin
			go[i] = 1'b1;
			wait (done[i]);
			errors = errors + errs(i);
			if (errs(i) != 0) n_fail = n_fail + 1;
		end
		$display("== %0d scenario(s), %0d failed, %0.1f ms simulated", N, n_fail, $realtime / 1.0e6);
		if (errors == 0) $display("== ALL SEED-GATE SCENARIOS PASS");
		else             $display("== %0d FAILURE(S)", errors);
		$finish;
	end

	initial begin
`ifdef SEED_GATE_FULL
		#(4.0e9);
`else
		#(200.0e6);
`endif
		$display("== WATCHDOG TIMEOUT in T%0d", i);
		$display("== %0d FAILURE(S)", errors + errs(i) + 1);
		$finish;
	end

endmodule

`default_nettype wire
