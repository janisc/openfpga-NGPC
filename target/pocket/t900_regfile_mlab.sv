// Copyright (c) 2026 Jamie Blanks
//
// Pocket port: the same register file with its storage in LUT RAM.

// TLCS-900/H general register file, stored in MLAB LUT RAM.
//
// This is a drop-in for t900_regfile.sv: the same ports, the same register-code
// map and the same cycle behaviour. Only the storage changes. Kept in flops,
// 640 bits and three 20:1 x 32-bit read muxes plus a per-register write
// decode cost about a thousand ALMs, and that cost swings by hundreds between
// syntheses. In MLABs it is a few LABs of memory plus the lane logic.
//
// An MLAB has one write port and one asynchronous read port, so the array is
// kept three times, once per reader: read port A, read port B and the
// savestate tap. All three copies take every write, so they always agree.
//
// Timing behaviour matches the flop version at clock-edge granularity: a read
// is combinational, and a write lands on the clock edge that ends the cycle in
// which wr_en (or ss_wren) is high. The CPU drives wr_en only on `ce` cycles
// and its read holds load only on `!ce` cycles, so no hold ever samples a
// read port in the same cycle that a write is in flight.
//
// Register-code byte map (CPU900H p.45):
//   code[7:4] = 0-3 : absolute bank  (bank = code[5:4])
//   code[7:4] = D   : previous bank  (RFP - 1)
//   code[7:4] = E   : current bank   (RFP)
//   code[7:4] = F   : XIX/XIY/XIZ/XSP
//   code[3:2] = register within the group (XWA/XBC/XDE/XHL or XIX/XIY/XIZ/XSP)
//   code[1:0] = byte lane; word codes are multiples of 2, long of 4.
// Codes 40-7C are undefined; reads return zero here and writes drop.
//
// Data convention: read data and write data are right-justified in 32 bits
// for every size. SIZE_B moves code[1:0]'s lane, SIZE_W moves the half
// selected by code[1], SIZE_L moves the whole register.

module t900_regfile
(
	input  wire        clk,

	input  wire [1:0]  rfp,          // current bank from SR

	// Read port A (combinational)
	input  wire [7:0]  ra_code,
	input  wire [1:0]  ra_size,      // 0=byte 1=word 2=long
	output wire [31:0] ra_data,

	// Read port B (combinational)
	input  wire [7:0]  rb_code,
	input  wire [1:0]  rb_size,
	output wire [31:0] rb_data,

	// Write port (registered)
	input  wire        wr_en,
	input  wire [7:0]  wr_code,
	input  wire [1:0]  wr_size,
	input  wire [31:0] wr_data,

	// Savestate tap: direct physical-index access, active only while the
	// core is paused. ss_wren writes a whole 32-bit entry.
	input  wire        ss_wren,
	input  wire [4:0]  ss_addr,
	input  wire [31:0] ss_wdata,
	output wire [31:0] ss_rdata
);

	localparam [1:0] SIZE_B = 2'd0;
	localparam [1:0] SIZE_W = 2'd1;

	// Register-code bits [7:2] to physical index 0-19. Invalid codes report
	// !valid and index 0; callers treat the data as zero.
	function automatic [5:0] phys_index(input [5:0] chi, input [1:0] cur_rfp);
		reg [4:0] idx;
		reg       valid;
	begin
		valid = 1'b1;
		idx   = 5'd0;
		casez (chi[5:2])
			4'b00??: idx = {1'b0, chi[3:2], chi[1:0]};                      // absolute banks 0-3
			4'hd:    idx = {1'b0, (cur_rfp - 2'd1), chi[1:0]};              // previous bank
			4'he:    idx = {1'b0, cur_rfp, chi[1:0]};                       // current bank
			4'hf:    idx = {3'b100, chi[1:0]};                              // XIX/XIY/XIZ/XSP
			default: valid = 1'b0;                                          // 40-7C undefined
		endcase
		phys_index = {valid, idx};
	end
	endfunction

	function automatic [31:0] lane_read(input [31:0] full, input [1:0] lane, input [1:0] size);
	begin
		lane_read = 32'd0;
		case (size)
			SIZE_B: begin
				case (lane)
					2'd0: lane_read = {24'd0, full[7:0]};
					2'd1: lane_read = {24'd0, full[15:8]};
					2'd2: lane_read = {24'd0, full[23:16]};
					2'd3: lane_read = {24'd0, full[31:24]};
				endcase
			end
			SIZE_W:  lane_read = lane[1] ? {16'd0, full[31:16]} : {16'd0, full[15:0]};
			default: lane_read = full;
		endcase
	end
	endfunction

	wire [5:0] ra_phys = phys_index(ra_code[7:2], rfp);
	wire [5:0] rb_phys = phys_index(rb_code[7:2], rfp);
	wire [5:0] wr_phys = phys_index(wr_code[7:2], rfp);

	wire ss_addr_ok = (ss_addr < 5'd20);

	// The one write port all three copies share. A savestate write wins over
	// an architectural one and always writes the whole entry. The write data
	// is replicated across the lanes so each byte enable picks its own copy.
	wire        ss_we = ss_wren && ss_addr_ok;
	wire        we    = ss_we || (wr_en && wr_phys[5]);
	wire [4:0]  waddr = ss_we ? ss_addr : wr_phys[4:0];
	reg  [3:0]  wbe;
	reg  [31:0] wdata;

	always @(*) begin
		if (ss_we) begin
			wbe   = 4'b1111;
			wdata = ss_wdata;
		end else begin
			case (wr_size)
				SIZE_B: begin
					wbe   = 4'b0001 << wr_code[1:0];
					wdata = {4{wr_data[7:0]}};
				end
				SIZE_W: begin
					wbe   = wr_code[1] ? 4'b1100 : 4'b0011;
					wdata = {2{wr_data[15:0]}};
				end
				default: begin
					wbe   = 4'b1111;
					wdata = wr_data;
				end
			endcase
		end
	end

	(* ramstyle = "MLAB" *) reg [31:0] mem_a [0:19];
	(* ramstyle = "MLAB" *) reg [31:0] mem_b [0:19];
	(* ramstyle = "MLAB" *) reg [31:0] mem_s [0:19];

	always @(posedge clk) begin
		if (we) begin
			if (wbe[0]) mem_a[waddr][7:0]   <= wdata[7:0];
			if (wbe[1]) mem_a[waddr][15:8]  <= wdata[15:8];
			if (wbe[2]) mem_a[waddr][23:16] <= wdata[23:16];
			if (wbe[3]) mem_a[waddr][31:24] <= wdata[31:24];
		end
	end

	always @(posedge clk) begin
		if (we) begin
			if (wbe[0]) mem_b[waddr][7:0]   <= wdata[7:0];
			if (wbe[1]) mem_b[waddr][15:8]  <= wdata[15:8];
			if (wbe[2]) mem_b[waddr][23:16] <= wdata[23:16];
			if (wbe[3]) mem_b[waddr][31:24] <= wdata[31:24];
		end
	end

	always @(posedge clk) begin
		if (we) begin
			if (wbe[0]) mem_s[waddr][7:0]   <= wdata[7:0];
			if (wbe[1]) mem_s[waddr][15:8]  <= wdata[15:8];
			if (wbe[2]) mem_s[waddr][23:16] <= wdata[23:16];
			if (wbe[3]) mem_s[waddr][31:24] <= wdata[31:24];
		end
	end

	assign ra_data  = ra_phys[5] ? lane_read(mem_a[ra_phys[4:0]], ra_code[1:0], ra_size) : 32'd0;
	assign rb_data  = rb_phys[5] ? lane_read(mem_b[rb_phys[4:0]], rb_code[1:0], rb_size) : 32'd0;
	assign ss_rdata = ss_addr_ok ? mem_s[ss_addr] : 32'd0;

endmodule
