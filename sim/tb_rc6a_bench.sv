// RC6A: rc6 issue R1 (saveless_erased) and the flash-idle guard, against the
// REAL rc6 RTL. Port of sim/tb_r6a_bench.sv (the R1 investigation bench,
// derived from tb_t9e_bench.sv); its machine, CPU, die and APF models are
// reused, with these changes:
//
//   * the save engine is target/pocket/ngpc_cart_save.sv as shipped in rc6
//     (or a sim/tb_rc6a_mut_*.sv mutant of it, built by sim/run_rc6_r1.sh);
//   * the staging region is the REAL target/pocket/ngpc_stage_mem.sv +
//     psram.sv behind a CellularRAM pin model (tb_t9s_bench's), in place of
//     tb_r6a's behavioral skid: its host_busy_o (with the ~10 ms tail) and
//     rc6 host_wr_ready_o are what the engine and the copier see;
//   * the core_top.v rc6 glue: the engine's host_busy_i is the staging host
//     port alone (L2), the host write port goes through the L3 arbiter
//     (APF save-slot beats vs the copier's drain), save_slot_wr_i is the APF
//     leg of that arbiter, and the bridge's save_busy_i is connected -- to
//     the engine's boot_hold_o since the rc6 follow-up (ngpc_machine
//     save_busy_state = overlay_boot_hold);
//   * the engine's host_rd_i (rc6 follow-up: APF's read strobe on the staging
//     port, core_top stage_host_rd) is the same signal as stage_mem's
//     host_rd_i: tied 0, this bench models no APF flush read;
//   * the G-DELIV file is really delivered, beat by beat, through that port;
//   * the die model erases block 9 or 10 (geometry of a 4 Mbit die) at a
//     per-scenario pace and programs in PROG_CLK+1 clocks; it counts
//     operations cut by the machine reset. Its busy windows sit on either
//     side of the engine's program/erase classifier (busy_cnt saturating at
//     4095): an erase is >= 4096 clocks at every pace used here (block 10 at
//     estep 1 is 8192), a program is 25.
//
// A save-less 4 Mbit game (Pac-Man-shaped) whose only flash activity is a
// power-up routine on block 10 (erase, program one 0x55 byte, erase). The
// previous game (Card Fighters) left its image in bank 0 of the staging
// PSRAM. Scenarios, in order (later ones reuse earlier blobs):
//   CAP        a sleep before the session's first flash event embeds the
//              stale bank (another game's image): the defect's cause
//   MEM        Memory load in the same session after its routine published
//   MEM-ERASE  the same Memory loaded again while the game erases block 10
//              once more: must load, the erase must complete     (rc6 guard)
//              -- its event leaves a pass owed at the decision, and R1 still
//              accepts: only a PROGRAM since the publish refuses (follow-up)
//   WAKE-HW    wake, load inside the boot hold (nothing dirty)
//   WAKE-LATE  wake, load after the fresh session's routine published
//   WAKE-ERASE wake, load while the fresh session's first erase of block 10
//              is in flight: must load, the erase must complete  (rc6 guard)
//              -- a pass owed at the decision, as MEM-ERASE
//   G-DATA     the loading session left DATA in flash       -> must refuse
//   G-PEND     a program lands during the drain (unpublished) -> must refuse
//   G-DELIV    a .sav was delivered and applied             -> must refuse
//   G-OVF      the session's image overflowed              -> must refuse
//   GUARD-A    Memory load while the game erases block 10, which the
//              Memory's image holds: the load waits for the erase, then
//              restores the block; no erase is cut
//   GUARD-B    Memory load while the game erases block 10, which the
//              Memory's image does NOT hold (it holds block 9): the load
//              waits for the erase and is refused on coverage; block 10 ends
//              fully erased, dirty and published -- not half-erased, untracked
//   G-BASE     guard: the session accepted a state carrying this game's
//              image (base_q), then erased that block and published -> a
//              no-image state must refuse
//   G-PROG     guard (follow-up): a save-less session whose last publish
//              was erase-only; the game PROGRAMS a data byte into block 10
//              as the state request reaches the engine, so the flash-idle
//              guard lets the program finish and its event arrives before
//              the decision, unpublished -> must refuse (prog_since_publish);
//              the program is not cut, its byte is in flash and is
//              published afterwards as the session's save
//   WAKE-PROG  guard (follow-up): new launch; the fresh session's power-up
//              routine runs during the drain -- erase, PROGRAM 0x55, erase --
//              and the second erase, which wipes that byte, is in flight at
//              the state request: the program is still unpublished at the
//              decision -> must refuse, though block 10 ends erased; the
//              erase completes, the session does not freeze. (The window a
//              wake load can hit at every power-up: from the routine's
//              program until its publish, ~QUIET_CLOCKS after the erase.)
//
// The bench encodes the rc6 contract. sim/run_rc6_r1.sh builds it against
// the real engine and against one mutant per rc6 change; each mutant must
// fail exactly its own scenarios among those the real engine passes.
// Run with vvp -N: the last line is "== ALL RC6A R1 SCENARIOS PASS" or
// "== N FAILURE(S): ...", and a failure exits 1 ($stop under -N).
// +ONLY=PROG (development) runs CAP, G-PROG and WAKE-PROG alone.
//
`timescale 1ns / 1ps
`default_nettype none

`define FAIL(a) begin errors = errors + 1; $write("   FAIL [%0s] ", scn); $display a ; end

module tb_rc6a_bench;

	reg clk_sys = 0;
	reg clk_74a = 0;
	always #10.173 clk_sys = ~clk_sys;
	always #6.734  clk_74a = ~clk_74a;

	reg reset = 1;

	localparam integer N_INT    = 112;
	localparam integer SZ0      = 12288;
	localparam integer SZ1      = 4096;
	localparam integer SZ2      = 16384;
	localparam integer CARTB    = 8424;
	localparam integer CARTW    = 16256;
	localparam integer WORDS    = CARTB + CARTW;
	localparam [31:0]  BLOBBASE = 32'h40000000;
	localparam integer BANKW    = 32768;
	localparam integer SLOTW    = 32512;
	localparam integer FLASHW   = 262144;
	localparam integer B10W     = 32'h3E000;   // block 10, 16-bit word index
	localparam integer B10N     = 8192;
	localparam integer B9W      = 32'h3D000;   // block 9 (8 KB)
	localparam integer B9N      = 4096;
	localparam integer QUIET    = 25000;
	localparam integer DRW_TO   = 4000000;
	localparam integer GAP      = 4;
	localparam integer PROG_CLK = 24;
	localparam integer CPU_REFILL = 48;
	localparam [31:0]  CRC_PAC  = 32'h21E8CC15;

	// ---- cartridge / slots ----------------------------------------------------
	reg         cart_ready = 0, cart_replace = 0;
	reg  [31:0] cart_crc   = CRC_PAC;
	reg         slots_settled = 0;

	// =========================================================================
	// Machine model
	// =========================================================================
	reg [63:0] internals [0:N_INT];
	reg  [7:0] mem0 [0:SZ0-1];
	reg  [7:0] mem1 [0:SZ1-1];
	reg  [7:0] mem2 [0:SZ2-1];

	wire [63:0] eng_bus_din;
	wire  [9:0] eng_bus_adr;
	wire        eng_bus_wren;
	wire        eng_bus_rst;
	wire [63:0] eng_bus_dout = internals[eng_bus_adr];

	wire [24:0] ram_addr;
	wire        ram_rden, ram_wren;
	wire  [7:0] ram_wdata;
	wire  [2:0] ram_type;
	reg   [7:0] ram_rdata_q = 0, ram_rdata_q2 = 0;
	wire  [7:0] ram_rdata = ram_rdata_q2;

	always @(posedge clk_sys) begin
		case (ram_type)
			3'd0:    ram_rdata_q <= mem0[ram_addr[13:0]];
			3'd1:    ram_rdata_q <= mem1[ram_addr[11:0]];
			default: ram_rdata_q <= mem2[ram_addr[13:0]];
		endcase
		ram_rdata_q2 <= ram_rdata_q;
		if (ram_wren) begin
			case (ram_type)
				3'd0:    mem0[ram_addr[13:0]] <= ram_wdata;
				3'd1:    mem1[ram_addr[11:0]] <= ram_wdata;
				default: mem2[ram_addr[13:0]] <= ram_wdata;
			endcase
		end
		if (eng_bus_wren) internals[eng_bus_adr] <= eng_bus_din;
	end

	wire       eng_pause_req;
	wire       sc_hold;
	wire       ss_loading;
	wire       boot_hold;
	wire       pause_req = (eng_pause_req === 1'b1) || (sc_hold === 1'b1);
	wire       mreset    = reset || (boot_hold === 1'b1);

	reg  [2:0] pause_pipe = 3'd0;
	reg  [2:0] die_idle_cnt = 3'd0;
	reg  [7:0] run_cnt = 8'd0;
	reg        die_busy0 = 0;
	always @(posedge clk_sys) begin
		pause_pipe <= {pause_pipe[1:0], pause_req};
		if (die_busy0)                 die_idle_cnt <= 3'd0;
		else if (die_idle_cnt != 3'd4) die_idle_cnt <= die_idle_cnt + 3'd1;
		if (pause_req || mreset)       run_cnt <= 8'd0;
		else if (run_cnt != CPU_REFILL) run_cnt <= run_cnt + 8'd1;
	end
	wire paused  = (pause_pipe[2] && (die_idle_cnt == 3'd4)) || (ss_loading === 1'b1);
	wire cpu_run = (run_cnt == CPU_REFILL);

	// =========================================================================
	// Cartridge SDRAM and the die (blocks 9 and 10 of a 4 Mbit die)
	// =========================================================================
	reg [15:0] sdram [0:FLASHW-1];

	reg        event0 = 0;
	reg  [5:0] block0 = 6'd10;
	reg  [1:0] die_op = 2'd0;          // 0 idle, 1 erase, 2 program
	integer    die_cnt = 0;
	reg [15:0] die_fill = 0;
	reg        req_erase = 0, req_prog = 0;
	reg  [5:0] req_blk = 6'd10;
	reg  [5:0] op_blk  = 6'd10;
	reg [17:0] prog_word = 0;
	reg [15:0] prog_mask = 16'hFFFF;
	integer    estep = 2;              // clocks per erased word
	integer    n_die_abort = 0, n_events = 0, n_erase_done = 0, n_prog_done = 0;
	integer    t_now = 0, t_erase_end = -1, t_prog_end = -1;

	function integer blk_base(input [5:0] b);
		blk_base = (b == 6'd9) ? B9W : B10W;
	endfunction
	function integer blk_words(input [5:0] b);
		blk_words = (b == 6'd9) ? B9N : B10N;
	endfunction
	function [5:0] word_blk(input [17:0] w);
		word_blk = (w >= B10W) ? 6'd10 : 6'd9;
	endfunction

	always @(posedge clk_sys) begin
		event0 <= 1'b0;
		if (mreset) begin
			// boot_hold (or a reset) cuts the operation: no completion event,
			// the block keeps whatever the cut left in it
			if (die_op != 2'd0) n_die_abort = n_die_abort + 1;
			die_op    <= 2'd0;
			die_busy0 <= 1'b0;
		end else if (die_op == 2'd0) begin
			if (req_erase) begin
				die_op <= 2'd1; die_busy0 <= 1'b1; die_cnt <= 0; die_fill <= 0; op_blk <= req_blk;
			end else if (req_prog) begin
				die_op <= 2'd2; die_busy0 <= 1'b1; die_cnt <= 0; op_blk <= word_blk(prog_word);
			end
		end else if (die_op == 2'd1) begin
			if (die_cnt >= estep - 1) begin
				die_cnt <= 0;
				sdram[blk_base(op_blk) + die_fill] <= 16'hFFFF;
				if (die_fill == blk_words(op_blk) - 1) begin
					die_op <= 2'd0; die_busy0 <= 1'b0; event0 <= 1'b1; block0 <= op_blk;
					n_events = n_events + 1; n_erase_done = n_erase_done + 1; t_erase_end = t_now;
				end else die_fill <= die_fill + 16'd1;
			end else die_cnt <= die_cnt + 1;
		end else begin
			if (die_cnt == PROG_CLK) begin
				sdram[prog_word] <= sdram[prog_word] & prog_mask;
				die_op <= 2'd0; die_busy0 <= 1'b0; event0 <= 1'b1; block0 <= op_blk;
				n_events = n_events + 1; n_prog_done = n_prog_done + 1; t_prog_end = t_now;
			end else die_cnt <= die_cnt + 1;
		end
	end

	// ---- the CPU running the game's flash routines -------------------------------
	reg cpu_killed = 0;
	always @(posedge clk_sys) if (mreset) cpu_killed <= 1'b1;

	integer cpu_step = 0;   // 0 none, 1 erase1, 2 program, 3 erase2, 4 done
	// kind 1: erase block arg; kind 2: program 0x55 into word arg
	task cpu_flash(input integer kind, input integer arg);
		begin
			while (!cpu_run && !cpu_killed) @(posedge clk_sys);
			if (!cpu_killed) begin
				@(posedge clk_sys);
				if (kind == 1) begin req_erase <= 1'b1; req_blk <= arg[5:0]; end
				else begin req_prog <= 1'b1; prog_word <= arg; prog_mask <= 16'h55FF; end
				@(posedge clk_sys); req_erase <= 1'b0; req_prog <= 1'b0;
				@(posedge clk_sys);
				while (die_op != 2'd0 && !cpu_killed) @(posedge clk_sys);
			end
		end
	endtask

	task bios_flash_routine(input integer pw);
		begin
			cpu_killed = 0;
			cpu_step = 1; cpu_flash(1, 10);
			cpu_step = 2; cpu_flash(2, pw);
			cpu_step = 3; cpu_flash(1, 10);
			cpu_step = 4;
		end
	endtask

	// =========================================================================
	// Savestate engine, bridge, save engine, copier
	// =========================================================================
	wire [63:0] bus_out_Din, bus_out_Dout;
	wire [25:0] bus_out_Adr;
	wire        bus_out_rnw, bus_out_ena, bus_out_done;
	wire  [7:0] bus_out_be;
	wire        ss_save, ss_load, ss_busy;

	savestates #(
		.STATESIZE_PARAM(8416), .SETTLECOUNT_PARAM(16), .INTERNALSCOUNT_PARAM(N_INT),
		.SAVETYPESCOUNT_PARAM(3), .SAVETYPE0_SIZE(SZ0), .SAVETYPE1_SIZE(SZ1),
		.SAVETYPE2_SIZE(SZ2), .SAVETYPE3_SIZE(0)
	) u_ss (
		.clk(clk_sys), .reset_in(reset), .reset_ss(), .reset_delay(), .restore_begin(),
		.load_done(), .restore_prepare_ready_i(1'b1), .restore_prepare_failed_i(1'b0),
		.increaseSSHeaderCount(1'b0), .save(ss_save), .load(ss_load),
		.state_size_i(32'd8416), .savetype3_size_i(25'd0), .is_rewind_i(1'b0),
		.savestate_address(0), .savestate_busy(ss_busy), .paused(paused),
		.BUS_Din(eng_bus_din), .BUS_Adr(eng_bus_adr), .BUS_wren(eng_bus_wren),
		.BUS_rst(eng_bus_rst), .BUS_Dout(eng_bus_dout),
		.loading_savestate(ss_loading), .saving_savestate(), .sleep_savestate(eng_pause_req),
		.Save_RAMAddr(ram_addr), .Save_RAMRdEn(ram_rden), .Save_RAMWrEn(ram_wren),
		.Save_RAMWriteData(ram_wdata), .Save_RAMReadData(ram_rdata), .Save_RAMReady(1'b1),
		.Save_RAMType(ram_type),
		.bus_out_Din(bus_out_Din), .bus_out_Dout(bus_out_Dout), .bus_out_Adr(bus_out_Adr),
		.bus_out_rnw(bus_out_rnw), .bus_out_ena(bus_out_ena), .bus_out_be(bus_out_be),
		.bus_out_done(bus_out_done)
	);

	reg         bridge_wr = 0, bridge_rd = 0;
	reg  [31:0] bridge_addr = 32'hF8000000;
	reg  [31:0] bridge_wr_data = 0;
	wire [31:0] bridge_rd_data;
	reg         ss_start_req = 0, ss_load_req = 0;
	wire        start_ack, start_busy, start_ok, start_err;
	wire        load_ack,  load_busy,  load_ok,  load_err;
	wire        br_save_req, br_save_done, br_load_req, br_load_done, br_load_error;
	wire        br_img_wr;
	wire [13:0] br_img_addr, br_img_rd_addr;
	wire [31:0] br_img_data, br_img_rd_data;
	wire        frozen, load_frozen, load_fail;
	wire        busy;

	ngpc_savestate_bridge u_bridge (

		.psram_report_i (32'h9D1F108F),   // 1.1.1
		.clk_sys(clk_sys), .clk_74a(clk_74a), .reset(reset),
		.savestate_start(ss_start_req), .savestate_start_ack(start_ack),
		.savestate_start_busy(start_busy), .savestate_start_ok(start_ok),
		.savestate_start_err(start_err),
		.savestate_load(ss_load_req), .savestate_load_ack(load_ack),
		.savestate_load_busy(load_busy), .savestate_load_ok(load_ok),
		.savestate_load_err(load_err),
		.bridge_wr(bridge_wr), .bridge_rd(bridge_rd), .bridge_addr(bridge_addr),
		.bridge_wr_data(bridge_wr_data), .bridge_rd_data(bridge_rd_data),
		.ss_save(ss_save), .ss_load(ss_load), .ss_busy(ss_busy), .ss_loading(ss_loading),
		.cart_crc32(cart_crc),
		.cart_save_req(br_save_req), .cart_save_done(br_save_done),
		.cart_img_wr(br_img_wr), .cart_img_addr(br_img_addr), .cart_img_data(br_img_data),
		.cart_load_req(br_load_req), .cart_load_done(br_load_done),
		.cart_load_error(br_load_error),
		.frozen_i(frozen), .load_frozen_o(load_frozen), .load_fail_o(load_fail),
		.save_busy_i(boot_hold),                  // core_top: mc_save_busy = save_busy_state = overlay_boot_hold (rc6 follow-up)
		.cart_img_rd_addr(br_img_rd_addr), .cart_img_rd_data(br_img_rd_data),
		.bus_out_Din(bus_out_Din), .bus_out_Dout(bus_out_Dout), .bus_out_Adr(bus_out_Adr),
		.bus_out_rnw(bus_out_rnw), .bus_out_ena(bus_out_ena), .bus_out_be(bus_out_be),
		.bus_out_done(bus_out_done)
	);

	wire        save_present, stage_current, stage_bank;
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
	wire        sc_rd_req, sc_rd_active, sc_draining;
	wire [24:0] sc_rd_addr;
	wire        sc_host_wr;
	wire [24:0] sc_host_addr;
	wire [15:0] sc_host_data;
	wire        sc_state_apply;
	wire [15:0] diag_drain;
	wire        eng_ready, eng_done;
	wire [15:0] eng_rdata;
	wire        host_ready, host_busy;
	wire [15:0] diag_beats, diag_drops;

	// ---- APF's save-slot writes and core_top's rc6 L3 write-port arbiter -------
	reg         apf_wr   = 1'b0;
	reg  [24:0] apf_addr = 25'd0;
	reg  [15:0] apf_data = 16'd0;
	wire        apf_save_wr = apf_wr;                  // bios_wr_raw && ld_is_save
	reg         sc_replay   = 1'b0;
	wire        sc_beat     = sc_host_wr || sc_replay;
	wire        sc_go       = sc_beat && !apf_save_wr;
	always @(posedge clk_sys) sc_replay <= !reset && sc_beat && apf_save_wr;
	wire        stage_host_wr      = apf_save_wr || sc_beat;
	wire [24:0] stage_host_wr_addr = sc_go ? sc_host_addr : apf_addr;
	wire [15:0] stage_host_wr_data = sc_go ? sc_host_data : apf_data;
	wire        stage_wr_bank      = sc_go ? ~stage_bank : stage_bank;
	wire        stage_host_ready;
	assign      host_ready = stage_host_ready && !sc_replay && !(sc_host_wr && apf_save_wr);
	// core_top stage_host_rd (data_unloader read_en): no APF flush read is
	// modelled here, so the staging port and the engine both see it low.
	wire        stage_host_rd = 1'b0;

	ngpc_cart_save #(.QUIET_CLOCKS(QUIET)) u_save (

		.psram_report_i (32'h9D1F108F),   // 1.1.1
		.clk(clk_sys), .reset(reset),
		.cart_ready_i(cart_ready), .cart_replace_i(cart_replace),
		.cart_crc32_i(cart_crc), .cart_bytes_i(25'h0080000),
		.cart_title_i(96'h2020202020204E414D434150), .cart_catalog_i(16'h0001),
		.cart_subcat_i(8'h80), .size_code0_i(2'd1), .size_code1_i(2'd0),
		.event0_i(event0), .block0_i(block0), .event1_i(1'b0), .block1_i(6'd0),
		.die_busy_i({1'b0, die_busy0}),
		.host_busy_i(host_busy),                   // rc6 core_top: the host port alone
		.host_rd_i(stage_host_rd),                 // rc6 follow-up: APF's read strobe (none here)
		.state_apply_i(sc_state_apply), .draining_i(sc_draining),
		.state_frozen_i(load_frozen), .state_fail_i(load_fail), .frozen_o(frozen),
		.save_slot_wr_i(apf_save_wr),
		.apply_reject_o(apply_reject), .state_done_o(state_done),
		.slots_settled_i(slots_settled),
		.diag_beats_i(diag_beats), .diag_drops_i(diag_drops), .diag_drain_i(diag_drain),
		.boot_hold_o(boot_hold), .busy_o(busy), .save_present_o(save_present),
		.stage_current_o(stage_current), .stage_bank_o(stage_bank),
		.p2_req_o(p2_req), .p2_we_o(p2_we), .p2_addr_o(p2_addr), .p2_wdata_o(p2_wdata),
		.p2_be_o(p2_be), .p2_ready_i(1'b1), .p2_done_i(p2_done), .p2_rdata_i(p2_rdata),
		.stage_req_o(cs_st_req), .stage_we_o(cs_st_we), .stage_addr_o(cs_st_addr),
		.stage_wdata_o(cs_st_wdata), .stage_ready_i(eng_ready), .stage_done_i(eng_done),
		.stage_rdata_i(eng_rdata)
	);

	ngpc_state_cart #(.DR_WAIT_TIMEOUT(DRW_TO)) u_copier (
		.clk(clk_sys), .reset(reset),
		.cart_save_req(br_save_req), .cart_save_done(br_save_done),
		.cart_img_wr(br_img_wr), .cart_img_addr(br_img_addr), .cart_img_data(br_img_data),
		.cart_load_req(br_load_req), .cart_load_done(br_load_done),
		.cart_load_error(br_load_error),
		.cart_img_rd_addr(br_img_rd_addr), .cart_img_rd_data(br_img_rd_data),
		.sc_rd_req(sc_rd_req), .sc_rd_addr(sc_rd_addr), .sc_rd_ready(eng_ready),
		.sc_rd_done(eng_done), .sc_rd_data(eng_rdata), .sc_rd_active(sc_rd_active),
		.draining_o(sc_draining),
		.sc_host_ready(host_ready), .sc_host_wr(sc_host_wr), .sc_host_addr(sc_host_addr),
		.sc_host_data(sc_host_data),
		.stage_current_i(stage_current), .apply_reject_i(apply_reject),
		.state_apply_o(sc_state_apply), .state_done_i(state_done),
		.diag_drain_o(diag_drain), .hold_o(sc_hold)
	);

	// =========================================================================
	// Staging: the REAL ngpc_stage_mem + psram, core_top's engine-port mux
	// =========================================================================
	wire [21:16] cram_a;
	wire [15:0]  cram_dq;
	wire cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n;
	wire cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;

	ngpc_stage_mem u_stage (
		.active_bank_i (stage_bank),
		.host_wr_bank_i(stage_wr_bank),
		.clk  (clk_sys),
		.reset(reset),
		.host_wr_i     (stage_host_wr),
		.host_wr_addr_i(stage_host_wr_addr),
		.host_wr_data_i(stage_host_wr_data),
		.host_rd_i     (stage_host_rd),
		.host_rd_addr_i(25'd0),
		.host_rd_data_o(),
		.host_busy_o   (host_busy),
		.host_wr_ready_o(stage_host_ready),
		.diag_beats_o  (diag_beats),
		.diag_drops_o  (diag_drops),
		.eng_req_i  (sc_rd_active ? sc_rd_req : cs_st_req),
		.eng_we_i   (sc_rd_active ? 1'b0 : cs_st_we),
		.eng_addr_i (sc_rd_active ? (sc_rd_addr | {8'd0, stage_bank, 16'd0}) : cs_st_addr),
		.eng_wdata_i(cs_st_wdata),
		.eng_ready_o(eng_ready),
		.eng_done_o (eng_done),
		.eng_rdata_o(eng_rdata),
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

	// behavioral CellularRAM (async mode) at the pins, as tb_t9s_bench:
	// cmem[bank*BANKW + word]
	reg [15:0] cmem [0:65535];
	reg [21:0] c_addr_l = 0;
	reg        p_we = 1, p_ce = 1, p_ub = 1, p_lb = 1;
	reg [15:0] p_dq = 0;
	reg [21:0] p_addr = 0;
	always @(posedge clk_sys) begin
		p_we <= cram_we_n; p_ce <= cram_ce0_n;
		p_ub <= cram_ub_n; p_lb <= cram_lb_n;
		p_dq <= cram_dq;   p_addr <= c_addr_l;
		if (!cram_ce0_n && !cram_adv_n) c_addr_l <= {cram_a, cram_dq};
		if (cram_we_n && !p_we && !p_ce) begin
			if (!p_ub) cmem[p_addr[15:0]][15:8] <= p_dq[15:8];
			if (!p_lb) cmem[p_addr[15:0]][7:0]  <= p_dq[7:0];
		end
	end
	assign cram_dq = (!cram_ce0_n && !cram_oe_n && cram_we_n) ? cmem[c_addr_l[15:0]] : 16'hZZZZ;

	always @(posedge clk_sys) begin
		p2_done <= 1'b0;
		if (p2_req === 1'b1) begin
			if (p2_we) sdram[p2_addr[18:1]] <= p2_wdata;
			else       p2_rdata <= sdram[p2_addr[18:1]];
			p2_pend <= 1'b1;
		end else if (p2_pend) begin
			p2_pend <= 1'b0; p2_done <= 1'b1;
		end
	end

	// =========================================================================
	// Monitors
	// =========================================================================
	integer n_p2wr = 0, n_flips = 0, n_apply = 0, n_sdone = 0, n_lfail = 0;
	reg     bank_q = 0;
	reg     sd_rej = 0;
	integer t_ldreq = -1, t_drain = -1, t_sdone = -1, t_ssload = -1;
	integer t_capreq = -1, t_ssave_end = -1;
	reg     sc_draining_q = 0, ss_busy_q = 0;
	reg [15:0] snap10 [0:B10N-1];     // block 10 when the engine finished the capture
	reg     capturing_now = 0;
	integer ev_at_start = 0, ev_at_park = 0;
	// the state request: what the engine held when the copier asked
	integer t_sreq = -1, t_apply_begin = -1;
	reg     sreq_die_busy = 0, sreq_boot_pend = 0, apb_q = 0;

	always @(posedge clk_sys) begin
		t_now = t_now + 1;
		if (p2_req === 1'b1 && p2_we === 1'b1) n_p2wr = n_p2wr + 1;
		if (sc_state_apply === 1'b1) begin
			n_apply = n_apply + 1; t_sreq = t_now;
			sreq_die_busy  = (die_busy0 === 1'b1);
			sreq_boot_pend = (u_save.apply_pending === 1'b1);
		end
		if ((u_save.in_apply === 1'b1 && u_save.from_state === 1'b1) && !apb_q) t_apply_begin = t_now;
		apb_q = (u_save.in_apply === 1'b1 && u_save.from_state === 1'b1);
		if (state_done === 1'b1) begin n_sdone = n_sdone + 1; sd_rej = apply_reject; t_sdone = t_now; end
		if ((stage_bank ^ bank_q) === 1'b1) n_flips = n_flips + 1;
		bank_q = stage_bank;
		if (load_fail === 1'b1) n_lfail = n_lfail + 1;
		if (br_load_req === 1'b1) t_ldreq = t_now;
		if (sc_draining === 1'b1 && !sc_draining_q) t_drain = t_now;
		sc_draining_q = (sc_draining === 1'b1);
		if (ss_load === 1'b1) t_ssload = t_now;
		if (br_save_req === 1'b1) t_capreq = t_now;
		if (capturing_now && ss_busy_q && ss_busy !== 1'b1) begin : snap
			integer j;
			t_ssave_end = t_now;
			ev_at_park  = n_events;
			for (j = 0; j < B10N; j = j + 1) snap10[j] = sdram[B10W + j];
		end
		ss_busy_q = (ss_busy === 1'b1);
	end

	// =========================================================================
	// Bookkeeping
	// =========================================================================
	integer errors = 0;
	string  scn = "setup";
	string  fail_list = "";
	integer scn_e0 = 0, n_scn = 0, n_scn_fail = 0;

	task fail(input string msg);
		begin errors = errors + 1; $display("   FAIL [%0s] %0s", scn, msg); end
	endtask
	task begin_scn(input string id, input string what);
		begin scn = id; scn_e0 = errors; $display("== %0s  %0s", id, what); end
	endtask
	task end_scn;
		begin
			n_scn = n_scn + 1;
			if (errors == scn_e0) $display("   PASS %0s", scn);
			else begin
				n_scn_fail = n_scn_fail + 1;
				fail_list = $sformatf("%0s %0s", fail_list, scn);
				$display("   FAIL %0s (%0d check(s))", scn, errors - scn_e0);
			end
			$fflush;
		end
	endtask

	// heartbeat, flushed, so a long run shows where it is
	always @(posedge clk_sys) if ((t_now % 1000000) == 0 && $test$plusargs("hb")) begin
		$display("   hb t=%0d scn=%0s copier=%0d save=%0d bridge=%0d die_op=%0d cpu_step=%0d", t_now, scn,
		         u_copier.st, u_save.state, u_bridge.state, die_op, cpu_step);
		$fflush;
	end

	// ---- machine contents -----------------------------------------------------
	function [63:0] int_pat(input [7:0] s, input integer i);
		int_pat = {s, i[7:0], 8'h5A ^ s, ~i[7:0], i[15:0], ~i[15:0]};
	endfunction
	function [7:0] m_pat(input integer which, input [7:0] s, input integer i);
		case (which)
			0:       m_pat = i[7:0] ^ 8'hC3 ^ s;
			1:       m_pat = (i[7:0] * 8'd7) + 8'h11 + s;
			default: m_pat = i[7:0] + i[11:4] + {s[6:0], 1'b0};
		endcase
	endfunction
	task machine_init(input [7:0] s);
		integer i;
		begin
			for (i = 0; i <= N_INT; i = i + 1) internals[i] = int_pat(s, i);
			for (i = 0; i < SZ0; i = i + 1) mem0[i] = m_pat(0, s, i);
			for (i = 0; i < SZ1; i = i + 1) mem1[i] = m_pat(1, s, i);
			for (i = 0; i < SZ2; i = i + 1) mem2[i] = m_pat(2, s, i);
		end
	endtask
	task machine_cold;
		integer i;
		begin
			for (i = 0; i <= N_INT; i = i + 1) internals[i] = 64'hDEADBEEF_DEADBEEF;
			for (i = 0; i < SZ0; i = i + 1) mem0[i] = 8'hEE;
			for (i = 0; i < SZ1; i = i + 1) mem1[i] = 8'hEE;
			for (i = 0; i < SZ2; i = i + 1) mem2[i] = 8'hEE;
		end
	endtask

	// ---- blobs ---------------------------------------------------------------
	reg [31:0] image [0:WORDS-1];
	localparam integer NBLOB = 4;
	reg [31:0] bstore [0:NBLOB*WORDS-1];
	reg [15:0] bsnap  [0:NBLOB*B10N-1];  // flash block 10 when each blob was captured
	task blob_keep(input integer id);
		integer k;
		begin
			for (k = 0; k < WORDS; k = k + 1) bstore[id*WORDS + k] = image[k];
			for (k = 0; k < B10N; k = k + 1) bsnap[id*B10N + k] = snap10[k];
		end
	endtask
	task blob_take(input integer id);
		integer k;
		begin for (k = 0; k < WORDS; k = k + 1) image[k] = bstore[id*WORDS + k]; end
	endtask
	function [15:0] secw(input integer k);
		reg [31:0] v;
		begin v = image[CARTB + (k >> 1)]; secw = k[0] ? v[31:16] : v[15:0]; end
	endfunction

	function integer restore_bad_vs_pat(input [7:0] s);
		integer i, n;
		begin
			n = 0;
			for (i = 0; i < N_INT; i = i + 1) if (internals[i] !== int_pat(s, i)) n = n + 1;
			for (i = 0; i < SZ0; i = i + 1) if (mem0[i] !== m_pat(0, s, i)) n = n + 1;
			for (i = 0; i < SZ1; i = i + 1) if (mem1[i] !== m_pat(1, s, i)) n = n + 1;
			for (i = 0; i < SZ2; i = i + 1) if (mem2[i] !== m_pat(2, s, i)) n = n + 1;
			restore_bad_vs_pat = n;
		end
	endfunction

	// Decode block 10 of the embedded image (packed payload from word 256:
	// a literal word, or 0xFFFF followed by a run length of erased words).
	reg [15:0] dec10 [0:B10N-1];
	reg        dec_ok;
	task decode_b10;
		integer p, k, j, n;
		reg [15:0] v;
		begin
			dec_ok = (secw(0) == 16'h4E47) && (secw(1) == 16'h5043) && (secw(2) == 16'h5341) &&
			         (secw(3) == 16'h5634) && (secw(4) == cart_crc[15:0]) &&
			         (secw(5) == cart_crc[31:16]) && (secw(8) == 16'h0400) && (secw(9) == 16'h0) &&
			         (secw(10) == 16'h0) && (secw(11) == 16'h0) && (secw(12) == 16'h0);
			p = 256; k = 0;
			while (k < B10N && p < 32512) begin
				v = secw(p); p = p + 1;
				if (v == 16'hFFFF) begin
					n = secw(p); p = p + 1;
					if (n == 0) n = 1;
					for (j = 0; j < n && k < B10N; j = j + 1) begin dec10[k] = 16'hFFFF; k = k + 1; end
				end else begin dec10[k] = v; k = k + 1; end
			end
		end
	endtask

	// ---- APF -------------------------------------------------------------------
	reg sv_ok, sv_done;
	task apf_save;
		integer k, n;
		begin
			sv_ok = 0; sv_done = 0;
			@(posedge clk_74a); ss_start_req <= 1;
			n = 0;
			while (start_ack !== 1'b1 && n < 10000) begin @(posedge clk_74a); n = n + 1; end
			@(posedge clk_74a); ss_start_req <= 0;
			n = 0;
			while (start_ok !== 1'b1 && start_err !== 1'b1 && n < 16000000) begin @(posedge clk_74a); n = n + 1; end
			sv_done = (start_ok === 1'b1 || start_err === 1'b1);
			sv_ok   = (start_ok === 1'b1);
			for (k = 0; k < WORDS; k = k + 1) begin
				@(posedge clk_74a); bridge_addr <= BLOBBASE | (k*4); bridge_rd <= 1;
				repeat (3) @(posedge clk_74a);
				image[k] = bridge_rd_data;
				bridge_rd <= 0;
			end
			@(posedge clk_74a); bridge_rd <= 0; bridge_addr <= 32'hF8000000;
			for (k = 0; k < WORDS; k = k + 1) if (^image[k] === 1'bx) image[k] = 32'd0;
			repeat (8) @(posedge clk_74a);
		end
	endtask

	task apf_write_burst;
		integer k;
		reg [31:0] a;
		begin
			@(posedge clk_74a);
			for (k = 0; k < WORDS; k = k + 1) begin
				a = (k == 0) ? 32'hF8000050 : (BLOBBASE | ((k-1)*4));
				@(posedge clk_74a);
				bridge_addr <= a; bridge_wr_data <= image[k]; bridge_wr <= 1;
				@(posedge clk_74a); bridge_wr <= 0;
				repeat (GAP) @(posedge clk_74a);
			end
			@(posedge clk_74a); bridge_addr <= 32'hF8000000;
		end
	endtask

	reg ld_ok, ld_done;
	task apf_load_cmd;
		integer n;
		begin
			ld_ok = 0; ld_done = 0;
			@(posedge clk_74a); ss_load_req <= 1;
			n = 0;
			while (load_ack !== 1'b1 && n < 10000) begin @(posedge clk_74a); n = n + 1; end
			@(posedge clk_74a); ss_load_req <= 0;
			n = 0;
			while (load_ok !== 1'b1 && load_err !== 1'b1 && n < 24000000) begin @(posedge clk_74a); n = n + 1; end
			ld_done = (load_ok === 1'b1 || load_err === 1'b1);
			ld_ok   = (load_ok === 1'b1);
			repeat (8) @(posedge clk_74a);
			repeat (4) @(posedge clk_sys);
		end
	endtask

	// ---- sessions -------------------------------------------------------------
	function [15:0] rom(input integer i);
		rom = i[15:0] ^ 16'hBEEF;
	endfunction

	task wait_idle(input integer max);
		integer n, q;
		begin
			n = 0; q = 0;
			while (q < 64 && n < max) begin
				@(posedge clk_sys); n = n + 1;
				if (busy === 1'b0 && boot_hold === 1'b0) q = q + 1; else q = 0;
			end
			if (q < 64) fail("the save engine never went idle");
		end
	endtask

	// boot apply: with nothing delivered F_NODELV, the machine released
	task settle_boot;
		begin
			@(posedge clk_sys); slots_settled <= 1'b1;
			wait_idle(4000000);
`ifdef NGPC_SAVE_DIAG
			if (u_save.diag_verdict !== 16'h0005)
				$display("   note: boot verdict %h", u_save.diag_verdict);
`endif
		end
	endtask

	// Wait until the stager has published everything the routine made owed.
	// The last operation's completion event reaches the engine a cycle after
	// the die idles, so give it a few clocks to register before looking.
	task wait_published;
		integer n;
		begin
			repeat (8) @(posedge clk_sys);
			n = 0;
			while (!(stage_current === 1'b1 && die_op == 2'd0 && cpu_step == 4 && busy === 1'b0) && n < 8000000) begin
				@(posedge clk_sys); n = n + 1;
			end
			repeat (QUIET + 50000) @(posedge clk_sys);
		end
	endtask

	// =========================================================================
	// R1: a state captured before the session's first flash event embeds the
	// stale committed bank (another game's image); rc6 lets it load while the
	// session holds no save and only erased, published blocks.
	// Flash-idle guard: a state request in a running session takes the
	// machine only once the dies are idle.
	// =========================================================================
	localparam integer BLOB_QUIET_SYS = 70000;
	localparam [31:0]  CRC_CF = 32'h94B63A97;   // Card Fighters: the game played before

	integer    bh_rises = 0, bh_high = 0;
	reg        bh_q = 0;
	reg        at_pend = 0, at_data = 0, at_ovf = 0, at_base = 0, at_prog = 0;
	reg [63:0] at_dirty0 = 0;
	// the engine held a state request while the die PROGRAMMED (G-PROG), and
	// the die operation and routine step when the request reached it
	integer    n_req_prog_wait = 0;
	reg  [1:0] sreq_die_op = 2'd0;
	integer    sreq_cpu_step = 0, n_prog_at_sreq = 0;
	always @(posedge clk_sys) begin
		if (boot_hold === 1'b1 && !bh_q) bh_rises = bh_rises + 1;
		if (boot_hold === 1'b1) bh_high = bh_high + 1;
		bh_q = (boot_hold === 1'b1);
		// what the engine saw when it decided (S_FINISH ran the cycle before)
		if (state_done === 1'b1) begin
			at_pend   = u_save.stage_pending;
			at_data   = u_save.image_has_data;
			at_ovf    = u_save.pack_overflow;
			at_base   = u_save.base_q;
			at_prog   = u_save.prog_since_publish;
			at_dirty0 = u_save.dirty0;
		end
		if (u_save.state_req === 1'b1 && u_save.in_apply !== 1'b1 && die_op == 2'd2 && die_busy0)
			n_req_prog_wait = n_req_prog_wait + 1;
		if (sc_state_apply === 1'b1) begin
			sreq_die_op = die_op; sreq_cpu_step = cpu_step; n_prog_at_sreq = n_prog_done;
		end
	end

	// Card Fighters' image, as its session left bank 0 of the staging PSRAM.
	task put_cf_image(input integer bank);
		integer k;
		begin
			for (k = 0; k < BANKW; k = k + 1) cmem[bank*BANKW + k] = 16'hC0DE ^ k[15:0];
			cmem[bank*BANKW + 0] = 16'h4E47; cmem[bank*BANKW + 1] = 16'h5043;
			cmem[bank*BANKW + 2] = 16'h5341; cmem[bank*BANKW + 3] = 16'h5634;
			cmem[bank*BANKW + 4] = CRC_CF[15:0]; cmem[bank*BANKW + 5] = CRC_CF[31:16];
			cmem[bank*BANKW + 6] = 16'h0010;     cmem[bank*BANKW + 7] = 16'h0000;
			for (k = 8; k < 16; k = k + 1) cmem[bank*BANKW + k] = 16'h0000;
			cmem[bank*BANKW + 8] = 16'h0800;     // block 11
		end
	endtask

	// APF streams the save slot (keepbank) into the committed bank, 16-bit
	// beats through core_top's arbiter, ~1 us per 32-bit word.
	reg [15:0] keepbank [0:BANKW-1];
	task apf_deliver_slot;
		integer k;
		begin
			for (k = 0; k < SLOTW; k = k + 1) begin
				@(posedge clk_sys);
				apf_addr <= k*2; apf_data <= keepbank[k]; apf_wr <= 1'b1;
				@(posedge clk_sys); apf_wr <= 1'b0;
				repeat (22) @(posedge clk_sys);
			end
		end
	endtask

	// A new core launch: the FPGA is reconfigured (every initial value, so
	// stage_bank_o = 0), the PSRAM keeps its contents, the cartridge is
	// reloaded. deliver: APF streams the save slot after the cartridge.
	task launch(input integer deliver);
		integer i;
		begin
			@(posedge clk_sys);
			reset <= 1; cart_ready <= 0; slots_settled <= 0;
			repeat (10) @(posedge clk_sys);
			u_save.stage_bank_o = 1'b0;
			reset <= 0;
			for (i = 0; i < FLASHW; i = i + 1) sdram[i] = rom(i);
			machine_cold;
			@(posedge clk_sys); cart_replace <= 1;
			@(posedge clk_sys); cart_replace <= 0;
			repeat (4) @(posedge clk_sys);
			cart_ready <= 1;
			if (deliver) begin
				repeat (50) @(posedge clk_sys);
				apf_deliver_slot;
			end
			repeat (4) @(posedge clk_sys);
		end
	endtask

	integer p2_0, bh0, bhh0, lf0, sd0, ab0, ed0, pd0, rpw0;
	task mark_load;
		begin
			p2_0 = n_p2wr; bh0 = bh_rises; bhh0 = bh_high; lf0 = n_lfail; sd0 = n_sdone;
			ab0 = n_die_abort; ed0 = n_erase_done; t_sreq = -1; t_apply_begin = -1;
			pd0 = n_prog_done; rpw0 = n_req_prog_wait;
		end
	endtask

	// APF writes the blob and issues 0xA4 to a running session.
	task load_now;
		begin
			mark_load;
			apf_write_burst;
			repeat (BLOB_QUIET_SYS) @(posedge clk_sys);
			apf_load_cmd;
		end
	endtask

	// The same, while the game erases block blk: the erase starts as the
	// copier's drain nears its end, so it is in flight when the state request
	// reaches the engine (estep 8: ~65k clocks for block 10).
	integer t_erase_go = -1;
	task load_with_erase(input [5:0] blk);
		begin
			mark_load;
			t_erase_go = -1;
			fork
				begin
					apf_write_burst;
					repeat (BLOB_QUIET_SYS) @(posedge clk_sys);
					apf_load_cmd;
				end
				begin : late_erase
					integer n;
					n = 0;
					while (!(sc_draining === 1'b1 && u_copier.w >= (CARTW - 128)) && n < 30000000) begin
						@(posedge clk_sys); n = n + 1;
					end
					estep = 8;
					cpu_killed = 0; cpu_step = 1;
					t_erase_go = t_now;
					cpu_flash(1, blk);
					cpu_step = 4;
				end
			join
			estep = 2;
		end
	endtask

	function integer b10_non_ff(input integer dummy);
		integer k, n;
		begin
			n = 0;
			for (k = 0; k < B10N; k = k + 1) if (sdram[B10W + k] !== 16'hFFFF) n = n + 1;
			b10_non_ff = n;
		end
	endfunction
	function integer b10_vs_snap(input integer id);
		integer k, n;
		begin
			n = 0;
			for (k = 0; k < B10N; k = k + 1) if (sdram[B10W + k] !== bsnap[id*B10N + k]) n = n + 1;
			b10_vs_snap = n;
		end
	endfunction

	task report(input string what);
		begin
			$display("   %0s: load %0s | state_done %0d apply_reject %b verdict %h p2 writes %0d | boot_hold rose %0d time(s), %0d clk | at the decision: dirty0 %h pass-owed %b programmed-since-publish %b image_has_data %b overflow %b base %b | frozen %b load_fail %0d",
			         what, ld_ok ? "OK" : "FAILED (a wake cold-boots; a Memory load fails)",
			         n_sdone - sd0, sd_rej, u_save.diag_verdict, n_p2wr - p2_0,
			         bh_rises - bh0, bh_high - bhh0, at_dirty0, at_pend, at_prog, at_data, at_ovf, at_base,
			         frozen, n_lfail - lf0);
			$display("   %0s: state request at %0d (die busy %b, boot apply pending %b), apply began %0d | erases: started %0d, completed %0d (last at %0d), cut by a reset %0d | block 10: %0d non-erased words",
			         what, t_sreq, sreq_die_busy, sreq_boot_pend, t_apply_begin, t_erase_go,
			         n_erase_done - ed0, t_erase_end, n_die_abort - ab0, b10_non_ff(0));
		end
	endtask

	task expect_accept(input [7:0] seed, input [63:0] want_dirty0);
		integer nb;
		begin
			if (!ld_done) fail("the load never finished");
			if (!ld_ok) fail("THE LOAD WAS REFUSED: a wake cold-boots here, a Memory load reports failure");
			if (n_sdone - sd0 != 1) `FAIL(("%0d state_done pulses", n_sdone - sd0))
			if (sd_rej !== 1'b0) fail("apply_reject with state_done");
			if (ld_ok) begin
				nb = restore_bad_vs_pat(seed);
				if (nb != 0) `FAIL(("%0d machine entries not restored", nb))
			end
			if (n_p2wr != p2_0) `FAIL(("%0d flash words written for a state with no image", n_p2wr - p2_0))
			if (u_save.dirty0 !== want_dirty0) `FAIL(("dirty0 %h after the load, want %h", u_save.dirty0, want_dirty0))
			if (frozen !== 1'b0) fail("the session froze");
			if (u_save.diag_verdict !== 16'h8406) `FAIL(("verdict %h, want 8406 (state, no image, at word 4)", u_save.diag_verdict))
		end
	endtask

	task expect_refuse(input [63:0] want_dirty0);
		begin
			if (!ld_done) fail("the load never finished");
			if (ld_ok) fail("the load was ACCEPTED: this guard must refuse it");
			if (n_sdone - sd0 != 1) `FAIL(("%0d state_done pulses", n_sdone - sd0))
			if (sd_rej !== 1'b1) fail("apply_reject low with state_done");
			if (n_p2wr != p2_0) `FAIL(("%0d flash words written", n_p2wr - p2_0))
			if (u_save.dirty0 !== want_dirty0) `FAIL(("dirty0 %h after the refusal, want %h", u_save.dirty0, want_dirty0))
			if (frozen !== 1'b0) fail("the session froze (not wake-shaped: dirty is not empty)");
			if (u_save.diag_verdict !== 16'h8406) `FAIL(("verdict %h, want 8406", u_save.diag_verdict))
		end
	endtask

	// The flash-idle guard: the request found the die mid-erase (setup), and
	// the apply began only after that erase completed; nothing was cut.
	task expect_guard_waited;
		begin
			if (t_erase_go < 0) fail("(setup) the game's erase was never started");
			if (t_sreq < 0) fail("(setup) no state request reached the engine");
			else begin
				if (!sreq_die_busy) fail("(setup) the die was idle at the state request: the guard was not exercised");
				if (sreq_boot_pend) fail("(setup) a boot apply was pending at the state request");
			end
			if (n_die_abort != ab0)
				`FAIL(("%0d erase(s) cut by boot_hold: the block is left half-erased and reports no completion", n_die_abort - ab0))
			if (n_erase_done != ed0 + 1)
				`FAIL(("the game's erase did not complete (%0d completions)", n_erase_done - ed0))
			else if (t_apply_begin >= 0 && t_erase_end > t_apply_begin)
				`FAIL(("the apply began at %0d, before the erase completed at %0d", t_apply_begin, t_erase_end))
		end
	endtask

	// MEM-ERASE / WAKE-ERASE: the guard's erase reported while the drain
	// blocked every pass, so its block was still owed at the decision -- the
	// load the rc6 R1 (!stage_pending) refused. The follow-up must accept it
	// because the event was an erase, not a program.
	task expect_erase_owed;
		begin
			if (at_pend !== 1'b1)
				fail("(setup) no pass owed at the decision: the erase's event was published first, so the follow-up is not exercised");
			if (at_prog !== 1'b0)
				fail("the guard's ERASE was classified as a program (prog_since_publish set at the decision)");
			if (n_prog_done != pd0) `FAIL(("(setup) %0d program(s) during the load", n_prog_done - pd0))
		end
	endtask

	// After a scenario: let the stager publish what is owed, then read the
	// committed bank's header bitmap.
	task wait_stager(input integer max);
		integer n;
		begin
			n = 0;
			while (!(stage_current === 1'b1 && busy === 1'b0 && die_op == 2'd0) && n < max) begin
				@(posedge clk_sys); n = n + 1;
			end
			repeat (1000) @(posedge clk_sys);
		end
	endtask

	// the game saves afterwards: one program into block 10, published, claimed
	task later_save_publishes(input integer pw);
		integer n;
		begin
			cpu_killed = 0;
			cpu_flash(2, pw);
			repeat (8) @(posedge clk_sys);  // the completion event registers
			n = 0;
			// the pass waits out the load's host-port tail (~10 ms) first
			while (!(u_save.stage_pending === 1'b0 && busy === 1'b0 && die_op == 2'd0) && n < 8000000) begin
				@(posedge clk_sys); n = n + 1;
			end
			repeat (QUIET + 60000) @(posedge clk_sys);
			if (save_present !== 1'b1) fail("the save the game made after the load does not claim the slot");
			if (frozen !== 1'b0) fail("frozen after the later save");
		end
	endtask

	// =========================================================================
	// The follow-up: R1 asks whether anything was PROGRAMMED since the last
	// publish (prog_since_publish), not whether a pass is owed.
	// =========================================================================
	integer t_prog_go = -1;
	// the copier's last drain beat (the high half of the last word)
	localparam integer LAST_BEAT = (CARTW - 1) * 4 + 2;

	// G-PROG: the program goes to the die in the clock after the copier's
	// last drain beat: the copier pulses state_apply the next clock and the
	// engine registers the request one later, so S_IDLE first sees the
	// request with the die ~2 clocks into its 25-clock program, and the
	// flash-idle guard holds it until the program reports.
	task scn_g_prog;
		integer pw;
		reg [15:0] pw_old;
		begin
			begin_scn("G-PROG", "guard: save-less session, last publish erase-only; the game PROGRAMS a data byte into block 10 as the state request arrives: the guard lets it finish, it is unpublished at the decision: must refuse");
			launch(0);
			settle_boot;
			cpu_killed = 0;
			cpu_step = 1; cpu_flash(1, 10);
			cpu_step = 4;
			wait_published;
			if (u_save.image_has_data !== 1'b0 || u_save.stage_pending !== 1'b0 || u_save.prog_since_publish !== 1'b0 ||
			    u_save.dirty0 !== 64'h400 || u_save.base_q !== 1'b0 || u_save.apf_delivered !== 1'b0)
				`FAIL(("(setup) session before the load: data %b owed %b programmed %b dirty0 %h base %b delivered %b",
				       u_save.image_has_data, u_save.stage_pending, u_save.prog_since_publish, u_save.dirty0,
				       u_save.base_q, u_save.apf_delivered))
			machine_cold;
			blob_take(0);
			mark_load;
			t_prog_go = -1;
			pw = B10W + 32'h0777;
			pw_old = sdram[pw];                 // erased by the setup's erase
			if (pw_old !== 16'hFFFF) `FAIL(("(setup) the word to program reads %h, not erased", pw_old))
			fork
				begin
					apf_write_burst;
					repeat (BLOB_QUIET_SYS) @(posedge clk_sys);
					apf_load_cmd;
				end
				begin : g_prog_go
					integer m;
					m = 0;
					while (!(sc_host_wr === 1'b1 && sc_host_addr == LAST_BEAT) && m < 30000000) begin
						@(posedge clk_sys); m = m + 1;
					end
					if (!cpu_run) fail("(setup) the CPU was not running at the end of the drain");
					req_prog <= 1'b1; prog_word <= pw; prog_mask <= 16'h55FF;
					t_prog_go = t_now;
					@(posedge clk_sys); req_prog <= 1'b0;
				end
			join
			report("G-PROG");
			$display("   G-PROG: program issued at %0d, completed at %0d (%0d program(s) in the load) | the engine held the state request %0d clk while the die programmed | die op at the request %0d",
			         t_prog_go, t_prog_end, n_prog_done - pd0, n_req_prog_wait - rpw0, sreq_die_op);
			if (t_prog_go < 0) fail("(setup) the program was never issued");
			if (n_req_prog_wait == rpw0)
				fail("(setup) the die was not programming while the engine held the state request: the guard was not exercised by a program");
			if (n_die_abort != ab0) `FAIL(("%0d operation(s) cut by boot_hold: the program was lost", n_die_abort - ab0))
			if (n_prog_done != pd0 + 1) `FAIL(("the program did not complete (%0d completions)", n_prog_done - pd0))
			if (sdram[pw] !== (pw_old & 16'h55FF))
				`FAIL(("the programmed word reads %h, want %h", sdram[pw], pw_old & 16'h55FF))
			if (t_apply_begin >= 0 && t_prog_end >= 0 && t_apply_begin <= t_prog_end)
				`FAIL(("the apply began at %0d, before the program completed at %0d", t_apply_begin, t_prog_end))
			if (at_data !== 1'b0) fail("(setup) the committed image held data at the decision");
			if (at_prog !== 1'b1) fail("the PROGRAM was not counted: prog_since_publish clear at the decision");
			expect_refuse(64'h400);
			wait_stager(8000000);
			if (u_save.stage_pending !== 1'b0 || u_save.prog_since_publish !== 1'b0 || u_save.image_has_data !== 1'b1 ||
			    cmem[stage_bank*BANKW + 8] !== 16'h0400)
				`FAIL(("the program was not published as the session's save (owed %b programmed %b data %b committed bitmap %h)",
				       u_save.stage_pending, u_save.prog_since_publish, u_save.image_has_data, cmem[stage_bank*BANKW + 8]))
			if (save_present !== 1'b1) fail("the published program does not claim the save slot");
			end_scn;
		end
	endtask

	// WAKE-PROG: the routine starts ~1536 drain words (~21k clocks) before
	// the request: erase 1 at estep 1 (8192 clocks, still an erase to the
	// classifier), the program, then erase 2 at estep 8 (~65k clocks), which
	// is in flight when the request arrives.
	task scn_wake_prog;
		integer pw;
		begin
			begin_scn("WAKE-PROG", "new launch; the fresh session's power-up routine runs during the drain (erase, PROGRAM 0x55, erase) and its second erase is in flight at the state request: the program is unpublished: must refuse, the erase must complete");
			launch(0);
			settle_boot;
			machine_cold;
			blob_take(0);
			mark_load;
			t_erase_go = -1; t_prog_go = -1;
			pw = B10W + 32'h0BFF;
			fork
				begin
					apf_write_burst;
					repeat (BLOB_QUIET_SYS) @(posedge clk_sys);
					apf_load_cmd;
				end
				begin : wake_routine
					integer m;
					m = 0;
					while (!(sc_draining === 1'b1 && u_copier.w >= (CARTW - 1536)) && m < 30000000) begin
						@(posedge clk_sys); m = m + 1;
					end
					cpu_killed = 0;
					estep = 1; cpu_step = 1; cpu_flash(1, 10);
					cpu_step = 2; t_prog_go = t_now; cpu_flash(2, pw);
					estep = 8; cpu_step = 3; t_erase_go = t_now; cpu_flash(1, 10);
					cpu_step = 4;
				end
			join
			estep = 2;
			report("WAKE-PROG");
			$display("   WAKE-PROG: program issued at %0d, completed at %0d; second erase from %0d | at the request: die op %0d, routine step %0d, programs done %0d",
			         t_prog_go, t_prog_end, t_erase_go, sreq_die_op, sreq_cpu_step, n_prog_at_sreq - pd0);
			if (t_erase_go < 0) fail("(setup) the routine's second erase was never started");
			if (t_sreq < 0) fail("(setup) no state request reached the engine");
			else if (!sreq_die_busy || sreq_die_op != 2'd1 || sreq_cpu_step != 3 || n_prog_at_sreq != pd0 + 1)
				`FAIL(("(setup) at the state request the routine was not in its second erase after its program (die busy %b op %0d step %0d programs %0d)",
				       sreq_die_busy, sreq_die_op, sreq_cpu_step, n_prog_at_sreq - pd0))
			if (n_die_abort != ab0)
				`FAIL(("%0d operation(s) cut by boot_hold: block 10 is left half-erased and reports no completion", n_die_abort - ab0))
			if (n_erase_done != ed0 + 2) `FAIL(("%0d erase(s) completed in the load, want 2", n_erase_done - ed0))
			else if (t_apply_begin >= 0 && t_erase_end >= t_apply_begin)
				`FAIL(("the apply began at %0d, before the second erase completed at %0d", t_apply_begin, t_erase_end))
			if (b10_non_ff(0) != 0) `FAIL(("block 10 left with %0d non-erased words", b10_non_ff(0)))
			if (at_data !== 1'b0) fail("(setup) the committed image held data at the decision");
			if (at_prog !== 1'b1) fail("the routine's PROGRAM was not counted: prog_since_publish clear at the decision");
			expect_refuse(64'h400);
			wait_stager(8000000);
			if (u_save.stage_pending !== 1'b0 || u_save.prog_since_publish !== 1'b0 || u_save.image_has_data !== 1'b0 ||
			    cmem[stage_bank*BANKW + 8] !== 16'h0400)
				`FAIL(("the routine was not published (owed %b programmed %b data %b committed bitmap %h, want 0400, no data)",
				       u_save.stage_pending, u_save.prog_since_publish, u_save.image_has_data, cmem[stage_bank*BANKW + 8]))
			if (save_present !== 1'b0) fail("an erased block claims the save slot");
			end_scn;
		end
	endtask

	integer i, nb;
	string  only_arg;

	initial begin
		for (i = 0; i < FLASHW; i = i + 1) sdram[i] = rom(i);
		for (i = 0; i < 2*BANKW; i = i + 1) cmem[i] = 16'hDEAD;
		put_cf_image(0);                    // Card Fighters was played last
		for (i = 0; i < WORDS; i = i + 1) image[i] = 32'd0;
		machine_cold;
		repeat (20) @(posedge clk_sys);

		// ---- CAP -----------------------------------------------------------------
		begin_scn("CAP", "Pac-Man, no .sav, Card Fighters played before: sleep before the session's first flash event");
		launch(0);
		settle_boot;
		machine_init(8'h51);
		ev_at_start = n_events;
		cpu_step = 0;
		fork
			begin
				repeat (5000) @(posedge clk_sys);
				bios_flash_routine(B10W + 32'h1240);
			end
			begin
				repeat (100) @(posedge clk_sys);
				capturing_now = 1;
				apf_save;
				capturing_now = 0;
			end
		join
		if (!sv_ok) fail("the capture did not report ok");
		if (ev_at_park != ev_at_start) fail("(setup) a flash event came before the capture");
		$display("   embedded cart section: %h %h %h %h crc %h%h bitmap0 %h | this cartridge's CRC %h",
		         secw(0), secw(1), secw(2), secw(3), secw(5), secw(4), secw(8), CRC_PAC);
		if ({secw(5), secw(4)} === CRC_CF)
			$display("   R1 cause: the capture embedded Card Fighters' image -- the committed bank this session never wrote");
		else fail("(setup) the capture did not embed the stale bank");
		blob_keep(0);
		wait_published;
		if (u_save.dirty0 !== 64'h400 || u_save.image_has_data !== 1'b0 || u_save.stage_pending !== 1'b0 ||
		    u_save.base_q !== 1'b0 || u_save.apf_delivered !== 1'b0)
			`FAIL(("(setup) session after the routine: dirty0 %h data %b owed %b base %b delivered %b",
			       u_save.dirty0, u_save.image_has_data, u_save.stage_pending, u_save.base_q, u_save.apf_delivered))
		if (u_save.prog_since_publish !== 1'b0)
			fail("the routine's program is still counted after its publish: prog_since_publish not cleared by the publish");
		end_scn;

		if ($value$plusargs("ONLY=%s", only_arg)) begin
			if (only_arg == "PROG") begin
				scn_g_prog;
				scn_wake_prog;
			end else begin
				scn = "setup";
				`FAIL(("+ONLY=%0s: only +ONLY=PROG is known", only_arg))
			end
			finish_run;
		end

		// ---- MEM: the same session loads it as a Memory ----------------------------
		begin_scn("MEM", "same session, after its routine published (block 10 erased): load that state as a Memory");
		machine_cold;
		blob_take(0);
		load_now;
		report("MEM");
		expect_accept(8'h51, 64'h400);
		end_scn;

		// ---- MEM-ERASE: the Memory again, while the game erases block 10 -----------
		begin_scn("MEM-ERASE", "same session, the Memory loaded again while the game erases block 10 once more: must load after the erase completes");
		machine_init(8'h66);
		blob_take(0);
		load_with_erase(6'd10);
		report("MEM-ERASE");
		expect_guard_waited;
		expect_erase_owed;
		expect_accept(8'h51, 64'h400);
		if (b10_non_ff(0) != 0) `FAIL(("block 10 left with %0d non-erased words", b10_non_ff(0)))
		wait_stager(8000000);
		if (u_save.stage_pending !== 1'b0 || cmem[stage_bank*BANKW + 8] !== 16'h0400)
			`FAIL(("the erase was not published (owed %b, committed bitmap %h, want 0400)",
			       u_save.stage_pending, cmem[stage_bank*BANKW + 8]))
		end_scn;

		// ---- WAKE-HW: the load arrives inside the boot hold ------------------------
		begin_scn("WAKE-HW", "new launch; the load arrives while the boot apply still waits for the slots to settle");
		launch(0);
		if (boot_hold !== 1'b1) fail("(setup) no boot apply pending");
		blob_take(0);
		mark_load;
		apf_write_burst;
		fork
			apf_load_cmd;
			begin : settle_mid
				integer n;
				n = 0;
				while (sc_draining !== 1'b1 && n < 8000000) begin @(posedge clk_sys); n = n + 1; end
				repeat (20000) @(posedge clk_sys);
				slots_settled <= 1'b1;
			end
		join
		report("WAKE-HW");
		expect_accept(8'h51, 64'h0);
		end_scn;

		// ---- WAKE-LATE: the load arrives after the wake's own routine published ----
		begin_scn("WAKE-LATE", "new launch; the load arrives after the fresh session's routine erased block 10 and published");
		launch(0);
		settle_boot;
		cpu_step = 0;
		bios_flash_routine(B10W + 32'h0BFF);
		wait_published;
		for (i = 0; i < BANKW; i = i + 1) keepbank[i] = cmem[stage_bank*BANKW + i];
		machine_cold;
		blob_take(0);
		load_now;
		report("WAKE-LATE");
		expect_accept(8'h51, 64'h400);
		$display("   block 10 at the resume: %0d non-erased words (the capture-time flash was the ROM: %0d non-erased)",
		         b10_non_ff(0), B10N);
		if (ld_ok) later_save_publishes(B10W + 32'h0100);
		end_scn;

		// ---- WAKE-ERASE: the load waits out the fresh session's first erase ---------
		begin_scn("WAKE-ERASE", "new launch; the load arrives while the fresh session's power-up erase of block 10 is in flight: must load after it completes");
		launch(0);
		settle_boot;
		machine_cold;
		blob_take(0);
		load_with_erase(6'd10);
		report("WAKE-ERASE");
		expect_guard_waited;
		expect_erase_owed;
		expect_accept(8'h51, 64'h400);
		if (b10_non_ff(0) != 0) `FAIL(("block 10 left with %0d non-erased words", b10_non_ff(0)))
		wait_stager(8000000);
		if (u_save.stage_pending !== 1'b0 || cmem[stage_bank*BANKW + 8] !== 16'h0400)
			`FAIL(("the erase was not published (owed %b, committed bitmap %h, want 0400)",
			       u_save.stage_pending, cmem[stage_bank*BANKW + 8]))
		end_scn;

		// ---- G-DATA: the fresh session left data in flash --------------------------
		begin_scn("G-DATA", "guard: the loading session's writes left DATA (0x55) in block 10: must refuse");
		launch(0);
		settle_boot;
		cpu_killed = 0;
		cpu_step = 1; cpu_flash(1, 10);
		cpu_step = 2; cpu_flash(2, B10W + 32'h0BFF);
		cpu_step = 4;
		wait_published;
		if (u_save.image_has_data !== 1'b1) fail("(setup) image_has_data is not set");
		machine_cold;
		blob_take(0);
		load_now;
		report("G-DATA");
		expect_refuse(64'h400);
		end_scn;

		// ---- G-PEND: a write lands during the drain -------------------------------
		begin_scn("G-PEND", "guard: a program lands during the drain, so a pass is owed at the decision: must refuse");
		launch(0);
		settle_boot;
		cpu_killed = 0;
		cpu_step = 1; cpu_flash(1, 10);
		cpu_step = 4;
		wait_published;
		machine_cold;
		blob_take(0);
		mark_load;
		fork
			begin
				apf_write_burst;
				repeat (BLOB_QUIET_SYS) @(posedge clk_sys);
				apf_load_cmd;
			end
			begin : prog_mid
				integer n;
				n = 0;
				while (sc_draining !== 1'b1 && n < 16000000) begin @(posedge clk_sys); n = n + 1; end
				repeat (2000) @(posedge clk_sys);
				cpu_killed = 0;
				cpu_flash(2, B10W + 32'h0200);
			end
		join
		report("G-PEND");
		if (at_pend !== 1'b1) fail("(setup) no pass owed at the decision");
		if (at_data !== 1'b0) fail("(setup) the committed image held data at the decision");
		if (at_prog !== 1'b1) fail("the program during the drain was not counted: prog_since_publish clear at the decision");
		expect_refuse(64'h400);
		end_scn;

		// ---- G-DELIV: a save file exists for this game -----------------------------
		begin_scn("G-DELIV", "guard: a .sav was delivered and applied (its block 10 erased): must refuse");
		launch(1);                          // keepbank, WAKE-LATE's published image
		settle_boot;
`ifdef NGPC_SAVE_DIAG
		if (u_save.diag_verdict !== 16'h0001) `FAIL(("(setup) boot verdict %h, want 0001 (accepted)", u_save.diag_verdict))
`endif
		if (u_save.base_q !== 1'b1 || u_save.apf_delivered !== 1'b1 || u_save.dirty0 !== 64'h400 ||
		    u_save.image_has_data !== 1'b0 || u_save.stage_pending !== 1'b0)
			`FAIL(("(setup) base %b delivered %b dirty0 %h data %b owed %b", u_save.base_q, u_save.apf_delivered,
			       u_save.dirty0, u_save.image_has_data, u_save.stage_pending))
		machine_cold;
		blob_take(0);
		load_now;
		report("G-DELIV");
		expect_refuse(64'h400);
		end_scn;

		// ---- G-OVF: the session's image never fit ----------------------------------
		begin_scn("G-OVF", "guard: the session's image overflowed (never published whole): must refuse");
		launch(0);
		settle_boot;
		cpu_step = 0;
		bios_flash_routine(B10W + 32'h0BFF);
		wait_published;
		force u_save.pack_overflow = 1'b1;
		machine_cold;
		blob_take(0);
		load_now;
		report("G-OVF");
		expect_refuse(64'h400);
		release u_save.pack_overflow;
		end_scn;

		// ---- GUARD-A: Memory load during an erase of a block the image holds -------
		begin_scn("GUARD-A", "Memory load while the game erases block 10, which the Memory's image holds: the load waits for the erase and restores the block");
		launch(0);
		settle_boot;
		cpu_killed = 0;
		cpu_step = 1; cpu_flash(1, 10);
		cpu_step = 2; cpu_flash(2, B10W + 32'h0321);
		cpu_step = 4;
		wait_published;
		if (u_save.image_has_data !== 1'b1 || u_save.dirty0 !== 64'h400)
			`FAIL(("(setup) data %b dirty0 %h", u_save.image_has_data, u_save.dirty0))
		machine_init(8'h6A);
		capturing_now = 1;
		apf_save;
		capturing_now = 0;
		if (!sv_ok) fail("(setup) the capture did not report ok");
		decode_b10;
		nb = 0;
		for (i = 0; i < B10N; i = i + 1) if (dec10[i] !== snap10[i]) nb = nb + 1;
		if (!dec_ok || nb != 0) `FAIL(("(setup) the Memory's image does not carry block 10 as captured (header ok %b, %0d words differ)", dec_ok, nb))
		blob_keep(1);
		machine_init(8'h77);                // the game moves on
		load_with_erase(6'd10);
		report("GUARD-A");
		expect_guard_waited;
		if (!ld_done) fail("the load never finished");
		if (!ld_ok) fail("the load was refused");
		if (sd_rej !== 1'b0) fail("apply_reject with state_done");
		if (u_save.diag_verdict !== 16'h8001) `FAIL(("verdict %h, want 8001 (state accepted)", u_save.diag_verdict))
		if (ld_ok) begin
			nb = restore_bad_vs_pat(8'h6A);
			if (nb != 0) `FAIL(("%0d machine entries not restored", nb))
		end
		nb = b10_vs_snap(1);
		if (nb != 0) `FAIL(("block 10 differs from the Memory's capture in %0d words (restored? erased? half-erased?)", nb))
		if (n_p2wr - p2_0 != B10N) `FAIL(("%0d flash words written by the apply, want %0d (block 10 whole)", n_p2wr - p2_0, B10N))
		if (u_save.dirty0 !== 64'h400) `FAIL(("dirty0 %h, want 400", u_save.dirty0))
		if (frozen !== 1'b0) fail("the session froze");
		wait_stager(8000000);
		if (u_save.stage_pending !== 1'b0 || cmem[stage_bank*BANKW + 8] !== 16'h0400)
			`FAIL(("after the load the stager did not publish block 10 (owed %b, committed bitmap %h)",
			       u_save.stage_pending, cmem[stage_bank*BANKW + 8]))
		end_scn;

		// ---- GUARD-B: Memory load during an erase of a block the image lacks -------
		begin_scn("GUARD-B", "Memory load while the game erases block 10, which the Memory's image does NOT hold: refused on coverage, block 10 fully erased and tracked");
		launch(0);
		settle_boot;
		cpu_killed = 0;
		cpu_step = 2; cpu_flash(2, B9W + 32'h0010);
		cpu_step = 4;
		wait_published;
		if (u_save.image_has_data !== 1'b1 || u_save.dirty0 !== 64'h200)
			`FAIL(("(setup) data %b dirty0 %h", u_save.image_has_data, u_save.dirty0))
		machine_init(8'h6B);
		apf_save;
		if (!sv_ok) fail("(setup) the capture did not report ok");
		if ({secw(5), secw(4)} !== CRC_PAC || secw(8) !== 16'h0200)
			`FAIL(("(setup) the Memory's image: crc %h%h bitmap %h, want this game's with block 9 only", secw(5), secw(4), secw(8)))
		blob_keep(2);
		machine_init(8'h78);
		if (b10_non_ff(0) != B10N) fail("(setup) block 10 is not the untouched ROM");
		load_with_erase(6'd10);
		report("GUARD-B");
		expect_guard_waited;
		if (!ld_done) fail("the load never finished");
		if (ld_ok) fail("the load was ACCEPTED over a block its image does not hold");
		if (sd_rej !== 1'b1) fail("apply_reject low with state_done");
		if (u_save.diag_verdict !== 16'h8002) `FAIL(("verdict %h, want 8002 (state refused: bitmap omits a dirty block)", u_save.diag_verdict))
		if (n_p2wr != p2_0) `FAIL(("%0d flash words written by a refused apply", n_p2wr - p2_0))
		nb = b10_non_ff(0);
		if (nb != 0) `FAIL(("block 10 is HALF-ERASED: %0d of %0d words not erased", nb, B10N))
		if (u_save.dirty0 !== 64'h600) `FAIL(("dirty0 %h, want 600: the erased block is untracked", u_save.dirty0))
		if (frozen !== 1'b0) fail("the session froze");
		wait_stager(8000000);
		if (u_save.stage_pending !== 1'b0 || cmem[stage_bank*BANKW + 8] !== 16'h0600)
			`FAIL(("the erase was not published (owed %b, committed bitmap %h, want 0600)",
			       u_save.stage_pending, cmem[stage_bank*BANKW + 8]))
		if (sdram[B9W + 32'h0010] !== (rom(B9W + 32'h0010) & 16'h55FF)) fail("block 9's save data is gone");
		end_scn;

		// ---- G-BASE: the session restored an image, then erased it -----------------
		begin_scn("G-BASE", "guard: the session accepted a state carrying this game's image (base_q), then erased that block and published: must refuse");
		launch(0);
		settle_boot;
		machine_cold;
		blob_take(1);                       // GUARD-A's Memory: block 10 with data
		load_now;
		report("G-BASE setup load");
		if (!ld_ok || u_save.base_q !== 1'b1 || u_save.apf_delivered !== 1'b0 || u_save.pre_delivered !== 1'b0)
			`FAIL(("(setup) state with an image: load %b base %b delivered %b/%b", ld_ok, u_save.base_q,
			       u_save.apf_delivered, u_save.pre_delivered))
		cpu_killed = 0;
		cpu_step = 1; cpu_flash(1, 10);
		cpu_step = 4;
		wait_published;
		if (u_save.image_has_data !== 1'b0 || u_save.stage_pending !== 1'b0 || u_save.dirty0 !== 64'h400 ||
		    u_save.pack_overflow !== 1'b0)
			`FAIL(("(setup) after the erase: data %b owed %b dirty0 %h overflow %b", u_save.image_has_data,
			       u_save.stage_pending, u_save.dirty0, u_save.pack_overflow))
		machine_cold;
		blob_take(0);
		load_now;
		report("G-BASE");
		expect_refuse(64'h400);
		end_scn;

		// ---- the follow-up: a program since the publish refuses -------------------
		scn_g_prog;
		scn_wake_prog;

		finish_run;
	end

	task finish_run;
		begin
			$display("== %0d scenario(s) run, %0d failed, %0d check(s) failed", n_scn, n_scn_fail, errors);
			if (errors == 0) begin
				$display("== ALL RC6A R1 SCENARIOS PASS");
				$finish;
			end else begin
				if (n_scn_fail == 0) fail_list = " setup";
				$display("== %0d FAILURE(S):%0s", (n_scn_fail > 0) ? n_scn_fail : errors, fail_list);
				$stop;                      // vvp -N: exit status 1
			end
		end
	endtask

	initial begin
		#(16_000_000_000.0);
		$display("== 1 FAILURE(S): WATCHDOG in %0s", scn);
		$stop;
	end

endmodule

`default_nettype wire
