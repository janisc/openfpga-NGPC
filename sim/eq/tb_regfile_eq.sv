// Lock-step equivalence: the LUT-RAM register file against upstream's flop
// register file. Both see the same random port traffic every cycle; every
// read port is compared before each clock edge, so a write that lands one
// edge late, in the wrong lane or in the wrong copy shows up as a mismatch on
// the next cycle that reads that register.
//
// The reference is upstream's t900_regfile.sv with its module renamed to
// t900_regfile_ref by run_regfile_eq.sh.

module tb_regfile_eq;

	localparam int CYCLES = 20_000_000;

	reg        clk = 1'b0;
	reg [1:0]  rfp;
	reg [7:0]  ra_code, rb_code, wr_code;
	reg [1:0]  ra_size, rb_size, wr_size;
	reg        wr_en, ss_wren;
	reg [31:0] wr_data, ss_wdata;
	reg [4:0]  ss_addr;

	wire [31:0] ra_ref, rb_ref, ss_ref;
	wire [31:0] ra_dut, rb_dut, ss_dut;

	t900_regfile_ref u_ref
	(
		.clk(clk), .rfp(rfp),
		.ra_code(ra_code), .ra_size(ra_size), .ra_data(ra_ref),
		.rb_code(rb_code), .rb_size(rb_size), .rb_data(rb_ref),
		.wr_en(wr_en), .wr_code(wr_code), .wr_size(wr_size), .wr_data(wr_data),
		.ss_wren(ss_wren), .ss_addr(ss_addr), .ss_wdata(ss_wdata), .ss_rdata(ss_ref)
	);

	t900_regfile u_dut
	(
		.clk(clk), .rfp(rfp),
		.ra_code(ra_code), .ra_size(ra_size), .ra_data(ra_dut),
		.rb_code(rb_code), .rb_size(rb_size), .rb_data(rb_dut),
		.wr_en(wr_en), .wr_code(wr_code), .wr_size(wr_size), .wr_data(wr_data),
		.ss_wren(ss_wren), .ss_addr(ss_addr), .ss_wdata(ss_wdata), .ss_rdata(ss_dut)
	);

	// Mostly valid register codes (absolute banks, previous, current, the
	// index group), sometimes anything at all, including the undefined 40-7C.
	function automatic [7:0] pick_code();
		int r = $urandom_range(0, 99);
		if (r < 15)
			return 8'($urandom);
		else if (r < 45)
			return {2'b00, 6'($urandom)};
		else if (r < 60)
			return {4'hd, 4'($urandom)};
		else if (r < 85)
			return {4'he, 4'($urandom)};
		else
			return {4'hf, 4'($urandom)};
	endfunction

	longint mismatches = 0;
	longint writes = 0, ss_writes = 0, both = 0;

	task automatic check(input longint cyc);
		if (ra_ref !== ra_dut || rb_ref !== rb_dut || ss_ref !== ss_dut) begin
			mismatches++;
			if (mismatches <= 10)
				$display("MISMATCH cycle %0d: ra %h/%h rb %h/%h ss %h/%h (ra_code %h sz %0d rb_code %h sz %0d ss_addr %0d rfp %0d)",
					cyc, ra_ref, ra_dut, rb_ref, rb_dut, ss_ref, ss_dut,
					ra_code, ra_size, rb_code, rb_size, ss_addr, rfp);
		end
	endtask

	initial begin
		rfp = 0; ra_code = 0; rb_code = 0; wr_code = 0;
		ra_size = 0; rb_size = 0; wr_size = 0;
		wr_en = 0; ss_wren = 0; wr_data = 0; ss_wdata = 0; ss_addr = 0;

		// Bring both arrays to the same known contents through the savestate
		// tap, the way a restore does, so the comparison starts defined.
		for (int i = 0; i < 20; i++) begin
			ss_wren = 1; ss_addr = 5'(i); ss_wdata = $urandom;
			#1 clk = 1; #1 clk = 0;
		end
		ss_wren = 0;

		for (longint cyc = 0; cyc < CYCLES; cyc++) begin
			if ($urandom_range(0, 31) == 0)
				rfp = 2'($urandom);
			ra_code = pick_code();  ra_size = 2'($urandom);
			rb_code = pick_code();  rb_size = 2'($urandom);
			wr_en   = ($urandom_range(0, 99) < 35);
			wr_code = pick_code();  wr_size = 2'($urandom);
			wr_data = $urandom;
			ss_wren = ($urandom_range(0, 99) < 3);
			ss_addr = 5'($urandom);
			ss_wdata = $urandom;
			if (wr_en) writes++;
			if (ss_wren) ss_writes++;
			if (wr_en && ss_wren) both++;

			#1 check(cyc);          // reads before the edge: old contents
			clk = 1;
			#1 check(cyc);          // the same reads after it: new contents
			clk = 0;
		end

		$display("cycles %0d, writes %0d, savestate writes %0d, both at once %0d, mismatches %0d",
			CYCLES, writes, ss_writes, both, mismatches);
		if (mismatches == 0)
			$display("REGFILE EQUIVALENT");
		else
			$display("REGFILE DIFFERS");
		$finish;
	end

endmodule
