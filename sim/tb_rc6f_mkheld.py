#!/usr/bin/env python3
"""rc6 family F: build sim/tb_rc6f_held.sv from sim/tb_rc5_loadpath.sv.

    python3 sim/tb_rc6f_mkheld.py [--machine F] [--core F] [--out F]
    python3 sim/tb_rc6f_mkheld.py --wiring [--machine F] [--core F]

The load diagnostic's held bit (pad word 8419, bit 10) is the bridge's
save_busy_i sampled at the identity check. The bridge documents it as "the
load arrived while the boot apply still held the machine", and
tools/savinfo.py prints "arrived while the core was still starting up (the
boot apply held the machine)". What save_busy_i IS comes from outside the
bridge: core_top routes ngpc_machine's save_busy_state to it, and
ngpc_machine assigns save_busy_state from one of the save engine's outputs.
Since the rc6 follow-up that is boot_hold_o (overlay_boot_hold); before it,
busy_o -- which is also high for every background staging pass.

So the wiring is not copied by hand: this script READS it from
target/pocket/ngpc_machine.sv (the one 'assign save_busy_state = <net>;' and
the ngpc_cart_save port that <net> is connected to) and checks that
core_top.v drives the bridge's save_busy_i from the machine's
save_busy_state. --wiring prints the engine port (boot_hold_o or busy_o) and
exits; run_rc6_stamp.sh builds tb_rc6f_stamp.sv's wiring from it too. A sed
mutant of ngpc_machine.sv (--machine) therefore rewires both benches.

The bench: the tracked sim/tb_rc5_loadpath.sv, which wires the REAL bridge,
copier (ngpc_state_cart) and save engine as core_top does, taken unchanged up
to its scenario list except two lines -- the module name, and the bridge's
save_busy_i, connected to the bench net of the engine port read above (the
tracked bench now wires boot_hold there too, as ngpc_machine does). Its own
scenarios are replaced by these:

  SETUP       a healthy session and a good layout-2 Memory of it
  HELD-IDLE   a Memory load with the save engine idle: held 0
  HELD-LATE   a Memory load in a running session, long after the boot
              apply, whose identity check falls inside a background staging
              pass (the game has just saved): busy_o 1, boot_hold_o 0 at the
              check. held 0 (the pre-follow-up wiring stamped 1)
  HELD-EARLY  a wake-shaped load while the delivered file's boot apply is
              pending (boot_hold_o high at the check): held 1
  C3-REAL     a reset (the one reset net, a core relaunch) cuts a Memory
              load's drain while the copier presents section word 1 -- the
              address the stamp's drained bit keys on -- and the next load
              is a copier timeout (cart not ready, as tb_rc5_loadpath BF-TO).
              ngpc_state_cart resets cart_img_rd_addr (rc6 follow-up), so the
              timeout stamps drained 0: D113E000. Without that reset the
              address stays parked at 1 and the stamp reads "drained, the
              apply refused the image".

Every held scenario checks held against save_busy_i at the check (the
bridge's own contract), against boot_hold_o at the check (the documented
meaning) and against the scenario's expectation; HELD-LATE and HELD-EARLY
also check that their setup produced the situation they are about (a pass
without the hold / the hold). +SCN=<name> runs SETUP and that one scenario
only (the mutant runs). Each capture is written to
sim/tb_rc6f_out/held/<name>.hex (+CAPDIR=<dir> elsewhere) for
tb_rc6f_check.py held. The tracked bench is only read.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(HERE, 'tb_rc5_loadpath.sv')
DST = os.path.join(HERE, 'tb_rc6f_held.sv')
MACHINE = os.path.join(ROOT, 'target', 'pocket', 'ngpc_machine.sv')
CORE = os.path.join(ROOT, 'target', 'pocket', 'core_top.v')

ENGINE_PORTS = ('boot_hold_o', 'busy_o')


class WiringError(Exception):
    pass


def strip_comments(t):
    t = re.sub(r'/\*.*?\*/', '', t, flags=re.S)
    return re.sub(r'//[^\n]*', '', t)


def instance_ports(text, module, inst):
    """{port: connected expression} of 'module [#(...)] inst ( ... );'."""
    t = strip_comments(text)
    m = re.search(r'\b%s\b\s*(#\s*\(.*?\)\s*)?\b%s\s*\(' % (module, inst), t, re.S)
    if not m:
        raise WiringError('no instance %s %s' % (module, inst))
    i, depth = m.end(), 1
    start = i
    while depth and i < len(t):
        if t[i] == '(':
            depth += 1
        elif t[i] == ')':
            depth -= 1
        i += 1
    body = t[start:i - 1]
    ports = {}
    for p, e in re.findall(r'\.(\w+)\s*\(\s*([^()]*?)\s*\)', body):
        if p in ports:
            raise WiringError('%s %s: port %s connected twice' % (module, inst, p))
        ports[p] = e
    return ports


def machine_wiring(machine, core):
    """The ngpc_cart_save output that drives the bridge's save_busy_i."""
    mt = open(machine).read()
    assigns = re.findall(r'^\s*assign\s+save_busy_state\s*=\s*([^;]*?)\s*;',
                         strip_comments(mt), re.M)
    if len(assigns) != 1:
        raise WiringError('%s: %d assignments to save_busy_state, want 1' % (machine, len(assigns)))
    net = assigns[0]
    if not re.fullmatch(r'\w+', net):
        raise WiringError('%s: save_busy_state = %r, not a plain net' % (machine, net))
    ports = instance_ports(mt, 'ngpc_cart_save', 'cart_save')
    hits = [p for p, e in ports.items() if e == net]
    if len(hits) != 1:
        raise WiringError('%s: save_busy_state = %s, which is on %d ngpc_cart_save ports %s'
                          % (machine, net, len(hits), hits))
    port = hits[0]
    if port not in ENGINE_PORTS:
        raise WiringError('%s: save_busy_state = %s = cart_save.%s, which this bench does not model'
                          % (machine, net, port))
    ct = open(core).read()
    br = instance_ports(ct, 'ngpc_savestate_bridge', 'savestate_bridge').get('save_busy_i')
    mc = instance_ports(ct, 'ngpc_machine', 'machine').get('save_busy_state')
    if not br or br != mc:
        raise WiringError('%s: bridge save_busy_i = %r, machine save_busy_state = %r: not one net'
                          % (core, br, mc))
    if re.search(r'^\s*assign\s+%s\b' % re.escape(br), strip_comments(ct), re.M):
        raise WiringError('%s: %s is also assigned' % (core, br))
    return port, net, br


SCENARIOS = r'''
	// =========================================================================
	// rc6 family F (sim/tb_rc6f_mkheld.py): what the held and drained bits
	// record, on the real bridge, copier and save engine
	// =========================================================================
	integer i, n;
	string  only_scn, capdir;
	reg     chk_seen = 0, chk_busy = 0, chk_hold = 0, chk_sbi = 0;
	reg     hold_arm = 0, hold_seen = 0;
	integer rd_moves = 0;
	reg [13:0] rd_prev = 14'd0;
	// the bridge's identity-check decision cycle: S_LOAD_CHECK, step 5 --
	// the cycle it samples save_busy_i into the held bit
	always @(posedge clk_sys)
		if (u_bridge.state == 4'd4 && u_bridge.id_cnt == 3'd5) begin
			chk_seen <= 1'b1; chk_busy <= busy; chk_hold <= boot_hold;
			chk_sbi  <= u_bridge.save_busy_i;
		end
	// boot_hold_o seen high between the arm (before the transfer) and the check
	always @(posedge clk_sys) if (hold_arm && !chk_seen && boot_hold === 1'b1) hold_seen <= 1'b1;
	// the copier's read address: every move counted
	always @(posedge clk_sys) begin
		if (br_img_rd_addr !== rd_prev) rd_moves = rd_moves + 1;
		rd_prev = br_img_rd_addr;
	end

	function automatic string fields(input [31:0] w);
		fields = $sformatf("loads %0d ran %0d ok %0d chk %05b frozen %0d drained %0d HELD %0d",
		                   w[23:20], w[19], w[18], w[17:13], w[12], w[11], w[10]);
	endfunction

	task write_cap(input string name);
		integer k, fd;
		begin
			fd = $fopen($sformatf("%s/%s.hex", capdir, name), "w");
			for (k = 0; k < WORDS; k = k + 1) $fwrite(fd, "%08h\n", image[k]);
			$fclose(fd);
		end
	endtask

	// what the stamp's held bit says against what happened at the check
	task judge(input string name, input want_held);
		reg held;
		begin
			held = image[8419][10];
			$display("   %0s: word 8419 = %08h: %0s", name, image[8419], fields(image[8419]));
			$display("   %0s: at the identity check save_busy_i=%b busy_o=%b boot_hold_o=%b; boot_hold_o high between the transfer and the check: %b",
			         name, chk_sbi, chk_busy, chk_hold, hold_seen);
			if (image[8419][31:24] !== 8'hD1) fail("word 8419 carries no D1 stamp");
			if (held !== chk_sbi) fail("held is not save_busy_i at the check");
			// the documented meaning: the boot apply still held the machine
			if (held !== chk_hold)
				`FAIL(("held = %0d, but the boot apply %0s the machine at the check (boot_hold_o = %b): savinfo will say the load %0s",
				       held, chk_hold ? "held" : "did not hold", chk_hold,
				       held ? "arrived while the core was still starting up" : "arrived after startup"))
			if (held !== want_held)
				`FAIL(("held = %0d, want %0d", held, want_held))
			write_cap(name);
		end
	endtask

	function automatic integer want(input string name);
		want = (only_scn == "" || only_scn == name);
	endfunction

	initial begin
		if (!$value$plusargs("SCN=%s", only_scn)) only_scn = "";
		if (!$value$plusargs("CAPDIR=%s", capdir)) capdir = "sim/tb_rc6f_out/held";
		for (i = 0; i < FLASHW; i = i + 1) begin sdram[i] = rom(i); gold[i] = rom(i); end
		for (i = 0; i < 2*BANKW; i = i + 1) psram[i] = 16'hDEAD;
		for (i = 0; i < WORDS; i = i + 1) image[i] = 32'd0;
		machine_cold;
		repeat (20) @(posedge clk_sys);

		// a healthy session and a good layout-2 Memory of it
		begin_scn("SETUP", "good file accepted at boot, the game saves, a Memory is captured");
		reconfigure(CRC_A, 1);
		seeds_clear; seed_of[8] = 8'h31; seed_of[10] = 8'h32;
		build_img(64'h500, TAG_V4, CRC_A);
		apf_deliver;
		mark;
		settle;
		later_save_publishes(9, 8'h33);
		machine_init(8'h14);
		capture(32'd2, CRC_A);
		if (image[8419] !== 32'hD1000000) `FAIL(("word 8419 = %08h, want D1000000 (no load yet)", image[8419]))
		blob_keep(B_L2, 8'h14);
		end_scn;

		// ---- the save engine idle at the check --------------------------------
		if (want("HELD-IDLE")) begin
		begin_scn("HELD-IDLE", "Memory load with the save engine idle");
		wait_idle(600000);
		machine_cold;
		blob_take(B_L2);
		chk_seen = 0; hold_arm = 1; hold_seen = 0;
		mark;
		do_load(1, WORDS);
		hold_arm = 0;
		if (!ld_ok) fail("the Memory did not load");
		if (!chk_seen) fail("(bench) the identity check was not observed");
		wait_idle(600000);
		capture(32'd2, CRC_A);
		judge("HELD-IDLE", 1'b0);
		end_scn;
		end

		// ---- a background staging pass at the check ---------------------------
		if (want("HELD-LATE")) begin
		begin_scn("HELD-LATE", "Memory load during a background staging pass, long after the boot apply");
		wait_idle(600000);
		machine_cold;
		blob_take(B_L2);
		apf_write_burst(1);
		// the bridge's quiet gate (100,000 clk_74a) passes before the command
		repeat (110000) @(posedge clk_74a);
		chk_seen = 0; hold_arm = 1; hold_seen = 0;
		// the game saves again; QUIET clocks later the stager starts a pass
		blk_seed(8, 8'h36);
		flash_write(6'd8);
		n = 0;
		while (!(busy === 1'b1 && boot_hold === 1'b0) && n < 200000) begin @(posedge clk_sys); n = n + 1; end
		if (n >= 200000) fail("(setup) no staging pass started");
		mark;
		apf_load;
		hold_arm = 0;
		if (!chk_seen) fail("(bench) the identity check was not observed");
		else if (!(chk_busy === 1'b1 && chk_hold === 1'b0))
			`FAIL(("(setup) at the check busy_o=%b boot_hold_o=%b: not a background pass", chk_busy, chk_hold))
		if (!ld_ok) fail("the Memory did not load");
		wait_idle(600000);
		capture(32'd2, CRC_A);
		judge("HELD-LATE", 1'b0);
		end_scn;
		end

		// ---- a wake: the delivered file's boot apply still pending ------------
		if (want("HELD-EARLY")) begin
		begin_scn("HELD-EARLY", "wake-shaped load while the boot apply is pending");
		reconfigure(CRC_A, 1);
		img_from_committed;
		apf_deliver;
		blob_take(B_L2);
		machine_cold;
		chk_seen = 0; hold_arm = 1; hold_seen = 0;
		mark;
		do_load_settle_mid_drain(1);
		hold_arm = 0;
		if (!ld_ok) fail("the wake did not load");
		if (!chk_seen) fail("(bench) the identity check was not observed");
		else if (chk_hold !== 1'b1) fail("(setup) boot_hold_o was not high at the check");
		wait_idle(600000);
		capture(32'd2, CRC_A);
		judge("HELD-EARLY", 1'b1);
		end_scn;
		end

		// ---- a reset cuts a drain at word 1; the next load times out ----------
		if (want("C3-REAL")) begin : c3real
		reg cut_drained, cut_in_cart;
		reg [13:0] addr_after;
		begin_scn("C3-REAL", "a reset cuts a drain at section word 1; the next load is a copier timeout");
		wait_idle(600000);
		machine_cold;
		blob_take(B_L2);
		apf_write_burst(1);
		mark;
		// the load command, by hand: this load never reports (the reset cuts it)
		@(posedge clk_74a); ss_load_req <= 1;
		n = 0;
		while (load_ack !== 1'b1 && n < 10000) begin @(posedge clk_74a); n = n + 1; end
		if (load_ack !== 1'b1) fail("APF: no savestate_load_ack");
		@(posedge clk_74a); ss_load_req <= 0;
		// the copier presents section word 1 and holds it at least six clocks
		// (sample, two staging writes); one clock later the stamp says drained
		n = 0;
		while (br_img_rd_addr !== 14'd1 && n < 4000000) begin @(posedge clk_sys); n = n + 1; end
		if (br_img_rd_addr !== 14'd1) fail("(setup) the drain never reached section word 1");
		@(posedge clk_sys);
		cut_drained = u_bridge.dg_drained;
		cut_in_cart = (u_bridge.state == 4'd8);
		if (br_img_rd_addr !== 14'd1) fail("(setup) the copier left word 1 before the cut");
		// the cut: the one reset net, as reconfigure (a core relaunch) pulses
		// it; the cartridge is downloaded again and is not ready at the load
		reset <= 1; cart_ready <= 0; slots_settled <= 0; die_busy <= 2'b00;
		event0 <= 0; apf_wr <= 0;
		repeat (10) @(posedge clk_sys);
		reset <= 0;
		addr_after = br_img_rd_addr;
		$display("   C3-REAL: at the cut the stamp said drained=%b (S_LOAD_CART %0d); after the reset cart_img_rd_addr=%0d",
		         cut_drained, cut_in_cart, addr_after);
		if (cut_drained !== 1'b1 || !cut_in_cart)
			fail("(setup) the cut load had not reached the copier's drain as the stamp sees it");
		// The cut transfer never finished, so APF's write pointer (clk_74a,
		// not on the reset net) is rewound only by the bridge's half-second
		// idle backstop -- long past by the next transfer on the device, a
		// few microseconds away here. Fast-forward the idle count to its
		// last 16 clocks and let the RTL's own backstop do it.
		@(negedge clk_74a) u_bridge.xfer_idle = 26'd37_000_000 - 26'd16;
		repeat (40) @(posedge clk_74a);
		if (u_bridge.wr_ptr !== 15'd0) fail("(setup) the bridge's write pointer did not rewind after the cut transfer");
		for (i = 0; i < FLASHW; i = i + 1) begin sdram[i] = rom(i); gold[i] = rom(i); end
		machine_cold;
		@(posedge clk_sys); cart_replace <= 1;
		@(posedge clk_sys); cart_replace <= 0;
		repeat (4) @(posedge clk_sys);
		@(posedge clk_sys); slots_settled <= 1'b1;
		repeat (100) @(posedge clk_sys);
		// the next load: the copier's stager wait times out (BF-TO's shape)
		blob_take(B_L2);
		mark;
		rd_moves = 0;
		do_load(1, WORDS);
		if (ld_ok) fail("a load passed a copier that never drained");
		if (n_ldreq - c_ldreq != 1) fail("(setup) the bridge did not hand the section to the copier");
		if (n_drain != c_drain) fail("(setup) staging drained on the timeout path");
		if (rd_moves != 0) `FAIL(("(setup) the copier moved its read address %0d time(s) on the timeout path", rd_moves))
		$display("   C3-REAL: the copier's read address through the timeout load: %0d", br_img_rd_addr);
		@(posedge clk_sys); cart_ready <= 1'b1;
		wait_idle(600000);
		$display("   C3-REAL: session frozen_o=%b after the failed load", frozen);
		capture(frozen === 1'b1 ? 32'd3 : 32'd2, CRC_A);
		$display("   C3-REAL: word 8419 = %08h: %0s", image[8419], fields(image[8419]));
		if (image[8419] !== 32'hD113E000)
			`FAIL(("word 8419 = %08h (%0s), want D113E000 (loads 1, all five identity terms, not ran, not drained, not held): %0s",
			       image[8419], fields(image[8419]),
			       image[8419][11] ? "drained reads 1, so savinfo calls this copier timeout an apply refusal" : "see the fields"))
		write_cap("C3-REAL");
		end_scn;
		end

		$display("== %0d scenario(s), %0d failed, %0.1f ms simulated", n_scn, n_scn_fail, $realtime / 1.0e6);
		if (errors == 0) $display("== RC6F HELD BENCH: ALL PASS");
		else             $display("== RC6F HELD BENCH: %0d FAILURE(S)", errors);
		$finish;
	end

'''


def build(machine, core, out):
    port, net, top_net = machine_wiring(machine, core)
    src = open(SRC).read().split('\n')
    try:
        run = next(i for i, ln in enumerate(src) if ln.strip() == '// The run')
        dog = next(i for i, ln in enumerate(src) if ln.strip().startswith('// ---- watchdog'))
        mod = next(i for i, ln in enumerate(src) if ln.startswith('module tb_rc5_loadpath;'))
        br0 = next(i for i, ln in enumerate(src) if ln.strip().startswith('ngpc_savestate_bridge u_bridge'))
        sv0 = next(i for i, ln in enumerate(src) if ln.strip().startswith(') u_save ('))
    except StopIteration:
        raise WiringError('sim/tb_rc5_loadpath.sv no longer has the expected markers')
    # the bench net on the engine port
    bench_net = None
    for ln in src[sv0:sv0 + 80]:
        m = re.match(r'\s*\.%s\s*\(\s*(\w+)\s*\)' % port, ln)
        if m:
            bench_net = m.group(1)
            break
        if ln.strip() == ');':
            break
    if not bench_net:
        raise WiringError('sim/tb_rc5_loadpath.sv: u_save has no .%s' % port)
    # the bridge's save_busy_i line, exactly one, inside u_bridge
    sbi = [i for i in range(br0, br0 + 60) if re.match(r'\s*\.save_busy_i\s*\(\s*\w+\s*\),', src[i])]
    if len(sbi) != 1:
        raise WiringError('sim/tb_rc5_loadpath.sv: %d .save_busy_i lines in u_bridge, want 1' % len(sbi))
    head = src[:run - 1]            # up to the '// ====' line before '// The run'
    head[mod] = 'module tb_rc6f_held;'
    indent = re.match(r'\s*', head[sbi[0]]).group(0)
    head[sbi[0]] = ('%s.save_busy_i     (%s),   // tb_rc6f_mkheld: = ngpc_machine save_busy_state'
                    ' = %s = cart_save.%s' % (indent, bench_net, net, port))
    rel = os.path.relpath(machine, ROOT).replace(os.sep, '/')
    out_lines = ['// GENERATED by sim/tb_rc6f_mkheld.py from sim/tb_rc5_loadpath.sv -- do not edit.',
                 "// The bridge's save_busy_i is wired as %s wires it: save_busy_state = %s," % (rel, net),
                 "// the save engine's %s (core_top: both on %s)." % (port, top_net),
                 '// The scenario list is replaced by the scenarios described there.',
                 ''] + head + SCENARIOS.split('\n') + src[dog:]
    with open(out, 'w') as f:
        f.write('\n'.join(out_lines))
    return port, net, bench_net


def main(argv):
    machine, core, out, wiring = MACHINE, CORE, DST, False
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == '--wiring':
            wiring = True
        elif a in ('--machine', '--core', '--out') and args:
            v = args.pop(0)
            if a == '--machine':
                machine = v
            elif a == '--core':
                core = v
            else:
                out = v
        else:
            print(__doc__)
            return 2
    try:
        if wiring:
            port, net, top_net = machine_wiring(machine, core)
            print(port)
            return 0
        port, net, bench_net = build(machine, core, out)
    except (WiringError, OSError) as e:
        print('tb_rc6f_mkheld: %s' % e)
        return 1
    print('wrote %s (save_busy_i = %s: ngpc_machine save_busy_state = %s = cart_save.%s)'
          % (os.path.relpath(out, ROOT).replace(os.sep, '/'), bench_net, net, port))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
