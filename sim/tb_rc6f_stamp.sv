// tb_rc6f_stamp -- rc6 family F: the load diagnostic the savestate bridge
// stamps into pad word 8419 of every capture.
//
// REAL, compiled unmodified: target/pocket/ngpc_savestate_bridge.sv (rc6) and
// upstream/rtl/Savestates/savestates.sv. With +define+RC6F_RC5 the same bench
// drives sim/tb_rc6f_rc5_bridge.sv instead (the rc5 bridge, git show
// ca02563:target/pocket/ngpc_savestate_bridge.sv, which has no save_busy_i
// port) -- the comparison build: its load decisions and its captures (every
// word but 8419) must be identical to rc6's, and it must fail the stamp
// checks. MODELED as in sim/tb_savestate_bridge.sv: the machine behind the
// engine, APF's bridge bus (lagged write bursts, linear readout) and the cart
// copier, which gains the three endings of a real drain: drained and applied,
// drained and refused (cart_load_error), and the stager timeout (error
// without ever moving cart_img_rd_addr) -- plus a drain cut by a reset, which
// returns its read address to 0 as ngpc_state_cart does since the rc6
// follow-up. The save engine's boot_hold_o and busy_o are modeled by two
// modes that can follow the bridge's own state, so the bench can tell WHEN
// they are sampled; save_busy_i is wired as target/pocket/ngpc_machine.sv
// wires save_busy_state: boot_hold_o (the rc6 follow-up), or busy_o under
// +define+RC6F_SBI_BUSY. run_rc6_stamp.sh reads which one from that file
// (sim/tb_rc6f_mkheld.py --wiring), so a mutant of ngpc_machine.sv that wires
// busy_o back fails group 4 (H6, H7). The real copier's half of C3 is
// sim/tb_rc6f_held.sv's C3-REAL. One deposit into the real bridge: C3's cut
// transfer never finishes, and the half second before the next transfer on
// the device is fast-forwarded by setting dut.xfer_idle 16 clocks short of
// its XFER_ABANDONED backstop, which then rewinds wr_ptr itself.
//
// Every capture is read out whole through the APF read path, word 8419 is
// checked against the scenario, the identity block 8420..8423 against rc5's
// format, and the blob is written to <OUT>/g<group>_<name>.hex for
// sim/tb_rc6f_check.py (the .sta files, tools/savinfo.py and the rc5
// comparison). Every load prints one decision line (RC6F DEC ...): verdict,
// failure pulses, frozen, whether the copier and the engine were started,
// the clk_sys cycles from the identity check to the verdict, and what became
// of the machine and the drained cart section.
//
// +GROUP=n picks one of six independent groups; each starts from reset with
// A0 (a capture with no load: D1000000), which is also its good state:
//   1  A0 A1 F1 F1b F2 F3      no load; restores (held, frozen, re-stamp)
//   2  E1 D1 D2 C1 C2 C4 C3    engine refusal, apply refusal, copier timeout;
//                              C3: a reset cuts a drain at section word 1,
//                              then a timeout -- not drained
//   3  B1..B8                  the identity gate, one term at a time
//   4  H1..H7                  held: boot_hold_o sampled at the check; H6/H7
//                              a background staging pass (busy_o without
//                              the hold) is not held
//   5  Q1..Q18                 one session: clears at every load, saturation
//   6  S1..S5                  junk in the pad words changes nothing
// Word 8419 = {8'hD1, loads[3:0], ran, ok, chk[4:0], frozen, drained, held,
// 10'd0}, chk = {blob_full, magic, crc, layout 2/3, ~crc}, 1 = passed.
// +STOPFAIL ends the run at the first failure (the mutant runs).
// Each group ends "== RC6F GROUP n PASS (k scenarios)" or
// "== RC6F GROUP n: m FAILURE(S)".
//
// Run: wsl -e sh sim/run_rc6_stamp.sh   (needs
// sim/tb_rc6f_out/sav_img.hex from sim/tb_rc6f_mkimg.py, which it makes)

`timescale 1ns / 1ps
`default_nettype none

module tb_rc6f_stamp;

	reg clk_sys = 0;
	reg clk_74a = 0;
	always #10.173 clk_sys = ~clk_sys;   // 49.152 MHz
	always #6.734  clk_74a = ~clk_74a;   // 74.25 MHz

	reg reset = 1;

	// ---- geometry (ngpc_machine's engine config, as tb_savestate_bridge) ---
	localparam integer N_INT   = 112;
	localparam integer SZ0     = 12288;
	localparam integer SZ1     = 4096;
	localparam integer SZ2     = 16384;
	localparam integer CARTB   = 8424;
	localparam integer CARTW   = 16256;
	localparam integer WORDS   = CARTB + CARTW;
	localparam [31:0]  BLOBBASE  = 32'h40000000;
	localparam [31:0]  CRC_OK    = 32'h94B63A97;   // the cartridge (and the .sav's ROM CRC)
	localparam [31:0]  CRC_OTHER = 32'h0BAD0C2C;   // another cartridge
	localparam [31:0]  ID_MAGIC  = 32'h4E475053;
	localparam [31:0]  HDR_BAD   = 32'hE1200000;   // the engine's size word, damaged
	localparam [31:0]  PAD_JUNK  = 32'h5A5A1234;   // word 8419 of every image loaded
	localparam integer TMO_CYC   = 600;            // the copier's modeled stager timeout

	// bridge sequencer states (identical in rc5 and rc6)
	localparam [3:0] S_LOAD_WAIT = 4'd3, S_LOAD_CHECK = 4'd4, S_LOAD_RUN = 4'd5,
	                 S_DONE = 4'd6, S_LOAD_CART = 4'd8;

	// ---- the machine model -------------------------------------------------
	reg [63:0] internals [0:N_INT];
	reg [63:0] internals_gold [0:N_INT];
	reg [7:0]  mem0 [0:SZ0-1];  reg [7:0] mem0_gold [0:SZ0-1];
	reg [7:0]  mem1 [0:SZ1-1];  reg [7:0] mem1_gold [0:SZ1-1];
	reg [7:0]  mem2 [0:SZ2-1];  reg [7:0] mem2_gold [0:SZ2-1];
	reg [31:0] sav_img [0:CARTW-1];      // the save image a capture carries
	reg [31:0] sav_rd  [0:CARTW-1];      // what the copier drained on a load

	wire [63:0] eng_bus_din;
	wire  [9:0] eng_bus_adr;
	wire        eng_bus_wren;
	wire        eng_bus_rst;
	wire [63:0] eng_bus_dout = internals[eng_bus_adr];

	wire [24:0] ram_addr;
	wire        ram_rden, ram_wren;
	wire  [7:0] ram_wdata;
	wire  [2:0] ram_type;
	reg   [7:0] ram_rdata_q, ram_rdata_q2;
	wire  [7:0] ram_rdata = ram_rdata_q2;

	always @(posedge clk_sys) begin
		case (ram_type)
			3'd0: ram_rdata_q <= mem0[ram_addr[13:0]];
			3'd1: ram_rdata_q <= mem1[ram_addr[11:0]];
			default: ram_rdata_q <= mem2[ram_addr[13:0]];
		endcase
		ram_rdata_q2 <= ram_rdata_q;
		if (ram_wren) begin
			case (ram_type)
				3'd0: mem0[ram_addr[13:0]] <= ram_wdata;
				3'd1: mem1[ram_addr[11:0]] <= ram_wdata;
				default: mem2[ram_addr[13:0]] <= ram_wdata;
			endcase
		end
		if (eng_bus_wren) internals[eng_bus_adr] <= eng_bus_din;
	end

	wire eng_pause_req;
	reg  [2:0] pause_pipe = 0;
	always @(posedge clk_sys) pause_pipe <= {pause_pipe[1:0], eng_pause_req};
	wire paused = pause_pipe[2];

	wire [63:0] bus_out_Din, bus_out_Dout;
	wire [25:0] bus_out_Adr;
	wire        bus_out_rnw, bus_out_ena, bus_out_done;
	wire  [7:0] bus_out_be;
	wire        ss_save, ss_load, ss_busy, ss_loading;

	savestates #(
		.STATESIZE_PARAM      (8416),
		.SETTLECOUNT_PARAM    (16),
		.INTERNALSCOUNT_PARAM (N_INT),
		.SAVETYPESCOUNT_PARAM (3),
		.SAVETYPE0_SIZE       (SZ0),
		.SAVETYPE1_SIZE       (SZ1),
		.SAVETYPE2_SIZE       (SZ2),
		.SAVETYPE3_SIZE       (0)
	) engine (
		.clk(clk_sys), .reset_in(reset), .reset_ss(), .reset_delay(),
		.restore_begin(), .load_done(),
		.restore_prepare_ready_i(1'b1), .restore_prepare_failed_i(1'b0),
		.increaseSSHeaderCount(1'b0),
		.save(ss_save), .load(ss_load),
		.state_size_i(32'd8416), .savetype3_size_i(25'd0), .is_rewind_i(1'b0),
		.savestate_address(0), .savestate_busy(ss_busy), .paused(paused),
		.BUS_Din(eng_bus_din), .BUS_Adr(eng_bus_adr), .BUS_wren(eng_bus_wren),
		.BUS_rst(eng_bus_rst), .BUS_Dout(eng_bus_dout),
		.loading_savestate(ss_loading), .saving_savestate(), .sleep_savestate(eng_pause_req),
		.Save_RAMAddr(ram_addr), .Save_RAMRdEn(ram_rden), .Save_RAMWrEn(ram_wren),
		.Save_RAMWriteData(ram_wdata), .Save_RAMReadData(ram_rdata),
		.Save_RAMReady(1'b1), .Save_RAMType(ram_type),
		.bus_out_Din(bus_out_Din), .bus_out_Dout(bus_out_Dout), .bus_out_Adr(bus_out_Adr),
		.bus_out_rnw(bus_out_rnw), .bus_out_ena(bus_out_ena), .bus_out_be(bus_out_be),
		.bus_out_done(bus_out_done)
	);

	// ---- APF side ----------------------------------------------------------
	reg         bridge_wr = 0, bridge_rd = 0;
	reg  [31:0] bridge_addr = 32'hF8000000;
	reg  [31:0] bridge_wr_data = 0;
	wire [31:0] bridge_rd_data;

	reg  ss_start_req = 0, ss_load_req = 0;
	reg  [31:0] tb_cart_crc = CRC_OK;
	wire start_ack, start_busy, start_ok, start_err;
	wire load_ack,  load_busy,  load_ok,  load_err;

	// ---- copier port and knobs ---------------------------------------------
	wire        cart_save_req, cart_load_req;
	reg         cart_save_done = 0, cart_load_done = 0;
	reg         cart_load_error = 0;
	reg         cart_img_wr = 0;
	reg  [13:0] cart_img_addr = 0;
	reg  [31:0] cart_img_data = 0;
	reg  [13:0] cart_img_rd_addr = 0;    // power-up zero, as on the device
	wire [31:0] cart_img_rd_data;
	reg         frozen_in = 0;           // the save engine's freeze, for captures
	wire        load_frozen, load_fail;

	// copier_mode: 0 drain and apply, 1 drain and refuse, 2 stager timeout,
	// 3 the drain stops after presenting section word 1 (a reset cuts it)
	integer copier_mode = 0;
	// The save engine during a load (modeled):
	// held_mode, its boot_hold_o -- the boot apply holds the machine:
	//   0 low   1 high   2 high only in S_LOAD_CHECK   3 high only in
	//   S_LOAD_WAIT (falls before the check)   4 high only after the check
	// pass_mode, a background staging pass -- busy_o high, boot_hold_o low:
	//   0 none   1 throughout the load   2 only in S_LOAD_CHECK
	// busy_o is high whenever boot_hold_o is (ngpc_cart_save's S_IDLE raises
	// both for the hold, busy_o alone for a pass).
	integer held_mode = 0;
	integer pass_mode = 0;
	wire eng_boot_hold = (held_mode == 1)
	              || (held_mode == 2 && dut.state == S_LOAD_CHECK)
	              || (held_mode == 3 && dut.state == S_LOAD_WAIT)
	              || (held_mode == 4 && (dut.state == S_LOAD_CART || dut.state == S_LOAD_RUN));
	wire eng_busy = eng_boot_hold || (pass_mode == 1)
	              || (pass_mode == 2 && dut.state == S_LOAD_CHECK);
	// save_busy_i: ngpc_machine's save_busy_state, as run_rc6_stamp.sh read it
	// from target/pocket/ngpc_machine.sv
`ifdef RC6F_SBI_BUSY
	wire save_busy = eng_busy;
`else
	wire save_busy = eng_boot_hold;
`endif

	ngpc_savestate_bridge dut (
		.clk_sys(clk_sys), .clk_74a(clk_74a), .reset(reset),
		.savestate_start(ss_start_req), .savestate_start_ack(start_ack),
		.savestate_start_busy(start_busy), .savestate_start_ok(start_ok),
		.savestate_start_err(start_err),
		.savestate_load(ss_load_req), .savestate_load_ack(load_ack),
		.savestate_load_busy(load_busy), .savestate_load_ok(load_ok),
		.savestate_load_err(load_err),
		.bridge_wr(bridge_wr), .bridge_rd(bridge_rd),
		.bridge_addr(bridge_addr), .bridge_wr_data(bridge_wr_data),
		.bridge_rd_data(bridge_rd_data),
		.ss_save(ss_save), .ss_load(ss_load), .ss_busy(ss_busy), .ss_loading(ss_loading),
		.cart_crc32(tb_cart_crc),
		.cart_save_req(cart_save_req), .cart_save_done(cart_save_done),
		.cart_img_wr(cart_img_wr), .cart_img_addr(cart_img_addr), .cart_img_data(cart_img_data),
		.cart_load_req(cart_load_req), .cart_load_done(cart_load_done),
		.cart_load_error(cart_load_error),
		.frozen_i(frozen_in), .load_frozen_o(load_frozen), .load_fail_o(load_fail),
`ifndef RC6F_RC5
		.save_busy_i(save_busy),
`endif
		.cart_img_rd_addr(cart_img_rd_addr), .cart_img_rd_data(cart_img_rd_data),
		.bus_out_Din(bus_out_Din), .bus_out_Dout(bus_out_Dout),
		.bus_out_Adr(bus_out_Adr), .bus_out_rnw(bus_out_rnw),
		.bus_out_ena(bus_out_ena), .bus_out_be(bus_out_be),
		.bus_out_done(bus_out_done)
	);

	// ---- the copier model ----------------------------------------------------
	// Save: streams sav_img into the section. Load: drains the section word by
	// word (address, three cycles, sample -- the port's contract) and answers
	// done, with error in mode 1; in mode 2 it answers error after TMO_CYC
	// without presenting a single address, as ngpc_state_cart's I_DR_WAIT
	// timeout does; in mode 3 it stops at word 1 until a reset cuts it. A
	// reset stops whatever it is doing and returns the read address to 0, as
	// ngpc_state_cart's reset does since the rc6 follow-up.
	integer ci;
	always @(posedge clk_sys) begin : copier
		cart_save_done  <= 0;
		cart_load_done  <= 0;
		cart_load_error <= 0;
		cart_img_wr     <= 0;
		if (cart_save_req) begin
			for (ci = 0; ci < CARTW; ci = ci + 1) begin
				@(posedge clk_sys);
				cart_img_wr   <= 1;
				cart_img_addr <= ci[13:0];
				cart_img_data <= sav_img[ci];
				@(posedge clk_sys);
				cart_img_wr <= 0;
			end
			@(posedge clk_sys);
			cart_save_done <= 1;
		end
		if (cart_load_req) begin
			if (copier_mode == 2) begin
				repeat (TMO_CYC) @(posedge clk_sys);
				cart_load_error <= 1;
				cart_load_done  <= 1;
			end else begin
				for (ci = 0; ci < CARTW; ci = ci + 1) begin
					@(posedge clk_sys);
					cart_img_rd_addr <= ci[13:0];
					repeat (3) @(posedge clk_sys);
					sav_rd[ci] = cart_img_rd_data;
					if (copier_mode == 3 && ci == 1) begin
						wait (reset === 1'b1);
						disable copier;
					end
				end
				@(posedge clk_sys);
				cart_load_error <= (copier_mode == 1);
				cart_load_done  <= 1;
			end
		end
	end
	always @(posedge clk_sys) if (reset) begin
		disable copier;
		cart_img_rd_addr <= 14'd0;
	end

	// ---- per-load monitors -------------------------------------------------
	reg     mon_clr = 0;
	reg     mon_cnt = 0;
	integer mon_fail = 0, mon_creq = 0, mon_ssload = 0, mon_cyc = 0, mon_c2d = -1;
	always @(posedge clk_sys) begin
		if (mon_clr) begin
			mon_fail = 0; mon_creq = 0; mon_ssload = 0;
			mon_cyc = 0; mon_c2d = -1; mon_cnt = 0; mon_clr = 0;
		end else begin
			if (load_fail)     mon_fail   = mon_fail + 1;
			if (cart_load_req) mon_creq   = mon_creq + 1;
			if (ss_load)       mon_ssload = mon_ssload + 1;
			if (mon_cnt) begin
				mon_cyc = mon_cyc + 1;
				if (dut.state == S_DONE) begin mon_cnt = 0; mon_c2d = mon_cyc; end
			end else if (mon_c2d < 0 && dut.state == S_LOAD_CHECK) begin
				mon_cnt = 1; mon_cyc = 0;
			end
		end
	end

	// ---- machine helpers -----------------------------------------------------
	reg [31:0] image [0:WORDS-1];      // what APF writes on a load
	reg [31:0] good  [0:WORDS-1];      // the group's first capture: a good state
	reg [31:0] cap   [0:WORDS-1];      // the latest capture
	integer burst_limit = WORDS;

	task machine_init;
		integer i;
		begin
			for (i = 0; i <= N_INT; i = i + 1) begin
				internals[i] = {8'hA5, i[7:0], 8'h5A, ~i[7:0], i[15:0], ~i[15:0]};
				internals_gold[i] = internals[i];
			end
			for (i = 0; i < SZ0; i = i + 1) begin mem0[i] = i[7:0] ^ 8'hC3; mem0_gold[i] = mem0[i]; end
			for (i = 0; i < SZ1; i = i + 1) begin mem1[i] = (i[7:0] * 7) + 8'h11; mem1_gold[i] = mem1[i]; end
			for (i = 0; i < SZ2; i = i + 1) begin mem2[i] = i[7:0] + i[11:4]; mem2_gold[i] = mem2[i]; end
		end
	endtask

	task machine_corrupt;
		integer i;
		begin
			for (i = 0; i <= N_INT; i = i + 1) internals[i] = 64'hDEADBEEF_DEADBEEF;
			for (i = 0; i < SZ0; i = i + 1) mem0[i] = 8'hFF;
			for (i = 0; i < SZ1; i = i + 1) mem1[i] = 8'hFF;
			for (i = 0; i < SZ2; i = i + 1) mem2[i] = 8'hFF;
			for (i = 0; i < CARTW; i = i + 1) sav_rd[i] = 32'hCCCCCCCC;
		end
	endtask

	// 0: the gold machine (restored)  1: the corrupt pattern (untouched)  2: other
	task machine_state(output integer st);
		integer i, g, u;
		begin
			g = 1; u = 1;
			for (i = 0; i < N_INT; i = i + 1) begin
				if (internals[i] !== internals_gold[i]) g = 0;
				if (internals[i] !== 64'hDEADBEEF_DEADBEEF) u = 0;
			end
			for (i = 0; i < SZ0; i = i + 1) begin
				if (mem0[i] !== mem0_gold[i]) g = 0;
				if (mem0[i] !== 8'hFF) u = 0;
			end
			for (i = 0; i < SZ1; i = i + 1) begin
				if (mem1[i] !== mem1_gold[i]) g = 0;
				if (mem1[i] !== 8'hFF) u = 0;
			end
			for (i = 0; i < SZ2; i = i + 1) begin
				if (mem2[i] !== mem2_gold[i]) g = 0;
				if (mem2[i] !== 8'hFF) u = 0;
			end
			st = g ? 0 : u ? 1 : 2;
		end
	endtask

	// ---- APF helpers (tb_savestate_bridge's bus model) -----------------------
	task apf_save_to_cap;
		integer k;
		begin
			@(posedge clk_74a); ss_start_req <= 1;
			wait (start_ack);  @(posedge clk_74a); ss_start_req <= 0;
			wait (start_ok || start_err);
			for (k = 0; k < WORDS; k = k + 1) begin
				@(posedge clk_74a); bridge_addr <= BLOBBASE | (k*4); bridge_rd <= 1;
				repeat (3) @(posedge clk_74a);
				cap[k] = bridge_rd_data;
				bridge_rd <= 0;
			end
			@(posedge clk_74a); bridge_rd <= 0; bridge_addr <= 32'hF8000000;
			// never-written words read X here; the device's RAM powers up zero
			for (k = 0; k < WORDS; k = k + 1)
				if (^cap[k] === 1'bx) cap[k] = 32'd0;
			repeat (8) @(posedge clk_74a);
		end
	endtask

	task apf_write_burst(input integer lag);
		integer k;
		reg [31:0] a;
		begin
			@(posedge clk_74a);
			for (k = 0; k < burst_limit; k = k + 1) begin
				if (lag) a = (k == 0) ? 32'hF8000050 : (BLOBBASE | ((k-1)*4));
				else     a = BLOBBASE | (k*4);
				@(posedge clk_74a);
				bridge_addr <= a; bridge_wr_data <= image[k]; bridge_wr <= 1;
				@(posedge clk_74a); bridge_wr <= 0;
				repeat (2) @(posedge clk_74a);
			end
			@(posedge clk_74a); bridge_addr <= 32'hF8000000;
		end
	endtask

	task apf_load(output integer ok);
		begin
			@(posedge clk_74a); ss_load_req <= 1;
			wait (load_ack); @(posedge clk_74a); ss_load_req <= 0;
			wait (load_ok || load_err);
			ok = load_ok ? 1 : 0;
			repeat (8) @(posedge clk_74a);
		end
	endtask

	// a new core launch: sequencer, engine and freeze start over; the blob
	// store keeps what it held (a RAM), as on the device
	task wake_reset;
		begin
			@(posedge clk_sys) reset <= 1;
			frozen_in = 0;
			held_mode = 0;
			pass_mode = 0;
			repeat (20) @(posedge clk_sys);
			reset <= 0;
			repeat (40) @(posedge clk_sys);
		end
	endtask

	// ---- scenario plumbing ---------------------------------------------------
	string  outdir;
	integer group = 0;
	integer stopfail = 0;
	integer nfail = 0, nscn = 0, serr = 0;
	string  scn_name;
	integer c2d_ref;

	function [31:0] dgw(input [3:0] loads, input ran, input ok, input [4:0] chk,
	                    input frz, input drn, input held);
		dgw = {8'hD1, loads, ran, ok, chk, frz, drn, held, 10'd0};
	endfunction

	function string fields(input [31:0] w);
		fields = $sformatf("tag=%02h loads=%0d ran=%0d ok=%0d chk=%05b frozen=%0d drained=%0d held=%0d low=%03h",
		                   w[31:24], w[23:20], w[19], w[18], w[17:13], w[12], w[11], w[10], w[9:0]);
	endfunction

	task automatic fail(input string msg);
		begin
			$display("   FAIL %s: %s", scn_name, msg);
			serr = serr + 1;
			nfail = nfail + 1;
			if (stopfail) begin
				$display("== RC6F GROUP %0d: STOPPED AT FIRST FAILURE (%s)", group, scn_name);
				$finish;
			end
		end
	endtask

	task automatic scn(input string name);
		begin
			scn_name = name;
			serr = 0;
			nscn = nscn + 1;
		end
	endtask

	task automatic scn_end;
		begin
			if (serr == 0) $display("   PASS %s", scn_name);
		end
	endtask

	task img_good;
		integer i;
		begin
			for (i = 0; i < WORDS; i = i + 1) image[i] = good[i];
			image[8419] = PAD_JUNK;    // the same in both builds (rc5 leaves it 0)
		end
	endtask

	// The next load. L_xfer: 0 no transfer (the store as it stands), 1 full
	// lagged burst, 2 full no-lag burst, 3 lagged burst stopping at word 20000.
	integer    L_xfer = 1;
	integer    L_park = -1;          // park the copier's read address first
	reg [31:0] L_crc  = CRC_OK;      // the cartridge's CRC during the load

	// x_mach: 0 restored (gold), 1 untouched
	task automatic do_load(input integer x_ok, input integer x_copier, input integer x_engine,
	                       input integer x_frozen, input integer x_mach);
		integer ok, ms, i, cerr, lerr;
		string cs, ms_s, xm_s;
		begin
			machine_corrupt;
			if (L_xfer != 0) begin
				burst_limit = (L_xfer == 3) ? 20000 : WORDS;
				apf_write_burst(L_xfer != 2);
				burst_limit = WORDS;
			end
			if (L_park >= 0) cart_img_rd_addr = L_park[13:0];
			tb_cart_crc = L_crc;
			@(posedge clk_sys); mon_clr = 1;
			@(posedge clk_sys); @(posedge clk_sys);
			apf_load(ok);
			tb_cart_crc = CRC_OK;
			lerr = load_err;
			machine_state(ms);
			cs = "-";
			cerr = 0;
			if (mon_creq != 0 && copier_mode != 2) begin
				for (i = 0; i < CARTW; i = i + 1) if (sav_rd[i] !== image[CARTB + i]) cerr = cerr + 1;
				if (cerr == 0) cs = "exact"; else cs = $sformatf("%0d-words-wrong", cerr);
			end
			if (ms == 0) ms_s = "restored"; else if (ms == 1) ms_s = "untouched"; else ms_s = "other";
			if (x_mach == 0) xm_s = "restored"; else xm_s = "untouched";
			$display("RC6F DEC %-4s ok=%0d err=%0d fail=%0d frozen=%0d copier=%0d engine=%0d chk2done=%0d mach=%s cart=%s",
			         scn_name, ok, lerr, mon_fail, load_frozen, mon_creq, mon_ssload, mon_c2d, ms_s, cs);
			if (ok != x_ok || lerr != !x_ok)
				fail($sformatf("load ok=%0d err=%0d, want ok=%0d", ok, lerr, x_ok));
			if (mon_fail != (x_ok ? 0 : 1))
				fail($sformatf("%0d load_fail_o pulses, want %0d", mon_fail, x_ok ? 0 : 1));
			if (load_frozen !== x_frozen[0])
				fail($sformatf("load_frozen_o=%0d, want %0d", load_frozen, x_frozen));
			if (mon_creq != x_copier)
				fail($sformatf("copier started %0d times, want %0d", mon_creq, x_copier));
			if (mon_ssload != x_engine)
				fail($sformatf("engine started %0d times, want %0d", mon_ssload, x_engine));
			if (ms != x_mach)
				fail($sformatf("machine %s, want %s", ms_s, xm_s));
			if (cerr != 0)
				fail($sformatf("the drained cart section has %0d words wrong", cerr));
			// the knobs apply to one load
			copier_mode = 0; held_mode = 0; pass_mode = 0; L_park = -1; L_crc = CRC_OK; L_xfer = 1;
		end
	endtask

	// A capture (Memory or sleep state) taken with frozen_i = frz; word 8419
	// must be want (0: not checked -- no stamp is 0, its tag is D1). Written
	// out for sim/tb_rc6f_check.py.
	task automatic do_cap(input [31:0] want, input integer frz);
		integer k, fd, e;
		string fn;
		begin
			frozen_in = frz[0];
			apf_save_to_cap;
			frozen_in = 0;
			$display("RC6F CAP %-4s w8419=%08h id=%08h %08h %08h %08h w8418=%08h w1=%08h",
			         scn_name, cap[8419], cap[8420], cap[8421], cap[8422], cap[8423], cap[8418], cap[1]);
			// the identity block, exactly rc5's
			if (cap[8420] !== ID_MAGIC || cap[8421] !== CRC_OK
			    || cap[8422] !== (frz ? 32'd3 : 32'd2) || cap[8423] !== ~CRC_OK)
				fail($sformatf("identity block %08h %08h %08h %08h, want %08h %08h %08h %08h",
				               cap[8420], cap[8421], cap[8422], cap[8423],
				               ID_MAGIC, CRC_OK, frz ? 32'd3 : 32'd2, ~CRC_OK));
			if (cap[1] !== 32'hE0200000)
				fail($sformatf("engine header word 1 = %08h", cap[1]));
			e = 0;
			for (k = 0; k < CARTW; k = k + 1) if (cap[CARTB + k] !== sav_img[k]) e = e + 1;
			if (e != 0) fail($sformatf("cart section: %0d words differ from the save image", e));
			if (want != 32'd0 && cap[8419] !== want)
				fail($sformatf("word 8419 = %08h (%s), want %08h (%s)",
				               cap[8419], fields(cap[8419]), want, fields(want)));
			fn = $sformatf("%s/g%0d_%s.hex", outdir, group, scn_name);
			fd = $fopen(fn, "w");
			if (fd == 0) fail($sformatf("cannot write %s", fn));
			else begin
				for (k = 0; k < WORDS; k = k + 1) $fwrite(fd, "%08h\n", cap[k]);
				$fclose(fd);
			end
		end
	endtask

	// ---- the groups ------------------------------------------------------------
	integer i, dummy;

	task preamble;
		begin
			machine_init;
			$readmemh("sim/tb_rc6f_out/sav_img.hex", sav_img);
			if (^sav_img[0] === 1'bx || ^sav_img[CARTW-1] === 1'bx) begin
				$display("== RC6F GROUP %0d: 1 FAILURE(S): sim/tb_rc6f_out/sav_img.hex missing (run sim/tb_rc6f_mkimg.py)", group);
				$finish;
			end
			repeat (20) @(posedge clk_sys);
			reset = 0;
			repeat (40) @(posedge clk_sys);
			// (a) the first capture of a session with no load: loads 0, all clear
			scn("A0");
			do_cap(32'hD100_0000, 0);
			scn_end;
			for (i = 0; i < WORDS; i = i + 1) good[i] = cap[i];
		end
	endtask

	initial begin
		if (!$value$plusargs("GROUP=%d", group)) group = 1;
		if (!$value$plusargs("OUT=%s", outdir)) outdir = "sim/tb_rc6f_out/rc6";
		if ($test$plusargs("STOPFAIL")) stopfail = 1;
		$display("== RC6F GROUP %0d start (%s)", group,
`ifdef RC6F_RC5
		         "rc5 bridge");
`else
		         "rc6 bridge");
`endif
		preamble;

		case (group)
		1: begin
			// a second capture, frozen: layout 3 in the identity block, the
			// stamp still says no load (the capture's freeze is not the bit)
			scn("A1"); do_cap(32'hD100_0000, 1); scn_end;
			// (f) a restore
			scn("F1"); wake_reset; img_good;
			do_load(1, 1, 1, 0, 0);
			do_cap(dgw(1, 1, 1, 5'b11111, 0, 1, 0), 0); scn_end;
			// the stamp is rewritten, unchanged, by a second capture
			scn("F1b"); do_cap(dgw(1, 1, 1, 5'b11111, 0, 1, 0), 1); scn_end;
			// held: the boot apply holds the machine at the check
			scn("F2"); wake_reset; img_good; held_mode = 1;
			do_load(1, 1, 1, 0, 0);
			do_cap(dgw(1, 1, 1, 5'b11111, 0, 1, 1), 0); scn_end;
			// frozen: a layout-3 state restored, captured unfrozen
			scn("F3"); wake_reset; img_good; image[8422] = 32'd3;
			do_load(1, 1, 1, 1, 0);
			do_cap(dgw(1, 1, 1, 5'b11111, 1, 1, 0), 0); scn_end;
		end
		2: begin
			// (e) the engine refuses the header (no-lag bus so the damaged size
			// word still lands at slot 1)
			scn("E1"); wake_reset; img_good; image[1] = HDR_BAD; L_xfer = 2;
			do_load(0, 1, 1, 0, 1);
			do_cap(dgw(1, 1, 0, 5'b11111, 0, 1, 0), 1); scn_end;
			// (d) the apply refuses the image
			scn("D1"); wake_reset; img_good; copier_mode = 1;
			do_load(0, 1, 0, 0, 1);
			do_cap(dgw(1, 0, 0, 5'b11111, 0, 1, 0), 1); scn_end;
			scn("D2"); wake_reset; img_good; image[8422] = 32'd3; copier_mode = 1;
			do_load(0, 1, 0, 1, 1);
			do_cap(dgw(1, 0, 0, 5'b11111, 1, 1, 0), 1); scn_end;
			// (c) the copier times out: the read address stays where the last
			// drain of the session left it (16255) or at zero (power-up, reset)
			scn("C1"); wake_reset; img_good; copier_mode = 2; L_park = CARTW - 1;
			do_load(0, 1, 0, 0, 1);
			do_cap(dgw(1, 0, 0, 5'b11111, 0, 0, 0), 1); scn_end;
			scn("C2"); wake_reset; img_good; copier_mode = 2; L_park = 0;
			do_load(0, 1, 0, 0, 1);
			do_cap(dgw(1, 0, 0, 5'b11111, 0, 0, 0), 0); scn_end;
			scn("C4"); wake_reset; img_good; image[8422] = 32'd3; copier_mode = 2; L_park = CARTW - 1;
			do_load(0, 1, 0, 1, 1);
			do_cap(dgw(1, 0, 0, 5'b11111, 1, 0, 0), 1); scn_end;
			// a reset cuts a drain right after its first word -- the read
			// address sits at 1, the address the drained bit keys on -- and
			// the next load is a copier timeout. The reset returned the
			// address to 0 (ngpc_state_cart since the rc6 follow-up, modeled
			// here; the real copier: sim/tb_rc6f_held.sv C3-REAL), so the
			// timeout reads as one: not drained. (Before, the address stayed
			// parked at 1 and the stamp read "drained, the apply refused".)
			scn("C3"); wake_reset; img_good;
			machine_corrupt;
			apf_write_burst(1);
			copier_mode = 3;
			@(posedge clk_74a); ss_load_req <= 1;
			wait (load_ack); @(posedge clk_74a); ss_load_req <= 0;
			wait (cart_img_rd_addr == 14'd1);
			repeat (4) @(posedge clk_sys);
			if (dut.state != S_LOAD_CART) fail("(bench) the cut load is not in the copier's drain");
			wake_reset;                                   // the cut
			if (cart_img_rd_addr !== 14'd0) fail("(bench) the copier model kept its read address over the reset");
			// The cut transfer never finished, so APF's write pointer
			// (clk_74a, not on the reset net) is rewound only by the
			// bridge's half-second idle backstop -- long past by the next
			// transfer on the device. Fast-forward the idle count to its last
			// 16 clocks and let the RTL's own backstop do it.
			@(negedge clk_74a) dut.xfer_idle = 26'd37_000_000 - 26'd16;
			repeat (40) @(posedge clk_74a);
			if (dut.wr_ptr !== 15'd0) fail("(bench) the bridge's write pointer did not rewind after the cut transfer");
			img_good; copier_mode = 2;
			do_load(0, 1, 0, 0, 1);
			do_cap(dgw(1, 0, 0, 5'b11111, 0, 0, 0), 0); scn_end;
		end
		3: begin
			// (b) the identity gate, each term alone, then all at once
			scn("B1"); wake_reset; img_good; L_xfer = 3;                       // short transfer
			do_load(0, 0, 0, 0, 1);
			do_cap(dgw(1, 0, 0, 5'b01111, 0, 0, 0), 0); scn_end;
			scn("B2"); wake_reset; img_good; image[8420] = image[8420] ^ 32'h1;  // magic
			do_load(0, 0, 0, 0, 1);
			do_cap(dgw(1, 0, 0, 5'b10111, 0, 0, 0), 1); scn_end;
			scn("B3"); wake_reset; img_good; image[8421] = image[8421] ^ 32'h100; // crc word
			do_load(0, 0, 0, 0, 1);
			do_cap(dgw(1, 0, 0, 5'b11011, 0, 0, 0), 0); scn_end;
			scn("B4"); wake_reset; img_good; image[8422] = 32'd1;              // layout 1 (pre-rc3)
			do_load(0, 0, 0, 0, 1);
			do_cap(dgw(1, 0, 0, 5'b11101, 0, 0, 0), 1); scn_end;
			scn("B4c"); wake_reset; img_good; image[8422] = 32'd4;             // layout 4
			do_load(0, 0, 0, 0, 1);
			do_cap(dgw(1, 0, 0, 5'b11101, 0, 0, 0), 0); scn_end;
			scn("B5"); wake_reset; img_good; image[8423] = image[8423] ^ 32'h80000000; // ~crc
			do_load(0, 0, 0, 0, 1);
			do_cap(dgw(1, 0, 0, 5'b11110, 0, 0, 0), 0); scn_end;
			scn("B6"); wake_reset; img_good; L_xfer = 3;                       // all five
			image[8420] = 32'h0; image[8421] = 32'h12345678; image[8422] = 32'd9; image[8423] = 32'h0;
			do_load(0, 0, 0, 0, 1);
			do_cap(dgw(1, 0, 0, 5'b00000, 0, 0, 0), 0); scn_end;
			scn("B7"); wake_reset; img_good; L_crc = CRC_OTHER;                // another cartridge
			do_load(0, 0, 0, 0, 1);
			do_cap(dgw(1, 0, 0, 5'b11010, 0, 0, 0), 0); scn_end;
			scn("B8"); wake_reset; img_good; image[8422] = 32'd3;              // layout 3, bad magic
			image[8420] = image[8420] ^ 32'h1;
			do_load(0, 0, 0, 0, 1);
			do_cap(dgw(1, 0, 0, 5'b10111, 0, 0, 0), 0); scn_end;
		end
		4: begin
			// held follows boot_hold_o (save_busy_i) AT the check, not before or after it
			scn("H1"); wake_reset; img_good; image[8420] = image[8420] ^ 32'h1; held_mode = 2;
			do_load(0, 0, 0, 0, 1);
			do_cap(dgw(1, 0, 0, 5'b10111, 0, 0, 1), 0); scn_end;
			scn("H2"); wake_reset; img_good; image[8420] = image[8420] ^ 32'h1; held_mode = 3;
			do_load(0, 0, 0, 0, 1);
			do_cap(dgw(1, 0, 0, 5'b10111, 0, 0, 0), 0); scn_end;
			scn("H3"); wake_reset; img_good; held_mode = 4;
			do_load(1, 1, 1, 0, 0);
			do_cap(dgw(1, 1, 1, 5'b11111, 0, 1, 0), 0); scn_end;
			scn("H4"); wake_reset; img_good; held_mode = 2;
			do_load(1, 1, 1, 0, 0);
			do_cap(dgw(1, 1, 1, 5'b11111, 0, 1, 1), 0); scn_end;
			scn("H5"); wake_reset; img_good; held_mode = 1; copier_mode = 2; L_park = CARTW - 1;
			do_load(0, 1, 0, 0, 1);
			do_cap(dgw(1, 0, 0, 5'b11111, 0, 0, 1), 1); scn_end;
			// a background staging pass is not the hold: busy_o high and
			// boot_hold_o low at the check -- held 0 (busy_o wired to
			// save_busy_i, ngpc_machine before the follow-up, stamps 1)
			scn("H6"); wake_reset; img_good; image[8420] = image[8420] ^ 32'h1; pass_mode = 2;
			do_load(0, 0, 0, 0, 1);
			do_cap(dgw(1, 0, 0, 5'b10111, 0, 0, 0), 0); scn_end;
			scn("H7"); wake_reset; img_good; pass_mode = 1;
			do_load(1, 1, 1, 0, 0);
			do_cap(dgw(1, 1, 1, 5'b11111, 0, 1, 0), 0); scn_end;
		end
		5: begin
			// one session: every load clears what the last one set, the count
			// saturates at 15 and the other fields keep working past it
			wake_reset;
			scn("Q1"); img_good; held_mode = 1;
			do_load(1, 1, 1, 0, 0);
			do_cap(dgw(1, 1, 1, 5'b11111, 0, 1, 1), 0); scn_end;
			scn("Q2"); L_xfer = 0;                        // no transfer: blob_full clear
			do_load(0, 0, 0, 0, 1);
			do_cap(dgw(2, 0, 0, 5'b01111, 0, 0, 0), 0); scn_end;
			scn("Q3"); img_good;
			do_load(1, 1, 1, 0, 0);
			do_cap(dgw(3, 1, 1, 5'b11111, 0, 1, 0), 0); scn_end;
			scn("Q4"); img_good; copier_mode = 2;         // address left at 16255 by Q3
			do_load(0, 1, 0, 0, 1);
			do_cap(dgw(4, 0, 0, 5'b11111, 0, 0, 0), 1); scn_end;
			scn("Q5"); img_good; copier_mode = 1;
			do_load(0, 1, 0, 0, 1);
			do_cap(dgw(5, 0, 0, 5'b11111, 0, 1, 0), 1); scn_end;
			scn("Q6"); img_good; image[1] = HDR_BAD; L_xfer = 2;
			do_load(0, 1, 1, 0, 1);
			do_cap(dgw(6, 1, 0, 5'b11111, 0, 1, 0), 1); scn_end;
			scn("Q7"); img_good; image[8422] = 32'd3;
			do_load(1, 1, 1, 1, 0);
			do_cap(dgw(7, 1, 1, 5'b11111, 1, 1, 0), 0); scn_end;
			scn("Q8"); img_good; image[8420] = image[8420] ^ 32'h1;
			do_load(0, 0, 0, 0, 1);
			do_cap(dgw(8, 0, 0, 5'b10111, 0, 0, 0), 0); scn_end;
			// loads 9..14 without a transfer: blob_full is clear; the store holds
			// Q8's capture, whose stamp rewrote a good identity block over Q8's image
			scn("Q14");
			for (dummy = 9; dummy <= 14; dummy = dummy + 1) begin
				L_xfer = 0;
				do_load(0, 0, 0, 0, 1);
			end
			do_cap(dgw(14, 0, 0, 5'b01111, 0, 0, 0), 0); scn_end;
			scn("Q15"); L_xfer = 0;
			do_load(0, 0, 0, 0, 1);
			do_cap(dgw(15, 0, 0, 5'b01111, 0, 0, 0), 0); scn_end;
			scn("Q16"); img_good; held_mode = 1;           // load 16: saturated
			do_load(1, 1, 1, 0, 0);
			do_cap(dgw(15, 1, 1, 5'b11111, 0, 1, 1), 0); scn_end;
			scn("Q17"); L_xfer = 0;                        // load 17
			do_load(0, 0, 0, 0, 1);
			do_cap(dgw(15, 0, 0, 5'b01111, 0, 0, 0), 0); scn_end;
			// a reset clears it all
			scn("Q18"); wake_reset;
			do_cap(32'hD100_0000, 0); scn_end;
		end
		6: begin
			// the pad words a loaded state carries decide nothing: the same
			// restore with four different 8419 (and 8418) contents
			scn("S1"); wake_reset; img_good; image[8419] = 32'h0;
			do_load(1, 1, 1, 0, 0);
			c2d_ref = mon_c2d;
			do_cap(dgw(1, 1, 1, 5'b11111, 0, 1, 0), 0); scn_end;
			scn("S2"); wake_reset; img_good; image[8419] = 32'hFFFFFFFF;
			do_load(1, 1, 1, 0, 0);
			if (mon_c2d != c2d_ref) fail($sformatf("check-to-verdict %0d cycles, S1 took %0d", mon_c2d, c2d_ref));
			do_cap(dgw(1, 1, 1, 5'b11111, 0, 1, 0), 0); scn_end;
			scn("S3"); wake_reset; img_good; image[8419] = 32'hD1FFFC00;  // a stamp that says everything
			do_load(1, 1, 1, 0, 0);
			if (mon_c2d != c2d_ref) fail($sformatf("check-to-verdict %0d cycles, S1 took %0d", mon_c2d, c2d_ref));
			do_cap(dgw(1, 1, 1, 5'b11111, 0, 1, 0), 0); scn_end;
			scn("S4"); wake_reset; img_good; image[8418] = 32'hDEADBEEF; image[8419] = 32'h12345678;
			do_load(1, 1, 1, 0, 0);
			if (mon_c2d != c2d_ref) fail($sformatf("check-to-verdict %0d cycles, S1 took %0d", mon_c2d, c2d_ref));
			do_cap(dgw(1, 1, 1, 5'b11111, 0, 1, 0), 0);
			if (cap[8418] !== 32'hDEADBEEF) fail($sformatf("pad word 8418 = %08h, the loaded DEADBEEF expected (nothing writes it)", cap[8418]));
			scn_end;
			scn("S5"); wake_reset; img_good; image[8419] = 32'hFFFFFFFF; image[8420] = image[8420] ^ 32'h1;
			do_load(0, 0, 0, 0, 1);
			do_cap(dgw(1, 0, 0, 5'b10111, 0, 0, 0), 0); scn_end;
		end
		default: begin
			$display("== RC6F GROUP %0d: 1 FAILURE(S): no such group", group);
			$finish;
		end
		endcase

		if (nfail == 0) $display("== RC6F GROUP %0d PASS (%0d scenarios)", group, nscn);
		else            $display("== RC6F GROUP %0d: %0d FAILURE(S)", group, nfail);
		$finish;
	end

	initial begin
		repeat (5) #1_000_000_000;   // 5 s of simulated time
		$display("== RC6F GROUP %0d: 1 FAILURE(S): WATCHDOG", group);
		$finish;
	end

endmodule

`default_nettype wire
