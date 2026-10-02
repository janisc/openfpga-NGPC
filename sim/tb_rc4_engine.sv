// Testbench: the rc4 save-engine contract (rc4_spec.md S1-S10), against
// fake SDRAM and PSRAM.
//
// Written from the specification, not from the implementation. Every check
// is on a port, on PSRAM or SDRAM contents, or on a header word the engine
// stamps. The one internal it reads is dirty0, which predates rc4.
//
// Real: ngpc_cart_save.sv and upstream's ngp_cart_overlay_geometry,
// compiled unmodified with NGPC_SAVE_DIAG (header words 18 and 23 are
// diagnostics) and QUIET_CLOCKS shrunk to 200.
//
// Modeled around it:
//   - cartridge SDRAM (p2 port) and the PSRAM staging region, ready/done in
//     2 cycles, exactly as tb_cart_save models them;
//   - APF: delivers a file into the COMMITTED bank (core_top routes APF
//     writes there) with save_slot_wr for the burst, and host_busy trailing
//     the last beat by less than QUIET_CLOCKS, as on hardware (10 ms vs 20);
//   - the copier (rc4 C1/C2): waits for stage_current, raises draining --
//     which core_top also ORs into host_busy -- drains the state's image
//     into the SPARE bank, pulses state_apply, waits for state_done, then
//     lowers draining; diag_drain counts its 32512 host writes per drain;
//   - the game: flash writes on die 0 (die_busy, the event, die idle).
//
// GEOMETRY: one 4 Mbit die. Its top blocks 8, 9 (8 KB) and 10 (16 KB) are
// this bench's analog of the 16 Mbit blocks 32, 33 and 34 of issue #3.
// Block contents are mostly erased with a few literals, as real saves are,
// which keeps every pass and apply short.
//
// WHAT IT OBSERVES
//   - applies: each apply's header walk starts by reading word 0 of the bank
//     it applies from, so a read of word 0 of either bank marks one apply and
//     tells which bank it read (hdr_rd / hdr_bank);
//   - staging passes: engine writes into PSRAM (eng_wr);
//   - flash writes: engine p2 writes (p2wr);
//   - publishes: stage_bank_o changes (flips).
//
// SCENARIOS (spec items in brackets)
//   S2-PU     stage_bank_o powers up 0 [S2]
//   S1a-TAG   issue #3 end to end: a delivered V3-tagged file with blocks
//             {8,9,10} is refused; the game writes block 10 and erases it
//             again; nothing publishes and the committed bank stays byte-
//             identical to the file [S1a]
//   S1c       frozen: an accepted state load writes flash and sets dirty to
//             its bitmap, but commits no bank and publishes nothing
//             afterwards [S1, S2, S4]
//   S1a-RELOAD frozen, then cart_replace: the same delivered file is read
//             again (S3) and refused again, re-freezing [S1, S3]
//   S1a-CRC   the same freeze for a cart-CRC refusal (word 5) [S1a]
//   S1a-FIX   cart_replace to the file's own cartridge clears the freeze and
//             the file, delivered before the reload, is applied [S1, S3]
//   S3-CRC-RELOAD5/4 the same (wrong) cartridge reloaded: the file delivered
//             before the reload fails only the cartridge CRC (word 5, then
//             word 4). rc5: verdict 4 and the session FREEZES again, the
//             committed bank stays the file; applies/p2 writes restart at
//             cart_replace [S3 rc5, S1a, S10]
//   S1a-MAGIC the same freeze for a magic refusal (word 2) [S1a]
//   S1a-PAY   the same freeze for a payload-CRC refusal, flash untouched [S1a]
//   S1a-PAY-RELOAD reload: the pre-reload file is refused on its payload
//             again, which is not a CRC mismatch, so it freezes again [S3]
//   S1a-RESET reset ALONE (no cart_replace) clears the freeze and both
//             delivery flags: verdict 5, the game's save publishes [S1, S3]
//   S1a-LATE  the slow-card path: the game has saved and published, then a
//             late file arrives and its re-armed apply refuses it -> freeze,
//             dirty unchanged, the committed bank stays the file [S1a, S4]
//   S1b-WAKE  x3 (tag, cart CRC, payload CRC): a wake with nothing
//             delivered and dirty empty; the state image is refused ->
//             apply_reject with state_done, one apply on the spare bank serves
//             the pending boot apply too, and the session freezes [S1b, S7, S8]
//             rc5: the cart-CRC variant is S6 "no image" now: a no-op accept,
//             no freeze, verdict 6 at fail_idx 4 [S6 rc5]
//   S1b-DIRTY mid-session (dirty nonempty): refused, no freeze [S1b, S4]
//   S1b-BASE  an apply was accepted (dirty empty): refused, no freeze [S1b]
//   S1b-EPOCH an accepted state, then cart_replace: no base any more, so a
//             refused state with dirty empty freezes [S1b]
//   S2        stage_bank_o survives reset and cart_replace [S2]
//   S3        delivery, then cart_replace, then cart_ready: accepted [S3, S10]
//   S4a/S5b   a late re-armed boot apply with a dirty block the image lacks
//             is accepted (S5: no coverage refusal for a boot apply). rc5:
//             dirty = the image's bitmap, the session's block is dropped, and
//             the next pass carries the file's blocks only [S4 rc5, S5]
//   S4b       a refused state apply leaves dirty exactly as it was [S4, S7]
//   S5a       coverage reject is a reject for a state: no freeze, no writes,
//             apply_reject holds until the next apply [S5, S10]
//   S6a       no-image state, dirty empty: no-op accept, verdict 6 [S6]
//   S6b       no-image state, dirty nonempty: reject, verdict 6 [S6]
//   S8a       state_apply during a running boot apply: a second apply reads
//             the SPARE bank; state_done once, only after it; word 22 = 2
//             [S8, S10]
//   S8b       x6: state_apply pulsed from 2 cycles before to 3 after the
//             boot apply's start: never lost [S8]
//   S8c       a boot apply is held off while draining; the state request is
//             served instead, by one apply (word 22 = 1); dirty = the
//             image's bitmap [S8, S4, S10]
//   S9a       die_busy held across the end of a pass: no publish until it
//             clears, then the owed pass publishes [S9]
//   S9b       the review's race: a pass owed, a late delivery, host_busy
//             falls before the re-arm -> no pass runs first; the re-armed
//             apply restores the delivered blocks and the committed image
//             carries them (rc5: and only them, dirty = the file's bitmap)
//             [S9, S4 rc5]
//   S10-18    header word 18 = diag_drain_i at stamping time [S10]
//   S10-23    header word 23 for verdicts 1 (boot and state), 2, 3, 4 (tag),
//             5 and 6 (no magic; rc5: a state's cart CRC word 5 / word 4
//             mismatch, fail_idx 5 / 4) [S10, S6 rc5]
//
// rc5 (rc5_spec.md). The engine gained state_frozen_i, state_fail_i and
// frozen_o. This bench has no bridge, so state_frozen_i and state_fail_i are
// tied low; the rc5 items they drive are in tb_rc5_engine.sv. Every
// expectation that rc5 changed says "rc5" where it is checked:
//   - S4: an accepted boot apply sets dirty to the image's bitmap; the rc4
//     union is gone (S4a/S5b, S9b);
//   - S3/S1a: a pre-reload file that fails only the cartridge CRC now
//     freezes like any other refused delivery (S3-CRC-RELOAD5/4 invert);
//   - S6: a state whose magic matches but whose cartridge CRC is another
//     cartridge's is "no image" -- a no-op at a wake, not a freeze
//     (S1b-WAKE-CRC), and verdict 6 rather than 4 (S10-23);
//   - S10: header word 21 is {8'h06, cart_subcat} (check_committed; rc6);
//   - S1: frozen_o is refused_q, so every frozen window also checks it.
// Internals read: dut.dirty0 (predates rc4); dut.diag_verdict,
// dut.diag_applies and dut.diag_p2wr only in S3-CRC-RELOAD*, where the
// session is frozen and no header carrying them is ever staged.
//
// Run: wsl -e sh sim/run_rc4_engine.sh

`timescale 1ns / 1ps
`default_nettype none

`define FAIL(a) begin errors = errors + 1; $write("   FAIL [%0s] ", scn); $display a ; end

module tb_rc4_engine;

	reg clk = 0;
	always #10.173 clk = ~clk;

	reg reset = 1;

	localparam integer QUIET  = 200;        // = QUIET_CLOCKS below
	localparam integer FILE_W = 32512;      // the .sav: 0xFE00 bytes
	localparam integer BANK_W = 32768;      // one staging bank, in words
	localparam [15:0]  TAG_V4 = 16'h5634;
	localparam [15:0]  TAG_V3 = 16'h5633;   // the PR #5 test build's tag
	localparam [15:0]  BEATS  = 16'h1234;   // diag_beats_i, stamped as word 16
	localparam [31:0]  CRC0   = 32'h600DCA57;

	// ---- DUT wiring --------------------------------------------------------
	reg         cart_ready = 0, cart_replace = 0;
	reg  [31:0] cart_crc   = CRC0;
	reg  [24:0] cart_bytes = 25'h0080000;
	reg   [1:0] size_code0 = 2'd1;             // one 4 Mbit die
	reg   [1:0] size_code1 = 2'd0;             // second die absent

	reg         event0 = 0;
	reg   [5:0] block0 = 0;
	reg   [1:0] die_busy = 0;
	reg         apf_busy = 0;                  // stage_mem's host_busy_o
	reg         draining = 0;                  // the copier's draining_o
	reg         slots_settled = 0;
	reg         save_slot_wr = 0;
	reg         state_apply = 0;
	reg  [15:0] diag_drain = 16'd0;            // the copier's diag_drain_o

	wire        boot_hold, busy, save_present, stage_current, stage_bank;
	wire        apply_reject, state_done;
	wire        frozen;                        // rc5: frozen_o = refused_q
	wire        p2_req, p2_we;
	wire [24:0] p2_addr;
	wire [15:0] p2_wdata;
	wire  [1:0] p2_be;
	wire        st_req, st_we;
	wire [24:0] st_addr;
	wire [15:0] st_wdata;

	// ---- fake cartridge SDRAM (die0 only: 512 KB = 256K words) -------------
	reg [15:0] sdram [0:262143];
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
		.clk             (clk),
		.reset           (reset),
		.cart_ready_i    (cart_ready),
		.cart_replace_i  (cart_replace),
		.cart_crc32_i    (cart_crc),
		.cart_bytes_i    (cart_bytes),
		.cart_title_i    (96'h54524143545345544350474E),
		.cart_catalog_i  (16'h0042),
		.cart_subcat_i   (8'h01),
		.size_code0_i    (size_code0),
		.size_code1_i    (size_code1),
		.event0_i        (event0),
		.block0_i        (block0),
		.event1_i        (1'b0),
		.block1_i        (6'd0),
		.die_busy_i      (die_busy),
		// core_top (rc6): .host_busy(host_busy); the drain is draining_i
		.host_busy_i     (apf_busy),
		.host_rd_i       (1'b0),         // no APF flush read modelled here
		.state_apply_i   (state_apply),
		.draining_i      (draining),
		// rc5: no bridge here. A state is never from a frozen session and no
		// load is ever reported failed except through the engine's own
		// apply_reject (tb_rc5_engine drives both).
		.state_frozen_i  (1'b0),
		.state_fail_i    (1'b0),
		.frozen_o        (frozen),
		.save_slot_wr_i  (save_slot_wr),
		.apply_reject_o  (apply_reject),
		.state_done_o    (state_done),
		.slots_settled_i (slots_settled),
		.diag_beats_i    (BEATS),
		.diag_drops_i    (16'h0000),
		.diag_drain_i    (diag_drain),
		.boot_hold_o     (boot_hold),
		.busy_o          (busy),
		.save_present_o  (save_present),
		.stage_current_o (stage_current),
		.stage_bank_o    (stage_bank),
		.p2_req_o        (p2_req),
		.p2_we_o         (p2_we),
		.p2_addr_o       (p2_addr),
		.p2_wdata_o      (p2_wdata),
		.p2_be_o         (p2_be),
		.p2_ready_i      (1'b1),
		.p2_done_i       (p2_done),
		.p2_rdata_i      (p2_rdata),
		.stage_req_o     (st_req),
		.stage_we_o      (st_we),
		.stage_addr_o    (st_addr),
		.stage_wdata_o   (st_wdata),
		.stage_ready_i   (1'b1),
		.stage_done_i    (st_done),
		.stage_rdata_i   (st_rdata)
	);

	// ---- observers ----------------------------------------------------------
	integer errors = 0;
	string  scn = "setup";

	integer eng_wr  = 0;     // engine writes into PSRAM: staging passes
	integer hdr_rd  = 0;     // header word 0 reads: one per apply
	reg     hdr_bank [0:4095];
	integer p2wr    = 0;     // engine writes into cartridge flash
	integer flips   = 0;     // stage_bank_o changes
	integer sd_cnt  = 0;     // state_done_o pulses
	integer sa_cnt  = 0;     // state_apply_i pulses issued
	reg     sd_rej  = 0;     // apply_reject_o in the state_done_o cycle
	integer bad_flip = 0;    // bank changes while a die or APF was busy
	reg     frz_en  = 0;     // a frozen window is being watched
	integer frz_cur = 0;     // ...cycles idle with stage_current low
	integer frz_sp  = 0;     // ...cycles with save_present high
	reg     bank_q  = 1'b0;
	reg [1:0] die_busy_q = 2'b00;
	reg     apf_busy_q = 1'b0;

	always @(posedge clk) begin
		if (st_req === 1'b1 && st_we === 1'b1) eng_wr <= eng_wr + 1;
		if (st_req === 1'b1 && st_we === 1'b0 && st_addr[15:0] == 16'd0) begin
			hdr_bank[hdr_rd % 4096] <= st_addr[16];
			hdr_rd <= hdr_rd + 1;
		end
		if (p2_req === 1'b1 && p2_we === 1'b1) p2wr <= p2wr + 1;
		if (state_done === 1'b1) begin
			sd_cnt <= sd_cnt + 1;
			sd_rej <= apply_reject;
		end
		// A change seen here was made at the previous edge, when the DUT
		// saw die_busy_q / apf_busy_q.
		bank_q     <= stage_bank;
		die_busy_q <= die_busy;
		apf_busy_q <= apf_busy;
		if ((stage_bank ^ bank_q) === 1'b1) begin
			flips <= flips + 1;
			if (die_busy_q != 2'b00 || apf_busy_q) begin
				bad_flip <= bad_flip + 1;
				$display("   [flip] t=%0t bank %b -> %b while die_busy=%b apf_busy=%b",
				         $time, bank_q, stage_bank, die_busy_q, apf_busy_q);
			end
		end
		if (frz_en) begin
			// busy_o low is taken as "the engine is idle" (S_IDLE, no apply
			// pending); every existing transition moves both together.
			if (busy === 1'b0 && cart_ready && stage_current !== 1'b1) frz_cur <= frz_cur + 1;
			if (save_present !== 1'b0) frz_sp <= frz_sp + 1;
		end
	end

	// ---- scenario bookkeeping -----------------------------------------------
	integer scn_e0, scn_bal0;
	integer n_scn = 0, n_scn_fail = 0;

	task begin_scn(input string name, input string what);
		begin
			scn      = name;
			scn_e0   = errors;
			scn_bal0 = sd_cnt - sa_cnt;
			$display("== %0s  %0s", name, what);
		end
	endtask

	// S8: state_done_o pulses exactly once per state_apply_i pulse, and
	// never for a boot apply. Checked for every scenario.
	task end_scn;
		begin
			repeat (4) @(posedge clk);
			if (sd_cnt - sa_cnt != scn_bal0)
				`FAIL(("state_done pulses minus state_apply pulses = %0d in this scenario (S8: exactly one each)",
				       sd_cnt - sa_cnt - scn_bal0))
			n_scn = n_scn + 1;
			if (errors == scn_e0) $display("   PASS %0s", scn);
			else begin
				n_scn_fail = n_scn_fail + 1;
				$display("   FAIL %0s (%0d check(s))", scn, errors - scn_e0);
			end
		end
	endtask

	// ---- geometry, as the bench knows it (checked against upstream below) ---
	function integer bwords(input integer b);
		begin
			if (b < 7)                 bwords = 32768;
			else if (b == 7)           bwords = 16384;
			else if (b == 8 || b == 9) bwords = 4096;
			else if (b == 10)          bwords = 8192;
			else                       bwords = 0;
		end
	endfunction

	function integer bbase(input integer b);        // SDRAM word address
		begin
			if (b < 7)       bbase = b * 32768;
			else if (b == 7) bbase = 32'h38000;
			else if (b == 8) bbase = 32'h3C000;
			else if (b == 9) bbase = 32'h3D000;
			else             bbase = 32'h3E000;
		end
	endfunction

	reg   [5:0] g_block = 6'd0;
	wire        g_valid;
	wire [20:0] g_base;
	wire [15:0] g_words;
	ngp_cart_overlay_geometry chk_geo (
		.size_code_i(2'd1), .block_i(g_block),
		.valid_o(g_valid), .base_o(g_base), .bytes_o(), .words_o(g_words)
	);

	// Block content for a seed: a few literals, as a real save has, in an
	// otherwise erased block. Seed 0 is an erased block. Seeds stay below
	// 0xF0 so a literal is never 0xFFFF.
	function [15:0] cval(input [7:0] seed, input [5:0] b, input [15:0] w);
		begin
			if (seed == 8'h00)   cval = 16'hFFFF;
			else if (w < 16'd16) cval = {seed, b[3:0], w[3:0]};
			else if (w == 16'd1000) cval = {seed, 8'hE8};
			else                 cval = 16'hFFFF;
		end
	endfunction

	task sd_fill(input integer b, input [7:0] seed);
		integer w;
		begin
			for (w = 0; w < bwords(b); w = w + 1) sdram[bbase(b) + w] = cval(seed, b, w);
		end
	endtask

	function integer sd_bad(input integer b, input [7:0] seed);
		integer w, n;
		begin
			n = 0;
			for (w = 0; w < bwords(b); w = w + 1)
				if (sdram[bbase(b) + w] !== cval(seed, b, w)) n = n + 1;
			sd_bad = n;
		end
	endfunction

	// CRC32 over the packed payload, each word low bit first, from the format
	// rather than from the engine.
	function [31:0] crc32_word_tb(input [31:0] c, input [15:0] w);
		integer b; reg [31:0] v;
		begin
			v = c;
			for (b = 0; b < 16; b = b + 1)
				v = (v[0] ^ w[b]) ? ((v >> 1) ^ 32'hEDB88320) : (v >> 1);
			crc32_word_tb = v;
		end
	endfunction

	// ---- images ---------------------------------------------------------------
	reg [15:0] img   [0:32767];   // the image being built
	reg [15:0] stimg [0:32767];   // a state's embedded image, for the copier
	reg [15:0] deliv [0:32767];   // the last file APF delivered
	reg [15:0] keep  [0:32767];   // a snapshot of a bank
	reg [15:0] keep2 [0:32767];
	reg  [7:0] seed_of  [0:63];   // per-block seeds for build_img
	reg  [7:0] exp_seed [0:63];   // per-block seeds check_committed expects
	integer    img_pk;
	reg [31:0] img_c;

	task seeds_clear;
		integer b;
		begin
			for (b = 0; b < 64; b = b + 1) begin seed_of[b] = 8'h00; exp_seed[b] = 8'h00; end
		end
	endtask

	task emit(input [15:0] v);
		begin
			img[256 + img_pk] = v;
			img_c  = crc32_word_tb(img_c, v);
			img_pk = img_pk + 1;
		end
	endtask

	// A V4 image as the engine writes one: header, then each listed block in
	// walk order, a literal passed through and an erased run as 0xFFFF plus
	// its length, runs stopping at block boundaries; payload CRC in 19/20.
	task build_img(input [63:0] bmp, input [15:0] tag, input [31:0] ccrc);
		integer b, w, run, k;
		reg [15:0] v;
		reg [31:0] c;
		begin
			for (k = 0; k < BANK_W; k = k + 1) img[k] = 16'h0000;
			img_pk = 0; img_c = 32'hFFFFFFFF;
			for (b = 0; b < 64; b = b + 1) if (bmp[b]) begin
				run = 0;
				for (w = 0; w < bwords(b); w = w + 1) begin
					v = cval(seed_of[b], b, w);
					if (v == 16'hFFFF) run = run + 1;
					else begin
						if (run != 0) begin emit(16'hFFFF); emit(run[15:0]); run = 0; end
						emit(v);
					end
				end
				if (run != 0) begin emit(16'hFFFF); emit(run[15:0]); end
			end
			c = ~img_c;
			img[0]  = 16'h4E47; img[1] = 16'h5043; img[2] = 16'h5341; img[3] = tag;
			img[4]  = ccrc[15:0]; img[5] = ccrc[31:16];
			img[6]  = {7'd0, cart_bytes[24:16]}; img[7] = cart_bytes[15:0];
			img[8]  = bmp[15:0];  img[9]  = bmp[31:16];
			img[10] = bmp[47:32]; img[11] = bmp[63:48];
			img[16] = BEATS;
			img[19] = c[15:0]; img[20] = c[31:16];
			// rc5 S10: as an rc5 writer stamps it (the apply ignores word 21;
			// this only lets check_committed accept a delivered file as-is)
			img[21] = 16'h0501;
		end
	endtask

	// A state taken while staging held no save: no magic at all.
	task build_noimage;
		integer k;
		begin
			for (k = 0; k < BANK_W; k = k + 1) img[k] = 16'hFFFF;
		end
	endtask

	task st_from_img;
		integer k;
		begin
			for (k = 0; k < BANK_W; k = k + 1) stimg[k] = img[k];
		end
	endtask

	task psram_fill(input [15:0] v);
		integer k;
		begin
			for (k = 0; k < 131328; k = k + 1) psram[k] = v;
		end
	endtask

	function integer cbase(input dummy);           // committed bank, in words
		cbase = (stage_bank === 1'b1) ? BANK_W : 0;
	endfunction

	function [15:0] hdr(input integer idx);        // committed header word
		hdr = psram[cbase(0) + idx];
	endfunction

	// Decode the committed image the way the engine's decoder does and check
	// it against the expectation: V4 magic, this cartridge's CRC, the bitmap,
	// every listed block's words, and the stamped payload CRC.
	task check_committed(input [63:0] bmp);
		integer base, b, w, pk, n, k, blkbad;
		reg [15:0] v;
		reg [31:0] c;
		reg [63:0] hb;
		begin
			base = cbase(0);
			if (psram[base+0] !== 16'h4E47 || psram[base+1] !== 16'h5043 ||
			    psram[base+2] !== 16'h5341 || psram[base+3] !== TAG_V4)
				`FAIL(("committed magic %h %h %h %h", psram[base+0], psram[base+1],
				       psram[base+2], psram[base+3]))
			if (psram[base+4] !== cart_crc[15:0] || psram[base+5] !== cart_crc[31:16])
				`FAIL(("committed cart CRC %h%h, cartridge %h", psram[base+5], psram[base+4], cart_crc))
			// rc6 S10: word 21 = {writer revision 8'h06, cart_subcat} (0x01 here)
			if (psram[base+21] !== 16'h0601)
				`FAIL(("committed word 21 = %h, expected 0601 (rc6 writer revision 06, subcat 01)", psram[base+21]))
			hb = {psram[base+11], psram[base+10], psram[base+9], psram[base+8]};
			if (hb !== bmp) `FAIL(("committed bitmap %h, expected %h", hb, bmp))
			pk = 0; c = 32'hFFFFFFFF;
			for (b = 0; b < 64; b = b + 1) if (hb[b] === 1'b1) begin
				w = 0; blkbad = 0;
				while (w < bwords(b) && pk < 32256) begin
					v = psram[base + 256 + pk]; pk = pk + 1;
					c = crc32_word_tb(c, v);
					if (v !== 16'hFFFF) begin
						if (v !== cval(exp_seed[b], b, w)) blkbad = blkbad + 1;
						w = w + 1;
					end else begin
						v = psram[base + 256 + pk]; pk = pk + 1;
						c = crc32_word_tb(c, v);
						n = (v === 16'd0) ? 1 : v;
						for (k = 0; k < n && w < bwords(b); k = k + 1) begin
							if (cval(exp_seed[b], b, w) !== 16'hFFFF) blkbad = blkbad + 1;
							w = w + 1;
						end
					end
				end
				if (blkbad != 0)
					`FAIL(("committed block %0d: %0d words differ from the expected content", b, blkbad))
			end
			c = ~c;
			if ({psram[base+20], psram[base+19]} !== c)
				`FAIL(("committed payload CRC %h%h, the payload comes to %h",
				       psram[base+20], psram[base+19], c))
		end
	endtask

	// S10: word 23 = {from_state, 1'b0, fail_idx[5:0], verdict[7:0]}.
	task expect23(input [15:0] mask, input [15:0] want, input string what);
		reg [15:0] v;
		begin
			v = hdr(23);
			if ((v & mask) !== (want & mask))
				`FAIL(("%0s: header word 23 = %h (verdict %0d fail_idx %0d from_state %b bit14 %b), expected %h under mask %h",
				       what, v, v[7:0], v[13:8], v[15], v[14], want, mask))
			else
				$display("   word 23 = %h  (%0s: verdict %0d, fail_idx %0d, from_state %b)",
				         v, what, v[7:0], v[13:8], v[15]);
		end
	endtask

	// ---- stimulus -------------------------------------------------------------
	task flash_write(input [5:0] blk);
		begin
			// the die goes busy, the write event fires, the die idles again
			@(posedge clk); die_busy <= 2'b01;
			@(posedge clk); block0 <= blk; event0 <= 1;
			@(posedge clk); event0 <= 0;
			repeat (4) @(posedge clk); die_busy <= 2'b00;
		end
	endtask

	task game_write(input integer b, input [7:0] seed);
		begin
			sd_fill(b, seed);
			flash_write(b[5:0]);
		end
	endtask

	task wait_idle(input integer max);           // busy low 8 cycles running
		integer n, q;
		begin
			n = 0; q = 0;
			while (q < 8 && n < max) begin
				@(posedge clk); n = n + 1;
				if (busy === 1'b0) q = q + 1; else q = 0;
			end
			if (q < 8) `FAIL(("engine still busy after %0d cycles", max))
		end
	endtask

	task wait_busy(input integer max);
		integer n;
		begin
			n = 0;
			while (busy !== 1'b1 && n < max) begin @(posedge clk); n = n + 1; end
			if (busy !== 1'b1) `FAIL(("engine never went busy within %0d cycles", max))
		end
	endtask

	task wait_publish(input integer f0);
		integer n;
		begin
			n = 0;
			while (flips == f0 && n < 1500000) begin @(posedge clk); n = n + 1; end
			if (flips == f0) `FAIL(("no pass published"))
			wait_idle(1000000);
		end
	endtask

	// A new session: the core restarts (reset) and a cartridge loads.
	task fresh;
		begin
			@(posedge clk);
			cart_ready <= 0; slots_settled <= 0; draining <= 0; apf_busy <= 0;
			save_slot_wr <= 0; state_apply <= 0; die_busy <= 2'b00; event0 <= 0;
			reset <= 1; diag_drain <= 16'd0;
			repeat (4) @(posedge clk);
			reset <= 0;
			@(posedge clk); cart_replace <= 1;
			@(posedge clk); cart_replace <= 0;
			@(posedge clk);
		end
	endtask

	// cart_replace alone: the cartridge reloads without the core restarting.
	task reload;
		begin
			@(posedge clk);
			cart_ready <= 0; slots_settled <= 0;
			@(posedge clk); cart_replace <= 1;
			@(posedge clk); cart_replace <= 0;
			@(posedge clk);
		end
	endtask

	// The cartridge is ready and the slots settle at once: the boot apply runs
	// on whatever the committed bank holds. Every caller comes from
	// cart_ready low with a boot apply pending (reset or cart_replace), so
	// busy must be SEEN to rise -- the hold and the apply -- before its fall
	// means the apply is over; a fixed delay would let a slow start slip
	// past every check that follows.
	task boot_now;
		begin
			cart_ready <= 1; slots_settled <= 1;
			wait_busy(1000);
			wait_idle(2000000);
		end
	endtask

	// APF delivers `img` as the save file, into the committed bank.
	integer beat_cycles = 40;
	integer hb_tail     = 100;      // host_busy falls this long after the last beat
	task deliver;
		integer k, cb;
		begin
			@(posedge clk);
			apf_busy <= 1; save_slot_wr <= 1;
			cb = cbase(0);
			for (k = 0; k < BANK_W; k = k + 1) begin
				if (k < FILE_W) psram[cb + k] = img[k];
				deliv[k] = (k < FILE_W) ? img[k] : psram[cb + k];
			end
			repeat (beat_cycles) @(posedge clk);
			save_slot_wr <= 0;
			repeat (hb_tail) @(posedge clk);
			apf_busy <= 0;
			@(posedge clk);
		end
	endtask

	// The copier, C1: wait for stage_current (I_DR_WAIT), raise draining,
	// drain stimg into the SPARE bank.
	reg drain_bank;
	task drain_begin;
		integer n, k, sp;
		begin
			n = 0;
			@(posedge clk);
			while (stage_current !== 1'b1 && n < 1000000) begin n = n + 1; @(posedge clk); end
			if (stage_current !== 1'b1) `FAIL(("copier: stage_current never rose"))
			draining   <= 1;
			drain_bank = (stage_bank === 1'b1) ? 1'b0 : 1'b1;
			sp = drain_bank ? BANK_W : 0;
			for (k = 0; k < FILE_W; k = k + 1) psram[sp + k] = stimg[k];
			diag_drain <= diag_drain + 16'd32512;      // C3: 2 host writes a word
			repeat (40) @(posedge clk);
		end
	endtask

	task pulse_state_apply;
		begin
			state_apply <= 1;
			@(posedge clk);
			state_apply <= 0;
			sa_cnt = sa_cnt + 1;
		end
	endtask

	task wait_state_done(input integer s0);
		integer n;
		begin
			n = 0;
			while (sd_cnt == s0 && n < 1000000) begin n = n + 1; @(posedge clk); end
			if (sd_cnt == s0) `FAIL(("state_done never pulsed"))
		end
	endtask

	// The whole copier sequence for stimg (C1, C2).
	task state_load;
		integer s0;
		begin
			drain_begin;
			s0 = sd_cnt;
			pulse_state_apply;
			wait_state_done(s0);
			draining <= 0;
			repeat (8) @(posedge clk);
		end
	endtask

	// The game plays on in a frozen session: it writes a save into block 10,
	// erases it again (issue #3's pattern), then scribbles on block 8. No pass
	// may start or publish, the committed bank must not change, the slot stays
	// unclaimed, and stage_current stays high whenever the engine is idle
	// (S1). Leaves the committed bank's snapshot in keep.
	task frozen_window;
		integer k, bad, w0, f0, fc0, fs0, cb;
		reg b0;
		begin
			b0 = stage_bank; cb = cbase(0);
			for (k = 0; k < BANK_W; k = k + 1) keep[k] = psram[cb + k];
			w0 = eng_wr; f0 = flips; fc0 = frz_cur; fs0 = frz_sp;
			// rc5 S1: frozen_o is refused_q, and the bridge stamps it into
			// every capture
			if (frozen !== 1'b1) `FAIL(("frozen: frozen_o = %b at the start of the frozen window", frozen))
			frz_en = 1;
			game_write(10, 8'h3A);
			@(posedge clk);
			if (stage_current !== 1'b1)
				`FAIL(("frozen: stage_current low right after a flash write (a capture would wait)"))
			// each wait is long enough for a pass over blocks 8-10 to run and
			// publish, were one to start
			repeat (QUIET + 80000) @(posedge clk);
			game_write(10, 8'h00);
			repeat (QUIET + 80000) @(posedge clk);
			game_write(8, 8'h3B);
			repeat (QUIET + 80000) @(posedge clk);
			frz_en = 0;
			@(posedge clk);
			if (eng_wr != w0)
				`FAIL(("frozen: a staging pass ran (%0d PSRAM writes)", eng_wr - w0))
			if (flips != f0 || stage_bank !== b0)
				`FAIL(("frozen: stage_bank changed (%0d flips)", flips - f0))
			bad = 0;
			for (k = 0; k < BANK_W; k = k + 1) if (psram[cb + k] !== keep[k]) bad = bad + 1;
			if (bad != 0) `FAIL(("frozen: %0d words of the committed bank changed", bad))
			if (frz_sp != fs0)
				`FAIL(("frozen: save_present high for %0d cycles", frz_sp - fs0))
			if (frz_cur != fc0)
				`FAIL(("frozen: stage_current low for %0d idle cycles", frz_cur - fc0))
			if (save_present !== 1'b0) `FAIL(("frozen: save_present = %b", save_present))
			if (frozen !== 1'b1) `FAIL(("frozen: frozen_o = %b at the end of the frozen window", frozen))
		end
	endtask

	function integer bank_vs_deliv(input dummy);   // committed bank vs the file
		integer k, n, cb;
		begin
			n = 0; cb = cbase(0);
			for (k = 0; k < FILE_W; k = k + 1) if (psram[cb + k] !== deliv[k]) n = n + 1;
			bank_vs_deliv = n;
		end
	endfunction

	// ---- S1a: a delivered file refused at boot freezes the session ----------
	// variant 0: tag 'V3'; 1: cart CRC word 5; 2: magic word 2; 3: payload CRC;
	// 4: cart CRC word 4
	task s1a_refuse(input integer variant);
		integer h0, p0;
		begin
			fresh;
			psram_fill(16'hFEED);
			sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
			seeds_clear;
			seed_of[8] = 8'h31; seed_of[9] = 8'h32; seed_of[10] = 8'h33;
			build_img(64'h700, TAG_V4, cart_crc);
			case (variant)
				0: img[3]   = TAG_V3;
				1: img[5]   = ~cart_crc[31:16];
				2: img[2]   = 16'h5342;
				3: img[256] = img[256] ^ 16'h0100;   // one bit of rot in a literal
				default: img[4] = ~cart_crc[15:0];
			endcase
			cart_ready <= 1;                    // cartridge in, slot not delivered yet
			deliver;
			h0 = hdr_rd; p0 = p2wr;
			slots_settled <= 1;
			repeat (4) @(posedge clk);
			wait_idle(2000000);
			if (hdr_rd == h0) `FAIL(("the boot apply never read the delivered header"))
			else if (hdr_bank[h0 % 4096] !== stage_bank)
				`FAIL(("the boot apply read the spare bank (S8: boot reads the committed one)"))
			if (p2wr != p0) `FAIL(("%0d flash words written by a refused apply", p2wr - p0))
			if (sd_bad(8, 8'h00) + sd_bad(9, 8'h00) + sd_bad(10, 8'h00) != 0)
				`FAIL(("flash changed by a refused apply"))
			if (boot_hold !== 1'b0) `FAIL(("boot still held after the refusal"))
			if (dut.dirty0 !== 64'd0)
				`FAIL(("dirty %h after a refused boot apply (S4: unchanged, and it was empty)", dut.dirty0))
			if (save_present !== 1'b0) `FAIL(("the refused file claims the slot"))
			frozen_window;
			if (bank_vs_deliv(0) != 0)
				`FAIL(("the committed bank is no longer the delivered file (%0d words)", bank_vs_deliv(0)))
		end
	endtask

	// ---- S3: a file for another cartridge, delivered before a reload -------
	// rc5 S3/S1(a): the rc4 exemption is gone. A pre-reload delivery refused
	// on the cartridge CRC (words 4-5) is a refused delivery like any other:
	// verdict 4 and the session FREEZES, so the committed bank -- the file --
	// is what APF flushes. (rc4 read it as "no file": no freeze, and the
	// game's own save published over it.)
	// variant 1: word 5 differs; 4: word 4 differs.
	task s3_crc_reload(input integer variant, input [5:0] fidx);
		integer h0, p0, n;
		reg b0;
		begin
			s1a_refuse(variant);                // delivered this epoch: refused, frozen
			reload;                             // the same cartridge again
			if (frozen !== 1'b0) `FAIL(("frozen_o = %b after cart_replace (S1: it clears the freeze)", frozen))
			h0 = hdr_rd; p0 = p2wr; b0 = stage_bank;
			boot_now;
			n = p2wr - p0;
			if (stage_bank !== b0) `FAIL(("cart_replace or the apply changed stage_bank (S2)"))
			if (hdr_rd == h0) `FAIL(("the file delivered before the reload was not read (S3)"))
			else if (hdr_bank[h0 % 4096] !== b0) `FAIL(("the boot apply read the spare bank"))
			if (n != 0) `FAIL(("%0d flash words written from another game's file", n))
			if (dut.dirty0 !== 64'd0) `FAIL(("dirty %h after a refusal (S4: unchanged, and it was empty)", dut.dirty0))
			if (boot_hold !== 1'b0) `FAIL(("boot still held"))
			if (save_present !== 1'b0) `FAIL(("another game's file claims the slot"))
			if (stage_current !== 1'b1) `FAIL(("stage_current low while idle with nothing to stage"))
			// rc5: frozen. The frozen window writes flash and checks that no
			// pass stages or publishes and the committed bank stays the file.
			if (frozen !== 1'b1) `FAIL(("rc5 S3: the refused pre-reload file did not freeze the session"))
			frozen_window;
			if (bank_vs_deliv(0) != 0)
				`FAIL(("the committed bank is no longer the delivered file (%0d words)", bank_vs_deliv(0)))
			// rc5 S10: the verdict. Frozen, nothing is ever staged, so no header
			// carries it: read the diagnostics the next header would stamp.
			// diag_applies and diag_p2wr restart at cart_replace; the refused
			// apply before the reload does not count.
			if (dut.diag_verdict !== {2'b00, fidx, 8'd4})
				`FAIL(("rc5: verdict word %h, expected %h (verdict 4 at fail_idx %0d, boot apply)",
				       dut.diag_verdict, {2'b00, fidx, 8'd4}, fidx))
			if (dut.diag_applies !== 16'd1)
				`FAIL(("applies since the reload = %0d, expected 1", dut.diag_applies))
			if (dut.diag_p2wr !== 16'd0)
				`FAIL(("p2 writes of the last apply = %0d, expected 0", dut.diag_p2wr))
		end
	endtask

	// ---- S1b: a state refused at wake, with no base, freezes the session ----
	// variant 0: tag 'V3'; 1: cart CRC word 4; 2: payload CRC
	// rc5: variant 1 is no longer a refusal. The magic matches and the
	// cartridge CRC does not, which S6 now reads as "no image": a no-op here.
	task s1b_wake(input integer variant);
		integer h0, p0, s0, f0, k;
		reg b0;
		begin
			fresh;
			psram_fill(16'hFEED);                // what staging held: no file
			sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
			cart_ready <= 1;                     // the boot apply waits for settle
			repeat (20) @(posedge clk);
			seeds_clear;
			seed_of[8] = 8'h41; seed_of[9] = 8'h42; seed_of[10] = 8'h43;
			build_img(64'h700, TAG_V4, cart_crc);
			case (variant)
				0: img[3]   = TAG_V3;
				1: img[4]   = ~cart_crc[15:0];
				default: img[256] = img[256] ^ 16'h0100;
			endcase
			st_from_img;
			b0 = stage_bank;
			for (k = 0; k < BANK_W; k = k + 1) keep2[k] = psram[cbase(0) + k];
			h0 = hdr_rd; p0 = p2wr; s0 = sd_cnt;
			drain_begin;
			pulse_state_apply;
			// Settle comes after the load here, so the result does not depend
			// on whether a state apply waits for it.
			repeat (100) @(posedge clk);
			slots_settled <= 1;
			wait_state_done(s0);
			draining <= 0;
			repeat (QUIET + 2000) @(posedge clk);
			if (sd_cnt != s0 + 1) `FAIL(("state_done pulsed %0d times", sd_cnt - s0))
			if (hdr_rd != h0 + 1)
				`FAIL(("%0d applies read a header; one state apply serves both (S8)", hdr_rd - h0))
			else if (hdr_bank[h0 % 4096] !== ~b0)
				`FAIL(("the state apply read the committed bank, not the spare"))
			if (p2wr != p0) `FAIL(("%0d flash words written", p2wr - p0))
			if (stage_bank !== b0) `FAIL(("the %0s state changed stage_bank", (variant == 1) ? "no-image" : "refused"))
			if (dut.dirty0 !== 64'd0) `FAIL(("dirty %h after the state (S4/S6: unchanged)", dut.dirty0))
			if (boot_hold !== 1'b0) `FAIL(("boot still held"))
			if (variant == 1) begin
				// rc5 S6: the magic matches but the cartridge CRC is another
				// cartridge's -- a leftover image, "no image". Dirty is empty,
				// so it is a no-op accept (verdict 6 at fail_idx 4) and it never
				// freezes. rc4 refused it here and froze the session.
				if (sd_rej !== 1'b0) `FAIL(("rc5 S6: apply_reject = %b with state_done: a no-op must load", sd_rej))
				if (frozen !== 1'b0) `FAIL(("rc5 S6: another cartridge's state image froze the session"))
				f0 = flips;
				game_write(10, 8'h44);
				wait_publish(f0);
				if (save_present !== 1'b1) `FAIL(("rc5 S6: the game's own save does not claim the slot"))
				seeds_clear; exp_seed[10] = 8'h44;
				check_committed(64'h400);
				expect23(16'hFFFF, 16'h8406, "rc5 S6: state for another cartridge, CRC word 4");
			end else begin
				if (sd_rej !== 1'b1) `FAIL(("apply_reject = %b with state_done: the load would succeed", sd_rej))
				if (apply_reject !== 1'b1) `FAIL(("apply_reject did not hold"))
				frozen_window;
				for (k = 0; k < FILE_W; k = k + 1)
					if (psram[cbase(0) + k] !== keep2[k]) begin
						`FAIL(("committed bank changed at word %0d", k))
						k = FILE_W;
					end
			end
		end
	endtask

	// ---- S8b: a state_apply pulse at offset koff from the boot apply start ---
	// koff 0 = the DUT sees state_apply in the same edge it first sees
	// slots_settled, which is the edge the boot apply starts on.
	task s8b_offset(input integer koff);
		integer h0, s0, k, sp;
		reg b0;
		begin
			fresh;
			psram_fill(16'hFEED);
			sd_fill(8, 8'h00);
			cart_ready <= 1;
			seeds_clear;
			seed_of[8] = 8'h83; build_img(64'h100, TAG_V4, cart_crc);
			deliver;
			// The drained image; draining itself is S8c's business, so the
			// bank is written directly and draining stays low.
			seed_of[8] = 8'h84; build_img(64'h100, TAG_V4, cart_crc);
			b0 = stage_bank; sp = b0 ? 0 : BANK_W;
			for (k = 0; k < FILE_W; k = k + 1) psram[sp + k] = img[k];
			repeat (QUIET + 50) @(posedge clk);
			h0 = hdr_rd; s0 = sd_cnt;
			@(posedge clk);
			if (koff < 0) begin
				pulse_state_apply;
				repeat (-koff - 1) @(posedge clk);
				slots_settled <= 1;
			end else if (koff == 0) begin
				state_apply <= 1; slots_settled <= 1;
				@(posedge clk);
				state_apply <= 0; sa_cnt = sa_cnt + 1;
			end else begin
				slots_settled <= 1;
				repeat (koff) @(posedge clk);
				pulse_state_apply;
			end
			wait_state_done(s0);
			if (sd_bad(8, 8'h84) != 0)
				`FAIL(("at state_done block 8 does not hold the state's image (%0d words)", sd_bad(8, 8'h84)))
			if (hdr_rd == h0 || hdr_rd - h0 > 2)
				`FAIL(("%0d applies read a header", hdr_rd - h0))
			else if (hdr_bank[(hdr_rd - 1) % 4096] !== ~b0)
				`FAIL(("the last apply read the committed bank, not the spare"))
			if (sd_rej !== 1'b0) `FAIL(("a good state was rejected"))
			repeat (QUIET + 2000) @(posedge clk);
			if (sd_cnt != s0 + 1) `FAIL(("state_done pulsed %0d times", sd_cnt - s0))
			if (stage_bank !== ~b0) `FAIL(("the accepted state did not commit the drained bank"))
			if (sd_bad(8, 8'h84) != 0) `FAIL(("block 8 was overwritten after the state apply"))
		end
	endtask

	// ============================================================================
	integer i, k, n, h0, p0, s0, f0, w0, bf0, cb;
	reg     b0;

	initial begin
		for (i = 0; i < 262144; i = i + 1) sdram[i] = i[15:0] ^ 16'hBEEF;
		psram_fill(16'hDEAD);

		// the bench's geometry is upstream's
		for (i = 0; i <= 10; i = i + 1) begin
			g_block = i; #1;
			if (!g_valid || g_words != bwords(i) || (g_base >> 1) != bbase(i))
				`FAIL(("bench geometry for block %0d disagrees with upstream", i))
		end

		repeat (10) @(posedge clk);
		reset <= 0;
		repeat (2) @(posedge clk);

		// ---- S2-PU --------------------------------------------------------------
		begin_scn("S2-PU", "stage_bank_o powers up 0");
		if (stage_bank !== 1'b0) `FAIL(("stage_bank = %b after power-up", stage_bank))
		end_scn;

		// ---- S1a-TAG: issue #3 end to end ------------------------------------
		begin_scn("S1a-TAG", "issue #3: a delivered V3 file is refused and stays exactly as delivered");
		s1a_refuse(0);
		end_scn;

		// ---- S1c: a state load while frozen ------------------------------------
		begin_scn("S1c", "frozen: an accepted state load writes flash but commits no bank");
		b0 = stage_bank;
		seeds_clear;
		seed_of[8] = 8'hC1; seed_of[9] = 8'hC2; seed_of[10] = 8'hC3;
		build_img(64'h700, TAG_V4, cart_crc);
		st_from_img;
		p0 = p2wr; f0 = flips; s0 = sd_cnt; h0 = hdr_rd;
		state_load;
		if (sd_cnt != s0 + 1) `FAIL(("state_done pulsed %0d times", sd_cnt - s0))
		if (sd_rej !== 1'b0) `FAIL(("a good state was rejected while frozen"))
		if (hdr_rd != h0 + 1 || hdr_bank[h0 % 4096] !== ~b0)
			`FAIL(("the state apply did not read the spare bank"))
		if (sd_bad(8, 8'hC1) + sd_bad(9, 8'hC2) + sd_bad(10, 8'hC3) != 0)
			`FAIL(("the accepted state's image did not reach flash"))
		if (stage_bank !== b0 || flips != f0) `FAIL(("a state apply committed a bank while frozen"))
		if (bank_vs_deliv(0) != 0) `FAIL(("the committed bank is no longer the delivered file"))
		if (save_present !== 1'b0) `FAIL(("save_present while frozen"))
		// S4: an accepted state apply sets dirty to the image's bitmap (it
		// was empty: the refused file left it so)
		if (dut.dirty0 !== 64'h700) `FAIL(("dirty %h after the accepted state, expected 700 (S4)", dut.dirty0))
		frozen_window;
		if (bank_vs_deliv(0) != 0) `FAIL(("the committed bank is no longer the delivered file"))
		end_scn;

		// ---- S1a-RELOAD: a cartridge reload re-reads the same file -------------
		begin_scn("S1a-RELOAD", "cart_replace clears the freeze, the file is read again and refused again");
		reload;
		h0 = hdr_rd; p0 = p2wr; b0 = stage_bank;
		cart_ready <= 1; slots_settled <= 1;
		repeat (4) @(posedge clk);
		wait_idle(2000000);
		if (stage_bank !== b0) `FAIL(("cart_replace changed stage_bank (S2)"))
		if (hdr_rd == h0) `FAIL(("the delivered file was not read after the reload (S3)"))
		if (p2wr != p0) `FAIL(("the refused file reached flash"))
		frozen_window;
		if (bank_vs_deliv(0) != 0) `FAIL(("the committed bank is no longer the delivered file"))
		end_scn;

		// ---- S1a-CRC ----------------------------------------------------------------
		begin_scn("S1a-CRC", "a delivered file for another cartridge (word 5) freezes the session");
		s1a_refuse(1);
		end_scn;

		// ---- S1a-FIX: reloading the file's own cartridge -----------------------
		begin_scn("S1a-FIX", "cart_replace to the file's cartridge: freeze cleared, delivered file applied");
		@(posedge clk);
		cart_ready <= 0; slots_settled <= 0;
		cart_crc <= {~CRC0[31:16], CRC0[15:0]};       // the cartridge the file is for
		@(posedge clk); cart_replace <= 1;
		@(posedge clk); cart_replace <= 0;
		@(posedge clk);
		b0 = stage_bank; f0 = flips;
		boot_now;
		if (sd_bad(8, 8'h31) + sd_bad(9, 8'h32) + sd_bad(10, 8'h33) != 0)
			`FAIL(("the file delivered before the reload was not applied (S3)"))
		if (dut.dirty0 !== 64'h700) `FAIL(("dirty %h after the accepted apply", dut.dirty0))
		if (stage_bank !== b0 || flips != f0) `FAIL(("a boot apply changed stage_bank"))
		if (save_present !== 1'b1) `FAIL(("an applied save with data does not claim the slot"))
		game_write(9, 8'h34);
		wait_publish(f0);
		seeds_clear; exp_seed[8] = 8'h31; exp_seed[9] = 8'h34; exp_seed[10] = 8'h33;
		check_committed(64'h700);
		@(posedge clk); cart_crc <= CRC0;
		end_scn;

		// ---- S3-CRC-RELOAD: another game's file, from before the reload -------
		// The same (wrong) cartridge reloaded. The file delivered before the
		// reload fails only the cartridge CRC. rc4 read that as "no file";
		// rc5 S3 removed the exemption, so it is refused and FREEZES (S1a).
		// Both CRC words, since the old exemption covered words 4-5.
		begin_scn("S3-CRC-RELOAD5", "rc5: reload, pre-reload file fails only CRC word 5: verdict 4, freezes");
		s3_crc_reload(1, 6'd5);
		end_scn;
		begin_scn("S3-CRC-RELOAD4", "rc5: reload, pre-reload file fails only CRC word 4: verdict 4, freezes");
		s3_crc_reload(4, 6'd4);
		end_scn;

		// ---- S1a-MAGIC ------------------------------------------------------------
		begin_scn("S1a-MAGIC", "a delivered file with a bad magic (word 2) freezes the session");
		s1a_refuse(2);
		end_scn;

		// ---- S1a-PAY --------------------------------------------------------------
		begin_scn("S1a-PAY", "a delivered file with a damaged payload freezes, flash untouched");
		s1a_refuse(3);
		end_scn;

		// ---- S1a-PAY-RELOAD ---------------------------------------------------------
		// S3: a pre-reload file refused for anything but the cartridge CRC
		// still freezes.
		begin_scn("S1a-PAY-RELOAD", "reload: the pre-reload file is refused on its payload again and freezes again");
		reload;
		h0 = hdr_rd; p0 = p2wr; b0 = stage_bank;
		boot_now;
		if (stage_bank !== b0) `FAIL(("cart_replace changed stage_bank (S2)"))
		if (hdr_rd == h0) `FAIL(("the delivered file was not read after the reload (S3)"))
		else if (hdr_bank[h0 % 4096] !== b0) `FAIL(("the boot apply read the spare bank"))
		if (p2wr != p0) `FAIL(("the refused file reached flash"))
		if (save_present !== 1'b0) `FAIL(("the refused file claims the slot"))
		frozen_window;
		if (bank_vs_deliv(0) != 0) `FAIL(("the committed bank is no longer the delivered file"))
		end_scn;

		// ---- S1a-RESET --------------------------------------------------------------
		// reset ALONE (a menu reset: no cart_replace) clears the freeze and
		// both delivery flags, so the same file is now "nothing delivered".
		begin_scn("S1a-RESET", "reset alone clears the freeze and forgets the pre-reload delivery");
		@(posedge clk);
		cart_ready <= 0; slots_settled <= 0;
		reset <= 1;
		repeat (4) @(posedge clk);
		reset <= 0;
		@(posedge clk);
		h0 = hdr_rd; p0 = p2wr; b0 = stage_bank;
		boot_now;                               // nothing delivered since the reset
		if (p2wr != p0) `FAIL(("%0d flash words written: nothing was delivered since the reset (S3)", p2wr - p0))
		if (dut.dirty0 !== 64'd0) `FAIL(("dirty %h after a boot with nothing delivered", dut.dirty0))
		if (stage_bank !== b0) `FAIL(("reset changed stage_bank (S2)"))
		f0 = flips;
		game_write(10, 8'h35);
		wait_publish(f0);
		if (save_present !== 1'b1) `FAIL(("a real save after the reset does not claim the slot"))
		seeds_clear; exp_seed[10] = 8'h35;
		check_committed(64'h400);
		expect23(16'hFFFF, 16'h0005, "boot apply after reset, nothing delivered");
		if (hdr(22) !== 16'd1) `FAIL(("word 22 (applies since reset) = %0d, expected 1", hdr(22)))
		end_scn;

		// ---- S1a-LATE: a refused late delivery -------------------------------------
		// The slow-card path of issue #3: the settle fired early, the game has
		// saved and published, then the file arrives, over the committed bank.
		// Its re-armed apply refuses it (a damaged payload): the session
		// freezes, so the file APF flushes is the one it delivered.
		begin_scn("S1a-LATE", "a late delivery refused by its re-armed apply freezes a session that already published");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		boot_now;                               // settle fired early: nothing delivered
		f0 = flips;
		game_write(10, 8'h37);
		wait_publish(f0);
		if (save_present !== 1'b1) `FAIL(("setup: the session's save does not claim the slot"))
		seeds_clear;
		seed_of[8] = 8'h38; seed_of[9] = 8'h39; seed_of[10] = 8'h3C;
		build_img(64'h700, TAG_V4, cart_crc);
		img[256] = img[256] ^ 16'h0100;         // damaged payload
		h0 = hdr_rd; p0 = p2wr; b0 = stage_bank; f0 = flips; w0 = eng_wr;
		deliver;                                // late, into the committed bank
		wait_busy(QUIET + 4000);                // the re-arm
		wait_idle(2000000);
		if (hdr_rd != h0 + 1) `FAIL(("%0d re-armed applies read a header, expected 1", hdr_rd - h0))
		else if (hdr_bank[h0 % 4096] !== b0) `FAIL(("the re-armed apply read the spare bank"))
		if (p2wr != p0) `FAIL(("%0d flash words written by a refused apply", p2wr - p0))
		if (sd_bad(8, 8'h00) + sd_bad(9, 8'h00) + sd_bad(10, 8'h37) != 0) `FAIL(("flash changed"))
		if (dut.dirty0 !== 64'h400)
			`FAIL(("dirty %h after the refusal, expected 400 (S4: unchanged)", dut.dirty0))
		if (stage_bank !== b0 || flips != f0) `FAIL(("stage_bank changed"))
		if (eng_wr != w0) `FAIL(("a staging pass ran around the late delivery"))
		if (save_present !== 1'b0) `FAIL(("the session still claims the slot over a refused file"))
		frozen_window;
		if (bank_vs_deliv(0) != 0)
			`FAIL(("the committed bank is no longer the delivered file (%0d words)", bank_vs_deliv(0)))
		end_scn;

		// ---- S1b-WAKE ---------------------------------------------------------------
		begin_scn("S1b-WAKE-TAG", "wake, no delivery, dirty empty: a V3 state is rejected and freezes");
		s1b_wake(0);
		end_scn;
		begin_scn("S1b-WAKE-CRC", "rc5: wake, no delivery, dirty empty: a state for another cart (word 4) is a no-op, no freeze");
		s1b_wake(1);
		end_scn;
		begin_scn("S1b-WAKE-PAY", "wake, no delivery, dirty empty: a state with a damaged payload");
		s1b_wake(2);
		end_scn;

		// ---- S1b-DIRTY: mid-session refusal ------------------------------------
		begin_scn("S1b-DIRTY", "dirty nonempty: a refused state rejects without freezing");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		boot_now;
		f0 = flips;
		game_write(10, 8'h45);
		wait_publish(f0);
		seeds_clear;
		seed_of[8] = 8'h46; seed_of[9] = 8'h47; seed_of[10] = 8'h48;
		build_img(64'h700, TAG_V4, cart_crc);
		img[3] = TAG_V3;
		st_from_img;
		b0 = stage_bank; p0 = p2wr; s0 = sd_cnt;
		state_load;
		if (sd_rej !== 1'b1) `FAIL(("the V3 state was not rejected"))
		if (p2wr != p0) `FAIL(("flash written"))
		if (stage_bank !== b0) `FAIL(("stage_bank changed"))
		if (dut.dirty0 !== 64'h400) `FAIL(("dirty %h, expected 400 (S4: unchanged)", dut.dirty0))
		f0 = flips;
		game_write(10, 8'h49);
		wait_publish(f0);
		if (save_present !== 1'b1) `FAIL(("the session's save does not claim the slot"))
		seeds_clear; exp_seed[10] = 8'h49;
		check_committed(64'h400);
		end_scn;

		// ---- S1b-BASE: an accepted apply is a base even with dirty empty -------
		begin_scn("S1b-BASE", "an apply was accepted (dirty empty): a refused state does not freeze");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		cart_ready <= 1;
		seeds_clear;
		build_img(64'h0, TAG_V4, cart_crc);     // a valid file listing no blocks
		deliver;
		p0 = p2wr;
		slots_settled <= 1;
		repeat (4) @(posedge clk);
		wait_idle(2000000);
		if (dut.dirty0 !== 64'd0) `FAIL(("setup: dirty %h", dut.dirty0))
		if (p2wr != p0) `FAIL(("setup: an empty file wrote flash"))
		seeds_clear;
		seed_of[8] = 8'h4C; seed_of[9] = 8'h4D; seed_of[10] = 8'h4E;
		build_img(64'h700, TAG_V4, cart_crc);
		img[3] = TAG_V3;
		st_from_img;
		b0 = stage_bank; p0 = p2wr;
		state_load;
		if (sd_rej !== 1'b1) `FAIL(("the V3 state was not rejected"))
		if (p2wr != p0) `FAIL(("flash written"))
		if (stage_bank !== b0) `FAIL(("stage_bank changed"))
		f0 = flips;
		game_write(10, 8'h4F);
		wait_publish(f0);
		expect23(16'hFFFF, 16'h8304, "state refused on its tag");
		end_scn;

		// ---- S1b-EPOCH: a base does not outlive a cart_replace --------------------
		// S1(b): "no apply has been accepted since reset OR cart replace". An
		// accepted state, then a cartridge reload with nothing delivered in
		// either epoch: the session has no base again, and a refused state
		// with dirty empty freezes it.
		begin_scn("S1b-EPOCH", "an apply accepted before a cart_replace is no base after it: a refused state freezes");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		boot_now;                               // nothing delivered
		seeds_clear; seed_of[8] = 8'h71;
		build_img(64'h100, TAG_V4, cart_crc);
		st_from_img;
		b0 = stage_bank;
		state_load;
		if (sd_rej !== 1'b0) `FAIL(("setup: a good state was rejected"))
		if (stage_bank !== ~b0) `FAIL(("setup: the accepted state did not commit the drained bank"))
		if (dut.dirty0 !== 64'h100) `FAIL(("dirty %h after the accepted state, expected 100 (S4)", dut.dirty0))
		reload;
		p0 = p2wr;
		boot_now;                               // still nothing delivered: verdict 5
		if (p2wr != p0) `FAIL(("setup: the boot after the reload wrote flash"))
		if (dut.dirty0 !== 64'd0) `FAIL(("setup: dirty %h after the reload", dut.dirty0))
		seeds_clear; seed_of[8] = 8'h72; seed_of[9] = 8'h73;
		build_img(64'h300, TAG_V4, cart_crc);
		img[3] = TAG_V3;
		st_from_img;
		b0 = stage_bank; p0 = p2wr; s0 = sd_cnt;
		state_load;
		if (sd_cnt != s0 + 1) `FAIL(("state_done pulsed %0d times", sd_cnt - s0))
		if (sd_rej !== 1'b1) `FAIL(("the V3 state was not rejected"))
		if (p2wr != p0) `FAIL(("flash written"))
		if (stage_bank !== b0) `FAIL(("stage_bank changed"))
		if (dut.dirty0 !== 64'd0) `FAIL(("dirty %h after a refused state (S4: unchanged)", dut.dirty0))
		frozen_window;
		end_scn;

		// ---- S2: the committed bank survives reset and cart_replace -----------
		begin_scn("S2", "stage_bank_o survives reset and cart_replace");
		fresh;
		psram_fill(16'hFEED);
		boot_now;
		f0 = flips;
		game_write(10, 8'h52);
		wait_publish(f0);
		if (stage_bank !== 1'b1) begin
			f0 = flips;
			game_write(10, 8'h53);
			wait_publish(f0);
		end
		if (stage_bank !== 1'b1) `FAIL(("setup: could not publish into bank 1"))
		for (k = 0; k < BANK_W; k = k + 1) keep2[k] = psram[BANK_W + k];
		f0 = flips;
		@(posedge clk);
		cart_ready <= 0; slots_settled <= 0;
		reset <= 1;
		repeat (4) @(posedge clk);
		if (stage_bank !== 1'b1) `FAIL(("stage_bank = %b during reset", stage_bank))
		reset <= 0;
		repeat (2) @(posedge clk);
		if (stage_bank !== 1'b1) `FAIL(("stage_bank = %b after reset", stage_bank))
		cart_replace <= 1;
		@(posedge clk); cart_replace <= 0;
		repeat (2) @(posedge clk);
		if (stage_bank !== 1'b1) `FAIL(("stage_bank = %b after cart_replace", stage_bank))
		boot_now;
		if (stage_bank !== 1'b1 || flips != f0) `FAIL(("stage_bank changed by the boot that followed"))
		n = 0;
		for (k = 0; k < BANK_W; k = k + 1) if (psram[BANK_W + k] !== keep2[k]) n = n + 1;
		if (n != 0) `FAIL(("%0d words of the committed bank changed", n))
		end_scn;

		// ---- S3: a delivery survives a cartridge reload -----------------------
		begin_scn("S3", "delivery, then cart_replace, then cart_ready: the apply accepts the file");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		seeds_clear;
		seed_of[8] = 8'hD1; seed_of[9] = 8'hD2; seed_of[10] = 8'hD3;
		build_img(64'h700, TAG_V4, cart_crc);
		deliver;                                 // before the cartridge (re)loads
		repeat (50) @(posedge clk);
		reload;
		b0 = stage_bank; f0 = flips; h0 = hdr_rd; p0 = p2wr;
		boot_now;
		n = p2wr - p0;                           // flash writes the apply made
		if (hdr_rd == h0) `FAIL(("the apply never read the file"))
		else if (hdr_bank[h0 % 4096] !== b0) `FAIL(("the boot apply read the spare bank"))
		if (sd_bad(8, 8'hD1) + sd_bad(9, 8'hD2) + sd_bad(10, 8'hD3) != 0)
			`FAIL(("the delivered file was not applied after the reload"))
		if (dut.dirty0 !== 64'h700) `FAIL(("dirty %h, expected 700", dut.dirty0))
		if (save_present !== 1'b1) `FAIL(("the applied save does not claim the slot"))
		if (stage_bank !== b0 || flips != f0) `FAIL(("a boot apply changed stage_bank"))
		game_write(9, 8'hD4);
		wait_publish(f0);
		seeds_clear; exp_seed[8] = 8'hD1; exp_seed[9] = 8'hD4; exp_seed[10] = 8'hD3;
		check_committed(64'h700);
		expect23(16'hFFFF, 16'h0001, "boot apply accepted");
		// S10: diag_applies and diag_p2wr keep their meaning (applies since
		// reset or cart_replace; flash writes the last apply made)
		if (hdr(22) !== 16'd1) `FAIL(("word 22 (applies since the reload) = %0d, expected 1", hdr(22)))
		if (hdr(24) !== n[15:0]) `FAIL(("word 24 (p2 writes of the last apply) = %0d, the bench saw %0d", hdr(24), n))
		end_scn;

		// ---- S4a/S5b: a late boot apply and the session's own blocks ----------
		// rc5 S4: an accepted boot apply sets dirty to the image's bitmap. The
		// rc4 union is gone: block 10, which the unrestored session dirtied
		// before the late delivery, is dropped, and the re-armed apply restarts
		// the machine (boot_hold) on the delivered save.
		begin_scn("S4a/S5b", "rc5: a late re-armed boot apply missing a dirty block is accepted, dirty = the image's bitmap");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		boot_now;                                // settle fired early: nothing delivered
		f0 = flips;
		game_write(10, 8'h4A);
		wait_publish(f0);
		seeds_clear;
		seed_of[8] = 8'h48; seed_of[9] = 8'h49;
		build_img(64'h300, TAG_V4, cart_crc);
		b0 = stage_bank; f0 = flips; h0 = hdr_rd; w0 = eng_wr;
		deliver;                                 // late
		wait_busy(QUIET + 4000);                 // the re-arm
		if (boot_hold !== 1'b1) `FAIL(("rc5 S4: the re-armed apply does not hold the machine in reset"))
		wait_idle(2000000);
		if (hdr_rd != h0 + 1) `FAIL(("%0d re-armed applies read a header", hdr_rd - h0))
		else if (hdr_bank[h0 % 4096] !== b0) `FAIL(("the re-armed apply read the spare bank"))
		if (sd_bad(8, 8'h48) + sd_bad(9, 8'h49) != 0) `FAIL(("the delivered blocks were not applied"))
		if (sd_bad(10, 8'h4A) != 0) `FAIL(("the session's own block 10 was touched (S4: the walk follows the image's bitmap)"))
		if (dut.dirty0 !== 64'h300)
			`FAIL(("rc5: dirty %h, expected 300 (S4: dirty := the image's bitmap, no union)", dut.dirty0))
		if (stage_bank !== b0 || flips != f0) `FAIL(("stage_bank changed across the re-armed apply"))
		if (eng_wr != w0) `FAIL(("a staging pass ran before the re-armed apply"))
		if (frozen !== 1'b0) `FAIL(("frozen_o = %b after an accepted apply", frozen))
		// rc5, from the ports: the next pass carries the file's blocks and not
		// block 10. Any pass still owed from before the delivery runs first.
		repeat (QUIET + 100) @(posedge clk);
		wait_idle(2000000);
		f0 = flips;
		game_write(9, 8'h4B);
		wait_publish(f0);
		seeds_clear; exp_seed[8] = 8'h48; exp_seed[9] = 8'h4B;
		check_committed(64'h300);
		if (save_present !== 1'b1) `FAIL(("save_present low"))
		// block 10 comes back only when the game writes it again
		f0 = flips;
		game_write(10, 8'h4C);
		wait_publish(f0);
		seeds_clear; exp_seed[8] = 8'h48; exp_seed[9] = 8'h4B; exp_seed[10] = 8'h4C;
		check_committed(64'h700);
		end_scn;

		// ---- S4b: a refused state leaves dirty alone ---------------------------
		begin_scn("S4b", "a refused state apply (bitmap a superset) leaves dirty exactly as it was");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		boot_now;
		f0 = flips;
		sd_fill(8, 8'h51);
		game_write(10, 8'h52);
		flash_write(6'd8);
		wait_publish(f0);
		if (dut.dirty0 !== 64'h500) `FAIL(("setup: dirty %h", dut.dirty0))
		seeds_clear;
		seed_of[8] = 8'h53; seed_of[9] = 8'h54; seed_of[10] = 8'h55;
		build_img(64'h700, TAG_V4, cart_crc);
		img[256] = img[256] ^ 16'h0100;          // damaged payload
		st_from_img;
		b0 = stage_bank; p0 = p2wr;
		state_load;
		if (sd_rej !== 1'b1) `FAIL(("a damaged state was accepted"))
		if (dut.dirty0 !== 64'h500)
			`FAIL(("dirty %h after the refusal, expected 500 (S4; the old engine left 700)", dut.dirty0))
		if (p2wr != p0) `FAIL(("flash written"))
		if (sd_bad(8, 8'h51) + sd_bad(9, 8'h00) + sd_bad(10, 8'h52) != 0) `FAIL(("flash changed"))
		if (stage_bank !== b0) `FAIL(("stage_bank changed"))
		f0 = flips;
		game_write(10, 8'h56);
		wait_publish(f0);
		seeds_clear; exp_seed[8] = 8'h51; exp_seed[10] = 8'h56;
		check_committed(64'h500);
		expect23(16'hC0FF, 16'h8003, "state refused on its payload CRC");
		end_scn;

		// ---- S5a: coverage is a reject for a state -----------------------------
		begin_scn("S5a", "a state whose bitmap omits a dirty block is rejected: no writes, no freeze");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		boot_now;
		f0 = flips;
		sd_fill(8, 8'h57);
		game_write(10, 8'h58);
		flash_write(6'd8);
		wait_publish(f0);
		seeds_clear;
		seed_of[8] = 8'h59;
		build_img(64'h100, TAG_V4, cart_crc);    // valid, but omits block 10
		st_from_img;
		b0 = stage_bank; p0 = p2wr;
		state_load;
		if (sd_rej !== 1'b1) `FAIL(("the older state was not rejected"))
		if (p2wr != p0) `FAIL(("flash written"))
		if (sd_bad(8, 8'h57) + sd_bad(10, 8'h58) != 0) `FAIL(("flash changed"))
		if (dut.dirty0 !== 64'h500) `FAIL(("dirty %h, expected 500", dut.dirty0))
		if (stage_bank !== b0) `FAIL(("stage_bank changed"))
		f0 = flips;
		game_write(10, 8'h5A);
		wait_publish(f0);                        // no freeze
		if (apply_reject !== 1'b1) `FAIL(("apply_reject did not hold until the next apply"))
		seeds_clear; exp_seed[8] = 8'h57; exp_seed[10] = 8'h5A;
		check_committed(64'h500);
		expect23(16'hC0FF, 16'h8002, "state coverage reject");
		end_scn;

		// ---- S6a/S6b: a state with no image -------------------------------------
		begin_scn("S6a", "no-image state, dirty empty: accepted as a no-op, verdict 6");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		boot_now;
		if (dut.dirty0 !== 64'd0) `FAIL(("setup: dirty %h", dut.dirty0))
		build_noimage;
		st_from_img;
		b0 = stage_bank; p0 = p2wr; f0 = flips; s0 = sd_cnt;
		state_load;
		if (sd_cnt != s0 + 1) `FAIL(("state_done pulsed %0d times", sd_cnt - s0))
		if (sd_rej !== 1'b0) `FAIL(("rejected: a state with no save must load when nothing is dirty"))
		if (p2wr != p0) `FAIL(("flash written"))
		if (stage_bank !== b0 || flips != f0) `FAIL(("stage_bank changed"))
		if (dut.dirty0 !== 64'd0) `FAIL(("dirty %h", dut.dirty0))
		game_write(10, 8'h61);
		wait_publish(f0);                        // never freezes
		expect23(16'hFFFF, 16'h8006, "state with no image");
		end_scn;

		begin_scn("S6b", "no-image state, dirty nonempty: rejected, verdict 6, no freeze");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		boot_now;
		f0 = flips;
		game_write(10, 8'h62);
		wait_publish(f0);
		build_noimage;
		st_from_img;
		b0 = stage_bank; p0 = p2wr; f0 = flips;
		state_load;
		if (sd_rej !== 1'b1) `FAIL(("accepted: flash would stay ahead of the restored machine"))
		if (p2wr != p0) `FAIL(("flash written"))
		if (stage_bank !== b0 || flips != f0) `FAIL(("stage_bank changed"))
		if (dut.dirty0 !== 64'h400) `FAIL(("dirty %h", dut.dirty0))
		game_write(10, 8'h63);
		wait_publish(f0);
		expect23(16'hFFFF, 16'h8006, "state with no image");
		end_scn;

		// ---- S8a: state_apply during a running boot apply ----------------------
		begin_scn("S8a", "state_apply during a running boot apply: a second apply reads the spare bank");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00);
		cart_ready <= 1;
		seeds_clear;
		seed_of[8] = 8'h81; build_img(64'h100, TAG_V4, cart_crc);
		deliver;
		seed_of[8] = 8'h82; build_img(64'h100, TAG_V4, cart_crc);
		st_from_img;
		repeat (QUIET + 50) @(posedge clk);
		b0 = stage_bank; h0 = hdr_rd; s0 = sd_cnt;
		slots_settled <= 1;
		n = 0;
		while (hdr_rd == h0 && n < 1000) begin @(posedge clk); n = n + 1; end
		if (hdr_rd == h0) `FAIL(("the boot apply never started"))
		// The copier saw stage_current in the cycle the apply started and
		// drains now, while the boot apply runs.
		draining <= 1;
		drain_bank = ~b0;
		for (k = 0; k < FILE_W; k = k + 1) psram[(b0 ? 0 : BANK_W) + k] = stimg[k];
		diag_drain <= diag_drain + 16'd32512;
		repeat (60) @(posedge clk);
		if (busy !== 1'b1) `FAIL(("setup: the boot apply was no longer running at the pulse"))
		if (sd_cnt != s0) `FAIL(("state_done pulsed before any state request"))
		pulse_state_apply;
		wait_state_done(s0);
		if (sd_bad(8, 8'h82) != 0)
			`FAIL(("state_done came before the state's image reached flash (%0d words)", sd_bad(8, 8'h82)))
		if (hdr_rd != h0 + 2) `FAIL(("%0d applies read a header, expected 2", hdr_rd - h0))
		else begin
			if (hdr_bank[h0 % 4096] !== b0) `FAIL(("the boot apply read the spare bank"))
			if (hdr_bank[(h0 + 1) % 4096] !== ~b0) `FAIL(("the state apply read the committed bank"))
		end
		if (sd_rej !== 1'b0) `FAIL(("a good state was rejected"))
		draining <= 0;
		repeat (QUIET + 2000) @(posedge clk);
		if (sd_cnt != s0 + 1) `FAIL(("state_done pulsed %0d times", sd_cnt - s0))
		if (stage_bank !== ~b0) `FAIL(("the accepted state did not commit the drained bank"))
		if (dut.dirty0 !== 64'h100) `FAIL(("dirty %h", dut.dirty0))
		if (sd_bad(8, 8'h82) != 0) `FAIL(("block 8 lost the state's image"))
		// the same from the header (S10): two applies since reset, the last
		// one the state's, accepted
		f0 = flips; game_write(10, 8'h87); wait_publish(f0);
		if (hdr(22) !== 16'd2) `FAIL(("word 22 (applies since reset) = %0d, expected 2", hdr(22)))
		expect23(16'hFFFF, 16'h8001, "state accepted after a boot apply");
		end_scn;

		// ---- S8b: a pulse around the apply's start is never lost ---------------
		for (i = -2; i <= 3; i = i + 1) begin
			begin_scn("S8b", "a state_apply pulse near the boot apply's start is never lost");
			$display("   (state_apply %0d cycle(s) from the edge that starts the boot apply)", i);
			s8b_offset(i);
			end_scn;
		end

		// ---- S8c: no boot apply under a drain -------------------------------------
		begin_scn("S8c", "settle during a drain: no boot apply; one state apply serves both");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00);
		cart_ready <= 1;
		seeds_clear;
		seed_of[8] = 8'h85; build_img(64'h100, TAG_V4, cart_crc);
		deliver;
		seed_of[8] = 8'h86; build_img(64'h100, TAG_V4, cart_crc);
		st_from_img;
		repeat (QUIET + 50) @(posedge clk);
		b0 = stage_bank; h0 = hdr_rd; s0 = sd_cnt; p0 = p2wr;
		drain_begin;
		slots_settled <= 1;                      // settle lands inside the drain
		repeat (1500) @(posedge clk);
		if (hdr_rd != h0 || p2wr != p0) `FAIL(("a boot apply started while draining"))
		pulse_state_apply;
		wait_state_done(s0);
		if (sd_bad(8, 8'h86) != 0) `FAIL(("the state's image is not in flash at state_done"))
		if (hdr_rd != h0 + 1) `FAIL(("%0d applies read a header, expected 1", hdr_rd - h0))
		else if (hdr_bank[h0 % 4096] !== ~b0) `FAIL(("the state apply read the committed bank"))
		if (sd_rej !== 1'b0) `FAIL(("a good state was rejected"))
		draining <= 0;
		repeat (QUIET + 2000) @(posedge clk);
		if (hdr_rd != h0 + 1) `FAIL(("another apply ran after the state apply served both"))
		if (sd_cnt != s0 + 1) `FAIL(("state_done pulsed %0d times", sd_cnt - s0))
		if (stage_bank !== ~b0) `FAIL(("the accepted state did not commit the drained bank"))
		if (sd_bad(8, 8'h86) != 0) `FAIL(("block 8 lost the state's image"))
		if (dut.dirty0 !== 64'h100) `FAIL(("dirty %h after the accepted state, expected 100 (S4)", dut.dirty0))
		// the same from the header (S10): ONE apply since reset, a state's
		f0 = flips; game_write(10, 8'h88); wait_publish(f0);
		if (hdr(22) !== 16'd1) `FAIL(("word 22 (applies since reset) = %0d, expected 1", hdr(22)))
		expect23(16'hFFFF, 16'h8001, "one state apply served the boot apply too");
		end_scn;

		// ---- S9a: flash busy across the end of a pass ----------------------------
		begin_scn("S9a", "die_busy held across the end of a pass: no publish until it clears");
		fresh;
		psram_fill(16'hFEED);
		boot_now;
		f0 = flips; bf0 = bad_flip;
		game_write(10, 8'h91);
		wait_busy(QUIET + 2000);                 // the pass starts
		repeat (100) @(posedge clk);
		die_busy <= 2'b01;                       // the die goes busy, no event yet
		n = 0;
		while (busy === 1'b1 && n < 1000000) begin @(posedge clk); n = n + 1; end
		repeat (500) @(posedge clk);
		if (flips != f0) `FAIL(("the pass published while die_busy was high"))
		die_busy <= 2'b00;
		wait_publish(f0);                        // the owed pass
		if (bad_flip != bf0) `FAIL(("stage_bank changed while a die was busy"))
		seeds_clear; exp_seed[10] = 8'h91;
		check_committed(64'h400);
		end_scn;

		// ---- S9b: the review's race ----------------------------------------------
		begin_scn("S9b", "pass owed + late delivery: the re-armed apply runs first; rc5: the committed image is the file's blocks only");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		boot_now;                                // settle fired early: nothing delivered
		seeds_clear;
		seed_of[8] = 8'h92; seed_of[9] = 8'h93;
		build_img(64'h300, TAG_V4, cart_crc);
		b0 = stage_bank; f0 = flips; h0 = hdr_rd; w0 = eng_wr; bf0 = bad_flip;
		game_write(10, 8'h94);                   // a pass is now owed...
		// ...and APF starts delivering before QUIET_CLOCKS pass, so host_busy
		// holds the stager off. The burst outlasts QUIET_CLOCKS, so flash is
		// quiet when it ends.
		@(posedge clk);
		apf_busy <= 1; save_slot_wr <= 1;
		cb = cbase(0);
		for (k = 0; k < BANK_W; k = k + 1) begin
			if (k < FILE_W) psram[cb + k] = img[k];
			deliv[k] = psram[cb + k];
		end
		repeat (QUIET + 100) @(posedge clk);
		save_slot_wr <= 0;
		repeat (hb_tail) @(posedge clk);         // host_busy falls BEFORE the re-arm
		apf_busy <= 0;
		n = 0;
		while (hdr_rd == h0 && n < 400000) begin @(posedge clk); n = n + 1; end
		if (hdr_rd == h0) `FAIL(("the re-armed apply never ran"))
		else begin
			if (eng_wr != w0)
				`FAIL(("a staging pass ran between the delivery and its re-armed apply (%0d PSRAM writes)",
				       eng_wr - w0))
			if (hdr_bank[h0 % 4096] !== b0 || flips != f0)
				`FAIL(("the re-armed apply did not read the delivered file in the committed bank"))
		end
		wait_idle(2000000);
		if (sd_bad(8, 8'h92) + sd_bad(9, 8'h93) != 0) `FAIL(("the delivered blocks were not restored"))
		if (sd_bad(10, 8'h94) != 0) `FAIL(("the game's block 10 was touched"))
		// rc5 S4: dirty := the file's bitmap; the game's block 10, written over
		// the missing save before the delivery, is dropped (rc4: 700, union)
		if (dut.dirty0 !== 64'h300) `FAIL(("rc5: dirty %h, expected 300 (S4: the image's bitmap, no union)", dut.dirty0))
		// The pass owed from before the delivery may run now; whether it does
		// or not, the committed image is the delivered file's blocks and only
		// those (rc5; rc4 published 700 with block 10).
		repeat (QUIET + 100) @(posedge clk);
		wait_idle(2000000);
		seeds_clear; exp_seed[8] = 8'h92; exp_seed[9] = 8'h93;
		check_committed(64'h300);
		if (save_present !== 1'b1) `FAIL(("save_present low"))
		// and staging carries on from the restored save
		f0 = flips;
		game_write(9, 8'h95);
		wait_publish(f0);
		seeds_clear; exp_seed[8] = 8'h92; exp_seed[9] = 8'h95;
		check_committed(64'h300);
		if (bad_flip != bf0) `FAIL(("stage_bank changed while APF or a die was busy"))
		end_scn;

		// ---- S10-18: drain beats in the header ------------------------------------
		begin_scn("S10-18", "header word 18 is diag_drain_i when the header is stamped");
		fresh;
		psram_fill(16'hFEED);
		boot_now;
		diag_drain <= 16'hA5C3;
		f0 = flips;
		game_write(10, 8'hA0);
		wait_publish(f0);
		if (hdr(18) !== 16'hA5C3) `FAIL(("word 18 = %h, expected A5C3", hdr(18)))
		if (hdr(16) !== BEATS) `FAIL(("word 16 = %h, expected %h", hdr(16), BEATS))
		diag_drain <= 16'h0F0F;
		f0 = flips;
		game_write(10, 8'hA1);
		wait_publish(f0);
		if (hdr(18) !== 16'h0F0F) `FAIL(("word 18 = %h, expected 0F0F", hdr(18)))
		end_scn;

		// ---- S10-23: the verdict word ----------------------------------------------
		begin_scn("S10-23", "header word 23 = {from_state, 0, fail_idx, verdict}");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		cart_ready <= 1;
		seeds_clear;
		seed_of[8] = 8'hA2; build_img(64'h100, TAG_V4, cart_crc);
		deliver;
		slots_settled <= 1;
		repeat (4) @(posedge clk);
		wait_idle(2000000);
		f0 = flips; game_write(10, 8'hA3); wait_publish(f0);
		expect23(16'hFFFF, 16'h0001, "boot apply accepted");

		seeds_clear; seed_of[8] = 8'hA4; seed_of[10] = 8'hA5;
		build_img(64'h500, TAG_V4, cart_crc); img[3] = TAG_V3; st_from_img;
		state_load;
		if (sd_rej !== 1'b1) `FAIL(("V3 state not rejected"))
		f0 = flips; game_write(10, 8'hA6); wait_publish(f0);
		expect23(16'hFFFF, 16'h8304, "state tag refused");

		// rc5 S6: a state whose magic matches but whose cartridge CRC is
		// another cartridge's is "no image": verdict 6 at fail_idx 5 / 4
		// (rc4: verdict 4). Dirty is not empty here, so it is still a reject.
		build_img(64'h500, TAG_V4, cart_crc); img[5] = ~img[5]; st_from_img;
		state_load;
		if (sd_rej !== 1'b1) `FAIL(("state for another cart (word 5) not rejected"))
		f0 = flips; game_write(10, 8'hA7); wait_publish(f0);
		expect23(16'hFFFF, 16'h8506, "rc5: state for another cart (CRC word 5): no image");

		build_img(64'h500, TAG_V4, cart_crc); img[4] = ~img[4]; st_from_img;
		state_load;
		if (sd_rej !== 1'b1) `FAIL(("state for another cart (word 4) not rejected"))
		f0 = flips; game_write(10, 8'hA8); wait_publish(f0);
		expect23(16'hFFFF, 16'h8406, "rc5: state for another cart (CRC word 4): no image");

		build_img(64'h500, TAG_V4, cart_crc); img[256] = img[256] ^ 16'h0100; st_from_img;
		state_load;
		if (sd_rej !== 1'b1) `FAIL(("damaged state not rejected"))
		f0 = flips; game_write(10, 8'hA9); wait_publish(f0);
		expect23(16'hC0FF, 16'h8003, "state payload CRC refused");

		build_img(64'h100, TAG_V4, cart_crc); st_from_img;
		state_load;
		if (sd_rej !== 1'b1) `FAIL(("state omitting dirty block 10 not rejected"))
		f0 = flips; game_write(10, 8'hAA); wait_publish(f0);
		expect23(16'hC0FF, 16'h8002, "state coverage reject");

		build_noimage; st_from_img;
		state_load;
		if (sd_rej !== 1'b1) `FAIL(("no-image state with dirty blocks not rejected"))
		f0 = flips; game_write(10, 8'hAB); wait_publish(f0);
		expect23(16'hFFFF, 16'h8006, "state with no image");

		seeds_clear; seed_of[8] = 8'hAC; seed_of[10] = 8'hAD;
		build_img(64'h500, TAG_V4, cart_crc); st_from_img;
		b0 = stage_bank;
		state_load;
		if (sd_rej !== 1'b0) `FAIL(("good state rejected"))
		if (stage_bank !== ~b0) `FAIL(("the accepted state did not commit the drained bank"))
		if (sd_bad(8, 8'hAC) + sd_bad(10, 8'hAD) != 0) `FAIL(("the accepted state did not reach flash"))
		f0 = flips; game_write(10, 8'hAE); wait_publish(f0);
		expect23(16'hFFFF, 16'h8001, "state accepted");
		if (hdr(18) !== diag_drain) `FAIL(("word 18 = %h, the copier has counted %h", hdr(18), diag_drain))

		// A valid file for this cartridge is left in the committed bank, but
		// nothing is delivered after the reset.
		fresh;
		p0 = p2wr;
		boot_now;
		if (p2wr != p0) `FAIL(("an undelivered image was applied"))
		if (dut.dirty0 !== 64'd0) `FAIL(("an undelivered image's bitmap was adopted (%h)", dut.dirty0))
		f0 = flips; game_write(10, 8'hAF); wait_publish(f0);
		expect23(16'hFFFF, 16'h0005, "boot apply, nothing delivered");
		end_scn;

		// ---- summary ------------------------------------------------------------------
		if (bad_flip != 0) begin
			errors = errors + 1;
			$display("== FAIL: %0d bank change(s) while a die or APF was busy", bad_flip);
		end
		$display("== %0d scenario(s), %0d failed, %0.1f ms simulated", n_scn, n_scn_fail, $realtime / 1.0e6);
		if (errors == 0) $display("== ALL RC4 ENGINE SCENARIOS PASS");
		else             $display("== %0d FAILURE(S)", errors);
		$finish;
	end

	initial begin
		#3_000_000_000;
		$display("== WATCHDOG TIMEOUT in %0s", scn);
		$display("== %0d FAILURE(S)", errors + 1);
		$finish;
	end

	wire unused = &{1'b0, p2_be, st_wdata, 1'b0};

endmodule

`default_nettype wire
