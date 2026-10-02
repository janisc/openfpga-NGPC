// tb_rc6b_port -- rc6 L3: APF's save-slot delivery and the savestate copier's
// drain on the ONE staging host write port.
//   Run through sim/run_rc6_hostport.sh (builds, mutants, matrix).
//   One scenario per run: +SCN=1..8. Last line: "== ALL RC6B-PORT SCENARIOS
//   PASS" or "== N FAILURE(S) ...". Run it with "vvp -N": a failing run then
//   exits with status 1 ($stop), a passing one with 0 ($finish).
//
// REAL, compiled unmodified from the worktree:
//   target/pocket/ngpc_stage_mem.sv   skid FIFO, pending slot, ready threshold
//                                     (rc6 L3 part B), diag counters
//   target/pocket/psram.sv            PSRAM controller at 49.152 MHz
//   target/pocket/data_loader.sv      APF slot loader (+ sim/sim_dcfifo.v)
//   target/pocket/ngpc_state_cart.sv  the copier (drain path)
//   the rc6 write-port arbiter        core_top.v "apf_save_wr .. sc_host_ready",
//                                     extracted VERBATIM by the run script into
//                                     sim/tb_rc6b_arb.vh and `included below
//                                     (rc6 L3 part A)
// MODELED: the CellularRAM chip at the pins (write side, as tb_stage_host),
// the blob image read port (data 2 clk after the address), the engine's
// state_done (a few clocks after state_apply), the APF bridge.
//
// SCENARIOS (+SCN=n), as sim/tb_r6d_l3.sv:
//   1  FORCED    bench-driven loader output (data_loader's protocol: one-cycle
//                strobe, >= 4 clk apart, addr/data held) aimed at the exact
//                cycle a drain beat is on the port: every 5th LO/HI issue,
//                plus the drain's very last beat.
//   2  DENSE     as 1, every issue the 4-cycle spacing allows.
//   3  SPACING2  as 2 with 2-cycle spacing -- beyond what data_loader can
//                produce (every copier beat collides).
//   4  REAL75    the real data_loader, a full 0xFE00 file at APF's measured
//                ~75 clk_74a per 32-bit word, started 200 us into the drain.
//   5  REALBURST the real data_loader, 128-word SD-chunk bursts at gap 4,
//                started 200 us into the drain (burst collisions).
//   6  NOOVERLAP delivery, then the drain (the order APF actually uses).
//   7  BURSTONLY scenario 5's delivery with no drain.
//   8  REPLAYHIT (added) as 2, and after each collision one or two more APF
//                beats 1 clk apart, so APF also takes the replay cycle(s) and
//                sc_replay must hold -- beyond data_loader (>= 4 clk), a
//                robustness case for the arbiter alone.
//
// CHECKS (every scenario):
//   K1 committed bank == every APF save beat delivered (by word)
//   K2 no stray word: committed words APF never sent, spare words past the
//      image, and everything outside the two banks still hold the fill
//   K3 spare bank == the whole drained image (all but 7); untouched (7)
//   K4 chip write strobes: committed-bank writes == APF beats and spare-bank
//      writes == drain beats (each beat written exactly once), and every chip
//      write carries its own writer's word for that address: no drain word
//      in the committed bank, no APF word in the spare bank
//   K5 no beat met a full skid; diag_drops == 0; diag_beats == APF beats +
//      drain beats (the counters need NGPC_SAVE_DIAG, as the release build
//      defines it; without it only the skid check runs)
//   K6 the drain finished without error (all but 7)
//   K7 coverage: the scenario produced what it is for (collisions in 1-5, 8,
//      an APF beat on a replay cycle in 8, APF queued past the copier's
//      threshold during the drain in 5, no collision in 6/7)

`timescale 1ns / 1ps
`default_nettype none

module tb_rc6b_port;

	reg clk_sys = 0;
	reg clk_74a = 0;
	always #10.173 clk_sys = ~clk_sys;   // 49.152 MHz
	always #6.734  clk_74a = ~clk_74a;   // 74.25 MHz

	integer cyc = 0;
	always @(posedge clk_sys) cyc = cyc + 1;

	reg reset_in = 1;
	reg mc_stage_bank = 1'b0;            // committed bank (stable during a drain)

	integer SCN = 1;

	localparam integer CARTW = 16256;    // 32-bit words in the blob's cart section
	localparam integer SLOTW = 32512;    // 16-bit words in the 0xFE00 slot

	// =====================================================================
	// APF slot loader: real data_loader, or a bench model of its output
	// =====================================================================
	reg         bridge_wr = 0;
	reg  [31:0] bridge_addr = 32'hF8000000;
	reg  [31:0] bridge_wr_data = 0;

	wire        ld_wr_real;
	wire [27:0] ld_addr_real;
	wire [15:0] ld_data_real;

	data_loader #(
		.ADDRESS_MASK_UPPER_4(4'h1),
		.OUTPUT_WORD_SIZE(2)
	) bios_loader (
		.clk_74a   (clk_74a),
		.clk_memory(clk_sys),
		.bridge_wr          (bridge_wr),
		.bridge_endian_little(1'b0),
		.bridge_addr        (bridge_addr),
		.bridge_wr_data     (bridge_wr_data),
		.write_en  (ld_wr_real),
		.write_addr(ld_addr_real),
		.write_data(ld_data_real)
	);

	reg         use_real = 0;
	reg         ld_wr_b = 0;
	reg  [27:0] ld_addr_b = 0;
	reg  [15:0] ld_data_b = 0;

	wire        bios_wr_raw   = use_real ? ld_wr_real   : ld_wr_b;
	wire [27:0] bios_addr_raw = use_real ? ld_addr_real : ld_addr_b;
	wire [15:0] bios_data_raw = use_real ? ld_data_real : ld_data_b;

	// core_top.v:804
	wire        ld_is_save = bios_addr_raw[25];

	// =====================================================================
	// The copier
	// =====================================================================
	reg         cs_load_req = 0;
	wire        cs_load_done, cs_load_error;
	wire [13:0] cs_img_rd_addr;
	reg  [31:0] cs_img_rd_data = 0;
	wire        sc_host_wr;
	wire [24:0] sc_host_addr;
	wire [15:0] sc_host_data;
	wire        sc_host_ready;
	wire        sc_draining;
	wire        mc_state_apply;
	reg         mc_state_done = 0;
	wire [15:0] sc_diag_drain;

	ngpc_state_cart #(.DR_WAIT_TIMEOUT(27'd100_000)) state_cart (
		.clk  (clk_sys),
		.reset(reset_in),
		.cart_save_req   (1'b0),
		.cart_save_done  (),
		.cart_img_wr     (),
		.cart_img_addr   (),
		.cart_img_data   (),
		.cart_load_req   (cs_load_req),
		.cart_load_done  (cs_load_done),
		.cart_load_error (cs_load_error),
		.cart_img_rd_addr(cs_img_rd_addr),
		.cart_img_rd_data(cs_img_rd_data),
		.sc_rd_req   (),
		.sc_rd_addr  (),
		.sc_rd_ready (1'b0),
		.sc_rd_done  (1'b0),
		.sc_rd_data  (16'd0),
		.sc_rd_active(),
		.draining_o  (sc_draining),
		.sc_host_wr  (sc_host_wr),
		.sc_host_ready(sc_host_ready),
		.sc_host_addr(sc_host_addr),
		.sc_host_data(sc_host_data),
		.stage_current_i(1'b1),
		.apply_reject_i (1'b0),
		.state_apply_o  (mc_state_apply),
		.state_done_i   (mc_state_done),
		.diag_drain_o   (sc_diag_drain),
		.hold_o         ()
	);

	// The blob's cart section: word w (32-bit), data 2 clk after the address.
	function [31:0] blobw(input integer w);
		blobw = {16'hB000 ^ w[15:0], 16'h5A00 ^ (w[15:0] * 16'd7)};
	endfunction
	// The 16-bit word k of the drained image (what the spare bank must get).
	function [15:0] drained(input integer k);
		reg [31:0] bw;
		begin
			bw = blobw(k >> 1);
			drained = k[0] ? bw[31:16] : bw[15:0];
		end
	endfunction
	reg [31:0] img_q1 = 0;
	always @(posedge clk_sys) begin
		img_q1         <= blobw(cs_img_rd_addr);
		cs_img_rd_data <= img_q1;
	end

	// The engine's answer to the state apply.
	integer eng_n = 0;
	always @(posedge clk_sys) begin : engine_stub
		mc_state_done <= 1'b0;
		if (mc_state_apply) eng_n = 12;
		else if (eng_n > 0) begin
			eng_n = eng_n - 1;
			if (eng_n == 0) mc_state_done <= 1'b1;
		end
	end

	// =====================================================================
	// The rc6 write-port arbiter, verbatim from core_top.v (or a mutant)
	// =====================================================================
	wire        stage_host_wr;
	wire [27:0] stage_host_wr_addr;
	wire [15:0] stage_host_wr_data;
	wire        stage_wr_bank;
	wire        stage_host_ready;       // ngpc_stage_mem.host_wr_ready_o

`ifdef RC6B_ARB_MUT
	`include "tb_rc6b_arb_mut.vh"
`else
	`include "tb_rc6b_arb.vh"
`endif

	// =====================================================================
	// Staging PSRAM (the real rc6 ngpc_stage_mem, or a mutant copy)
	// =====================================================================
	wire [21:16] cram_a;
	wire [15:0]  cram_dq;
	wire cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n;
	wire cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;
	wire [15:0] diag_beats, diag_drops;

	ngpc_stage_mem stage_mem (
		.active_bank_i (mc_stage_bank),
		.host_wr_bank_i(stage_wr_bank),
		.clk  (clk_sys),
		.reset(reset_in),
		.host_wr_i     (stage_host_wr),
		.host_wr_addr_i(stage_host_wr_addr[24:0]),
		.host_wr_data_i(stage_host_wr_data),
		.host_rd_i     (1'b0),
		.host_rd_addr_i(25'd0),
		.host_rd_data_o(),
		.host_busy_o   (),
		.host_wr_ready_o(stage_host_ready),
		.diag_beats_o  (diag_beats),
		.diag_drops_o  (diag_drops),
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

	// CellularRAM, async mode, write side (as tb_stage_host). 128 K words:
	// the two 32 K-word banks the region uses and everything above them, so a
	// write that escapes the banks is seen rather than aliased.
	reg [15:0] cmem [0:131071];
	reg [21:0] c_addr_l = 0;
	reg        p_we = 1, p_ce = 1, p_ub = 1, p_lb = 1;
	reg [15:0] p_dq = 0;
	reg [21:0] p_addr = 0;
	assign cram_dq = 16'hzzzz;
	integer    wr_comm = 0, wr_spare = 0, wr_else = 0;
	// per chip write: is it the right writer's word for that address?
	integer    wr_comm_bad = 0, wr_comm_drain = 0, wr_spare_bad = 0, wr_spare_apf = 0;

	always @(posedge clk_sys) begin
		p_we <= cram_we_n; p_ce <= cram_ce0_n;
		p_ub <= cram_ub_n; p_lb <= cram_lb_n;
		p_dq <= cram_dq;   p_addr <= c_addr_l;
		if (!cram_ce0_n && !cram_adv_n) c_addr_l <= {cram_a, cram_dq};
		if (cram_we_n && !p_we && !p_ce) begin
			if (!p_ub) cmem[p_addr[16:0]][15:8] <= p_dq[15:8];
			if (!p_lb) cmem[p_addr[16:0]][7:0]  <= p_dq[7:0];
			if (p_addr[21:16] != 6'd0) wr_else = wr_else + 1;
			else if (p_addr[15] == mc_stage_bank) begin
				wr_comm = wr_comm + 1;
				if (!(apf_seen[p_addr[14:0]] === 1'b1 && p_dq === apf_exp[p_addr[14:0]])) begin
					wr_comm_bad = wr_comm_bad + 1;
					if (p_addr[14:0] < SLOTW && p_dq === drained(p_addr[14:0]))
						wr_comm_drain = wr_comm_drain + 1;
				end
			end else begin
				wr_spare = wr_spare + 1;
				if (!(p_addr[14:0] < SLOTW && p_dq === drained(p_addr[14:0]))) begin
					wr_spare_bad = wr_spare_bad + 1;
					if (apf_seen[p_addr[14:0]] === 1'b1 && p_dq === apf_exp[p_addr[14:0]])
						wr_spare_apf = wr_spare_apf + 1;
				end
			end
		end
	end

	// =====================================================================
	// Monitors
	// =====================================================================
	integer n_collide = 0, n_apf = 0, n_apf_inbank = 0, n_drain = 0, n_skidfull = 0;
	integer n_apf_on_replay = 0, n_host_wr = 0;
	integer t_dr_up = -1, t_dr_dn = -1, max_fill = 0, max_fill_drain = 0;
	reg     load_done_seen = 0, load_err_seen = 0;
	always @(posedge clk_sys) if (!reset_in) begin
		if (sc_draining && t_dr_up < 0) t_dr_up = cyc;
		if (cs_load_done) begin
			t_dr_dn = cyc; load_done_seen = 1;
			if (cs_load_error) load_err_seen = 1;
		end
		if (stage_mem.skid_fill > max_fill) max_fill = stage_mem.skid_fill;
		if (sc_draining && stage_mem.skid_fill > max_fill_drain) max_fill_drain = stage_mem.skid_fill;
		// the arbiter's own names: a copier beat pending (fresh or replayed)
		// in the cycle APF takes the port
		if (sc_beat && apf_save_wr)     n_collide = n_collide + 1;
		if (sc_replay && apf_save_wr)   n_apf_on_replay = n_apf_on_replay + 1;
		if (bios_wr_raw && ld_is_save)  n_apf = n_apf + 1;
		if (bios_wr_raw && ld_is_save && bios_addr_raw[24:16] == 9'd0) n_apf_inbank = n_apf_inbank + 1;
		if (sc_host_wr)                 n_drain = n_drain + 1;
		if (stage_host_wr)              n_host_wr = n_host_wr + 1;
		if (stage_host_wr && stage_mem.skid_full) n_skidfull = n_skidfull + 1;
	end

	// Expected committed-bank contents: every APF save beat, by word, taken at
	// the loader's output (upstream of the arbiter).
	reg  [15:0] apf_exp  [0:32767];
	reg         apf_seen [0:32767];
	always @(posedge clk_sys) if (!reset_in && bios_wr_raw && ld_is_save && bios_addr_raw[24:16] == 9'd0) begin
		apf_exp [bios_addr_raw[15:1]] <= bios_data_raw;
		apf_seen[bios_addr_raw[15:1]] <= 1'b1;
	end

	// =====================================================================
	// Stimulus
	// =====================================================================
	function [15:0] pat16(input integer j);
		pat16 = 16'hA000 ^ j[15:0] ^ (j[15:0] << 5);
	endfunction

	// Scenarios 1-3, 8: bench-driven loader output, aimed at the drain's beats.
	reg     force_on = 0;
	reg     force_follow = 0;      // 8: also put APF on the replay cycle
	integer force_every = 5;       // collide on every Nth issue (1 = all allowed)
	integer force_space = 4;       // minimum clk between aimed bench APF strobes
	integer opp = 0, n_apf_b = 0;
	integer last_hi = -100;
	integer chain = 0, chain_max = 1;

	task issue_apf_b;
		begin
			ld_wr_b   <= 1'b1;
			ld_addr_b <= 28'h2000000 + 2 * n_apf_b;
			ld_data_b <= pat16(n_apf_b);
			n_apf_b    = n_apf_b + 1;
			last_hi    = cyc + 1;
		end
	endtask

	always @(posedge clk_sys) begin
		ld_wr_b <= 1'b0;
		if (force_on && !reset_in && n_apf_b < SLOTW) begin
			if (force_follow && sc_beat && apf_save_wr && chain < chain_max) begin
				// A copier beat lost the port to APF this cycle, so its replay
				// is on the port next cycle: put another APF beat there (one or
				// two in a row), 1 clk after the last -- beyond data_loader.
				issue_apf_b;
				chain = chain + 1;
			end else if ((state_cart.st == 4'd9 || state_cart.st == 4'd10) && sc_host_ready) begin
				// The copier drives sc_host_wr next cycle: put an APF beat there.
				opp = opp + 1;
				if ((cyc + 1 - last_hi >= force_space) &&
				    ((opp % force_every) == 0 ||
				     (state_cart.st == 4'd10 && state_cart.w == CARTW - 1))) begin
					chain     = 0;
					chain_max = 1 + (n_apf_b % 2);
					issue_apf_b;
				end
			end
		end
	end

	task bridge_word(input [31:0] a, input [31:0] d, input integer gap);
		begin
			@(posedge clk_74a);
			bridge_addr <= a; bridge_wr_data <= d; bridge_wr <= 1;
			@(posedge clk_74a); bridge_wr <= 0;
			repeat (gap) @(posedge clk_74a);
		end
	endtask

	// A full file through the real loader: 16256 bridge words.
	task apf_file(input integer gap, input integer bursty);
		integer j;
		reg [15:0] w0, w1;
		begin
			for (j = 0; j < SLOTW / 2; j = j + 1) begin
				w0 = pat16(2*j); w1 = pat16(2*j+1);
				// data_loader byte-swaps (bridge_endian_little = 0): the file's
				// little-endian 16-bit words come out as w0, then w1.
				bridge_word(32'h12000000 + 4 * j, {w0[7:0], w0[15:8], w1[7:0], w1[15:8]}, gap);
				if (bursty && (j % 128) == 127) repeat (4000) @(posedge clk_74a);
			end
		end
	endtask

	task start_drain;
		begin
			@(posedge clk_sys); cs_load_req <= 1'b1;
			@(posedge clk_sys); cs_load_req <= 1'b0;
		end
	endtask

	task wait_drain_done;
		integer t;
		begin
			t = 0;
			while (!cs_load_done && t < 4000000) begin @(posedge clk_sys); t = t + 1; end
		end
	endtask

	task wait_quiet;
		integer q, t;
		begin
			q = 0; t = 0;
			while (q < 400 && t < 4000000) begin
				@(posedge clk_sys); t = t + 1;
				if (stage_host_wr || sc_replay || stage_mem.host_pending || stage_mem.ps_busy ||
				    stage_mem.skid_wp != stage_mem.skid_rp || bios_loader.read_state != 0 ||
				    !bios_loader.mem_empty || sc_draining)
					q = 0;
				else
					q = q + 1;
			end
		end
	endtask

	// ---- checks ----------------------------------------------------------
	integer failures = 0;
	task fail(input [8*120-1:0] what);
		begin
			failures = failures + 1;
			$display("   FAIL %0s", what);
		end
	endtask

	integer e_comm, e_other, e_spare, e_spare_stray, e_high, apf_words;
	task check_all;
		integer k;
		reg [16:0] cb, sb;
		reg [31:0] bw;
		reg [15:0] ew;
		begin
			e_comm = 0; e_other = 0; e_spare = 0; e_spare_stray = 0; e_high = 0; apf_words = 0;
			cb = {1'b0, mc_stage_bank, 15'd0};
			sb = {1'b0, ~mc_stage_bank, 15'd0};
			for (k = 0; k < 32768; k = k + 1) begin
				if (apf_seen[k] === 1'b1) begin
					apf_words = apf_words + 1;
					if (cmem[cb + k] !== apf_exp[k]) begin
						if (e_comm < 4)
							$display("   committed word %0d: %h, APF delivered %h", k, cmem[cb + k], apf_exp[k]);
						e_comm = e_comm + 1;
					end
				end else if (cmem[cb + k] !== 16'hCCCC) begin
					if (e_other < 4)
						$display("   committed word %0d written (%h) though APF never sent it", k, cmem[cb + k]);
					e_other = e_other + 1;
				end
			end
			for (k = 0; k < 32768; k = k + 1) begin
				bw = blobw(k >> 1);
				ew = k[0] ? bw[31:16] : bw[15:0];
				if (SCN != 7 && k < SLOTW) begin
					if (cmem[sb + k] !== ew) begin
						if (e_spare < 4)
							$display("   spare word %0d: %h, drained %h", k, cmem[sb + k], ew);
						e_spare = e_spare + 1;
					end
				end else if (cmem[sb + k] !== 16'hCCCC) begin
					if (e_spare_stray < 4)
						$display("   spare word %0d written (%h) though nothing drained it", k, cmem[sb + k]);
					e_spare_stray = e_spare_stray + 1;
				end
			end
			for (k = 65536; k < 131072; k = k + 1)
				if (cmem[k] !== 16'hCCCC) e_high = e_high + 1;

			if (e_comm != 0)   fail("K1 committed bank: APF words missing or wrong");
			if (e_other != 0 || e_spare_stray != 0 || e_high != 0)
				fail("K2 stray words written");
			if (e_spare != 0)  fail("K3 spare bank: drained words missing or wrong");
			if (wr_comm != n_apf_inbank || wr_spare != n_drain || wr_else != 0)
				fail("K4 chip write strobes != APF beats / drain beats");
			if (wr_comm_drain != 0) fail("K4 drain words written into the committed bank");
			if (wr_spare_apf != 0)  fail("K4 APF words written into the spare bank");
			if (wr_comm_bad != 0 || wr_spare_bad != 0)
				fail("K4 chip writes carrying another writer's or a wrong word");
			if (n_skidfull != 0)
				fail("K5 host beats dropped at a full skid");
`ifdef NGPC_SAVE_DIAG
			if (diag_beats != ((n_apf + n_drain) & 16'hFFFF))
				fail("K5 diag_beats != APF beats + drain beats");
			if (diag_drops != (n_skidfull & 16'hFFFF))
				fail("K5 diag_drops != beats that met a full skid");
`else
			$display("   (built without NGPC_SAVE_DIAG: the diag counter checks are skipped)");
`endif
			if (SCN != 7 && (!load_done_seen || load_err_seen))
				fail("K6 the drain did not finish cleanly");
			if (SCN == 7 && (load_done_seen || n_drain != 0))
				fail("K6 a drain ran in the no-drain baseline");
			case (SCN)
				1, 2, 3, 4, 5, 8: if (n_collide == 0) fail("K7 coverage: no APF/drain collision happened");
				default:          if (n_collide != 0) fail("K7 coverage: a collision in a no-overlap scenario");
			endcase
			if (SCN == 8 && n_apf_on_replay == 0) fail("K7 coverage: no APF beat on a replay cycle");
			if (SCN == 5 && max_fill_drain <= 32)
				fail("K7 coverage: APF never queued past the copier threshold during the drain");
		end
	endtask

	integer k0;
	initial begin
		if (!$value$plusargs("SCN=%d", SCN)) SCN = 1;
		for (k0 = 0; k0 < 131072; k0 = k0 + 1) cmem[k0] = 16'hCCCC;
		for (k0 = 0; k0 < 32768; k0 = k0 + 1) begin apf_seen[k0] = 1'b0; apf_exp[k0] = 16'h0; end

`ifdef RC6B_LABEL
		$display("== RC6B-PORT build: %0s", `RC6B_LABEL);
`endif
		$display("== RC6B-PORT scenario %0d", SCN);

		repeat (20) @(posedge clk_sys);
		reset_in <= 1'b0;
		repeat (20) @(posedge clk_sys);

		case (SCN)
			1, 2, 3, 8: begin
				force_every  = (SCN == 1) ? 5 : 1;
				force_space  = (SCN == 3) ? 2 : 4;
				force_follow = (SCN == 8);
				force_on     = 1;
				start_drain;
				wait_drain_done;
				force_on    = 0;
			end
			4, 5: begin
				use_real = 1;
				start_drain;
				fork
					wait_drain_done;
					begin
						repeat (10000) @(posedge clk_sys);   // ~200 us into the drain
						apf_file((SCN == 4) ? 75 : 4, (SCN == 5));
					end
				join
			end
			6: begin
				use_real = 1;
				apf_file(75, 0);
				wait_quiet;
				start_drain;
				wait_drain_done;
			end
			7: begin
				use_real = 1;
				apf_file(4, 1);
			end
			default: begin
				$display("   unknown scenario %0d", SCN);
				failures = failures + 1;
			end
		endcase
		wait_quiet;
		check_all;

		$display("   drain %0d clk (%0d us); deepest skid fill %0d (%0d while draining)",
		         (t_dr_dn >= 0 && t_dr_up >= 0) ? t_dr_dn - t_dr_up : 0,
		         (t_dr_dn >= 0 && t_dr_up >= 0) ? $rtoi((t_dr_dn - t_dr_up) / 49.152) : 0,
		         max_fill, max_fill_drain);
		$display("   collisions %0d (APF on a replay cycle %0d); APF beats %0d, drain beats %0d, port beats %0d",
		         n_collide, n_apf_on_replay, n_apf, n_drain, n_host_wr);
		$display("   diag_beats %0d diag_drops %0d skid-full beats %0d; chip writes committed %0d spare %0d outside %0d",
		         diag_beats, diag_drops, n_skidfull, wr_comm, wr_spare, wr_else);
		$display("   chip writes not the right writer's word: committed %0d (drain words among them %0d), spare %0d (APF words among them %0d)",
		         wr_comm_bad, wr_comm_drain, wr_spare_bad, wr_spare_apf);
		$display("   committed: %0d/%0d APF words wrong, %0d stray | spare: %0d/%0d drained words wrong, %0d stray | above banks %0d",
		         e_comm, apf_words, e_other, e_spare, (SCN == 7) ? 0 : SLOTW, e_spare_stray, e_high);
		// Pass: $finish, exit status 0. Fail: $stop, which under "vvp -N" (as
		// the run script runs it) ends the run with exit status 1.
		if (failures == 0) begin
			$display("== ALL RC6B-PORT SCENARIOS PASS");
			$finish;
		end else begin
			$display("== %0d FAILURE(S) in RC6B-PORT scenario %0d", failures, SCN);
			$stop;
		end
	end

	initial begin
		#400_000_000;
		$display("   FAIL watchdog");
		$display("== %0d FAILURE(S) in RC6B-PORT scenario %0d (watchdog)", failures + 1, SCN);
		$stop;
	end

endmodule

`default_nettype wire
