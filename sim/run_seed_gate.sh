#!/bin/sh
# Language gate and automatic power press (rc5_spec.md G1, G2):
#   wsl -e sh sim/run_seed_gate.sh          fast, seconds
#   wsl -e sh sim/run_seed_gate.sh full     T3 counts all 2^27
#                                           standby clocks, ~20 min
# Passes when the last line is "== ALL SEED-GATE SCENARIOS PASS" (exit 0).
#
# ngpc_machine is too large to simulate whole. The bench runs the real
# upstream ngp_setup_seed with a VERBATIM copy of the machine's own text,
# cut out of target/pocket/ngpc_machine.sv here, at run time, in file order:
#   1. the machine reset net:       wire reset = ... ;
#   2. the automatic power press:   between the marker lines
#                                       // ---- auto power begin ----
#                                       // ---- auto power end ----
#                                   or, when the file has neither marker, from
#                                   the "localparam ... PWR_HOLD_CLKS" line
#                                   through "wire power_btn = ... ;"
#   3. the settings gate:           between the marker lines
#                                       // ---- settings gate begin ----
#                                       // ---- settings gate end ----
#   4. the setup seed instance:     ngp_setup_seed setup_seed ( ... );
# A piece that is missing, doubled or unterminated stops the run before
# anything is compiled. Compile errors in a piece point at its line in
# ngpc_machine.sv (`line directives).
#
# Before that, a static check of the gate's input in target/pocket/core_top.v
# (rc5_spec.md G1, Wiring): the machine's apf_reset_exit is APF reset_n
# through a synch_3 into clk_sys, and the rc4 settings_ready logic is gone.
#
# SEED_GATE_SRC=<file> takes the pieces from another file (bench self-tests).
# SEED_GATE_TOP=<file> checks another core_top.
# KEEP=1 keeps the work directory (the extracted pieces, the log).
set -e
cd "$(dirname "$0")/.."

# Every way out that is not a pass ends on the same verdict line.
no_run() { [ -n "$1" ] && echo "$1" >&2; echo "== 1 FAILURE(S)"; exit 1; }

MODE=${1:-fast}
case "$MODE" in
    fast) DEFS="" ;;
    full) DEFS="-DSEED_GATE_FULL" ;;
    *)    echo "usage: $0 [fast|full]" >&2; exit 2 ;;
esac

SRC=${SEED_GATE_SRC:-target/pocket/ngpc_machine.sv}
SEED=upstream/rtl/soc/ngp_setup_seed.sv
[ -f "$SRC" ]  || no_run "== EXTRACTION FAILED: $SRC not found"
[ -f "$SEED" ] || no_run "== $SEED not found: run scripts/setup.sh"
TOP=${SEED_GATE_TOP:-target/pocket/core_top.v}
[ -f "$TOP" ]  || no_run "== WIRING CHECK FAILED: $TOP not found"

# ---- step 0: where apf_reset_exit comes from (G1 wiring) -----------------
echo "== checking the apf_reset_exit wiring in $TOP"
if ! awk -v top="$TOP" '
function fail(msg) { printf("== WIRING CHECK FAILED: %s: %s\n", top, msg) > "/dev/stderr"; bad = 1 }
{ sub(/\r$/, ""); line = $0; sub(/\/\/.*/, "", line) }
match(line, /\.apf_reset_exit[ \t]*\([ \t]*[A-Za-z_][A-Za-z0-9_$]*[ \t]*\)/) {
    s = substr(line, RSTART, RLENGTH)
    sub(/^\.apf_reset_exit[ \t]*\([ \t]*/, "", s); sub(/[ \t]*\)$/, "", s)
    n_conn++; conn = s; conn_line = NR
}
match(line, /synch_3[ \t]+[A-Za-z_][A-Za-z0-9_$]*[ \t]*\([ \t]*reset_n[ \t]*,[ \t]*[A-Za-z_][A-Za-z0-9_$]*[ \t]*,[ \t]*clk_sys[ \t]*\)/) {
    s = substr(line, RSTART, RLENGTH)
    sub(/^[^,]*,[ \t]*/, "", s); sub(/[ \t]*,.*$/, "", s)
    sync[s] = NR
}
line ~ /(^|[^A-Za-z0-9_$])(settings_ready|settings_timeout|settings_wait|apf_run_seen)([^A-Za-z0-9_$]|$)/ {
    if (n_old++ == 0) old_line = NR
}
line ~ /\.apf_reset_exit([^A-Za-z0-9_$]|$)/ { n_port++ }
END {
    if (n_old)
        fail(sprintf("line %d (and %d more): the rc4 settings gate is still here; rc5 moves it into ngpc_machine",
                     old_line, n_old - 1))
    if (n_conn != 1 || n_port != 1)
        fail(sprintf("%d .apf_reset_exit(<net>) connection(s) (%d of the port in all), expected one", n_conn + 0, n_port + 0))
    else if (!(conn in sync))
        fail(sprintf("line %d: .apf_reset_exit(%s), but %s is not the output of a synch_3 <name> (reset_n, %s, clk_sys)",
                     conn_line, conn, conn, conn))
    if (bad) exit 1
    printf("   apf_reset_exit <- %s (line %d) <- synch_3 (reset_n, %s, clk_sys) (line %d)\n",
           conn, conn_line, conn, sync[conn]) > "/dev/stderr"
}' "$TOP"; then
    no_run
fi

OUT=$(mktemp -d "${TMPDIR:-/tmp}/seed_gate.XXXXXX")
if [ -n "$KEEP" ]; then
    echo "== work directory: $OUT"
else
    trap 'rm -rf "$OUT"' EXIT
fi

# ---- step 1: cut the pieces out of the machine ---------------------------
echo "== extracting the gate and power pieces from $SRC"
# The auto power markers are optional: without either of them the piece is
# cut from the PWR_HOLD_CLKS localparam through "wire power_btn = ...;".
if grep -Eq '^[[:space:]]*//[[:space:]]*----[[:space:]]*auto power (begin|end)[[:space:]]*----' "$SRC"; then
    AP_MARKED=1
else
    AP_MARKED=0
fi
if ! awk -v src="$SRC" -v apmark="$AP_MARKED" '
function fail(msg) { printf("== EXTRACTION FAILED: %s: %s\n", src, msg) > "/dev/stderr"; bad = 1 }
function begin_piece(p, body_line) {
    if (cur != "") fail(sprintf("line %d: \"%s\" starts inside \"%s\"", NR, p, cur))
    cur = p; seen[p]++; first[p] = body_line
    printf("\n// ---- %s: %s from line %d, verbatim ----\n", p, src, body_line)
    printf("`line %d \"%s\" 0\n", body_line, src)
}
function end_piece(p) {
    if (cur != p) fail(sprintf("line %d: end of \"%s\" outside it", NR, p))
    last[p] = NR; cur = ""
}
function has(p, id) { return text[p] ~ ("(^|[^A-Za-z0-9_$])" id "([^A-Za-z0-9_$]|$)") }
function need(p, ids,   n, a, i) {
    n = split(ids, a, " ")
    for (i = 1; i <= n; i++)
        if (!has(p, a[i])) fail(sprintf("the %s piece does not mention %s", p, a[i]))
}
function drives(p, id,   w) {
    w = "(^|[^A-Za-z0-9_$])"
    return text[p] ~ (w "assign[ \t]+" id "[ \t]*=") ||
           text[p] ~ (w "(wire|reg|logic)[^;=]*[^A-Za-z0-9_$]" id "[ \t]*=") ||
           text[p] ~ (w id "[ \t]*<=")
}
BEGIN { cur = "" }
{ sub(/\r$/, "") }                   # the working tree may be CRLF
/^[ \t]*\/\/[ \t]*----[ \t]*auto power begin[ \t]*----/    { begin_piece("auto power", NR + 1); next }
/^[ \t]*\/\/[ \t]*----[ \t]*auto power end[ \t]*----/      { end_piece("auto power"); next }
/^[ \t]*\/\/[ \t]*----[ \t]*settings gate begin[ \t]*----/ { begin_piece("settings gate", NR + 1); next }
/^[ \t]*\/\/[ \t]*----[ \t]*settings gate end[ \t]*----/   { end_piece("settings gate"); next }
cur == "" && /^[ \t]*wire[ \t]+reset[ \t]*=/              { begin_piece("reset net", NR) }
cur == "" && apmark + 0 == 0 &&
    /^[ \t]*localparam[^;]*[^A-Za-z0-9_$]PWR_HOLD_CLKS[ \t]*=/ { begin_piece("auto power", NR); ap_tail = 0 }
cur == "" && /^[ \t]*ngp_setup_seed([ \t#(]|$)/           { begin_piece("seed instance", NR) }
cur != "" {
    print
    text[cur] = text[cur] "\n" $0
    if (cur == "reset net" && /;/)                      end_piece("reset net")
    else if (cur == "seed instance" && /^[ \t]*\)[ \t]*;/) end_piece("seed instance")
    else if (cur == "auto power" && apmark + 0 == 0) {
        # unmarked: the piece ends with the statement "wire power_btn = ...;"
        if (/^[ \t]*wire[ \t]+power_btn[ \t]*=/) ap_tail = 1
        if (ap_tail && /;/) end_piece("auto power")
    }
}
END {
    if (cur != "") fail(sprintf("\"%s\" (from line %d) never ends", cur, first[cur]))
    split("reset net|auto power|settings gate|seed instance", P, "|")
    for (i = 1; i <= 4; i++) {
        p = P[i]
        if (seen[p] == 0)     fail(sprintf("no \"%s\" piece", p))
        else if (seen[p] > 1) fail(sprintf("%d \"%s\" pieces, expected one", seen[p], p))
    }
    if (seen["auto power"] == 0) {
        print "   No \"localparam ... PWR_HOLD_CLKS = ...\" line to start the automatic power" > "/dev/stderr"
        print "   press at. Put these two lines around it in ngpc_machine.sv, from the" > "/dev/stderr"
        print "   pwr_hold_q declarations through \"wire power_btn = ...;\":" > "/dev/stderr"
        print "\t// ---- auto power begin ----" > "/dev/stderr"
        print "\t// ---- auto power end ----" > "/dev/stderr"
    }
    if (seen["settings gate"] == 0) {
        print "   Put these two lines around the settings gate in ngpc_machine.sv," > "/dev/stderr"
        print "   from apf_run_seen_q through \"wire settings_ready = ...;\":" > "/dev/stderr"
        print "\t// ---- settings gate begin ----" > "/dev/stderr"
        print "\t// ---- settings gate end ----" > "/dev/stderr"
    }
    if (bad) exit 1

    # What the bench reads or writes by name (the spec names them).
    need("auto power",    "pwr_hold_q auto_pwr_pending_q power_btn")
    need("settings gate", "apf_reset_exit bios_setup_ready apf_run_seen_q settings_wait_q settings_late_q settings_ready")
    need("seed instance", "setup_ready settings_ready")
    # What the bench drives must come from outside the pieces.
    n = split("reset_in hard_reset bios_reset base_reset strap_reset cart_download cart_download_start " \
              "wram_clear_busy overlay_boot_hold cart_present cart_ready bios_setup_ready pause_ready " \
              "bios_mono_active cart_header_valid cart_header_catalog cart_header_subcatalog " \
              "cart_header_title host_rtc", D, " ")
    for (i = 1; i <= 4; i++)
        for (j = 1; j <= n; j++)
            if (drives(P[i], D[j]))
                fail(sprintf("the %s piece drives %s, which the bench models from outside", P[i], D[j]))
    if (bad) exit 1

    for (i = 1; i <= 4; i++)
        printf("   %-14s lines %d-%d\n", P[i], first[P[i]], last[P[i]]) > "/dev/stderr"
}
' "$SRC" > "$OUT/seed_gate_extract.svh"; then
    no_run
fi

# ---- step 2: compile and run ---------------------------------------------
iverilog -g2012 $DEFS -I "$OUT" -o "$OUT/tb_seed_gate.vvp" -s tb_seed_gate \
    "$SEED" \
    sim/tb_seed_gate.sv || no_run "== COMPILE FAILED"

vvp -n "$OUT/tb_seed_gate.vvp" | tee "$OUT/log"
case "$(tail -n 1 "$OUT/log")" in
    "== ALL SEED-GATE SCENARIOS PASS") exit 0 ;;
    "== "*" FAILURE(S)")               exit 1 ;;
    *)                                 no_run "== the simulation ended without a verdict" ;;
esac
