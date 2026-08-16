# Build the PYNQ-Z2 bitstream for the async FIFO hardware test.
#
#   export PATH="/c/Xilinx/Vivado/2020.2/bin:$PATH"
#   vivado -mode batch -source hw/build.tcl
#
# The project is built under TEMP, not inside the repo. This repo lives in a
# OneDrive folder and Vivado cannot build there: OneDrive holds a lock on the
# project cache and synth_design dies with "fifo_hw.cache/wt already exists,
# is a directory, but is not writable". Only the finished artifacts get copied
# back into hw/.

set here  [file dirname [file normalize [info script]]]
set repo  [file dirname $here]
set build [file join $::env(TEMP) async_fifo_hw_build]

file delete -force $build

create_project -force fifo_hw $build -part xc7z020clg400-1
set_property board_part tul.com.tw:pynq-z2:part0:1.0 [current_project]

# ---------------------------------------------------------------------
# The PS, present only as a clock source
#
# FCLK_CLK0 runs off the PS PLL and the 33.333 MHz crystal. sys_clk runs off
# the board's separate 125 MHz oscillator. That independence is the entire
# reason the PS is in this design at all.
# ---------------------------------------------------------------------
create_bd_design "ps"
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7

apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" \
             Master "Disable" Slave "Disable"} [get_bd_cells ps7]

set_property -dict [list \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_USE_M_AXI_GP0 {0} \
] [get_bd_cells ps7]

# Named ports rather than make_external, so the wrapper has predictable
# signal names for top_pynq_z2.v to connect to.
create_bd_port -dir O -type clk FCLK_CLK0
create_bd_port -dir O -type rst FCLK_RESET0_N
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]     [get_bd_ports FCLK_CLK0]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_ports FCLK_RESET0_N]

validate_bd_design
save_bd_design

set wrapper [make_wrapper -files [get_files ps.bd] -top -force]
add_files -norecurse $wrapper

# ---------------------------------------------------------------------
# design sources
# ---------------------------------------------------------------------
add_files -norecurse [list \
    [file join $repo rtl sync_2ff.v] \
    [file join $repo rtl async_fifo.v] \
    [file join $here fifo_hw_test.v] \
    [file join $here top_pynq_z2.v] \
]

add_files -fileset constrs_1 -norecurse [file join $here pynq_z2.xdc]
set_property top top_pynq_z2 [current_fileset]

# ---------------------------------------------------------------------
# VIO, to read the counters back over JTAG
#
# 32-bit inputs for the three counters, 2 bits for the full/empty sticky
# flags, and four outputs to drive the run, reset and the two rate knobs.
# ---------------------------------------------------------------------
create_ip -name vio -vendor xilinx.com -library ip -module_name vio_0

set_property -dict [list \
    CONFIG.C_PROBE_IN0_WIDTH  {32} \
    CONFIG.C_PROBE_IN1_WIDTH  {32} \
    CONFIG.C_PROBE_IN2_WIDTH  {32} \
    CONFIG.C_PROBE_IN3_WIDTH  {2}  \
    CONFIG.C_NUM_PROBE_IN     {4}  \
    CONFIG.C_PROBE_OUT0_WIDTH {1}  \
    CONFIG.C_PROBE_OUT1_WIDTH {1}  \
    CONFIG.C_PROBE_OUT2_WIDTH {4}  \
    CONFIG.C_PROBE_OUT3_WIDTH {4}  \
    CONFIG.C_NUM_PROBE_OUT    {4}  \
    CONFIG.C_PROBE_OUT0_INIT_VAL {0x0} \
    CONFIG.C_PROBE_OUT1_INIT_VAL {0x0} \
    CONFIG.C_PROBE_OUT2_INIT_VAL {0xF} \
    CONFIG.C_PROBE_OUT3_INIT_VAL {0x2} \
] [get_ips vio_0]

generate_target all [get_files vio_0.xci]

# ---------------------------------------------------------------------
# build
# ---------------------------------------------------------------------
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "synthesis failed"
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "implementation failed"
}

open_run impl_1

puts "\n==================== TIMING ===================="
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts [format "  worst setup slack (WNS)  %s ns" $wns]
puts [format "  worst hold slack  (WHS)  %s ns" $whs]
if {$wns < 0 || $whs < 0} {
    puts "  TIMING NOT MET"
} else {
    puts "  timing met"
}

puts "\n==================== CDC ===================="
set cdc_file [file join $build cdc_impl.txt]
report_cdc -details -file $cdc_file
set fh [open $cdc_file r]
foreach line [split [read $fh] "\n"] {
    if {[regexp {^(Copyright|-----|\| Tool|\| Date|\| Host|\| Command|\| Design|\| Device|\| Speed)} $line]} { continue }
    puts $line
}
close $fh

# ---------------------------------------------------------------------
# collect what programming needs, so hw/build can be deleted afterwards
# ---------------------------------------------------------------------
file copy -force [file join $build fifo_hw.runs impl_1 top_pynq_z2.bit] \
                 [file join $here fifo_hw.bit]

# The debug probes file is what lets the hardware manager map VIO probes back
# to signal names. Without it the VIO shows up as unnamed nets.
set ltx [file join $build fifo_hw.runs impl_1 top_pynq_z2.ltx]
if {[file exists $ltx]} { file copy -force $ltx [file join $here fifo_hw.ltx] }

# ps7_init is generated with the block design and is what brings the PS PLLs
# up over JTAG, so it has to come along too.
foreach pat {ps7_init.tcl ps7_init.c ps7_init.h} {
    foreach f [glob -nocomplain [file join $build *.gen sources_1 bd ps ip ps_ps7_0 $pat] \
                                [file join $build *.srcs sources_1 bd ps ip ps_ps7_0 $pat]] {
        file copy -force $f $here
    }
}

puts "\nbitstream: [file join $here fifo_hw.bit]"
exit
