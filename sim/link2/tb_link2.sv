// Two NGPCs joined by a simulated GBC link cable. Each side's SO reaches the
// other side's SI only while that side drives it (so_oe); an undriven wire
// idles high, like the link port with nothing driving it. sim_main.cpp
// supplies the two clocks (independent, a little apart), the buttons and the
// link switches, and records the screens.

module tb_link2
(
	input  wire       clk_a,
	input  wire       clk_b,
	input  wire       reset,
	input  wire [6:0] btn_a,
	input  wire [6:0] btn_b,
	input  wire       link_en_a,
	input  wire       link_en_b,
	input  wire       cable,          // 1 = plugged in

	output wire       ce_pix_a,
	output wire [7:0] r_a, g_a, b_a,
	output wire       hbl_a, vbl_a,
	output wire       ce_pix_b,
	output wire [7:0] r_b, g_b, b_b,
	output wire       hbl_b, vbl_b,

	output wire       present_a,
	output wire       present_b,
	output wire       powered_a,
	output wire       powered_b,
	output wire       so_a_o,
	output wire       so_b_o
);

	wire so_a, oe_a, so_b, oe_b;
	wire si_a = (cable && oe_b) ? so_b : 1'b1;
	wire si_b = (cable && oe_a) ? so_a : 1'b1;
	assign so_a_o = oe_a ? so_a : 1'b1;
	assign so_b_o = oe_b ? so_b : 1'b1;

	ngpc_sim_machine #(.CART_ARG("cart0")) a
	(
		.clk_sys(clk_a), .reset(reset), .btn(btn_a),
		.link_enable(link_en_a), .link_si(si_a), .link_so(so_a), .link_so_oe(oe_a),
		.link_present(present_a),
		.ce_pix(ce_pix_a), .vga_r(r_a), .vga_g(g_a), .vga_b(b_a), .hblank(hbl_a), .vblank(vbl_a),
		.bios_loaded(), .powered(powered_a)
	);

	ngpc_sim_machine #(.CART_ARG("cart1")) b
	(
		.clk_sys(clk_b), .reset(reset), .btn(btn_b),
		.link_enable(link_en_b), .link_si(si_b), .link_so(so_b), .link_so_oe(oe_b),
		.link_present(present_b),
		.ce_pix(ce_pix_b), .vga_r(r_b), .vga_g(g_b), .vga_b(b_b), .hblank(hbl_b), .vblank(vbl_b),
		.bios_loaded(), .powered(powered_b)
	);

endmodule
