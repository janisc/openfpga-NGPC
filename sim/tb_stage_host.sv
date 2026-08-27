// Testbench: the host write leg of the save staging region.
//
// APF -> data_loader -> (core_top's save demux) -> ngpc_stage_mem -> psram
// controller -> a behavioral CellularRAM at the pins. This is the one leg of
// the save pipeline that hardware showed corrupting (a loaded save came back
// with its header's first words intact and later words wrong) and the only
// one no bench had ever exercised: the flush READ leg produced a byte-perfect
// file on hardware, and the engine legs are covered by tb_cart_save.
//
// Everything except the CellularRAM model and the APF pacing is real RTL,
// including the exact demux expressions from core_top.

`timescale 1ns / 1ps
`default_nettype none

module tb_stage_host;

	reg clk_sys = 0;   // 49.152 MHz
	reg clk_74a = 0;   // 74.25 MHz
	always #10.173 clk_sys = ~clk_sys;
	always #6.734  clk_74a = ~clk_74a;

	reg reset = 1;

	// ---- APF bridge (write side only) --------------------------------------
	reg         bridge_wr = 0;
	reg  [31:0] bridge_addr = 32'hF8000000;
	reg  [31:0] bridge_wr_data = 0;

	// ---- the real loader, exactly as core_top instantiates it --------------
	wire        bios_wr_raw;
	wire [27:0] bios_addr_raw;
	wire [15:0] bios_data_raw;

	data_loader #(
		.ADDRESS_MASK_UPPER_4(4'h1),
		.OUTPUT_WORD_SIZE(2)
	) slot_loader (
		.clk_74a   (clk_74a),
		.clk_memory(clk_sys),
		.bridge_wr          (bridge_wr),
		.bridge_endian_little(1'b0),
		.bridge_addr        (bridge_addr),
		.bridge_wr_data     (bridge_wr_data),
		.write_en  (bios_wr_raw),
		.write_addr(bios_addr_raw),
		.write_data(bios_data_raw)
	);

	// ---- the demux, verbatim from core_top ---------------------------------
	wire        ld_is_save         = bios_addr_raw[25];
	wire        stage_host_wr      = bios_wr_raw && ld_is_save;
	wire [24:0] stage_host_wr_addr = bios_addr_raw[24:0];
	wire [15:0] stage_host_wr_data = bios_data_raw;

	// ---- stage_mem + psram controller + chip -------------------------------
	wire [21:16] cram_a;
	wire [15:0]  cram_dq;
	wire cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n;
	wire cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;

	ngpc_stage_mem dut (
		.clk  (clk_sys),
		.reset(reset),
		.host_wr_i     (stage_host_wr),
		.host_wr_addr_i(stage_host_wr_addr),
		.host_wr_data_i(stage_host_wr_data),
		.host_rd_i     (1'b0),
		.host_rd_addr_i(25'd0),
		.host_rd_data_o(),
		.host_busy_o   (),
		.diag_beats_o  (),
		.diag_drops_o  (),
		.diag_depth_o  (),
		.eng_req_i  (1'b0),
		.eng_we_i   (1'b0),
		.eng_addr_i (25'd0),
		.eng_wdata_i(16'd0),
		.eng_ready_o(),
		.eng_done_o (),
		.eng_rdata_o(),
		.cram_a    (cram_a),
		.cram_dq   (cram_dq),
		.cram_wait (1'b0),
		.cram_clk  (cram_clk),
		.cram_adv_n(cram_adv_n),
		.cram_cre  (cram_cre),
		.cram_ce0_n(cram_ce0_n),
		.cram_ce1_n(cram_ce1_n),
		.cram_oe_n (cram_oe_n),
		.cram_we_n (cram_we_n),
		.cram_ub_n (cram_ub_n),
		.cram_lb_n (cram_lb_n)
	);

	// ---- behavioral CellularRAM (async mode) -------------------------------
	//
	// Synchronous shadow model on the controller's own clock: the controller is
	// synchronous, so sampling its outputs one cycle back reproduces what the
	// chip's async latches see. Address latches while adv_n is low; data
	// commits on we_n rising, using the values driven the cycle BEFORE the
	// edge (ce/ub/lb/dq all deassert on the same edge as we_n in the
	// controller, which real silicon resolves by hold time).
	reg [15:0] cmem [0:262143];
	reg [21:0] c_addr_l;
	reg        p_we, p_ce, p_ub, p_lb;
	reg [15:0] p_dq;
	reg [21:0] p_addr;

	always @(posedge clk_sys) begin
		p_we <= cram_we_n; p_ce <= cram_ce0_n;
		p_ub <= cram_ub_n; p_lb <= cram_lb_n;
		p_dq <= cram_dq;   p_addr <= c_addr_l;

		if (!cram_ce0_n && !cram_adv_n) begin
			c_addr_l <= {cram_a, cram_dq};
		end

		if (cram_we_n && !p_we && !p_ce) begin
			if (!p_ub) cmem[p_addr][15:8] <= p_dq[15:8];
			if (!p_lb) cmem[p_addr][7:0]  <= p_dq[7:0];
		end
	end

	// read side unused in this bench; never drive dq from the model
	assign cram_dq = 16'hZZZZ;

	// ---- the test ----------------------------------------------------------
	localparam integer WORDS16 = 2048;             // 4 KB image
	reg [7:0] img [0:WORDS16*2-1];

	integer i, k, errs, gap;

	task stream_image(input integer word_gap);
		integer j;
		reg [31:0] a, d;
		begin
			for (j = 0; j < WORDS16/2; j = j + 1) begin
				a = 32'h12000000 + j*4;
				d = {img[4*j], img[4*j+1], img[4*j+2], img[4*j+3]};
				@(posedge clk_74a);
				bridge_addr <= a; bridge_wr_data <= d; bridge_wr <= 1;
				@(posedge clk_74a); bridge_wr <= 0;
				repeat (word_gap) @(posedge clk_74a);
			end
			// drain: loader fifo + stage_mem + controller
			repeat (2000) @(posedge clk_74a);
		end
	endtask

	task check(input integer word_gap);
		begin
			errs = 0;
			for (k = 0; k < WORDS16; k = k + 1) begin
				if (cmem[k] !== {img[2*k+1], img[2*k]}) begin
					if (errs < 8)
						$display("   word %0d: got %h expected %h%h",
						         k, cmem[k], img[2*k+1], img[2*k]);
					errs = errs + 1;
				end
			end
			if (errs == 0) $display("   PASS (gap %0d: all %0d words byte-exact)", word_gap, WORDS16);
			else           $display("   FAIL (gap %0d: %0d of %0d words wrong)", word_gap, errs, WORDS16);
		end
	endtask

	integer total;

	initial begin
		total = 0;
		for (i = 0; i < WORDS16*2; i = i + 1) img[i] = (i * 7 + (i >> 6)) ^ 8'hA5;

		repeat (10) @(posedge clk_sys);
		reset = 0;
		repeat (10) @(posedge clk_sys);

		// APF's measured pacing is ~75 clk_74a per 32-bit word; also try
		// tighter and looser in case the failure is pacing-sensitive.
		$display("== gap 75 (measured APF pacing)");
		for (i = 0; i < 262144; i = i + 1) cmem[i] = 16'hCCCC;
		stream_image(75); check(75); total = total + errs;

		$display("== gap 20 (fast host)");
		for (i = 0; i < 262144; i = i + 1) cmem[i] = 16'hCCCC;
		stream_image(20); check(20); total = total + errs;

		// SD-chunk bursts: 128 words back-to-back, then a long gap -- the shape
		// a fast host with sector-granular reads actually produces. The skid
		// FIFO must ride these out; a truly sustained gap-4 stream exceeds the
		// PSRAM's physical service rate and no finite buffer can absorb it.
		$display("== bursty (128-word SD chunks at gap 4, ~54us between chunks)");
		for (i = 0; i < 262144; i = i + 1) cmem[i] = 16'hCCCC;
		begin : bursty
			integer j;
			reg [31:0] a, d;
			for (j = 0; j < WORDS16/2; j = j + 1) begin
				a = 32'h12000000 + j*4;
				d = {img[4*j], img[4*j+1], img[4*j+2], img[4*j+3]};
				@(posedge clk_74a);
				bridge_addr <= a; bridge_wr_data <= d; bridge_wr <= 1;
				@(posedge clk_74a); bridge_wr <= 0;
				repeat (4) @(posedge clk_74a);
				if ((j % 128) == 127) repeat (4000) @(posedge clk_74a);
			end
			repeat (4000) @(posedge clk_74a);
		end
		check(4); total = total + errs;

		if (total == 0) $display("== HOST WRITE LEG CLEAN IN SIMULATION");
		else            $display("== %0d TOTAL ERRORS", total);
		$finish;
	end

	initial begin
		#80_000_000;
		$display("== WATCHDOG TIMEOUT");
		$finish;
	end

endmodule

`default_nettype wire
