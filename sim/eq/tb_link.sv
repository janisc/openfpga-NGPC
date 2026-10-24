// Two ngpc_link transports on simulated link cables.
//
// Side A and side B run on independent clocks (B is 300 ppm slow, more than
// two Pockets' oscillators ever differ). Each side's machine sends random
// 19200 bps 8N1 bytes on TxD and wiggles RTS_n; the other side's RxD is decoded
// by a strict receiver that samples every bit at 30%, 50% and 70% of its width
// and requires all three to agree. (The TMP95C061 samples around the middle of
// a bit and needs far less.)
//
// THE CABLES. Each physical wire is resolved from every pin driving it. Two
// drivers on one wire at the same time is CONTENTION -- the thing that must
// never happen with a standard cable -- and is measured on every wire.
//
//   none      nothing plugged in; every pin on its own (undriven = high)
//   gbc       A.SO-B.SI and B.SO-A.SI; SD not connected
//   gbc_sd    as gbc, with SD joined straight through (some cables might)
//   gba       A on the parent plug: A.SO-B.SI, A.SI tied low, B.SO to the
//             middle socket (nothing), SD of both joined
//   straight  a broken / home-made cable: SO-SO, SI-SI, SD-SD
//
// Every phase sets a cable and both sides' Link Cable mode (1 GBC, 2 GBA),
// starts both links from off, and checks what must hold.

`timescale 1ps/1ps

module tb_link;

	localparam integer BIT_PS  = 52_083_333;          // 19200 bps
	localparam integer HALF_A  = 10_173;              // clk_sys 49.152 MHz
	localparam integer HALF_B  = 10_176;              // about 300 ppm slower

	reg clk_a = 0, clk_b = 0;
	always #(HALF_A) clk_a = ~clk_a;
	always #(HALF_B) clk_b = ~clk_b;

	reg reset = 1;

	// ---- the two transports ------------------------------------------------
	reg  [1:0] mode_a = 0, mode_b = 0;
	reg  txd_a = 1, txd_b = 1, rts_a = 1, rts_b = 1;
	wire rxd_a, rxd_b, cts_a, cts_b, pres_a, pres_b;
	wire so_a, soe_a, sd_a, sde_a, so_b, soe_b, sd_b, sde_b;
	wire w_so_a, w_si_a, w_sd_a, w_so_b, w_si_b, w_sd_b;   // what each pin sees

	ngpc_link #(.SEED(16'hACE1)) u_a (.clk(clk_a), .reset(reset), .mode(mode_a),
		.txd(txd_a), .rts_n(rts_a), .rxd(rxd_a), .cts_n(cts_a), .present(pres_a),
		.so(so_a), .so_oe(soe_a), .so_pin(w_so_a), .si(w_si_a),
		.sd(sd_a), .sd_oe(sde_a), .sd_pin(w_sd_a));
	ngpc_link #(.SEED(16'h1D2B)) u_b (.clk(clk_b), .reset(reset), .mode(mode_b),
		.txd(txd_b), .rts_n(rts_b), .rxd(rxd_b), .cts_n(cts_b), .present(pres_b),
		.so(so_b), .so_oe(soe_b), .so_pin(w_so_b), .si(w_si_b),
		.sd(sd_b), .sd_oe(sde_b), .sd_pin(w_sd_b));

	// ---- the cable ---------------------------------------------------------
	localparam int C_NONE = 0, C_GBC = 1, C_GBC_SD = 2, C_GBA = 3, C_STRAIGHT = 4;
	int cable = C_NONE;

	bit f_so, f_sd;                                    // contention flags
	bit v_so_a, v_so_b, v_si_a, v_si_b, v_sd_a, v_sd_b;

	// Two pins on one wire: the driving pin's level, high when undriven.
	function automatic bit pick(input bit e0, input bit v0, input bit e1, input bit v1);
		if (e0) return v0;
		if (e1) return v1;
		return 1'b1;
	endfunction

	always_comb begin
		f_so = 0; f_sd = 0;
		v_so_a = soe_a ? so_a : 1'b1;  v_so_b = soe_b ? so_b : 1'b1;
		v_si_a = 1'b1;  v_si_b = 1'b1;
		v_sd_a = sde_a ? sd_a : 1'b1;  v_sd_b = sde_b ? sd_b : 1'b1;
		case (cable)
			C_GBC, C_GBC_SD: begin
				v_si_b = v_so_a;
				v_si_a = v_so_b;
				if (cable == C_GBC_SD) begin
					f_sd = sde_a && sde_b;
					v_sd_a = pick(sde_a, sd_a, sde_b, sd_b);  v_sd_b = v_sd_a;
				end
			end
			C_GBA: begin
				v_si_b = v_so_a;                              // B.SO: middle socket
				v_si_a = 1'b0;                                // tied low
				f_sd = sde_a && sde_b;
				v_sd_a = pick(sde_a, sd_a, sde_b, sd_b);  v_sd_b = v_sd_a;
			end
			C_STRAIGHT: begin
				f_so = soe_a && soe_b;
				v_so_a = pick(soe_a, so_a, soe_b, so_b);  v_so_b = v_so_a;
				f_sd = sde_a && sde_b;
				v_sd_a = pick(sde_a, sd_a, sde_b, sd_b);  v_sd_b = v_sd_a;
			end
			default: ;
		endcase
	end

	// Disturbances on top of the cable: spikes on the receiving pins, and an
	// undriven line that floats as noise instead of idling high.
	reg glitch_a = 0, glitch_b = 0, glitching = 0, float_noise = 0, noise = 1;
	always #(37_000) noise = $urandom_range(0, 1);
	initial forever begin
		#($urandom_range(100, 1000) * 1_000_000);
		if (glitching) begin glitch_a = 1; #($urandom_range(20_000, 60_000)); glitch_a = 0; end
	end
	initial forever begin
		#($urandom_range(100, 1000) * 1_000_000);
		if (glitching) begin glitch_b = 1; #($urandom_range(20_000, 60_000)); glitch_b = 0; end
	end
	wire floating = float_noise && cable == C_NONE;

	assign w_so_a = v_so_a;  assign w_so_b = v_so_b;
	assign w_si_a = (floating ? noise : v_si_a) ^ glitch_a;
	assign w_si_b = (floating ? noise : v_si_b) ^ glitch_b;
	assign w_sd_a = (cable == C_GBA) ? (v_sd_a ^ glitch_a) : v_sd_a;
	assign w_sd_b = v_sd_b;

	// Contention bookkeeping, sampled every nanosecond, and whether each side has
	// driven SD at any moment since the phase began.
	wire fight = f_so || f_sd;
	longint fight_ns = 0, fight_run_ns = 0, fight_max_ns = 0;
	bit sd_ever_a = 0, sd_ever_b = 0;
	always #(1000) begin
		if (sde_a) sd_ever_a = 1;
		if (sde_b) sd_ever_b = 1;
		if (fight) begin
			fight_ns++;
			fight_run_ns++;
			if (fight_run_ns > fight_max_ns) fight_max_ns = fight_run_ns;
		end else fight_run_ns = 0;
	end

	// ---- traffic and its checking ------------------------------------------
	reg        traffic = 0;
	reg        checking = 0;
	byte unsigned sent_ab [$];
	byte unsigned sent_ba [$];
	int        n_ok = 0, n_bad = 0, n_unexpected = 0, n_margin = 0;
	// With spikes on the wire a lost frame delays one edge by a frame more than
	// usual; the TMP95C061 samples a bit around its middle, so there a byte with
	// the right value counts as delivered and the 30-70% margin miss is reported.
	reg        strict = 1;

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
			if (at_b ? sent_ab.size() == 0 : sent_ba.size() == 0) begin
				if (checking) begin
					n_unexpected++;
					$display("%t UNEXPECTED byte %h at %s", $time, b, at_b ? "B" : "A");
				end
			end else begin
				automatic byte unsigned want = at_b ? sent_ab.pop_front() : sent_ba.pop_front();
				if (!checking) ;
				else if (ok && b == want) n_ok++;
				else if (!strict && b == want) begin n_ok++; n_margin++; end
				else begin
					n_bad++;
					$display("%t BAD at %s: got %h want %h, margin %s", $time, at_b ? "B" : "A",
						b, want, ok ? "ok" : "VIOLATED");
				end
			end
		end
	endtask

	initial uart_check(1);
	initial uart_check(0);

	// RTS wiggles slowly; CTS on the far side must follow within 20 us.
	int n_rts_late = 0;
	reg rts_check = 0;
	initial forever begin
		#($urandom_range(200, 2000) * 1_000_000);
		if (traffic) begin
			rts_a = ~rts_a;
			rts_b = ~rts_b;
			#(20_000_000);
			if (checking && rts_check && (cts_b !== rts_a || cts_a !== rts_b)) begin
				n_rts_late++;
				$display("%t RTS not through: A %b->B %b, B %b->A %b", $time, rts_a, cts_b, rts_b, cts_a);
			end
		end
	end

	// Log every change of link state while log_changes is set.
	reg log_changes = 0;
	always @(pres_a or pres_b or soe_a or soe_b or sde_a or sde_b or u_a.si_grounded or u_b.si_grounded or u_a.rem_parent or u_b.rem_parent)
		if (log_changes) $display("%t    present %b/%b  SO oe %b/%b  SD oe %b/%b  grounded %b/%b  rem_parent %b/%b", $time, pres_a, pres_b, soe_a, soe_b, sde_a, sde_b,
			u_a.si_grounded, u_b.si_grounded, u_a.rem_parent, u_b.rem_parent);

	// ---- the script ----------------------------------------------------------
	int fails = 0;
	task automatic check(input bit cond, input string what);
		if (!cond) begin
			fails++;
			$display("%t FAIL %s (present %b/%b, SO oe %b/%b, SD oe %b/%b, contention %0d ns, longest %0d ns)",
				$time, what, pres_a, pres_b, soe_a, soe_b, sde_a, sde_b, fight_ns, fight_max_ns);
		end else $display("%t ok   %s", $time, what);
	endtask

	// Start a phase: everything off and quiet, then the cable, then both links on.
	task automatic phase(input string name, input int c, input bit [1:0] ma, input bit [1:0] mb);
		traffic = 0; checking = 0;
		mode_a = 0; mode_b = 0;
		#(2_000_000_000);                       // let bytes in flight drain
		sent_ab.delete(); sent_ba.delete();
		cable = c;
		#(100_000_000);
		fight_ns = 0; fight_max_ns = 0; sd_ever_a = 0; sd_ever_b = 0;
		mode_a = ma; mode_b = mb;               // both switched on together
		$display("%t ---- %s", $time, name);
	endtask

	// Run traffic both ways for `ms` and require it all to arrive exactly.
	task automatic both_ways(input int ms, input string name);
		automatic int ok0 = n_ok, bad0 = n_bad, un0 = n_unexpected, late0 = n_rts_late;
		traffic = 1; checking = 1; rts_check = 1;
		#(longint'(ms) * 1_000_000_000);
		checking = 0; rts_check = 0; traffic = 0;
		check(n_ok - ok0 > ms * 2 && n_bad == bad0 && n_unexpected == un0 && n_rts_late == late0,
			$sformatf("%s: %0d bytes exact both ways, %0d bad, %0d RTS late", name,
				n_ok - ok0, n_bad - bad0, n_rts_late - late0));
	endtask

	initial begin
		#(1_000_000); reset = 0;

		// 1. Nothing plugged in.
		phase("no cable, both GBC mode", C_NONE, 1, 1);
		#(5_000_000_000);
		check(!pres_a && !pres_b && rxd_a && rxd_b && cts_a && cts_b, "no cable: unplugged on both");
		check(fight_ns == 0, "no cable: no wire ever had two drivers");

		// 1b. Nothing plugged in, the open pins floating as noise.
		float_noise = 1;
		phase("no cable, floating noise", C_NONE, 2, 2);
		#(10_000_000_000);
		check(!pres_a && !pres_b && rxd_a && rxd_b && !sd_ever_a && !sd_ever_b, "floating noise: unplugged on both, SD never driven");
		float_noise = 0;

		// 2. GBC cable, GBC mode.
		phase("GBC cable, both GBC mode", C_GBC, 1, 1);
		#(2_000_000_000);
		check(pres_a && pres_b, "GBC/GBC: linked");
		both_ways(60, "GBC/GBC");
		check(fight_ns == 0 && !sd_ever_a && !sd_ever_b, "GBC/GBC: no contention, SD never driven");

		// 3. GBC cable (SD joined), GBA mode: must behave like GBC mode, SD untouched.
		log_changes = 1;
		phase("GBC cable with SD joined, both GBA mode", C_GBC_SD, 2, 2);
		#(2_000_000_000);
		check(pres_a && pres_b, "GBC(SD joined)/GBA: linked");
		both_ways(60, "GBC(SD joined)/GBA");
		check(fight_ns == 0 && !sd_ever_a && !sd_ever_b, "GBC(SD joined)/GBA: no contention, SD never driven");
		log_changes = 0;

		// 4. GBA cable, GBA mode: A parent (SO out, SD in), B child (SI in, SD out).
		phase("GBA cable, both GBA mode", C_GBA, 2, 2);
		#(3_000_000_000);
		check(pres_a && pres_b, "GBA/GBA: linked");
		check(!sd_ever_a && sde_b, "GBA/GBA: only the child (B) drives SD");
		both_ways(60, "GBA/GBA");
		check(fight_ns == 0, "GBA/GBA: no contention");

		// 5. GBA cable, GBC mode: one way only, and harmless.
		phase("GBA cable, both GBC mode", C_GBA, 1, 1);
		#(3_000_000_000);
		check(!pres_a, "GBA/GBC: the parent plug (A) hears nothing");
		check(fight_ns == 0 && !sd_ever_a && !sd_ever_b, "GBA/GBC: no contention, SD never driven");

		// 6. GBA cable, mixed: A (parent) in GBA mode, B in GBC mode.
		phase("GBA cable, A GBA mode, B GBC mode", C_GBA, 2, 1);
		#(3_000_000_000);
		check(!pres_a && fight_ns == 0 && !sd_ever_a && !sd_ever_b, "GBA/mixed: no link back to A, no contention, SD never driven");

		// 7. Straight-through cable, both switched on together: SO against SO.
		phase("straight cable, both GBC mode", C_STRAIGHT, 1, 1);
		#(20_000_000_000);
		check(fight_max_ns < 3_000_000, $sformatf("straight/GBC: SO-SO contention resolved (longest %0d us, total %0d us)",
			fight_max_ns / 1000, fight_ns / 1000));
		check(!(soe_a && soe_b), "straight/GBC: at most one side drives SO now");
		check(!pres_a && !pres_b, "straight/GBC: no link (none possible)");

		// 8. Straight-through cable, GBA mode.
		phase("straight cable, both GBA mode", C_STRAIGHT, 2, 2);
		#(20_000_000_000);
		check(fight_max_ns < 3_000_000, $sformatf("straight/GBA: contention resolved (longest %0d us)", fight_max_ns / 1000));
		check(!(soe_a && soe_b) && !sd_ever_a && !sd_ever_b, "straight/GBA: one SO driver at most, SD never driven");

		// 8b. GBC and GBA cables with spikes on the receiving wires: still exact.
		glitching = 1; strict = 0;
		phase("GBC cable with spikes, GBC mode", C_GBC, 1, 1);
		#(2_000_000_000);
		both_ways(150, "GBC + spikes");
		phase("GBA cable with spikes, GBA mode", C_GBA, 2, 2);
		#(3_000_000_000);
		both_ways(150, "GBA + spikes");
		check(fight_ns == 0 && !sd_ever_a, "GBA + spikes: no contention, only the child drives SD");
		$display("%t      spikes: %0d bytes right but under the strict margin", $time, n_margin);
		glitching = 0; strict = 1;

		// 9. Back to a GBC cable after all that: still links.
		phase("GBC cable again", C_GBC, 1, 1);
		#(2_000_000_000);
		check(pres_a && pres_b, "GBC again: linked");
		both_ways(30, "GBC again");

		// 10. Unplugged mid-stream: presence drops quickly.
		traffic = 1;
		#(5_000_000_000);
		cable = C_NONE;
		#(100_000_000);
		check(!pres_a && !pres_b && rxd_a && rxd_b, "unplugged mid-stream: both see no cable within 100 us");
		traffic = 0;

		if (fails == 0)
			$display("LINK TRANSPORT OK (%0d bytes checked)", n_ok);
		else
			$display("LINK TRANSPORT FAILED (%0d checks failed)", fails);
		$finish;
	end

endmodule
