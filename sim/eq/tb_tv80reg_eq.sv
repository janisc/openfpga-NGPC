// Lock-step equivalence: the LUT-RAM tv80_reg against upstream's flop
// tv80_reg (renamed tv80_reg_ref by run_tv80reg_eq.sh). Random port traffic
// every cycle; all eight read outputs are compared before and after each edge.

module tb_tv80reg_eq;

	longint CYCLES = 20_000_000;      // +cycles=N overrides

	// The clock is a wire so it can feed altera_mf's tri1 clock ports too.
	reg        clk_r = 1'b0;
	wire       clk = clk_r;
	reg [2:0]  AddrA, AddrB, AddrC, AddrS;
	reg [7:0]  DIH, DIL, DISH, DISL;
	reg        CEN, WEH, WEL, WES;

	wire [7:0] r_DOAH, r_DOAL, r_DOBH, r_DOBL, r_DOCH, r_DOCL, r_DOSH, r_DOSL;
	wire [7:0] d_DOAH, d_DOAL, d_DOBH, d_DOBL, d_DOCH, d_DOCL, d_DOSH, d_DOSL;

	tv80_reg_ref u_ref
	(
		.clk(clk), .CEN(CEN), .WEH(WEH), .WEL(WEL),
		.AddrA(AddrA), .AddrB(AddrB), .AddrC(AddrC), .DIH(DIH), .DIL(DIL),
		.DOAH(r_DOAH), .DOAL(r_DOAL), .DOBH(r_DOBH), .DOBL(r_DOBL), .DOCH(r_DOCH), .DOCL(r_DOCL),
		.AddrS(AddrS), .DISH(DISH), .DISL(DISL), .WES(WES), .DOSH(r_DOSH), .DOSL(r_DOSL)
	);

	tv80_reg u_dut
	(
		.clk(clk), .CEN(CEN), .WEH(WEH), .WEL(WEL),
		.AddrA(AddrA), .AddrB(AddrB), .AddrC(AddrC), .DIH(DIH), .DIL(DIL),
		.DOAH(d_DOAH), .DOAL(d_DOAL), .DOBH(d_DOBH), .DOBL(d_DOBL), .DOCH(d_DOCH), .DOCL(d_DOCL),
		.AddrS(AddrS), .DISH(DISH), .DISL(DISL), .WES(WES), .DOSH(d_DOSH), .DOSL(d_DOSL)
	);

	wire [63:0] r_all = {r_DOAH, r_DOAL, r_DOBH, r_DOBL, r_DOCH, r_DOCL, r_DOSH, r_DOSL};
	wire [63:0] d_all = {d_DOAH, d_DOAL, d_DOBH, d_DOBL, d_DOCH, d_DOCL, d_DOSH, d_DOSL};

	longint mismatches = 0;
	longint writes = 0, ss_writes = 0;

	task automatic check(input longint cyc);
		if (r_all !== d_all) begin
			mismatches++;
			if (mismatches <= 10)
				$display("MISMATCH cycle %0d: ref %h dut %h (A %0d B %0d C %0d S %0d)",
					cyc, r_all, d_all, AddrA, AddrB, AddrC, AddrS);
		end
	endtask

	initial begin
		if ($value$plusargs("cycles=%d", CYCLES)) ;
		CEN = 0; WEH = 0; WEL = 0; WES = 0;
		AddrA = 0; AddrB = 0; AddrC = 0; AddrS = 0;
		DIH = 0; DIL = 0; DISH = 0; DISL = 0;

		// Same known contents in both, through the savestate port.
		for (int i = 0; i < 8; i++) begin
			WES = 1; AddrS = 3'(i); DISH = 8'($urandom); DISL = 8'($urandom);
			#1 clk_r = 1; #1 clk_r = 0;
		end
		WES = 0;

		for (longint cyc = 0; cyc < CYCLES; cyc++) begin
			AddrA = 3'($urandom); AddrB = 3'($urandom); AddrC = 3'($urandom); AddrS = 3'($urandom);
			DIH = 8'($urandom); DIL = 8'($urandom); DISH = 8'($urandom); DISL = 8'($urandom);
			CEN = ($urandom_range(0, 3) == 0);
			WEH = $urandom_range(0, 1);
			WEL = $urandom_range(0, 1);
			WES = ($urandom_range(0, 99) < 3);
			if (CEN && (WEH || WEL)) writes++;
			if (WES) ss_writes++;

			#1 check(cyc);
			clk_r = 1;
			#1 check(cyc);
			clk_r = 0;
		end

		$display("cycles %0d, writes %0d, savestate writes %0d, mismatches %0d",
			CYCLES, writes, ss_writes, mismatches);
		if (mismatches == 0)
			$display("TV80REG EQUIVALENT");
		else
			$display("TV80REG DIFFERS");
		$finish;
	end

endmodule
