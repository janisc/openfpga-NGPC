#!/bin/sh
# rc5 save-engine contract (rc5_spec.md, the [rc5] items), written from the spec:
#   wsl -e sh sim/run_rc5_engine.sh
# Passes when the last line is "== ALL RC5 ENGINE SCENARIOS PASS".
# Built twice: without NGPC_SAVE_DIAG, because no rc5 behaviour and not
# header word 21 may depend on the diagnostics (only failures and the summary
# of that run are shown), and with it, as the release build defines it, for
# the verdicts in word 23.
set -e
cd "$(dirname "$0")/.."

SRC="upstream/rtl/cart/ngp_cart_overlay_geometry.sv target/pocket/ngpc_cart_save.sv sim/tb_rc5_engine.sv"

iverilog -g2012 -o sim/tb_rc5nd.vvp -s tb_rc5_engine $SRC
iverilog -g2012 -DNGPC_SAVE_DIAG -o sim/tb_rc5.vvp -s tb_rc5_engine $SRC

echo "== run 1: without NGPC_SAVE_DIAG (failures and summary only)"
# "|| true": under set -e a vvp exiting non-zero would end the script right
# here with nothing printed; the case below reports it instead.
nd=$(vvp sim/tb_rc5nd.vvp) || true
printf '%s\n' "$nd" | grep -E '^   FAIL|^== FAIL|WATCHDOG|NOTE|^== [0-9]|^== ALL' || true
echo "== run 2: with NGPC_SAVE_DIAG"
vvp sim/tb_rc5.vvp
case "$nd" in
*"== ALL RC5 ENGINE SCENARIOS PASS"*) ;;
*) echo "== 1 FAILURE(S): the build without NGPC_SAVE_DIAG failed (see run 1)"; exit 1 ;;
esac
