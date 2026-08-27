// Simulation stand-in for platform/pocket/common.v's synch_3. The real one
// has trailing rise/fall ports the bridge leaves positionally unconnected --
// Quartus accepts that, Icarus does not, so the bench compiles this 3-port
// equivalent instead of common.v. Same 3-stage behavior.
module synch_3 #(parameter WIDTH = 1) (
	input  wire [WIDTH-1:0] i,
	output reg  [WIDTH-1:0] o,
	input  wire             clk
);
	reg [WIDTH-1:0] s1, s2;
	always @(posedge clk) begin
		{o, s2, s1} <= {s2, s1, i};
	end
endmodule
