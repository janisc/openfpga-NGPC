#!/bin/sh
set -e
cd "$(dirname "$0")/.."
iverilog -g2012 -o sim/out_statecart.vvp sim/tb_state_cart.sv target/pocket/ngpc_state_cart.sv
vvp sim/out_statecart.vvp
