// Testbench: the rc4 savestate load path, end to end, with the REAL copier
// (ngpc_state_cart) and the REAL save engine (ngpc_cart_save) wired to each
// other the way core_top / ngpc_machine wire them.
//
// Real, compiled unmodified: target/pocket/ngpc_state_cart.sv,
// target/pocket/ngpc_cart_save.sv and upstream's ngp_cart_overlay_geometry.
// QUIET_CLOCKS and DR_WAIT_TIMEOUT are shrunk by parameter.
//
// Wiring (core_top.v / ngpc_machine.sv, rc4):
//   copier draining_o     -> engine draining_i, and ORed into host_busy_i
//   engine state_done_o   -> copier state_done_i
//   engine apply_reject_o -> copier apply_reject_i
//   engine stage_current_o-> copier stage_current_i
//   copier diag_drain_o   -> engine diag_drain_i
//   copier state_apply_o  -> engine state_apply_i
//   staging engine port: the copier borrows it while sc_rd_active and reads
//     the COMMITTED bank (sc_rd_addr | stage_bank << 16)
//   staging host writes: APF delivery -> the committed bank, and it is the
//     engine's save_slot_wr_i; the copier's drain -> the SPARE bank
//     (~stage_bank), and it is NOT a delivery
//
// Modeled: cartridge SDRAM (p2 port, done 2 clk after the request),
// the staging PSRAM as ONE memory behind an engine port (ready/done, a
// few clocks an access) and a host-write skid with ready backpressure
// (the copier's sc_host_ready) and a host_busy tail like stage_mem's
// (shorter than QUIET_CLOCKS, as on hardware);
// the bridge's cart section (a 32-bit word array, reads valid 3 clk after
// the address, capture writes land in the same array); APF (delivery
// bursts, slots_settled); and the game (flash write events, die_busy).
//
// SCENARIOS (spec items in brackets)
//   B0   boot with nothing delivered: no flash write, no state_done, no X.
//   CAP1 capture after a publish embeds the committed bank byte-exact, and
//        its header carries the boot apply's verdict: word 23 = 0005
//        (nothing delivered, recorded at the early exit), 22 = 1, 16 = 0,
//        24 = 0; a capture requested with a pass owed waits for it and
//        embeds the freshly published image, which decodes to live flash.
//                                                       [Capture, S10]
//   DL1  deadlock regression, pass OWED: the game writes flash just before
//        the load request. The copier must not raise draining_o while it
//        waits, so the owed pass runs and publishes, then the drain runs,
//        and the state is applied: flash rewound, dirty = image bitmap,
//        committed bank = the drained bank.        [C1, C2, S2, S4, S8]
//   DL2  same, pass already RUNNING at the load request.         [C1]
//   CH1  chained applies at wake: the boot apply is pending since reset
//        (a file was delivered), slots_settled rises mid-drain. No flash
//        write before the state pulse (no boot apply under draining_i),
//        ONE state apply serves both and reads the spare (drained) image
//        (exactly 12288 flash writes: one pass over the state's blocks),
//        the delivered file's extra block is never applied, the copier
//        reports done only after that apply, no error; stage_bank kept
//        across reset (checked at every power-up; here it is 1). [S8, S2, C2]
//   CAP2 capture after a state commit reads the new committed bank; the
//        next published header carries word 18 = drain beats, word 16-18 =
//        delivery beats, word 22 = 1 apply, word 23 = 0x8001, word 24 =
//        12288 p2 writes.                                         [S10]
//   RJ1  mid-session (base, dirty 8+10), the delivered file loaded as a
//        state with one payload word damaged (bitmap 8+9+10 covers dirty):
//        cart_load_error=1, no flash write, committed bank and dirty kept
//        (the next header's bitmap is still 0500 -- savefix left the image's
//        0700), not frozen; header 18 = 65024, 22 = 2, 23 = 0x8003, 24 = 0.
//                                                  [S7, S4, S1b, S10]
//   FZ1  wake, no delivery, state image with a bad tag: cart_load_error=1,
//        flash untouched, no bank change, committed bank intact, and the
//        session is frozen: a later flash write starts no pass and does not
//        publish, save_present stays 0, stage_current stays 1.  [S7, S1b]
//   FZ2  a capture while frozen does not wait on the owed pass and embeds
//        the committed (as-delivered) bank.                          [S1]
//   FZ3  a good state loaded while frozen: its drain starts at once,
//        flash is restored, dirty = the image bitmap, no error, but no bank
//        is committed, save_present stays 0 (dirty is non-empty and the
//        applied image holds data, so the freeze is what holds it down)
//        and the session stays frozen.
//                                                           [S1, S2, S4]
//   NI1  cartless state (no magic) with dirty empty: success, nothing
//        written, no bank change, one state_done, not frozen (a later write
//        publishes; its header says 0x8006).                   [S6, S10]
//   NI2  the same state with dirty non-empty: cart_load_error=1, nothing
//        written, dirty unchanged, not frozen.                        [S6]
//   TO1  I_DR_WAIT timeout: a pass owed forever (die_busy held) keeps
//        stage_current low -> done with error after ~DR_WAIT_TIMEOUT,
//        draining_o never raised, nothing written to staging or flash.  [C1]
//   TO2  the copier is idle again: once the flash settles, a load works.
//   Global monitors: no request dropped by the staging port, no write into
//   a full skid, no drain write whose sampled host_ready was low (and
//   host_ready did fall under drains), no drain write outside draining_o,
//   one state_done per state_apply and none for boot applies, capture
//   reads only under hold.
//
// Stimulus follows tb_cart_save: DUT-facing regs change with <= at a clock
// edge.

`timescale 1ns / 1ps
`default_nettype none

module tb_rc4_loadpath;

	reg clk = 0;
	always #10.173 clk = ~clk;
	reg reset = 1;

	localparam integer CARTW      = 16256;    // section words (32-bit)
	localparam integer SLOTW      = 32512;    // slot words (16-bit), 0xFE00 bytes
	localparam integer BANKW      = 32768;    // staging bank, 16-bit words
	localparam integer FLASHW     = 262144;   // one 4 Mbit die, 16-bit words
	localparam integer DRW_TO     = 150000;   // copier DR_WAIT_TIMEOUT
	// stage_mem's host_busy tail, shrunk. Kept SHORTER than QUIET_CLOCKS
	// (200) because it is on hardware: 500k vs 1M clk, ~10 ms vs ~20 ms.
	localparam integer HOST_IDLE  = 100;
	localparam integer SKID_DEPTH = 32;       // host-write skid entries (index [4:0])
	localparam integer PS_LAT     = 3;        // PSRAM clocks per access
	localparam integer LOAD_MAX   = DRW_TO + 800000;

	// ---- cartridge / game / APF --------------------------------------------
	reg         cart_ready = 0, cart_replace = 0;
	reg  [31:0] cart_crc   = 32'h600DCA57;
	reg  [24:0] cart_bytes = 25'h0080000;
	reg   [1:0] size_code0 = 2'd1;           // one 4 Mbit die
	reg   [1:0] size_code1 = 2'd0;           // second die absent
	reg         event0 = 0;
	reg   [5:0] block0 = 0;
	reg   [1:0] die_busy = 0;
	reg         slots_settled = 0;

	reg         apf_wr = 0;
	reg  [24:0] apf_addr = 0;
	reg  [15:0] apf_data = 0;

	// ---- bridge side -------------------------------------------------------
	reg         cart_save_req = 0, cart_load_req = 0;
	wire        cart_save_done, cart_load_done, cart_load_error;
	wire        cart_img_wr;
	wire [13:0] cart_img_addr, cart_img_rd_addr;
	wire [31:0] cart_img_data;
	reg  [31:0] cart_img_rd_data;

	// ---- engine ------------------------------------------------------------
	wire        boot_hold, busy, save_present, stage_current, stage_bank;
	wire        apply_reject, state_done;
	wire        p2_req, p2_we;
	wire [24:0] p2_addr;
	wire [15:0] p2_wdata;
	wire  [1:0] p2_be;
	reg         p2_done = 0;
	reg  [15:0] p2_rdata = 0;
	reg         p2_pend = 0;
	wire        cs_st_req, cs_st_we;
	wire [24:0] cs_st_addr;
	wire [15:0] cs_st_wdata;

	// ---- copier ------------------------------------------------------------
	wire        sc_rd_req, sc_rd_active, sc_draining;
	wire [24:0] sc_rd_addr;
	wire        sc_host_wr;
	wire [24:0] sc_host_addr;
	wire [15:0] sc_host_data;
	wire        state_apply, hold;
	wire [15:0] diag_drain;

	// ---- staging port and host path (core_top muxes) -----------------------
	wire        eng_ready;
	reg         eng_done = 0;
	reg  [15:0] eng_rdata = 0;
	wire        host_ready, host_busy;
	reg  [15:0] diag_beats = 0, diag_drops = 0;

	wire        eng_req   = sc_rd_active ? sc_rd_req : cs_st_req;
	wire        eng_we    = sc_rd_active ? 1'b0      : cs_st_we;
	wire [24:0] eng_addr  = sc_rd_active ? (sc_rd_addr | {8'd0, stage_bank, 16'd0})
	                                     : cs_st_addr;
	wire [15:0] eng_wdata = cs_st_wdata;

	wire        host_wr   = apf_wr || sc_host_wr;
	wire [24:0] host_addr = sc_host_wr ? sc_host_addr : apf_addr;
	wire [15:0] host_data = sc_host_wr ? sc_host_data : apf_data;
	wire        host_bank = sc_host_wr ? ~stage_bank : stage_bank;

	// ---- staging PSRAM model -------------------------------------------------
	// One memory, two banks of 32K words. Each access (engine or host) holds
	// it for PS_LAT clocks. A pending engine request is served before the
	// skid (the M1 contract: a request issued the cycle after eng_ready was
	// high is never dropped); eng_ready also requires the skid empty.
	reg [15:0] psram [0:2*BANKW-1];
	reg [15:0] skid_w [0:SKID_DEPTH-1];
	reg [15:0] skid_d [0:SKID_DEPTH-1];
	reg  [7:0] skid_wp = 0, skid_rp = 0;
	wire [7:0] skid_fill  = skid_wp - skid_rp;
	wire       skid_empty = (skid_fill == 8'd0);
	wire       skid_full  = (skid_fill == SKID_DEPTH);
	assign     host_ready = (skid_fill < SKID_DEPTH - 3);
	reg  [3:0] ps_cnt = 0;
	reg        ps_eng = 0;
	wire       ps_idle = (ps_cnt == 4'd0);
	assign     eng_ready = ps_idle && skid_empty && (eng_req !== 1'b1);

	reg eng_drop = 0, eng_oob = 0, skid_overrun = 0, host_clash = 0, p2_oob = 0;

	always @(posedge clk) begin
		eng_done <= 1'b0;
		if (ps_cnt != 4'd0) ps_cnt <= ps_cnt - 4'd1;
		if (ps_cnt == 4'd1 && ps_eng) eng_done <= 1'b1;
		if (reset) begin
			skid_rp <= 8'd0;
			ps_cnt  <= 4'd0;
			ps_eng  <= 1'b0;
		end else if (eng_req === 1'b1) begin
			if (!ps_idle) eng_drop <= 1'b1;
			if (eng_addr[24:17] != 8'd0) eng_oob <= 1'b1;
			if (eng_we) psram[eng_addr[16:1]] <= eng_wdata;
			else        eng_rdata <= psram[eng_addr[16:1]];
			ps_cnt <= PS_LAT;
			ps_eng <= 1'b1;
		end else if (ps_idle && !skid_empty) begin
			psram[skid_w[skid_rp[4:0]]] <= skid_d[skid_rp[4:0]];
			skid_rp <= skid_rp + 8'd1;
			ps_cnt  <= PS_LAT;
			ps_eng  <= 1'b0;
		end
	end

	// host writes: skid entry (bank chosen per writer at entry, as
	// stage_mem does), host_busy tail, ingestion counters
	reg [15:0] host_idle = HOST_IDLE;
	assign host_busy = (host_idle != HOST_IDLE);
	always @(posedge clk) begin
		if (reset) begin
			skid_wp    <= 8'd0;
			diag_beats <= 16'd0;
			diag_drops <= 16'd0;
			host_idle  <= HOST_IDLE;
		end else begin
			if (host_wr === 1'b1) begin
				host_idle  <= 16'd0;
				diag_beats <= diag_beats + 16'd1;
				if (skid_full) begin
					diag_drops   <= diag_drops + 16'd1;
					skid_overrun <= 1'b1;
				end else if (host_addr[24:16] == 9'd0) begin
					skid_w[skid_wp[4:0]] <= {host_bank, host_addr[15:1]};
					skid_d[skid_wp[4:0]] <= host_data;
					skid_wp <= skid_wp + 8'd1;
				end
			end else if (host_idle != HOST_IDLE) begin
				host_idle <= host_idle + 16'd1;
			end
			if (apf_wr === 1'b1 && sc_host_wr === 1'b1) host_clash <= 1'b1;
		end
	end

	// The copier samples host_ready and writes the cycle after: a drain
	// write whose sampled ready was low ignored the backpressure. The
	// PSRAM takes a beat every 4 clk and the copier offers 2 per 7, so the
	// skid does fill during every drain; GLOBAL asserts that it did.
	reg     hr_q = 1'b1, wr_not_ready = 1'b0;
	integer n_hr_falls = 0;
	always @(posedge clk) begin
		if (sc_host_wr === 1'b1 && hr_q !== 1'b1) wr_not_ready <= 1'b1;
		if (sc_draining === 1'b1 && hr_q === 1'b1 && host_ready !== 1'b1) n_hr_falls = n_hr_falls + 1;
		hr_q <= host_ready;
	end

	// ---- cartridge SDRAM (die0, 512 KB) ------------------------------------
	reg [15:0] sdram [0:FLASHW-1];
	reg [15:0] gold  [0:FLASHW-1];      // what flash must hold
	always @(posedge clk) begin
		p2_done <= 1'b0;
		if (p2_req === 1'b1) begin
			if (p2_addr[24:19] != 6'd0) p2_oob <= 1'b1;
			if (p2_we) sdram[p2_addr[18:1]] <= p2_wdata;
			else       p2_rdata <= sdram[p2_addr[18:1]];
			p2_pend <= 1'b1;
		end else if (p2_pend) begin
			p2_pend <= 1'b0;
			p2_done <= 1'b1;
		end
	end

	// ---- bridge cart section -----------------------------------------------
	reg [31:0] section [0:CARTW-1];
	reg [31:0] rd_p1, rd_p2;
	always @(posedge clk) begin
		rd_p1            <= section[cart_img_rd_addr];
		rd_p2            <= rd_p1;
		cart_img_rd_data <= rd_p2;
		if (cart_img_wr === 1'b1) section[cart_img_addr] <= cart_img_data;
	end

	// ---- the two real modules ----------------------------------------------
	ngpc_cart_save #(
		.QUIET_CLOCKS (20'd200)
	) cs (
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
		.host_busy_i     (host_busy || sc_draining),
		.state_apply_i   (state_apply),
		.draining_i      (sc_draining),
		.save_slot_wr_i  (apf_wr),
		.apply_reject_o  (apply_reject),
		.state_done_o    (state_done),
		.slots_settled_i (slots_settled),
		.diag_beats_i    (diag_beats),
		.diag_drops_i    (diag_drops),
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
		.stage_req_o     (cs_st_req),
		.stage_we_o      (cs_st_we),
		.stage_addr_o    (cs_st_addr),
		.stage_wdata_o   (cs_st_wdata),
		.stage_ready_i   (eng_ready),
		.stage_done_i    (eng_done),
		.stage_rdata_i   (eng_rdata)
	);

	ngpc_state_cart #(
		.DR_WAIT_TIMEOUT (DRW_TO)
	) sc (
		.clk             (clk),
		.reset           (reset),
		.cart_save_req   (cart_save_req),
		.cart_save_done  (cart_save_done),
		.cart_img_wr     (cart_img_wr),
		.cart_img_addr   (cart_img_addr),
		.cart_img_data   (cart_img_data),
		.cart_load_req   (cart_load_req),
		.cart_load_done  (cart_load_done),
		.cart_load_error (cart_load_error),
		.cart_img_rd_addr(cart_img_rd_addr),
		.cart_img_rd_data(cart_img_rd_data),
		.sc_rd_req       (sc_rd_req),
		.sc_rd_addr      (sc_rd_addr),
		.sc_rd_ready     (eng_ready),
		.sc_rd_done      (eng_done),
		.sc_rd_data      (eng_rdata),
		.sc_rd_active    (sc_rd_active),
		.draining_o      (sc_draining),
		.sc_host_ready   (host_ready),
		.sc_host_wr      (sc_host_wr),
		.sc_host_addr    (sc_host_addr),
		.sc_host_data    (sc_host_data),
		.stage_current_i (stage_current),
		.apply_reject_i  (apply_reject),
		.state_apply_o   (state_apply),
		.state_done_i    (state_done),
		.diag_drain_o    (diag_drain),
		.hold_o          (hold)
	);

	// ---- monitors ------------------------------------------------------------
	integer cyc = 0;
	integer n_apply = 0, n_sdone = 0, n_ldone = 0, n_p2wr = 0, n_drain = 0;
	integer n_flips = 0, n_capwr = 0;
	reg     bank_q = 1'b0;
	reg     wr_outside_drain = 0, hold_gap = 0, busy_seen = 0, drain_seen = 0;
	// load window (armed by the bench at the request)
	reg     lw_arm = 0, lw_first = 0, lw_bank_first = 0, lw_busy_first = 0;
	reg     lw_apply_seen = 0, lw_p2_before_apply = 0;
	integer lw_arm_cyc = 0, lw_first_cyc = 0, lw_flips_first = 0;

	always @(posedge clk) begin
		cyc = cyc + 1;
		if (state_apply === 1'b1)    n_apply = n_apply + 1;
		if (state_done === 1'b1)     n_sdone = n_sdone + 1;
		if (cart_load_done === 1'b1) n_ldone = n_ldone + 1;
		if (p2_req === 1'b1 && p2_we === 1'b1) n_p2wr = n_p2wr + 1;
		if (cart_img_wr === 1'b1)    n_capwr = n_capwr + 1;
		if (sc_host_wr === 1'b1) begin
			n_drain = n_drain + 1;
			if (sc_draining !== 1'b1) wr_outside_drain = 1;
		end
		if (sc_draining === 1'b1) drain_seen = 1;
		if ((stage_bank ^ bank_q) === 1'b1) n_flips = n_flips + 1;
		bank_q = stage_bank;
		if (busy === 1'b1) busy_seen = 1;
		if (sc_rd_req === 1'b1 && hold !== 1'b1) hold_gap = 1;
		if (lw_arm) begin
			if (sc_host_wr === 1'b1 && !lw_first) begin
				lw_first       = 1;
				lw_first_cyc   = cyc;
				lw_flips_first = n_flips;
				lw_bank_first  = stage_bank;
				lw_busy_first  = busy;
			end
			if (state_apply === 1'b1) lw_apply_seen = 1;
			if (p2_req === 1'b1 && p2_we === 1'b1 && !lw_apply_seen) lw_p2_before_apply = 1;
		end
	end

	// ---- helpers -------------------------------------------------------------
	integer errors = 0;
	integer e0;
	task fail(input string msg);
		begin
			$display("   FAIL: %s", msg);
			errors = errors + 1;
		end
	endtask

	task verdict(input string what);
		begin
			if (errors == e0) $display("   PASS (%s)", what);
		end
	endtask

	function [15:0] rom(input integer i);
		rom = i[15:0] ^ 16'hBEEF;
	endfunction

	// size code 1 (4 Mbit): blocks 8/9 are 8 KB at 0x78000/0x7A000,
	// block 10 is 16 KB at 0x7C000 -- where real NGP saves live
	function integer bw(input integer blk);
		case (blk)
			8:       bw = 32'h3C000;
			9:       bw = 32'h3D000;
			10:      bw = 32'h3E000;
			default: bw = 0;
		endcase
	endfunction
	function integer bn(input integer blk);
		case (blk)
			8:       bn = 4096;
			9:       bn = 4096;
			10:      bn = 8192;
			default: bn = 0;
		endcase
	endfunction

	// erase a block, then write a short record at its start (a real save)
	task blk_fill(input integer blk, input [15:0] tag, input integer nlit);
		integer i, b;
		begin
			b = bw(blk);
			for (i = 0; i < bn(blk); i = i + 1) begin
				sdram[b + i] = (i < nlit) ? (tag + i[15:0]) : 16'hFFFF;
				gold[b + i]  = sdram[b + i];
			end
		end
	endtask

	task word_set(input integer blk, input integer idx, input [15:0] v);
		begin
			sdram[bw(blk) + idx] = v;
			gold[bw(blk) + idx]  = v;
		end
	endtask

	task flash_write(input [5:0] blk);
		begin
			@(posedge clk); die_busy <= 2'b01;
			@(posedge clk); block0 <= blk; event0 <= 1;
			@(posedge clk); event0 <= 0;
			repeat (4) @(posedge clk); die_busy <= 2'b00;
		end
	endtask

	// the die never goes idle again: the pass stays owed
	task flash_write_stuck(input [5:0] blk);
		begin
			@(posedge clk); die_busy <= 2'b01;
			@(posedge clk); block0 <= blk; event0 <= 1;
			@(posedge clk); event0 <= 0;
		end
	endtask

	function integer sdram_diff(input integer dummy);
		integer i, n;
		begin
			n = 0;
			for (i = 0; i < FLASHW; i = i + 1) if (sdram[i] !== gold[i]) n = n + 1;
			sdram_diff = n;
		end
	endfunction

	// flash as stateA left it, for blocks 8 and 10 (stateA's bitmap)
	reg [15:0] goldA [0:16383];          // words 0x3C000..0x3FFFF at capture
	task gold_restore_A;
		integer j;
		begin
			for (j = 0; j < 4096; j = j + 1)      gold[32'h3C000 + j] = goldA[j];
			for (j = 8192; j < 16384; j = j + 1)  gold[32'h3C000 + j] = goldA[j];
		end
	endtask

	// 16-bit word k of the image held in the bridge section
	function [15:0] secw(input integer k);
		reg [31:0] v;
		begin
			v = section[k >> 1];
			secw = k[0] ? v[31:16] : v[15:0];
		end
	endfunction

	function integer bank_vs_section(input integer b);
		integer k, n;
		begin
			n = 0;
			for (k = 0; k < SLOTW; k = k + 1)
				if (psram[b * BANKW + k] !== secw(k)) n = n + 1;
			bank_vs_section = n;
		end
	endfunction

	reg [15:0] keep [0:2*BANKW-1];
	task snap_psram;
		integer k;
		begin
			for (k = 0; k < 2*BANKW; k = k + 1) keep[k] = psram[k];
		end
	endtask
	function integer bank_vs_keep(input integer b);
		integer k, n;
		begin
			n = 0;
			for (k = 0; k < BANKW; k = k + 1)
				if (psram[b * BANKW + k] !== keep[b * BANKW + k]) n = n + 1;
			bank_vs_keep = n;
		end
	endfunction

	function [15:0] hdr(input integer w);     // committed-bank header word
		hdr = psram[(stage_bank ? BANKW : 0) + w];
	endfunction

	// Decode the V4 image in the section against gold: every block the
	// image's bitmap lists must decode to what flash holds. Returns the
	// number of mismatches (format trouble counts as mismatches).
	function integer decode_section_vs_gold(input integer dummy);
		integer pk, b, w, n, k, bad, base, cnt;
		reg [63:0] bmp;
		reg [15:0] word;
		begin
			bad = 0;
			bmp = {secw(11), secw(10), secw(9), secw(8)};
			if ({secw(15), secw(14), secw(13), secw(12)} !== 64'd0) bad = bad + 1;
			pk = 256;
			for (b = 0; b < 64; b = b + 1) if (bmp[b]) begin
				base = bw(b); n = bn(b);
				if (n == 0) bad = bad + 1;
				w = 0;
				while (w < n && pk < SLOTW) begin
					word = secw(pk); pk = pk + 1;
					if (word !== 16'hFFFF) begin
						if (gold[base + w] !== word) bad = bad + 1;
						w = w + 1;
					end else begin
						cnt = secw(pk); pk = pk + 1;
						if (cnt == 0) cnt = 1;
						for (k = 0; k < cnt && w < n; k = k + 1) begin
							if (gold[base + w] !== 16'hFFFF) bad = bad + 1;
							w = w + 1;
						end
					end
				end
				if (w < n) bad = bad + 1;
			end
			decode_section_vs_gold = bad;
		end
	endfunction

	// the engine idle with the machine released, for 64 clocks running
	task wait_idle(input integer max);
		integer n, q;
		begin
			n = 0; q = 0;
			while (q < 64 && n < max) begin
				@(posedge clk); n = n + 1;
				if (busy === 1'b0 && boot_hold === 1'b0) q = q + 1; else q = 0;
			end
			if (q < 64) fail("engine never went idle");
		end
	endtask

	reg flip_ok;
	task wait_flip(input integer f0, input integer max);
		integer n;
		begin
			n = 0;
			while (n_flips <= f0 && n < max) begin @(posedge clk); n = n + 1; end
			flip_ok = (n_flips > f0);
			repeat (8) @(posedge clk);
		end
	endtask

	reg     cap_ok;
	integer cap_cycles;
	task do_capture(input integer max);
		begin
			cap_ok = 0; cap_cycles = 0;
			@(posedge clk); cart_save_req <= 1;
			@(posedge clk); cart_save_req <= 0;
			while (!cap_ok && cap_cycles < max) begin
				@(posedge clk); cap_cycles = cap_cycles + 1;
				if (cart_save_done === 1'b1) cap_ok = 1;
			end
			repeat (3) @(posedge clk);       // the last section write lands
		end
	endtask

	task arm_window;
		begin
			lw_first = 0; lw_apply_seen = 0; lw_p2_before_apply = 0;
			lw_arm_cyc = cyc; lw_arm = 1;
		end
	endtask

	reg     ld_done, ld_err;
	integer ld_cycles;
	task do_load(input integer max);
		begin
			ld_done = 0; ld_err = 0; ld_cycles = 0;
			arm_window;
			@(posedge clk); cart_load_req <= 1;
			@(posedge clk); cart_load_req <= 0;
			while (!ld_done && ld_cycles < max) begin
				@(posedge clk); ld_cycles = ld_cycles + 1;
				if (cart_load_done === 1'b1) begin
					ld_done = 1;
					ld_err  = cart_load_error;
				end
			end
			lw_arm = 0;
		end
	endtask

	// Power-up of the core (sleep wake / relaunch): everything resets, PSRAM
	// keeps its contents, the cartridge is downloaded again (SDRAM = ROM).
	// S2: the committed bank survives both reset and cart_replace -- checked
	// at every power-up (CH1 makes sure one of them has the bank at 1).
	reg bank_before_reset;
	task power_up;
		integer i;
		begin
			bank_before_reset = stage_bank;
			@(posedge clk);
			reset <= 1; cart_ready <= 0; slots_settled <= 0; die_busy <= 2'b00;
			repeat (10) @(posedge clk);
			reset <= 0;
			for (i = 0; i < FLASHW; i = i + 1) begin sdram[i] = rom(i); gold[i] = rom(i); end
			@(posedge clk); cart_replace <= 1;
			@(posedge clk); cart_replace <= 0;
			repeat (4) @(posedge clk); cart_ready <= 1;
			repeat (4) @(posedge clk);
			if (stage_bank !== bank_before_reset) fail("S2: stage_bank changed by reset / cart_replace");
		end
	endtask

	reg [15:0] imgB [0:SLOTW-1];
	task apf_deliver_B;
		integer k;
		begin
			for (k = 0; k < SLOTW; k = k + 1) begin
				@(posedge clk); apf_wr <= 1'b1; apf_addr <= k * 2; apf_data <= imgB[k];
				@(posedge clk); apf_wr <= 1'b0;
				repeat (4) @(posedge clk);
			end
			repeat (8) @(posedge clk);
		end
	endtask

	reg [31:0] stateA [0:CARTW-1];
	task section_from_stateA;
		integer i;
		begin
			for (i = 0; i < CARTW; i = i + 1) section[i] = stateA[i];
		end
	endtask
	task section_cartless;
		integer i;
		begin
			for (i = 0; i < CARTW; i = i + 1) section[i] = 32'hDEAD0000 ^ (i * 32'h00010003);
		end
	endtask

	integer i, f0, p0, a0, s0, d0, n0, bank0;
	reg     sp0;
	reg [63:0] dirty_q;

	initial begin
		for (i = 0; i < FLASHW; i = i + 1) begin sdram[i] = rom(i); gold[i] = rom(i); end
		for (i = 0; i < 2*BANKW; i = i + 1) psram[i] = 16'hDEAD;
		for (i = 0; i < CARTW; i = i + 1) section[i] = 32'h0;

		// ==== session 1: a cartridge with no save file ========================
		repeat (10) @(posedge clk);
		reset <= 0;
		@(posedge clk); cart_replace <= 1;
		@(posedge clk); cart_replace <= 0;
		repeat (4) @(posedge clk); cart_ready <= 1;
		repeat (4) @(posedge clk); slots_settled <= 1;
		s0 = n_sdone;
		wait_idle(200000);
		$display("== B0 boot, nothing delivered");
		e0 = errors;
		if (^{stage_bank, stage_current, apply_reject, state_done, sc_draining,
		      save_present, diag_drain} === 1'bx)
			fail("X on an engine/copier output after boot");
		if (n_sdone != s0) fail("state_done pulsed for a boot apply");
		if (sdram_diff(0) != 0) fail("flash written by a boot apply with nothing delivered");
		verdict("released, flash untouched, no state_done");

		// ---- CAP1 ----------------------------------------------------------
		$display("== CAP1 capture after a publish, and with a pass owed");
		e0 = errors;
		blk_fill(8,  16'hA800, 32);
		blk_fill(10, 16'hAA00, 16);
		f0 = n_flips;
		flash_write(8);
		flash_write(10);
		wait_flip(f0, 400000);
		if (!flip_ok) fail("the first save never published");
		// (a) capture after the publish
		n0 = n_capwr;
		do_capture(600000);
		if (!cap_ok) fail("(a) capture never finished");
		if (n_capwr - n0 != CARTW) begin
			$display("   FAIL: (a) %0d section writes for %0d words", n_capwr - n0, CARTW);
			errors = errors + 1;
		end
		if (bank_vs_section(stage_bank) != 0) begin
			$display("   FAIL: (a) %0d words differ from the committed bank", bank_vs_section(stage_bank));
			errors = errors + 1;
		end
		if (secw(0) !== 16'h4E47 || secw(1) !== 16'h5043 || secw(2) !== 16'h5341 || secw(3) !== 16'h5634)
			fail("(a) captured magic/tag wrong");
		if (secw(8) !== 16'h0500) fail("(a) captured bitmap is not blocks 8+10");
		if (decode_section_vs_gold(0) != 0) fail("(a) captured image does not decode to flash");
`ifdef NGPC_SAVE_DIAG
		// S10: the boot apply with nothing delivered left the walk at word
		// 0, and its verdict is recorded all the same (1.0.2/rc3 said 0)
		if (secw(16) !== 16'd0) fail("(a) word 16 nonzero with no host beat since reset");
		if (secw(22) !== 16'd1) begin
			$display("   FAIL: (a) word 22 = %0d applies since reset, want 1", secw(22));
			errors = errors + 1;
		end
		if (secw(23) !== 16'h0005) begin
			$display("   FAIL: (a) word 23 = %h, want 0005 (boot, nothing delivered)", secw(23));
			errors = errors + 1;
		end
		if (secw(24) !== 16'd0) fail("(a) word 24: p2 writes counted for an apply that wrote none");
`endif
		// (b) a capture requested with a pass owed waits for it
		word_set(8, 32, 16'hA820);
		flash_write(8);
		f0 = n_flips;
		do_capture(600000);
		if (!cap_ok) fail("(b) capture never finished");
		if (n_flips != f0 + 1) fail("(b) the owed pass did not publish before the capture read");
		if (bank_vs_section(stage_bank) != 0) fail("(b) section differs from the committed bank");
		if (decode_section_vs_gold(0) != 0) fail("(b) captured image does not hold the owed write");
`ifdef NGPC_SAVE_DIAG
		if (secw(18) !== 16'd0) fail("(b) header word 18 nonzero with no drain since reset");
`endif
		if (hold_gap) fail("staging read by the copier without hold_o");
		if (drain_seen) fail("draining_o raised by a capture");
		for (i = 0; i < CARTW; i = i + 1) stateA[i] = section[i];
		for (i = 0; i < 16384; i = i + 1) goldA[i] = gold[32'h3C000 + i];
		verdict("committed bank byte-exact both times; owed pass published first");

		// ---- DL1 -----------------------------------------------------------
		$display("== DL1 deadlock regression: flash written just before the load");
		e0 = errors;
		section_from_stateA;
		word_set(8, 100, 16'h1111);          // inside stateA's bitmap
		flash_write(8);                      // a pass is now owed
		f0 = n_flips; p0 = n_p2wr; a0 = n_apply; s0 = n_sdone; d0 = n_drain;
		do_load(LOAD_MAX);
		if (!ld_done) fail("load never completed (the deadlock)");
		else if (ld_err) fail("load reported an error");
		if (!lw_first) fail("no drain write seen");
		else begin
			if (lw_flips_first != f0 + 1) fail("the owed pass did not publish before the drain started");
			if (lw_busy_first !== 1'b0) fail("drain started while the engine was busy");
			if (lw_first_cyc - lw_arm_cyc > DRW_TO / 2)
				$display("   note: I_DR_WAIT lasted %0d clk (timeout %0d)", lw_first_cyc - lw_arm_cyc, DRW_TO);
		end
		if (n_drain - d0 != SLOTW) begin
			$display("   FAIL: %0d drain writes, want %0d", n_drain - d0, SLOTW);
			errors = errors + 1;
		end
		if (n_apply - a0 != 1) fail("not exactly one state_apply pulse");
		if (n_sdone - s0 != 1) fail("not exactly one state_done pulse");
		if (lw_p2_before_apply) fail("flash written before the state apply was requested");
		gold_restore_A;
		if (sdram_diff(0) != 0) begin
			$display("   FAIL: %0d flash words not rewound to the state", sdram_diff(0));
			errors = errors + 1;
		end
		if (cs.dirty0 !== 64'h500) begin
			$display("   FAIL: dirty0 = %h, want the image bitmap 0500", cs.dirty0);
			errors = errors + 1;
		end
		if (lw_first && stage_bank !== ~lw_bank_first) fail("committed bank is not the bank the state was drained into");
		if (bank_vs_section(stage_bank) != 0) fail("committed bank does not hold the state image");
		if (!save_present) fail("save_present low after an accepted state with data");
		verdict("owed pass published, drain, state applied, bank committed");

		// ---- DL2 -----------------------------------------------------------
		$display("== DL2 deadlock regression: pass running at the load request");
		e0 = errors;
		word_set(10, 200, 16'h2222);
		flash_write(10);
		i = 0;
		while (!(busy === 1'b1 && boot_hold === 1'b0) && i < 5000) begin @(posedge clk); i = i + 1; end
		if (busy !== 1'b1) fail("the pass never started");
		repeat (2000) @(posedge clk);        // well into the walk
		if (busy !== 1'b1) fail("the pass ended before the load request (bench timing)");
		f0 = n_flips; p0 = n_p2wr; a0 = n_apply; s0 = n_sdone; d0 = n_drain;
		do_load(LOAD_MAX);
		if (!ld_done) fail("load never completed");
		else if (ld_err) fail("load reported an error");
		if (!lw_first) fail("no drain write seen");
		else begin
			if (lw_flips_first != f0 + 1) fail("the running pass did not publish before the drain");
			if (lw_busy_first !== 1'b0) fail("drain started while the engine was busy");
		end
		if (n_apply - a0 != 1 || n_sdone - s0 != 1) fail("not exactly one state_apply / state_done");
		if (lw_p2_before_apply) fail("flash written before the state apply was requested");
		gold_restore_A;
		if (sdram_diff(0) != 0) fail("flash not rewound to the state");
		if (cs.dirty0 !== 64'h500) fail("dirty0 is not the image bitmap");
		if (bank_vs_section(stage_bank) != 0) fail("committed bank does not hold the state image");
		verdict("running pass finished and published, then drain and apply");

		// the session saves more: block 9 and a change in block 8. This
		// image is the file APF will deliver at the next launch.
		blk_fill(9, 16'hB900, 8);
		word_set(8, 50, 16'hB850);
		f0 = n_flips;
		flash_write(9);
		flash_write(8);
		wait_flip(f0, 400000);
		if (!flip_ok) fail("(setup) image B never published");
		if (hdr(8) !== 16'h0700) fail("(setup) image B bitmap is not 8+9+10");
		for (i = 0; i < SLOTW; i = i + 1) imgB[i] = psram[(stage_bank ? BANKW : 0) + i];

		// ==== session 2: wake -- file delivered, state loaded before settle ===
		$display("== CH1 chained applies: slots settle during the drain");
		e0 = errors;
		// Seven flips so far (CAP1 x2, DL1 and DL2 a publish and a commit
		// each, image B), so the bank is 1 here and power_up's S2 check
		// can see a reset that zeroes it.
		if (stage_bank !== 1'b1)
			fail("(setup) committed bank is not 1 before the relaunch: the S2 check below would be blind");
		power_up;
		apf_deliver_B;
		begin : chk_delivery
			integer k, n;
			n = 0;
			for (k = 0; k < SLOTW; k = k + 1)
				if (psram[(stage_bank ? BANKW : 0) + k] !== imgB[k]) n = n + 1;
			if (n) fail("(setup) the delivery did not land in the committed bank");
		end
		if (boot_hold !== 1'b1) fail("(setup) boot apply not holding before the settle");
		section_from_stateA;
		p0 = n_p2wr; a0 = n_apply; s0 = n_sdone; d0 = n_drain;
		fork
			do_load(LOAD_MAX);
			begin : settle_mid_drain
				integer n;
				n = 0;
				while (n_drain < d0 + 4000 && n < LOAD_MAX) begin @(posedge clk); n = n + 1; end
				if (sc_draining !== 1'b1) fail("(setup) not draining when the slots settled");
				slots_settled <= 1'b1;
			end
		join
		if (!ld_done) fail("load never completed");
		else if (ld_err) fail("load reported an error");
		if (lw_p2_before_apply) fail("flash written before the state pulse: a boot apply ran under draining_i");
		if (n_apply - a0 != 1) fail("not exactly one state_apply pulse");
		if (n_sdone - s0 != 1) fail("not exactly one state_done pulse");
		p0 = n_p2wr - p0;
		gold_restore_A;
		if (sdram_diff(0) != 0) begin
			$display("   FAIL: %0d flash words differ (block 9 from the delivered file must NOT be applied)", sdram_diff(0));
			errors = errors + 1;
		end
		// exactly one write pass over the state's two blocks: more is a
		// second apply (the delivered file's, or the state's twice)
		if (p0 != bn(8) + bn(10)) begin
			$display("   FAIL: %0d flash writes, want exactly the state's %0d words",
			         p0, bn(8) + bn(10));
			errors = errors + 1;
		end
		// nothing runs after the copier said done
		n0 = n_p2wr;
		wait_idle(400000);
		repeat (2000) @(posedge clk);
		if (n_p2wr != n0) fail("flash written after cart_load_done: done came before the (last) apply");
		if (n_sdone - s0 != 1) fail("a further state_done after the load");
		if (cs.dirty0 !== 64'h500) fail("dirty0 is not the state's bitmap");
		if (lw_first && stage_bank !== ~lw_bank_first) fail("committed bank is not the drained (spare) bank");
		if (bank_vs_section(stage_bank) != 0) fail("committed bank does not hold the state image");
		if (!save_present) fail("save_present low");
		verdict("one state apply from the spare bank served both; done after it");

		// ---- CAP2 ----------------------------------------------------------
		$display("== CAP2 capture after a state commit; diagnostics in the header");
		e0 = errors;
		word_set(8, 60, 16'hC860);
		f0 = n_flips;
		flash_write(8);
		wait_flip(f0, 400000);
		if (!flip_ok) fail("no publish after the state commit");
		do_capture(600000);
		if (!cap_ok) fail("capture never finished");
		if (bank_vs_section(stage_bank) != 0) fail("section differs from the committed bank");
		if (decode_section_vs_gold(0) != 0) fail("captured image does not decode to flash");
`ifdef NGPC_SAVE_DIAG
		if (secw(18) !== 16'd32512) begin
			$display("   FAIL: word 18 = %0d, want 32512 drain beats", secw(18));
			errors = errors + 1;
		end
		if (secw(16) - secw(18) !== 16'd32512) begin
			$display("   FAIL: word 16 - word 18 = %0d, want 32512 delivery beats", secw(16) - secw(18));
			errors = errors + 1;
		end
		if (secw(22) !== 16'd1) begin
			$display("   FAIL: word 22 = %0d applies since reset, want 1", secw(22));
			errors = errors + 1;
		end
		if (secw(23) !== 16'h8001) begin
			$display("   FAIL: word 23 = %h, want 8001 (state, accepted)", secw(23));
			errors = errors + 1;
		end
		if (secw(24) !== 16'd12288) begin
			$display("   FAIL: word 24 = %0d p2 writes in the last apply, want 12288", secw(24));
			errors = errors + 1;
		end
`endif
		verdict("new committed bank embedded; words 16/18/22/23/24 as specified");

		// ---- RJ1 -----------------------------------------------------------
		// The delivered file B, taken as a state with one payload word
		// damaged. Its bitmap (8+9+10) covers dirty (8+10), its header is
		// good, so only the payload CRC can refuse it. The session has a
		// base (CH1 was accepted) and dirty is not empty: no freeze.
		$display("== RJ1 damaged state mid-session: refused, dirty and bank kept, not frozen");
		e0 = errors;
		if (imgB[256] === 16'hFFFF || imgB[256] === 16'hFFFE)
			fail("(setup) image B's payload does not open with a literal");
		for (i = 0; i < CARTW; i = i + 1) section[i] = {imgB[2*i+1], imgB[2*i]};
		section[128] = section[128] ^ 32'h0000_0001;   // payload word 0 (a literal stays one)
		dirty_q = cs.dirty0;
		// dirty must be a strict subset of the image's bitmap, or "dirty
		// unchanged" could not tell a refusal from an acceptance
		if (dirty_q !== 64'h500 || imgB[8] !== 16'h0700)
			fail("(setup) dirty is not 0500 under an 0700 image");
		sp0 = save_present;
		bank0 = stage_bank;
		snap_psram;
		p0 = n_p2wr; a0 = n_apply; s0 = n_sdone;
		do_load(LOAD_MAX);
		if (!ld_done) fail("load never completed");
		else if (ld_err !== 1'b1) fail("damaged state loaded without error");
		if (n_apply - a0 != 1 || n_sdone - s0 != 1) fail("not exactly one state_apply / state_done");
		if (n_p2wr != p0 || sdram_diff(0) != 0) fail("flash written by a refused state");
		if (stage_bank !== bank0) fail("bank changed by a refused state");
		if (bank_vs_keep(bank0) != 0) fail("committed bank changed");
		if (cs.dirty0 !== dirty_q) begin
			$display("   FAIL: dirty0 = %h after the refusal, want it unchanged (%h)", cs.dirty0, dirty_q);
			errors = errors + 1;
		end
		if (save_present !== sp0) fail("save_present changed by a refused state");
		word_set(8, 61, 16'hC861);
		f0 = n_flips;
		flash_write(8);
		wait_flip(f0, 400000);
		if (!flip_ok) fail("frozen after a refused state with a base (a write did not publish)");
		else begin
			if (hdr(8) !== 16'h0500) begin
				$display("   FAIL: published bitmap = %h, want 0500 (dirty as before the refusal)", hdr(8));
				errors = errors + 1;
			end
`ifdef NGPC_SAVE_DIAG
			if (hdr(18) !== 16'd65024) begin
				$display("   FAIL: word 18 = %0d, want 65024 (two drains)", hdr(18));
				errors = errors + 1;
			end
			if (hdr(16) - hdr(18) !== 16'd32512) fail("word 16 - word 18 is not the one delivery");
			if (hdr(22) !== 16'd2) begin
				$display("   FAIL: word 22 = %0d, want 2", hdr(22));
				errors = errors + 1;
			end
			if (hdr(23) !== 16'h8003) begin
				$display("   FAIL: word 23 = %h, want 8003 (state, payload CRC)", hdr(23));
				errors = errors + 1;
			end
			if (hdr(24) !== 16'd0) fail("word 24: p2 writes counted for a refused apply");
`endif
		end
		verdict("CRC-refused, nothing written, dirty kept, session still saves");

		// ==== session 3: wake, no delivery, a state with a bad tag ===========
		$display("== FZ1 bad-tag state at wake: error, flash untouched, frozen");
		e0 = errors;
		power_up;
		slots_settled <= 1'b1;
		s0 = n_sdone;
		wait_idle(400000);
		if (n_sdone != s0) fail("state_done pulsed for a boot apply");
		if (sdram_diff(0) != 0) fail("(setup) boot apply with nothing delivered wrote flash");
		bank0 = stage_bank;
		snap_psram;
		section_from_stateA;
		section[1] = {16'h5633, section[1][15:0]};   // header word 3: "V3"
		p0 = n_p2wr; a0 = n_apply; s0 = n_sdone;
		do_load(LOAD_MAX);
		if (!ld_done) fail("load never completed");
		else if (ld_err !== 1'b1) fail("bad-tag state loaded without error");
		if (n_sdone - s0 != 1) fail("not exactly one state_done pulse");
		if (n_p2wr != p0) fail("flash written by a refused state");
		if (sdram_diff(0) != 0) fail("flash changed");
		if (stage_bank !== bank0) fail("bank changed by a refused state");
		if (bank_vs_keep(bank0) != 0) fail("committed bank changed");
		if (save_present) fail("save_present high after the refusal");
		// frozen: a flash write starts no pass and publishes nothing
		wait_idle(400000);
		blk_fill(8, 16'hF800, 24);
		f0 = n_flips;
		busy_seen = 0;
		flash_write(8);
		repeat (200 + 150000) @(posedge clk);
		if (n_flips != f0) fail("a pass published while frozen");
		if (busy_seen) fail("a staging pass started while frozen");
		if (save_present) fail("save_present rose while frozen");
		if (stage_current !== 1'b1) fail("stage_current low while frozen and idle");
		if (bank_vs_keep(bank0) != 0) fail("committed bank changed while frozen");
		verdict("refused, nothing written, frozen");

		// ---- FZ2 -----------------------------------------------------------
		$display("== FZ2 capture while frozen does not wait on the owed pass");
		e0 = errors;
		do_capture(600000);
		if (!cap_ok) fail("capture hung while frozen");
		if (bank_vs_section(bank0) != 0) fail("capture did not embed the committed bank");
		if (bank_vs_keep(bank0) != 0) fail("committed bank changed");
		verdict("capture completed from the as-delivered bank");

		// ---- FZ3 -----------------------------------------------------------
		$display("== FZ3 a good state while frozen: flash restored, nothing committed");
		e0 = errors;
		section_from_stateA;                 // bitmap 8+10 covers dirty (8)
		snap_psram;
		a0 = n_apply; s0 = n_sdone;
		do_load(LOAD_MAX);
		if (!ld_done) fail("load never completed");
		else if (ld_err) fail("good state refused while frozen");
		if (!lw_first) fail("no drain");
		else if (lw_first_cyc - lw_arm_cyc > 200) begin
			$display("   FAIL: drain waited %0d clk on staging while frozen", lw_first_cyc - lw_arm_cyc);
			errors = errors + 1;
		end
		if (n_apply - a0 != 1 || n_sdone - s0 != 1) fail("not exactly one state_apply / state_done");
		gold_restore_A;
		if (sdram_diff(0) != 0) fail("flash not restored to the state");
		if (cs.dirty0 !== 64'h500) fail("dirty0 is not the image bitmap after an accepted state");
		if (stage_bank !== bank0) fail("a state committed a bank while frozen");
		if (bank_vs_keep(bank0) != 0) fail("committed bank changed");
		if (save_present) fail("save_present high while frozen");
		wait_idle(400000);
		word_set(8, 7, 16'hF807);
		f0 = n_flips;
		busy_seen = 0;
		flash_write(8);
		repeat (200 + 150000) @(posedge clk);
		if (n_flips != f0 || busy_seen) fail("no longer frozen after the state apply");
		verdict("applied to flash, committed bank and freeze kept");

		// ==== session 4: a state taken with no save in staging ===============
		$display("== NI1 cartless state, nothing dirty: success, nothing applied");
		e0 = errors;
		power_up;
		slots_settled <= 1'b1;
		wait_idle(400000);
		bank0 = stage_bank;
		snap_psram;
		section_cartless;
		p0 = n_p2wr; a0 = n_apply; s0 = n_sdone;
		do_load(LOAD_MAX);
		if (!ld_done) fail("load never completed");
		else if (ld_err) fail("cartless state with nothing dirty reported an error");
		if (n_apply - a0 != 1 || n_sdone - s0 != 1) fail("not exactly one state_apply / state_done");
		if (n_p2wr != p0 || sdram_diff(0) != 0) fail("flash written");
		if (stage_bank !== bank0) fail("bank changed");
		if (bank_vs_keep(bank0) != 0) fail("committed bank changed");
		if (cs.dirty0 !== 64'd0) fail("dirty0 changed");
		blk_fill(8, 16'hE800, 20);
		f0 = n_flips;
		flash_write(8);
		wait_flip(f0, 400000);
		if (!flip_ok) fail("frozen after a cartless state (a write did not publish)");
`ifdef NGPC_SAVE_DIAG
		else begin
			if (hdr(23) !== 16'h8006) begin
				$display("   FAIL: word 23 = %h, want 8006 (state, no image)", hdr(23));
				errors = errors + 1;
			end
			if (hdr(18) !== 16'd32512) fail("word 18 is not the one drain's beats");
		end
`endif
		verdict("no-op accepted; the session still saves");

		// ---- NI2 -----------------------------------------------------------
		$display("== NI2 cartless state with dirty blocks: rejected, not frozen");
		e0 = errors;
		wait_idle(400000);
		repeat (HOST_IDLE + 16) @(posedge clk);
		bank0 = stage_bank;
		snap_psram;
		section_cartless;
		dirty_q = cs.dirty0;
		sp0 = save_present;
		p0 = n_p2wr; s0 = n_sdone;
		do_load(LOAD_MAX);
		if (!ld_done) fail("load never completed");
		else if (ld_err !== 1'b1) fail("cartless state over dirty flash loaded without error");
		if (n_sdone - s0 != 1) fail("not exactly one state_done");
		if (n_p2wr != p0 || sdram_diff(0) != 0) fail("flash written");
		if (stage_bank !== bank0) fail("bank changed");
		if (bank_vs_keep(bank0) != 0) fail("committed bank changed");
		if (cs.dirty0 !== dirty_q) fail("dirty0 changed by a rejected state");
		if (save_present !== sp0) fail("save_present changed by a rejected state");
		word_set(8, 21, 16'hE821);
		f0 = n_flips;
		flash_write(8);
		wait_flip(f0, 400000);
		if (!flip_ok) fail("frozen after a rejected cartless state");
`ifdef NGPC_SAVE_DIAG
		else if (hdr(23) !== 16'h8006) begin
			$display("   FAIL: word 23 = %h, want 8006", hdr(23));
			errors = errors + 1;
		end
`endif
		verdict("rejected, nothing written, still saving");

		// ---- TO1 -----------------------------------------------------------
		$display("== TO1 I_DR_WAIT timeout: a pass owed forever");
		e0 = errors;
		wait_idle(400000);
		repeat (HOST_IDLE + 16) @(posedge clk);
		word_set(8, 70, 16'h7070);
		flash_write_stuck(8);                // die_busy never falls
		repeat (1000) @(posedge clk);
		if (stage_current !== 1'b0) fail("(setup) stage_current high with a pass owed");
		section_from_stateA;
		snap_psram;
		bank0 = stage_bank;
		drain_seen = 0;
		p0 = n_p2wr; a0 = n_apply; s0 = n_sdone; d0 = n_drain;
		do_load(DRW_TO + 20000);
		if (!ld_done) fail("no done after the timeout");
		else begin
			if (ld_err !== 1'b1) fail("timeout reported without error");
			if (ld_cycles < DRW_TO - 8 || ld_cycles > DRW_TO + 256) begin
				$display("   FAIL: done after %0d clk, want ~%0d", ld_cycles, DRW_TO);
				errors = errors + 1;
			end
		end
		if (drain_seen) fail("draining_o raised on the timeout path");
		if (n_drain != d0) fail("staging written on the timeout path");
		if (n_apply != a0 || n_sdone != s0) fail("an apply ran on the timeout path");
		if (n_p2wr != p0) fail("flash written on the timeout path");
		if (bank_vs_keep(0) != 0 || bank_vs_keep(1) != 0) fail("staging changed on the timeout path");
		if (stage_bank !== bank0) fail("bank changed");
		verdict("error after the timeout, nothing touched");

		// ---- TO2 -----------------------------------------------------------
		$display("== TO2 after a timeout the copier loads normally");
		e0 = errors;
		f0 = n_flips;
		@(posedge clk); die_busy <= 2'b00;
		wait_flip(f0, 400000);
		if (!flip_ok) fail("(setup) the owed pass never published");
		section_from_stateA;                 // bitmap 8+10 covers dirty (8)
		a0 = n_apply; s0 = n_sdone;
		do_load(LOAD_MAX);
		if (!ld_done) fail("load never completed");
		else if (ld_err) fail("load reported an error");
		if (n_apply - a0 != 1 || n_sdone - s0 != 1) fail("not exactly one state_apply / state_done");
		gold_restore_A;
		if (sdram_diff(0) != 0) fail("flash not restored to the state");
		if (bank_vs_section(stage_bank) != 0) fail("committed bank does not hold the state image");
		verdict("copier idle again after the timeout");

		// ---- global ----------------------------------------------------------
		$display("== GLOBAL monitors");
		e0 = errors;
		if (eng_drop)         fail("a staging-port request arrived while the port was busy");
		if (eng_oob)          fail("a staging-port address outside the two banks");
		if (skid_overrun)     fail("a host write into a full skid");
		if (host_clash)       fail("an APF write and a drain write in the same cycle");
		if (p2_oob)           fail("a p2 access outside die 0");
		if (wr_outside_drain) fail("a drain write while draining_o was low");
		if (hold_gap)         fail("a copier staging read without hold_o");
		if (wr_not_ready)     fail("a drain write whose sampled host_ready was low");
		if (n_hr_falls == 0)  fail("(bench) host_ready never fell under a drain: backpressure untested");
		if (n_sdone != n_apply) begin
			$display("   FAIL: %0d state_done pulses for %0d state_apply pulses", n_sdone, n_apply);
			errors = errors + 1;
		end
		verdict("no protocol violations");

		if (errors == 0) $display("== ALL RC4 LOAD-PATH SCENARIOS PASS");
		else             $display("== %0d FAILURE(S)", errors);
		$finish;
	end

	initial begin
		#600_000_000;
		$display("== WATCHDOG TIMEOUT");
		$display("== %0d FAILURE(S)", errors + 1);
		$finish;
	end

	wire unused = &{1'b0, p2_be, 1'b0};

endmodule

`default_nettype wire
