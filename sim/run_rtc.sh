#!/bin/sh
set -e
cd "$(dirname "$0")/.."
iverilog -g2012 -o sim/out_rtc.vvp sim/tb_apf_rtc.sv target/pocket/ngpc_apf_rtc.sv
vvp sim/out_rtc.vvp
