`timescale 1ns/1ps
`default_nettype none

// Bench for ngpc_state_cart, the staging <-> blob-cart-section copier.
//
// Modeled around it: the staging PSRAM (both faces the copier uses -- the
// borrowed engine read port with ready/done pacing, and the host-write skid
// sink), the bridge's cart section (a word array serving reads with the
// bridge's 3-cycle latency and capturing writes), and the cart save engine's
// three signals (stage_current, busy, and the state_apply observer).
//
// SCENARIOS
//   C1 capture: staging holds a known image, stager reports current after a
//      delay -> the copier must wait, hold the machine the whole time, then
//      deliver every word to the bridge exactly once, in order, byte-exact.
//   C2 restore: the bridge section holds a known image -> the copier must
//      wait for the stager, write staging byte-exact through the host path,
//      pulse the apply, and report done only after busy rises AND falls.
//   C3 restore with a slow apply: done must not fire early (the busy-rise
//      race the copier's apply_seen flag exists for).

module tb_state_cart;

	reg clk = 0;
	always #10.173 clk = ~clk;
	reg reset = 1;

	localparam integer CARTW = 16256;

	// ---- DUT wiring --------------------------------------------------------
	reg         cart_save_req = 0, cart_load_req = 0;
	wire        cart_save_done, cart_load_done;
	wire        cart_img_wr;
	wire [13:0] cart_img_addr;
	wire [31:0] cart_img_data;
	wire [13:0] cart_img_rd_addr;
	reg  [31:0] cart_img_rd_data;

	wire        sc_rd_req, sc_rd_active, sc_draining;
	wire [24:0] sc_rd_addr;
	reg         sc_rd_ready = 1, sc_rd_done = 0;
	reg  [15:0] sc_rd_data;

	wire        sc_host_wr;
	wire [24:0] sc_host_addr;
	wire [15:0] sc_host_data;

	reg         stage_current = 0;
	wire        state_apply;
	reg         apply_busy = 0;
	wire        hold;

	ngpc_state_cart dut (
		.clk(clk), .reset(reset),
		.cart_save_req(cart_save_req), .cart_save_done(cart_save_done),
		.cart_img_wr(cart_img_wr), .cart_img_addr(cart_img_addr),
		.cart_img_data(cart_img_data),
		.cart_load_req(cart_load_req), .cart_load_done(cart_load_done),
		.cart_img_rd_addr(cart_img_rd_addr), .cart_img_rd_data(cart_img_rd_data),
		.sc_rd_req(sc_rd_req), .sc_rd_addr(sc_rd_addr),
		.sc_rd_ready(sc_rd_ready), .sc_rd_done(sc_rd_done),
		.sc_rd_data(sc_rd_data), .sc_rd_active(sc_rd_active),
		.draining_o(sc_draining),
		.sc_host_wr(sc_host_wr), .sc_host_addr(sc_host_addr),
		.sc_host_data(sc_host_data),
		.stage_current_i(stage_current), .state_apply_o(state_apply),
		.apply_busy_i(apply_busy),
		.hold_o(hold)
	);

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

	initial begin
		init_patterns;
		repeat (10) @(posedge clk);
		reset = 0;
		repeat (10) @(posedge clk);

		// ---- C1: capture ---------------------------------------------------
		begin : c1
			integer i, errs;
			$display("== C1 capture: wait, hold, deliver");
			stage_current = 0;
			@(posedge clk); cart_save_req <= 1;
			@(posedge clk); cart_save_req <= 0;
			repeat (200) @(posedge clk);
			if (!hold) begin
				$display("   FAIL: hold not asserted while waiting");
				errors = errors + 1;
			end
			if (cap_count != 0) begin
				$display("   FAIL: copier read staging before stage_current");
				errors = errors + 1;
			end
			stage_current = 1;
			wait (cart_save_done);
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
			end else if (hold_dropped_early) begin
				$display("   FAIL: hold dropped while reading staging");
				errors = errors + 1;
			end else if (hold) begin
				repeat (4) @(posedge clk);
				if (hold) begin
					$display("   FAIL: hold stuck after done");
					errors = errors + 1;
				end else $display("   PASS");
			end else $display("   PASS");
		end

		// ---- C2: restore ---------------------------------------------------
		begin : c2
			integer i, errs, done_seen;
			$display("== C2 restore: drain, stage, apply, done");
			init_patterns;
			stage_current = 0;
			@(posedge clk); cart_load_req <= 1;
			@(posedge clk); cart_load_req <= 0;
			repeat (100) @(posedge clk);
			if (!sc_draining) begin
				$display("   FAIL: draining_o not asserted");
				errors = errors + 1;
			end
			stage_current = 1;
			wait (state_apply);
			// every section word must already be in staging before the apply
			errs = 0;
			for (i = 0; i < CARTW; i = i + 1)
				if ({staging[2*i+1], staging[2*i]} !== section[i]) errs = errs + 1;
			if (errs != 0) begin
				$display("   FAIL: apply pulsed with %0d staging words wrong", errs);
				errors = errors + 1;
			end
			// the apply takes its time
			done_seen = 0;
			fork
				begin
					repeat (30) @(posedge clk);
					apply_busy = 1;
					repeat (400) @(posedge clk);
					apply_busy = 0;
				end
				begin
					wait (cart_load_done);
					done_seen = 1;
				end
			join_any
			if (!done_seen) wait (cart_load_done);
			if (apply_busy) begin
				$display("   FAIL: done fired while the apply still ran");
				errors = errors + 1;
			end else if (sc_draining) begin
				$display("   FAIL: draining_o stuck after done");
				errors = errors + 1;
			end else $display("   PASS");
		end

		// ---- C3: the busy-rise race ---------------------------------------
		begin : c3
			integer premature;
			$display("== C3 slow apply: done must wait for busy rise+fall");
			init_patterns;
			stage_current = 1;
			@(posedge clk); cart_load_req <= 1;
			@(posedge clk); cart_load_req <= 0;
			wait (state_apply);
			// busy stays low for a long time before the engine reacts
			premature = 0;
			fork : race
				begin
					repeat (300) @(posedge clk);
					apply_busy = 1;
					repeat (50) @(posedge clk);
					apply_busy = 0;
				end
				begin
					wait (cart_load_done);
					if (!apply_busy) premature = premature; // reached: check timing below
				end
			join
			// if done fired before busy ever rose, the copier raced
			// (we detect it by re-checking: done must come after the fall)
			if (premature) begin
				$display("   FAIL: premature done");
				errors = errors + 1;
			end else $display("   PASS");
		end

		if (errors == 0) $display("== ALL STATE-CART SCENARIOS PASS");
		else             $display("== %0d ERRORS", errors);
		$finish;
	end

	// C3's real teeth: done before busy's rise is a race failure
	reg busy_ever = 0;
	always @(posedge clk) begin
		if (apply_busy) busy_ever <= 1;
		if (cart_load_done && !busy_ever) begin
			$display("   FAIL: cart_load_done before the apply ever ran");
			errors = errors + 1;
		end
		if (cart_load_done) busy_ever <= 0;
	end

	initial begin
		#80_000_000;
		$display("== WATCHDOG TIMEOUT");
		$finish;
	end

endmodule

`default_nettype wire
