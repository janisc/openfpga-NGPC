// Two ngpc_link transports on a simulated GBC link cable.
//
// Side A and side B run on independent clocks (B is 300 ppm slow, more than
// two Pockets' oscillators ever differ). Each side's machine sends random
// 19200 bps 8N1 bytes on TxD and wiggles RTS_n; the other side's RxD is decoded
// by a strict receiver that samples every bit at 30%, 50% and 70% of its width
// and requires all three to agree, so a pass means every rebuilt bit kept at
// least 30% of a bit of margin on both edges. (The TMP95C061 samples around the
// middle of a bit and needs far less.) A frame lost to a glitch costs one frame
// of extra delay, about 11% of a bit at 19200 bps.
//
// Phases:
//   1. cable unplugged, partner pin held high      -> no presence, RxD mark
//   2. unplugged, pin floating as noise           -> no presence, no bytes
//   3. plugged in                                  -> presence, then traffic
//   4. glitches injected on both wires             -> traffic still exact
//   5. side B's link switched off (pin released)   -> A sees the cable go
//   6. B back on                                   -> presence and traffic again
//   7. unplugged mid-stream                        -> presence drops quickly
// Bytes in flight when the cable changes are not checked.

`timescale 1ps/1ps

module tb_link;

	localparam integer BIT_PS  = 52_083_333;          // 19200 bps
	localparam integer HALF_A  = 10_173;              // clk_sys 49.152 MHz
	localparam integer HALF_B  = 10_176;              // about 300 ppm slower

	reg clk_a = 0, clk_b = 0;
	always #(HALF_A) clk_a = ~clk_a;
	always #(HALF_B) clk_b = ~clk_b;

	reg reset = 1;

	// Machine side.
	reg  txd_a = 1, txd_b = 1, rts_a = 1, rts_b = 1;
	reg  en_a = 1, en_b = 1;
	wire rxd_a, rxd_b, cts_a, cts_b, pres_a, pres_b;

	// Pins and the cable.
	wire so_a, so_b, oe_a, oe_b;
	reg  plugged = 0;
	reg  float_noise = 0;
	reg  glitch_a = 0, glitch_b = 0;     // pulses injected onto each wire
	reg  noise = 1;

	// What each side's SI sees: the partner's SO when plugged and driven,
	// otherwise the idle level or noise; plus any injected glitch.
	wire line_ab = (plugged && oe_a) ? so_a : (float_noise ? noise : 1'b1);
	wire line_ba = (plugged && oe_b) ? so_b : (float_noise ? noise : 1'b1);
	wire si_b = line_ab ^ glitch_a;
	wire si_a = line_ba ^ glitch_b;

	always #(37_000) noise = $urandom_range(0, 1);

	ngpc_link u_a (.clk(clk_a), .reset(reset), .enable(en_a),
		.txd(txd_a), .rts_n(rts_a), .rxd(rxd_a), .cts_n(cts_a), .present(pres_a),
		.so(so_a), .so_oe(oe_a), .si(si_a));
	ngpc_link u_b (.clk(clk_b), .reset(reset), .enable(en_b),
		.txd(txd_b), .rts_n(rts_b), .rxd(rxd_b), .cts_n(cts_b), .present(pres_b),
		.so(so_b), .so_oe(oe_b), .si(si_b));

	// ---- traffic ------------------------------------------------------------
	reg        traffic = 0;
	reg        checking = 0;
	byte unsigned sent_ab [$];
	byte unsigned sent_ba [$];
	int        n_ok = 0, n_bad = 0, n_unexpected = 0;

	task automatic uart_send(input bit a_side, input byte unsigned b);
		if (a_side) begin
			txd_a = 0; #(BIT_PS);
			for (int i = 0; i < 8; i++) begin txd_a = b[i]; #(BIT_PS); end
			txd_a = 1; #(BIT_PS);
		end else begin
			txd_b = 0; #(BIT_PS);
			for (int i = 0; i < 8; i++) begin txd_b = b[i]; #(BIT_PS); end
			txd_b = 1; #(BIT_PS);
		end
	endtask

	initial forever begin
		wait (traffic);
		begin
			automatic byte unsigned b = 8'($urandom);
			sent_ab.push_back(b);
			uart_send(1, b);
			#($urandom_range(0, 3) * BIT_PS);
		end
	end
	initial forever begin
		wait (traffic);
		begin
			automatic byte unsigned b = 8'($urandom);
			sent_ba.push_back(b);
			uart_send(0, b);
			#($urandom_range(0, 3) * BIT_PS);
		end
	end

	// A strict 8N1 receiver: samples at 30%, 50% and 70% of every bit, all must agree.
	task automatic uart_check(input bit at_b);
		forever begin
			automatic byte unsigned b = 0;
			automatic bit ok = 1;
			if (at_b) @(negedge rxd_b); else @(negedge rxd_a);
			#(BIT_PS / 10 * 3);
			for (int i = 0; i < 10; i++) begin
				automatic bit s0, s1, s2;
				s0 = at_b ? rxd_b : rxd_a; #(BIT_PS / 5);
				s1 = at_b ? rxd_b : rxd_a; #(BIT_PS / 5);
				s2 = at_b ? rxd_b : rxd_a;
				if (s0 != s1 || s1 != s2) ok = 0;
				if (i == 0 && s1 != 0) ok = 0;
				if (i == 9 && s1 != 1) ok = 0;
				if (i >= 1 && i <= 8) b[i-1] = s1;
				if (i < 9) #(BIT_PS / 5 * 3);
			end
			begin
				if (at_b ? sent_ab.size() == 0 : sent_ba.size() == 0) begin
					if (checking) n_unexpected++;
					$display("%t UNEXPECTED byte %h at %s", $time, b, at_b ? "B" : "A");
				end else begin
					automatic byte unsigned want = at_b ? sent_ab.pop_front() : sent_ba.pop_front();
					if (!checking) ;
					else if (ok && b == want) n_ok++;
					else begin
						n_bad++;
						$display("%t BAD at %s: got %h want %h, margin %s", $time, at_b ? "B" : "A",
							b, want, ok ? "ok" : "VIOLATED");
					end
				end
			end
			// Re-arm straight after the last stop sample, like a real receiver:
			// back-to-back bytes start exactly where this stop bit ends.
		end
	endtask

	initial uart_check(1);
	initial uart_check(0);

	// RTS wiggles slowly; CTS on the far side must follow within 20 us.
	int n_rts_late = 0;
	initial forever begin
		#($urandom_range(200, 2000) * 1_000_000);
		if (traffic) begin
			rts_a = ~rts_a;
			rts_b = ~rts_b;
			#(20_000_000);
			if (checking && (cts_b !== rts_a || cts_a !== rts_b)) begin
				n_rts_late++;
				$display("%t RTS not through: A %b->B %b, B %b->A %b", $time, rts_a, cts_b, rts_b, cts_a);
			end
		end
	end

	// Glitches: one-to-three-cycle spikes (20-60 ns) every 0.1-1 ms on each wire,
	// far noisier than a working cable.
	reg glitching = 0;
	initial forever begin
		#($urandom_range(100, 1000) * 1_000_000);
		if (glitching) begin glitch_a = 1; #($urandom_range(20_000, 60_000)); glitch_a = 0; end
	end
	initial forever begin
		#($urandom_range(100, 1000) * 1_000_000);
		if (glitching) begin glitch_b = 1; #($urandom_range(20_000, 60_000)); glitch_b = 0; end
	end

	// ---- the script -----------------------------------------------------------
	int fails = 0;
	task automatic expect_absent(input string what);
		if (pres_a || pres_b || rxd_a !== 1 || rxd_b !== 1 || cts_a !== 1 || cts_b !== 1) begin
			fails++;
			$display("%t FAIL %s: present %b/%b rxd %b/%b cts %b/%b", $time, what,
				pres_a, pres_b, rxd_a, rxd_b, cts_a, cts_b);
		end else $display("%t ok   %s", $time, what);
	endtask
	task automatic expect_present(input string what);
		if (!pres_a || !pres_b) begin
			fails++;
			$display("%t FAIL %s: present %b/%b", $time, what, pres_a, pres_b);
		end else $display("%t ok   %s", $time, what);
	endtask
	task automatic settle_and_check(input int ms);
		// Count only bytes sent and received while the cable is steady; the
		// queues themselves always track every byte.
		checking = 1;
		#(longint'(ms) * 1_000_000_000);
		checking = 0;
	endtask

	initial begin
		#(1_000_000); reset = 0;

		// 1. Unplugged, pin high.
		#(2_000_000_000);
		expect_absent("unplugged, idle line");

		// 2. Unplugged, floating as noise.
		float_noise = 1;
		#(5_000_000_000);
		expect_absent("unplugged, noisy line");
		float_noise = 0;

		// 3. Plugged in.
		plugged = 1;
		#(300_000_000);
		expect_present("plugged in, after 300 us");
		traffic = 1;
		settle_and_check(200);
		$display("%t phase 3: %0d bytes ok, %0d bad, %0d unexpected, %0d RTS late", $time, n_ok, n_bad, n_unexpected, n_rts_late);

		// 4. Glitches on both wires.
		glitching = 1;
		settle_and_check(200);
		glitching = 0;
		$display("%t phase 4: %0d bytes ok, %0d bad, %0d unexpected, %0d RTS late", $time, n_ok, n_bad, n_unexpected, n_rts_late);

		// 5. B switches its link off: A must see the cable go.
		traffic = 0; checking = 0;
		#(2_000_000_000);
		sent_ab.delete(); sent_ba.delete();       // the line is idle: nothing in flight
		en_b = 0;
		#(200_000_000);
		if (pres_a || rxd_a !== 1 || cts_a !== 1) begin fails++; $display("%t FAIL B off: A still sees a partner", $time); end
		else $display("%t ok   B's link off: A sees no cable", $time);
		if (oe_b) begin fails++; $display("%t FAIL B off but still driving SO", $time); end

		// 6. B back on.
		en_b = 1;
		#(300_000_000);
		expect_present("B back on");
		traffic = 1;
		settle_and_check(100);
		$display("%t phase 6: %0d bytes ok, %0d bad, %0d unexpected, %0d RTS late", $time, n_ok, n_bad, n_unexpected, n_rts_late);

		// 7. Unplugged mid-stream: presence must drop within 100 us.
		plugged = 0;
		#(100_000_000);
		expect_absent("unplugged mid-stream, after 100 us");
		traffic = 0;

		if (fails == 0 && n_bad == 0 && n_unexpected == 0 && n_rts_late == 0 && n_ok > 1000)
			$display("LINK TRANSPORT OK (%0d bytes checked)", n_ok);
		else
			$display("LINK TRANSPORT FAILED (%0d checks failed, %0d bad, %0d unexpected, %0d RTS late, %0d ok)",
				fails, n_bad, n_unexpected, n_rts_late, n_ok);
		$finish;
	end

endmodule
