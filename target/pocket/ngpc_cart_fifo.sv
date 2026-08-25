// NGPC for Analogue Pocket -- cartridge download elasticity buffer.
//
// `ngp_cart_rom` back-pressures its producer with `ioctl_wait_o`, and on MiSTer
// that stalls the HPS mid-transfer. APF has no equivalent: a data slot is
// streamed at the framework's pace and a core that is not ready simply loses
// the word. So the two are separated by a FIFO, and the wait line throttles the
// read side instead of the transfer.
//
// Depth. APF delivers a 32-bit word roughly every 75 clk_74a cycles, about one
// microsecond, which is two 16-bit words per ~50 clk_sys cycles -- one entry
// per 25 cycles. 512 entries therefore absorb a stall of about 12,800 clk_sys
// cycles, a quarter of a millisecond. The one long stall the loader documents,
// the 0xFF tail prefill of up to ~65 ms, happens after the last file byte has
// arrived, when nothing is being streamed and the depth is irrelevant.
//
// `overflow_o` is latched and brought out rather than being quietly dropped: if
// the assumption above is ever wrong, the symptom is a corrupted cartridge that
// still boots, which is the worst kind of bug to chase from a photograph.

`default_nettype none

module ngpc_cart_fifo
(
	input  wire        clk,
	input  wire        reset,

	// Producer: the APF data loader, one 16-bit word at a time.
	input  wire        wr_i,
	input  wire [26:0] addr_i,
	input  wire [15:0] data_i,

	// Consumer: ngp_cart_rom's ioctl face.
	input  wire        wait_i,
	output wire        wr_o,
	output wire [26:0] addr_o,
	output wire [15:0] data_o,

	output reg         overflow_o
);

	localparam int unsigned WIDTH = 43;   // 27 address + 16 data
	localparam int unsigned DEPTH = 512;

	wire [WIDTH-1:0] fifo_din = {addr_i, data_i};
	wire [WIDTH-1:0] fifo_dout;
	wire             fifo_empty;
	wire             fifo_full;

	// Pop whenever the loader is willing to take a word. scfifo is in
	// show-ahead mode, so the head is already on q and a read acknowledges it.
	wire pop = !fifo_empty && !wait_i;

	scfifo #(
		.lpm_width      (WIDTH),
		.lpm_numwords   (DEPTH),
		.lpm_widthu     ($clog2(DEPTH)),
		.lpm_showahead  ("ON"),
		.lpm_type       ("scfifo"),
		.intended_device_family ("Cyclone V"),
		.overflow_checking ("ON"),
		.underflow_checking("ON"),
		.use_eab        ("ON"),
		.add_ram_output_register ("OFF")
	) u_fifo (
		.clock (clk),
		.sclr  (reset),
		.data  (fifo_din),
		.wrreq (wr_i && !fifo_full),
		.rdreq (pop),
		.q     (fifo_dout),
		.empty (fifo_empty),
		.full  (fifo_full),
		.aclr  (1'b0),
		.almost_empty (),
		.almost_full  (),
		.usedw        (),
		.eccstatus    ()
	);

	assign wr_o   = pop;
	assign addr_o = fifo_dout[42:16];
	assign data_o = fifo_dout[15:0];

	always @(posedge clk) begin
		if (reset)                 overflow_o <= 1'b0;
		else if (wr_i && fifo_full) overflow_o <= 1'b1;
	end

endmodule

`default_nettype wire
