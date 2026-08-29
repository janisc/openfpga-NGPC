#!/bin/sh
# Cartridge-save engine regression:
#   wsl -e sh /mnt/c/FPGA/openfpga-NGPC/sim/run_cartsave.sh
# The staging engine does not go to hardware unless this passes.
set -e
cd "$(dirname "$0")/.."

iverilog -g2012 -o sim/tb_cs.vvp -s tb_cart_save \
    upstream/rtl/cart/ngp_cart_overlay_geometry.sv \
    target/pocket/ngpc_cart_save.sv \
    sim/tb_cart_save.sv

vvp sim/tb_cs.vvp
