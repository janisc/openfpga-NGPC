`timescale 1ns/1ps
`default_nettype none

// Bench for ngpc_state_cart, the staging <-> blob-cart-section copier (rc4).
//
// Modeled around it: the staging PSRAM (both faces the copier uses -- the
// borrowed engine read port with ready/done pacing, and the host-write skid
// sink), the bridge's cart section (a word array serving reads with the
// bridge's 3-cycle latency and capturing writes), and the cart save engine's
// side of the handshake (stage_current, state_done, apply_reject, and the
// state_apply observer). DR_WAIT_TIMEOUT is shrunk by parameter.
//
// SCENARIOS (spec items in brackets)
//   C1 capture: staging holds a known image, stager reports current after a
//      delay -> the copier must wait, hold the machine the whole time, then
//      deliver every word to the bridge exactly once, in order, byte-exact.
//      No drain activity at all during a capture.                [Capture]
//   C2 restore: stage_current held low -> the copier waits WITHOUT raising
//      draining_o and without writing; once stage_current rises, draining_o
//      rises and the drain writes staging byte-exact through the host path
//      under real backpressure (the PSRAM is choked, then slowed, so ready
//      falls many times -- asserted; no write whose sampled ready was low,
//      none into a full skid), even if stage_current falls again mid-drain;
//      it pulses state_apply once and reports done only after state_done_i,
//      keeping draining_o high until then and low in the done cycle. [C1, C2]
//   C3 state_done arriving one cycle after the apply pulse is not missed;
//      state_done arriving thousands of cycles later is waited for.  [C2]
//   C4 cart_load_error is apply_reject_i sampled WITH state_done_i: a
//      stale reject flag that clears at state_done gives no error, a reject
//      raised at state_done gives an error.                        [C2]
//   C5 I_DR_WAIT timeout: stage_current never rises -> done with error at
//      ~DR_WAIT_TIMEOUT, nothing written, draining_o never raised, no apply;
//      the copier is idle again and the next load's wait starts a fresh
//      timeout (a 3/4-timeout wait then succeeds); the default
//      DR_WAIT_TIMEOUT is 100_000_000.                             [C1]
//   C6 diag_drain_o counts every sc_host_wr pulse since reset (checked
//      across 16-bit wrap), is untouched by capture and the timeout path,
//      and clears on reset.                                        [C3]

module tb_state_cart;

	reg clk = 0;
	always #10.173 clk = ~clk;
	reg reset = 1;

	localparam integer CARTW = 16256;
	localparam integer TO    = 3000;          // DR_WAIT_TIMEOUT for the bench

	// ---- DUT wiring --------------------------------------------------------
	reg         cart_save_req = 0, cart_load_req = 0;
	wire        cart_save_done, cart_load_done, cart_load_error;
	wire        cart_img_wr;
	wire [13:0] cart_img_addr;
	wire [31:0] cart_img_data;
	wire [13:0] cart_img_rd_addr;
	reg  [31:0] cart_img_rd_data;

	wire        sc_rd_req, sc_rd_active, sc_draining;
	wire [24:0] sc_rd_addr;
	reg         sc_rd_ready = 1, sc_rd_done = 0;
	reg  [15:0] sc_rd_data;

	reg         sc_host_ready = 1;
	wire        sc_host_wr;
	wire [24:0] sc_host_addr;
	wire [15:0] sc_host_data;

	reg         stage_current = 0;
	reg         apply_reject = 0;
	wire        state_apply;
	reg         state_done = 0;
	wire [15:0] diag_drain;
	wire        hold;

	ngpc_state_cart #(
		.DR_WAIT_TIMEOUT(TO)
	) dut (
		.clk(clk), .reset(reset),
		.cart_save_req(cart_save_req), .cart_save_done(cart_save_done),
		.cart_img_wr(cart_img_wr), .cart_img_addr(cart_img_addr),
		.cart_img_data(cart_img_data),
		.cart_load_req(cart_load_req), .cart_load_done(cart_load_done),
		.cart_load_error(cart_load_error),
		.cart_img_rd_addr(cart_img_rd_addr), .cart_img_rd_data(cart_img_rd_data),
		.sc_rd_req(sc_rd_req), .sc_rd_addr(sc_rd_addr),
		.sc_rd_ready(sc_rd_ready), .sc_rd_done(sc_rd_done),
		.sc_rd_data(sc_rd_data), .sc_rd_active(sc_rd_active),
		.draining_o(sc_draining),
		.sc_host_ready(sc_host_ready),
		.sc_host_wr(sc_host_wr), .sc_host_addr(sc_host_addr),
		.sc_host_data(sc_host_data),
		.stage_current_i(stage_current), .apply_reject_i(apply_reject),
		.state_apply_o(state_apply),
		.state_done_i(state_done),
		.diag_drain_o(diag_drain),
		.hold_o(hold)
	);

	// A second copier left at its defaults, only so C5 can check the
	// DR_WAIT_TIMEOUT the hardware gets (spec C1: 100_000_000 clk).
	ngpc_state_cart dflt (
		.clk(clk), .reset(1'b1),
		.cart_save_req(1'b0), .cart_save_done(),
		.cart_img_wr(), .cart_img_addr(), .cart_img_data(),
		.cart_load_req(1'b0), .cart_load_done(), .cart_load_error(),
		.cart_img_rd_addr(), .cart_img_rd_data(32'd0),
		.sc_rd_req(), .sc_rd_addr(), .sc_rd_ready(1'b0), .sc_rd_done(1'b0),
		.sc_rd_data(16'd0), .sc_rd_active(), .draining_o(),
		.sc_host_ready(1'b0), .sc_host_wr(), .sc_host_addr(), .sc_host_data(),
		.stage_current_i(1'b0), .apply_reject_i(1'b0), .state_apply_o(),
		.state_done_i(1'b0), .diag_drain_o(), .hold_o()
	);

	// Backpressure honesty: a 511-deep skid model whose drain stalls in
	// long bursts (a congested PSRAM). ready is the same conservative
	// fill-threshold the real stage_mem exports; the copier's ready-then-
	// write pipeline is legal because during a drain it is the only
	// writer, so fill can only fall between sample and assert. The
	// failure that must never happen is a write at TRUE full.
	//
	// The short random stalls alone never fill 508 entries (the copier
	// writes 2 words per 7 clk), so C2 also chokes the drain outright and
	// then runs it slower than the copier fills it: ready then toggles
	// around the threshold for thousands of clocks, and C2 fails if it
	// never fell.
	reg [9:0]  skid_fill = 0;
	reg [9:0]  stall_lfsr = 10'h2A5;
	reg [5:0]  drain_stall = 0;
	reg        choke = 0;              // PSRAM taking no host beats at all
	reg        slow  = 0;              // PSRAM taking one beat in four
	reg [1:0]  slow_ctr = 0;
	wire       skid_drain = (skid_fill != 0) && (drain_stall == 0) && !choke &&
	                        (!slow || slow_ctr == 2'd0);
	always @(posedge clk) begin
		slow_ctr   <= slow_ctr + 2'd1;
		stall_lfsr <= {stall_lfsr[8:0], stall_lfsr[9] ^ stall_lfsr[6]};
		if (drain_stall != 0)            drain_stall <= drain_stall - 6'd1;
		else if (stall_lfsr[3:0] == 4'h7) drain_stall <= {2'b01, stall_lfsr[7:4]};
		if (reset) begin
			skid_fill     <= 10'd0;
			sc_host_ready <= 1'b1;
		end else begin
			skid_fill <= skid_fill + ((sc_host_wr === 1'b1) ? 10'd1 : 10'd0)
			                       - ((skid_drain === 1'b1) ? 10'd1 : 10'd0);
			sc_host_ready <= (skid_fill < 10'd508);
		end
	end
	reg lost_write = 0;
	always @(posedge clk) begin
		if (sc_host_wr && skid_fill == 10'd511) lost_write <= 1;
	end
	// The copier samples ready and writes the cycle after: a write whose
	// sampled ready was low ignored the backpressure, even if the slack
	// above the threshold happened to absorb it.
	reg ready_q = 1;
	reg wr_not_ready = 0;
	integer nr_cycles = 0, nr_falls = 0, max_fill = 0;
	always @(posedge clk) begin
		if (sc_host_wr === 1'b1 && ready_q !== 1'b1) wr_not_ready <= 1;
		ready_q <= sc_host_ready;
		if (sc_draining === 1'b1 && !sc_host_ready) nr_cycles = nr_cycles + 1;
		if (sc_draining === 1'b1 && ready_q && !sc_host_ready) nr_falls = nr_falls + 1;
		if (skid_fill > max_fill) max_fill = skid_fill;
	end

	// ---- staging model: 16-bit, ready/done pacing on reads -----------------
	reg [15:0] staging [0:2*CARTW-1];
	reg [2:0]  rd_lat;
	always @(posedge clk) begin
		sc_rd_done <= 0;
		if (sc_rd_req) begin
			sc_rd_ready <= 0;
			sc_rd_data  <= staging[sc_rd_addr[24:1]];
			rd_lat      <= 3'd3;
		end else if (!sc_rd_ready) begin
			rd_lat <= rd_lat - 3'd1;
			if (rd_lat == 3'd1) begin
				sc_rd_done  <= 1;
				sc_rd_ready <= 1;
			end
		end
		if (sc_host_wr) begin
			staging[sc_host_addr[24:1]] <= sc_host_data;
		end
	end

	// ---- bridge section model ----------------------------------------------
	reg [31:0] section [0:CARTW-1];
	reg [31:0] captured [0:CARTW-1];
	reg [31:0] rd_p1, rd_p2;
	integer    cap_count;
	always @(posedge clk) begin
		// bridge read path: registered twice, valid on the third cycle
		rd_p1            <= section[cart_img_rd_addr];
		rd_p2            <= rd_p1;
		cart_img_rd_data <= rd_p2;
		if (cart_img_wr) begin
			captured[cart_img_addr] <= cart_img_data;
			cap_count = cap_count + 1;
		end
	end

	// ---- monitors ----------------------------------------------------------
	integer errors = 0;
	reg hold_dropped_early = 0;
	always @(posedge clk) begin
		if (sc_rd_req && !hold) hold_dropped_early <= 1;
	end

	// Every drain write since reset, counted independently of the DUT.
	integer host_wr_count = 0;
	integer apply_pulses  = 0;
	integer done_pulses   = 0;
	always @(posedge clk) begin
		if (reset) host_wr_count = 0;
		else if (sc_host_wr === 1'b1) host_wr_count = host_wr_count + 1;
		if (state_apply === 1'b1)    apply_pulses = apply_pulses + 1;
		if (cart_load_done === 1'b1) done_pulses  = done_pulses + 1;
	end

	// A drain write is only ever legal while draining_o is up.
	reg wr_outside_drain = 0;
	always @(posedge clk)
		if (sc_host_wr === 1'b1 && sc_draining !== 1'b1) wr_outside_drain <= 1;

	// in_wait: the bench is holding stage_current low with a load pending.
	// draining_o must not rise there (C1: an owed pass must still run).
	reg in_wait = 0;
	reg drained_in_wait = 0;
	always @(posedge clk)
		if (in_wait && (sc_draining !== 1'b0 || sc_host_wr === 1'b1)) drained_in_wait <= 1;

	// A capture never drains.
	reg drain_in_capture = 0;
	always @(posedge clk)
		if (hold === 1'b1 && (sc_draining === 1'b1 || sc_host_wr === 1'b1)) drain_in_capture <= 1;

	// A load never borrows the staging read port.
	reg load_active = 0;
	reg rd_during_load = 0;
	always @(posedge clk)
		if (load_active && (sc_rd_active === 1'b1 || sc_rd_req === 1'b1)) rd_during_load <= 1;

	// The apply is outstanding from state_apply_o until state_done_i; done
	// inside that window is the race the old busy-watching copier had.
	reg apply_out = 0;
	reg done_early = 0;
	always @(posedge clk) begin
		if (cart_load_done === 1'b1 && apply_out) done_early <= 1;
		if (state_apply === 1'b1) apply_out <= 1'b1;
		else if (state_done)      apply_out <= 1'b0;
	end

	// draining_o, once up, stays up until done (the engine gates its boot
	// apply on it through the whole apply, not just the drain).
	reg drain_seen = 0;
	reg drain_dipped = 0;
	always @(posedge clk) begin
		if (!load_active || cart_load_done === 1'b1) drain_seen <= 0;
		else if (sc_draining === 1'b1) drain_seen <= 1;
		else if (drain_seen) drain_dipped <= 1;   // fell before done
	end

	task fail(input string msg);
		begin
			$display("   FAIL: %0s", msg);
			errors = errors + 1;
		end
	endtask

	task init_patterns;
		integer i;
		begin
			for (i = 0; i < 2*CARTW; i = i + 1) staging[i] = {i[7:0], i[15:8]} ^ 16'hB00B;
			for (i = 0; i < CARTW; i = i + 1) begin
				section[i]  = {~i[15:0], i[15:0]} ^ 32'h1BADB002;
				captured[i] = 32'hEEEEEEEE;
			end
			cap_count = 0;
		end
	endtask

	// New section contents per load, so a load that skipped words is seen.
	task reseed_section(input [31:0] salt);
		integer i;
		begin
			for (i = 0; i < CARTW; i = i + 1)
				section[i] = ({i[15:0], ~i[15:0]} * 32'd2654435761) ^ salt;
		end
	endtask

	task pulse_load;
		begin
			@(posedge clk); cart_load_req <= 1;
			@(posedge clk); cart_load_req <= 0;
		end
	endtask

	// Wait for a signal with a bound; returns the cycles waited.
	integer waited;
	task wait_apply(input integer max);
		begin
			waited = 0;
			while (state_apply !== 1'b1 && waited < max) begin
				@(posedge clk); waited = waited + 1;
			end
		end
	endtask

	// got_drn: draining_o in the done cycle itself. C2 says the copier
	// pulses done "and lowers draining_o" -- one step, so it must already
	// be low there (drain_dipped below catches it falling before done).
	reg        got_done, got_err, got_drn;
	task wait_done(input integer max);
		begin
			waited = 0; got_done = 0; got_err = 0; got_drn = 0;
			while (!got_done && waited < max) begin
				@(posedge clk); waited = waited + 1;
				if (cart_load_done === 1'b1) begin
					got_done = 1; got_err = cart_load_error; got_drn = sc_draining;
				end
			end
		end
	endtask

	task pulse_state_done(input rej);
		begin
			@(posedge clk); state_done <= 1; apply_reject <= rej;
			@(posedge clk); state_done <= 0;
			// apply_reject_o holds until the next apply starts
		end
	endtask

	function integer staging_mismatches(input integer dummy);
		integer i, e;
		begin
			e = 0;
			for (i = 0; i < CARTW; i = i + 1)
				if ({staging[2*i+1], staging[2*i]} !== section[i]) e = e + 1;
			staging_mismatches = e;
		end
	endfunction

	integer n0, e0, a0, d0;

	initial begin
		init_patterns;
		repeat (10) @(posedge clk);
		reset <= 0;
		repeat (10) @(posedge clk);

		// ---- C1: capture ---------------------------------------------------
		begin : c1
			integer i, errs;
			$display("== C1 capture: wait, hold, deliver");
			e0 = errors;
			n0 = host_wr_count;
			stage_current <= 0;
			@(posedge clk); cart_save_req <= 1;
			@(posedge clk); cart_save_req <= 0;
			repeat (200) @(posedge clk);
			if (!hold) fail("hold not asserted while waiting");
			if (cap_count != 0) fail("copier read staging before stage_current");
			if (sc_rd_active) fail("staging port borrowed before stage_current");
			stage_current <= 1;
			waited = 0;
			while (!cart_save_done && waited < 400000) begin @(posedge clk); waited = waited + 1; end
			if (!cart_save_done) fail("capture never finished");
			// the final img_wr pulse lands in the same timestep as done;
			// give the bench's own clocked capture two edges to settle
			repeat (2) @(posedge clk);
			errs = 0;
			for (i = 0; i < CARTW; i = i + 1)
				if (captured[i] !== {staging[2*i+1], staging[2*i]}) begin
					if (errs < 4)
						$display("    captured[%0d] = %h, want %h", i,
						         captured[i], {staging[2*i+1], staging[2*i]});
					errs = errs + 1;
				end
			if (cap_count != CARTW) begin
				$display("   FAIL: %0d writes for %0d words (%0d wrong)", cap_count, CARTW, errs);
				errors = errors + 1;
			end else if (errs != 0) begin
				$display("   FAIL: %0d captured words wrong", errs);
				errors = errors + 1;
			end
			if (hold_dropped_early) fail("hold dropped while reading staging");
			if (host_wr_count != n0) fail("capture wrote staging through the host path");
			if (drain_in_capture) fail("draining_o raised (or a drain write) during a capture");
			if (diag_drain !== 16'd0) fail("diag_drain_o moved without a drain");
			repeat (4) @(posedge clk);
			if (hold) fail("hold stuck after done");
			if (errors == e0) $display("   PASS");
		end

		// ---- C2: restore ---------------------------------------------------
		begin : c2
			integer errs;
			$display("== C2 restore: wait without draining, drain, apply, done on state_done");
			e0 = errors;
			init_patterns;
			stage_current <= 0;
			n0 = host_wr_count; a0 = apply_pulses; d0 = done_pulses;
			load_active = 1;
			pulse_load;
			in_wait = 1;
			repeat (400) @(posedge clk);
			in_wait <= 0;
			if (drained_in_wait) fail("draining_o raised (or a write issued) before stage_current");
			if (done_pulses != d0) fail("done while still waiting for stage_current");
			stage_current <= 1;
			// the drain starts; the stager may lose currency again under it
			// (the game keeps running) -- that must not stall the drain
			waited = 0;
			while (sc_host_wr !== 1'b1 && waited < 100) begin @(posedge clk); waited = waited + 1; end
			if (sc_host_wr !== 1'b1) fail("drain did not start within 100 clk of stage_current");
			stage_current <= 0;
			// congest the PSRAM under the drain: take nothing until the skid
			// reaches the ready threshold, then take beats slower than the
			// copier offers them, so ready falls again and again
			nr_cycles = 0; nr_falls = 0;
			choke <= 1;
			repeat (2200) @(posedge clk);
			choke <= 0; slow <= 1;
			repeat (20000) @(posedge clk);
			slow <= 0;
			if (apply_pulses != a0) fail("(bench) the drain finished inside the congestion window");
			wait_apply(600000);
			if (state_apply !== 1'b1) fail("state_apply never pulsed");
			// every section word must already be in staging before the apply
			errs = staging_mismatches(0);
			if (errs != 0) begin
				$display("   FAIL: apply pulsed with %0d staging words wrong", errs);
				errors = errors + 1;
			end
			if (sc_draining !== 1'b1) fail("draining_o not up at the apply pulse");
			// the apply takes its time; nothing may finish before state_done
			repeat (400) @(posedge clk);
			if (done_pulses != d0) fail("done before state_done_i");
			if (sc_draining !== 1'b1) fail("draining_o dropped before state_done_i");
			pulse_state_done(1'b0);
			wait_done(20);
			if (!got_done) fail("no cart_load_done within 20 clk of state_done_i");
			else begin
				if (got_err !== 1'b0) fail("error flagged for an accepted apply");
				if (got_drn !== 1'b0) fail("draining_o still high in the done cycle");
			end
			repeat (2) @(posedge clk);
			if (sc_draining !== 1'b0) fail("draining_o stuck after done");
			load_active = 0;
			if (apply_pulses - a0 != 1) begin
				$display("   FAIL: %0d state_apply pulses for one load", apply_pulses - a0);
				errors = errors + 1;
			end
			if (done_pulses - d0 != 1) begin
				$display("   FAIL: %0d done pulses for one load", done_pulses - d0);
				errors = errors + 1;
			end
			if (host_wr_count - n0 != 2*CARTW) begin
				$display("   FAIL: %0d drain writes, want %0d", host_wr_count - n0, 2*CARTW);
				errors = errors + 1;
			end
			if (lost_write) fail("copier wrote into a full skid");
			if (wr_not_ready) fail("copier wrote although the ready it sampled was low");
			if (nr_falls < 10) begin
				$display("   FAIL: (bench) ready fell only %0d times under the drain", nr_falls);
				errors = errors + 1;
			end
			if (wr_outside_drain) fail("a drain write while draining_o was low");
			if (rd_during_load) fail("a load borrowed the staging read port");
			if (done_early) fail("done while the apply was outstanding");
			if (drain_dipped) fail("draining_o dipped between drain start and done");
			if (errors == e0)
				$display("   PASS (byte-exact; ready fell %0d times, %0d clk low, skid peak %0d)",
				         nr_falls, nr_cycles, max_fill);
		end

		// ---- C3: state_done timing ----------------------------------------
		begin : c3
			$display("== C3 state_done one clock after the apply, and very late");
			e0 = errors;
			reseed_section(32'h00C3C3A1);
			stage_current <= 1;
			d0 = done_pulses;
			load_active = 1;
			pulse_load;
			wait_apply(600000);
			if (state_apply !== 1'b1) fail("state_apply never pulsed (fast case)");
			// the earliest an engine could answer: the next edge
			state_done <= 1; apply_reject <= 0;
			@(posedge clk); state_done <= 0;
			wait_done(20);
			if (!got_done) fail("state_done one clock after the apply was missed");
			else if (got_err !== 1'b0) fail("error on the fast accepted apply");
			else if (got_drn !== 1'b0) fail("draining_o still high in the done cycle (fast case)");
			load_active = 0;
			repeat (4) @(posedge clk);
			// and the slow one
			reseed_section(32'h5107D0E5);
			d0 = done_pulses;
			load_active = 1;
			pulse_load;
			wait_apply(600000);
			if (state_apply !== 1'b1) fail("state_apply never pulsed (slow case)");
			repeat (5000) @(posedge clk);
			if (done_pulses != d0) fail("done without state_done (slow case)");
			pulse_state_done(1'b0);
			wait_done(20);
			if (!got_done) fail("no done after the late state_done");
			else if (got_err !== 1'b0) fail("error on the slow accepted apply");
			else if (got_drn !== 1'b0) fail("draining_o still high in the done cycle (slow case)");
			load_active = 0;
			if (staging_mismatches(0) != 0) fail("slow-case staging not byte-exact");
			if (done_early) fail("done while the apply was outstanding");
			if (errors == e0) $display("   PASS");
		end

		// ---- C4: the apply's verdict reaches the bridge -------------------
		begin : c4
			$display("== C4 cart_load_error is apply_reject_i sampled with state_done_i");
			e0 = errors;
			// (a) refused: the engine raises the flag with its done pulse
			reseed_section(32'hC4C4000A);
			stage_current <= 1;
			apply_reject  <= 0;
			load_active = 1;
			pulse_load;
			wait_apply(600000);
			repeat (60) @(posedge clk);
			pulse_state_done(1'b1);
			wait_done(20);
			load_active = 0;
			if (!got_done) fail("(a) no done");
			else if (got_err !== 1'b1) fail("(a) refused apply reported without error");
			else if (got_drn !== 1'b0) fail("(a) draining_o still high in the done cycle of a refused load");
			// (b) the flag from the refusal above is still up (it holds until
			// the next apply starts) and clears in the done cycle: no error
			reseed_section(32'hC4C4000B);
			apply_reject <= 1;
			load_active = 1;
			pulse_load;
			wait_apply(600000);
			repeat (60) @(posedge clk);
			pulse_state_done(1'b0);
			wait_done(20);
			load_active = 0;
			if (!got_done) fail("(b) no done");
			else if (got_err !== 1'b0) fail("(b) stale reject flag reported as an error");
			else if (got_drn !== 1'b0) fail("(b) draining_o still high in the done cycle");
			if (errors == e0) $display("   PASS");
		end

		// ---- C5: I_DR_WAIT timeout ----------------------------------------
		begin : c5
			integer t0;
			$display("== C5 I_DR_WAIT timeout: error, nothing written, copier idle again");
			e0 = errors;
			init_patterns;              // staging must stay exactly as it is
			stage_current <= 0;
			n0 = host_wr_count; a0 = apply_pulses; d0 = done_pulses;
			load_active = 1;
			pulse_load;
			in_wait = 1;
			wait_done(TO + 200);
			in_wait <= 0;
			load_active = 0;
			if (!got_done) fail("no done after DR_WAIT_TIMEOUT");
			else begin
				if (got_err !== 1'b1) fail("timeout reported without error");
				if (waited < TO - 4 || waited > TO + 64) begin
					$display("   FAIL: timed out after %0d clk, want ~%0d", waited, TO);
					errors = errors + 1;
				end
			end
			if (drained_in_wait) fail("draining_o raised (or a write issued) in the timeout path");
			if (host_wr_count != n0) fail("staging written on the timeout path");
			if (apply_pulses != a0) fail("state_apply pulsed on the timeout path");
			if (done_pulses - d0 != 1) fail("not exactly one done pulse for the timed-out load");
			begin : chk
				integer i, e;
				e = 0;
				for (i = 0; i < 2*CARTW; i = i + 1)
					if (staging[i] !== ({i[7:0], i[15:8]} ^ 16'hB00B)) e = e + 1;
				if (e) fail("staging changed on the timeout path");
			end
			if (diag_drain !== host_wr_count[15:0]) fail("diag_drain_o moved on the timeout path");
			// idle again, and the timeout restarts per request: wait 3/4 of it
			repeat (8) @(posedge clk);
			reseed_section(32'h7117E0D8);
			load_active = 1;
			pulse_load;
			in_wait = 1;
			repeat ((TO * 3) / 4) @(posedge clk);
			in_wait <= 0;
			if (done_pulses - d0 != 1) fail("second load ended during its own wait");
			stage_current <= 1;
			wait_apply(600000);
			if (state_apply !== 1'b1) fail("load after a timeout never applied");
			pulse_state_done(1'b0);
			wait_done(20);
			load_active = 0;
			if (!got_done) fail("load after a timeout never finished");
			else if (got_err !== 1'b0) fail("load after a timeout reported an error");
			else if (got_drn !== 1'b0) fail("draining_o still high in the done cycle after a timeout");
			if (staging_mismatches(0) != 0) fail("load after a timeout not byte-exact");
			if (drained_in_wait) fail("draining_o raised during the second wait");
			// and the timeout the hardware build gets (spec C1: ~2 s at 49 MHz)
			if (dflt.DR_WAIT_TIMEOUT != 100_000_000) begin
				$display("   FAIL: default DR_WAIT_TIMEOUT = %0d, want 100000000", dflt.DR_WAIT_TIMEOUT);
				errors = errors + 1;
			end
			if (errors == e0) $display("   PASS (timed out after %0d clk; next load clean)", TO);
		end

		// ---- C6: the drain counter ----------------------------------------
		begin : c6
			$display("== C6 diag_drain_o counts drain writes since reset");
			e0 = errors;
			// six complete drains so far (C2, C3 x2, C4 x2, C5's second
			// load): 195,072 writes, past a 16-bit wrap
			repeat (4) @(posedge clk);
			if (host_wr_count != 6 * 2 * CARTW) begin
				$display("   FAIL: bench counted %0d drain writes, expected %0d",
				         host_wr_count, 6 * 2 * CARTW);
				errors = errors + 1;
			end
			if (diag_drain !== host_wr_count[15:0]) begin
				$display("   FAIL: diag_drain_o = %0d, want %0d (mod 2^16)",
				         diag_drain, host_wr_count[15:0]);
				errors = errors + 1;
			end
			@(posedge clk); reset <= 1;
			repeat (4) @(posedge clk); reset <= 0;
			repeat (2) @(posedge clk);
			if (diag_drain !== 16'd0) fail("diag_drain_o not cleared by reset");
			if (sc_draining !== 1'b0) fail("draining_o not low after reset");
			if (errors == e0) $display("   PASS");
		end

		if (lost_write)       fail("(global) a drain write hit a full skid");
		if (wr_not_ready)     fail("(global) a drain write whose sampled ready was low");
		if (wr_outside_drain) fail("(global) a drain write outside draining_o");

		if (errors == 0) $display("== ALL STATE-CART SCENARIOS PASS");
		else             $display("== %0d FAILURE(S)", errors);
		$finish;
	end

	initial begin
		#80_000_000;
		$display("== WATCHDOG TIMEOUT");
		$display("== %0d FAILURE(S)", errors + 1);
		$finish;
	end

endmodule

`default_nettype wire
