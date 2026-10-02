#!/bin/sh
# rc6 family A: issue R1 (saveless_erased, made program-aware by the rc6
# follow-up) and the flash-idle guard in target/pocket/ngpc_cart_save.sv,
# against the REAL rc6 RTL.
#
#   wsl -e sh sim/run_rc6_r1.sh [all|bench|t9s|t9sfull|full]
#
#   bench  1. sim/tb_rc6a_classify.sv: the follow-up's program/erase
#          classifier against the REAL upstream flash_die (programs at store
#          latency 3/8/64, erases of the 8 KB and 16 KB blocks, a program
#          after an erase cut by a reset, a program straight after an erase),
#          built against the real engine and the classifier mutants:
#            progall  (m2) every event a program   ERASE-8K ERASE-16K PROG-AFTER
#            prog0    (m3) every event an erase    PROG-L3 PROG-L8 PROG-L64 PROG-CUT PROG-AFTER
#            norestart busy count not restarted     PROG-CUT
#          2. sim/tb_rc6a_bench.sv (the tb_r6a R1 bench ported to the real rc6
#          engine, stage_mem and core_top glue, the guard scenarios and the
#          follow-up's G-PROG / WAKE-PROG), built against
#          target/pocket/ngpc_cart_save.sv and against each mutant from
#          sim/tb_rc6a_mutants.sh. The real engine must pass every scenario;
#          each mutant must fail exactly its own scenarios among the ones the
#          real engine passes:
#            nor1     R1 removed                  MEM MEM-ERASE WAKE-LATE WAKE-ERASE
#            nodata   no !image_has_data          G-DATA
#            noprog   no !prog_since_publish      G-PEND G-PROG WAKE-PROG
#            noovf    no !pack_overflow           G-OVF
#            nodeliv  no !apf_delivered/!pre_delivered/!base_q  G-DELIV G-BASE
#            nobase   no !base_q                  G-BASE
#            pend     (m1) !stage_pending in place of !prog_since_publish
#                                                 MEM-ERASE WAKE-ERASE
#            progall  (m2) every event a program  MEM-ERASE WAKE-ERASE
#            prog0    (m3) every event an erase   G-PEND G-PROG WAKE-PROG
#            nopubclr publish keeps prog_since_publish
#                                                 CAP MEM MEM-ERASE WAKE-LATE G-PROG WAKE-PROG
#            noguard  flash-idle guard removed    MEM-ERASE WAKE-ERASE GUARD-A GUARD-B G-PROG WAKE-PROG
#   t9s    the T9S wake matrix with the real ngp_cart + flash_die
#          (sim/tb_rc6a_t9s.sh quick: rc6 captures, the R1 subset and the late
#          loads), then the mutants on it: mut-noguard, mut-nor1, mut-pend
#          (m1), mut-progall (m2) -- each of their wakes must fail as listed
#          in sim/tb_rc6a_t9s.sh
#   t9sfull  the full T9S matrix (29 captures, 90 wakes), the same mutants
#          on it, and rc5's captures (sim/tb_t9s_out, read only) woken on rc6
#   all    (default) bench, then t9s
#   full   bench, then t9sfull
#
# XVER=0 leaves the rc5-capture wakes out of t9sfull/full (20 wakes, ~2 CPU-h);
# the script says so. They are also left out (and the script says so) when
# sim/tb_t9s_out is absent: those rc5 captures come from the rc5-era
# run_t9s.sh bench and are not in git. JOBS (default 4) runs in parallel. Logs: sim/tb_rc6a_logs/ (bench) and
# sim/tb_rc6a_t9s_out/ (T9S). The last line is "== ALL RC6 R1 SCENARIOS PASS"
# or "== N FAILURE(S) ...", and the script then exits 1.
#
# State on the rc6 worktree (2026-10-01, rc6 + the follow-up patch, the RTL
# committed as 2695c4c on branch rc6): `JOBS=3 XVER=0 ... full` PASSES (log
# sim/tb_rc6a_logs/run_full.out): classify 7/7 and every classifier mutant
# killed exactly; the bench 15/15 on the real engine (MEM-ERASE, WAKE-ERASE,
# G-PROG, WAKE-PROG included) and all 11 mutants killed exactly; T9S full
# 29 captures + 90 wakes all load, every real flash_die event read as an
# erase; the four T9S mutant sets killed. On the pre-follow-up RTL (night of
# 2026-09-30) MEM-ERASE, WAKE-ERASE and 12 T9S wakes (w_bios/w_busy/w_busy2
# of c_snk, c_snk_rom, c_pre_rom, c_seq_160) were refused.
cd "$(dirname "$0")/.."
. sim/tb_rc6a_pool.sh

MODE=${1:-all}
JOBS=${JOBS:-4}
export JOBS
LOG=sim/tb_rc6a_logs
mkdir -p "$LOG"
NF=0
SUMMARY=""

case "$MODE" in all|bench|t9s|t9sfull|full) ;; *) echo "usage: $0 [all|bench|t9s|t9sfull|full]"; exit 2 ;; esac

targets() {
	case "$1" in
	real)     echo "" ;;
	nor1)     echo "MEM MEM-ERASE WAKE-LATE WAKE-ERASE" ;;
	nodata)   echo "G-DATA" ;;
	noprog)   echo "G-PEND G-PROG WAKE-PROG" ;;
	noovf)    echo "G-OVF" ;;
	nodeliv)  echo "G-DELIV G-BASE" ;;
	nobase)   echo "G-BASE" ;;
	pend)     echo "MEM-ERASE WAKE-ERASE" ;;
	progall)  echo "MEM-ERASE WAKE-ERASE" ;;
	prog0)    echo "G-PEND G-PROG WAKE-PROG" ;;
	nopubclr) echo "CAP MEM MEM-ERASE WAKE-LATE G-PROG WAKE-PROG" ;;
	noguard)  echo "MEM-ERASE WAKE-ERASE GUARD-A GUARD-B G-PROG WAKE-PROG" ;;
	esac
}
ctargets() {
	case "$1" in
	real)      echo "" ;;
	progall)   echo "ERASE-8K ERASE-16K PROG-AFTER" ;;
	prog0)     echo "PROG-L3 PROG-L8 PROG-L64 PROG-CUT PROG-AFTER" ;;
	norestart) echo "PROG-CUT" ;;
	esac
}

# compare a mutant's failures with its targets, on the scenarios the real
# engine passes: prefix variant targets-function
compare() {
	p=$1; v=$2
	$3 "$v" | tr ' ' '\n' | grep -v '^$' | sort -u > "$LOG/$p$v.want"
	comm -12 "$LOG/$p$v.want" "$LOG/${p}real.pass" > "$LOG/$p$v.wantp"
	comm -12 "$LOG/$p$v.fail" "$LOG/${p}real.pass" > "$LOG/$p$v.got"
	w=$(tr '\n' ' ' < "$LOG/$p$v.wantp"); g=$(tr '\n' ' ' < "$LOG/$p$v.got")
	if [ ! -s "$LOG/$p$v.wantp" ]; then
		NF=$((NF + 1)); SUMMARY="$SUMMARY mut:$p$v-undemonstrable"
		echo "   $v: NOT DEMONSTRABLE -- every target ($($3 "$v")) fails on the real engine too"
	elif cmp -s "$LOG/$p$v.wantp" "$LOG/$p$v.got"; then
		echo "   $v: killed, fails exactly: $g"
	else
		NF=$((NF + 1)); SUMMARY="$SUMMARY mut:$p$v"
		echo "   $v: MISMATCH -- must fail exactly: $w; failed: $g"
	fi
	x=$(comm -23 "$LOG/$p$v.want" "$LOG/${p}real.pass" | tr '\n' ' ')
	[ -n "$x" ] && echo "      (target(s) the real engine fails as well, not compared: $x)"
	y=$(comm -12 "$LOG/$p$v.pass" "$LOG/${p}real.fail" | tr '\n' ' ')
	[ -n "$y" ] && echo "      (note: this mutant PASSES $y, which the real engine fails)"
}

# read a run's per-scenario verdicts: prefix variant
verdicts() {
	f=$LOG/$1$2.log
	grep -E '^   PASS [A-Z0-9-]+$' "$f" | awk '{print $2}' | sort -u > "$LOG/$1$2.pass"
	grep -E '^   FAIL [A-Z0-9-]+ \(' "$f" | awk '{print $2}' | sort -u > "$LOG/$1$2.fail"
	if ! grep -q '^== [0-9]* scenario(s) run' "$f"; then
		NF=$((NF + 1)); SUMMARY="$SUMMARY bench:$1$2-incomplete"
		echo "   $1$2: INCOMPLETE run ($(tail -n 1 "$f"))"
	fi
}

# the real engine's failures are RTL defects (or bench faults): prefix
real_report() {
	echo "   pass: $(tr '\n' ' ' < "$LOG/${1}real.pass")"
	for s in $(cat "$LOG/${1}real.fail"); do
		NF=$((NF + 1)); SUMMARY="$SUMMARY $1real:$s"
		echo "   FAILS on the real engine: $s"
		grep -E "^   FAIL \[$s\]|^   $s: " "$LOG/${1}real.log" | sed 's/^/      /'
	done
	if ! grep -q '^== ALL RC6A' "$LOG/${1}real.log"; then
		if [ ! -s "$LOG/${1}real.fail" ]; then
			NF=$((NF + 1)); SUMMARY="$SUMMARY $1real:summary"
			echo "   the real engine's run did not end in ALL ... PASS: $(tail -n 1 "$LOG/${1}real.log")"
		fi
	fi
}

# ============================================================================
# bench
# ============================================================================
if [ "$MODE" = all ] || [ "$MODE" = bench ] || [ "$MODE" = full ]; then
	echo "== RC6A bench: mutants"
	if ! sh sim/tb_rc6a_mutants.sh; then
		echo "== 1 FAILURE(S): the mutants could not be built"
		exit 1
	fi

	# ---- 1. the classifier against the real flash_die -------------------------
	CVARIANTS="real progall prog0 norestart"
	for v in $CVARIANTS; do
		if [ "$v" = real ]; then e=target/pocket/ngpc_cart_save.sv; else e=sim/tb_rc6a_mut_$v.sv; fi
		if ! iverilog -g2012 -D SYNTHESIS -DNGPC_SAVE_DIAG=1 -o sim/tb_rc6a_cls_$v.vvp -s tb_rc6a_classify \
		        $e upstream/rtl/cart/ngp_cart_overlay_geometry.sv upstream/rtl/cart/flash_die.sv sim/tb_rc6a_classify.sv; then
			echo "== 1 FAILURE(S): the classify $v build failed"
			exit 1
		fi
	done
	echo "== RC6A classify: $CVARIANTS (real flash_die), $JOBS at a time (~20 s each)"
	: > "$LOG/.cmds_cls"
	for v in $CVARIANTS; do
		rm -f "$LOG/cls_$v.log"
		printf '%s\n' "vvp -N sim/tb_rc6a_cls_$v.vvp > $LOG/cls_$v.log 2>&1; echo \"   ran $v (exit \$?): \$(tail -n 1 $LOG/cls_$v.log)\"" >> "$LOG/.cmds_cls"
	done
	rc6a_pool "$LOG/.cmds_cls" "$LOG/.pool_cls"
	for v in $CVARIANTS; do verdicts cls_ "$v"; done
	echo "== RC6A classify: the real engine"
	real_report cls_
	grep -E '^   event:' "$LOG/cls_real.log" | sed 's/^/   /'
	echo "== RC6A classify: mutants (compared on the scenarios the real engine passes)"
	for v in $CVARIANTS; do
		[ "$v" = real ] && continue
		compare cls_ "$v" ctargets
	done

	# ---- 2. the R1 / guard bench ---------------------------------------------
	COMMON="upstream/rtl/Savestates/savestates.sv target/pocket/ngpc_savestate_bridge.sv sim/sim_synch3.v target/pocket/psram.sv target/pocket/ngpc_stage_mem.sv upstream/rtl/cart/ngp_cart_overlay_geometry.sv target/pocket/ngpc_state_cart.sv sim/tb_rc6a_bench.sv"
	VARIANTS="real nor1 nodata noprog noovf nodeliv nobase pend progall prog0 nopubclr noguard"
	for v in $VARIANTS; do
		if [ "$v" = real ]; then e=target/pocket/ngpc_cart_save.sv; else e=sim/tb_rc6a_mut_$v.sv; fi
		if ! iverilog -g2012 -D SYNTHESIS -DNGPC_SAVE_DIAG=1 -o sim/tb_rc6a_$v.vvp -s tb_rc6a_bench $e $COMMON; then
			echo "== 1 FAILURE(S): the $v build failed"
			exit 1
		fi
	done
	echo "== RC6A bench: $VARIANTS, $JOBS at a time (~18 min each)"
	: > "$LOG/.cmds_bench"
	for v in $VARIANTS; do
		rm -f "$LOG/$v.log"
		printf '%s\n' "vvp -N sim/tb_rc6a_$v.vvp > $LOG/$v.log 2>&1; echo \"   ran $v (exit \$?): \$(tail -n 1 $LOG/$v.log)\"" >> "$LOG/.cmds_bench"
	done
	rc6a_pool "$LOG/.cmds_bench" "$LOG/.pool_bench"
	for v in $VARIANTS; do verdicts "" "$v"; done
	echo "== RC6A bench: the real rc6 engine"
	real_report ""
	echo "== RC6A bench: mutants (compared on the scenarios the real engine passes)"
	for v in $VARIANTS; do
		[ "$v" = real ] && continue
		compare "" "$v" targets
	done
fi

# ============================================================================
# T9S
# ============================================================================
t9s() {   # mode
	out=$LOG/t9s_$1.out
	sh sim/tb_rc6a_t9s.sh "$1" > "$out" 2>&1
	rc=$?
	grep -E '^   (FAIL|killed|SURVIVED)|^== ALL|FAILURE' "$out" | sed 's/^/   /'
	if [ $rc -ne 0 ]; then
		NF=$((NF + 1)); SUMMARY="$SUMMARY t9s:$1"
	fi
}
t9s_mutants() {
	echo "== RC6A T9S mutant: flash-idle guard removed"
	t9s mut-noguard
	echo "== RC6A T9S mutant: R1 removed"
	t9s mut-nor1
	echo "== RC6A T9S mutant (m1): R1 on !stage_pending"
	t9s mut-pend
	echo "== RC6A T9S mutant (m2): every flash event a program"
	t9s mut-progall
}
if [ "$MODE" = all ] || [ "$MODE" = t9s ]; then
	echo "== RC6A T9S quick (rc6 captures)"
	t9s quick
	t9s_mutants
fi
if [ "$MODE" = full ] || [ "$MODE" = t9sfull ]; then
	echo "== RC6A T9S full matrix (rc6 captures)"
	t9s full
	t9s_mutants
	if [ "${XVER:-1}" = 0 ]; then
		echo "== RC6A T9S rc5 captures woken on rc6: SKIPPED (XVER=0)"
	elif [ ! -d sim/tb_t9s_out ]; then
		echo "== RC6A T9S rc5 captures woken on rc6: SKIPPED (no sim/tb_t9s_out: the rc5 captures are not in git)"
	else
		echo "== RC6A T9S rc5 captures woken on rc6"
		t9s xver
	fi
fi

if [ "$NF" -eq 0 ]; then
	echo "== ALL RC6 R1 SCENARIOS PASS"
else
	echo "== $NF FAILURE(S):$SUMMARY"
	exit 1
fi
