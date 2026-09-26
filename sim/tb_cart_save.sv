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
// BLOCK CHOICE: the small top blocks (8 KB, 8 KB, 16 KB on a 4 Mbit die) --
// where real NGPC saves live. The 64 KB blocks were used here once; two of
// them make a 128 KB image, which cannot fit a 64 KB staging bank and is
// far past the save slot a real image has to fit anyway.
//
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
	reg         save_slot_wr = 0;
	reg         state_apply = 0;
	reg   [5:0] block0 = 0;
	reg   [1:0] die_busy = 0;
	reg         host_busy = 0, slots_settled = 0;

	wire        boot_hold, busy, save_present, stage_bank, stage_current;
	// Staging is double-banked; APF only ever sees the committed one.
	wire [17:0] BANK = stage_bank ? 18'd32768 : 18'd0;
	wire        apply_reject;
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
		// Header words 16-18 are inside the checksummed span, so leaving
		// these unconnected poisons the CRC with X -- which is how this
		// bench gap was found.
		.diag_beats_i   (16'h1234),
		.diag_drops_i   (16'h0000),
		.cart_title_i   (96'h54524143545345544350474E),
		.cart_catalog_i (16'h0042),
		.cart_subcat_i  (8'h01),
		.size_code0_i   (size_code0),
		.size_code1_i   (size_code1),
		.event0_i       (event0),
		.block0_i       (block0),
		.event1_i       (1'b0),
		.block1_i       (6'd0),
		.die_busy_i     (die_busy),
		.host_busy_i    (host_busy),
		.state_apply_i   (state_apply),
		.save_slot_wr_i  (save_slot_wr),
		.apply_reject_o  (apply_reject),
		.stage_current_o (stage_current),
		.slots_settled_i(slots_settled),
		.save_present_o (save_present),
		.stage_bank_o   (stage_bank),
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
	reg [15:0] imgK [0:131327];      // the same, kept for the damage scenario

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

	// The staged payload is RLE-packed (V4): a literal passes through, a
	// run of erased words is the marker 0xFFFF plus its length. Unpack the
	// whole stream back into flat block order so the checks below can
	// compare it against the cartridge the way they always have.
	// Decoding is driven by the bitmap IN THE FILE, not by the engine's
	// live one -- that is what the decoder does, and it is why a corrupted
	// bitmap changes how many payload words get consumed.
	reg [15:0] dec [0:131071];
	integer dec_used;
	task decode_at(input integer base);
		integer pk, out, b, w, n, k;
		reg [15:0] word;
		reg [63:0] bmp;
		begin
			bmp = {psram[base+11], psram[base+10], psram[base+9], psram[base+8]};
			pk = 0; out = 0;
			for (b = 0; b < 64; b = b + 1) begin
				if (bmp[b]) begin
					g_block = b[5:0]; #1;
					w = 0;
					while (w < g_words && pk < 32512) begin
						word = psram[base + 256 + pk]; pk = pk + 1;
						if (word !== 16'hFFFF) begin
							dec[out] = word; out = out + 1; w = w + 1;
						end else begin
							n = psram[base + 256 + pk]; pk = pk + 1;
							if (n == 0) n = 1;
							for (k = 0; k < n; k = k + 1) begin
								dec[out] = 16'hFFFF; out = out + 1; w = w + 1;
							end
						end
					end
				end
			end
			dec_used = pk;
		end
	endtask
	task decode_payload; begin decode_at(BANK); end endtask

	// The image's own checksum, reimplemented here from the format rather
	// than from the engine: CRC32 over header words 0-18 and then the
	// packed payload, each word low byte first, as the file stores them.
	// When the DUT and this agree, two independent implementations agree.
	function [31:0] crc32_word_tb(input [31:0] c, input [15:0] w);
		integer b; reg [31:0] v;
		begin
			v = c;
			for (b = 0; b < 16; b = b + 1)
				v = (v[0] ^ w[b]) ? ((v >> 1) ^ 32'hEDB88320) : (v >> 1);
			crc32_word_tb = v;
		end
	endfunction

	function [31:0] crc_of(input integer base, input integer nwords);
		integer k; reg [31:0] c;
		begin
			c = 32'hFFFFFFFF;
			for (k = 0; k < nwords; k = k + 1) c = crc32_word_tb(c, psram[base + 256 + k]);
			crc_of = ~c;
		end
	endfunction

	// Write the staged image out exactly as APF would put it on the card,
	// so tools/savinfo.py can be pointed at a file this engine really
	// produced instead of one written to match the tool.
	task dump_image(input integer base);
		integer f, k;
		begin
			f = $fopen("sim/staged.sav", "wb");
			for (k = 0; k < 32512; k = k + 1) begin
				$fwrite(f, "%c%c", psram[base + k] & 8'hFF, psram[base + k] >> 8);
			end
			$fclose(f);
		end
	endtask

	// Re-stamp a hand-edited image so the checksum is not what rejects it.
	task stamp_crc(input integer base);
		reg [31:0] c;
		begin
			decode_at(base);
			c = crc_of(base, dec_used);
			psram[base + 19] = c[15:0];
			psram[base + 20] = c[31:16];
		end
	endtask

	// verify one decoded block at a given flat offset against sdram_gold
	task check_block(input [5:0] blk, input [24:0] off);
		integer w; integer bad;
		begin
			g_block = blk; #1;
			bad = 0;
			for (w = 0; w < g_words; w = w + 1)
				if (dec[off/2 + w] !== sdram_gold[(g_base>>1) + w]) bad = bad + 1;
			if (bad) begin
				errors = errors + 1;
				$display("   FAIL: block %0d payload, %0d words wrong", blk, bad);
			end
		end
	endtask

	integer i, n0, n2, offB, SPARE;
	reg bank_q, hd_q;
	reg [63:0] dirty_q;
	reg [15:0] keep [0:32767];       // a copy of the committed bank

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
		flash_write(6'd8);
		flash_write(6'd10);
		// dies quiet -> QUIET_CLOCKS(200) -> staging (two 64 KB blocks,
		// ~6 cycles a word: allow 2M)
		run_pass(2000, 2000000);
		// header
		if (psram[BANK+0] !== 16'h4E47 || psram[BANK+1] !== 16'h5043 ||
		    psram[BANK+2] !== 16'h5341 || psram[BANK+3] !== 16'h5634) begin
			errors = errors + 1; $display("   FAIL: magic %h %h %h %h",
			         psram[BANK+0],psram[BANK+1],psram[BANK+2],psram[BANK+3]);
		end
		if (psram[BANK+4] !== cart_crc[15:0] || psram[BANK+5] !== cart_crc[31:16]) begin
			errors = errors + 1; $display("   FAIL: crc %h%h", psram[BANK+5], psram[BANK+4]);
		end
		if (psram[BANK+8] !== 16'h0500) begin   // dirty0 = blocks 8 and 10
			errors = errors + 1; $display("   FAIL: bitmap %h expected 0500", psram[BANK+8]);
		end
		// payload: block 0 then block 2, in walk order
		decode_payload;
		check_block(6'd8, 25'd0);
		g_block = 6'd8; #1; offB = {g_words, 1'b0};
		check_block(6'd10, offB[24:0]);
		if ({psram[BANK+20], psram[BANK+19]} !== crc_of(BANK, dec_used)) begin
			errors = errors + 1;
			$display("   FAIL: stamped crc %h%h, expected %h",
			         psram[BANK+20], psram[BANK+19], crc_of(BANK, dec_used));
		end
		if (errors == 0) $display("   PASS (header + payload byte-exact, checksum stamped)");
		for (i = 0; i < 131328; i = i + 1) imgA[i] = psram[i];

		// ---- D: torn copy self-corrects ----------------------------------
		$display("== D  block rewritten mid-stage is re-staged");
		g_block = 6'd8; #1;
		sdram[(g_base>>1) + 8] = 16'h1111; sdram_gold[(g_base>>1) + 8] = 16'h1111;
		flash_write(6'd8);
		// Wait until block 8 is genuinely PART-COPIED before rewriting it.
		// Waiting only for `busy` is not enough: the walk scans from block 0,
		// so an event fired then lands before this block is read at all, the
		// copy captures the new data by itself, and clearing pending is right.
		// The case that must not be lost is a write landing after some of the
		// block has already been staged.
		i = 0;
		while (!(busy && dut.geo_block == 6'd8 && dut.block_word > 16'd64)
		       && i < 200000) begin i = i + 1; @(posedge clk); end
		if (!busy) begin errors = errors + 1; $display("   FAIL: restage never started"); end
		g_block = 6'd8; #1;
		sdram[(g_base>>1) + 9] = 16'h2222; sdram_gold[(g_base>>1) + 9] = 16'h2222;
		flash_write(6'd8);                 // marks it pending again mid-pass
		i = 0;
		while (busy && i < 2000000) begin i = i + 1; @(posedge clk); end
		run_pass(2000, 2000000);           // second pass carries the rewrite
		decode_payload;
		check_block(6'd8, 25'd0);
		if (errors == 0) $display("   PASS (second pass carried the rewrite)");
		for (i = 0; i < 131328; i = i + 1) begin imgA[i] = psram[i]; imgK[i] = psram[i]; end

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
		@(posedge clk); host_busy <= 1; save_slot_wr <= 1;
		for (i = 0; i < 131328; i = i + 1) psram[i] = imgA[i];
		repeat (50) @(posedge clk);
		save_slot_wr <= 0; host_busy <= 0;
		repeat (20) @(posedge clk);
		slots_settled <= 1;
		@(posedge clk);
		// corrupt the block regions so only the apply can heal them
		g_block = 6'd8; #1;
		for (i = 0; i < g_words; i = i + 1) sdram[(g_base>>1) + i] = 16'h0BAD;
		g_block = 6'd10; #1;
		for (i = 0; i < g_words; i = i + 1) sdram[(g_base>>1) + i] = 16'h0BAD;
		run_pass(2000, 2000000);
		if (boot_hold) begin errors = errors + 1; $display("   FAIL: boot never released"); end
		n2 = 0;
		g_block = 6'd8; #1;
		for (i = 0; i < g_words; i = i + 1)
			if (sdram[(g_base>>1) + i] !== sdram_gold[(g_base>>1) + i]) n2 = n2 + 1;
		g_block = 6'd10; #1;
		for (i = 0; i < g_words; i = i + 1)
			if (sdram[(g_base>>1) + i] !== sdram_gold[(g_base>>1) + i]) n2 = n2 + 1;
		if (n2) begin errors = errors + 1; $display("   FAIL: %0d words not restored", n2); end
		if (dut.dirty0 !== 64'h500) begin
			errors = errors + 1; $display("   FAIL: dirty bitmap %h after apply", dut.dirty0);
		end
		if (errors == 0) $display("   PASS (held through the race, applied byte-exact, bitmap restored)");

		// ---- E: late save delivery re-arms the apply (issue #3) ----------
		$display("== E  save slot arriving after the settle re-arms the apply");
		@(posedge clk);
		cart_ready <= 0; slots_settled <= 0;
		@(posedge clk); cart_replace <= 1;
		@(posedge clk); cart_replace <= 0;
		@(posedge clk);
		for (i = 0; i < 131328; i = i + 1) psram[i] = 16'hFEED;   // nothing delivered
		cart_ready <= 1;
		slots_settled <= 1;               // the settle window LIES: it fired early
		run_pass(2000, 200000);           // first apply runs on garbage, rejects magic
		if (dut.apply_pending !== 1'b0) begin
			errors = errors + 1; $display("   FAIL: pending not consumed by early apply");
		end
		// corrupt the block regions so only a re-apply can heal them
		g_block = 6'd8; #1;
		for (i = 0; i < g_words; i = i + 1) sdram[(g_base>>1) + i] = 16'h0BAD;
		g_block = 6'd10; #1;
		for (i = 0; i < g_words; i = i + 1) sdram[(g_base>>1) + i] = 16'h0BAD;
		// the save slot NOW arrives -- late, after the settle already fired
		@(posedge clk); host_busy <= 1; save_slot_wr <= 1;
		for (i = 0; i < 131328; i = i + 1) psram[i] = imgA[i];
		repeat (8) @(posedge clk);
		save_slot_wr <= 0; host_busy <= 0;
		// burst quiet (QUIET_CLOCKS=200) -> self-arm -> second apply
		run_pass(4000, 2000000);
		n2 = 0;
		g_block = 6'd8; #1;
		for (i = 0; i < g_words; i = i + 1)
			if (sdram[(g_base>>1) + i] !== sdram_gold[(g_base>>1) + i]) n2 = n2 + 1;
		g_block = 6'd10; #1;
		for (i = 0; i < g_words; i = i + 1)
			if (sdram[(g_base>>1) + i] !== sdram_gold[(g_base>>1) + i]) n2 = n2 + 1;
		if (n2) begin errors = errors + 1; $display("   FAIL: %0d words not healed by re-apply", n2); end
		else if (dut.dirty0 !== 64'h500) begin
			errors = errors + 1; $display("   FAIL: bitmap %h after re-apply", dut.dirty0);
		end else $display("   PASS (late delivery healed by the re-armed apply)");

		// ---- F: rejecting a state whose bitmap omits current dirt --------
		$display("== F  state load with an older bitmap is rejected");
		// forge an older image: same payload start, bitmap says only block 0
		for (i = 0; i < 131328; i = i + 1) psram[i] = imgA[i];
		psram[8] = 16'h0001; psram[32768+8] = 16'h0001;
		for (i = 0; i < 262144; i = i + 1) sdram_gold[i] = sdram[i];   // must stay put
		@(posedge clk); state_apply <= 1;
		@(posedge clk); state_apply <= 0;
		run_pass(2000, 200000);
		if (!apply_reject) begin
			errors = errors + 1; $display("   FAIL: reject flag not raised");
		end
		if (dut.dirty0 !== 64'h500) begin
			errors = errors + 1; $display("   FAIL: dirty bitmap changed to %h", dut.dirty0);
		end
		n2 = 0;
		for (i = 0; i < 262144; i = i + 1) if (sdram[i] !== sdram_gold[i]) n2 = n2 + 1;
		if (n2) begin errors = errors + 1; $display("   FAIL: SDRAM touched (%0d words)", n2); end
		if (errors == 0) $display("   PASS (rejected, bitmap and flash untouched)");

		// ---- G: an erased-only image must not claim the save slot --------
		// A game that merely erases a block on startup (Card Fighters does)
		// dirties it with nothing in it. Claiming the slot for that makes APF
		// overwrite a real save file on the card with 65 KB of erased flash --
		// the amplifier that turned one missed apply into permanent data loss.
		$display("== G  erased-only image must not claim the save slot");
		@(posedge clk);
		cart_ready <= 0; slots_settled <= 0;
		@(posedge clk); cart_replace <= 1;
		@(posedge clk); cart_replace <= 0;
		for (i = 0; i < 131328; i = i + 1) psram[i] = 16'hDEAD;   // no file at all
		@(posedge clk); cart_ready <= 1; slots_settled <= 1;
		run_pass(2000, 2000000);         // no-file boot: rejects, stages nothing
		if (save_present) begin
			errors = errors + 1; $display("   FAIL: slot claimed before any write");
		end
		// the game erases block 0 and writes nothing into it
		g_block = 6'd8; #1;
		for (i = 0; i < g_words; i = i + 1) begin
			sdram[(g_base>>1) + i] = 16'hFFFF; sdram_gold[(g_base>>1) + i] = 16'hFFFF;
		end
		flash_write(6'd8);
		run_pass(2000, 2000000);
		if (dut.dirty0 !== 64'h100) begin
			errors = errors + 1; $display("   FAIL: block 8 not marked dirty (%h)", dut.dirty0);
		end else if (save_present) begin
			errors = errors + 1;
			$display("   FAIL: erased-only image claimed the slot -- a real save");
			$display("         file on the card would be overwritten with nothing");
		end else $display("   PASS (dirty, but nothing to save: slot not claimed)");
		// and now a real save in another block must claim it again
		g_block = 6'd10; #1;
		sdram[(g_base>>1) + 3] = 16'hC0DE; sdram_gold[(g_base>>1) + 3] = 16'hC0DE;
		flash_write(6'd2);
		run_pass(2000, 2000000);
		if (!save_present) begin
			errors = errors + 1; $display("   FAIL: real save did not claim the slot");
		end else $display("   PASS (real data present: slot claimed)");

		// ---- H: a valid image nobody delivered must NOT be applied --------
		// The staging PSRAM is external and survives a core relaunch, so a
		// previous session's image can still be sitting there with good magic
		// and a matching CRC. Measured on hardware: ingest 0 beats, verdict
		// ACCEPTED, 16 KB written into a cartridge with no save of its own.
		$display("== H  undelivered stale image must not be applied");
		@(posedge clk);
		cart_ready <= 0; slots_settled <= 0;
		@(posedge clk); cart_replace <= 1;
		@(posedge clk); cart_replace <= 0;
		@(posedge clk);
		for (i = 0; i < 131328; i = i + 1) psram[i] = imgA[i];   // left behind
		for (i = 0; i < 262144; i = i + 1) sdram_gold[i] = sdram[i];
		cart_ready <= 1; slots_settled <= 1;                     // nothing delivered
		run_pass(2000, 2000000);
		n2 = 0;
		for (i = 0; i < 262144; i = i + 1) if (sdram[i] !== sdram_gold[i]) n2 = n2 + 1;
		if (n2) begin
			errors = errors + 1;
			$display("   FAIL: %0d words written into flash from an undelivered image", n2);
		end else if (dut.dirty0 !== 64'd0) begin
			errors = errors + 1;
			$display("   FAIL: stale bitmap adopted (%h)", dut.dirty0);
		end else $display("   PASS (no delivery, no apply, flash untouched)");

		// ---- I: a realistic save is mostly erased, and must pack small ----
		// Measured on real cartridges: Card Fighters packs 32 KB into about
		// 2 KB, Unitron 2's 72 KB into about 3.5 KB. This proves the encoder
		// actually packs rather than passing data through, and that what it
		// packs still decodes back byte for byte.
		$display("== I  erased-heavy image packs small and restores exactly");
		@(posedge clk);
		cart_ready <= 0; slots_settled <= 0;
		@(posedge clk); cart_replace <= 1;
		@(posedge clk); cart_replace <= 0;
		@(posedge clk); cart_ready <= 1; slots_settled <= 1;
		run_pass(2000, 2000000);
		// block 8: erased except a small record. block 10: fully erased.
		g_block = 6'd8; #1;
		for (i = 0; i < g_words; i = i + 1) begin
			sdram[(g_base>>1) + i] = (i < 64) ? (16'hA000 + i[15:0]) : 16'hFFFF;
			sdram_gold[(g_base>>1) + i] = sdram[(g_base>>1) + i];
		end
		g_block = 6'd10; #1;
		for (i = 0; i < g_words; i = i + 1) begin
			sdram[(g_base>>1) + i] = 16'hFFFF; sdram_gold[(g_base>>1) + i] = 16'hFFFF;
		end
		flash_write(6'd8);
		flash_write(6'd10);
		run_pass(2000, 2000000);
		$display("   packed %0d words for %0d raw words (%0d%%)",
		         dut.pack_ptr, 4096 + 8192, (dut.pack_ptr * 100) / (4096 + 8192));
		if (dut.pack_ptr > 16'd256) begin
			errors = errors + 1;
			$display("   FAIL: encoder did not pack (%0d words)", dut.pack_ptr);
		end
		decode_payload;
		check_block(6'd8, 25'd0);
		g_block = 6'd8; #1; offB = {g_words, 1'b0};
		check_block(6'd10, offB[24:0]);
		dump_image(BANK);
		if (errors == 0) $display("   PASS (packed small, decodes byte-exact)");

		// ---- J: a V2 save still restores, and is rewritten as V4 ---------
		// Upgrading must not look like data loss. A V2 file is raw blocks in
		// fixed slots; it is read as it always was and converted by the next
		// staging pass. Built here by hand rather than captured, so the old
		// format is pinned down independently of the code that wrote it.
		$display("== J  a V2 save restores and converts to V4");
		@(posedge clk);
		cart_ready <= 0; slots_settled <= 0;
		@(posedge clk); cart_replace <= 1;
		@(posedge clk); cart_replace <= 0;
		@(posedge clk);
		// give the two blocks known contents, then hand-build the V2 image
		g_block = 6'd8; #1;
		for (i = 0; i < g_words; i = i + 1) begin
			sdram_gold[(g_base>>1) + i] = 16'h5500 + i[15:0];
			psram[256 + i] = 16'h5500 + i[15:0];          // raw slot, block 8
		end
		n0 = g_words;
		g_block = 6'd10; #1;
		for (i = 0; i < g_words; i = i + 1) begin
			sdram_gold[(g_base>>1) + i] = 16'hAA00 + i[15:0];
			psram[256 + n0 + i] = 16'hAA00 + i[15:0];     // raw slot, block 10
		end
		psram[0] = 16'h4E47; psram[1] = 16'h5043;
		psram[2] = 16'h5341; psram[3] = 16'h5632;        // "V2"
		psram[4] = cart_crc[15:0]; psram[5] = cart_crc[31:16];
		psram[6] = 16'd0; psram[7] = 16'd0;
		psram[8] = 16'h0500; psram[9] = 16'd0;           // blocks 8 and 10
		for (i = 10; i < 32; i = i + 1) psram[i] = 16'd0;
		// the cartridge itself is blank: only the apply can fill it
		g_block = 6'd8; #1;
		for (i = 0; i < g_words; i = i + 1) sdram[(g_base>>1) + i] = 16'h0BAD;
		g_block = 6'd10; #1;
		for (i = 0; i < g_words; i = i + 1) sdram[(g_base>>1) + i] = 16'h0BAD;
		@(posedge clk); cart_ready <= 1; host_busy <= 1; save_slot_wr <= 1;
		repeat (8) @(posedge clk);
		save_slot_wr <= 0; host_busy <= 0;
		repeat (20) @(posedge clk);
		slots_settled <= 1;
		run_pass(4000, 2000000);
		n2 = 0;
		g_block = 6'd8; #1;
		for (i = 0; i < g_words; i = i + 1)
			if (sdram[(g_base>>1) + i] !== sdram_gold[(g_base>>1) + i]) n2 = n2 + 1;
		g_block = 6'd10; #1;
		for (i = 0; i < g_words; i = i + 1)
			if (sdram[(g_base>>1) + i] !== sdram_gold[(g_base>>1) + i]) n2 = n2 + 1;
		if (n2) begin
			errors = errors + 1;
			$display("   FAIL: %0d words not restored from the V2 image", n2);
		end else $display("   PASS (V2 image restored byte-exact)");
		// the next save rewrites the file in the new format
		flash_write(6'd8);
		run_pass(4000, 2000000);
		if (psram[BANK+3] !== 16'h5634) begin
			errors = errors + 1;
			$display("   FAIL: not converted to V4 (magic %h)", psram[BANK+3]);
		end else $display("   PASS (rewritten as V4)");

		// ---- K: a damaged image must be refused before flash is touched --
		// The decoder writes as it walks, so a checksum taken during the
		// decode would only ever confirm damage already done. The check is
		// a separate pass ahead of it, and this scenario is the reason.
		$display("== K  a damaged payload is refused, flash untouched");
		@(posedge clk);
		cart_ready <= 0; slots_settled <= 0;
		@(posedge clk); cart_replace <= 1;
		@(posedge clk); cart_replace <= 0;
		@(posedge clk);
		for (i = 0; i < 131328; i = i + 1) psram[i] = 16'hFEED;
		cart_ready <= 1;
		@(posedge clk); host_busy <= 1; save_slot_wr <= 1;
		for (i = 0; i < 131328; i = i + 1) psram[i] = imgK[i];
		psram[256 + 100] = psram[256 + 100] ^ 16'h0040;   // one bit of rot
		repeat (50) @(posedge clk);
		save_slot_wr <= 0; host_busy <= 0;
		repeat (20) @(posedge clk);
		slots_settled <= 1;
		@(posedge clk);
		g_block = 6'd8; #1;
		for (i = 0; i < g_words; i = i + 1) sdram[(g_base>>1) + i] = 16'h0BAD;
		g_block = 6'd10; #1;
		for (i = 0; i < g_words; i = i + 1) sdram[(g_base>>1) + i] = 16'h0BAD;
		for (i = 0; i < 262144; i = i + 1) sdram_gold[i] = sdram[i];
		run_pass(4000, 2000000);
		n2 = 0;
		for (i = 0; i < 262144; i = i + 1) if (sdram[i] !== sdram_gold[i]) n2 = n2 + 1;
		if (n2) begin errors = errors + 1; $display("   FAIL: %0d flash words written", n2); end
		if (dut.dirty0 !== 64'd0) begin
			errors = errors + 1; $display("   FAIL: bitmap committed as %h", dut.dirty0);
		end
		if (save_present) begin
			errors = errors + 1; $display("   FAIL: claimed the slot, so APF would overwrite the file");
		end
		if (errors == 0) $display("   PASS (refused; flash, bitmap and the file on the card all intact)");

		// ---- L: a pass torn by a flash write must not publish ------------
		// The encoder walks blocks in order and writes the header last, so a
		// block dirtied AFTER the walk went past it lands in the bitmap but
		// not in the payload -- and every block after it would then decode
		// from the wrong offset. A checksum cannot see this: it would cover
		// the broken image faithfully. The bank simply does not flip.
		$display("== L  a pass torn by a mid-walk flash write does not publish");
		@(posedge clk);
		cart_ready <= 0; slots_settled <= 0;
		@(posedge clk); cart_replace <= 1;
		@(posedge clk); cart_replace <= 0;
		@(posedge clk);
		for (i = 0; i < 131328; i = i + 1) psram[i] = 16'hDEAD;
		cart_ready <= 1; slots_settled <= 1;
		run_pass(4000, 2000000);          // no-file boot: nothing to apply
		flash_write(6'd8);
		flash_write(6'd10);
		run_pass(4000, 2000000);          // a clean pass commits blocks 8+10
		bank_q = stage_bank;
		if (psram[BANK+8] !== 16'h0500) begin
			errors = errors + 1; $display("   FAIL: setup bitmap %h", psram[BANK+8]);
		end
		// now tear one: dirty block 9 while the walk is inside block 10
		flash_write(6'd8);
		i = 0;
		while (!(busy && dut.geo_block == 6'd10 && dut.block_word > 16'd64)
		       && i < 400000) begin i = i + 1; @(posedge clk); end
		if (!busy) begin errors = errors + 1; $display("   FAIL: pass never reached block 10"); end
		flash_write(6'd9);                // block 9 is already behind the walk
		i = 0;
		while (busy && i < 2000000) begin i = i + 1; @(posedge clk); end
		if (stage_bank !== bank_q) begin
			errors = errors + 1;
			$display("   FAIL: the torn pass published (bank %b -> %b)", bank_q, stage_bank);
		end
		if (psram[BANK+8] !== 16'h0500) begin
			errors = errors + 1;
			$display("   FAIL: committed image changed to bitmap %h", psram[BANK+8]);
		end
		run_pass(4000, 4000000);          // the next pass carries all three
		if (psram[BANK+8] !== 16'h0700) begin
			errors = errors + 1;
			$display("   FAIL: retry bitmap %h, expected 0700", psram[BANK+8]);
		end
		decode_payload;
		if ({psram[BANK+20], psram[BANK+19]} !== crc_of(BANK, dec_used)) begin
			errors = errors + 1; $display("   FAIL: retry image checksum wrong");
		end
		if (errors == 0)
			$display("   PASS (torn pass withheld, the retry published all three blocks)");

		// ---- M: no bank flip while APF is moving the slot ----------------
		// APF reads (flush) and writes (delivery) the committed bank. A pass
		// that finishes mid-transfer must not flip it, or the file on the
		// card is half one image and half the other. The pass is owed and
		// publishes once the transfer is over.
		$display("== M  no bank flip while APF is moving the slot");
		bank_q = stage_bank;
		flash_write(6'd9);
		i = 0;
		while (!busy && i < 4000) begin i = i + 1; @(posedge clk); end
		if (!busy) begin errors = errors + 1; $display("   FAIL: pass never started"); end
		host_busy <= 1;                   // the exit flush begins mid-pass
		i = 0;
		while (busy && i < 4000000) begin i = i + 1; @(posedge clk); end
		if (stage_bank !== bank_q) begin
			errors = errors + 1; $display("   FAIL: flipped under the transfer");
		end
		repeat (2000) @(posedge clk);
		if (busy) begin errors = errors + 1; $display("   FAIL: a pass started during the transfer"); end
		host_busy <= 0;
		run_pass(4000, 4000000);
		if (stage_bank === bank_q) begin
			errors = errors + 1; $display("   FAIL: the owed pass never published");
		end
		decode_payload;
		if ({psram[BANK+20], psram[BANK+19]} !== crc_of(BANK, dec_used)) begin
			errors = errors + 1; $display("   FAIL: published image checksum wrong");
		end
		if (errors == 0) $display("   PASS (held through the transfer, published after it)");

		// ---- O: a savestate image goes to the spare bank ------------------
		// The copier drains a state's image into the SPARE bank (core_top
		// picks the bank per writer); the apply reads it there and commits it
		// by flipping only if it accepts it.
		$display("== O  an accepted savestate image is applied from the spare bank and committed");
		bank_q = stage_bank;
		SPARE = bank_q ? 0 : 32768;
		// the capture: the committed image as it is now
		for (i = 0; i < 32768; i = i + 1) psram[SPARE + i] = psram[BANK + i];
		for (i = 0; i < 262144; i = i + 1) sdram_gold[i] = sdram[i];
		// the game plays on and rewrites a word of block 9 (no event: the
		// block is already dirty, and an event would start a pass)
		g_block = 6'd9; #1;
		sdram[(g_base>>1) + 5] = 16'h7777;
		@(posedge clk); state_apply <= 1;
		@(posedge clk); state_apply <= 0;
		run_pass(4000, 4000000);
		if (apply_reject) begin errors = errors + 1; $display("   FAIL: refused a good state"); end
		if (stage_bank === bank_q) begin
			errors = errors + 1; $display("   FAIL: accepted state not committed (no flip)");
		end
		n2 = 0;
		for (i = 0; i < 262144; i = i + 1) if (sdram[i] !== sdram_gold[i]) n2 = n2 + 1;
		if (n2) begin errors = errors + 1; $display("   FAIL: %0d flash words not rewound", n2); end
		if (errors == 0) $display("   PASS (flash rewound to the state, its image committed)");

		$display("== O2 a refused savestate image leaves the committed bank and flash alone");
		bank_q = stage_bank;
		SPARE = bank_q ? 0 : 32768;
		for (i = 0; i < 32768; i = i + 1) keep[i] = psram[BANK + i];
		for (i = 0; i < 32768; i = i + 1) psram[SPARE + i] = psram[BANK + i];
		// a state whose bitmap claims one more block, and whose payload is
		// damaged: the bitmap check passes (it covers every dirty block),
		// the checksum does not
		psram[SPARE + 8] = psram[SPARE + 8] | 16'h0001;
		psram[SPARE + 256 + 3] = psram[SPARE + 256 + 3] ^ 16'h0100;
		dirty_q = dut.dirty0; hd_q = dut.image_has_data;
		for (i = 0; i < 262144; i = i + 1) sdram_gold[i] = sdram[i];
		@(posedge clk); state_apply <= 1;
		@(posedge clk); state_apply <= 0;
		run_pass(4000, 4000000);
		if (!apply_reject) begin errors = errors + 1; $display("   FAIL: damaged state accepted"); end
		if (stage_bank !== bank_q) begin errors = errors + 1; $display("   FAIL: bank flipped"); end
		n2 = 0;
		for (i = 0; i < 32768; i = i + 1) if (psram[BANK + i] !== keep[i]) n2 = n2 + 1;
		if (n2) begin errors = errors + 1; $display("   FAIL: committed image changed (%0d words)", n2); end
		// The bitmap may grow to the refused file's (a superset: the reject
		// check guarantees it); losing any of this session's blocks is the
		// failure.
		if ((dut.dirty0 & dirty_q) !== dirty_q) begin
			errors = errors + 1; $display("   FAIL: bitmap %h lost blocks of %h", dut.dirty0, dirty_q);
		end
		if (dut.image_has_data !== hd_q) begin
			errors = errors + 1; $display("   FAIL: data flag changed by a refused image");
		end
		n2 = 0;
		for (i = 0; i < 262144; i = i + 1) if (sdram[i] !== sdram_gold[i]) n2 = n2 + 1;
		if (n2) begin errors = errors + 1; $display("   FAIL: flash touched (%0d words)", n2); end
		if (errors == 0) $display("   PASS (refused; the exit file, bitmap and flash are as they were)");

		// ---- N: a V2 file cut at the slot restores only what it holds -----
		// Before packing, a save larger than the slot was cut at 0xFE00 while
		// its header still listed every block -- found on real cards for
		// Faselei!, Neo Turf Masters, Neo 21, Unitron 2 and Bust-A-Move. The
		// decode must stop at the slot, not pour the memory past it into
		// flash. Block 0 here is 64 KB, so the file cuts it 512 words short
		// and never reaches block 8.
		$display("== N  a V2 file cut at the slot size restores only what it holds");
		@(posedge clk);
		cart_ready <= 0; slots_settled <= 0;
		@(posedge clk); cart_replace <= 1;
		@(posedge clk); cart_replace <= 0;
		@(posedge clk);
		g_block = 6'd0; #1;
		if (g_words !== 16'd32768) begin
			errors = errors + 1; $display("   FAIL: bench assumes block 0 is 64 KB (%0d words)", g_words);
		end
		for (i = 0; i < 131328; i = i + 1) psram[i] = 16'h5A5A;     // what lies past the file
		for (i = 0; i < 32; i = i + 1) psram[i] = 16'd0;
		psram[0] = 16'h4E47; psram[1] = 16'h5043;
		psram[2] = 16'h5341; psram[3] = 16'h5632;                    // "V2"
		psram[4] = cart_crc[15:0]; psram[5] = cart_crc[31:16];
		psram[8] = 16'h0101;                                         // blocks 0 and 8
		for (i = 0; i < 32256; i = i + 1)                            // the file's payload
			psram[256 + i] = (i % 64 == 0) ? (16'h3300 + i[15:0]) : 16'hFFFF;
		for (i = 256; i < 512; i = i + 1) psram[i] = 16'h0000;       // header padding
		for (i = 0; i < 262144; i = i + 1) sdram_gold[i] = sdram[i];
		g_block = 6'd0; #1;
		for (i = 0; i < 32768; i = i + 1) begin
			sdram[(g_base>>1) + i] = 16'h0BAD;
			sdram_gold[(g_base>>1) + i] = (i < 32256) ? psram[256 + i] : 16'h0BAD;
		end
		g_block = 6'd8; #1;
		for (i = 0; i < g_words; i = i + 1) begin
			sdram[(g_base>>1) + i] = 16'h0BAD; sdram_gold[(g_base>>1) + i] = 16'h0BAD;
		end
		@(posedge clk); cart_ready <= 1; host_busy <= 1; save_slot_wr <= 1;
		repeat (8) @(posedge clk);
		save_slot_wr <= 0; host_busy <= 0;
		repeat (20) @(posedge clk);
		slots_settled <= 1;
		run_pass(4000, 4000000);
		n2 = 0;
		for (i = 0; i < 262144; i = i + 1) if (sdram[i] !== sdram_gold[i]) n2 = n2 + 1;
		if (n2) begin
			errors = errors + 1;
			$display("   FAIL: %0d flash words differ -- memory past the file reached flash", n2);
		end else $display("   PASS (the file's part restored, the rest of flash untouched)");

		// ---- P: an overflow must not hang a capture ---------------------
		// After an image too big for the slot, staging stands down for the
		// session. A later flash write leaves a pass owed that never comes;
		// a savestate or sleep waiting for it would hold the machine paused
		// forever.
		$display("== P  after an overflow, a capture still finds staging current");
		@(posedge clk);
		cart_ready <= 0; slots_settled <= 0;
		@(posedge clk); cart_replace <= 1;
		@(posedge clk); cart_replace <= 0;
		for (i = 0; i < 131328; i = i + 1) psram[i] = 16'hDEAD;
		@(posedge clk); cart_ready <= 1; slots_settled <= 1;
		run_pass(4000, 4000000);                   // no-file boot
		g_block = 6'd0; #1;
		for (i = 0; i < 32768; i = i + 1) sdram[(g_base>>1) + i] = 16'h1000 + i[15:0];
		flash_write(6'd0);                          // 64 KB of real data: cannot fit
		run_pass(4000, 8000000);
		if (!dut.pack_overflow) begin errors = errors + 1; $display("   FAIL: no overflow"); end
		flash_write(6'd8);                          // the game saves again
		repeat (2000) @(posedge clk);
		if (!stage_current) begin
			errors = errors + 1;
			$display("   FAIL: stage_current stuck low -- a capture would hang the machine");
		end else $display("   PASS (capture proceeds on the last image that fit)");

		// ---- Q: an all-erased V2 file must not claim the slot ------------
		// On the V2 path every word goes through the literal branch, erased
		// or not. Found on a real card (Neo Turf Masters): an old file of
		// nothing but erased flash was applied, claimed the slot, and was
		// written back as an equally empty V4 file.
		$display("== Q  an all-erased V2 file does not claim the slot");
		@(posedge clk);
		cart_ready <= 0; slots_settled <= 0;
		@(posedge clk); cart_replace <= 1;
		@(posedge clk); cart_replace <= 0;
		@(posedge clk);
		for (i = 0; i < 131328; i = i + 1) psram[i] = 16'hFFFF;
		for (i = 0; i < 32; i = i + 1) psram[i] = 16'd0;
		psram[0] = 16'h4E47; psram[1] = 16'h5043;
		psram[2] = 16'h5341; psram[3] = 16'h5632;                    // "V2"
		psram[4] = cart_crc[15:0]; psram[5] = cart_crc[31:16];
		psram[8] = 16'h0100;                                         // block 8, erased
		for (i = 32; i < 256; i = i + 1) psram[i] = 16'h0000;
		@(posedge clk); cart_ready <= 1; host_busy <= 1; save_slot_wr <= 1;
		repeat (8) @(posedge clk);
		save_slot_wr <= 0; host_busy <= 0;
		repeat (20) @(posedge clk);
		slots_settled <= 1;
		run_pass(4000, 4000000);
		if (dut.dirty0 !== 64'h100) begin
			errors = errors + 1; $display("   FAIL: bitmap %h, expected 0100", dut.dirty0);
		end else if (save_present) begin
			errors = errors + 1; $display("   FAIL: an erased-only V2 file claimed the slot");
		end else $display("   PASS (applied, dirty, but nothing to save: slot not claimed)");

		if (errors == 0) $display("== ALL CART-SAVE SCENARIOS PASS");
		else             $display("== %0d FAILURE(S)", errors);
		$finish;
	end

	initial begin
		#900_000_000;
		$display("== WATCHDOG TIMEOUT");
		$finish;
	end

	wire unused = &{1'b0, p2_be, boot_hold, 1'b0};

endmodule

`default_nettype wire
