#!/bin/sh
# rc4 save-engine contract (rc4_spec.md S1-S10), written from the spec:
#   wsl -e sh /mnt/c/FPGA/ngpc-rc4/sim/run_rc4_engine.sh
# Passes when the last line is "== ALL RC4 ENGINE SCENARIOS PASS".
# NGPC_SAVE_DIAG is defined because header words 18 and 23 are diagnostics.
set -e
cd "$(dirname "$0")/.."

iverilog -g2012 -DNGPC_SAVE_DIAG -o sim/tb_rc4.vvp -s tb_rc4_engine \
    upstream/rtl/cart/ngp_cart_overlay_geometry.sv \
    target/pocket/ngpc_cart_save.sv \
    sim/tb_rc4_engine.sv

vvp sim/tb_rc4.vvp
