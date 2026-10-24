// Two NGPCs joined by a simulated link cable: a GBC cable (cable = 1: each SO
// on the other's SI) or a GBA cable (cable = 2: A on the parent plug, A.SO on
// B.SI, A.SI tied low, SD joined). A pin reaches a wire only while its side
// drives it; an undriven wire idles high. sim_main.cpp supplies the two clocks
// (independent, a little apart), the buttons, the Link Cable modes and the
// cable, and records the screens.

module tb_link2
(
	input  wire       clk_a,
	input  wire       clk_b,
	input  wire       reset,
	input  wire [6:0] btn_a,
	input  wire [6:0] btn_b,
	input  wire [1:0] link_mode_a,    // 0 off, 1 GBC cable, 2 GBA cable
	input  wire [1:0] link_mode_b,
	input  wire [1:0] cable,          // 0 unplugged, 1 GBC cable, 2 GBA cable

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

	wire so_a, oe_a, so_b, oe_b, sd_a, sde_a, sd_b, sde_b;
	wire w_so_a = oe_a ? so_a : 1'b1;
	wire w_so_b = oe_b ? so_b : 1'b1;
	wire w_sd   = sde_a ? sd_a : sde_b ? sd_b : 1'b1;
	wire si_a = (cable == 2'd1) ? w_so_b : (cable == 2'd2) ? 1'b0 : 1'b1;
	wire si_b = (cable != 2'd0) ? w_so_a : 1'b1;
	wire sd_in_a = (cable == 2'd2) ? w_sd : (sde_a ? sd_a : 1'b1);
	wire sd_in_b = (cable == 2'd2) ? w_sd : (sde_b ? sd_b : 1'b1);
	assign so_a_o = w_so_a;
	assign so_b_o = (cable == 2'd2) ? w_sd : w_so_b;    // what reaches A

	ngpc_sim_machine #(.CART_ARG("cart0")) a
	(
		.clk_sys(clk_a), .reset(reset), .btn(btn_a),
		.link_mode(link_mode_a), .link_si(si_a), .link_so(so_a), .link_so_oe(oe_a), .link_so_pin(w_so_a),
		.link_sd(sd_a), .link_sd_oe(sde_a), .link_sd_pin(sd_in_a),
		.link_present(present_a),
		.ce_pix(ce_pix_a), .vga_r(r_a), .vga_g(g_a), .vga_b(b_a), .hblank(hbl_a), .vblank(vbl_a),
		.bios_loaded(), .powered(powered_a)
	);

	ngpc_sim_machine #(.CART_ARG("cart1")) b
	(
		.clk_sys(clk_b), .reset(reset), .btn(btn_b),
		.link_mode(link_mode_b), .link_si(si_b), .link_so(so_b), .link_so_oe(oe_b), .link_so_pin(w_so_b),
		.link_sd(sd_b), .link_sd_oe(sde_b), .link_sd_pin(sd_in_b),
		.link_present(present_b),
		.ce_pix(ce_pix_b), .vga_r(r_b), .vga_g(g_b), .vga_b(b_b), .hblank(hbl_b), .vblank(vbl_b),
		.bios_loaded(), .powered(powered_b)
	);

endmodule
