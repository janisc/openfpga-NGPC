// NGPC for Analogue Pocket -- native LCD presenter.
//
// Replaces `ngpc_crt_framebuffer` for the Pocket target.
//
// The MiSTer presenter exists because MiSTer has to hand the framework a
// CRT-shaped raster: the K1GE/K2GE line period is 83.8 us, nowhere near the
// 64 us an analog display wants, so the core buffers whole frames and re-emits
// them as a 262-line raster. That store costs two RGB888 banks -- 192 of the
// Pocket's 308 M10K blocks, which is more than the device can give.
//
// APF has no such constraint. The scaler consumes whatever raster the core
// produces, so the native 515 x 199 dot grid goes straight out and the frame
// store disappears entirely. What is left is wiring plus two small jobs:
//
//   1. RGB444 -> RGB888 by nibble replication, as the MiSTer presenter did.
//   2. Pixel gating. The panel takes one pixel per THREE dots (hdot 0, 3, ...
//      477 = 160 pixels), so a naive DE would present 480 pixels per line.
//      `ce_pixel` marks the dot that actually carries a new pixel and the top
//      level turns it into APF's `video_skip`, which suppresses the latch on
//      every other cycle. The Pocket therefore latches exactly 160 x 152.
//
// Everything here is in clk_sys. The APF video clock is clk_sys as well, so no
// clock domain is crossed and no line buffer is needed.
//
// Not carried over from the MiSTer presenter:
//   - `lcd_persistence` (the "LCD Response: Panel" option). It blends against
//     the previous frame, which needs the frame store this module removes.
//   - `tint`, which the mainboard already ties to zero.
// Both are accepted and ignored so the port list stays honest about what the
// mainboard offers.

`default_nettype none

module ngpc_pocket_video
(
	input  wire        clk_sys,
	input  wire        rst,

	// Native LCD pads, straight off the K2GE.
	input  wire        lcd_dclk_ce,   // panel dot-clock enable, /3 per line
	input  wire [3:0]  lcd_r,
	input  wire [3:0]  lcd_g,
	input  wire [3:0]  lcd_b,
	input  wire        lcd_de,        // level, high across the 480-dot window
	input  wire        lcd_hs,        // active high, hdot 489..506
	input  wire        lcd_vs,        // active high, vline 168..170
	input  wire        lcd_lp,        // line pulse, one per line
	input  wire        lcd_sp,        // frame start pulse, one per frame

	// Machine pause chain. The MiSTer presenter aligned pause release to its
	// public frame wrap because its raster and the machine's ran on separate
	// clocks-in-spirit. Here the presentation IS the machine's raster, so a
	// request needs no alignment and passes straight through.
	input  wire        external_pause_req,
	input  wire        machine_pause_ready,
	input  wire        loading_savestate,
	output wire        video_pause_req,
	output wire        video_reset_hold,

	// Accepted and ignored -- see the header.
	input  wire [2:0]  tint,
	input  wire        lcd_persistence,

	output reg         ce_pixel,
	output reg  [7:0]  vga_r,
	output reg  [7:0]  vga_g,
	output reg  [7:0]  vga_b,
	output reg         vga_de,
	output reg         vga_hbl,
	output reg         vga_vbl,
	output reg         vga_hs,
	output reg         vga_vs
);

	// The K2GE drives DE only over the 152 display lines, so vertical blank is
	// the complement of DE having been active this line. Tracking it with the
	// line pulse rather than a counter keeps this module free of any assumption
	// about the raster's shape: if upstream retimes the panel, this follows.
	reg v_active;

	always @(posedge clk_sys) begin
		if (rst) begin
			v_active <= 1'b0;
		end else if (lcd_sp) begin
			v_active <= 1'b0;
		end else if (lcd_de) begin
			v_active <= 1'b1;
		end else if (lcd_vs) begin
			v_active <= 1'b0;
		end
	end

	// One pixel per dclk tick inside the active window. The RGB pads settle on
	// the tick, so the strobe is registered alongside them and the top level
	// sees data and its qualifier on the same edge.
	always @(posedge clk_sys) begin
		if (rst) begin
			ce_pixel <= 1'b0;
			vga_r    <= 8'd0;
			vga_g    <= 8'd0;
			vga_b    <= 8'd0;
			vga_de   <= 1'b0;
			vga_hbl  <= 1'b1;
			vga_vbl  <= 1'b1;
			vga_hs   <= 1'b0;
			vga_vs   <= 1'b0;
		end else begin
			ce_pixel <= lcd_dclk_ce && lcd_de;

			// RGB444 -> RGB888, nibble replication. 0xF maps to 0xFF so full
			// scale stays full scale.
			vga_r    <= {lcd_r, lcd_r};
			vga_g    <= {lcd_g, lcd_g};
			vga_b    <= {lcd_b, lcd_b};

			vga_de   <= lcd_de;
			vga_hbl  <= ~lcd_de;
			vga_vbl  <= ~v_active;
			vga_hs   <= lcd_hs;
			vga_vs   <= lcd_vs;
		end
	end

	assign video_pause_req  = external_pause_req;
	assign video_reset_hold = 1'b0;

	wire unused_ok = &{1'b0, machine_pause_ready, loading_savestate,
	                   tint, lcd_persistence, lcd_lp, 1'b0};

endmodule

`default_nettype wire
