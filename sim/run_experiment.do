# ModelSim batch script — CDC encoding experiment (not the design)
#   export PATH="/c/intelFPGA_lite/20.1/modelsim_ase/win32aloem:$PATH"
#   cd sim && vsim -c -do run_experiment.do

if {[file exists work_exp]} { vdel -all -lib work_exp }
vlib work_exp

# -timescale because the experiment injects real per-bit delays; without a
# consistent unit across all three files vsim refuses to elaborate.
vlog -timescale 1ns/1ps -work work_exp ../rtl/sync_2ff.v
vlog -timescale 1ns/1ps -work work_exp ../experiments/async_fifo_exp.v
vlog -sv -timescale 1ns/1ps -work work_exp ../experiments/tb_cdc_experiment.sv

vsim -c -voptargs="+acc" work_exp.tb_cdc_experiment
run -all
quit -f
