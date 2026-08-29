#!/bin/sh
# Host write leg of the save staging region:
#   wsl -e sh /mnt/c/FPGA/openfpga-NGPC/sim/run_stage.sh
set -e
cd "$(dirname "$0")/.."

iverilog -g2012 -DNGPC_SAVE_DIAG -o sim/tb_sh.vvp -s tb_stage_host \
    sim/sim_dcfifo.v \
    target/pocket/data_loader.sv \
    target/pocket/ngpc_stage_mem.sv \
    target/pocket/psram.sv \
    sim/tb_stage_host.sv

vvp sim/tb_sh.vvp
