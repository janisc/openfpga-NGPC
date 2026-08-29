`timescale 1ns/1ps

// Bench for ngpc_apf_rtc: BCD pass-through, Zeller weekday against Python
// datetime goldens (0 = Sunday), CDC settle, toggle and flag bits, and the
// no-delivery case. Vectors are re-run on one DUT by forcing its one-shot
// FSM back to idle -- a bench liberty the RTL does not need to pay for.

module tb_apf_rtc;

	reg clk_74a = 0;
	reg clk_sys = 0;
	always #6.75  clk_74a = ~clk_74a;   // ~74.25 MHz
	always #10.17 clk_sys = ~clk_sys;   // ~49.152 MHz

	reg         rtc_valid = 0;
	reg  [31:0] rtc_date_bcd = 0;
	reg  [31:0] rtc_time_bcd = 0;
	wire [64:0] hps_rtc;
	wire        rtc_ready;

	ngpc_apf_rtc dut
	(
		.clk_74a      (clk_74a),
		.clk_sys      (clk_sys),
		.rtc_valid    (rtc_valid),
		.rtc_date_bcd (rtc_date_bcd),
		.rtc_time_bcd (rtc_time_bcd),
		.hps_rtc      (hps_rtc),
		.rtc_ready    (rtc_ready)
	);

	integer errors = 0;
	integer vecs = 0;

	task rewind;
	begin
		@(posedge clk_74a);
		rtc_valid <= 0;
		force dut.state      = 3'd0;
		force dut.settle     = 5'd0;
		force dut.valid_sync = 3'd0;
		force dut.rtc_ready  = 1'b0;
		repeat (6) @(posedge clk_sys);
		release dut.state;
		release dut.settle;
		release dut.valid_sync;
		release dut.rtc_ready;
		@(posedge clk_sys);
	end
	endtask

	task run_vec(input [31:0] date_bcd, input [2:0] exp_dow);
		integer guard;
	begin
		rewind;
		@(posedge clk_74a);
		rtc_date_bcd <= date_bcd;
		rtc_time_bcd <= 32'h00134527;
		@(posedge clk_74a);
		rtc_valid <= 1;

		guard = 0;
		while (!rtc_ready && guard < 5000) begin
			@(posedge clk_sys);
			guard = guard + 1;
		end
		vecs = vecs + 1;

		if (!rtc_ready) begin
			$display("FAIL %h: never ready", date_bcd);
			errors = errors + 1;
		end else begin
			if (hps_rtc[64]    !== 1'b1)          begin $display("FAIL %h: toggle", date_bcd); errors = errors + 1; end
			if (hps_rtc[63:56] !== 8'h40)         begin $display("FAIL %h: flags",  date_bcd); errors = errors + 1; end
			if (hps_rtc[47:40] !== date_bcd[23:16]) begin $display("FAIL %h: year",  date_bcd); errors = errors + 1; end
			if (hps_rtc[39:32] !== date_bcd[15:8])  begin $display("FAIL %h: month", date_bcd); errors = errors + 1; end
			if (hps_rtc[31:24] !== date_bcd[7:0])   begin $display("FAIL %h: day",   date_bcd); errors = errors + 1; end
			if (hps_rtc[23:0]  !== 24'h134527)      begin $display("FAIL %h: time",  date_bcd); errors = errors + 1; end
			if (hps_rtc[50:48] !== exp_dow) begin
				$display("FAIL %h: weekday got %0d want %0d", date_bcd, hps_rtc[50:48], exp_dow);
				errors = errors + 1;
			end
		end
	end
	endtask

	initial begin
		// No delivery: ready must stay low
		repeat (400) @(posedge clk_sys);
		if (rtc_ready !== 1'b0) begin
			$display("FAIL: ready without valid");
			errors = errors + 1;
		end

		run_vec(32'h20260828, 3'd5); // Friday
		run_vec(32'h20000101, 3'd6); // Saturday
		run_vec(32'h20000229, 3'd2); // Tuesday, leap century
		run_vec(32'h19991231, 3'd5); // Friday
		run_vec(32'h20240229, 3'd4); // Thursday, leap
		run_vec(32'h20010101, 3'd1); // Monday
		run_vec(32'h21000215, 3'd1); // Monday, February with century borrow
		run_vec(32'h19850307, 3'd4); // Thursday
		run_vec(32'h20261225, 3'd5); // Friday
		run_vec(32'h20270101, 3'd5); // Friday, January shift
		run_vec(32'h20260301, 3'd0); // Sunday
		run_vec(32'h20380119, 3'd2); // Tuesday

		if (errors == 0) begin
			$display("== ALL %0d APF-RTC VECTORS PASS", vecs);
		end else begin
			$display("== %0d ERRORS", errors);
		end
		$finish;
	end

	initial begin
		#4_000_000;
		$display("FAIL: watchdog");
		$finish;
	end

endmodule
