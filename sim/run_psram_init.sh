#!/bin/sh
# 1.1.1: the PSRAM set-up (ngpc_stage_mem + psram.sv) against a CellularRAM
# model with configuration registers:
#   wsl -e sh sim/run_psram_init.sh
# Runs die 0 left synchronous with refresh off, then die 1 in deep power-down, then a
# mutant psram.sv that never raises CRE, which must FAIL.
set -e
cd "$(dirname "$0")/.."
SRC="target/pocket/ngpc_stage_mem.sv sim/tb_psram_init.sv"

iverilog -g2012 -DNGPC_SAVE_DIAG -o sim/tb_psram_init.vvp -s tb_psram_init target/pocket/psram.sv $SRC
vvp -n sim/tb_psram_init.vvp | grep -v -i "info" | tail -16

iverilog -g2012 -DNGPC_SAVE_DIAG -DDPD -o sim/tb_psram_init_dpd.vvp -s tb_psram_init target/pocket/psram.sv $SRC
vvp -n sim/tb_psram_init_dpd.vvp | grep -v -i "info" | tail -16

sed 's/cram_cre  <= cfg;/cram_cre  <= 1'"'"'b0;/; s/cram_cre <= cfg;/cram_cre <= 1'"'"'b0;/' target/pocket/psram.sv > sim/mut_psram_nocre.sv
iverilog -g2012 -DNGPC_SAVE_DIAG -o sim/tb_psram_init_mut.vvp -s tb_psram_init sim/mut_psram_nocre.sv $SRC
echo "== mutant (CRE never raised), must FAIL:"
vvp -n sim/tb_psram_init_mut.vvp | grep -E "^== "
