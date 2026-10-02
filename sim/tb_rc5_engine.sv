// Testbench: the rc5 save-engine contract (rc5_spec.md, the items marked
// [rc5]), against fake SDRAM and PSRAM.
//
// Written from the specification, not from the implementation. The
// infrastructure is tb_rc4_engine's (see there); this bench adds the two
// bridge inputs rc5 gave the engine and the output it gave the bridge:
//   - state_frozen_i: the bridge's load_frozen_o. Raised when the identity
//     check passes (before the drain, so before state_apply_i), lowered once
//     the load has finished (after state_done_o) (B2);
//   - state_fail_i: the bridge's load_fail_o, one cycle per reported load
//     failure (B3). Pulsed by hand where the bridge would report one;
//   - frozen_o: compared against refused_q on every clock (S1: "frozen_o
//     equals refused_q"), and checked by value wherever a freeze is or is
//     not expected.
//
// Real: ngpc_cart_save.sv and upstream's ngp_cart_overlay_geometry,
// compiled unmodified, QUIET_CLOCKS shrunk to 200. run_rc5_engine.sh builds
// it twice: without NGPC_SAVE_DIAG (no rc5 behaviour may depend on the
// diagnostics; word 21 is stamped "always") and with it (verdicts).
//
// Modeled around it, as tb_rc4_engine does: cartridge SDRAM and PSRAM
// (ready/done in 2 cycles); APF delivering into the COMMITTED bank with
// save_slot_wr and host_busy trailing the burst; the copier (waits for
// stage_current, raises draining, drains the state's image into the SPARE
// bank, pulses state_apply, lowers draining after state_done); the game
// writing die 0's small top blocks 8, 9 (8 KB) and 10 (16 KB). A new core
// launch is reset; a cartridge reload is cart_replace alone.
//
// WHAT IT OBSERVES
//   - applies: a read of word 0 of either bank starts a header walk
//     (hdr_rd, hdr_bank);
//   - every engine PSRAM read, per bank (rd_b0, rd_b1): S11 "reads nothing";
//   - staging: engine PSRAM writes (eng_wr); publishes: stage_bank_o flips;
//   - flash writes: engine p2 writes (p2wr);
//   - state_done_o pulses, with apply_reject_o in the same cycle (sd_rej).
//
// SCENARIOS (spec items in brackets; every scenario also checks S8's one
// state_done per state_apply and S1's frozen_o == refused_q)
//   S10-21    header word 21 = {8'h06, cart_subcat} in every staged header,
//             for two subcat values; both builds [S10 rc5]
//   S6x-W4 / -W5 / -W45 a wake (nothing delivered, dirty empty, boot apply
//             pending): a state whose magic matches but whose cart CRC is
//             another cartridge's (word 4, word 5, both) -> accepted no-op:
//             apply_reject 0, no flash writes, no bank change, dirty empty,
//             no freeze, one state apply serves the boot apply; verdict 6 at
//             fail_idx 4 / 5 / 4, in the next staged header [S6 rc5, S8, S10]
//   S6x-TAGCRC the same with the tag also wrong (V3). Settled in the spec:
//             for a state the cart CRC outranks the tag, so this is S6 -- a
//             no-op, no freeze, verdict 6 at word 4 [S6 rc5, S7, S1b]
//   S6x-DIRTY4 / -DIRTY5 dirty not empty: the same state is a reject
//             (apply_reject 1, no writes, dirty unchanged), verdict 6 at
//             fail_idx 4 / 5; the load failure the bridge then reports does
//             not freeze either [S6 rc5, S1c, S4]
//   S11-WAKE  a wake, a state from a frozen session (state_frozen_i = 1)
//             carrying a GOOD image: no PSRAM read of either bank, no flash
//             or PSRAM write, accepted, frozen_o set, bank and dirty
//             unchanged, verdict 7 (from_state 1), state_done once; the
//             boot apply it serves never runs; then frozen [S11, S1d, S8, S10]
//   S11-MID   the same mid-session (dirty not empty, a pass published) with
//             an image that would fail coverage: still accepted, nothing
//             read or written, dirty unchanged, frozen [S11, S1d, S5]
//   S11-FROZEN already frozen by a refused file: a frozen state with no
//             image at all is accepted, nothing read; then an ordinary good
//             state is applied but does not unfreeze or commit a bank; the
//             committed bank stays the delivered file [S11, S1, S2]
//   S11-QUEUED a frozen state requested while a boot apply runs: the boot
//             apply -- started with state_frozen_i already high (the
//             bridge's check precedes the drain) but no state request, so
//             not S11 -- applies the file; the state apply that follows
//             reads nothing of the spare bank, accepted, frozen [S11, S8]
//   S1c-WAKE  state_fail_i at a wake (boot apply refused as "nothing
//             delivered", dirty empty) freezes [S1c rc5]
//   S1c-PEND  state_fail_i while the boot apply still waits for the settle
//             freezes; that boot apply ("nothing delivered") does not clear
//             it [S1c rc5, S1]
//   S1c-PEND-FILE the same with the file already delivered: frozen, then
//             that first boot apply accepts the file and clears the freeze
//             [S1c rc5, S1 rc5, S4]
//   S1c-BASE-BOOT / -BASE-STATE an accepted boot apply / state apply of an
//             image listing no blocks (dirty stays empty): state_fail_i does
//             not freeze, staging publishes [S1c rc5]
//   S1c-DIRTY dirty not empty: state_fail_i does not freeze [S1c rc5]
//   S1c-EPOCH an accepted state, then cart_replace: no base any more, so
//             state_fail_i freezes [S1c rc5]
//   S1-CLR-EDGE a freeze is cleared by cart_replace alone and by reset alone;
//             stage_bank untouched [S1, S2]
//   S1-CLR-PAY / -HDR the settle fires while APF is still delivering: the
//             boot apply reads a partial file (payload cut: verdict 3;
//             header cut after word 3: verdict 4 at 4) and freezes; the rest
//             arrives, the re-armed apply accepts the complete file ->
//             unfrozen, dirty = its bitmap, and passes publish again
//             [S1 rc5, S1a, S4, S3]
//   S1-CLR-FAIL / -S11 a freeze from state_fail_i / from a frozen state at a
//             wake is cleared by a late delivery's accepted boot apply
//             [S1 rc5, S1c, S11]
//   S1-NOCLR-STATE frozen by state_fail at a wake with the file delivered;
//             a good state then serves the pending boot apply (S8): it is a
//             STATE apply, so it is applied (dirty = its bitmap) but the
//             session stays frozen, no bank is committed and the committed
//             bank stays the file [S1 rc5, S2, S8]
//   S9-GATE   a pass starts, then a late delivery arrives while it runs;
//             host_busy falls before the pass ends and flash is quiet; the
//             pass must not publish before the re-armed apply, that apply
//             reads the bank the file went into, dirty = the file's bitmap
//             (the game's block 10 is dropped), and the committed image is
//             the file's blocks; staging then carries on [S9 rc5, S4 rc5]
//   S8R-PEND / -PEND-FZ cart_replace while a state request waits for the
//             settle (-FZ: from a frozen session): state_done with
//             apply_reject 1 within 8 cycles, and the reload's boot apply
//             reads the committed bank; the request is never served, no
//             freeze [S8 rc5, S11]
//   S8R-QUEUED cart_replace while a state request waits behind a running
//             boot apply: the same; the reload applies the pre-reload file
//             [S8 rc5, S3]
//   S8R-HDR / -VERIFY / -WRITE cart_replace while a state apply is in
//             flight: in its header walk, its verify pass, its write pass
//             [S8 rc5]
//   S8R-SAME  state_apply_i in the very cycle of cart_replace [S8 rc5]
//
// Internal signals read: dut.refused_q (S1 names it; compared with frozen_o),
// dut.dirty0 (predates rc4), dut.diag_verdict (only under NGPC_SAVE_DIAG:
// the verdict of an apply after which the session is frozen, which no staged
// header can ever carry -- verdict 7 is always such a verdict).
//
// Run: wsl -e sh sim/run_rc5_engine.sh

`timescale 1ns / 1ps
`default_nettype none

`define FAIL(a) begin errors = errors + 1; $write("   FAIL [%0s] ", scn); $display a ; end

module tb_rc5_engine;

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
	localparam [31:0]  CRC_OTHER = 32'h0BADF00D;   // another cartridge: both words differ

	// ---- DUT wiring --------------------------------------------------------
	reg         cart_ready = 0, cart_replace = 0;
	reg  [31:0] cart_crc   = CRC0;
	reg  [24:0] cart_bytes = 25'h0080000;
	reg   [7:0] cart_subcat = 8'h01;
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
	reg         state_frozen = 0;              // the bridge's load_frozen_o (B2)
	reg         state_fail = 0;                // the bridge's load_fail_o (B3)
	reg  [15:0] diag_drain = 16'd0;            // the copier's diag_drain_o

	wire        boot_hold, busy, save_present, stage_current, stage_bank;
	wire        apply_reject, state_done, frozen;
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
		.cart_subcat_i   (cart_subcat),
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
		.state_frozen_i  (state_frozen),
		.state_fail_i    (state_fail),
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
	integer rd_b0   = 0;     // engine reads of PSRAM bank 0 ...
	integer rd_b1   = 0;     // ... and of bank 1
	integer hdr_rd  = 0;     // header word 0 reads: one per apply
	reg     hdr_bank [0:4095];
	integer p2wr    = 0;     // engine writes into cartridge flash
	integer flips   = 0;     // stage_bank_o changes
	integer sd_cnt  = 0;     // state_done_o pulses
	integer sa_cnt  = 0;     // state_apply_i pulses issued
	reg     sd_rej  = 0;     // apply_reject_o in the state_done_o cycle
	integer bad_flip = 0;    // bank changes while a die or APF was busy
	integer frz_mis = 0;     // cycles with frozen_o != refused_q
	reg     frz_en  = 0;     // a frozen window is being watched
	integer frz_cur = 0;     // ...cycles idle with stage_current low
	integer frz_sp  = 0;     // ...cycles with save_present high
	reg     bank_q  = 1'b0;
	reg [1:0] die_busy_q = 2'b00;
	reg     apf_busy_q = 1'b0;

	always @(posedge clk) begin
		if (st_req === 1'b1 && st_we === 1'b1) eng_wr <= eng_wr + 1;
		if (st_req === 1'b1 && st_we === 1'b0) begin
			if (st_addr[16] === 1'b1) rd_b1 <= rd_b1 + 1;
			else                      rd_b0 <= rd_b0 + 1;
			if (st_addr[15:0] == 16'd0) begin
				hdr_bank[hdr_rd % 4096] <= st_addr[16];
				hdr_rd <= hdr_rd + 1;
			end
		end
		if (p2_req === 1'b1 && p2_we === 1'b1) p2wr <= p2wr + 1;
		if (state_done === 1'b1) begin
			sd_cnt <= sd_cnt + 1;
			sd_rej <= apply_reject;
		end
		// S1 [rc5]: frozen_o equals refused_q
		if (frozen !== dut.refused_q) frz_mis <= frz_mis + 1;
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
			if (busy === 1'b0 && cart_ready && stage_current !== 1'b1) frz_cur <= frz_cur + 1;
			if (save_present !== 1'b0) frz_sp <= frz_sp + 1;
		end
	end

	function integer rd_of(input b);               // engine reads of bank b
		rd_of = b ? rd_b1 : rd_b0;
	endfunction

	// ---- scenario bookkeeping -----------------------------------------------
	integer scn_e0, scn_bal0, scn_mis0;
	integer n_scn = 0, n_scn_fail = 0;

	task begin_scn(input string name, input string what);
		begin
			scn      = name;
			scn_e0   = errors;
			scn_bal0 = sd_cnt - sa_cnt;
			scn_mis0 = frz_mis;
			$display("== %0s  %0s", name, what);
		end
	endtask

	// S8: state_done_o pulses exactly once per state_apply_i pulse, S6 no-ops
	// and S11 included, never for a boot apply. S1: frozen_o is refused_q.
	// Checked for every scenario.
	task end_scn;
		begin
			repeat (4) @(posedge clk);
			if (sd_cnt - sa_cnt != scn_bal0)
				`FAIL(("state_done pulses minus state_apply pulses = %0d in this scenario (S8: exactly one each)",
				       sd_cnt - sa_cnt - scn_bal0))
			if (frz_mis != scn_mis0)
				`FAIL(("frozen_o differed from refused_q for %0d cycles (S1: frozen_o = refused_q)",
				       frz_mis - scn_mis0))
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

	// Block content for a seed: a few literals in an otherwise erased block,
	// as a real save has. Seed 0 is an erased block; seeds stay below 0xF0 so
	// a literal is never 0xFFFF.
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

	function integer sd_bad3(input [7:0] s8, input [7:0] s9, input [7:0] s10);
		sd_bad3 = sd_bad(8, s8) + sd_bad(9, s9) + sd_bad(10, s10);
	endfunction

	// CRC32 over the packed payload, each word low bit first, from the format.
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
	reg [15:0] deliv [0:32767];   // the committed bank as APF left it
	reg [15:0] keep  [0:32767];   // a snapshot of a bank
	reg [15:0] keep2 [0:32767];
	reg  [7:0] seed_of  [0:63];   // per-block seeds for build_img
	reg  [7:0] exp_seed [0:63];   // per-block seeds check_committed expects
	integer    img_pk;            // payload words of the last build_img
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

	// A V4 image as the engine writes one (see tb_rc4_engine).
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
			img[21] = {8'h05, cart_subcat};    // as an rc5 writer stamps it
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

	function integer bank_vs(input dummy);         // committed bank vs keep
		integer k, n, cb;
		begin
			n = 0; cb = cbase(0);
			for (k = 0; k < BANK_W; k = k + 1) if (psram[cb + k] !== keep2[k]) n = n + 1;
			bank_vs = n;
		end
	endfunction

	task keep_committed;                           // snapshot the committed bank
		integer k, cb;
		begin
			cb = cbase(0);
			for (k = 0; k < BANK_W; k = k + 1) keep2[k] = psram[cb + k];
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

	// Decode the committed image the way the engine's decoder does and check
	// it: V4 magic, this cartridge's CRC, word 21 (S10 rc5), the bitmap, every
	// listed block's words, and the stamped payload CRC.
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
			if (psram[base+21] !== {8'h06, cart_subcat})
				`FAIL(("committed word 21 = %h, expected %h (S10: writer revision 06, subcat)",
				       psram[base+21], {8'h06, cart_subcat}))
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

	// S10: word 23 = {from_state, 1'b0, fail_idx[5:0], verdict[7:0]}, as the
	// next staged header carries it. A diagnostic: only under NGPC_SAVE_DIAG.
	task expect23(input [15:0] mask, input [15:0] want, input string what);
		reg [15:0] v;
		begin
`ifdef NGPC_SAVE_DIAG
			v = hdr(23);
			if ((v & mask) !== (want & mask))
				`FAIL(("%0s: header word 23 = %h (verdict %0d fail_idx %0d from_state %b bit14 %b), expected %h under mask %h",
				       what, v, v[7:0], v[13:8], v[15], v[14], want, mask))
			else
				$display("   word 23 = %h  (%0s)", v, what);
`endif
		end
	endtask

	// The same word before any header can carry it -- after an apply that
	// leaves the session frozen, none ever will. Reads dut.diag_verdict.
	task expect_verdict(input [15:0] mask, input [15:0] want, input string what);
		reg [15:0] v;
		begin
`ifdef NGPC_SAVE_DIAG
			v = dut.diag_verdict;
			if ((v & mask) !== (want & mask))
				`FAIL(("%0s: verdict word %h (verdict %0d fail_idx %0d from_state %b bit14 %b), expected %h under mask %h",
				       what, v, v[7:0], v[13:8], v[15], v[14], want, mask))
			else
				$display("   verdict word = %h  (%0s)", v, what);
`endif
		end
	endtask

	// ---- stimulus -------------------------------------------------------------
	task flash_write(input [5:0] blk);
		begin
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

	task wait_hdr(input integer h, input integer max);   // an apply starts
		integer n;
		begin
			n = 0;
			while (hdr_rd == h && n < max) begin @(posedge clk); n = n + 1; end
			if (hdr_rd == h) `FAIL(("no apply read a header within %0d cycles", max))
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
			state_frozen <= 0; state_fail <= 0;
			reset <= 1; diag_drain <= 16'd0;
			repeat (4) @(posedge clk);
			reset <= 0;
			@(posedge clk); cart_replace <= 1;
			@(posedge clk); cart_replace <= 0;
			@(posedge clk);
			if (frozen !== 1'b0) `FAIL(("frozen_o = %b after reset and cart_replace (S1)", frozen))
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

	// The cartridge is ready and the slots settle at once (see tb_rc4_engine).
	task boot_now;
		begin
			cart_ready <= 1; slots_settled <= 1;
			wait_busy(1000);
			wait_idle(2000000);
		end
	endtask

	// APF delivers img[k0 .. k1-1] into the committed bank in one burst.
	// deliv[] is the committed bank as APF has left it so far.
	integer beat_cycles = 40;
	integer hb_tail     = 100;      // host_busy falls this long after the last beat
	task deliver_range(input integer k0, input integer k1);
		integer k, cb;
		begin
			@(posedge clk);
			apf_busy <= 1; save_slot_wr <= 1;
			cb = cbase(0);
			for (k = k0; k < k1; k = k + 1) psram[cb + k] = img[k];
			for (k = 0; k < BANK_W; k = k + 1) deliv[k] = psram[cb + k];
			repeat (beat_cycles) @(posedge clk);
			save_slot_wr <= 0;
			repeat (hb_tail) @(posedge clk);
			apf_busy <= 0;
			@(posedge clk);
		end
	endtask

	task deliver;
		deliver_range(0, FILE_W);
	endtask

	// The copier, C1: wait for stage_current, raise draining, drain stimg
	// into the SPARE bank.
	task drain_begin;
		integer n, k, sp;
		begin
			n = 0;
			@(posedge clk);
			while (stage_current !== 1'b1 && n < 1000000) begin n = n + 1; @(posedge clk); end
			if (stage_current !== 1'b1) `FAIL(("copier: stage_current never rose"))
			draining <= 1;
			sp = (stage_bank === 1'b1) ? 0 : BANK_W;
			for (k = 0; k < FILE_W; k = k + 1) psram[sp + k] = stimg[k];
			diag_drain <= diag_drain + 16'd32512;
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

	// B3: the bridge reports a failed load.
	task pulse_state_fail;
		begin
			@(posedge clk); state_fail <= 1;
			@(posedge clk); state_fail <= 0;
			repeat (4) @(posedge clk);
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

	// The whole load of stimg: the bridge's check (state_frozen = fz, B2),
	// then the copier (C1, C2).
	task state_load_fz(input fz);
		integer s0;
		begin
			@(posedge clk); state_frozen <= fz;
			drain_begin;
			s0 = sd_cnt;
			pulse_state_apply;
			wait_state_done(s0);
			state_frozen <= 1'b0;
			draining <= 0;
			repeat (8) @(posedge clk);
		end
	endtask

	task state_load;
		state_load_fz(1'b0);
	endtask

	// Snapshot of the counters a scenario compares against.
	integer s_rd0, s_rd1, s_p2, s_ew, s_fl, s_hdr, s_sd;
	reg     s_bank;
	task snap;
		begin
			s_rd0 = rd_b0; s_rd1 = rd_b1; s_p2 = p2wr; s_ew = eng_wr; s_fl = flips;
			s_hdr = hdr_rd; s_sd = sd_cnt; s_bank = stage_bank;
		end
	endtask

	// The game plays on in a frozen session (see tb_rc4_engine): no pass may
	// start or publish, the committed bank must not change, the slot stays
	// unclaimed, stage_current stays high whenever idle, frozen_o stays high.
	task frozen_window;
		integer k, bad, w0, f0, fc0, fs0, cb;
		reg b0;
		begin
			b0 = stage_bank; cb = cbase(0);
			for (k = 0; k < BANK_W; k = k + 1) keep[k] = psram[cb + k];
			w0 = eng_wr; f0 = flips; fc0 = frz_cur; fs0 = frz_sp;
			if (frozen !== 1'b1) `FAIL(("frozen: frozen_o = %b at the start of the frozen window", frozen))
			frz_en = 1;
			game_write(10, 8'h3A);
			@(posedge clk);
			if (stage_current !== 1'b1)
				`FAIL(("frozen: stage_current low right after a flash write (a capture would wait)"))
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

	// Not frozen: the game's own save stages and publishes (block 10, seed).
	task publishes(input [7:0] seed);
		integer f0;
		begin
			if (frozen !== 1'b0) `FAIL(("frozen_o = %b where the session must not be frozen", frozen))
			f0 = flips;
			game_write(10, seed);
			wait_publish(f0);
			if (save_present !== 1'b1) `FAIL(("the game's own save does not claim the slot"))
		end
	endtask

	// ---- S6 [rc5]: a state image for another cartridge ------------------------
	// variant 4: word 4 differs; 5: word 5 differs; 45: another cartridge's
	// whole CRC; 3: tag V3 AND another cartridge's CRC.
	task s6x_build(input integer variant);
		begin
			build_img(64'h700, (variant == 3) ? TAG_V3 : TAG_V4,
			          (variant == 45 || variant == 3) ? CRC_OTHER : cart_crc);
			if (variant == 4) img[4] = ~img[4];
			if (variant == 5) img[5] = ~img[5];
		end
	endtask

	function [5:0] s6x_fidx(input integer variant);   // the first failing CRC word
		s6x_fidx = (variant == 5) ? 6'd5 : 6'd4;
	endfunction

	// At a wake: nothing delivered, dirty empty, the boot apply still waiting
	// for the settle. S6: a no-op accept, never a freeze.
	task s6x_wake(input integer variant);
		reg [15:0] m, want;
		begin
			fresh;
			psram_fill(16'hFEED);                   // what staging held: no file
			sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
			cart_ready <= 1;                        // the boot apply waits for the settle
			repeat (20) @(posedge clk);
			seeds_clear;
			seed_of[8] = 8'h61; seed_of[9] = 8'h62; seed_of[10] = 8'h63;
			s6x_build(variant);
			st_from_img;
			keep_committed;
			snap;
			drain_begin;
			pulse_state_apply;
			repeat (100) @(posedge clk);
			slots_settled <= 1;
			wait_state_done(s_sd);
			draining <= 0;
			repeat (QUIET + 2000) @(posedge clk);
			// What S6 and S7 agree on: state_done once, one state apply serves
			// the pending boot apply, nothing written, bank and dirty unchanged.
			if (sd_cnt != s_sd + 1) `FAIL(("state_done pulsed %0d times", sd_cnt - s_sd))
			if (hdr_rd != s_hdr + 1)
				`FAIL(("%0d applies read a header; one state apply serves the pending boot apply too (S8)", hdr_rd - s_hdr))
			else if (hdr_bank[s_hdr % 4096] !== ~s_bank)
				`FAIL(("the state apply read the committed bank, not the spare (S8)"))
			if (p2wr != s_p2) `FAIL(("rc5 S6: %0d flash words written for a state with no image", p2wr - s_p2))
			if (sd_bad3(8'h00, 8'h00, 8'h00) != 0) `FAIL(("rc5 S6: flash changed"))
			if (stage_bank !== s_bank || flips != s_fl) `FAIL(("rc5 S6: a state with no image changed stage_bank"))
			if (bank_vs(0) != 0) `FAIL(("the committed bank changed (%0d words)", bank_vs(0)))
			if (dut.dirty0 !== 64'd0) `FAIL(("dirty %h after the state (S4/S6: nothing applied)", dut.dirty0))
			if (boot_hold !== 1'b0) `FAIL(("boot still held"))
			// rc5 decision (spec S6): for a state the cart CRC outranks the
			// tag -- another game's image in a format this build does not
			// read is still another game's image. So variant 3 must be the
			// S6 no-op with verdict 6 at word 4, exactly like the others.
			begin
				if (sd_rej !== 1'b0)
					`FAIL(("rc5 S6: apply_reject = 1 with state_done: another cartridge's image with dirty empty must load as a no-op"))
				if (frozen !== 1'b0)
					`FAIL(("rc5 S6: another cartridge's state image froze the session (it is no image, never S7/S1b)"))
				m    = 16'hFFFF;
				want = {2'b10, s6x_fidx(variant), 8'd6};
				expect_verdict(m, want, "rc5 S6: state for another cartridge at a wake");
				// never frozen: the game's own save publishes, and its header
				// carries the verdict of the last apply
				if (frozen === 1'b0) begin
					publishes(8'h64);
					seeds_clear; exp_seed[10] = 8'h64;
					check_committed(64'h400);
					expect23(m, want, "rc5 S6: state for another cartridge at a wake");
				end
			end
		end
	endtask

	// Dirty not empty: S6 is a reject, still never a freeze -- not by S1(b),
	// and not by the load failure the bridge then reports (S1c: not
	// wake-shaped).
	task s6x_dirty(input integer variant);
		reg [15:0] want;
		begin
			fresh;
			psram_fill(16'hFEED);
			sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
			boot_now;                               // nothing delivered
			publishes(8'h65);                       // dirty = block 10
			seeds_clear;
			seed_of[8] = 8'h66; seed_of[9] = 8'h67; seed_of[10] = 8'h68;
			s6x_build(variant);
			st_from_img;
			keep_committed;
			snap;
			state_load;
			if (sd_cnt != s_sd + 1) `FAIL(("state_done pulsed %0d times", sd_cnt - s_sd))
			if (sd_rej !== 1'b1)
				`FAIL(("rc5 S6: apply_reject = 0: with blocks dirty, a state with no image must be rejected"))
			if (p2wr != s_p2) `FAIL(("%0d flash words written", p2wr - s_p2))
			if (sd_bad3(8'h00, 8'h00, 8'h65) != 0) `FAIL(("flash changed"))
			if (stage_bank !== s_bank || flips != s_fl) `FAIL(("stage_bank changed"))
			if (bank_vs(0) != 0) `FAIL(("the committed bank changed (%0d words)", bank_vs(0)))
			if (dut.dirty0 !== 64'h400) `FAIL(("dirty %h after the reject, expected 400 (S4: unchanged)", dut.dirty0))
			if (frozen !== 1'b0) `FAIL(("rc5 S6: a state with no image froze the session"))
			want = {2'b10, s6x_fidx(variant), 8'd6};
			expect_verdict(16'hFFFF, want, "rc5 S6: state for another cartridge, dirty not empty");
			// B3: the bridge reports the failed load
			pulse_state_fail;
			if (frozen !== 1'b0)
				`FAIL(("rc5 S6/S1c: the load failure a no-image reject causes froze the session (dirty is not empty)"))
			publishes(8'h69);
			seeds_clear; exp_seed[10] = 8'h69;
			check_committed(64'h400);
			expect23(16'hFFFF, want, "rc5 S6: state for another cartridge, dirty not empty");
		end
	endtask

	// ---- S11 [rc5]: a wake whose state comes from a frozen session ----------
	// The state carries a GOOD image for this cartridge -- one that would be
	// accepted and applied if it were read at all. Leaves the session as the
	// frozen state apply left it.
	task s11_wake;
		begin
			fresh;
			psram_fill(16'hFEED);
			sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
			cart_ready <= 1;                        // the boot apply waits for the settle
			repeat (20) @(posedge clk);
			seeds_clear;
			seed_of[8] = 8'hB1; seed_of[9] = 8'hB2; seed_of[10] = 8'hB3;
			build_img(64'h700, TAG_V4, cart_crc);
			st_from_img;
			keep_committed;
			snap;
			@(posedge clk); state_frozen <= 1;      // B2: layout 3, before the drain
			drain_begin;
			pulse_state_apply;
			repeat (100) @(posedge clk);
			slots_settled <= 1;
			wait_state_done(s_sd);
			state_frozen <= 0;
			draining <= 0;
			repeat (QUIET + 2000) @(posedge clk);
			if (sd_cnt != s_sd + 1) `FAIL(("state_done pulsed %0d times (S8: once, S11 included)", sd_cnt - s_sd))
			if (sd_rej !== 1'b0)
				`FAIL(("rc5 S11: a frozen state was rejected: the machine would not restore and sleep/wake breaks"))
			if (rd_of(~s_bank) != (s_bank ? s_rd0 : s_rd1))
				`FAIL(("rc5 S11: %0d reads of the drained bank: a frozen state reads nothing",
				       rd_of(~s_bank) - (s_bank ? s_rd0 : s_rd1)))
			if (rd_of(s_bank) != (s_bank ? s_rd1 : s_rd0))
				`FAIL(("%0d reads of the committed bank: one state apply serves the pending boot apply (S8)",
				       rd_of(s_bank) - (s_bank ? s_rd1 : s_rd0)))
			if (p2wr != s_p2) `FAIL(("rc5 S11: %0d flash words written", p2wr - s_p2))
			if (sd_bad3(8'h00, 8'h00, 8'h00) != 0) `FAIL(("rc5 S11: flash changed: the frozen state's image was applied"))
			if (eng_wr != s_ew) `FAIL(("rc5 S11: %0d engine PSRAM writes", eng_wr - s_ew))
			if (stage_bank !== s_bank || flips != s_fl) `FAIL(("rc5 S11: stage_bank changed"))
			if (bank_vs(0) != 0) `FAIL(("the committed bank changed (%0d words)", bank_vs(0)))
			if (dut.dirty0 !== 64'd0) `FAIL(("rc5 S11: dirty %h, expected unchanged (0)", dut.dirty0))
			if (frozen !== 1'b1) `FAIL(("rc5 S11/S1d: a state served with state_frozen_i = 1 did not freeze"))
			if (boot_hold !== 1'b0) `FAIL(("boot still held"))
			// S10: verdict 7, from_state 1, bit 14 clear; fail_idx is not specified
			expect_verdict(16'hC0FF, 16'h8007, "rc5 S11: frozen state at a wake");
		end
	endtask

	// ---- S1 [rc5]: a late delivery's accepted boot apply clears a freeze ------
	// cause 0: state_fail_i at a wake; 1: a frozen state at a wake (S11).
	task clr_late(input integer cause);
		begin
			if (cause == 0) begin
				fresh;
				psram_fill(16'hFEED);
				sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
				boot_now;                           // nothing delivered
				pulse_state_fail;
			end else begin
				s11_wake;
			end
			if (frozen !== 1'b1) `FAIL(("setup: the session is not frozen"))
			seeds_clear;
			seed_of[8] = 8'hF1; seed_of[9] = 8'hF2;
			build_img(64'h300, TAG_V4, cart_crc);
			snap;
			deliver;                                // late, into the committed bank
			wait_busy(QUIET + 4000);                // the re-arm
			wait_idle(2000000);
			if (hdr_rd != s_hdr + 1) `FAIL(("%0d re-armed applies read a header, expected 1", hdr_rd - s_hdr))
			else if (hdr_bank[s_hdr % 4096] !== s_bank) `FAIL(("the re-armed apply read the spare bank"))
			if (sd_bad3(8'hF1, 8'hF2, 8'h00) != 0) `FAIL(("the delivered file was not applied"))
			if (dut.dirty0 !== 64'h300) `FAIL(("dirty %h, expected 300 (S4: the image's bitmap)", dut.dirty0))
			if (frozen !== 1'b0)
				`FAIL(("rc5 S1: an accepted boot apply did not clear the freeze"))
			expect_verdict(16'hFFFF, 16'h0001, "the late file accepted");
			if (save_present !== 1'b1) `FAIL(("the applied save does not claim the slot"))
			// staging runs again, and carries the file
			publishes(8'hF3);
			seeds_clear; exp_seed[8] = 8'hF1; exp_seed[9] = 8'hF2; exp_seed[10] = 8'hF3;
			check_committed(64'h700);
			expect23(16'hFFFF, 16'h0001, "the late file accepted");
		end
	endtask

	// ---- S1 [rc5]: the settle fires while the file is still arriving ---------
	// variant 0: the first burst carries the header and part of the payload
	// (payload CRC: verdict 3); 1: only words 0-3 (cart CRC word 4: verdict 4).
	task clr_part(input integer variant);
		integer kcut, k, n;
		begin
			fresh;
			psram_fill(16'hFEED);                   // the rest of the bank: stale
			sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
			cart_ready <= 1;                        // the cartridge is in, no settle yet
			seeds_clear;
			seed_of[8] = 8'hE1; seed_of[9] = 8'hE2; seed_of[10] = 8'hE3;
			build_img(64'h700, TAG_V4, cart_crc);
			kcut = (variant == 0) ? 256 + img_pk / 2 : 4;
			deliver_range(0, kcut);                 // the first part of the file
			snap;
			slots_settled <= 1;                     // the settle fires in the gap
			wait_hdr(s_hdr, 2000);
			wait_idle(4000000);
			if (hdr_rd != s_hdr + 1) `FAIL(("%0d applies read a header, expected 1", hdr_rd - s_hdr))
			else if (hdr_bank[s_hdr % 4096] !== s_bank) `FAIL(("the boot apply read the spare bank"))
			if (p2wr != s_p2) `FAIL(("%0d flash words written from a partial file", p2wr - s_p2))
			if (sd_bad3(8'h00, 8'h00, 8'h00) != 0) `FAIL(("flash changed by a refused apply"))
			if (dut.dirty0 !== 64'd0) `FAIL(("dirty %h after a refused boot apply (S4: unchanged)", dut.dirty0))
			if (frozen !== 1'b1) `FAIL(("S1a: the refused partial file did not freeze the session"))
			if (save_present !== 1'b0) `FAIL(("the refused file claims the slot"))
			if (variant == 0) expect_verdict(16'hFFFF, 16'h0003, "partial file: payload CRC");
			else              expect_verdict(16'hFFFF, 16'h0404, "partial file: cart CRC word 4");
			// the rest of the file arrives; its burst re-arms the apply
			snap;
			deliver_range(kcut, FILE_W);
			n = 0;
			for (k = 0; k < FILE_W; k = k + 1) if (psram[cbase(0) + k] !== img[k]) n = n + 1;
			if (n != 0) `FAIL(("setup: the committed bank is not the complete file (%0d words)", n))
			wait_busy(QUIET + 4000);
			wait_idle(4000000);
			if (hdr_rd != s_hdr + 1) `FAIL(("%0d re-armed applies read a header, expected 1", hdr_rd - s_hdr))
			else if (hdr_bank[s_hdr % 4096] !== s_bank) `FAIL(("the re-armed apply read the spare bank"))
			if (sd_bad3(8'hE1, 8'hE2, 8'hE3) != 0) `FAIL(("the complete file was not applied"))
			if (dut.dirty0 !== 64'h700) `FAIL(("dirty %h, expected 700 (S4: the image's bitmap)", dut.dirty0))
			if (stage_bank !== s_bank) `FAIL(("a boot apply changed stage_bank (S2)"))
			if (frozen !== 1'b0)
				`FAIL(("rc5 S1: the accepted re-armed apply of the complete file did not clear the freeze"))
			expect_verdict(16'hFFFF, 16'h0001, "the complete file accepted");
			if (save_present !== 1'b1) `FAIL(("the applied save does not claim the slot"))
			// passes publish again
			publishes(8'hE4);
			seeds_clear; exp_seed[8] = 8'hE1; exp_seed[9] = 8'hE2; exp_seed[10] = 8'hE4;
			check_committed(64'h700);
			expect23(16'hFFFF, 16'h0001, "the complete file accepted");
		end
	endtask

	// ---- S8 [rc5]: cart_replace drops a state request ------------------------
	// cart_replace at the next edge; from then on the cartridge is not ready
	// and the slots have not settled.
	task cut;
		begin
			@(posedge clk);
			cart_ready <= 0; slots_settled <= 0; cart_replace <= 1;
			@(posedge clk);
			cart_replace <= 0;
		end
	endtask

	// After the cut: state_done with apply_reject within 8 cycles, exactly
	// once; the copier completes; the new cartridge boots with a BOOT apply of
	// the committed bank; the dropped request is never served; nothing is
	// frozen. want23 is the boot apply's word 23 in the next staged header.
	task s8r_after(input integer s0, input [15:0] want23, input string what);
		integer n, h1;
		begin
			n = 0;
			while (sd_cnt == s0 && n < 8) begin @(posedge clk); n = n + 1; end
			if (sd_cnt == s0)
				`FAIL(("rc5 S8: no state_done within 8 cycles of cart_replace: the copier is stranded"))
			else if (sd_rej !== 1'b1)
				`FAIL(("rc5 S8: the state_done answering a dropped request has apply_reject = 0"))
			@(posedge clk);
			draining <= 0; state_frozen <= 0;       // C2: the copier completes
			repeat (8) @(posedge clk);
			if (frozen !== 1'b0) `FAIL(("frozen_o = %b after cart_replace (S1)", frozen))
			h1 = hdr_rd;
			boot_now;
			if (hdr_rd != h1 + 1)
				`FAIL(("%0d applies read a header after the reload, expected the one boot apply", hdr_rd - h1))
			else if (hdr_bank[h1 % 4096] !== stage_bank)
				`FAIL(("the apply after the reload read the spare bank: the dropped state request was served"))
			if (boot_hold !== 1'b0) `FAIL(("boot still held after the reload"))
			repeat (QUIET + 2000) @(posedge clk);
			if (sd_cnt != s0 + 1) `FAIL(("state_done pulsed %0d times for one request", sd_cnt - s0))
			publishes(8'h8F);
			expect23(16'hFFFF, want23, what);
		end
	endtask

	// The state apply in flight when the cartridge reloads.
	// stage 0: its header walk; 1: its verify pass; 2: its write pass.
	task s8r_flight(input integer stage);
		integer n;
		reg sp;
		begin
			fresh;
			psram_fill(16'hFEED);
			sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
			boot_now;                               // nothing delivered
			seeds_clear;
			seed_of[8] = 8'h8A; seed_of[9] = 8'h8B; seed_of[10] = 8'h8C;
			build_img(64'h700, TAG_V4, cart_crc);
			st_from_img;
			snap;
			sp = ~s_bank;
			drain_begin;
			pulse_state_apply;
			n = 0;
			case (stage)
				0: while (hdr_rd == s_hdr && n < 20000) begin @(posedge clk); n = n + 1; end
				1: while (rd_of(sp) - (sp ? s_rd1 : s_rd0) < 40 && n < 200000) begin @(posedge clk); n = n + 1; end
				default: while (p2wr == s_p2 && n < 2000000) begin @(posedge clk); n = n + 1; end
			endcase
			repeat (3) @(posedge clk);
			if (hdr_rd == s_hdr) `FAIL(("setup: the state apply never started"))
			else if (hdr_bank[s_hdr % 4096] !== sp) `FAIL(("setup: the state apply read the committed bank"))
			if (stage == 1 && rd_of(sp) - (sp ? s_rd1 : s_rd0) < 40) `FAIL(("setup: the verify pass never began"))
			if (stage < 2 && p2wr != s_p2) `FAIL(("setup: the apply is already writing flash"))
			if (stage == 2 && p2wr == s_p2) `FAIL(("setup: the write pass never began"))
			if (busy !== 1'b1 || sd_cnt != s_sd) `FAIL(("setup: the state apply is no longer in flight"))
			cut;
			s8r_after(s_sd, 16'h0005, "after the reload: nothing delivered, a boot apply");
		end
	endtask

	// ============================================================================
	integer i, k, n, f0, bf0, sp;
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

`ifdef NGPC_SAVE_DIAG
		$display("== build: NGPC_SAVE_DIAG defined");
`else
		$display("== build: NGPC_SAVE_DIAG not defined (verdict checks compiled out)");
`endif

		// ---- S10-21: the writer revision ----------------------------------------
		begin_scn("S10-21", "header word 21 = {8'h06, cart_subcat} in every staged header");
		fresh;
		psram_fill(16'hFEED);
		boot_now;
		publishes(8'h21);
		if (hdr(21) !== 16'h0601) `FAIL(("word 21 = %h, expected 0601", hdr(21)))
		seeds_clear; exp_seed[10] = 8'h21;
		check_committed(64'h400);
		@(posedge clk); cart_subcat <= 8'h7E;
		publishes(8'h22);
		if (hdr(21) !== 16'h067E) `FAIL(("word 21 = %h, expected 067E", hdr(21)))
		@(posedge clk); cart_subcat <= 8'h01;
		end_scn;

		// ---- S6 [rc5]: a state for another cartridge ----------------------------
		begin_scn("S6x-W4", "wake: a state whose cart CRC word 4 is another cart's: no-op accept, no freeze, verdict 6 @4");
		s6x_wake(4);
		end_scn;
		begin_scn("S6x-W5", "wake: a state whose cart CRC word 5 is another cart's: no-op accept, no freeze, verdict 6 @5");
		s6x_wake(5);
		end_scn;
		begin_scn("S6x-W45", "wake: another cartridge's whole image: no-op accept, no freeze, verdict 6 @4");
		s6x_wake(45);
		end_scn;
		begin_scn("S6x-TAGCRC", "wake: tag V3 AND another cart's CRC: the CRC outranks the tag -> S6 no-op, verdict 6 @4");
		s6x_wake(3);
		end_scn;
		begin_scn("S6x-DIRTY4", "dirty not empty: a state for another cart (word 4) is a reject, verdict 6 @4, no freeze");
		s6x_dirty(4);
		end_scn;
		begin_scn("S6x-DIRTY5", "dirty not empty: a state for another cart (word 5) is a reject, verdict 6 @5, no freeze");
		s6x_dirty(5);
		end_scn;

		// ---- S11 [rc5]: a state from a frozen session -----------------------------
		begin_scn("S11-WAKE", "wake, frozen state with a good image: nothing read or written, accepted, frozen, verdict 7");
		s11_wake;
		frozen_window;
		if (bank_vs(0) != 0) `FAIL(("the committed bank changed (%0d words)", bank_vs(0)))
		end_scn;

		begin_scn("S11-MID", "mid-session, frozen state that would fail coverage: accepted, nothing read, dirty kept, frozen");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		boot_now;
		publishes(8'hB4);                           // dirty = block 10
		seeds_clear;
		seed_of[8] = 8'hB5;
		build_img(64'h100, TAG_V4, cart_crc);       // omits the dirty block 10
		st_from_img;
		keep_committed;
		snap;
		state_load_fz(1'b1);
		if (sd_cnt != s_sd + 1) `FAIL(("state_done pulsed %0d times", sd_cnt - s_sd))
		if (sd_rej !== 1'b0) `FAIL(("rc5 S11: a frozen state was rejected (S5 coverage must not apply: nothing is read)"))
		if (rd_b0 != s_rd0 || rd_b1 != s_rd1)
			`FAIL(("rc5 S11: the frozen state apply read PSRAM (%0d / %0d reads of bank 0 / 1)", rd_b0 - s_rd0, rd_b1 - s_rd1))
		if (p2wr != s_p2) `FAIL(("rc5 S11: %0d flash words written", p2wr - s_p2))
		if (sd_bad3(8'h00, 8'h00, 8'hB4) != 0) `FAIL(("rc5 S11: flash changed"))
		if (eng_wr != s_ew) `FAIL(("rc5 S11: %0d engine PSRAM writes", eng_wr - s_ew))
		if (stage_bank !== s_bank || flips != s_fl) `FAIL(("rc5 S11: stage_bank changed"))
		if (dut.dirty0 !== 64'h400) `FAIL(("rc5 S11: dirty %h, expected unchanged (400)", dut.dirty0))
		if (frozen !== 1'b1) `FAIL(("rc5 S11/S1d: the frozen state did not freeze the session"))
		if (save_present !== 1'b0) `FAIL(("save_present while frozen"))
		expect_verdict(16'hC0FF, 16'h8007, "rc5 S11: frozen state mid-session");
		frozen_window;
		if (bank_vs(0) != 0) `FAIL(("the committed bank changed (%0d words)", bank_vs(0)))
		end_scn;

		begin_scn("S11-FROZEN", "already frozen: a frozen state (no image) is accepted; a good state later does not unfreeze");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		cart_ready <= 1;
		seeds_clear;
		seed_of[8] = 8'hB6; seed_of[9] = 8'hB7; seed_of[10] = 8'hB8;
		build_img(64'h700, TAG_V3, cart_crc);      // a file this build refuses
		deliver;
		slots_settled <= 1;
		repeat (4) @(posedge clk);
		wait_idle(2000000);
		if (frozen !== 1'b1) `FAIL(("setup: the refused file did not freeze (S1a)"))
		build_noimage;
		st_from_img;
		snap;
		state_load_fz(1'b1);
		if (sd_rej !== 1'b0) `FAIL(("rc5 S11: a frozen state with no image was rejected"))
		if (rd_b0 != s_rd0 || rd_b1 != s_rd1)
			`FAIL(("rc5 S11: the frozen state apply read PSRAM (%0d / %0d reads of bank 0 / 1)", rd_b0 - s_rd0, rd_b1 - s_rd1))
		if (p2wr != s_p2) `FAIL(("rc5 S11: flash written"))
		if (dut.dirty0 !== 64'd0) `FAIL(("rc5 S11: dirty %h, expected unchanged (0)", dut.dirty0))
		if (frozen !== 1'b1) `FAIL(("rc5 S11: frozen_o fell"))
		expect_verdict(16'hC0FF, 16'h8007, "rc5 S11: frozen state in a frozen session");
		if (bank_vs_deliv(0) != 0) `FAIL(("the committed bank is no longer the delivered file"))
		// an ordinary state (not frozen) is applied, but no state apply clears
		// the freeze (S1) and none commits a bank while frozen (S2)
		seeds_clear;
		seed_of[8] = 8'hB9; seed_of[9] = 8'hBA; seed_of[10] = 8'hBB;
		build_img(64'h700, TAG_V4, cart_crc);
		st_from_img;
		snap;
		state_load;
		if (sd_rej !== 1'b0) `FAIL(("a good state was rejected while frozen"))
		if (sd_bad3(8'hB9, 8'hBA, 8'hBB) != 0) `FAIL(("the good state's image did not reach flash"))
		if (dut.dirty0 !== 64'h700) `FAIL(("dirty %h after the accepted state, expected 700 (S4)", dut.dirty0))
		if (stage_bank !== s_bank || flips != s_fl) `FAIL(("a state apply committed a bank while frozen (S2)"))
		if (frozen !== 1'b1) `FAIL(("S1: a state apply cleared the freeze"))
		frozen_window;
		if (bank_vs_deliv(0) != 0) `FAIL(("the committed bank is no longer the delivered file"))
		end_scn;

		begin_scn("S11-QUEUED", "a frozen state requested during a boot apply: the next apply reads nothing, accepted, frozen");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00);
		cart_ready <= 1;
		seeds_clear;
		seed_of[8] = 8'hBC; build_img(64'h100, TAG_V4, cart_crc);
		deliver;                                    // the file
		seed_of[8] = 8'hBD; build_img(64'h100, TAG_V4, cart_crc);
		st_from_img;                                // the frozen session's state
		repeat (QUIET + 50) @(posedge clk);
		snap;
		// The bridge's check has passed (layout 3, B2) before the copier's
		// drain begins, and the slots settle in that gap: the boot apply
		// starts with state_frozen_i already high but no state request
		// pending. It is a boot apply, not S11 ("a STATE apply served while
		// state_frozen_i = 1"), so it must read and apply the file.
		state_frozen <= 1;
		repeat (10) @(posedge clk);
		slots_settled <= 1;
		wait_hdr(s_hdr, 1000);                      // the boot apply starts
		// the copier drains now, while the boot apply runs
		draining <= 1;
		sp = s_bank ? 0 : BANK_W;
		for (k = 0; k < FILE_W; k = k + 1) psram[sp + k] = stimg[k];
		diag_drain <= diag_drain + 16'd32512;
		repeat (60) @(posedge clk);
		if (busy !== 1'b1) `FAIL(("setup: the boot apply was no longer running at the pulse"))
		s_rd0 = rd_b0; s_rd1 = rd_b1;               // from the pulse on
		pulse_state_apply;
		wait_state_done(s_sd);
		state_frozen <= 0;
		draining <= 0;
		repeat (QUIET + 2000) @(posedge clk);
		if (sd_cnt != s_sd + 1) `FAIL(("state_done pulsed %0d times", sd_cnt - s_sd))
		if (sd_rej !== 1'b0) `FAIL(("rc5 S11: the frozen state was rejected"))
		if (hdr_rd != s_hdr + 1)
			`FAIL(("%0d applies read a header, expected only the boot apply (0: the boot apply, started with state_frozen_i high but no state request, was taken for S11)",
			       hdr_rd - s_hdr))
		else if (hdr_bank[s_hdr % 4096] !== s_bank) `FAIL(("the boot apply read the spare bank"))
		if (rd_of(~s_bank) != (s_bank ? s_rd0 : s_rd1))
			`FAIL(("rc5 S11: %0d reads of the drained bank after the pulse: a frozen state reads nothing",
			       rd_of(~s_bank) - (s_bank ? s_rd0 : s_rd1)))
		if (sd_bad(8, 8'hBC) != 0)
			`FAIL(("block 8 does not hold the file: the boot apply (state_frozen_i high, no state request) did not apply it, or the frozen state was applied"))
		if (dut.dirty0 !== 64'h100) `FAIL(("dirty %h, expected 100 (the boot apply's; S11 leaves it)", dut.dirty0))
		if (stage_bank !== s_bank || flips != s_fl) `FAIL(("stage_bank changed"))
		if (frozen !== 1'b1) `FAIL(("rc5 S11: the frozen state did not freeze the session"))
		expect_verdict(16'hC0FF, 16'h8007, "rc5 S11: frozen state after a boot apply");
		frozen_window;
		end_scn;

		// ---- S1(c) [rc5]: a load failure reported by the bridge -------------------
		begin_scn("S1c-WAKE", "state_fail at a wake (nothing accepted, dirty empty) freezes");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		boot_now;                                   // nothing delivered
		if (frozen !== 1'b0 || dut.dirty0 !== 64'd0) `FAIL(("setup: frozen %b dirty %h", frozen, dut.dirty0))
		pulse_state_fail;                           // e.g. the identity check failed
		if (frozen !== 1'b1) `FAIL(("rc5 S1c: state_fail at a wake did not freeze"))
		frozen_window;
		end_scn;

		begin_scn("S1c-PEND", "state_fail while the boot apply waits: freezes; a 'nothing delivered' boot apply keeps it");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		cart_ready <= 1;                            // no settle yet: the boot apply waits
		repeat (50) @(posedge clk);
		if (boot_hold !== 1'b1) `FAIL(("setup: the boot apply is not pending"))
		snap;
		pulse_state_fail;
		if (frozen !== 1'b1) `FAIL(("rc5 S1c: state_fail with the boot apply pending did not freeze"))
		slots_settled <= 1;
		wait_hdr(s_hdr, 1000);
		wait_idle(2000000);
		if (frozen !== 1'b1)
			`FAIL(("S1: a boot apply that found nothing delivered cleared the freeze (only an accepted one may)"))
		expect_verdict(16'hFFFF, 16'h0005, "boot apply, nothing delivered");
		frozen_window;
		end_scn;

		// A wake whose state fails at the bridge while the file has already
		// arrived: S1(c) freezes (nothing accepted yet, dirty empty), and the
		// boot apply that follows -- the first one, not a re-armed one --
		// accepts the file and so clears the freeze (S1 rc5).
		begin_scn("S1c-PEND-FILE", "state_fail while the boot apply waits on a delivered file: freezes; that boot apply accepts it and unfreezes");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		cart_ready <= 1;                            // no settle yet: the boot apply waits
		seeds_clear;
		seed_of[8] = 8'hC1; seed_of[9] = 8'hC2;
		build_img(64'h300, TAG_V4, cart_crc);
		deliver;                                    // the file, ahead of the settle
		repeat (QUIET + 50) @(posedge clk);         // its burst is long over
		snap;
		if (boot_hold !== 1'b1 || busy !== 1'b1)
			`FAIL(("setup: the boot apply is not pending (boot_hold %b busy %b)", boot_hold, busy))
		pulse_state_fail;                           // e.g. the state failed its identity check
		if (frozen !== 1'b1) `FAIL(("rc5 S1c: state_fail with the boot apply pending did not freeze"))
		if (hdr_rd != s_hdr) `FAIL(("setup: an apply ran before the settle"))
		slots_settled <= 1;
		wait_hdr(s_hdr, 1000);
		wait_idle(2000000);
		repeat (QUIET + 2000) @(posedge clk);
		if (hdr_rd != s_hdr + 1) `FAIL(("%0d applies read a header, expected the one boot apply", hdr_rd - s_hdr))
		else if (hdr_bank[s_hdr % 4096] !== s_bank) `FAIL(("the boot apply read the spare bank (S8)"))
		if (sd_bad3(8'hC1, 8'hC2, 8'h00) != 0) `FAIL(("the delivered file was not applied"))
		if (dut.dirty0 !== 64'h300) `FAIL(("dirty %h, expected 300 (S4: the image's bitmap)", dut.dirty0))
		if (stage_bank !== s_bank) `FAIL(("a boot apply changed stage_bank (S2)"))
		if (frozen !== 1'b0)
			`FAIL(("rc5 S1: the accepted boot apply did not clear the freeze state_fail set"))
		expect_verdict(16'hFFFF, 16'h0001, "the file accepted");
		if (save_present !== 1'b1) `FAIL(("the applied save does not claim the slot"))
		publishes(8'hC3);
		seeds_clear; exp_seed[8] = 8'hC1; exp_seed[9] = 8'hC2; exp_seed[10] = 8'hC3;
		check_committed(64'h700);
		expect23(16'hFFFF, 16'h0001, "the file accepted");
		end_scn;

		begin_scn("S1c-BASE-BOOT", "an accepted boot apply (dirty still empty): state_fail does not freeze");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		cart_ready <= 1;
		seeds_clear;
		build_img(64'h0, TAG_V4, cart_crc);         // a valid file listing no blocks
		deliver;
		slots_settled <= 1;
		repeat (4) @(posedge clk);
		wait_idle(2000000);
		if (dut.dirty0 !== 64'd0 || frozen !== 1'b0) `FAIL(("setup: dirty %h frozen %b", dut.dirty0, frozen))
		expect_verdict(16'hFFFF, 16'h0001, "setup: the empty file accepted");
		pulse_state_fail;
		if (frozen !== 1'b0) `FAIL(("rc5 S1c: state_fail froze a session in which an apply was accepted"))
		publishes(8'hC5);
		seeds_clear; exp_seed[10] = 8'hC5;
		check_committed(64'h400);
		end_scn;

		begin_scn("S1c-BASE-STATE", "an accepted state apply (dirty still empty): state_fail does not freeze");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		boot_now;                                   // nothing delivered
		seeds_clear;
		build_img(64'h0, TAG_V4, cart_crc);         // a state whose image lists no blocks
		st_from_img;
		state_load;
		if (sd_rej !== 1'b0 || dut.dirty0 !== 64'd0) `FAIL(("setup: reject %b dirty %h", sd_rej, dut.dirty0))
		pulse_state_fail;
		if (frozen !== 1'b0) `FAIL(("rc5 S1c: state_fail froze a session in which a state apply was accepted"))
		publishes(8'hC6);
		seeds_clear; exp_seed[10] = 8'hC6;
		check_committed(64'h400);
		end_scn;

		begin_scn("S1c-DIRTY", "dirty not empty: state_fail does not freeze");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		boot_now;                                   // nothing delivered
		publishes(8'hC7);
		pulse_state_fail;
		if (frozen !== 1'b0) `FAIL(("rc5 S1c: state_fail froze a session with dirty blocks"))
		publishes(8'hC8);
		seeds_clear; exp_seed[10] = 8'hC8;
		check_committed(64'h400);
		end_scn;

		begin_scn("S1c-EPOCH", "an apply accepted before cart_replace is no base after it: state_fail freezes");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		boot_now;
		seeds_clear; seed_of[8] = 8'hC9;
		build_img(64'h100, TAG_V4, cart_crc);
		st_from_img;
		state_load;
		if (sd_rej !== 1'b0) `FAIL(("setup: a good state was rejected"))
		reload;
		boot_now;                                   // nothing delivered in either epoch
		if (dut.dirty0 !== 64'd0) `FAIL(("setup: dirty %h after the reload", dut.dirty0))
		pulse_state_fail;
		if (frozen !== 1'b1) `FAIL(("rc5 S1c: state_fail after a cart_replace did not freeze (the old base still counted)"))
		frozen_window;
		end_scn;

		// ---- S1 [rc5]: what clears a freeze --------------------------------------
		begin_scn("S1-CLR-EDGE", "a freeze is cleared by cart_replace alone, and by reset alone");
		fresh;
		psram_fill(16'hFEED);
		boot_now;
		pulse_state_fail;
		if (frozen !== 1'b1) `FAIL(("setup: not frozen"))
		b0 = stage_bank;
		reload;
		if (frozen !== 1'b0) `FAIL(("cart_replace did not clear the freeze (S1)"))
		boot_now;
		pulse_state_fail;
		if (frozen !== 1'b1) `FAIL(("setup: not frozen again"))
		@(posedge clk);
		cart_ready <= 0; slots_settled <= 0;
		reset <= 1;
		repeat (4) @(posedge clk);
		reset <= 0;
		repeat (2) @(posedge clk);
		if (frozen !== 1'b0) `FAIL(("reset did not clear the freeze (S1)"))
		if (stage_bank !== b0) `FAIL(("stage_bank changed across reset / cart_replace (S2)"))
		boot_now;
		publishes(8'hCA);
		end_scn;

		begin_scn("S1-CLR-PAY", "settle mid-delivery (payload cut): refused, frozen; the re-armed apply of the whole file unfreezes");
		clr_part(0);
		end_scn;
		begin_scn("S1-CLR-HDR", "settle mid-delivery (header cut after word 3): refused, frozen; the re-armed apply unfreezes");
		clr_part(1);
		end_scn;
		begin_scn("S1-CLR-FAIL", "frozen by state_fail at a wake: a late delivery's accepted boot apply unfreezes");
		clr_late(0);
		end_scn;
		begin_scn("S1-CLR-S11", "frozen by a frozen state at a wake: a late delivery's accepted boot apply unfreezes");
		clr_late(1);
		end_scn;

		// Only an accepted BOOT apply clears a freeze. A state apply that also
		// serves the pending boot apply (S8) is a state apply ("an apply
		// started while a state request is pending"): accepted and applied,
		// but the session stays frozen and no bank is committed (S1, S2).
		begin_scn("S1-NOCLR-STATE", "frozen at a wake; a good state then serves the pending boot apply: applied, but still frozen, no commit");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		cart_ready <= 1;                            // no settle yet: the boot apply waits
		seeds_clear;
		seed_of[8] = 8'hC4; seed_of[9] = 8'hC5;
		build_img(64'h300, TAG_V4, cart_crc);
		deliver;                                    // the file
		repeat (QUIET + 50) @(posedge clk);
		pulse_state_fail;                           // the first load failed at the bridge
		if (frozen !== 1'b1) `FAIL(("setup: state_fail at a wake did not freeze (S1c)"))
		seeds_clear;
		seed_of[8] = 8'hD5; seed_of[9] = 8'hD6; seed_of[10] = 8'hD7;
		build_img(64'h700, TAG_V4, cart_crc);       // a good state, loaded next
		st_from_img;
		snap;
		drain_begin;
		pulse_state_apply;
		repeat (100) @(posedge clk);
		slots_settled <= 1;                         // one state apply serves both
		wait_state_done(s_sd);
		draining <= 0;
		repeat (QUIET + 2000) @(posedge clk);
		if (sd_cnt != s_sd + 1) `FAIL(("state_done pulsed %0d times", sd_cnt - s_sd))
		if (sd_rej !== 1'b0) `FAIL(("a good state was rejected while frozen"))
		if (hdr_rd != s_hdr + 1)
			`FAIL(("%0d applies read a header; one state apply serves the pending boot apply too (S8)", hdr_rd - s_hdr))
		else if (hdr_bank[s_hdr % 4096] !== ~s_bank)
			`FAIL(("the apply read the committed bank: it was not the state apply (S8)"))
		if (sd_bad3(8'hD5, 8'hD6, 8'hD7) != 0) `FAIL(("the good state's image did not reach flash"))
		if (dut.dirty0 !== 64'h700) `FAIL(("dirty %h after the accepted state, expected 700 (S4)", dut.dirty0))
		if (stage_bank !== s_bank || flips != s_fl) `FAIL(("a state apply committed a bank while frozen (S2)"))
		if (frozen !== 1'b1)
			`FAIL(("rc5 S1: a state apply that served the pending boot apply cleared the freeze (only an accepted BOOT apply may)"))
		if (bank_vs_deliv(0) != 0) `FAIL(("the committed bank is no longer the delivered file"))
		expect_verdict(16'hFFFF, 16'h8001, "the state accepted");
		frozen_window;
		if (bank_vs_deliv(0) != 0) `FAIL(("the committed bank is no longer the delivered file"))
		end_scn;

		// ---- S9 [rc5]: no publish while a late delivery waits for its apply -----
		begin_scn("S9-GATE", "a pass running when a late file arrives does not publish before the re-armed apply");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		boot_now;                                   // settle fired early: nothing delivered
		seeds_clear;
		seed_of[8] = 8'h9A; seed_of[9] = 8'h9B;
		build_img(64'h300, TAG_V4, cart_crc);       // the file, arriving late
		b0 = stage_bank; f0 = flips; bf0 = bad_flip;
		game_write(10, 8'h9C);                      // a pass is owed ...
		wait_busy(QUIET + 2000);                    // ... and starts
		repeat (200) @(posedge clk);
		snap;
		if (busy !== 1'b1 || flips != f0) `FAIL(("setup: the pass is not running when the file arrives"))
		deliver;                                    // late, into the committed bank
		if (busy !== 1'b1) `FAIL(("setup: the pass ended before host_busy fell"))
		n = 0;
		while (busy === 1'b1 && n < 2000000) begin @(posedge clk); n = n + 1; end
		// The pass is over: host_busy is low, flash is quiet, nothing new is
		// dirty -- every rc4 publish condition holds. Only the waiting re-arm
		// (saw_save_wr) may hold it.
		if (apf_busy !== 1'b0 || die_busy !== 2'b00) `FAIL(("setup: APF or a die is busy at the end of the pass"))
		if (hdr_rd != s_hdr) `FAIL(("setup: an apply ran before the pass ended"))
		if (flips != f0 || stage_bank !== b0)
			`FAIL(("rc5 S9: the pass that started before the late delivery published before its re-armed apply"))
		wait_hdr(s_hdr, 400000);                    // the re-armed apply
		if (hdr_rd != s_hdr) begin
			if (flips != f0) `FAIL(("rc5 S9: a pass published before the re-armed apply"))
			if (hdr_bank[s_hdr % 4096] !== b0)
				`FAIL(("the re-armed apply did not read the bank the file was delivered into"))
		end
		wait_idle(2000000);
		if (sd_bad(8, 8'h9A) + sd_bad(9, 8'h9B) != 0) `FAIL(("the delivered blocks were not restored"))
		if (sd_bad(10, 8'h9C) != 0) `FAIL(("the game's block 10 was touched (S4: the walk follows the image)"))
		if (dut.dirty0 !== 64'h300) `FAIL(("rc5 S4: dirty %h, expected 300 (the file's bitmap, no union)", dut.dirty0))
		if (frozen !== 1'b0) `FAIL(("frozen after an accepted apply"))
		// any pass still owed runs now; either way the committed image is the
		// delivered file's blocks
		repeat (QUIET + 100) @(posedge clk);
		wait_idle(2000000);
		seeds_clear; exp_seed[8] = 8'h9A; exp_seed[9] = 8'h9B;
		check_committed(64'h300);
		if (save_present !== 1'b1) `FAIL(("save_present low"))
		// and staging carries on from the restored save
		f0 = flips;
		game_write(8, 8'h9D);
		wait_publish(f0);
		seeds_clear; exp_seed[8] = 8'h9D; exp_seed[9] = 8'h9B;
		check_committed(64'h300);
		if (bad_flip != bf0) `FAIL(("stage_bank changed while APF or a die was busy"))
		end_scn;

		// ---- S8 [rc5]: cart_replace and a state request ---------------------------
		for (i = 0; i < 2; i = i + 1) begin
			if (i == 0) begin_scn("S8R-PEND", "cart_replace while a state request waits for the settle: state_done + reject");
			else        begin_scn("S8R-PEND-FZ", "the same for a frozen session's state: dropped, never served, no freeze");
			fresh;
			psram_fill(16'hFEED);
			sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
			cart_ready <= 1;                        // no settle: nothing can be served
			repeat (20) @(posedge clk);
			seeds_clear; seed_of[8] = 8'hD3;
			build_img(64'h100, TAG_V4, cart_crc);
			st_from_img;
			snap;
			if (i == 1) begin @(posedge clk); state_frozen <= 1; end
			drain_begin;
			pulse_state_apply;
			repeat (50) @(posedge clk);
			if (hdr_rd != s_hdr || sd_cnt != s_sd) `FAIL(("setup: the request was served before the settle"))
			cut;
			s8r_after(s_sd, 16'h0005, "after the reload: nothing delivered, a boot apply");
			if (p2wr != s_p2) `FAIL(("%0d flash words written", p2wr - s_p2))
			if (sd_bad(8, 8'h00) != 0) `FAIL(("block 8 changed: the dropped state was applied"))
			end_scn;
		end

		begin_scn("S8R-QUEUED", "cart_replace while a state request waits behind a running boot apply: state_done + reject");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		cart_ready <= 1;
		seeds_clear;
		seed_of[8] = 8'hD1; build_img(64'h100, TAG_V4, cart_crc);
		deliver;                                    // the file
		seed_of[8] = 8'hD2; build_img(64'h100, TAG_V4, cart_crc);
		st_from_img;                                // the state
		repeat (QUIET + 50) @(posedge clk);
		snap;
		slots_settled <= 1;
		wait_hdr(s_hdr, 1000);                      // the boot apply starts
		draining <= 1;
		sp = s_bank ? 0 : BANK_W;
		for (k = 0; k < FILE_W; k = k + 1) psram[sp + k] = stimg[k];
		diag_drain <= diag_drain + 16'd32512;
		repeat (20) @(posedge clk);
		pulse_state_apply;
		repeat (20) @(posedge clk);
		if (busy !== 1'b1 || hdr_rd != s_hdr + 1 || sd_cnt != s_sd)
			`FAIL(("setup: the boot apply is not running with the request queued behind it"))
		cut;
		// the reload's boot apply reads the file delivered before it (S3)
		s8r_after(s_sd, 16'h0001, "after the reload: the pre-reload file, a boot apply");
		if (sd_bad(8, 8'hD1) != 0) `FAIL(("block 8 does not hold the file: the dropped state was applied"))
		end_scn;

		begin_scn("S8R-HDR", "cart_replace during a state apply's header walk: state_done + reject");
		s8r_flight(0);
		end_scn;
		begin_scn("S8R-VERIFY", "cart_replace during a state apply's verify pass: state_done + reject");
		s8r_flight(1);
		end_scn;
		begin_scn("S8R-WRITE", "cart_replace during a state apply's write pass: state_done + reject");
		s8r_flight(2);
		end_scn;

		begin_scn("S8R-SAME", "state_apply in the very cycle of cart_replace: state_done + reject");
		fresh;
		psram_fill(16'hFEED);
		sd_fill(8, 8'h00); sd_fill(9, 8'h00); sd_fill(10, 8'h00);
		boot_now;                                   // idle, ready, settled
		seeds_clear; seed_of[8] = 8'hD4;
		build_img(64'h100, TAG_V4, cart_crc);
		st_from_img;
		snap;
		drain_begin;                                // the copier has drained ...
		@(posedge clk);
		state_apply <= 1; cart_replace <= 1;        // ... and pulses as the cartridge reloads
		@(posedge clk);
		state_apply <= 0; cart_replace <= 0; cart_ready <= 0; slots_settled <= 0;
		sa_cnt = sa_cnt + 1;
		s8r_after(s_sd, 16'h0005, "after the reload: nothing delivered, a boot apply");
		if (hdr_rd != s_hdr + 1) `FAIL(("%0d applies read a header, expected only the reload's boot apply", hdr_rd - s_hdr))
		if (sd_bad(8, 8'h00) != 0) `FAIL(("block 8 changed: the dropped state was applied"))
		end_scn;

		// ---- summary ------------------------------------------------------------------
		if (bad_flip != 0) begin
			errors = errors + 1;
			$display("== FAIL: %0d bank change(s) while a die or APF was busy", bad_flip);
		end
		if (frz_mis != 0) begin
			errors = errors + 1;
			$display("== FAIL: frozen_o differed from refused_q for %0d cycles", frz_mis);
		end
		$display("== %0d scenario(s), %0d failed, %0.1f ms simulated", n_scn, n_scn_fail, $realtime / 1.0e6);
		if (errors == 0) $display("== ALL RC5 ENGINE SCENARIOS PASS");
		else             $display("== %0d FAILURE(S)", errors);
		$finish;
	end

	initial begin
		#4_000_000_000;
		$display("== WATCHDOG TIMEOUT in %0s", scn);
		$display("== %0d FAILURE(S)", errors + 1);
		$finish;
	end

	wire unused = &{1'b0, p2_be, st_wdata, 1'b0};

endmodule

`default_nettype wire
