#!/usr/bin/env bash
# Vivado XSim run — assertions and functional coverage.
#
#   cd sim && ./run_xsim.sh
#
# ModelSim ASE cannot compile SVA or covergroups, so tb/async_fifo_sva.sv only
# ever runs here. Same RTL and same testbench as the ASE flow; this adds the
# bound checker on top.

set -e

export PATH="/c/Xilinx/Vivado/2020.2/bin:$PATH"
cd "$(dirname "$0")"

rm -rf xsim.dir xsim.covdb .Xil *.log *.pb *.jou *.wdb webtalk*

# RTL is Verilog-2001; testbench and bound checker are SystemVerilog
xvlog ../rtl/sync_2ff.v ../rtl/async_fifo.v

xvlog -sv ../tb/tb_async_fifo.sv ../tb/async_fifo_sva.sv

# -relax so the bind statement does not trip elaboration ordering.
# -timescale because the RTL carries no `timescale directive and the testbench
# does; without it xelab warns once per instance. The unit belongs to the
# simulation, not to the design, so it is set here rather than in the RTL.
xelab -debug typical -relax -timescale 1ns/1ps tb_async_fifo -s tb_snap

xsim tb_snap -runall
