#!/usr/bin/env bash
# Vivado XSim run — the same Verilog testbench under a second simulator.
#
#   cd sim && ./run_xsim.sh
#
# Everything is Verilog-2001, so nothing is compiled with -sv. Running the same
# testbench under a second tool is a cross-check: a design that passes on one
# simulator and fails on another usually has a race the first tool happened to
# resolve in its favour.

set -e

export PATH="/c/Xilinx/Vivado/2020.2/bin:$PATH"
cd "$(dirname "$0")"

rm -rf xsim.dir xsim.covdb .Xil *.log *.pb *.jou *.wdb webtalk*

xvlog ../rtl/sync_2ff.v ../rtl/async_fifo.v ../tb/tb_async_fifo.v

# -timescale because the RTL carries no `timescale directive and the testbench
# does; without it xelab warns once per instance. The unit belongs to the
# simulation, not to the design, so it is set here rather than in the RTL.
xelab -debug typical -timescale 1ns/1ps tb_async_fifo -s tb_snap

xsim tb_snap -runall
