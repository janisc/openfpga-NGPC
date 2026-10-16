// One complete NGPC for simulation: the mainboard, the BIOS setup seed and the
// automatic power press as ngpc_machine has them, the link transport, and
// behavioural stand-ins for what the Pocket supplies -- the BIOS loader and the
// cartridge backing store (one flat byte array behind ngp_cart's mem_* mailbox).
//
// Images come from hex files, one byte per line:
//   +bios=<file>        the colour BIOS, shared by every machine
//   +<CART_ARG>=<file>  this machine's cartridge, and +<CART_ARG>_bytes=<n>
//
// The BIOS is written while reset is held, then reset releases, ngp_cart is
// strapped from the image size, the BIOS cold-starts into standby, the seed
// writes the setup a first boot would have made (English, colour, animation
// skipped) and the power button is held for 24 frames, exactly as on the
// Pocket.

module ngpc_sim_machine
#(
	parameter string CART_ARG = "cart0"
)
(
	input  wire        clk_sys,
	input  wire        reset,         // hold until the images are loaded

	input  wire [6:0]  btn,           // Up Down Left Right A B Option, active high

	input  wire [1:0]  link_mode,      // 0 off, 1 GBC cable, 2 GBA cable
	input  wire        link_si,
	output wire        link_so,
	output wire        link_so_oe,
	input  wire        link_so_pin,
	output wire        link_sd,
	output wire        link_sd_oe,
	input  wire        link_sd_pin,
	output wire        link_present,

	output wire        ce_pix,
	output wire [7:0]  vga_r,
	output wire [7:0]  vga_g,
	output wire [7:0]  vga_b,
	output wire        hblank,
	output wire        vblank,

	output wire        bios_loaded,
	output wire        powered       // the seed has run and the power press started
);

	// ---- images -------------------------------------------------------------
	logic [7:0]  bios_img [0:65535];
	logic [7:0]  cart [0:(1 << 22) - 1];
	logic [24:0] cart_bytes_cfg = 25'd0;

	initial begin
		string f;
		int    n;
		for (int i = 0; i < (1 << 22); i++) cart[i] = 8'hFF;   // blank flash
		if ($value$plusargs("bios=%s", f)) $readmemh(f, bios_img);
		if ($value$plusargs({CART_ARG, "=%s"}, f)) $readmemh(f, cart);
		if ($value$plusargs({CART_ARG, "_bytes=%d"}, n)) cart_bytes_cfg = 25'(n);
	end

	// ---- BIOS loader: 32 K words while reset is held ----------------------
	reg  [15:0] ld_idx = 16'd0;
	wire        ld_busy = (ld_idx != 16'h8000);
	assign bios_loaded = !ld_busy;

	always @(posedge clk_sys) if (ld_busy) ld_idx <= ld_idx + 16'd1;

	wire        bios_wr   = ld_busy;
	wire [14:0] bios_addr = ld_idx[14:0];
	wire [15:0] bios_data = {bios_img[{ld_idx[14:0], 1'b1}], bios_img[{ld_idx[14:0], 1'b0}]};

	wire        machine_reset = reset || ld_busy;

	// ---- cartridge strap: eight config strobes after reset, as ngpc_machine
	reg  [3:0]  cfg_q = 4'd0;
	always @(posedge clk_sys)
		if (machine_reset)    cfg_q <= 4'd8;
		else if (cfg_q != 0)  cfg_q <= cfg_q - 4'd1;
	wire cart_config_load = !machine_reset && (cfg_q != 4'd0);

	// ---- cartridge backing store behind ngp_cart's mailbox -----------------
	wire        cart_mem_req, cart_mem_we, cart_mem_lane, cart_mem_tag, cart_mem_flash;
	wire [24:0] cart_mem_addr;
	wire [15:0] cart_mem_wdata;
	wire [1:0]  cart_mem_be;
	reg  [15:0] cart_mem_rdata = 16'hFFFF;
	reg         cart_mem_rvalid = 1'b0;
	reg         cart_mem_done = 1'b0;

	// One transaction per request edge or tag change; answered after a few
	// cycles like the SDRAM service, payload taken while it is held stable.
	reg         served = 1'b0;
	reg         served_tag = 1'b0;
	reg  [2:0]  lat = 3'd0;
	wire [21:0] ca = cart_mem_addr[21:0];

	always @(posedge clk_sys) begin
		cart_mem_rvalid <= 1'b0;
		cart_mem_done   <= 1'b0;
		if (!cart_mem_req) begin
			served <= 1'b0;
			lat    <= 3'd0;
		end else if (!(served && served_tag == cart_mem_tag) && !cart_mem_done) begin
			if (lat != 3'd5) begin
				lat <= lat + 3'd1;
			end else begin
				lat <= 3'd0;
				if (cart_mem_we) begin
					if (cart_mem_be[0]) cart[{ca[21:1], 1'b0}] <= cart_mem_wdata[7:0];
					if (cart_mem_be[1]) cart[{ca[21:1], 1'b1}] <= cart_mem_wdata[15:8];
				end else begin
					cart_mem_rdata  <= {cart[{ca[21:1], 1'b1}], cart[{ca[21:1], 1'b0}]};
					cart_mem_rvalid <= 1'b1;
				end
				cart_mem_done <= 1'b1;
				served        <= 1'b1;
				served_tag    <= cart_mem_tag;
			end
		end
	end

	// The header fields the seed is given (it does not seed a resume, so they
	// are only checked, never used).
	wire        cart_header_valid = (cart_bytes_cfg != 0);
	wire [15:0] cart_catalog      = {cart[22'h21], cart[22'h20]};
	wire [7:0]  cart_subcatalog   = cart[22'h22];
	wire [95:0] cart_title        = {cart[22'h2F], cart[22'h2E], cart[22'h2D], cart[22'h2C],
	                                 cart[22'h2B], cart[22'h2A], cart[22'h29], cart[22'h28],
	                                 cart[22'h27], cart[22'h26], cart[22'h25], cart[22'h24]};

	// ---- BIOS setup seed and the automatic power press ---------------------
	wire        bios_setup_ready, bios_mono_active;
	wire        seed_pause_req, seed_busy, seed_done, pause_ready;
	wire  [9:0] ss_bus_adr;
	wire [63:0] ss_bus_din;
	wire        ss_bus_wren;
	wire  [1:0] ss_mem_type;
	wire        ss_mem_active;
	wire [13:0] ss_mem_addr;
	wire  [7:0] ss_mem_wdata;
	wire        ss_mem_wren, ss_mem_rden;

	ngp_setup_seed setup_seed
	(
		.clk                   (clk_sys),
		.reset                 (machine_reset),
		.setup_ready           (bios_setup_ready),
		.mono                  (bios_mono_active),
		.osd_language_japanese (1'b0),
		.osd_palette           (3'd0),
		.use_hps_rtc           (1'b0),
		.hps_rtc               (65'd0),
		.skip_bios_animation   (1'b1),
		.cart_header_valid     (cart_header_valid),
		.cart_catalog          (cart_catalog),
		.cart_subcatalog       (cart_subcatalog),
		.cart_title            (cart_title),
		.pause_req             (seed_pause_req),
		.pause_ready           (pause_ready),
		.ss_bus_adr            (ss_bus_adr),
		.ss_bus_din            (ss_bus_din),
		.ss_bus_wren           (ss_bus_wren),
		.ss_mem_type           (ss_mem_type),
		.ss_mem_active         (ss_mem_active),
		.ss_mem_addr           (ss_mem_addr),
		.ss_mem_wdata          (ss_mem_wdata),
		.ss_mem_wren           (ss_mem_wren),
		.ss_mem_rden           (ss_mem_rden),
		.seed_busy             (seed_busy),
		.seed_done             (seed_done)
	);

	localparam [24:0] PWR_HOLD_CLKS = 25'd19_677_144;   // 24 frames, as ngpc_machine
	reg  [24:0] pwr_hold_q = 25'd0;
	reg         pressed = 1'b0;
	always @(posedge clk_sys) begin
		if (machine_reset) begin
			pwr_hold_q <= 25'd0;
			pressed    <= 1'b0;
		end else if (seed_done && !pressed) begin
			pwr_hold_q <= PWR_HOLD_CLKS;
			pressed    <= 1'b1;
		end else if (pwr_hold_q != 25'd0) begin
			pwr_hold_q <= pwr_hold_q - 25'd1;
		end
	end
	wire power_btn = (pwr_hold_q != 25'd0);
	assign powered = pressed;

	// ---- the link cable ------------------------------------------------------
	wire link_txd, link_rts_n, link_rxd, link_cts_n;

	ngpc_link link
	(
		.clk     (clk_sys),
		.reset   (machine_reset),
		.mode    (link_mode),
		.txd     (link_txd),
		.rts_n   (link_rts_n),
		.rxd     (link_rxd),
		.cts_n   (link_cts_n),
		.present (link_present),
		.so      (link_so),
		.so_oe   (link_so_oe),
		.so_pin  (link_so_pin),
		.si      (link_si),
		.sd      (link_sd),
		.sd_oe   (link_sd_oe),
		.sd_pin  (link_sd_pin)
	);

	// ---- the board ------------------------------------------------------------
	wire [1:0]  cart_size_code0, cart_size_code1;
	wire [24:0] cart_bytes;
	wire        cart_present;

	ngp_mainboard mainboard
	(
		.clk_sys               (clk_sys),
		.reset                 (machine_reset),
		.restore_reset         (1'b0),
		.mono_strap            (1'b0),
		.lcd_persistence       (1'b0),
		.palette_frame_boundary(1'b0),

		.ce_pix                (ce_pix),
		.vga_r                 (vga_r),
		.vga_g                 (vga_g),
		.vga_b                 (vga_b),
		.hsync                 (),
		.vsync                 (),
		.hblank                (hblank),
		.vblank                (vblank),
		.audio_l               (),
		.audio_r               (),

		.btn                   (btn),
		.power_btn             (power_btn),

		.link_txd              (link_txd),
		.link_rxd              (link_rxd),
		.link_rts_n            (link_rts_n),
		.link_cts_n            (link_cts_n),
		.link_present          (link_present),

		.led_user              (),
		.bios_setup_ready      (bios_setup_ready),
		.bios_mono_active      (bios_mono_active),
		.bios_wr               (bios_wr),
		.bios_sel              (1'b0),
		.bios_addr             (bios_addr),
		.bios_data             (bios_data),
		.skip_bios_animation   (1'b1),

		.cheat_load_begin      (1'b0),
		.cheat_invalidate      (1'b0),
		.cheat_commit_req      (1'b0),
		.cheat_commit_done     (),
		.cheat_code            (129'd0),

		.cart_image_bytes      (cart_bytes_cfg),
		.cart_config_load      (cart_config_load),
		.cart_force_8m_die0    (1'b0),
		.cart_force_flash_read (1'b0),
		.cart_size_code0       (cart_size_code0),
		.cart_size_code1       (cart_size_code1),
		.cart_bytes            (cart_bytes),
		.cart_present          (cart_present),
		.cart_mem_req          (cart_mem_req),
		.cart_mem_we           (cart_mem_we),
		.cart_mem_addr         (cart_mem_addr),
		.cart_mem_wdata        (cart_mem_wdata),
		.cart_mem_be           (cart_mem_be),
		.cart_mem_lane         (cart_mem_lane),
		.cart_mem_tag          (cart_mem_tag),
		.cart_mem_flash        (cart_mem_flash),
		.cart_mem_rdata        (cart_mem_rdata),
		.cart_mem_rvalid       (cart_mem_rvalid),
		.cart_mem_done         (cart_mem_done),
		.cart_dirty_pulse      (),
		.cart_dirty0           (),
		.cart_dirty1           (),
		.cart_dirty0_event     (),
		.cart_dirty0_block     (),
		.cart_dirty1_event     (),
		.cart_dirty1_block     (),
		.cart_dirty_clear      (1'b0),
		.cart_flash_busy       (),
		.cart_die_busy         (),

		.ss_bus_adr            (ss_bus_adr),
		.ss_bus_din            (ss_bus_din),
		.ss_bus_wren           (ss_bus_wren),
		.ss_bus_rst            (1'b0),
		.ss_restore_is_rewind  (1'b0),
		.ss_bus_dout           (),
		.ss_mem_type           (ss_mem_type),
		.ss_mem_active         (ss_mem_active),
		.ss_mem_addr           (ss_mem_addr),
		.ss_mem_wdata          (ss_mem_wdata),
		.ss_mem_wren           (ss_mem_wren),
		.ss_mem_rden           (ss_mem_rden),
		.ss_mem_rdata          (),
		.loading_savestate     (1'b0),

		.pause_req             (seed_pause_req),
		.pause_ready           (pause_ready)
	);

endmodule
