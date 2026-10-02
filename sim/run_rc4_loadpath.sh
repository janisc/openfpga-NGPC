#!/bin/sh
# rc4 savestate load path, copier + save engine together:
#   wsl -e sh sim/run_rc4_loadpath.sh
# NGPC_SAVE_DIAG is defined because the release build defines it
# (projects/ngpc_pocket.qsf); the header-word checks need it.
set -e
cd "$(dirname "$0")/.."

iverilog -g2012 -DNGPC_SAVE_DIAG=1 -o sim/tb_rc4lp.vvp -s tb_rc4_loadpath \
    upstream/rtl/cart/ngp_cart_overlay_geometry.sv \
    target/pocket/ngpc_cart_save.sv \
    target/pocket/ngpc_state_cart.sv \
    sim/tb_rc4_loadpath.sv

vvp sim/tb_rc4lp.vvp
