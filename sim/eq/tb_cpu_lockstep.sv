// Lock-step equivalence of the whole TLCS-900/H core: upstream's t900_cpu
// (renamed *_ref by run_cpu_lockstep.sh) against the core as this port builds
// it (the t900 files listed in projects/ngpc_upstream.qip).
//
// One environment drives both cores with identical inputs. It answers the
// reference core's bus cycles; the core under test sees the same inputs, and
// every one of its outputs is compared against the reference on every clk_sys
// cycle. The first difference stops the run. As long as nothing differs, the
// environment's reactions are the same for both, so this is exact.
//
// The environment follows the fabric's bus contract (k2_soc_fabric.sv): a
// combinational bus_width8 for plan_addr, a T1 latch on `ce`, wait states
// counted in machine states, late cartridge responses in clk_sys, byte lanes
// as the BIU drives them. On top of that it injects interrupts at random
// levels, micro-DMA requests, and pauses during which the savestate tap is
// swept and some registers are rewritten, the way a savestate restore does.
// The tap address is also randomised on every cycle, so the savestate read
// port is compared continuously.
//
// Memory: 16 MiB. +mode=fuzz fills it with random bytes, so the core runs
// random instruction streams, undefined opcodes and wild vectors included.
// +mode=rom loads the BIOS at FF0000 and a cartridge at 200000 from hex files
// (+bios=, +rom=; one byte per line) and leaves the rest zero.
//
// Plusargs: +cycles=N (clk_sys cycles), +mode=fuzz|rom, +bios=, +rom=,
//           +verilator+seed+N for the random stream.

module tb_cpu_lockstep;

	// ---- clock, enable, reset ---------------------------------------------
	reg clk = 1'b0;
	always #5 clk = ~clk;

	reg        ce = 1'b0;
	reg        reset = 1'b1;
	int        ce_gap = 0;

	// ---- inputs shared by both cores --------------------------------------
	wire        bus_width8;
	wire        bus_wait_gfx;
	wire [15:0] bus_rdata;
	wire        bus_rdy;
	reg         int_req = 1'b0;
	reg  [2:0]  int_level = 3'd0;
	reg  [7:0]  int_vector = 8'd0;
	reg  [4:0]  int_id = 5'd0;
	int         int_life = 0;
	wire        halt_release = int_req;
	reg  [3:0]  dma_req = 4'd0;
	reg  [7:0]  ss_reg_addr = 8'd0;
	reg  [31:0] ss_wdata = 32'd0;
	reg         ss_wren = 1'b0;
	reg         pause_req = 1'b0;

	// ---- outputs, reference (r_) and under test (d_) ----------------------
	wire [23:0] r_plan_addr, d_plan_addr;
	wire        r_bus_req,   d_bus_req;
	wire        r_bus_we,    d_bus_we;
	wire [23:0] r_bus_addr,  d_bus_addr;
	wire [1:0]  r_bus_be,    d_bus_be;
	wire [15:0] r_bus_wdata, d_bus_wdata;
	wire        r_int_ack,   d_int_ack;
	wire [4:0]  r_int_ack_id, d_int_ack_id;
	wire [3:0]  r_dma_ack,   d_dma_ack;
	wire [3:0]  r_dma_end,   d_dma_end;
	wire        r_trace_valid, d_trace_valid;
	wire [23:0] r_trace_pc,  d_trace_pc;
	wire [15:0] r_trace_sr,  d_trace_sr;
	wire [7:0]  r_trace_f,   d_trace_f;
	wire        r_halted,    d_halted;
	wire [31:0] r_ss_rdata,  d_ss_rdata;
	wire        r_pause_ready, d_pause_ready;

	t900_cpu_ref #(.SPLIT_RF_READ(1)) u_ref
	(
		.clk(clk), .ce(ce), .reset(reset),
		.plan_addr(r_plan_addr), .bus_width8(bus_width8), .bus_wait_gfx(bus_wait_gfx),
		.bus_req(r_bus_req), .bus_we(r_bus_we), .bus_addr(r_bus_addr), .bus_be(r_bus_be),
		.bus_wdata(r_bus_wdata), .bus_rdata(bus_rdata), .bus_rdy(bus_rdy),
		.int_req(int_req), .int_level(int_level), .int_vector(int_vector), .int_id(int_id),
		.int_ack(r_int_ack), .int_ack_id(r_int_ack_id), .halt_release(halt_release),
		.dma_req(dma_req), .dma_ack(r_dma_ack), .dma_end(r_dma_end),
		.trace_valid(r_trace_valid), .trace_pc(r_trace_pc), .trace_sr(r_trace_sr),
		.trace_f(r_trace_f), .halted(r_halted),
		.ss_reg_addr(ss_reg_addr), .ss_wdata(ss_wdata), .ss_wren(ss_wren),
		.ss_rdata(r_ss_rdata), .restore_hold(1'b0), .pause_req(pause_req),
		.pause_ready(r_pause_ready)
	);

	t900_cpu #(.SPLIT_RF_READ(1)) u_dut
	(
		.clk(clk), .ce(ce), .reset(reset),
		.plan_addr(d_plan_addr), .bus_width8(bus_width8), .bus_wait_gfx(bus_wait_gfx),
		.bus_req(d_bus_req), .bus_we(d_bus_we), .bus_addr(d_bus_addr), .bus_be(d_bus_be),
		.bus_wdata(d_bus_wdata), .bus_rdata(bus_rdata), .bus_rdy(bus_rdy),
		.int_req(int_req), .int_level(int_level), .int_vector(int_vector), .int_id(int_id),
		.int_ack(d_int_ack), .int_ack_id(d_int_ack_id), .halt_release(halt_release),
		.dma_req(dma_req), .dma_ack(d_dma_ack), .dma_end(d_dma_end),
		.trace_valid(d_trace_valid), .trace_pc(d_trace_pc), .trace_sr(d_trace_sr),
		.trace_f(d_trace_f), .halted(d_halted),
		.ss_reg_addr(ss_reg_addr), .ss_wdata(ss_wdata), .ss_wren(ss_wren),
		.ss_rdata(d_ss_rdata), .restore_hold(1'b0), .pause_req(pause_req),
		.pause_ready(d_pause_ready)
	);

	// ---- memory and the address map the environment pretends to have -----
	logic [7:0] mem [0:(1 << 24) - 1];

	function automatic bit is_cart(input [23:0] a);
		return (a >= 24'h200000 && a < 24'h400000) || (a >= 24'h800000 && a < 24'hA00000);
	endfunction
	function automatic bit is_gfx(input [23:0] a);
		return a >= 24'h008000 && a < 24'h00C000;
	endfunction

	// 8-bit: the I/O page and the cartridge windows; 16-bit elsewhere.
	assign bus_width8 = (r_plan_addr < 24'h000100) || is_cart(r_plan_addr);

	// ---- the bus cycle, after k2_soc_fabric --------------------------------
	reg        cyc_active = 1'b0;
	reg        rdy_q = 1'b0;
	reg [2:0]  wcnt = 3'd0;
	int        late = 0;
	int        since = 0;

	wire cart_read = cyc_active && !r_bus_we && is_cart(r_bus_addr);
	wire resp_ok   = !cart_read || (since >= late);
	assign bus_rdy      = rdy_q && resp_ok;
	assign bus_wait_gfx = cyc_active && is_gfx(r_bus_addr) && !rdy_q;
	assign bus_rdata    = (r_bus_be == 2'b11) ? {mem[r_bus_addr | 24'd1], mem[r_bus_addr]}
	                                          : {mem[r_bus_addr], mem[r_bus_addr]};

	function automatic [2:0] pick_waits(input [23:0] a);
		if (is_gfx(a))  return 3'($urandom_range(0, 2));
		if (is_cart(a)) return 3'($urandom_range(0, 3));
		return ($urandom_range(0, 9) == 0) ? 3'($urandom_range(1, 3)) : 3'd0;
	endfunction

	// ---- run control and statistics --------------------------------------
	longint cycles = 2_000_000;
	longint cyc = 0;
	longint n_retire = 0, n_bios = 0, n_cart = 0, n_halt = 0, n_int = 0, n_dma = 0, n_pause = 0, n_sswr = 0, n_wr = 0, n_rd = 0;
	longint mismatches = 0;
	string  mode = "fuzz";

	// ---- pause and savestate sweep ----------------------------------------
	// Driven from the clocked process below as a small state machine.
	typedef enum int { P_RUN, P_WAIT, P_SWEEP, P_RELEASE } pstate_t;
	pstate_t pst = P_RUN;
	int      pause_in = 0;
	int      sweep_i = 0;
	int      sweep_wait = 0;
	bit      entered = 0;
	byte unsigned tap [$] = '{
		8'h00, 8'h01, 8'h02, 8'h03, 8'h04, 8'h05, 8'h06, 8'h07, 8'h08, 8'h09,
		8'h0A, 8'h0B, 8'h0C, 8'h0D, 8'h0E, 8'h0F, 8'h10, 8'h11, 8'h12, 8'h13,
		8'h20, 8'h21, 8'h22, 8'h30, 8'h31, 8'h32, 8'h33, 8'h34, 8'h35, 8'h36,
		8'h37, 8'h38, 8'h39, 8'h3A, 8'h3B};

	initial begin
		string f;
		if ($value$plusargs("cycles=%d", cycles)) ;
		if ($value$plusargs("mode=%s", mode)) ;
		if (mode == "rom") begin
			for (int i = 0; i < (1 << 24); i++) mem[i] = 8'h00;
			if ($value$plusargs("bios=%s", f)) $readmemh(f, mem, 24'hFF0000);
			if ($value$plusargs("rom=%s", f))  $readmemh(f, mem, 24'h200000);
		end else begin
			for (int i = 0; i < (1 << 24); i++) mem[i] = 8'($urandom);
		end
		// In rom mode the first pause comes early and starts the cartridge at the
		// entry point in its header (offset 1C), since nothing here plays the
		// video and timer hardware the BIOS waits on before it hands over.
		pause_in = (mode == "rom") ? 5_000 : $urandom_range(20_000, 200_000);
	end

	always @(posedge clk) begin
		cyc <= cyc + 1;

		// Reset for the first 64 cycles, with `ce` low throughout, as the SoC does.
		if (cyc == 64) reset <= 1'b0;

		// Machine enable: single-cycle pulses 8-24 clk_sys apart, sometimes a
		// long gap like a slow clock gear. Never two in a row.
		if (reset) begin
			ce <= 1'b0;
			ce_gap <= 16;
		end else if (ce_gap == 0) begin
			ce <= 1'b1;
			ce_gap <= ($urandom_range(0, 49) == 0) ? $urandom_range(25, 255)
			                                       : $urandom_range(7, 23);
		end else begin
			ce <= 1'b0;
			ce_gap <= ce_gap - 1;
		end

		// Bus cycle bookkeeping (clk_sys) and the CSC state machine (ce).
		since <= cyc_active ? since + 1 : 0;
		if (reset) begin
			cyc_active <= 1'b0;
			rdy_q <= 1'b0;
			wcnt <= 3'd0;
		end else if (ce) begin
			if (!cyc_active && r_bus_req) begin
				automatic logic [2:0] w = pick_waits(r_bus_addr);
				cyc_active <= 1'b1;
				wcnt  <= w;
				rdy_q <= (w == 3'd0);
				late  <= ($urandom_range(0, 3) == 0) ? $urandom_range(0, 60) : 0;
			end else if (cyc_active && rdy_q && resp_ok) begin
				if (r_bus_we) begin
					n_wr++;
					case (r_bus_be)
						2'b11: begin
							mem[r_bus_addr]          <= r_bus_wdata[7:0];
							mem[r_bus_addr | 24'd1]  <= r_bus_wdata[15:8];
						end
						2'b10:   mem[r_bus_addr] <= r_bus_wdata[15:8];
						default: mem[r_bus_addr] <= r_bus_wdata[7:0];
					endcase
				end else begin
					n_rd++;
				end
				cyc_active <= 1'b0;
				rdy_q <= 1'b0;
			end else if (cyc_active) begin
				if (wcnt != 3'd0) begin
					if (wcnt == 3'd1) begin
						wcnt <= 3'd0;
						rdy_q <= 1'b1;
					end else begin
						wcnt <= wcnt - 3'd1;
					end
				end else if (resp_ok) begin
					rdy_q <= 1'b1;
				end
			end
		end

		// Interrupts: one presented source at a time, held until acknowledged
		// or until its lifetime runs out (software cleared it, or the
		// controller's winner changed), so a masked request cannot wedge the
		// model.
		if (int_req && r_int_ack && r_int_ack_id == int_id) begin
			int_req <= 1'b0;
			n_int++;
		end else if (int_req && int_life == 0) begin
			int_req <= 1'b0;
		end else if (!int_req && !reset && $urandom_range(0, 2999) == 0) begin
			int_req    <= 1'b1;
			int_level  <= 3'($urandom_range(1, 7));
			int_vector <= 8'($urandom) & 8'hFC;
			int_id     <= 5'($urandom);
			int_life   <= $urandom_range(200, 40_000);
		end
		if (int_life > 0) int_life <= int_life - 1;

		// Micro-DMA requests: a channel stays requested until its start strobe.
		for (int n = 0; n < 4; n++) begin
			if (r_dma_ack[n]) begin
				dma_req[n] <= 1'b0;
				n_dma++;
			end else if (!reset && $urandom_range(0, 19999) == 0) begin
				dma_req[n] <= 1'b1;
			end
		end

		// trace_valid stands for a whole machine state, so count it on the tick.
		if (ce && r_trace_valid) begin
			n_retire++;
			if (r_trace_pc >= 24'hFF0000) n_bios++;
			else if (is_cart(r_trace_pc)) n_cart++;
		end
		if (ce && r_halted) n_halt++;

		// Pauses with a savestate sweep; otherwise a random tap address.
		ss_wren <= 1'b0;
		case (pst)
			P_RUN: begin
				ss_reg_addr <= tap[$urandom_range(0, tap.size() - 1)];
				if (!reset && pause_in == 0) begin
					pause_req <= 1'b1;
					pst <= P_WAIT;
				end else if (pause_in > 0) begin
					pause_in <= pause_in - 1;
				end
			end
			P_WAIT: if (r_pause_ready) begin
				n_pause++;
				sweep_i <= 0;
				sweep_wait <= 0;
				pst <= P_SWEEP;
			end
			P_SWEEP: begin
				// Present each tap address for two cycles (compared every cycle)
				// and rewrite some of the state, the way a restore does: about a
				// third of the registers, sometimes the PC, usually SR with an
				// interrupt mask below 7 (reset leaves 7, which shuts out both
				// maskable interrupts and micro-DMA), sometimes the halt and
				// nesting state, and the DMA channel registers.
				if (sweep_wait == 0) begin
					ss_reg_addr <= tap[sweep_i];
					sweep_wait <= 1;
				end else begin
					automatic byte unsigned t = tap[sweep_i];
					automatic int r = $urandom_range(0, 99);
					automatic logic [31:0] v = $urandom;
					automatic bit w = 0;
					if (t < 8'h14)        w = (r < 33);
					else if (t == 8'h20) begin
						w = (r < 25) && (mode != "rom");   // keep real code running
						if (mode == "rom" && !entered) begin
							w = 1;
							v = {8'd0, mem[24'h20001E], mem[24'h20001D], mem[24'h20001C]};
							entered = 1;
						end
					end
					else if (t == 8'h21) begin
						w = (r < 60);
						if ($urandom_range(0, 9) != 0) v[14:12] = 3'($urandom_range(0, 6));
					end
					else if (t == 8'h22) begin
						w = (r < 10);
						v[15:0] = 16'($urandom_range(0, 3));
					end
					else                  w = (r < 30);
					if (w) begin
						ss_wdata <= v;
						ss_wren  <= 1'b1;
						n_sswr++;
					end
					sweep_wait <= 0;
					if (sweep_i == tap.size() - 1)
						pst <= P_RELEASE;
					else
						sweep_i <= sweep_i + 1;
				end
			end
			P_RELEASE: begin
				pause_req <= 1'b0;
				pause_in <= $urandom_range(20_000, 200_000);
				pst <= P_RUN;
			end
		endcase

		if (cyc >= cycles) begin
			$display("mode %s: %0d cycles, %0d retired (%0d in BIOS, %0d in cartridge), %0d halted states, %0d reads, %0d writes, %0d interrupts, %0d dma starts, %0d pauses, %0d tap writes",
				mode, cyc, n_retire, n_bios, n_cart, n_halt, n_rd, n_wr, n_int, n_dma, n_pause, n_sswr);
			$display("LOCKSTEP EQUIVALENT");
			$finish;
		end
	end

	// ---- the comparison ---------------------------------------------------
	`define CMP(sig) if (r_``sig !== d_``sig) begin \
		$display("MISMATCH cycle %0d: %s ref %h dut %h", cyc, `"sig`", r_``sig, d_``sig); \
		bad = 1; end

	always @(negedge clk) begin
		automatic bit bad = 0;
		`CMP(plan_addr)
		`CMP(bus_req)
		`CMP(bus_we)
		`CMP(bus_addr)
		`CMP(bus_be)
		`CMP(bus_wdata)
		`CMP(int_ack)
		`CMP(int_ack_id)
		`CMP(dma_ack)
		`CMP(dma_end)
		`CMP(trace_valid)
		`CMP(trace_pc)
		`CMP(trace_sr)
		`CMP(trace_f)
		`CMP(halted)
		`CMP(ss_rdata)
		`CMP(pause_ready)
		if (bad) begin
			$display("  at ref PC %h, %0d instructions retired, tap address %h", r_trace_pc, n_retire, ss_reg_addr);
			$display("LOCKSTEP DIFFERS");
			$finish;
		end
	end

endmodule
