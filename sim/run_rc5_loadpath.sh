#!/bin/sh
# rc5 savestate load path with the REAL bridge, copier and save engine
# (rc5_spec.md B1-B3, S1, S6, S8, S11), written from the spec:
#   wsl -e sh /mnt/c/FPGA/ngpc-rc4/sim/run_rc5_loadpath.sh
# Passes when the last line is "== ALL RC5 LOAD-PATH SCENARIOS PASS".
# SYNTHESIS keeps savestates.sv at full size, as sim/run.sh does.
# NGPC_SAVE_DIAG is defined because the release build defines it
# (projects/ngpc_pocket.qsf); the verdict checks need it.
set -e
cd "$(dirname "$0")/.."

iverilog -g2012 -D SYNTHESIS -DNGPC_SAVE_DIAG=1 -o sim/tb_rc5lp.vvp -s tb_rc5_loadpath \
    upstream/rtl/Savestates/savestates.sv \
    target/pocket/ngpc_savestate_bridge.sv \
    sim/sim_synch3.v \
    upstream/rtl/cart/ngp_cart_overlay_geometry.sv \
    target/pocket/ngpc_cart_save.sv \
    target/pocket/ngpc_state_cart.sv \
    sim/tb_rc5_loadpath.sv

vvp sim/tb_rc5lp.vvp
