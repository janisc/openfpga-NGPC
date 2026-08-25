// NGPC for Analogue Pocket -- machine wrapper.
//
// This is the Pocket's answer to NGPC.sv. It keeps the machine-side logic of
// the MiSTer top level (reset sequencing, BIOS load, strap, power button, BIOS
// setup seeding, the cartridge loader and its SDRAM backing store) and drops
// everything that only existed to talk to MiSTer's framework: hps_io, CONF_STR,
// the DDR3 clients, video_mixer/video_freak, and the HPS UART.
//
// Signal names and comments are kept close to NGPC.sv on purpose. When upstream
// changes its reset or power rules, the corresponding block here should be
// recognisably the same code so the change can be carried across.
//
// PHASE 2 SCOPE. Cartridges load and run. Not here yet: .sav persistence (the
// pristine shadow and sparse overlay MiSTer keeps in DDR3) and savestates.
// Ports for those are marked below.

`default_nettype none

module ngpc_machine
(
	input  wire        clk_sys,          // 49.152 MHz
	input  wire        clk_ram,          // 98.304 MHz, SDRAM command clock
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

	// ---- Cartridge load ---------------------------------------------------
	input  wire        cart_downloading, // held across the whole transfer
	input  wire        cart_wr,
	input  wire [26:0] cart_wr_addr,     // byte address within the image
	input  wire [15:0] cart_wr_data,
	output wire        cart_fifo_overflow, // diagnostic, see ngpc_cart_fifo

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

	// ---- SDRAM ------------------------------------------------------------
	// The Pocket has no chip-select pin; CS is tied low on the board, so every
	// clock is a live command. That is safe with this controller because its
	// only nCS-high encoding is CMD_DESELECT (4'b1111), which also drives
	// RAS/CAS/WE high -- with CS forced low the device reads it as a NOP.
	output wire [12:0] SDRAM_A,
	output wire  [1:0] SDRAM_BA,
	inout  wire [15:0] SDRAM_DQ,
	output wire        SDRAM_DQML,
	output wire        SDRAM_DQMH,
	output wire        SDRAM_CKE,
	output wire        SDRAM_CLK,
	output wire        SDRAM_nCAS,
	output wire        SDRAM_nRAS,
	output wire        SDRAM_nWE,

	output wire        led_user
);

	//////////////////////////////// Reset ///////////////////////////////////

	// Reset is extended across a BIOS download so the first fetch cannot race
	// the loader's final BRAM write. A cartridge download defines a
	// deterministic cold session: hold the machine in reset, clear all 12 KiB
	// of work RAM through its existing port B, then let the selected BIOS
	// cold-initialize that blank bank.
	//
	// The power button is NOT reset. It is the NMI/standby flow, and on this
	// machine "power" and "reset" are emphatically different things.
	//
	// The cartridge loader and its SDRAM backing store sit OUTSIDE the machine
	// reset. A soft reset is a console reset, not a cartridge removal.
	localparam [7:0] BIOS_RESET_TAIL = 8'hFF;

	wire hard_reset = reset_in;

	reg [7:0] bios_reset_cnt;

	always @(posedge clk_sys) begin
		if (hard_reset || bios_downloading) bios_reset_cnt <= BIOS_RESET_TAIL;
		else if (bios_reset_cnt != 8'd0)    bios_reset_cnt <= bios_reset_cnt - 8'd1;
	end

	wire bios_reset = bios_downloading || (bios_reset_cnt != 8'd0);
	wire base_reset = hard_reset | bios_reset;

	wire        cart_download;
	wire        cart_download_start;
	wire        wram_clear_busy;
	wire        wram_clear_done;
	wire  [1:0] clear_ss_mem_type;
	wire        clear_ss_mem_active;
	wire [13:0] clear_ss_mem_addr;
	wire  [7:0] clear_ss_mem_wdata;
	wire        clear_ss_mem_wren;
	wire        clear_ss_mem_rden;

	ngp_wram_clear wram_clear
	(
		.clk           (clk_sys),
		.reset         (hard_reset),
		.start         (cart_download_start),
		.busy          (wram_clear_busy),
		.done          (wram_clear_done),
		.ss_mem_type   (clear_ss_mem_type),
		.ss_mem_active (clear_ss_mem_active),
		.ss_mem_addr   (clear_ss_mem_addr),
		.ss_mem_wdata  (clear_ss_mem_wdata),
		.ss_mem_wren   (clear_ss_mem_wren),
		.ss_mem_rden   (clear_ss_mem_rden)
	);

	// cart_download asserts before the clear start pulse, so the CPU cannot get
	// one running edge ahead of the walker.
	wire reset = base_reset | cart_download | wram_clear_busy;

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
	wire cart_present;
	wire cart_ready;

	// No cartridge is a valid launch target: it is how the stock BIOS reaches
	// its built-in utilities. A present cartridge must finish loading first,
	// and any active download blocks both cases so the press cannot race a
	// transfer.
	wire launch_target_ready = !cart_download && !bios_downloading &&
	                           (!cart_present || cart_ready);
	wire auto_pwr = auto_pwr_pending_q && bios_setup_ready && launch_target_ready;

	always @(posedge clk_sys) begin
		if (hard_reset || cart_download_start) begin
			pwr_hold_q         <= 25'd0;
			auto_pwr_pending_q <= 1'b0;
		end else begin
			if (pwr_pad || auto_pwr)      pwr_hold_q <= PWR_HOLD_CLKS;
			else if (pwr_hold_q != 25'd0) pwr_hold_q <= pwr_hold_q - 25'd1;

			// Remember a completed setup and wake once both sides are ready. A
			// manual press cancels the pending automatic press so a later
			// cartridge load cannot turn an already-running machine back off.
			if (!opt_auto_power || pwr_pad || auto_pwr) auto_pwr_pending_q <= 1'b0;
			else if (seed_done)                         auto_pwr_pending_q <= 1'b1;
		end
	end

	wire power_btn = pwr_pad || (pwr_hold_q != 25'd0);

	// System select. 0 = NGPC (colour), 1 = Auto, 2 = NGP (mono).
	//
	// MiSTer resolves Auto from the file extension, which it learns from
	// ioctl_index. APF does not tell a core which of a slot's extensions
	// matched, so Auto resolves to colour here and a mono-only title needs the
	// explicit menu choice. Recovering the extension would mean asking APF for
	// the slot's filename (target command 0x0190) and parsing it, which is a
	// job of its own.
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
	wire        cart_header_valid;
	wire [15:0] cart_header_catalog;
	wire  [7:0] cart_header_subcatalog;
	wire [95:0] cart_header_title;

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
		.cart_header_valid      (cart_header_valid),
		.cart_catalog           (cart_header_catalog),
		.cart_subcatalog        (cart_header_subcatalog),
		.cart_title             (cart_header_title),
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

	// The work-RAM clear walker and the seed engine share the machine's
	// savestate memory port. The walker wins while it runs; the savestate
	// engine will join this mux in phase 4.
	wire  [1:0] mb_ss_mem_type   = wram_clear_busy ? clear_ss_mem_type   : seed_ss_mem_type;
	wire        mb_ss_mem_active = wram_clear_busy ? clear_ss_mem_active : seed_ss_mem_active;
	wire [13:0] mb_ss_mem_addr   = wram_clear_busy ? clear_ss_mem_addr   : seed_ss_mem_addr;
	wire  [7:0] mb_ss_mem_wdata  = wram_clear_busy ? clear_ss_mem_wdata  : seed_ss_mem_wdata;
	wire        mb_ss_mem_wren   = wram_clear_busy ? clear_ss_mem_wren   : seed_ss_mem_wren;
	wire        mb_ss_mem_rden   = wram_clear_busy ? clear_ss_mem_rden   : seed_ss_mem_rden;

	//////////////////// Cartridge backing store and loader //////////////////

	wire        cart_load_req;
	wire [24:0] cart_load_addr;
	wire [15:0] cart_load_data;
	wire        cart_load_ready;
	wire        cart_load_done;

	wire [24:0] cart_image_bytes;
	wire [31:0] cart_image_crc32;
	wire        cart_loader_config;
	wire [24:0] cart_bytes;
	wire  [1:0] cart_size_code0;
	wire  [1:0] cart_size_code1;

	// ngp_cart_rom stalls its producer, and APF cannot be stalled. See
	// ngpc_cart_fifo.
	wire        cart_ioctl_wait;
	wire        cart_ioctl_wr;
	wire [26:0] cart_ioctl_addr;
	wire [15:0] cart_ioctl_dout;

	ngpc_cart_fifo cart_fifo
	(
		.clk        (clk_sys),
		.reset      (hard_reset),

		.wr_i       (cart_wr),
		.addr_i     (cart_wr_addr),
		.data_i     (cart_wr_data),

		.wait_i     (cart_ioctl_wait),
		.wr_o       (cart_ioctl_wr),
		.addr_o     (cart_ioctl_addr),
		.data_o     (cart_ioctl_dout),

		.overflow_o (cart_fifo_overflow)
	);

	// The loader makes its own ioctl_index[5:0] == 1 comparison internally, so
	// it is handed the index MiSTer would have used for the cartridge slot.
	ngp_cart_rom cart_loader
	(
		.clk_sys               (clk_sys),
		.reset_i               (hard_reset),

		.ioctl_download_i      (cart_downloading),
		.ioctl_wr_i            (cart_ioctl_wr),
		.ioctl_addr_i          (cart_ioctl_addr),
		.ioctl_dout_i          (cart_ioctl_dout),
		.ioctl_index_i         (16'd1),
		.ioctl_wait_o          (cart_ioctl_wait),

		.load_req_o            (cart_load_req),
		.load_addr_o           (cart_load_addr),
		.load_data_o           (cart_load_data),
		.load_ready_i          (cart_load_ready),
		.load_done_i           (cart_load_done),

		.image_bytes_o         (cart_image_bytes),
		.image_crc32_o         (cart_image_crc32),
		.config_load_o         (cart_loader_config),
		.cart_bytes_i          (cart_bytes),
		.header_valid_o        (cart_header_valid),
		.header_catalog_o      (cart_header_catalog),
		.header_subcatalog_o   (cart_header_subcatalog),
		.header_title_o        (cart_header_title),
		.cart_download_o       (cart_download),
		.cart_download_start_o (cart_download_start),
		.cart_ready_o          (cart_ready)
	);

	// Original Delta Warp is a 512-KiB dump whose retail code writes 8-Mbit
	// blocks 16/17. Match all header identity bytes before overriding geometry.
	wire cart_force_8m_die0 = cart_header_valid &&
		(cart_image_bytes == 25'h080000) &&
		(cart_header_catalog == 16'h0103) &&
		(cart_header_subcatalog == 8'h05) &&
		(cart_header_title[7:0]   == 8'h44) && // D
		(cart_header_title[15:8]  == 8'h45) && // E
		(cart_header_title[23:16] == 8'h4C) && // L
		(cart_header_title[31:24] == 8'h54) && // T
		(cart_header_title[39:32] == 8'h41) && // A
		(cart_header_title[47:40] == 8'h20);   // space

	// A machine reset clears ngp_cart's die population, but the loader and the
	// SDRAM image survive it because they sit on hard_reset. Re-strap the board
	// from the retained byte count once the machine reset releases, so a
	// cartridge does not disappear when the user hits Reset.
	reg [3:0] cart_reconfig_q;

	always @(posedge clk_sys) begin
		if (reset) cart_reconfig_q <= 4'd8;
		else if (cart_reconfig_q != 4'd0) cart_reconfig_q <= cart_reconfig_q - 4'd1;
	end

	wire cart_config_load = cart_loader_config || (!reset && (cart_reconfig_q != 4'd0));

	wire        cart_mem_req;
	wire        cart_mem_we;
	wire [24:0] cart_mem_addr;
	wire [15:0] cart_mem_wdata;
	wire  [1:0] cart_mem_be;
	wire        cart_mem_lane;
	wire  [1:0] cart_mem_tag;
	wire        cart_mem_flash;
	wire [15:0] cart_mem_rdata;
	wire        cart_mem_rvalid;
	wire        cart_mem_done;

	// PHASE 3 will put the pristine shadow and the sparse overlay on the
	// background port. Until then it is idle: MiSTer keeps those in DDR3, and
	// the Pocket's plan is a second region of this same 64 MB chip.
	ngp_cart_sdram #(.CLK_FREQ_HZ(98_304_000)) cart_sdram
	(
		.clk_sys      (clk_sys),
		.clk_ram      (clk_ram),
		.reset_i      (hard_reset),

		.mem_req_i    (cart_mem_req),
		.mem_we_i     (cart_mem_we),
		.mem_addr_i   (cart_mem_addr),
		.mem_wdata_i  (cart_mem_wdata),
		.mem_be_i     (cart_mem_be),
		.mem_lane_i   (cart_mem_lane),
		.mem_tag_i    (cart_mem_tag[0]),
		.mem_flash_i  (cart_mem_flash),
		.mem_rdata_o  (cart_mem_rdata),
		.mem_rvalid_o (cart_mem_rvalid),
		.mem_done_o   (cart_mem_done),

		.load_req_i   (cart_load_req),
		.load_addr_i  (cart_load_addr),
		.load_data_i  (cart_load_data),
		.load_ready_o (cart_load_ready),
		.load_done_o  (cart_load_done),

		.bg_req_i     (1'b0),
		.bg_we_i      (1'b0),
		.bg_addr_i    (25'd0),
		.bg_wdata_i   (16'd0),
		.bg_be_i      (2'd0),
		.bg_ready_o   (),
		.bg_done_o    (),
		.bg_rdata_o   (),

		.SDRAM_A      (SDRAM_A),
		.SDRAM_BA     (SDRAM_BA),
		.SDRAM_DQ     (SDRAM_DQ),
		.SDRAM_DQML   (SDRAM_DQML),
		.SDRAM_DQMH   (SDRAM_DQMH),
		.SDRAM_CKE    (SDRAM_CKE),
		.SDRAM_CLK    (SDRAM_CLK),
		.SDRAM_nCS    (),
		.SDRAM_nCAS   (SDRAM_nCAS),
		.SDRAM_nRAS   (SDRAM_nRAS),
		.SDRAM_nWE    (SDRAM_nWE)
	);

	///////////////////////// The machine: mainboard //////////////////////////

	// The link port has no host on the Pocket. TMP95C061 Port 8 pulls P81/RXD0
	// and P82/CTS0 high (datasheet pp.41-42), so an absent cable is RXD at
	// mark/idle and active-low CTS deasserted -- which is what a disabled or
	// mismatched host looks like electrically.
	localparam [0:0] LINK_RXD_UNPLUGGED   = 1'b1;
	localparam [0:0] LINK_CTS_N_UNPLUGGED = 1'b1;

	wire link_txd, link_rts_n;

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

		.cart_image_bytes     (cart_image_bytes),
		.cart_config_load     (cart_config_load),
		.cart_force_8m_die0   (cart_force_8m_die0),
		.cart_force_flash_read(1'b0),
		.cart_size_code0      (cart_size_code0),
		.cart_size_code1      (cart_size_code1),
		.cart_bytes           (cart_bytes),
		.cart_present         (cart_present),
		.cart_mem_req         (cart_mem_req),
		.cart_mem_we          (cart_mem_we),
		.cart_mem_addr        (cart_mem_addr),
		.cart_mem_wdata       (cart_mem_wdata),
		.cart_mem_be          (cart_mem_be),
		.cart_mem_lane        (cart_mem_lane),
		.cart_mem_tag         (cart_mem_tag),
		.cart_mem_flash       (cart_mem_flash),
		.cart_mem_rdata       (cart_mem_rdata),
		.cart_mem_rvalid      (cart_mem_rvalid),
		.cart_mem_done        (cart_mem_done),

		// Flash-write bookkeeping feeds .sav persistence, which is phase 3.
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

		// ---- Savestate buses: seed and the RAM clear (PHASE 4 adds the engine)
		.ss_bus_adr           (seed_ss_bus_adr),
		.ss_bus_din           (seed_ss_bus_din),
		.ss_bus_wren          (seed_ss_bus_wren),
		.ss_bus_rst           (1'b0),
		.ss_restore_is_rewind (1'b0),
		.ss_bus_dout          (ss_bus_dout),
		.ss_mem_type          (mb_ss_mem_type),
		.ss_mem_active        (mb_ss_mem_active),
		.ss_mem_addr          (mb_ss_mem_addr),
		.ss_mem_wdata         (mb_ss_mem_wdata),
		.ss_mem_wren          (mb_ss_mem_wren),
		.ss_mem_rden          (mb_ss_mem_rden),
		.ss_mem_rdata         (ss_mem_rdata),
		.loading_savestate    (1'b0),

		.pause_req            (seed_pause_req),
		.pause_ready          (pause_ready)
	);

	assign vga_de = ~(vga_hbl | vga_vbl);

	wire unused_ok = &{1'b0, link_txd, link_rts_n, seed_busy, ss_bus_dout,
	                   ss_mem_rdata, cart_image_crc32, cart_size_code0,
	                   cart_size_code1, wram_clear_done, 1'b0};

endmodule

`default_nettype wire
