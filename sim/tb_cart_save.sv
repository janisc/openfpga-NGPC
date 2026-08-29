// Testbench: the cartridge-save staging engine, against fake SDRAM and PSRAM.
//
// ngpc_cart_save had run zero verified cycles when this was written: every
// hardware round before it died on the savestate path first. The transport
// war established the rule this bench enforces -- the engine does not go to
// hardware until its lifecycle passes here.
//
// Real: ngpc_cart_save.sv and upstream's ngp_cart_overlay_geometry, compiled
// unmodified (QUIET_CLOCKS shrunk by parameter so a "20 ms" quiet is 200
// cycles of simulation).
//
// Modeled: cartridge SDRAM (p2 port, ready/done in 2 cycles), the PSRAM
// staging region (same shape), and the outside world: flash-write events from
// the cartridge, host_busy from the staging arbiter, and slots_settled from
// core_top's delivery detector.
//
// SCENARIOS
//   A  stage: game writes two flash blocks, dies go quiet -> engine stages
//      them; the PSRAM image must carry the header (magic, CRC, byte count,
//      bitmap) and the block payload in walk order.
//   B  boot-order: cart_replace + cart_ready with PSRAM still garbage -- the
//      engine must HOLD (boot_hold high, no apply) until slots_settled, which
//      the TB raises only after "APF" has copied the scenario-A image in.
//      Then the apply must land those blocks into a corrupted SDRAM and
//      restore the dirty bitmap. This is the race that killed every real
//      in-game save before the settle gate existed.
//   C  no-file boot: PSRAM garbage, slots settle -> apply must reject on the
//      magic and leave SDRAM untouched, boot_hold released.
//   D  torn copy: a flash write to a block WHILE it is being staged must mark
//      it pending again, and the next quiet pass must re-stage the new data.

`timescale 1ns / 1ps
`default_nettype none

module tb_cart_save;

	reg clk = 0;
	always #10.173 clk = ~clk;

	reg reset = 1;

	// ---- DUT wiring --------------------------------------------------------
	reg         cart_ready = 0, cart_replace = 0;
	reg  [31:0] cart_crc = 32'h600DCA57;
	reg  [24:0] cart_bytes = 25'h0080000;      // 512 KB image
	reg   [1:0] size_code0 = 2'd1;             // one 4 Mbit die
	reg   [1:0] size_code1 = 2'd0;             // second die absent

	reg         event0 = 0;
	reg   [5:0] block0 = 0;
	reg   [1:0] die_busy = 0;
	reg         host_busy = 0, slots_settled = 0;

	wire        boot_hold, busy;
	wire        p2_req, p2_we;
	wire [24:0] p2_addr;
	wire [15:0] p2_wdata;
	wire  [1:0] p2_be;
	wire        st_req, st_we;
	wire [24:0] st_addr;
	wire [15:0] st_wdata;

	// ---- fake cartridge SDRAM (die0 only: 512 KB = 256K words) -------------
	reg [15:0] sdram [0:262143];
	reg [15:0] sdram_gold [0:262143];
	reg        p2_done;
	reg [15:0] p2_rdata;
	reg        p2_pend;

	always @(posedge clk) begin
		p2_done <= 1'b0;
		if (p2_req) begin
			if (p2_we) sdram[p2_addr[18:1]] <= p2_wdata;
			else       p2_rdata <= sdram[p2_addr[18:1]];
			p2_pend <= 1'b1;
		end else if (p2_pend) begin
			p2_pend <= 1'b0;
			p2_done <= 1'b1;
		end
	end

	// ---- fake PSRAM staging region (0x40200 bytes = 131,328 words) ---------
	reg [15:0] psram [0:131327];
	reg        st_done;
	reg [15:0] st_rdata;
	reg        st_pend;

	always @(posedge clk) begin
		st_done <= 1'b0;
		if (st_req) begin
			if (st_we) psram[st_addr[17:1]] <= st_wdata;
			else       st_rdata <= psram[st_addr[17:1]];
			st_pend <= 1'b1;
		end else if (st_pend) begin
			st_pend <= 1'b0;
			st_done <= 1'b1;
		end
	end

	ngpc_cart_save #(
		.QUIET_CLOCKS (20'd200)
	) dut (
		.clk            (clk),
		.reset          (reset),
		.cart_ready_i   (cart_ready),
		.cart_replace_i (cart_replace),
		.cart_crc32_i   (cart_crc),
		.cart_bytes_i   (cart_bytes),
		.size_code0_i   (size_code0),
		.size_code1_i   (size_code1),
		.event0_i       (event0),
		.block0_i       (block0),
		.event1_i       (1'b0),
		.block1_i       (6'd0),
		.die_busy_i     (die_busy),
		.host_busy_i    (host_busy),
		.state_apply_i   (1'b0),
		.stage_current_o (),
		.slots_settled_i(slots_settled),
		.boot_hold_o    (boot_hold),
		.busy_o         (busy),
		.p2_req_o       (p2_req),
		.p2_we_o        (p2_we),
		.p2_addr_o      (p2_addr),
		.p2_wdata_o     (p2_wdata),
		.p2_be_o        (p2_be),
		.p2_ready_i     (1'b1),
		.p2_done_i      (p2_done),
		.p2_rdata_i     (p2_rdata),
		.stage_req_o    (st_req),
		.stage_we_o     (st_we),
		.stage_addr_o   (st_addr),
		.stage_wdata_o  (st_wdata),
		.stage_ready_i  (1'b1),
		.stage_done_i   (st_done),
		.stage_rdata_i  (st_rdata)
	);

	// TB-side geometry clone, for expected offsets of the chosen blocks
	reg  [5:0]  g_block;
	wire        g_valid;
	wire [20:0] g_base;
	wire [15:0] g_words;
	ngp_cart_overlay_geometry expect_geo (
		.size_code_i(size_code0), .block_i(g_block),
		.valid_o(g_valid), .base_o(g_base), .bytes_o(), .words_o(g_words)
	);

	// ---- helpers -----------------------------------------------------------
	integer errors;
	reg [15:0] imgA [0:131327];      // the scenario-A staged image, kept as gold

	task flash_write(input [5:0] blk);
		begin
			// the die goes busy, the write event fires, the die idles again
			@(posedge clk); die_busy <= 2'b01;
			@(posedge clk); block0 <= blk; event0 <= 1;
			@(posedge clk); event0 <= 0;
			repeat (4) @(posedge clk); die_busy <= 2'b00;
		end
	endtask

	// Wait for the engine to START (busy rise) and then FINISH (busy fall).
	// Polling busy alone races the quiet delay: the engine is legitimately
	// idle for QUIET_CLOCKS before it begins, and the first version of this
	// task sailed straight through that window and judged untouched memory.
	task run_pass(input integer rise_max, input integer fall_max);
		integer n;
		begin
			n = 0;
			@(posedge clk);
			while (!busy && n < rise_max) begin n = n + 1; @(posedge clk); end
			if (!busy) begin errors = errors + 1; $display("   FAIL: engine never started"); end
			n = 0;
			while (busy && n < fall_max) begin n = n + 1; @(posedge clk); end
			if (busy) begin errors = errors + 1; $display("   FAIL: engine stuck busy"); end
		end
	endtask

	// verify one staged block at a given payload offset against sdram_gold
	task check_block(input [5:0] blk, input [24:0] off);
		integer w; integer bad;
		begin
			g_block = blk; #1;
			bad = 0;
			for (w = 0; w < g_words; w = w + 1)
				if (psram[(25'd512 + off)/2 + w] !== sdram_gold[(g_base>>1) + w]) bad = bad + 1;
			if (bad) begin
				errors = errors + 1;
				$display("   FAIL: block %0d payload, %0d words wrong", blk, bad);
			end
		end
	endtask

	integer i, n0, n2, offB;

	// transition monitor: every change of apply_pending, with context
	reg ap_q = 0;
	always @(posedge clk) begin
		ap_q <= dut.apply_pending;
		if (dut.apply_pending !== ap_q)
			$display("   [ap] t=%0t pending %b->%b state=%0d settled=%b ready=%b replace=%b",
			         $time, ap_q, dut.apply_pending, dut.state, slots_settled, cart_ready, cart_replace);
	end

	initial begin
		errors = 0;
		for (i = 0; i < 262144; i = i + 1) begin
			sdram[i] = i[15:0] ^ 16'hBEEF; sdram_gold[i] = sdram[i];
		end
		for (i = 0; i < 131328; i = i + 1) psram[i] = 16'hDEAD;

		repeat (10) @(posedge clk);
		reset <= 0;
		// a fresh cart arrives and settles, with nothing staged for it.
		// All DUT-facing stimulus uses <= at an edge: a blocking assign in the
		// same timestep as a posedge races the DUT's sampling (scenario B lost
		// exactly that race and its replace pulse vanished).
		@(posedge clk); cart_replace <= 1;
		@(posedge clk); cart_replace <= 0;
		@(posedge clk);
		cart_ready <= 1;
		slots_settled <= 1;                // no file: garbage PSRAM
		run_pass(2000, 200000);
		$display("== C  no-file boot: apply must reject garbage");
		if (boot_hold) begin errors = errors + 1; $display("   FAIL: boot still held"); end
		else begin
			n0 = 0;
			for (i = 0; i < 262144; i = i + 1) if (sdram[i] !== sdram_gold[i]) n0 = n0 + 1;
			if (n0) begin errors = errors + 1; $display("   FAIL: SDRAM modified (%0d words)", n0); end
			else $display("   PASS (rejected, SDRAM untouched, boot released)");
		end

		// ---- A: the game saves -------------------------------------------
		$display("== A  stage two written blocks on quiescence");
		flash_write(6'd0);
		flash_write(6'd2);
		// dies quiet -> QUIET_CLOCKS(200) -> staging (two 64 KB blocks,
		// ~6 cycles a word: allow 2M)
		run_pass(2000, 2000000);
		// header
		if (psram[0] !== 16'h4E47 || psram[1] !== 16'h5043 ||
		    psram[2] !== 16'h5341 || psram[3] !== 16'h5632) begin
			errors = errors + 1; $display("   FAIL: magic %h %h %h %h", psram[0],psram[1],psram[2],psram[3]);
		end
		if (psram[4] !== cart_crc[15:0] || psram[5] !== cart_crc[31:16]) begin
			errors = errors + 1; $display("   FAIL: crc %h%h", psram[5], psram[4]);
		end
		if (psram[8] !== 16'h0005) begin   // dirty0 = blocks 0 and 2
			errors = errors + 1; $display("   FAIL: bitmap %h expected 0005", psram[8]);
		end
		// payload: block 0 then block 2, in walk order
		check_block(6'd0, 25'd0);
		g_block = 6'd0; #1; offB = {g_words, 1'b0};
		check_block(6'd2, offB[24:0]);
		if (errors == 0) $display("   PASS (header + payload byte-exact)");
		for (i = 0; i < 131328; i = i + 1) imgA[i] = psram[i];

		// ---- D: torn copy self-corrects ----------------------------------
		$display("== D  block rewritten mid-stage is re-staged");
		sdram[16'h0010] = 16'h1111; sdram_gold[16'h0010] = 16'h1111;   // block 0 changes
		flash_write(6'd0);
		// wait for staging to START, then fire another write mid-copy
		i = 0;
		while (!busy && i < 100000) begin i = i + 1; @(posedge clk); end
		if (!busy) begin errors = errors + 1; $display("   FAIL: restage never started"); end
		sdram[16'h0011] = 16'h2222; sdram_gold[16'h0011] = 16'h2222;
		flash_write(6'd0);                 // marks it pending again mid-pass
		i = 0;
		while (busy && i < 2000000) begin i = i + 1; @(posedge clk); end
		run_pass(2000, 2000000);           // second pass carries the rewrite
		check_block(6'd0, 25'd0);
		if (errors == 0) $display("   PASS (second pass carried the rewrite)");
		for (i = 0; i < 131328; i = i + 1) imgA[i] = psram[i];

		// ---- B: the boot-order race --------------------------------------
		$display("== B  apply waits for slot delivery, then lands");
		@(posedge clk);
		cart_ready <= 0; slots_settled <= 0;
		@(posedge clk); cart_replace <= 1;
		@(posedge clk); cart_replace <= 0;
		@(posedge clk);
		for (i = 0; i < 131328; i = i + 1) psram[i] = 16'hFEED;   // PSRAM garbage again
		cart_ready <= 1;                    // cartridge is in; save NOT delivered yet
		repeat (5000) @(posedge clk);
		$display("   [dbg] state=%0d pending=%b busy=%b hold=%b settled=%b ready=%b",
		         dut.state, dut.apply_pending, busy, boot_hold, slots_settled, cart_ready);
		if (!boot_hold) begin errors = errors + 1; $display("   FAIL: not holding boot through the wait"); end
		if (!busy && dut.apply_pending !== 1'b1) begin
			errors = errors + 1; $display("   FAIL: apply consumed before delivery");
		end
		// "APF" now streams the save slot in, then everything settles
		@(posedge clk); host_busy <= 1;
		for (i = 0; i < 131328; i = i + 1) psram[i] = imgA[i];
		repeat (50) @(posedge clk);
		host_busy <= 0;
		repeat (20) @(posedge clk);
		slots_settled <= 1;
		@(posedge clk);
		// corrupt the block regions so only the apply can heal them
		g_block = 6'd0; #1;
		for (i = 0; i < g_words; i = i + 1) sdram[(g_base>>1) + i] = 16'h0BAD;
		g_block = 6'd2; #1;
		for (i = 0; i < g_words; i = i + 1) sdram[(g_base>>1) + i] = 16'h0BAD;
		run_pass(2000, 2000000);
		if (boot_hold) begin errors = errors + 1; $display("   FAIL: boot never released"); end
		n2 = 0;
		g_block = 6'd0; #1;
		for (i = 0; i < g_words; i = i + 1)
			if (sdram[(g_base>>1) + i] !== sdram_gold[(g_base>>1) + i]) n2 = n2 + 1;
		g_block = 6'd2; #1;
		for (i = 0; i < g_words; i = i + 1)
			if (sdram[(g_base>>1) + i] !== sdram_gold[(g_base>>1) + i]) n2 = n2 + 1;
		if (n2) begin errors = errors + 1; $display("   FAIL: %0d words not restored", n2); end
		if (dut.dirty0 !== 64'h5) begin
			errors = errors + 1; $display("   FAIL: dirty bitmap %h after apply", dut.dirty0);
		end
		if (errors == 0) $display("   PASS (held through the race, applied byte-exact, bitmap restored)");

		if (errors == 0) $display("== ALL CART-SAVE SCENARIOS PASS");
		else             $display("== %0d FAILURE(S)", errors);
		$finish;
	end

	initial begin
		#400_000_000;
		$display("== WATCHDOG TIMEOUT");
		$finish;
	end

	wire unused = &{1'b0, p2_be, boot_hold, 1'b0};

endmodule

`default_nettype wire
