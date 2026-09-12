#!/bin/bash
# usage: ./build.sh
set -e
SP=~/venv/bin/sandpiper-saas          # <- your venv name
$SP -i rv32i.tlv -o rv32i.sv --outdir=out
mkdir -p ~/build/rv32i
verilator --binary --timing -j 0 -Wno-fatal --top-module tb \
   +incdir+out --Mdir ~/build/rv32i -o rv32i_sim \
   tb.sv pseudo_rand.sv out/rv32i.sv
echo "built ~/build/rv32i/rv32i_sim"
