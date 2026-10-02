#!/bin/sh
# State-cart copier regression:
#   wsl -e sh sim/run_statecart.sh
# NGPC_SAVE_DIAG is defined because the release build defines it
# (projects/ngpc_pocket.qsf), so diag_drain_o counts here as on hardware.
set -e
cd "$(dirname "$0")/.."
iverilog -g2012 -DNGPC_SAVE_DIAG=1 -o sim/out_statecart.vvp -s tb_state_cart \
    sim/tb_state_cart.sv target/pocket/ngpc_state_cart.sv
vvp sim/out_statecart.vvp
