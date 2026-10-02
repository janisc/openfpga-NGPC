#!/bin/sh
# rc6 family X: the combined rc6 staging behaviour and the T7 benches, on the
# REAL rc6 RTL (target/pocket + upstream, with the rc6 follow-up patch) and
# core_top's rc6 glue verbatim.
#
#   wsl -e sh /mnt/c/FPGA/ngpc-rc4/sim/run_rc6_combo.sh           the default list (the t7p prep + 97 runs)
#   wsl -e sh /mnt/c/FPGA/ngpc-rc4/sim/run_rc6_combo.sh quick     a subset (the t7p prep + 26 runs)
#   wsl -e sh /mnt/c/FPGA/ngpc-rc4/sim/run_rc6_combo.sh sweep     the default list plus
#        every remaining point of sim/run_t7r.sh's T7 sweep
#   wsl -e sh /mnt/c/FPGA/ngpc-rc4/sim/run_rc6_combo.sh mutants   mutation checks
#   wsl -e sh /mnt/c/FPGA/ngpc-rc4/sim/run_rc6_combo.sh one BENCH ARGS...
#        BENCH = combo | t7p | t7s (the real-RTL build), e.g.
#        ... one combo +TAG=x +SAVES=1 +DELAYUS=30000 +FDFULL=2000 +VERBOSE=1
#
# Benches (each compiles the real files; nothing under target/ or upstream/
# is modified, and no file outside sim/tb_rc6x_* and this script is written):
#   sim/tb_rc6x_combo.sv  the T7 session with the real bridge + savestates.sv,
#                         copier, engine, stage_mem, psram, data_loader and
#                         data_unloader: the r6x FDFULL cross-check, the
#                         flush/commit and flush/publish races, the whole
#                         run_t7r.sh sweep and its fault injections
#                         (tb_t7r_bench.sv's harness)
#   sim/tb_rc6x_t7p.sv    tb_t7p_flush's T7 replays, modes 0-10
#   sim/tb_rc6x_t7s.sv    tb_t7s_inv's invariants on the real T7 Memory image
# The three are the rc6 ports of tb_t7r_bench / tb_t7p_flush / tb_t7s_inv.
# Their rc5 monitors ('host writes lost to host reads', 'wr_lost_to_read',
# 'clobber cycles') counted the CONDITION of rc5's L1 hazard -- a host read
# while a popped write was pending -- which with L1 is a harmless wait
# (still printed as rd_wait, info only). They are retired: real loss is
# counted by the ARB and SKID scoreboards and diag_drops.
#
# The engine's host_rd_i (rc6 follow-up) is wired as core_top wires it: the
# data_unloader's read strobe (stage_host_rd), and in tb_rc6x_t7s the
# bench's flush strobe. Every run also checks that the committed bank never
# flips on a clock where that strobe is up, nor inside a flush.
#
# Every run prints '== RC6X SCENARIO <tag> (rtl|fault injection) PASS' or
# '... FAIL (n check(s))'. This script's last line is
# '== ALL RC6 COMBO SCENARIOS PASS' or '== N FAILURE(S) ...', and it exits
# non-zero on failure.
#
# 'mutants' makes sim/tb_rc6x_mut_*.sv -- sed copies of the real RTL (or of
# the benches' verbatim core_top glue) with ONE rc6 change removed each; every
# sed must change exactly the lines it names -- and runs the scenarios that
# cover that change on it. A mutant is caught only when the run FAILs WITH ITS
# SIGNATURE (the failure the change exists to prevent, grepped from the log),
# e.g. L2 removed: the FDFULL flush is MIXED, and the relaunch on it is
# refused (0003) and frozen. It ends '== ALL RC6 COMBO MUTANTS CAUGHT' or
# '== N FAILURE(S) ...'.
#
# The defect this family reported on rc6 before the follow-up (an APF flush
# whose first read is claimed in the two clocks before the state commit sees
# host_busy takes word 0 from the old bank: x_raceofs_w0_6/7) is closed by the
# follow-up's host_rd_i hold; those runs are now in the quick list with their
# expected outcome, and mutant nol2rd (the strobe hold removed) re-opens it.
#
# NGPC_SAVE_DIAG is defined as in the release build (projects/ngpc_pocket.qsf).
# Logs: sim/tb_rc6x_logs/rtl_<tag>.log (mutants: mut_<mutant>_<tag>.log), the
# verdict lines in sim/tb_rc6x_logs/summary_<mode>.txt. JOBS (default 2) runs
# in parallel; the machine is shared, so keep it low.
cd "$(dirname "$0")/.."
LOGS=sim/tb_rc6x_logs
mkdir -p "$LOGS"
JOBS=${JOBS:-2}

IV="iverilog -g2012 -D SYNTHESIS -DNGPC_SAVE_DIAG=1"
UP_SS=upstream/rtl/Savestates/savestates.sv
UP_GEO=upstream/rtl/cart/ngp_cart_overlay_geometry.sv
R_BR=target/pocket/ngpc_savestate_bridge.sv
R_DL=target/pocket/data_loader.sv
R_DU=target/pocket/data_unloader.sv
R_PS=target/pocket/psram.sv
R_SM=target/pocket/ngpc_stage_mem.sv
R_CS=target/pocket/ngpc_cart_save.sv
R_SC=target/pocket/ngpc_state_cart.sv

# build NAME STAGE_MEM ENGINE COMBO_TB T7P_TB T7S_TB. Each .vvp is written
# under a temporary name and renamed, so a run starting meanwhile never loads
# a half-written one.
build() {
    $IV -o sim/tb_rc6x_combo_$1.vvp.$$ -s tb_rc6x_combo \
        $UP_SS $R_BR sim/sim_synch3.v sim/sim_dcfifo.v $R_DL $R_DU $R_PS $2 \
        $UP_GEO $3 $R_SC $4 || return 1
    $IV -o sim/tb_rc6x_t7p_$1.vvp.$$ -s tb_rc6x_t7p \
        sim/sim_dcfifo.v $R_DL $R_DU $R_PS $2 $UP_GEO $3 $R_SC $5 || return 1
    $IV -o sim/tb_rc6x_t7s_$1.vvp.$$ -s tb_rc6x_t7s \
        $R_PS $2 $UP_GEO $3 $R_SC $6 || return 1
    for b in combo t7p t7s; do mv -f sim/tb_rc6x_${b}_$1.vvp.$$ sim/tb_rc6x_${b}_$1.vvp; done
}
build_rtl() {
    build rtl $R_SM $R_CS sim/tb_rc6x_combo.sv sim/tb_rc6x_t7p.sv sim/tb_rc6x_t7s.sv
}

# the t7p modes read the pre-T7 file the REAL build writes (mode 0)
t7p_prep() {
    echo "== t7p prep (mode 0: the pre-T7 file, written to sim/tb_rc6x_t7p_F0.hex)"
    vvp -n sim/tb_rc6x_t7p_rtl.vvp +TAG=t7p_mode0 +V=0 > $LOGS/rtl_t7p_mode0.log 2>&1
    R0=$(grep "^== RC6X SCENARIO" $LOGS/rtl_t7p_mode0.log | tail -n 1)
    echo "${R0:-== RC6X SCENARIO t7p_mode0 FAIL (no verdict)}"
}

# run_list FILE BUILD: every line of FILE is 'BENCH TAG ARGS...'; one log per
# line, sim/tb_rc6x_logs/<BUILD>_<TAG>.log; prints one verdict line per run
run_list() {
    grep -v '^ *#' "$1" | grep -v '^ *$' | while read -r bench tag args; do
        echo "$bench $tag $args"
    done | xargs -P "$JOBS" -L 1 sh -c '
        bench=$1; tag=$2; shift 2
        log='"$LOGS"'/'"$2"'_$tag.log
        vvp -n sim/tb_rc6x_${bench}_'"$2"'.vvp +TAG=$tag "$@" > $log 2>&1
        r=$(grep "^== RC6X SCENARIO" $log | tail -n 1)
        [ -n "$r" ] || r="== RC6X SCENARIO $tag FAIL (no verdict: see $log)"
        echo "$r"' sh
}

# ---- scenario lists ---------------------------------------------------------
# Three tiers: addq = quick, default and sweep; add = default and sweep;
# adds = sweep only (the remaining points of sim/run_t7r.sh's T7 sweep).
LIST=$LOGS/jobs_all.txt
QLIST=$LOGS/jobs_quick.txt
SLIST=$LOGS/jobs_sweep.txt
: > "$LIST"
: > "$QLIST"
: > "$SLIST"
adds() { echo "$*" >> "$SLIST"; }
add()  { echo "$*" >> "$LIST"; adds "$@"; }
addq() { echo "$*" >> "$QLIST"; add "$@"; }
# t7r BENCH TAG ARGS: in the default list when TAG is in $PICK, else sweep only
t7r() {
    case " $PICK " in *" $2 "*) add "$@" ;; *) adds "$@" ;; esac
}

# (1) the r6x FDFULL cross-check: a whole-slot APF flush starting 2000 clk
# after draining rises, spare bank poisoned; flush reads 8 us apart (RGAP=600)
# so the flush outlasts the drain and the apply. rc6: the load succeeds, the
# commit lands after the flush, the flushed file is wholly the old image, the
# next boot accepts it (0001) and is not frozen.
FD="+SAVES=1 +DELAYUS=30000 +FLUSH=0 +SEED=7 +RELAUNCHMID=1 +EXPECT_LOAD=1 +EXPECT_MID=old +EXPECT_COMMIT=after +EXPECT_RELAUNCH=1"
addq combo x_fdfull_rgap600      $FD +FDFULL=2000 +RGAP=600
add  combo x_fdfull_rgap200      $FD +FDFULL=2000
add  combo x_fdfull_middrain     $FD +FDFULL=60000 +RGAP=600
# a whole-slot flush starting after the state_apply pulse (the apply runs)
FA="+SAVES=1 +DELAYUS=30000 +FLUSH=2 +SEED=7 +RELAUNCHMID=1 +EXPECT_LOAD=1 +EXPECT_MID=old +EXPECT_COMMIT=after +EXPECT_RELAUNCH=1"
addq combo x_flushapply_449477   $FA +FLUSHAPPLY=449477
add  combo x_flushapply_300977   $FA +FLUSHAPPLY=300977
# The flush's first read around the clock host_busy falls while the accepted
# commit waits (+RACEOFS=K: the flush starts when host_idle is K short of
# terminal). K <= 5: the commit lands before the first claim (file wholly
# new); K >= 6: the read strobe holds the commit (host_rd_i, rc6 follow-up)
# for the two clocks before slot_busy_q sees the read, then host_busy holds it
# until after the flush (file wholly old). K = 6 and 7 were the defect's two
# clocks (word 0 from the old bank, the rest new); with +OLDW0=BAD0 the
# committed bank's word 0 differs from the state's, so word 0's source shows.
RO="+SAVES=1 +DELAYUS=30000 +FLUSH=0 +SEED=7 +MIDWORDS=2700 +EXPECT_LOAD=1"
ROnew="+EXPECT_MID=new +EXPECT_COMMIT=before"
ROold="+EXPECT_MID=old +EXPECT_COMMIT=after"
addq combo x_raceofs_0           $RO +RACEOFS=0 $ROnew
add  combo x_raceofs_7           $RO +RACEOFS=7 $ROold
addq combo x_raceofs_8           $RO +RACEOFS=8 $ROold
for k in 4 5; do
    add  combo x_raceofs_w0_$k   $RO +RACEOFS=$k +OLDW0=BAD0 $ROnew
done
for k in 6 7; do
    addq combo x_raceofs_w0_$k   $RO +RACEOFS=$k +OLDW0=BAD0 $ROold
done
for k in 8 9 10; do
    add  combo x_raceofs_w0_$k   $RO +RACEOFS=$k +OLDW0=BAD0 $ROold
done
# The same race at the pass's publish (rc6 follow-up: the publish also waits
# on !host_rd_i): a flush whose first strobe is up on the clock of the publish
# decision of the pass after the save. PUBRACE_HIT is the offset that lands it
# there (measured 2026-10-01 on the follow-up RTL: 21 lands the strobe a clock
# early, so host_busy defers the publish; 23 a clock late, so the publish is
# first; the run fails if 22 no longer hits -- +EXPECT_PUBHIT). The flush
# reads the 32 header words (MIDWORDS=16): word 0 (made to differ by +OLDW0)
# and the words the pass rewrites show the source. Wholly old or wholly
# published, never word 0 of the old bank and the rest new.
PR="+SAVES=1 +DELAYUS=60000 +FLUSH=0 +SEED=7 +PUBHDR=29 +MIDWORDS=16 +OLDW0=BAD0 +EXPECT_LOAD=1"
PUBRACE_HIT=22
addq combo x_pubrace_hit         $PR +PUBRACE=$PUBRACE_HIT +EXPECT_PUBHIT=1
add  combo x_pubrace_early       $PR +PUBRACE=$((PUBRACE_HIT - 1))
add  combo x_pubrace_late        $PR +PUBRACE=$((PUBRACE_HIT + 1))
# the rc5 loss case (tb_t7r_flushdrain_2saves: wr_lost_to_read=2633, verdict
# 8003): a flush of the first 256 words during the drain after two saves
addq combo x_flushdrain_2saves   +SAVES=2 +GAPUS=40000 +DELAYUS=30000 +FLUSHDRAIN=1 +EXPECT_LOAD=1
addq combo x_flushdrain_1save    +SAVES=1 +DELAYUS=30000 +FLUSHDRAIN=1 +SEED=55 +EXPECT_LOAD=1

# (2) the T7 sweep of sim/run_t7r.sh, RTL runs (the load must succeed). The
# default list takes the points in PICK: the load inside the erase, inside
# the programs, in the quiet window, at the pass start and the publish (to
# the clock), and after; the 'sweep' mode runs every point.
L="+EXPECT_LOAD=1"
PICK="t7r_d-20000 t7r_d-1000 t7r_d0 t7r_d19000 t7r_d20300 t7r_d20500 t7r_d23000
      t7r_d26000 t7r_d30000 t7r_d50000 t7r_c999992 t7r_c1000000 t7r_c1289662
      t7r_c1289666 t7r_c1289668 t7r_flush_d0 t7r_flush_d26000 t7r_2s_g0_d0
      t7r_2s_g0_d21000 t7r_2s_g0_d26000 t7r_2s_g20500_d21000 t7r_2s_g22000_d26000
      t7r_2s_g26500_d21000 t7r_2s_g40000_d30000 t7r_same_d0 t7r_same_d21000
      t7r_same_d26300 t7r_p2max3_d21000 t7r_p2max15_d21000 t7r_noerase_d-5000
      t7r_noerase_d21000 t7r_quitsave_20000 t7r_quitsave_22000 t7r_quitsave_25000"
PICK=$(echo $PICK)
for d in -20000 -15000 -8000 -1000 0 100 500 1000 2000 5000 10000 15000 19000 \
         20000 20300 20400 20500 21000 22000 23000 24000 25000 25500 26000 \
         26200 26300 26500 27000 28000 30000 35000 40000 45000 50000; do
    case $d in -8000|21000|26300|40000) addq combo t7r_d$d +SAVES=1 +DELAYUS=$d $L ;;
    *) t7r combo t7r_d$d +SAVES=1 +DELAYUS=$d $L ;; esac
done
for c in 999980 999988 999990 999991 999992 999993 999995 1000000 1000010 \
         1289640 1289655 1289660 1289662 1289663 1289664 1289665 1289666 \
         1289667 1289668 1289670 1289675 1289680 1289700; do
    t7r combo t7r_c$c +SAVES=1 +DELAYCYC=$c $L
done
for d in 0 21000 26000 50000; do
    t7r combo t7r_flush_d$d +SAVES=1 +DELAYUS=$d +FLUSH=2 +SEED=$((d + 101)) $L
done
for g in 0 5000 20500 22000 26500 40000; do
    for d in 0 20400 21000 22000 23000 24000 26000 30000; do
        t7r combo t7r_2s_g${g}_d$d +SAVES=2 +GAPUS=$g +DELAYUS=$d +SEED=$((g + d + 11)) $L
    done
done
for d in 0 20400 21000 22000 23000 25000 26300; do
    t7r combo t7r_same_d$d +SAVES=1 +SAME=1 +DELAYUS=$d +SEED=$((d + 3)) $L
done
for d in 20400 21000 22000 23000; do
    t7r combo t7r_p2max3_d$d  +SAVES=1 +DELAYUS=$d +P2MAX=3 +SEED=$((d + 5)) $L
    t7r combo t7r_p2max15_d$d +SAVES=1 +DELAYUS=$d +P2MAX=15 +SEED=$((d + 9)) $L
done
for d in -5000 0 21000 23000; do
    t7r combo t7r_noerase_d$d +SAVES=1 +NOERASE=1 +DELAYUS=$d +SEED=$((d + 17)) $L
done
addq combo t7r_relaunch_1s  +SAVES=1 +DELAYUS=21000 +RELAUNCH=1 +FLUSH=2 +SEED=41 $L
add  combo t7r_relaunch_2s  +SAVES=2 +GAPUS=0 +DELAYUS=22000 +RELAUNCH=1 +FLUSH=2 +SEED=43 $L
add  combo t7r_redeliver_d30000 +SAVES=1 +DELAYUS=30000 +REDELIVER=1 +SEED=51 $L
add  combo t7r_redeliver_d0     +SAVES=1 +DELAYUS=0 +REDELIVER=1 +SEED=53 $L
add  combo t7r_flushdrain       +SAVES=1 +DELAYUS=30000 +FLUSHDRAIN=1 +SEED=55 $L
for q in 20000 21000 22000 23000 25000; do
    t7r combo t7r_quitsave_$q +SAVES=1 +DELAYUS=30000 +QUITSAVE=$q +PLAYUS=40000 +FLUSH=2 +SEED=$((q + 13)) $L
done
add combo t7r_probe1_progper300 +SAVES=1 +DELAYUS=21000 +PROGPER=300 $L

# (2) FAULT INJECTION (not RTL): an engine header write forced into a drain.
# The T7-exact runs (a forced stage_current at header index 17 plus a copier
# pause at drain count 8196/8197 -- word 18 = 0x2004/0x2005) must now carry
# word 23 bit 14 in the quit file. Every fault run is also held to the
# generic rules: the flag rises iff the engine wrote while draining, word 23
# always carries it, and a stray header in the committed bank implies bit 14.
FI="+SAVES=1 +SAME=1 +DELAYUS=21000"
addq combo fi_exact          $FI +FORCEDRAIN=17 +PAUSEDRAIN=8197 +FLUSH=2 +RELAUNCH=1 +EXPECT_FILEFLAG=1
add  combo fi_both           $FI +FORCEDRAIN=17 +PAUSEDRAIN=8196 +FLUSH=2 +EXPECT_FILEFLAG=1
add  combo fi_exact_play60   $FI +FORCEDRAIN=17 +PAUSEDRAIN=8197 +FLUSH=2 +PLAYUS=60000 +EXPECT_FILEFLAG=1
add  combo fi_both_odd_2saves +SAVES=2 +SAME=1 +DELAYUS=21000 +FORCEDRAIN=18 +PAUSEDRAIN=8197 +FLUSH=2
add  combo fi_both_odd_newdata +SAVES=1 +SAME=0 +DELAYUS=21000 +FORCEDRAIN=17 +PAUSEDRAIN=8197 +FLUSH=2
addq combo fi_pauseonly      +SAVES=1 +SAME=1 +DELAYUS=40000 +PAUSEDRAIN=8196 +FLUSH=2
add  combo fi_probe_fd12     +SAVES=1 +SAME=0 +DELAYUS=21000 +FORCEDRAIN=12 +FLUSH=2
add  combo fi_probe_fd17     +SAVES=1 +SAME=1 +DELAYUS=21000 +FORCEDRAIN=17 +FLUSH=2
for x in 0 12 16 17 18 19 31; do
    add combo fi_forcedrain_same_$x +SAVES=1 +SAME=1 +DELAYUS=21000 +FORCEDRAIN=$x +FLUSH=2
done
for x in 12 17; do
    add combo fi_forcedrain_new_$x +SAVES=1 +SAME=0 +DELAYUS=21000 +FORCEDRAIN=$x +FLUSH=2
done

# tb_t7p_flush's replays (mode 0, the prep, runs first on its own) and
# tb_t7s_inv's invariants
for m in 1 2 3 4 5 6 7 8 9 10; do
    case $m in 1|6|7|9) addq t7p t7p_mode$m +V=$m ;; *) add t7p t7p_mode$m +V=$m ;; esac
done
# mode 6 with the re-delivery in 512-byte bursts at data_loader's top rate: the
# skid must absorb them while the drain runs (L3 part B)
BURST="+WRGAP=2 +WRBURST=128 +WRPAUSE=3000"
addq t7p t7p_mode6_burst +V=6 $BURST
for a in 0_1 0_0 1_1 2_1 3_1; do
    m=${a%_*}; b=${a#*_}
    addq t7s t7s_mode${m}_bank$b +MODE=$m +BANK=$b
done

# ---- mutants --------------------------------------------------------------
# mk OUT SRC N SED-ARGS...: a sed copy of SRC that must differ from it in
# exactly N lines (N removed, N added, nothing else); the diff is shown.
mk() {
    out=$1; src=$2; n=$3; shift 3
    sed "$@" "$src" > "$out"
    nd=$(diff "$src" "$out" | grep -c '^<')
    na=$(diff "$src" "$out" | grep -c '^>')
    if [ "$nd" -ne "$n" ] || [ "$na" -ne "$n" ]; then
        echo "== 1 FAILURE(S): the sed for $out changed $nd/$na line(s), meant $n"
        diff "$src" "$out" | head -20
        exit 1
    fi
    echo "   $out: $n line(s) changed, as meant"
    diff "$src" "$out" | grep '^[<>]' | sed 's/^/      /'
}
make_mutants() {
    M=sim/tb_rc6x_mut
    Q="'"
    # L2: the accepted state commit no longer waits for the host port at all
    # (neither slot_busy_q nor the follow-up's read strobe); L1 kept
    mk ${M}_nol2.sv $R_CS 1 \
        -e "s/^\([[:space:]]*\)(slot_busy_q || host_rd_i)) begin/\11${Q}b0) begin/"
    # L2's follow-up half: the commit waits on slot_busy_q only, not on the
    # read strobe for the two clocks before slot_busy_q sees it (the JR7 window)
    mk ${M}_nol2rd.sv $R_CS 1 \
        -e "s/^\([[:space:]]*\)(slot_busy_q || host_rd_i)) begin/\1(slot_busy_q)) begin/"
    # the follow-up's publish guard: the pass publishes on a strobe clock
    mk ${M}_pubrd.sv $R_CS 1 \
        -e "s/^\([[:space:]]*\)!host_rd_i && !draining_i && !refused_q && !saw_save_wr) begin/\1!draining_i \&\& !refused_q \&\& !saw_save_wr) begin/"
    # L1: an APF read reloads the pending slot on every clock of its window,
    # over a popped write still waiting in it (rc5's 'else if (host_rd_i)')
    mk ${M}_nol1.sv $R_SM 2 \
        -e "s/wire       host_rd_claim = host_rd_i && !host_rd_served;/wire       host_rd_claim = host_rd_i;/" \
        -e "s/^\t\t\tif (!host_pending) begin/\t\t\tif (!host_pending || host_rd_i) begin/"
    # L3 part B: the copier held off only at 508 entries again (rc5)
    mk ${M}_nol3b.sv $R_SM 1 \
        -e "s/assign host_wr_ready_o = (skid_fill\[9:5\] == 5${Q}d0);/assign host_wr_ready_o = (skid_fill < 10${Q}d508);/"
    # L3 part A (core_top glue, reproduced verbatim in the benches): rc5's mux,
    # the copier's beat takes a colliding cycle and APF's beat is lost
    for b in combo t7p t7s; do
        case $b in t7s) n=3 ;; *) n=4 ;; esac
        mk ${M}_nol3a_$b.sv sim/tb_rc6x_$b.sv $n \
            -e "s/wire        sc_go       = sc_beat && !apf_save_wr;/wire        sc_go       = sc_host_wr;/" \
            -e "s/sc_replay <= !reset_in && sc_beat && apf_save_wr;/sc_replay <= 1${Q}b0;/" \
            -e "s/\(sc_host_ready *= stage_host_ready\) && !sc_replay &&\$/\1 ||/" \
            -e "s/^\([[:space:]]*\)!(sc_host_wr && apf_save_wr);/\1 1${Q}b0;/" \
            -e "s/sc_host_ready_mem && !sc_replay && !(sc_host_wr && apf_save_wr) && !stall;/sc_host_ready_mem \&\& !stall;/"
    done
    # L2's glue half: sc_draining ORed back into the engine's host_busy_i
    mk ${M}_hbdrain_combo.sv sim/tb_rc6x_combo.sv 1 \
        -e "s/\.host_busy_i     (host_busy),/.host_busy_i     (host_busy || sc_draining),/"
    # T7 flag: never set / not stamped into word 23 / set by any engine write
    mk ${M}_noflag.sv $R_CS 1 \
        -e "s/if (stage_req_o && stage_we_o && draining_i) diag_wr_drain <= 1${Q}b1;/if (stage_req_o \&\& stage_we_o \&\& draining_i) diag_wr_drain <= 1${Q}b0;/"
    mk ${M}_flagword.sv $R_CS 1 \
        -e "s/6${Q}d23: hdr_word = {diag_verdict\[15\], diag_wr_drain, diag_verdict\[13:0\]};/6${Q}d23: hdr_word = diag_verdict;/"
    mk ${M}_flagany.sv $R_CS 1 \
        -e "s/if (stage_req_o && stage_we_o && draining_i) diag_wr_drain/if (stage_req_o \&\& stage_we_o) diag_wr_drain/"
    # writer revision back to 05
    mk ${M}_rev05.sv $R_CS 1 \
        -e "s/6${Q}d21: hdr_word = {8${Q}h06, cart_subcat_i};/6${Q}d21: hdr_word = {8${Q}h05, cart_subcat_i};/"
}

if [ "$1" = "one" ]; then
    b=$2; shift 2
    build_rtl || exit 1
    vvp -n sim/tb_rc6x_${b}_rtl.vvp "$@"
    exit $?
fi

if [ "$1" = "mutants" ]; then
    echo "== making the mutants"
    make_mutants
    M=sim/tb_rc6x_mut
    T=sim/tb_rc6x
    echo "== building"
    build nol2    $R_SM ${M}_nol2.sv   $T\_combo.sv $T\_t7p.sv $T\_t7s.sv || exit 1
    build nol2rd  $R_SM ${M}_nol2rd.sv $T\_combo.sv $T\_t7p.sv $T\_t7s.sv || exit 1
    build pubrd   $R_SM ${M}_pubrd.sv  $T\_combo.sv $T\_t7p.sv $T\_t7s.sv || exit 1
    build nol1    ${M}_nol1.sv $R_CS  $T\_combo.sv $T\_t7p.sv $T\_t7s.sv || exit 1
    build nol3b   ${M}_nol3b.sv $R_CS $T\_combo.sv $T\_t7p.sv $T\_t7s.sv || exit 1
    build nol3a   $R_SM $R_CS ${M}_nol3a_combo.sv ${M}_nol3a_t7p.sv ${M}_nol3a_t7s.sv || exit 1
    build hbdrain $R_SM $R_CS ${M}_hbdrain_combo.sv $T\_t7p.sv $T\_t7s.sv || exit 1
    build noflag  $R_SM ${M}_noflag.sv   $T\_combo.sv $T\_t7p.sv $T\_t7s.sv || exit 1
    build flagword $R_SM ${M}_flagword.sv $T\_combo.sv $T\_t7p.sv $T\_t7s.sv || exit 1
    build flagany $R_SM ${M}_flagany.sv  $T\_combo.sv $T\_t7p.sv $T\_t7s.sv || exit 1
    build rev05   $R_SM ${M}_rev05.sv    $T\_combo.sv $T\_t7p.sv $T\_t7s.sv || exit 1
    # the t7p runs read the pre-T7 file of the REAL build: remade when missing
    # or older than the RTL or the bench
    if [ ! -f sim/tb_rc6x_t7p_F0.hex ] || \
       [ -n "$(find $R_SM $R_CS $R_SC $R_DL $R_DU $R_PS $UP_GEO sim/tb_rc6x_t7p.sv -newer sim/tb_rc6x_t7p_F0.hex)" ]; then
        build_rtl || exit 1
        t7p_prep
    fi
    ML=$LOGS/jobs_mutants.txt
    : > "$ML"
    # 'MUTANT BENCH TAG SIGNATURE ARGS': the run must FAIL on its mutant and
    # its log must match SIGNATURE (grep -E; '.' stands for a blank)
    FDM="+SAVES=1 +DELAYUS=30000 +FLUSH=0 +SEED=7 +RELAUNCHMID=1 +EXPECT_LOAD=1 +EXPECT_MID=old +EXPECT_COMMIT=after +EXPECT_RELAUNCH=1 +FDFULL=2000 +RGAP=600"
    ROM="+SAVES=1 +DELAYUS=30000 +FLUSH=0 +SEED=7 +MIDWORDS=2700 +EXPECT_LOAD=1 +OLDW0=BAD0 +EXPECT_MID=old +EXPECT_COMMIT=after"
    PRM="+SAVES=1 +DELAYUS=60000 +FLUSH=0 +SEED=7 +PUBHDR=29 +MIDWORDS=16 +OLDW0=BAD0 +EXPECT_LOAD=1 +PUBRACE=$PUBRACE_HIT +EXPECT_PUBHIT=1"
    {
    # L2 removed, L1 kept: the FDFULL file is MIXED, refused (0003) and frozen
    echo "nol2 combo x_fdfull_rgap600 mid_flush=MIXED.*relaunch.verdict=0003.frozen=1 $FDM"
    echo "nol2 combo x_flushapply_449477 commit_vs_flush=before +SAVES=1 +DELAYUS=30000 +FLUSH=2 +SEED=7 +RELAUNCHMID=1 +EXPECT_LOAD=1 +EXPECT_MID=old +EXPECT_COMMIT=after +EXPECT_RELAUNCH=1 +FLUSHAPPLY=449477"
    # the strobe hold removed: word 0 from the old bank, the rest new
    echo "nol2rd combo x_raceofs_w0_6 mid_flush=MIXED.*old=1.new=[0-9]+.*flips_under_strobe=1 $ROM +RACEOFS=6"
    echo "nol2rd combo x_raceofs_w0_7 mid_flush=MIXED.*old=1.new=[0-9]+.*flips_under_strobe=1 $ROM +RACEOFS=7"
    # the publish guard removed: the same split at the publish
    echo "pubrd combo x_pubrace_hit file=MIXED.*flips_under_strobe=1 $PRM"
    echo "nol1 combo x_flushdrain_2saves SKID.lost.[1-9] +SAVES=2 +GAPUS=40000 +DELAYUS=30000 +FLUSHDRAIN=1 +EXPECT_LOAD=1"
    echo "nol1 t7p t7p_mode7 CHECK.FAIL:.host-write.loss +V=7"
    echo "nol1 t7p t7p_mode9 the.drained.bank.lost.[1-9] +V=9"
    echo "nol3b t7p t7p_mode6_burst diag_drops.=.[1-9] +V=6 +WRGAP=2 +WRBURST=128 +WRPAUSE=3000"
    echo "nol3a t7p t7p_mode6 CHECK.FAIL:.host-write.loss +V=6"
    echo "hbdrain combo t7r_d30000 the.load.FAILED +SAVES=1 +DELAYUS=30000 +EXPECT_LOAD=1"
    echo "noflag combo fi_exact does.not.carry.the.T7.flag +SAVES=1 +SAME=1 +DELAYUS=21000 +FORCEDRAIN=17 +PAUSEDRAIN=8197 +FLUSH=2 +RELAUNCH=1 +EXPECT_FILEFLAG=1"
    echo "noflag t7s t7s_mode2_bank1 flag.rises.0 +MODE=2 +BANK=1"
    echo "flagword combo fi_exact did.not.carry.the.T7.flag.as.it.stood +SAVES=1 +SAME=1 +DELAYUS=21000 +FORCEDRAIN=17 +PAUSEDRAIN=8197 +FLUSH=2 +RELAUNCH=1 +EXPECT_FILEFLAG=1"
    echo "flagword t7s t7s_mode1_bank1 lacks.bit.14 +MODE=1 +BANK=1"
    echo "flagany combo t7r_d21000 RTL-only.run:.the.T7.flag.rose +SAVES=1 +DELAYUS=21000 +EXPECT_LOAD=1"
    echo "flagany t7p t7p_mode1 T7.flag:.rises.[1-9] +V=1"
    echo "rev05 t7p t7p_mode0 want.0603 +V=0 +NOWRITE=1"
    } >> "$ML"
    echo "== $(wc -l < "$ML") mutant runs, $JOBS at a time"
    OUT=$LOGS/mutants_summary.txt
    while read -r mut bench tag sig args; do echo "$mut $bench $tag $sig $args"; done < "$ML" | \
    xargs -P "$JOBS" -L 1 sh -c '
        mut=$1; bench=$2; tag=$3; sig=$4; shift 4
        log='"$LOGS"'/mut_${mut}_$tag.log
        vvp -n sim/tb_rc6x_${bench}_$mut.vvp +TAG=$tag "$@" > $log 2>&1
        r=$(grep "^== RC6X SCENARIO" $log | tail -n 1)
        case "$r" in
        *" FAIL"*)
            if grep -Eq "$sig" $log; then echo "   CAUGHT     mutant $mut: $r [$sig]"
            else echo "   NOT CAUGHT mutant $mut: $r, but without its signature [$sig] (see $log)"; fi ;;
        *)  echo "   NOT CAUGHT mutant $mut: ${r:-no verdict (see $log)}" ;;
        esac' sh | tee "$OUT"
    n=$(grep -c "NOT CAUGHT" "$OUT")
    t=$(grep -c "CAUGHT" "$OUT")
    if [ "$n" -eq 0 ] && [ "$t" -eq "$(wc -l < "$ML")" ]; then echo "== ALL RC6 COMBO MUTANTS CAUGHT"; exit 0; fi
    echo "== $((n + $(wc -l < "$ML") - t)) FAILURE(S): mutant run(s) not caught"; exit 1
fi

case "$1" in
"")      JL=$LIST ;;
quick)   JL=$QLIST ;;
sweep)   JL=$SLIST ;;
*)       echo "usage: $0 [quick | sweep | mutants | one BENCH ARGS...]"; exit 2 ;;
esac

echo "== building (real rc6 RTL)"
build_rtl || { echo "== 1 FAILURE(S): the build failed"; exit 1; }
OUT=$LOGS/summary_${1:-all}.txt
: > "$OUT"
if grep -q '^t7p' "$JL"; then
    t7p_prep | tee -a "$OUT"
fi
echo "== $(grep -vc '^ *$' "$JL") runs, $JOBS at a time"
run_list "$JL" rtl | tee -a "$OUT"
want=$(grep -vc '^ *$' "$JL")
grep -q '^t7p' "$JL" && want=$((want + 1))
total=$(grep -c "^== RC6X SCENARIO" "$OUT")
nfail=$(grep "^== RC6X SCENARIO" "$OUT" | grep -vc " PASS$")
nfi=$(grep "^== RC6X SCENARIO" "$OUT" | grep -c "(fault injection)")
[ "$total" -eq "$want" ] || nfail=$((nfail + want - total))
echo "== $total runs: $((total - nfi)) RTL, $nfi fault injection; failures listed with FAIL above"
if [ "$nfail" -eq 0 ]; then echo "== ALL RC6 COMBO SCENARIOS PASS"; exit 0; fi
echo "== $nfail FAILURE(S) (see $OUT and $LOGS/rtl_<tag>.log)"
exit 1
