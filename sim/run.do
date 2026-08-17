# ModelSim batch script — async FIFO
#   export PATH="/c/intelFPGA_lite/20.1/modelsim_ase/win32aloem:$PATH"
#   cd sim && vsim -c -do run.do
#
# Everything here is Verilog-2001, so nothing is compiled with -sv. Checks
# are procedural and coverage is counted by hand, because Verilog has neither
# assertions nor covergroups.

# -lib work, not a bare vdel -all: the bare form goes after whatever the
# current library happens to be and fails with "unable to remove directory"
# if anything else is still holding it.
if {[file exists work]} { vdel -lib work -all }
vlib work

vlog -work work ../rtl/sync_2ff.v
vlog -work work ../rtl/async_fifo.v
vlog -work work ../tb/tb_async_fifo.v

vsim -c -voptargs="+acc" work.tb_async_fifo
run -all
quit -f
