// Diagnostic, built only with the NGPC_CART_DIAG macro (projects/ngpc_pocket.qsf);
// release builds leave it out.
//
// Localises a corrupted cartridge load. On hardware (2026-10-01) fast
// quit/relaunch cycles of Card Fighters left ngp_cart_rom's image CRC at
// 3E1E08FE instead of the file's 94B63A97, three times in a row, while the
// Pocket's debug log showed an identical load sequence. This module measures
// the two ends of the core's cartridge path so one bad launch says where the
// data went wrong:
//
//   bridge side (clk_74a): CRC32 of every 32-bit bridge write to the cart
//     region 0x11xxxxxx, in arrival order and file byte order, before the
//     data_loader's dcfifo; the transfer duration from first to last word.
//   FIFO side (clk_sys): ngpc_cart_fifo's overflow flag and a count of the
//     words it dropped (a write while full).
//
// Reported through two spare savestate pad words (8418/8419, see
// ngpc_savestate_bridge.sv), read with tools/cartdiag.py:
//   diag_b = bridge-side CRC32 (compare with the file CRC and the image CRC)
//   diag_a = {overflow, drops[13:0] saturating, crc_overrun,
//             duration[15:0] in units of 4096 clk_74a cycles (55.2 us)}
//
// diag2: built for area. The CRC runs two bits per clk_74a (16 cycles per
// word); a bridge word needs 32 SCK edges, so it cannot arrive sooner, and a
// word that did would set crc_overrun. The reported values are static long
// before any capture samples them (the load ends seconds earlier), so they
// leave this module without synchronizer copies; the clk_74a <-> clk_sys
// transfer is a false path in the SDC.
`default_nettype none

module ngpc_cart_diag (
	input  wire        clk_74a,
	input  wire        clk_sys,
	input  wire        reset_sys,

	// APF bridge, clk_74a
	input  wire        bridge_wr,
	input  wire [31:0] bridge_addr,
	input  wire [31:0] bridge_wr_data,
	input  wire        dataslot_requestwrite,
	input  wire [15:0] dataslot_requestwrite_id,

	// cart FIFO, clk_sys
	input  wire        fifo_drop,       // a write arrived while the FIFO was full
	input  wire        fifo_overflow,   // ngpc_cart_fifo's latched flag

	output wire [31:0] diag_a,
	output wire [31:0] diag_b
);

	// ---- bridge side, clk_74a -------------------------------------------
	reg        prev_wr  = 1'b0;
	reg [31:0] crc_q    = 32'hFFFFFFFF;
	reg [31:0] sh_q     = 32'd0;      // bits in CRC processing order, LSB first
	reg  [4:0] left_q   = 5'd0;       // bit pairs still to fold in
	reg        overrun_q = 1'b0;
	reg [11:0] pre_q    = 12'd0;      // 4096-cycle prescaler
	reg [15:0] units_q  = 16'd0;      // units since the first cart word
	reg [15:0] dur_q    = 16'd0;
	reg        seen_q   = 1'b0;

	wire cart_beat = !prev_wr && bridge_wr && (bridge_addr[31:24] == 8'h11);

	// Two reflected CRC32 steps (bit 0 then bit 1 of sh_q).
	wire [31:0] c1 = (crc_q[0] ^ sh_q[0]) ? (crc_q >> 1) ^ 32'hEDB88320 : (crc_q >> 1);
	wire [31:0] c2 = (c1[0]    ^ sh_q[1]) ? (c1    >> 1) ^ 32'hEDB88320 : (c1    >> 1);

	always @(posedge clk_74a) begin
		prev_wr <= bridge_wr;
		pre_q   <= pre_q + 12'd1;
		if (&pre_q && !(&units_q)) units_q <= units_q + 16'd1;

		if (dataslot_requestwrite && dataslot_requestwrite_id == 16'd0) begin
			crc_q     <= 32'hFFFFFFFF;
			left_q    <= 5'd0;
			overrun_q <= 1'b0;
			seen_q    <= 1'b0;
			dur_q     <= 16'd0;
		end else begin
			if (left_q != 5'd0) begin
				crc_q  <= c2;
				sh_q   <= sh_q >> 2;
				left_q <= left_q - 5'd1;
			end
			if (cart_beat) begin
				if (left_q > 5'd1) overrun_q <= 1'b1;
				// data_loader byte-swaps (bridge_endian_little is 0): the
				// file's first byte is wr_data[31:24]; CRC bits go LSB first.
				sh_q   <= {bridge_wr_data[7:0], bridge_wr_data[15:8],
				           bridge_wr_data[23:16], bridge_wr_data[31:24]};
				left_q <= 5'd16;
				if (!seen_q) begin
					seen_q  <= 1'b1;
					units_q <= 16'd0;
				end else begin
					dur_q <= units_q;
				end
			end
		end
	end

	// ---- FIFO side, clk_sys -----------------------------------------------
	reg [13:0] drops_q = 14'd0;
	always @(posedge clk_sys) begin
		if (reset_sys)                         drops_q <= 14'd0;
		else if (fifo_drop && !(&drops_q))     drops_q <= drops_q + 14'd1;
	end

	assign diag_b = ~crc_q;
	assign diag_a = {fifo_overflow, drops_q, overrun_q, dur_q};

endmodule

`default_nettype wire
