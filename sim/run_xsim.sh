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

rm -rf xsim.dir .Xil xvlog.log xelab.log xsim.log *.pb *.jou

xvlog -sv \
    ../rtl/sync_2ff.sv \
    ../rtl/async_fifo.sv \
    ../tb/tb_async_fifo.sv \
    ../tb/async_fifo_sva.sv

# -relax so the bind statement does not trip elaboration ordering
xelab -debug typical -relax tb_async_fifo -s tb_snap

xsim tb_snap -runall
