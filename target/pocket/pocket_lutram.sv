// A small register array in MLAB LUT RAM: one write port with byte enables,
// written on the rising edge, and one asynchronous read port.
//
// Quartus does not infer an asynchronous-read RAM for Cyclone V from HDL (it
// rebuilds the array in flops), so synthesis instantiates altdpram directly.
// On Cyclone V the MLAB registers wren, address, data and byte enables on the
// rising edge and writes on that same edge (altera_mf.v altdpram: Cyclone V is
// a rising-edge-write family), so the read port changes exactly when a flop
// would. Simulation uses the behavioural array.
//
// One instance serves one reader; a multi-ported register file keeps one
// copy per read port, all written together.

module pocket_lutram
#(
	parameter WIDTH  = 16,   // a multiple of 8
	parameter ADDR_W = 3
)
(
	input  wire                 clk,
	input  wire                 we,
	input  wire [ADDR_W-1:0]    waddr,
	input  wire [WIDTH/8-1:0]   wbe,
	input  wire [WIDTH-1:0]     wdata,
	input  wire [ADDR_W-1:0]    raddr,
	output wire [WIDTH-1:0]     q
);

`ifdef SYNTHESIS
	altdpram
	#(
		.intended_device_family             ("Cyclone V"),
		.ram_block_type                     ("MLAB"),
		.width                              (WIDTH),
		.widthad                            (ADDR_W),
		.numwords                           (1 << ADDR_W),
		.width_byteena                      (WIDTH / 8),
		.byte_size                          (8),
		.indata_reg                         ("INCLOCK"),
		.indata_aclr                        ("OFF"),
		.wraddress_reg                      ("INCLOCK"),
		.wraddress_aclr                     ("OFF"),
		.wrcontrol_reg                      ("INCLOCK"),
		.wrcontrol_aclr                     ("OFF"),
		.rdaddress_reg                      ("UNREGISTERED"),
		.rdaddress_aclr                     ("OFF"),
		.rdcontrol_reg                      ("UNREGISTERED"),
		.rdcontrol_aclr                     ("OFF"),
		.outdata_reg                        ("UNREGISTERED"),
		.outdata_aclr                       ("OFF"),
		.outdata_sclr                       ("OFF"),
		.read_during_write_mode_mixed_ports ("DONT_CARE"),
		.lpm_type                           ("altdpram")
	)
	u_ram
	(
		.inclock   (clk),
		.wren      (we),
		.wraddress (waddr),
		.byteena   (wbe),
		.data      (wdata),
		.rdaddress (raddr),
		.q         (q)
	);
`else
	reg [WIDTH-1:0] mem [0:(1 << ADDR_W) - 1];

	integer i;
	always @(posedge clk) begin
		if (we) begin
			for (i = 0; i < WIDTH / 8; i = i + 1)
				if (wbe[i]) mem[waddr][i*8 +: 8] <= wdata[i*8 +: 8];
		end
	end

	assign q = mem[raddr];
`endif

endmodule
