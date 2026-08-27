// Behavioral stand-in for Altera's dcfifo primitive, for Icarus simulation
// only. Covers what data_loader/data_unloader actually use: normal (non-
// showahead) read mode -- q updates one rdclk after rdreq -- rdempty, and
// dual clocks. The empty flag crosses domains through a 2-stage synchronizer
// the way the real megafunction's gray-pointer pipeline delays it; precise
// latency is not load-bearing for these consumers, conservative is.
module dcfifo (
	data, rdclk, rdreq, wrclk, wrreq, q, rdempty,
	wrempty, aclr, eccstatus, rdfull, rdusedw, wrfull, wrusedw
);
	parameter clocks_are_synchronized = "FALSE";
	parameter intended_device_family = "Cyclone V";
	parameter lpm_numwords = 4;
	parameter lpm_showahead = "OFF";
	parameter lpm_type = "dcfifo";
	parameter lpm_width = 32;
	parameter lpm_widthu = 2;
	parameter overflow_checking = "OFF";
	parameter rdsync_delaypipe = 5;
	parameter underflow_checking = "OFF";
	parameter use_eab = "OFF";
	parameter wrsync_delaypipe = 5;

	input  wire [lpm_width-1:0] data;
	input  wire rdclk, rdreq, wrclk, wrreq;
	output reg  [lpm_width-1:0] q;
	output wire rdempty;
	output wire wrempty, rdfull, wrfull;
	input  wire aclr;
	output wire [1:0] eccstatus;
	output wire [lpm_widthu-1:0] rdusedw, wrusedw;

	localparam DEPTH = 1 << lpm_widthu;

	reg [lpm_width-1:0] mem [0:DEPTH-1];
	reg [lpm_widthu:0] wp = 0, rp = 0;

	always @(posedge wrclk) begin
		if (wrreq) begin
			mem[wp[lpm_widthu-1:0]] <= data;
			wp <= wp + 1;
		end
	end

	// empty as the read domain sees it, pessimistically delayed
	wire raw_empty = (wp == rp);
	reg e1 = 1, e2 = 1;
	always @(posedge rdclk) begin
		e1 <= raw_empty;
		e2 <= e1;
		if (rdreq) begin
			q  <= mem[rp[lpm_widthu-1:0]];
			rp <= rp + 1;
		end
	end
	assign rdempty = e2 || raw_empty;

	assign wrempty = raw_empty;
	assign rdfull = 0; assign wrfull = 0;
	assign eccstatus = 0; assign rdusedw = 0; assign wrusedw = 0;
endmodule
