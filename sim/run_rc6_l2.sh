#!/bin/sh
# rc6 family C (issue L2): an accepted savestate's commit -- and the pass
# publish -- wait for the staging host port, port-free. sim/tb_rc6c_bench.sv
# on the REAL rc6 RTL (target/pocket, upstream) with the rc6 follow-up patch,
# wired as rc6 core_top.v wires it: the engine's host_busy_i is ngpc_stage_mem's
# host_busy_o alone, host_rd_i the data_unloader's read_en (the same net as
# ngpc_stage_mem's host_rd_i), draining_i the copier's draining_o, the bridge's
# save_busy_i the engine's boot_hold_o, core_top's write-port arbiter verbatim
# (all checked below).
#
#   wsl -e sh sim/run_rc6_l2.sh              everything
#   wsl -e sh sim/run_rc6_l2.sh one BUILD +ARGS...
#       one run of a build (rtl, nohold, oldwire, nordhold, nopubrd), e.g.
#       ... one rtl +SCN=x +SAVES=1 +DELAYUS=30000 +SEED=7 +RACEOFS=7 +VERBOSE=1
#   wsl -e sh sim/run_rc6_l2.sh verdicts
#       re-evaluate the logs of the last full run without simulating
#   wsl -e sh sim/run_rc6_l2.sh check
#       premises, mutants and builds only (no runs)
#
# Builds:
#   rtl      target/pocket/ngpc_cart_save.sv as it is
#   nohold   mutant (a): the S_FINISH state-commit hold removed, both terms
#            (sim/tb_rc6c_mut_nohold_cart_save.sv, made here with sed)
#   oldwire  mutant (b): the bench with host_busy_i = host_busy || sc_draining,
#            the rc5 core_top wiring (sim/tb_rc6c_mut_oldwire_bench.sv, sed)
#   nordhold mutant (c): the host_rd_i term removed from the S_FINISH hold,
#            the pre-follow-up rc6 hold (sim/tb_rc6c_mut_nordhold_cart_save.sv)
#   nopubrd  mutant (d): the !host_rd_i term removed from the pass publish
#            gate (sim/tb_rc6c_mut_nopubrd_cart_save.sv)
# Scenarios on rtl (every one must end "== ALL RC6C SCENARIOS PASS"):
#   BASE       no flush during the load (the commit waits out the drain's own
#              host tail, ~1 ms past where rc5 committed); quit flush +
#              relaunch on it
#   FA1..FA4   APF flushes the whole slot starting 400, 1500, 23000, 78000 clk
#              before the hold-free commit point (state_apply + 447644 on rc6,
#              so FLUSHAPPLY = 447244 446144 424644 369644); the bench checks
#              the reads straddle it; relaunch on that file
#   FH1, FH2   FLUSHAPPLY = 450577 449477: the flush starts while the commit
#              already holds (checked); relaunch
#   RO0..RO14  RACEOFS = 0..14: the first flush read lands around the cycle
#              the host port goes quiet under the holding commit; relaunch
#   JR7        RACEOFS=7 in a JUNK session (a power-on session with no .sav,
#              so the committed bank the state replaces holds no image): the
#              first read lands in what was the 2-clock window before the flip
#              (RO6/RO7 too); before the follow-up it was served from the old
#              bank, and word 0 is where a junk bank and an image differ. Now
#              the commit holds and the file is wholly the junk bank: no
#              relaunch can accept that, and APF never writes it (save_present
#              low at the flush, checked: sp=0), so its relaunch is "skip"
#   PUB        PUBOFS=$PUBK: a JUNK session where the game's first save is
#              published by a pass; APF's first flush read strobe is first
#              seen on the very edge the pass decides to publish (checked:
#              pub_hit). The pass must be owed, not flipped under the read
# Every flush must be wholly one image AND served from one bank (split=no).
# Mutations (each run must FAIL with the named signature):
#   nohold   BASE: the commit flips with the host port busy (commit_hb=1,
#            hold_cyc=0). FA2: the file flushed during the load is MIXED
#   oldwire  BASE: deadlock (the watchdog in the bench)
#   nordhold RO6, RO7: the flush's word 0 comes from the old bank (split=YES,
#            old_last_w=0; word 0 is the magic in both images, so the
#            content is whole). JR7: the file is MIXED (junk word 0)
#   nopubrd  PUB: the pass publishes on the edge the read was claimed
#            (flip_minus_dec=1), word 0 from the old bank, the file MIXED
# Logs: sim/tb_rc6c_logs/<build>_<scenario>.log. JOBS (default 4) runs in
# parallel. Last line: "== ALL RC6 L2 SCENARIOS PASS" or "== N FAILURE(S)";
# exit status 1 on any failure.
set -e
cd "$(dirname "$0")/.."

LOGS=sim/tb_rc6c_logs
mkdir -p "$LOGS"

COMMON="upstream/rtl/Savestates/savestates.sv target/pocket/ngpc_savestate_bridge.sv
 sim/sim_synch3.v sim/sim_dcfifo.v target/pocket/data_loader.sv
 target/pocket/data_unloader.sv target/pocket/psram.sv target/pocket/ngpc_stage_mem.sv
 upstream/rtl/cart/ngp_cart_overlay_geometry.sv target/pocket/ngpc_state_cart.sv"
IVFLAGS="-g2012 -DNGPC_SIM_SKIP_PSRAM_INIT -D SYNTHESIS -DNGPC_SAVE_DIAG=1"
CS=target/pocket/ngpc_cart_save.sv
TB=sim/tb_rc6c_bench.sv
MUT_A=sim/tb_rc6c_mut_nohold_cart_save.sv
MUT_B=sim/tb_rc6c_mut_oldwire_bench.sv
MUT_C=sim/tb_rc6c_mut_nordhold_cart_save.sv
MUT_D=sim/tb_rc6c_mut_nopubrd_cart_save.sv
BUILDS="rtl nohold oldwire nordhold nopubrd"
# PUB's offset: the pass's header word 30 begins, PUBK clk_sys later APF's
# first flush read starts; with SEED=7 its strobe is first seen on the
# publish decision edge (found with +PUBANY=1; the bench fails the run as
# "scenario invalid" if it no longer is)
PUBK=${PUBK:-11}

fails=0
bad() { echo "   FAIL $*"; fails=$((fails + 1)); }

mutants() {
	# (a) the whole S_FINISH hold removed: slot_busy_q and the read strobe
	sed 's/(slot_busy_q || host_rd_i)) begin/(slot_busy_q || host_rd_i) \&\& 0) begin \/\/ RC6C-MUTANT (a): the rc6 L2 hold removed/' \
	    "$CS" > "$MUT_A"
	# (b) the rc5 core_top wiring: host_busy || sc_draining into host_busy_i
	sed '/RC6C-WIRE/s/(host_busy)/(host_busy || sc_draining)/' "$TB" > "$MUT_B"
	# (c) the hold without the read strobe (rc6 before the follow-up)
	sed 's/(slot_busy_q || host_rd_i)) begin/(slot_busy_q)) begin \/\/ RC6C-MUTANT (c): the read strobe term removed from the hold/' \
	    "$CS" > "$MUT_C"
	# (d) the pass publish without the read strobe (rc6 before the follow-up)
	sed 's/    !host_rd_i && !draining_i && !refused_q && !saw_save_wr) begin/    !draining_i \&\& !refused_q \&\& !saw_save_wr) begin \/\/ RC6C-MUTANT (d): the read strobe term removed from the publish/' \
	    "$CS" > "$MUT_D"
}

# NAME ORIGINAL MUTANT ORIGINAL-TEXT MUTANT-TEXT: exactly one line changed,
# that line the intended one, into the intended text
mutcheck() {
	nl=$(diff "$2" "$3" | grep -c '^<' || true)
	nr=$(diff "$2" "$3" | grep -c '^>' || true)
	if [ "$nl" -ne 1 ] || [ "$nr" -ne 1 ]; then
		bad "mutant $1: the sed changed $nl line(s) into $nr, expected 1 into 1"
	elif ! diff "$2" "$3" | grep '^<' | tr -d '\r' | grep -qF -- "$4"; then
		bad "mutant $1: the changed line is not the one meant (\"$4\")"
	elif ! diff "$2" "$3" | grep '^>' | tr -d '\r' | grep -qF -- "$5"; then
		bad "mutant $1: the new line is not the one meant (\"$5\")"
	else
		echo "   ok   mutant $1 ($3): one line, as meant:"
		diff "$2" "$3" | sed 's/^/          /' || true
	fi
}

build() {
	case "$1" in
	rtl)      iverilog $IVFLAGS -o sim/tb_rc6c_rtl.vvp      -s tb_rc6c $COMMON "$CS"    "$TB" ;;
	nohold)   iverilog $IVFLAGS -o sim/tb_rc6c_nohold.vvp   -s tb_rc6c $COMMON "$MUT_A" "$TB" ;;
	oldwire)  iverilog $IVFLAGS -o sim/tb_rc6c_oldwire.vvp  -s tb_rc6c $COMMON "$CS"    "$MUT_B" ;;
	nordhold) iverilog $IVFLAGS -o sim/tb_rc6c_nordhold.vvp -s tb_rc6c $COMMON "$MUT_C" "$TB" ;;
	nopubrd)  iverilog $IVFLAGS -o sim/tb_rc6c_nopubrd.vvp  -s tb_rc6c $COMMON "$MUT_D" "$TB" ;;
	*) echo "unknown build $1"; return 1 ;;
	esac
}

if [ "$1" = "one" ]; then
	b=$2; shift 2
	mutants
	build "$b"
	# -N: a failed run ($stop) exits 1
	exec vvp -n -N "sim/tb_rc6c_$b.vvp" +BUILD="$b" "$@"
fi

echo "== rc6 L2 (family C): the state commit's and the pass publish's wait for the host port, real rc6 RTL"

if [ "$1" != verdicts ]; then
# ---- premises: the wiring this bench reproduces is the RTL's -----------------
norm() { tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]][[:space:]]*/ /g'; }
glue() { tr -d '\r' < "$1" | sed -n '/wire        apf_save_wr = bios_wr_raw && ld_is_save;/,/!(sc_host_wr && apf_save_wr);/p' | norm; }
glue target/pocket/core_top.v > "$LOGS/glue_core_top.txt"
glue "$TB"                    > "$LOGS/glue_bench.txt"
if [ "$(wc -l < "$LOGS/glue_core_top.txt")" -ne 12 ]; then
	bad "premise: core_top.v's write-port arbiter not found as 12 lines"
elif ! cmp -s "$LOGS/glue_core_top.txt" "$LOGS/glue_bench.txt"; then
	bad "premise: the bench's arbiter differs from core_top.v's"
else
	echo "   ok   premise: the bench's write-port arbiter is core_top.v's, verbatim (12 lines)"
fi
premise() {   # FILE TEXT WHAT
	if tr -d '\r' < "$1" | norm | grep -qF -- "$2"; then echo "   ok   premise: $3"
	else bad "premise: $3 ($1 has no \"$2\")"; fi
}
# the RTL
premise target/pocket/core_top.v ".host_busy (host_busy)," \
	"core_top gives the machine stage_mem's host_busy alone"
premise target/pocket/core_top.v ".host_busy_o(host_busy)," \
	"host_busy is ngpc_stage_mem's host_busy_o"
premise target/pocket/core_top.v ".draining (sc_draining)," \
	"core_top gives the machine the copier's draining"
premise target/pocket/ngpc_machine.sv ".host_busy_i (host_busy)," \
	"ngpc_machine passes host_busy to the engine's host_busy_i"
premise target/pocket/ngpc_machine.sv ".draining_i (draining)," \
	"ngpc_machine passes draining to the engine's draining_i"
premise target/pocket/core_top.v ".host_wr_ready_o(stage_host_ready)," \
	"the copier's ready comes through the arbiter (stage_host_ready)"
premise target/pocket/core_top.v ".read_en (stage_host_rd)," \
	"stage_host_rd is the staging data_unloader's read_en"
premise target/pocket/core_top.v ".host_rd_i (stage_host_rd)," \
	"stage_host_rd is ngpc_stage_mem's host_rd_i"
premise target/pocket/core_top.v ".host_rd (stage_host_rd)," \
	"core_top gives the machine stage_host_rd"
premise target/pocket/ngpc_machine.sv ".host_rd_i (host_rd)," \
	"ngpc_machine passes host_rd to the engine's host_rd_i"
premise "$CS" "(slot_busy_q || host_rd_i)) begin" \
	"the engine's S_FINISH state-commit hold is (slot_busy_q || host_rd_i)"
premise "$CS" "!host_rd_i && !draining_i && !refused_q && !saw_save_wr) begin" \
	"the engine's pass publish requires !host_rd_i"
premise target/pocket/ngpc_machine.sv "assign save_busy_state = overlay_boot_hold;" \
	"ngpc_machine's save_busy_state is the engine's boot_hold_o"
premise target/pocket/core_top.v ".save_busy_state (mc_save_busy)," \
	"core_top takes save_busy_state as mc_save_busy"
premise target/pocket/core_top.v ".save_busy_i (mc_save_busy)," \
	"mc_save_busy is the bridge's save_busy_i"
# the bench wires the same nets
premise "$TB" ".read_en (stage_host_rd)," \
	"bench: stage_host_rd is its data_unloader's read_en"
premise "$TB" ".host_rd_i (stage_host_rd)," \
	"bench: stage_host_rd is its ngpc_stage_mem's host_rd_i"
if tr -d '\r' < "$TB" | grep 'RC6C-RDWIRE' | norm | grep -qF ".host_rd_i (stage_host_rd),"; then
	echo "   ok   premise: bench: the engine's host_rd_i is the same stage_host_rd"
else bad "premise: bench: the engine's host_rd_i is not stage_host_rd (RC6C-RDWIRE)"; fi
if [ "$(tr -d '\r' < "$TB" | grep -c '^[[:space:]]*\.host_rd_i[[:space:]]*(stage_host_rd)')" -ne 2 ]; then
	bad "premise: bench: expected exactly two .host_rd_i (stage_host_rd) connections (stage_mem, engine)"
else
	echo "   ok   premise: bench: exactly two .host_rd_i connections, both stage_host_rd (stage_mem, engine)"
fi
premise "$TB" "assign mc_save_busy = overlay_boot_hold;" \
	"bench: the bridge's save_busy_i is the engine's boot_hold_o"

# ---- mutants and builds ----------------------------------------------------------
mutants
mutcheck "(a) nohold" "$CS" "$MUT_A" "(slot_busy_q || host_rd_i)) begin" \
	"(slot_busy_q || host_rd_i) && 0) begin // RC6C-MUTANT (a)"
mutcheck "(b) oldwire" "$TB" "$MUT_B" ".host_busy_i     (host_busy),   // RC6C-WIRE" \
	".host_busy_i     (host_busy || sc_draining),   // RC6C-WIRE"
mutcheck "(c) nordhold" "$CS" "$MUT_C" "(slot_busy_q || host_rd_i)) begin" \
	"(slot_busy_q)) begin // RC6C-MUTANT (c)"
mutcheck "(d) nopubrd" "$CS" "$MUT_D" "!host_rd_i && !draining_i && !refused_q && !saw_save_wr) begin" \
	"    !draining_i && !refused_q && !saw_save_wr) begin // RC6C-MUTANT (d)"
for b in $BUILDS; do
	if ! build $b > "$LOGS/build_$b.log" 2>&1; then bad "build $b (see $LOGS/build_$b.log)"; fi
done
if [ "$fails" -ne 0 ]; then echo "== $fails FAILURE(S) (premises, mutants or builds)"; exit 1; fi
if [ "$1" = check ]; then echo "== premises, mutants and builds OK (check only, no runs)"; exit 0; fi
fi

# ---- the runs ---------------------------------------------------------------------
BASEARGS="+SAVES=1 +DELAYUS=30000 +SEED=7"
JOBFILE="$LOGS/jobs.txt"
if [ "$1" != verdicts ]; then
{
	# the slow ones first
	echo "rtl JR7 +JUNK=1 +RACEOFS=7 +RELAUNCHMID=1"
	echo "nordhold JR7 +JUNK=1 +RACEOFS=7 +RELAUNCHMID=1"
	echo "rtl BASE +FLUSH=2 +RELAUNCH=1"
	echo "rtl FA1 +FLUSHAPPLY=447244 +FLUSH=2 +RELAUNCHMID=1"
	echo "rtl FA2 +FLUSHAPPLY=446144 +FLUSH=2 +RELAUNCHMID=1"
	echo "rtl FA3 +FLUSHAPPLY=424644 +FLUSH=2 +RELAUNCHMID=1"
	echo "rtl FA4 +FLUSHAPPLY=369644 +FLUSH=2 +RELAUNCHMID=1"
	echo "rtl FH1 +FLUSHAPPLY=450577 +HOLDFLUSH=1 +RELAUNCHMID=1"
	echo "rtl FH2 +FLUSHAPPLY=449477 +HOLDFLUSH=1 +RELAUNCHMID=1"
	k=0
	while [ $k -le 14 ]; do echo "rtl RO$k +RACEOFS=$k +RELAUNCHMID=1"; k=$((k + 1)); done
	echo "rtl PUB +PUBOFS=$PUBK"
	echo "nohold BASE +FLUSH=2 +RELAUNCH=1"
	echo "nohold FA2 +FLUSHAPPLY=446144 +FLUSH=2 +RELAUNCHMID=1"
	echo "oldwire BASE +FLUSH=2 +RELAUNCH=1"
	echo "nordhold RO6 +RACEOFS=6"
	echo "nordhold RO7 +RACEOFS=7"
	echo "nopubrd PUB +PUBOFS=$PUBK"
} > "$JOBFILE"
	rm -f "$LOGS"/*_*.log "$LOGS"/*_*.rc
	echo "   $(wc -l < "$JOBFILE") runs, ${JOBS:-4} at a time (several minutes each; much longer on a loaded machine)"
	# every line: BUILD SCN ARGS...; the exit status goes to <log>.rc
	xargs -P "${JOBS:-4}" -L 1 sh -c '
		b=$1; s=$2; shift 2
		vvp -n -N sim/tb_rc6c_$b.vvp +BUILD=$b +SCN=$s '"$BASEARGS"' "$@" > '"$LOGS"'/${b}_$s.log 2>&1
		echo $? > '"$LOGS"'/${b}_$s.rc' sh < "$JOBFILE"
else
	echo "   verdicts only, from the logs already in $LOGS/ (jobs: $JOBFILE)"
fi

# ---- verdicts ---------------------------------------------------------------------
res() { grep '^== RC6C RESULT' "$LOGS/$1.log" 2>/dev/null | tail -n 1; }
pubres() { grep '^== RC6C PUBRACE' "$LOGS/$1.log" 2>/dev/null | tail -n 1; }
field() { res "$1" | tr ' ' '\n' | grep "^$2=" | head -n 1 | cut -d= -f2; }
pfield() { pubres "$1" | tr ' ' '\n' | grep "^$2=" | head -n 1 | cut -d= -f2; }
last() { tail -n 1 "$LOGS/$1.log" 2>/dev/null; }
rc() { cat "$LOGS/$1.rc" 2>/dev/null || echo 99; }
rl() { res "$1" | sed -n 's/.*relaunch verdict=\([^ ]*\) frozen=\([^ ]*\).*/\1\/\2/p'; }

echo "== rtl scenarios (must pass)"
while read -r b s args; do
	[ "$b" = rtl ] || continue
	r=$(res rtl_$s)
	if [ "$s" = PUB ]; then
		line="PUB   file=$(pfield rtl_PUB mid_flush) pub_hit=$(pfield rtl_PUB pub_hit) rd-dec=$(pfield rtl_PUB rd_minus_dec) flip-dec=$(pfield rtl_PUB flip_minus_dec) split=$(pfield rtl_PUB split) old=$(pfield rtl_PUB old) new=$(pfield rtl_PUB new)"
		[ "$(pfield rtl_PUB pub_hit)" = YES ] || r=""
	else
		line="$(printf '%-5s' $s) file=$(field rtl_$s mid_flush) straddle=$(field rtl_$s straddle) commit=$(field rtl_$s commit_vs_flush) rd-commit=$(field rtl_$s first_rd_minus_commit) hold_us=$(field rtl_$s hold_us) split=$(field rtl_$s split) sp=$(field rtl_$s sp_at_flush) relaunch=$(rl rtl_$s)"
	fi
	if [ "$(rc rtl_$s)" = 0 ] && [ "$(last rtl_$s)" = "== ALL RC6C SCENARIOS PASS" ] && [ -n "$r" ]; then
		echo "   PASS $line"
	else
		bad "$line  ($(last rtl_$s))"
		grep 'FAIL \[' "$LOGS/rtl_$s.log" 2>/dev/null | head -n 4 | sed 's/^ */          /'
	fi
done < "$JOBFILE"

# CAUGHT when the run failed AND shows the named signature
catch() {   # LOG SIGNATURE-OK(0/1) DESCRIPTION
	if [ "$(rc $1)" != 0 ] && [ "$2" = 1 ]; then
		echo "   CAUGHT $(printf '%-13s' $1) $3 :: $(last $1)"
	else
		bad "$1 not caught as: $3 (rc $(rc $1)): $(last $1)"
		return 1
	fi
}

echo "== mutation (a) nohold: the S_FINISH hold removed (must be caught)"
caught_a=1
ok=0; [ "$(field nohold_BASE commit_hb)" = 1 ] && [ "$(field nohold_BASE hold_cyc)" = 0 ] && ok=1
catch nohold_BASE $ok "commit_hb=1 hold_cyc=0" || caught_a=0
ok=0; [ "$(field nohold_FA2 mid_flush)" = MIXED ] && ok=1
catch nohold_FA2 $ok "mid_flush=MIXED (old=$(field nohold_FA2 old) new=$(field nohold_FA2 new) split=$(field nohold_FA2 split))" || caught_a=0

echo "== mutation (b) oldwire: host_busy_i = host_busy || sc_draining (must deadlock)"
caught_b=1
ok=0; [ "$(field oldwire_BASE deadlock)" = YES ] && ok=1
catch oldwire_BASE $ok "deadlock: $(grep -m1 'FAIL .*DEADLOCK' "$LOGS/oldwire_BASE.log" 2>/dev/null | sed 's/^ *FAIL //')" || caught_b=0

echo "== mutation (c) nordhold: the read strobe removed from the S_FINISH hold (must be caught)"
caught_c=1
for s in RO6 RO7; do
	f=nordhold_$s
	ok=0; [ "$(field $f split)" = YES ] && [ "$(field $f old_last_w)" = 0 ] && ok=1
	catch $f $ok "split=YES old_last_w=0: word 0 from the old bank (rd-commit=$(field $f first_rd_minus_commit), file=$(field $f mid_flush))" || caught_c=0
done
ok=0; [ "$(field nordhold_JR7 mid_flush)" = MIXED ] && ok=1
catch nordhold_JR7 $ok "mid_flush=MIXED (old=$(field nordhold_JR7 old) new=$(field nordhold_JR7 new); relaunch $(rl nordhold_JR7))" || caught_c=0

echo "== mutation (d) nopubrd: the read strobe removed from the pass publish gate (must be caught)"
caught_d=1
f=nopubrd_PUB
ok=0
[ "$(pfield $f pub_hit)" = YES ] && [ "$(pfield $f flip_minus_dec)" = 1 ] && \
	[ "$(pfield $f mid_flush)" = MIXED ] && [ "$(pfield $f old_last_w)" = 0 ] && ok=1
catch $f $ok "pub_hit=YES flip_minus_dec=1 old_last_w=0 mid_flush=MIXED (old=$(pfield $f old) new=$(pfield $f new))" || caught_d=0

# ---- the commit's delay against the hold-free commit, no flush -------------------
a=$(field rtl_BASE commit_after_sapply); z=$(field nohold_BASE commit_after_sapply)
if [ -n "$a" ] && [ -n "$z" ] && [ "$a" -ge 0 ] 2>/dev/null && [ "$z" -ge 0 ] 2>/dev/null; then
	d=$((a - z))
	echo "== no flush: rc6 commits $a clk after state_apply; with the hold removed (mutant a, rc5's S_FINISH) $z: +$d clk = $((d * 1000 / 49152)) us"
fi

yn() { [ "$1" = 1 ] && echo CAUGHT || echo MISSED; }
echo "== mutation (a): $(yn $caught_a); (b): $(yn $caught_b); (c): $(yn $caught_c); (d): $(yn $caught_d)"
if [ "$fails" -eq 0 ]; then
	echo "== ALL RC6 L2 SCENARIOS PASS"
else
	echo "== $fails FAILURE(S) (see above and $LOGS/)"
	exit 1
fi
