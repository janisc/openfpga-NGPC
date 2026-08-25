// NGPC for Analogue Pocket -- machine wrapper.
//
// This is the Pocket's answer to NGPC.sv. It keeps the machine-side logic of
// the MiSTer top level (reset sequencing, BIOS load, strap, power button, BIOS
// setup seeding) and drops everything that only existed to talk to MiSTer's
// framework: hps_io, CONF_STR, the DDR3 clients, video_mixer/video_freak, and
// the HPS UART link.
//
// Signal names and comments are kept close to NGPC.sv on purpose. When
// upstream changes its reset or power rules, the corresponding block here
// should be recognisably the same code so the change can be carried across.
//
// PHASE 1 SCOPE. No cartridge, no SDRAM, no savestates. The machine boots its
// BIOS with the cartridge slot reported empty, which the stock BIOS treats as
// a valid launch target -- it is how the built-in utilities are reached. The
// cartridge backing store, .sav persistence and the savestate/sleep path are
// separate, later steps; the ports they will need are marked below.

`default_nettype none

module ngpc_machine
(
	input  wire        clk_sys,          // 49.152 MHz
	input  wire        reset_in,         // async system reset (PLL unlocked / core reset)

	// ---- Settings ---------------------------------------------------------
	// All of these arrive from APF bridge registers and are already stable in
	// clk_sys. They are the subset of the MiSTer CONF_STR that affects the
	// machine rather than the framework's scaler.
	input  wire [1:0]  opt_system,       // 0 = NGPC, 1 = Auto, 2 = NGP        (status[2:1])
	input  wire        opt_language_jp,  //                                    (status[3])
	input  wire [2:0]  opt_palette,      // mono palette                       (status[16:14])
	input  wire        opt_skip_anim,    // 1 = skip the BIOS eye-catch        (!status[19])
	input  wire        opt_use_host_rtc, //                                    (!status[17])
	input  wire        opt_auto_power,   // 1 = power on automatically         (status[18])
	input  wire        opt_lcd_response, // panel response (accepted, unused)  (status[20])

	// ---- BIOS load --------------------------------------------------------
	input  wire        bios_downloading, // held across the whole transfer
	input  wire        bios_sel,         // 0 = colour (boot0), 1 = mono (boot1)
	input  wire        bios_wr,
	input  wire [14:0] bios_addr,        // word address inside the 64 KiB image
	input  wire [15:0] bios_data,

	// ---- Host wall clock --------------------------------------------------
	// Same packet shape ngp_host_clock consumes on MiSTer; the top level builds
	// it from APF's RTC host command.
	input  wire [64:0] hps_rtc,

	// ---- Controls ---------------------------------------------------------
	// Active high, in the MiSTer joystick_0 bit order the upstream comment
	// documents: 0 Right, 1 Left, 2 Down, 3 Up, 4 A, 5 B, 6 Option, 7 Power.
	input  wire [7:0]  joystick,

	// ---- Video ------------------------------------------------------------
	output wire        ce_pix,           // one pulse per latched pixel
	output wire [7:0]  vga_r,
	output wire [7:0]  vga_g,
	output wire [7:0]  vga_b,
	output wire        vga_de,
	output wire        vga_hs,
	output wire        vga_vs,
	output wire        vga_hbl,
	output wire        vga_vbl,

	// ---- Audio ------------------------------------------------------------
	output wire [15:0] audio_l,
	output wire [15:0] audio_r,

	output wire        led_user
);

	//////////////////////////////// Reset ///////////////////////////////////

	// Reset is extended across a BIOS download so the first fetch cannot race
	// the loader's final BRAM write. The power button is NOT reset: it is the
	// NMI/standby flow, and on this machine "power" and "reset" are emphatically
	// different things.
	localparam [7:0] BIOS_RESET_TAIL = 8'hFF;

	wire hard_reset = reset_in;

	reg [7:0] bios_reset_cnt;

	always @(posedge clk_sys) begin
		if (hard_reset || bios_downloading) bios_reset_cnt <= BIOS_RESET_TAIL;
		else if (bios_reset_cnt != 8'd0)    bios_reset_cnt <= bios_reset_cnt - 8'd1;
	end

	wire bios_reset = bios_downloading || (bios_reset_cnt != 8'd0);
	wire reset      = hard_reset | bios_reset;

	//////////////////////////////// Inputs //////////////////////////////////

	// `btn` is ACTIVE HIGH here. The board inverts it to the pads' active-low
	// SWCOM wiring, so do not invert twice.
	wire [6:0] btn;
	assign btn[0] = joystick[3];                    // Up
	assign btn[1] = joystick[2];                    // Down
	assign btn[2] = joystick[1];                    // Left
	assign btn[3] = joystick[0];                    // Right
	assign btn[4] = joystick[4];                    // A
	assign btn[5] = joystick[5];                    // B
	assign btn[6] = joystick[6];                    // Option

	// The power press is held, never pulsed: the BIOS hold gate at 0xFF1A45
	// runs 40 iterations and a single read of "released" aborts the boot back
	// to power-off, so an unstretched tap looks like a machine ignoring its
	// power button. 24 frames clears every reading of that gate.
	localparam [24:0] PWR_HOLD_CLKS = 25'd19_677_144; // 24 frames at 59.9503 Hz

	reg  [24:0] pwr_hold_q;
	reg         auto_pwr_pending_q;

	wire pwr_pad = joystick[7];
	wire seed_done;
	wire bios_setup_ready;

	// With no cartridge the launch target is always ready: an empty slot is how
	// the stock BIOS reaches its built-in utilities. A download still blocks the
	// press so it cannot race a transfer.
	wire launch_target_ready = !bios_downloading;
	wire auto_pwr = auto_pwr_pending_q && bios_setup_ready && launch_target_ready;

	always @(posedge clk_sys) begin
		if (hard_reset) begin
			pwr_hold_q         <= 25'd0;
			auto_pwr_pending_q <= 1'b0;
		end else begin
			if (pwr_pad || auto_pwr)          pwr_hold_q <= PWR_HOLD_CLKS;
			else if (pwr_hold_q != 25'd0)     pwr_hold_q <= pwr_hold_q - 25'd1;

			// Remember a completed setup and wake once both sides are ready. A
			// manual press cancels the pending automatic press so a later load
			// cannot turn an already-running machine back off.
			if (!opt_auto_power || pwr_pad || auto_pwr) auto_pwr_pending_q <= 1'b0;
			else if (seed_done)                         auto_pwr_pending_q <= 1'b1;
		end
	end

	wire power_btn = pwr_pad || (pwr_hold_q != 25'd0);

	// System select. 0 = NGPC (colour), 1 = Auto, 2 = NGP (mono). With no
	// cartridge there is no extension to infer from, so Auto resolves to
	// colour. k2_soc latches mono_strap while reset is asserted.
	wire mono_strap = (opt_system == 2'd2);

	//////////////////////////// BIOS setup seed /////////////////////////////

	// `ce` is tied high ON PURPOSE. This is host time, not machine state: it is
	// deliberately outside the pause tree, outside the savestate layout and
	// outside reset.
	wire [64:0] host_rtc;

	ngp_host_clock host_clock
	(
		.clk      (clk_sys),
		.ce       (1'b1),
		.hps_rtc  (hps_rtc),
		.host_rtc (host_rtc)
	);

	wire        bios_mono_active;
	wire  [9:0] seed_ss_bus_adr;
	wire [63:0] seed_ss_bus_din;
	wire        seed_ss_bus_wren;
	wire  [1:0] seed_ss_mem_type;
	wire        seed_ss_mem_active;
	wire [13:0] seed_ss_mem_addr;
	wire  [7:0] seed_ss_mem_wdata;
	wire        seed_ss_mem_wren;
	wire        seed_ss_mem_rden;
	wire        seed_pause_req;
	wire        seed_busy;
	wire        pause_ready;
	wire [63:0] ss_bus_dout;
	wire  [7:0] ss_mem_rdata;

	ngp_setup_seed setup_seed
	(
		.clk                    (clk_sys),
		.reset                  (reset),
		.setup_ready            (bios_setup_ready),
		.mono                   (bios_mono_active),
		.osd_language_japanese  (opt_language_jp),
		.osd_palette            (opt_palette),
		.use_hps_rtc            (opt_use_host_rtc),
		.hps_rtc                (host_rtc),
		.skip_bios_animation    (opt_skip_anim),
		// No cartridge: the seed engine has no header to copy forward.
		.cart_header_valid      (1'b0),
		.cart_catalog           (16'd0),
		.cart_subcatalog        (8'd0),
		.cart_title             (96'd0),
		.pause_req              (seed_pause_req),
		.pause_ready            (pause_ready),
		.ss_bus_adr             (seed_ss_bus_adr),
		.ss_bus_din             (seed_ss_bus_din),
		.ss_bus_wren            (seed_ss_bus_wren),
		.ss_mem_type            (seed_ss_mem_type),
		.ss_mem_active          (seed_ss_mem_active),
		.ss_mem_addr            (seed_ss_mem_addr),
		.ss_mem_wdata           (seed_ss_mem_wdata),
		.ss_mem_wren            (seed_ss_mem_wren),
		.ss_mem_rden            (seed_ss_mem_rden),
		.seed_busy              (seed_busy),
		.seed_done              (seed_done)
	);

	///////////////////////// The machine: mainboard //////////////////////////

	// The link port has no host on the Pocket. TMP95C061 Port 8 pulls P81/RXD0
	// and P82/CTS0 high (datasheet pp.41-42), so an absent cable is RXD at
	// mark/idle and active-low CTS deasserted -- which is what a disabled or
	// mismatched host looks like electrically.
	localparam [0:0] LINK_RXD_UNPLUGGED   = 1'b1;
	localparam [0:0] LINK_CTS_N_UNPLUGGED = 1'b1;

	wire link_txd, link_rts_n;

	// PHASE 2 will drive these from the cartridge backing store in SDRAM.
	wire        cart_mem_req;
	wire        cart_mem_we;
	wire [24:0] cart_mem_addr;
	wire [15:0] cart_mem_wdata;
	wire  [1:0] cart_mem_be;
	wire        cart_mem_lane;
	wire  [1:0] cart_mem_tag;
	wire        cart_mem_flash;

	ngp_mainboard mainboard
	(
		.clk_sys              (clk_sys),
		.reset                (reset),
		.restore_reset        (1'b0),
		.mono_strap           (mono_strap),
		.lcd_persistence      (opt_lcd_response),
		.palette_frame_boundary (1'b0),

		.ce_pix               (ce_pix),
		.vga_r                (vga_r),
		.vga_g                (vga_g),
		.vga_b                (vga_b),
		.hsync                (vga_hs),
		.vsync                (vga_vs),
		.hblank               (vga_hbl),
		.vblank               (vga_vbl),

		.audio_l              (audio_l),
		.audio_r              (audio_r),

		.btn                  (btn),
		.power_btn            (power_btn),

		.link_txd             (link_txd),
		.link_rxd             (LINK_RXD_UNPLUGGED),
		.link_rts_n           (link_rts_n),
		.link_cts_n           (LINK_CTS_N_UNPLUGGED),

		.led_user             (led_user),

		.bios_setup_ready     (bios_setup_ready),
		.bios_mono_active     (bios_mono_active),
		.bios_wr              (bios_wr),
		.bios_sel             (bios_sel),
		.bios_addr            (bios_addr),
		.bios_data            (bios_data),
		.skip_bios_animation  (opt_skip_anim),

		// Cheats are a MiSTer file format; not carried to the Pocket.
		.cheat_load_begin     (1'b0),
		.cheat_invalidate     (1'b0),
		.cheat_commit_req     (1'b0),
		.cheat_commit_done    (),
		.cheat_code           (128'd0),

		// ---- Cartridge: empty slot (PHASE 2) --------------------------------
		.cart_image_bytes     (25'd0),
		.cart_config_load     (1'b0),
		.cart_force_8m_die0   (1'b0),
		.cart_force_flash_read(1'b0),
		// These four are mainboard OUTPUTS -- the board derives them from
		// cart_image_bytes and cart_config_load. With no image loaded it
		// reports an empty slot on its own; leave them open rather than
		// tying them off, which would read as an attempt to drive them.
		.cart_size_code0      (),
		.cart_size_code1      (),
		.cart_bytes           (),
		.cart_present         (),
		.cart_mem_req         (cart_mem_req),
		.cart_mem_we          (cart_mem_we),
		.cart_mem_addr        (cart_mem_addr),
		.cart_mem_wdata       (cart_mem_wdata),
		.cart_mem_be          (cart_mem_be),
		.cart_mem_lane        (cart_mem_lane),
		.cart_mem_tag         (cart_mem_tag),
		.cart_mem_flash       (cart_mem_flash),
		.cart_mem_rdata       (16'd0),
		.cart_mem_rvalid      (1'b0),
		.cart_mem_done        (1'b0),
		.cart_dirty_pulse     (),
		.cart_dirty0          (),
		.cart_dirty1          (),
		.cart_dirty0_event    (),
		.cart_dirty0_block    (),
		.cart_dirty1_event    (),
		.cart_dirty1_block    (),
		.cart_dirty_clear     (1'b0),
		.cart_flash_busy      (),
		.cart_die_busy        (),

		// ---- Savestate buses: seed only (PHASE 4 adds the engine) -----------
		.ss_bus_adr           (seed_ss_bus_adr),
		.ss_bus_din           (seed_ss_bus_din),
		.ss_bus_wren          (seed_ss_bus_wren),
		.ss_bus_rst           (1'b0),
		.ss_restore_is_rewind (1'b0),
		.ss_bus_dout          (ss_bus_dout),
		.ss_mem_type          (seed_ss_mem_type),
		.ss_mem_active        (seed_ss_mem_active),
		.ss_mem_addr          (seed_ss_mem_addr),
		.ss_mem_wdata         (seed_ss_mem_wdata),
		.ss_mem_wren          (seed_ss_mem_wren),
		.ss_mem_rden          (seed_ss_mem_rden),
		.ss_mem_rdata         (ss_mem_rdata),
		.loading_savestate    (1'b0),

		.pause_req            (seed_pause_req),
		.pause_ready          (pause_ready)
	);

	assign vga_de = ~(vga_hbl | vga_vbl);

	wire unused_ok = &{1'b0, link_txd, link_rts_n, seed_busy, ss_bus_dout,
	                   ss_mem_rdata, cart_mem_req, cart_mem_we, cart_mem_addr,
	                   cart_mem_wdata, cart_mem_be, cart_mem_lane, cart_mem_tag,
	                   cart_mem_flash, 1'b0};

endmodule

`default_nettype wire
