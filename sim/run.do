# ModelSim batch script — async FIFO
#   export PATH="/c/intelFPGA_lite/20.1/modelsim_ase/win32aloem:$PATH"
#   cd sim && vsim -c -do run.do
#
# ModelSim ASE has no SVA/covergroup support. Assertions and functional
# coverage go through Vivado XSim, same as the MTP flow.

if {[file exists work]} { vdel -all }
vlib work

vlog -sv -work work ../rtl/sync_2ff.sv
vlog -sv -work work ../rtl/async_fifo.sv
vlog -sv -work work ../tb/tb_async_fifo.sv

vsim -c -voptargs="+acc" work.tb_async_fifo
run -all
quit -f
