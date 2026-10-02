#!/bin/sh
# rc6 family B -- the staging host port: L1 (ngpc_stage_mem, an APF flush read
# against a queued host write) and L3 (core_top's write-port arbiter, part A;
# the copier's ready threshold in ngpc_stage_mem, part B).
#   wsl -e sh sim/run_rc6_hostport.sh
# Passes when the last line is "== ALL RC6 HOSTPORT SCENARIOS PASS" (exit 0);
# otherwise the last line is "== N FAILURE(S) ..." and the exit status is 1.
#
# Benches -- both compile the REAL rc6 RTL from target/pocket:
#   sim/tb_rc6b_rdwr.sv  L1: APF reads interleaved with queued writes
#                        (data_loader, data_unloader, the copier, psram,
#                        ngpc_stage_mem, the arbiter)
#   sim/tb_rc6b_port.sv  L3: APF save beats against drain beats on the one
#                        host write port (data_loader, the copier, psram,
#                        ngpc_stage_mem, the arbiter)
# The arbiter is copied VERBATIM out of target/pocket/core_top.v on every run
# (from "wire apf_save_wr" to the end of "assign sc_host_ready") into
# sim/tb_rc6b_arb.vh, which both benches `include; the run stops if those
# twelve lines are not there.
#
# Mutation check: every rc6 change the benches cover is taken out again in a
# sed copy of the real file (sim/tb_rc6b_mut_*.sv, regenerated on every run,
# each checked to differ from the real file by exactly the lines intended),
# and the benches must FAIL on each one:
#   sm_rdelse   ngpc_stage_mem: the rc5 slot load -- "else if (host_rd_i)"
#               reloads the pending slot over a popped write (L1)
#   sm_served   ngpc_stage_mem: host_rd_served never clears (L1)
#   sm_nowin    ngpc_stage_mem: no once-per-window limit on the read claim (L1)
#   sm_thr508   ngpc_stage_mem: the rc5 copier ready threshold, fill < 508 (L3 B)
#   arb_bank    arbiter: bank select on sc_host_wr instead of sc_go (L3 A)
#   arb_norep   arbiter: no replay, the copier keeps the port on a collision
#               (sc_go = sc_host_wr, sc_replay never set) (L3 A)
#   arb_gohw    arbiter: only sc_go = sc_host_wr, the replay kept (L3 A)
#   arb_apfwin  arbiter: APF keeps the port, no replay (sc_replay never set)
#   arb_nostall arbiter: the copier's ready not withheld on a collision/replay
#   arb_nocolrdy  arbiter: ready not withheld in the collision cycle only
#   arb_norpyrdy  arbiter: ready not withheld in the replay cycle only
# (arb_gohw and arb_norpyrdy only lose a beat when APF also takes the replay
# cycle, 1 clk after a collision -- port scenario 8, which data_loader's
# >= 4-clock strobe spacing cannot produce; their real-loader runs pass.)
# Built with NGPC_SAVE_DIAG as the release build is; the real RTL is also
# built without it ("nodiag", four runs) to show L1/L3 do not depend on it.
# NOMUT=1 skips the mutants; JOBS=n sets the parallelism (default 5);
# ONLY=<ERE on the job id> runs a subset (debugging only).
# Logs: sim/tb_rc6b_work/log/<job>.log, one per run.
set -u
cd "$(dirname "$0")/.."

W=sim/tb_rc6b_work
JOBS=${JOBS:-5}
NOMUT=${NOMUT:-0}
mkdir -p "$W/log"
rm -f "$W"/log/*.log "$W"/log/*.rc "$W"/jobs.txt

SMMUTS="rdelse served nowin thr508"
ARBMUTS="bank norep gohw apfwin nostall nocolrdy norpyrdy"
SMMUTS_V=$(for m in $SMMUTS; do printf 'sm_%s ' $m; done)
ARBMUTS_V=$(for m in $ARBMUTS; do printf 'arb_%s ' $m; done)

SM=target/pocket/ngpc_stage_mem.sv
ARB=sim/tb_rc6b_arb.vh
COMMON="sim/sim_dcfifo.v target/pocket/data_loader.sv target/pocket/data_unloader.sv \
        target/pocket/psram.sv target/pocket/ngpc_state_cart.sv"

bail() { echo "$1"; echo "== 1 FAILURE(S): $2"; exit 1; }

# ---- 1. the arbiter, verbatim from core_top.v --------------------------------
# (The worktree's RTL has CRLF line ends; they are stripped before matching.)
tr -d '\r' < target/pocket/core_top.v |
    sed -n '/^  wire        apf_save_wr = bios_wr_raw && ld_is_save;$/,/^                              !(sc_host_wr && apf_save_wr);$/p' \
    > "$ARB"
[ "$(wc -l < "$ARB")" -eq 12 ] ||
    bail "   core_top.v: the rc6 arbiter block was not found as expected" "arbiter extraction"
echo "== arbiter under test (target/pocket/core_top.v, verbatim):"
sed 's/^/   | /' "$ARB"

# ---- 2. mutants -------------------------------------------------------------
# mk OUT SRC NLINES sed-args...: OUT = SRC with the sed applied; exactly NLINES
# lines must differ. The stage_mem mutants start from the real file with only
# its CRs stripped ($W/stage_mem_lf.sv).
mk() {
    out=$1; src=$2; nl=$3; shift 3
    sed "$@" "$src" > "$out"
    c=$(diff "$src" "$out" | grep -c '^>')
    [ "$c" -eq "$nl" ] || bail "   mutant $out: $c line(s) changed, expected $nl" "mutant $out not built"
}
if [ "$NOMUT" = 0 ]; then
    SMLF="$W/stage_mem_lf.sv"
    tr -d '\r' < "$SM" > "$SMLF"
    mk sim/tb_rc6b_mut_sm_rdelse.sv "$SMLF" 3 \
       -e 's/^\(\s*wire\s*host_rd_claim = \)host_rd_i && !host_rd_served;/\1host_rd_i \&\& !(!host_pending \&\& !skid_empty);/' \
       -e 's/^\(\s*\)if (!host_pending) begin$/\1if (1) begin/' \
       -e 's/^\(\s*\)end else if (!skid_empty) begin$/\1end else if (!host_pending \&\& !skid_empty) begin/'
    mk sim/tb_rc6b_mut_sm_served.sv "$SMLF" 1 \
       -e 's/if (!host_rd_i) host_rd_served <= /if (1 == 0) host_rd_served <= /'
    mk sim/tb_rc6b_mut_sm_nowin.sv "$SMLF" 1 \
       -e 's/wire       host_rd_claim = host_rd_i && !host_rd_served;/wire       host_rd_claim = host_rd_i;/'
    mk sim/tb_rc6b_mut_sm_thr508.sv "$SMLF" 1 \
       -e 's/assign host_wr_ready_o = (skid_fill\[9:5\] == 5.d0);/assign host_wr_ready_o = (skid_fill < 508);/'
    mk sim/tb_rc6b_mut_arb_bank.sv "$ARB" 1 \
       -e 's/assign stage_wr_bank      = sc_go ? /assign stage_wr_bank      = sc_host_wr ? /'
    mk sim/tb_rc6b_mut_arb_norep.sv "$ARB" 2 \
       -e 's/sc_replay <= !reset_in && sc_beat && apf_save_wr;/sc_replay <= 0;/' \
       -e 's/wire        sc_go       = sc_beat && !apf_save_wr;/wire        sc_go       = sc_host_wr;/'
    mk sim/tb_rc6b_mut_arb_gohw.sv "$ARB" 1 \
       -e 's/wire        sc_go       = sc_beat && !apf_save_wr;/wire        sc_go       = sc_host_wr;/'
    mk sim/tb_rc6b_mut_arb_apfwin.sv "$ARB" 1 \
       -e 's/sc_replay <= !reset_in && sc_beat && apf_save_wr;/sc_replay <= 0;/'
    mk sim/tb_rc6b_mut_arb_nostall.sv "$ARB" 1 \
       -e 's/assign sc_host_ready      = stage_host_ready && !sc_replay &&/assign sc_host_ready      = stage_host_ready; wire rc6b_unused = !sc_replay \&\&/'
    mk sim/tb_rc6b_mut_arb_nocolrdy.sv "$ARB" 1 \
       -e 's/^\( *\)!(sc_host_wr && apf_save_wr);$/\11;/'
    mk sim/tb_rc6b_mut_arb_norpyrdy.sv "$ARB" 1 \
       -e 's/assign sc_host_ready      = stage_host_ready && !sc_replay &&/assign sc_host_ready      = stage_host_ready \&\&/'
fi

# ---- 3. builds ----------------------------------------------------------------
# build VARIANT STAGE_MEM_FILE ARBITER_FILE [DIAG]: both benches, with
# NGPC_SAVE_DIAG as the release build defines it (projects/ngpc_pocket.qsf)
# unless DIAG is 0. The "nodiag" build shows no L1/L3 behaviour depends on the
# counters (its runs skip the counter checks and count the chip's writes).
build() {
    v=$1; sm=$2; arb=$3; dg=${4:-1}
    mkdir -p "$W/$v"
    cp "$arb" "$W/$v/tb_rc6b_arb.vh"
    if [ "$dg" = 1 ]; then def=-DNGPC_SAVE_DIAG=1; else def=-DRC6B_NODIAG; fi
    for tb in rdwr port; do
        iverilog -g2012 $def "-DRC6B_LABEL=\"$v\"" -I "$W/$v" \
            -o "$W/$v/$tb.vvp" -s "tb_rc6b_$tb" $COMMON "$sm" "sim/tb_rc6b_$tb.sv" ||
            bail "   build of $v/$tb failed" "build $v/$tb"
    done
}
build real "$SM" "$ARB"
build nodiag "$SM" "$ARB" 0
if [ "$NOMUT" = 0 ]; then
    for m in $SMMUTS; do build "sm_$m" "sim/tb_rc6b_mut_sm_$m.sv" "$ARB"; done
    for m in $ARBMUTS; do build "arb_$m" "$SM" "sim/tb_rc6b_mut_arb_$m.sv"; done
fi

# ---- 4. the matrix --------------------------------------------------------------
# job ID VARIANT BENCH plusargs...
job() { id=$1; v=$2; tb=$3; shift 3; echo "$id $W/$v/$tb.vvp $*" >> "$W/jobs.txt"; }

job real.rdwr.s1.g140      real rdwr +SCN=1 +RDGAP=140 +ENG=1 +SEED=1
job real.rdwr.s1.g125      real rdwr +SCN=1 +RDGAP=125 +ENG=1 +SEED=2
job real.rdwr.s1.g777.e0   real rdwr +SCN=1 +RDGAP=777 +ENG=0 +SEED=3
job real.rdwr.s1.g163      real rdwr +SCN=1 +RDGAP=163 +ENG=1 +SEED=21
job real.rdwr.s2.g140      real rdwr +SCN=2 +RDGAP=140 +ENG=1 +SEED=4
job real.rdwr.s2.g125      real rdwr +SCN=2 +RDGAP=125 +ENG=1 +SEED=24
job real.rdwr.s2.g300.e0   real rdwr +SCN=2 +RDGAP=300 +ENG=0 +SEED=25
job real.rdwr.s3.r5        real rdwr +SCN=3 +ENG=1 +SEED=5
job real.rdwr.s3.r11       real rdwr +SCN=3 +ENG=1 +SEED=11
job real.rdwr.s3.r12       real rdwr +SCN=3 +ENG=1 +SEED=12
job real.rdwr.s3.r13       real rdwr +SCN=3 +ENG=1 +SEED=13
job real.rdwr.s4.r6        real rdwr +SCN=4 +ENG=1 +SEED=6
job real.rdwr.s4.r31       real rdwr +SCN=4 +ENG=1 +SEED=31
job real.rdwr.s4.r32       real rdwr +SCN=4 +ENG=1 +SEED=32
job real.rdwr.s4.r33.e0    real rdwr +SCN=4 +ENG=0 +SEED=33
for s in 1 2 3 4 5 6 7 8; do job real.port.s$s real port +SCN=$s; done
job real.nodiag.rdwr.s1    nodiag rdwr +SCN=1 +RDGAP=140 +ENG=1 +SEED=1
job real.nodiag.rdwr.s4    nodiag rdwr +SCN=4 +ENG=1 +SEED=6
job real.nodiag.port.s5    nodiag port +SCN=5
job real.nodiag.port.s8    nodiag port +SCN=8

if [ "$NOMUT" = 0 ]; then
    for v in sm_rdelse; do
        job $v.rdwr.s1 $v rdwr +SCN=1 +RDGAP=140 +ENG=1 +SEED=1
        job $v.rdwr.s2 $v rdwr +SCN=2 +RDGAP=140 +ENG=1 +SEED=4
        job $v.rdwr.s3 $v rdwr +SCN=3 +ENG=1 +SEED=5
        job $v.rdwr.s4 $v rdwr +SCN=4 +ENG=1 +SEED=6
    done
    for v in sm_served sm_nowin; do
        job $v.rdwr.s1 $v rdwr +SCN=1 +RDGAP=140 +ENG=1 +SEED=1
        job $v.rdwr.s3 $v rdwr +SCN=3 +ENG=1 +SEED=5
    done
    job sm_thr508.port.s5 sm_thr508 port +SCN=5
    job sm_thr508.rdwr.s4 sm_thr508 rdwr +SCN=4 +ENG=1 +SEED=6
    for v in arb_bank arb_norep; do
        for s in 1 2 5; do job $v.port.s$s $v port +SCN=$s; done
        job $v.rdwr.s4 $v rdwr +SCN=4 +ENG=1 +SEED=6
    done
    # arb_gohw and arb_norpyrdy lose a beat only when APF also takes the
    # replay cycle (1 clk after the collision: scenario 8, beyond data_loader);
    # the real-loader scenarios 4/5 are run on them too, to show that.
    for v in arb_gohw arb_norpyrdy; do
        for s in 1 3 4 5 8; do job $v.port.s$s $v port +SCN=$s; done
    done
    for v in arb_apfwin arb_nostall arb_nocolrdy; do
        for s in 1 2; do job $v.port.s$s $v port +SCN=$s; done
    done
fi

if [ -n "${ONLY:-}" ]; then           # ONLY=<ERE on the job id>: a subset, for debugging
    grep -E "^($ONLY) " "$W/jobs.txt" > "$W/jobs.only"; mv "$W/jobs.only" "$W/jobs.txt"
fi
echo "== $(wc -l < "$W/jobs.txt") runs, $JOBS at a time"
export W
# vvp -N: a bench that fails ends with $stop, i.e. exit status 1.
xargs -P "$JOBS" -L 1 sh -c 'id=$1; f=$2; shift 2; vvp -N "$f" "$@" > "$W/log/$id.log" 2>&1; echo $? > "$W/log/$id.rc"' _ < "$W/jobs.txt"

# ---- 5. verdicts ----------------------------------------------------------------
# A run passes only with exit status 0 AND its summary line as its last line.
fails=0
last() { tail -n 1 "$W/log/$1.log"; }
rc()   { cat "$W/log/$1.rc" 2>/dev/null || echo 99; }
echo "== real rc6 RTL (every run must pass)"
for id in $(awk '$1 ~ /^real\./ {print $1}' "$W/jobs.txt"); do
    l=$(last "$id"); r=$(rc "$id")
    case "$r:$l" in
    "0:== ALL RC6B-"*" SCENARIOS PASS") printf '   %-24s PASS\n' "$id" ;;
    *)  printf '   %-24s FAIL  (exit %s) %s\n' "$id" "$r" "$l"
        grep '^   FAIL\|LOST\|STALE\|committed word\|spare word' "$W/log/$id.log" | head -n 6 | sed 's/^/        /'
        fails=$((fails + 1)) ;;
    esac
done
if [ "$NOMUT" = 0 ]; then
    echo "== mutants (each must be killed: at least one of its runs fails)"
    for v in $SMMUTS_V $ARBMUTS_V; do
        killed=""; kept=""
        for id in $(awk -v p="^$v\\\\." '$1 ~ p {print $1}' "$W/jobs.txt"); do
            case "$(rc "$id"):$(last "$id")" in
            "1:== "*"FAILURE(S)"*) killed="$killed ${id#$v.}[$(grep '^   FAIL' "$W/log/$id.log" | sed 's/^   FAIL //; s/ .*//' | sort -u | tr '\n' ' ' | sed 's/ $//')]" ;;
            "0:== ALL RC6B-"*" SCENARIOS PASS") kept="$kept ${id#$v.}" ;;
            *) kept="$kept ${id#$v.}(no-result)" ;;
            esac
        done
        if [ -z "$killed$kept" ]; then
            continue                      # not in this (ONLY) subset
        elif [ -n "$killed" ]; then
            printf '   %-12s KILLED  by:%s' "$v" "$killed"
            [ -n "$kept" ] && printf '   passed:%s' "$kept"
            printf '\n'
        else
            printf '   %-12s SURVIVED  passed:%s\n' "$v" "$kept"
            fails=$((fails + 1))
        fi
    done
fi

if [ "$fails" -eq 0 ]; then
    echo "== ALL RC6 HOSTPORT SCENARIOS PASS"
    exit 0
else
    echo "== $fails FAILURE(S) in RC6 HOSTPORT (real runs failed or mutants survived; logs in $W/log)"
    exit 1
fi
