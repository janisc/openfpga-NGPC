#!/bin/sh
# Savestate transport regression. Run from anywhere:
#   wsl -e sh /mnt/c/FPGA/openfpga-NGPC/sim/run.sh
# Requires iverilog (apt install iverilog). The transport does not change
# unless this prints ALL SCENARIOS MATCHED EXPECTATIONS.
set -e
cd "$(dirname "$0")/.."

iverilog -g2012 -D SYNTHESIS -o sim/tb.vvp \
    -s tb \
    upstream/rtl/Savestates/savestates.sv \
    target/pocket/ngpc_savestate_bridge.sv \
    sim/sim_synch3.v \
    sim/tb_savestate_bridge.sv

vvp sim/tb.vvp
