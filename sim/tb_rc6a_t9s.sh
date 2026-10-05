#!/bin/sh
# RC6A part 2: the T9S wake matrix against the REAL rc6 RTL, with the real
# ngp_cart + flash_die, savestates.sv, bridge, copier, stage_mem + psram and
# save engine (sim/tb_rc6a_t9s_bench.sv: tb_t9s_bench.sv with the rc6
# core_top glue). Called by sim/run_rc6_r1.sh; can be run on its own:
#
#   wsl -e sh sim/tb_rc6a_t9s.sh [full|quick|xver|mut-noguard|mut-nor1|mut-pend|mut-progall]
#
#   full   (default) rc6 captures of every T9S capture class, then every wake
#          timing run_t9s.sh uses for it (29 captures, 90 wakes)
#   quick  the R1 subset (tb_r6a_t9s.sh's 12 wakes) plus the late-load
#          timings (w_bios, w_busy) of the same captures
#   xver   rc5 captures from sim/tb_t9s_out (read only), woken on rc6: the
#          same R1 subset plus the late loads -- a state made by rc5 and
#          loaded after the upgrade (those captures are not in git: without
#          sim/tb_t9s_out this mode stops with a failure)
#   mut-noguard  the engine with the flash-idle guard removed
#          (sim/tb_rc6a_mut_noguard.sv, from sim/tb_rc6a_mutants.sh), woken
#          from the rc6 captures of a previous quick/full run at the late-load
#          timings of this game's own images: each wake must FAIL, with an
#          erase cut by the state apply
#   mut-nor1     the engine with R1 removed (sim/tb_rc6a_mut_nor1.sv), the
#          stale-image captures woken after the fresh session published its
#          erase (w_pub): each wake must FAIL, refused
#   mut-pend     (m1) R1 back on !stage_pending (sim/tb_rc6a_mut_pend.sv: rc6
#          before the follow-up), stale-image captures woken while the fresh
#          session's erase is in flight or just reported (w_bios, w_busy,
#          w_busy2): each wake must FAIL, refused -- the follow-up is what
#          loads them
#   mut-progall  (m2) the classifier forced to "program" (every flash event),
#          the same kind of wakes: each must FAIL, refused -- it is the
#          classifier reading the REAL flash_die's erase as an erase that
#          loads them
#
# Every wake must load; where the flash-idle guard applies (the state request
# found no boot apply pending) the apply must not begin with the die mid-erase
# and no erase may be cut by a reset; a loaded state restores the CPU exactly;
# the ROM below block 10 is intact; the game's flash self-check ends as it did
# in the capture session (its post_fail, read from <CAPDIR>/<tag>.cap.log);
# every flash event (this game only erases) reads as an erase to the
# follow-up's classifier -- in the captures as well. Each
# wake prints "== RC6A T9S PASS|FAIL ..."; this script ends with
# "== ALL RC6A T9S SCENARIOS PASS" or "== N FAILURE(S) ..." and exits 1 on any
# failure. JOBS (default 4) runs in parallel. Writes only sim/tb_rc6a_t9s_<mode>.vvp
# and sim/tb_rc6a_t9s_out/ (captures and logs; xver logs are x_*.log).
set -e
cd "$(dirname "$0")/.."
. sim/tb_rc6a_pool.sh

MODE=${1:-full}
DIR=sim/tb_rc6a_t9s_out
JOBS=${JOBS:-4}
mkdir -p "$DIR"
case "$MODE" in
mut-noguard) ENGSRC=sim/tb_rc6a_mut_noguard.sv; OUT=sim/tb_rc6a_t9s_noguard.vvp; PFX="m_noguard_"; WANT="flash-idle guard" ;;
mut-nor1)    ENGSRC=sim/tb_rc6a_mut_nor1.sv;    OUT=sim/tb_rc6a_t9s_nor1.vvp;    PFX="m_nor1_";    WANT="the load was refused" ;;
mut-pend)    ENGSRC=sim/tb_rc6a_mut_pend.sv;    OUT=sim/tb_rc6a_t9s_pend.vvp;    PFX="m_pend_";    WANT="the load was refused" ;;
mut-progall) ENGSRC=sim/tb_rc6a_mut_progall.sv; OUT=sim/tb_rc6a_t9s_progall.vvp; PFX="m_progall_"; WANT="the load was refused" ;;
*)           ENGSRC=target/pocket/ngpc_cart_save.sv; OUT=sim/tb_rc6a_t9s_$MODE.vvp; PFX=""; WANT="" ;;
esac
case "$MODE" in mut-*) sh sim/tb_rc6a_mutants.sh > /dev/null ;; esac

iverilog -g2012 -DNGPC_SIM_SKIP_PSRAM_INIT -D SYNTHESIS -DNGPC_SAVE_DIAG=1 -o "$OUT" -s tb_rc6a_t9s \
    upstream/rtl/Savestates/savestates.sv \
    target/pocket/ngpc_savestate_bridge.sv \
    sim/sim_synch3.v \
    target/pocket/psram.sv \
    target/pocket/ngpc_stage_mem.sv \
    upstream/rtl/cart/ngp_cart_overlay_geometry.sv \
    "$ENGSRC" \
    target/pocket/ngpc_state_cart.sv \
    upstream/rtl/cart/flash_die.sv \
    upstream/rtl/cart/ngp_cart.sv \
    sim/tb_rc6a_t9s_bench.sv

C="+BIOSUS=500 +SNKUS=300 +POSTUS=1000"
W="+BIOSUS=3000 +SNKUS=1000 +POSTUS=4000"

CAPS=$DIR/caps_$MODE.txt
WAKES=$DIR/wakes_$MODE.txt
: > "$CAPS"
: > "$WAKES"
cap() { echo "$*" >> "$CAPS"; }
wk()  { echo "$*" >> "$WAKES"; }

# ---- capture list: run_t9s.sh's, verbatim --------------------------------
all_caps() {
	cap c_pre_snk    $C +CAPREF=0 +CAPCYC=-8000
	cap c_snk        $C +CAPREF=5 +CAPCYC=30000
	cap c_snk_rom    $C +CAPREF=5 +CAPCYC=30000 +ROMFF=0
	cap c_pre_rom    $C +CAPREF=0 +CAPCYC=-8000 +ROMFF=0
	cap c_seq_80     $C +CAPREF=0 +CAPCYC=80
	cap c_seq_160    $C +CAPREF=0 +CAPCYC=160
	cap c_seq_200    $C +CAPREF=0 +CAPCYC=200
	cap c_busy_1k    $C +CAPREF=1 +CAPCYC=1000
	cap c_busy_600k  $C +CAPREF=1 +CAPCYC=600000
	cap c_busy_t1    $C +CAPREF=1 +CAPCYC=1000 +POLL=1
	cap c_poll0_b2   $C +CAPREF=0 +CAPCYC=205 +POLL=2
	cap c_poll1_b2   $C +CAPREF=0 +CAPCYC=215 +POLL=2
	cap c_busy_rom   $C +CAPREF=1 +CAPCYC=1000 +ROMFF=0
	cap c_done_0     $C +CAPREF=2 +CAPCYC=0
	cap c_done_990k  $C +CAPREF=2 +CAPCYC=990000
	cap c_done_rom   $C +CAPREF=2 +CAPCYC=500000 +ROMFF=0
	cap c_pass_30k   $C +CAPREF=3 +CAPCYC=30000
	cap c_pub_100k   $C +CAPREF=4 +CAPCYC=100000
	cap c_pub_rom    $C +CAPREF=4 +CAPCYC=100000 +ROMFF=0
	cap c_e2_seq     $C +CAPREF=0 +CAPERASE=2 +CAPCYC=160 +ERASES=2
	cap c_e2_busy    $C +CAPREF=1 +CAPERASE=2 +CAPCYC=1000 +ERASES=2
	for p in 200 201 202 203 204 205 206 207; do
		cap c_gap_p$p $C +CAPREF=0 +CAPCYC=180 +PARK=$p
	done
}

# ---- the R1 subset (tb_r6a_t9s.sh) plus the late loads --------------------
subset_wakes() {
	wk c_pre_snk w_hold  $W +LOADREF=0 +LOADCYC=25000
	wk c_pre_snk w_bios  $W +LOADREF=5 +LOADCYC=50000
	wk c_pre_snk w_busy  $W +LOADREF=1 +LOADCYC=1000
	wk c_pre_snk w_pub   $W +LOADREF=4 +LOADCYC=1000
	wk c_snk     w_hold  $W +LOADREF=0 +LOADCYC=25000
	wk c_snk     w_bios  $W +LOADREF=5 +LOADCYC=50000
	wk c_snk     w_busy  $W +LOADREF=1 +LOADCYC=1000
	wk c_snk     w_done  $W +LOADREF=2 +LOADCYC=1000
	wk c_snk     w_pub   $W +LOADREF=4 +LOADCYC=1000
	wk c_snk_rom w_bios  $W +LOADREF=5 +LOADCYC=50000 +ROMFF=0
	wk c_snk_rom w_busy  $W +LOADREF=1 +LOADCYC=1000 +ROMFF=0
	wk c_snk_rom w_done  $W +LOADREF=2 +LOADCYC=1000 +ROMFF=0
	wk c_snk_rom w_pub   $W +LOADREF=4 +LOADCYC=1000 +ROMFF=0
	wk c_pub_100k w_hold $W +LOADREF=0 +LOADCYC=25000
	wk c_pub_100k w_bios $W +LOADREF=5 +LOADCYC=50000
	wk c_pub_100k w_busy $W +LOADREF=1 +LOADCYC=1000
	wk c_pub_100k w_pub  $W +LOADREF=4 +LOADCYC=1000
	wk c_busy_1k w_bios  $W +LOADREF=5 +LOADCYC=50000
	wk c_busy_1k w_busy  $W +LOADREF=1 +LOADCYC=1000
	wk c_busy_1k w_done  $W +LOADREF=2 +LOADCYC=1000
}

case "$MODE" in
full)
	all_caps
	# run_t9s.sh's wake selection, verbatim
	while read -r tag args; do
		extra=""
		case "$args" in *ROMFF=0*) extra="$extra +ROMFF=0" ;; esac
		case "$args" in *POLL=1*) extra="$extra +POLL=1" ;; esac
		case "$args" in *POLL=2*) extra="$extra +POLL=2" ;; esac
		case "$args" in *ERASES=2*) extra="$extra +ERASES=2" ;; esac
		case "$tag" in
		c_gap_p201|c_gap_p203|c_pre_snk|c_seq_80)
			wk $tag w_hold  $W +LOADREF=0 +LOADCYC=25000 $extra
			wk $tag w_pub   $W +LOADREF=4 +LOADCYC=1000 $extra ;;
		c_gap_*) ;;
		c_seq_200|c_busy_600k|c_busy_t1|c_poll1_b2|c_done_990k|c_done_rom|c_pass_30k|c_e2_seq)
			wk $tag w_hold  $W +LOADREF=0 +LOADCYC=25000 $extra
			wk $tag w_done  $W +LOADREF=2 +LOADCYC=1000 $extra ;;
		*)
			wk $tag w_hold  $W +LOADREF=0 +LOADCYC=25000 $extra
			wk $tag w_bios  $W +LOADREF=5 +LOADCYC=50000 $extra
			wk $tag w_busy  $W +LOADREF=1 +LOADCYC=1000 $extra
			wk $tag w_busy2 $W +LOADREF=1 +LOADCYC=300000 $extra
			wk $tag w_done  $W +LOADREF=2 +LOADCYC=1000 $extra
			wk $tag w_pub   $W +LOADREF=4 +LOADCYC=1000 $extra ;;
		esac
	done < "$CAPS"
	CAPDIR=$DIR ;;
quick)
	cap c_pre_snk  $C +CAPREF=0 +CAPCYC=-8000
	cap c_snk      $C +CAPREF=5 +CAPCYC=30000
	cap c_snk_rom  $C +CAPREF=5 +CAPCYC=30000 +ROMFF=0
	cap c_busy_1k  $C +CAPREF=1 +CAPCYC=1000
	cap c_pub_100k $C +CAPREF=4 +CAPCYC=100000
	subset_wakes
	CAPDIR=$DIR ;;
xver)
	if [ ! -d sim/tb_t9s_out ]; then
		echo "== 1 FAILURE(S): xver needs the rc5 captures in sim/tb_t9s_out (made by the rc5-era run_t9s.sh; not in git)"
		exit 1
	fi
	subset_wakes
	PFX="x_"; CAPDIR=sim/tb_t9s_out ;;
mut-noguard)
	wk c_busy_1k  w_bios $W +LOADREF=5 +LOADCYC=50000
	wk c_busy_1k  w_busy $W +LOADREF=1 +LOADCYC=1000
	wk c_pub_100k w_bios $W +LOADREF=5 +LOADCYC=50000
	wk c_pub_100k w_busy $W +LOADREF=1 +LOADCYC=1000
	CAPDIR=$DIR ;;
mut-nor1)
	wk c_pre_snk w_pub   $W +LOADREF=4 +LOADCYC=1000
	wk c_snk     w_pub   $W +LOADREF=4 +LOADCYC=1000
	wk c_snk_rom w_pub   $W +LOADREF=4 +LOADCYC=1000 +ROMFF=0
	CAPDIR=$DIR ;;
mut-pend)
	wk c_pre_snk w_bios  $W +LOADREF=5 +LOADCYC=50000
	wk c_snk     w_busy  $W +LOADREF=1 +LOADCYC=1000
	wk c_snk_rom w_busy2 $W +LOADREF=1 +LOADCYC=300000 +ROMFF=0
	wk c_seq_160 w_bios  $W +LOADREF=5 +LOADCYC=50000
	CAPDIR=$DIR ;;
mut-progall)
	wk c_pre_snk w_busy  $W +LOADREF=1 +LOADCYC=1000
	wk c_snk     w_bios  $W +LOADREF=5 +LOADCYC=50000
	wk c_snk_rom w_bios  $W +LOADREF=5 +LOADCYC=50000 +ROMFF=0
	wk c_seq_160 w_busy  $W +LOADREF=1 +LOADCYC=1000
	CAPDIR=$DIR ;;
*)
	echo "usage: $0 [full|quick|xver|mut-noguard|mut-nor1|mut-pend|mut-progall]"; exit 2 ;;
esac

NF=0
FAILS=""

# ---- 1. captures ------------------------------------------------------------
if [ -s "$CAPS" ]; then
	echo "== RC6A T9S $MODE: $(wc -l < "$CAPS") capture runs, $JOBS at a time"
	: > "$DIR/.cmds_cap_$MODE"
	while read -r tag args; do
		rm -f "$DIR/$tag.cap.log"
		printf '%s\n' "vvp -n $OUT +WAKE=0 +TAG=$tag +DIR=$DIR $args > $DIR/$tag.cap.log 2>&1; grep -h \"== T9S CAPTURE RESULT\\|WATCHDOG\" $DIR/$tag.cap.log || echo \"== NO RESULT $tag\"" >> "$DIR/.cmds_cap_$MODE"
	done < "$CAPS"
	rc6a_pool "$DIR/.cmds_cap_$MODE" "$DIR/.pool_cap_$MODE"
	while read -r tag args; do
		if ! grep -q "== T9S CAPTURE RESULT tag=$tag ok=1" "$DIR/$tag.cap.log" 2>/dev/null ||
		   ! grep -q "^== ALL RC6A T9S SCENARIOS PASS (capture $tag)" "$DIR/$tag.cap.log" 2>/dev/null; then
			NF=$((NF + 1)); FAILS="$FAILS cap:$tag"
			echo "   FAIL cap:$tag: $(grep -h 'RC6A FAIL\|^== [0-9]* FAILURE' "$DIR/$tag.cap.log" 2>/dev/null | tr '\n' ' ')"
		fi
	done < "$CAPS"
fi

# ---- 2. wakes ---------------------------------------------------------------
echo "== RC6A T9S $MODE: $(wc -l < "$WAKES") wake runs, $JOBS at a time (captures from $CAPDIR)"
: > "$DIR/.cmds_wake_$MODE"
while read -r tag w args; do
	log=$DIR/$PFX$tag.$w.log
	rm -f "$log"
	printf '%s\n' "cf=\$(grep -ho \"post_fail=[0-9a-fA-F]*\" $CAPDIR/$tag.cap.log 2>/dev/null | head -n 1 | cut -d= -f2); vvp -n $OUT +WAKE=1 +TAG=$tag +DIR=$DIR +CAPDIR=$CAPDIR +CAPFAIL=\${cf:-00} $args > $log 2>&1; r=\$(grep -h \"== RC6A T9S\" $log || echo \"== RC6A T9S FAIL NO RESULT tag=$tag\"); echo \"$w \$r\"" >> "$DIR/.cmds_wake_$MODE"
done < "$WAKES"
rc6a_pool "$DIR/.cmds_wake_$MODE" "$DIR/.pool_wake_$MODE"

echo "== RC6A T9S $MODE summary"
while read -r tag w args; do
	log=$DIR/$PFX$tag.$w.log
	if [ -n "$WANT" ]; then
		# a mutant: the wake must fail, for the reason the change guards
		if grep -q "RC6A FAIL: $WANT" "$log" 2>/dev/null; then
			echo "   killed $PFX$tag.$w: $(grep -h "RC6A FAIL: $WANT" "$log" | head -1 | sed 's/^ *RC6A FAIL: //')"
		else
			NF=$((NF + 1)); FAILS="$FAILS $PFX$tag.$w"
			echo "   SURVIVED $PFX$tag.$w: $(grep -h '^== RC6A T9S' "$log" 2>/dev/null)"
		fi
	elif grep -q "^== RC6A T9S PASS" "$log" 2>/dev/null; then
		:
	else
		NF=$((NF + 1)); FAILS="$FAILS $PFX$tag.$w"
		echo "   FAIL $PFX$tag.$w: $(grep -h 'RC6A FAIL' "$log" 2>/dev/null | tr '\n' ' ')"
	fi
done < "$WAKES"
NW=$(wc -l < "$WAKES")
if [ "$NF" -eq 0 ]; then
	echo "== ALL RC6A T9S SCENARIOS PASS ($MODE: $NW wakes)"
else
	echo "== $NF FAILURE(S) in RC6A T9S $MODE ($NW wakes):$FAILS"
	exit 1
fi
