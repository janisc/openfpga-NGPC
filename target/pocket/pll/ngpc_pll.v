// NGPC Analogue Pocket core PLL.
//
//   refclk   74.25 MHz  (APF clk_74a)
//   outclk_0 49.152 MHz clk_sys   -- the machine, as on MiSTer
//   outclk_1 98.304 MHz clk_ram   -- SDRAM command clock (sdram.sdc expects c1)
//   outclk_2 49.152 MHz clk_sys90 -- +90 deg, for APF video_rgb_clock_90
//   outclk_3  6.144 MHz clk_dot   -- spare: clk_sys/8, the native dot cadence
`timescale 1 ps / 1 ps
module ngpc_pll (
		input  wire  refclk,
		input  wire  rst,
		output wire  outclk_0,
		output wire  outclk_1,
		output wire  outclk_2,
		output wire  outclk_3,
		output wire  locked
	);
	ngpc_pll_0002 ngpc_pll_inst (
		.refclk   (refclk),
		.rst      (rst),
		.outclk_0 (outclk_0),
		.outclk_1 (outclk_1),
		.outclk_2 (outclk_2),
		.outclk_3 (outclk_3),
		.locked   (locked)
	);
endmodule
