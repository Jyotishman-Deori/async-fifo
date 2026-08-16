# Vivado batch synthesis check — async FIFO
#   export PATH="/c/Xilinx/Vivado/2020.2/bin:$PATH"
#   vivado -mode batch -source synth/synth_check.tcl
#
# Purpose is not a bitstream. It answers one question: did the RTL infer any
# latches or anything unintended? Read the log, do not assume.

set outdir [file dirname [info script]]

read_verilog [file join $outdir .. rtl sync_2ff.v]
read_verilog [file join $outdir .. rtl async_fifo.v]

synth_design -top async_fifo -part xc7z020clg400-1 -mode out_of_context

# Without clock definitions report_cdc has nothing to reason about and returns
# an empty report, which is easy to mistake for a clean one. Declare both
# clocks and tell the tool they are unrelated -- that is what makes it go
# looking for crossings in the first place.
create_clock -name wclk -period 7.0  [get_ports wclk]
create_clock -name rclk -period 11.0 [get_ports rclk]
set_clock_groups -asynchronous -group [get_clocks wclk] -group [get_clocks rclk]

puts "\n==================== UTILIZATION ===================="
report_utilization

puts "\n==================== LATCH CHECK ===================="
set latches [get_cells -hier -filter {PRIMITIVE_TYPE =~ REGISTER.latch.*} -quiet]
if {[llength $latches] == 0} {
    puts "PASS: 0 latches inferred"
} else {
    puts "FAIL: [llength $latches] latch(es) inferred:"
    foreach l $latches { puts "  $l" }
}

puts "\n==================== CDC ===================="

# report_cdc prints nothing useful to stdout in batch mode -- it needs -file.
# Sending it to a file and echoing that back is the only way to see it here,
# and an empty report looks identical to a clean one otherwise.
set cdc_file [file join $outdir cdc_report.txt]
report_cdc -details -file $cdc_file

set fh [open $cdc_file r]
puts [read $fh]
close $fh

# Expect CDC-6 "Multi-bit synchronized with ASYNC_REG property" on both
# crossings. That warning is correct and expected: Vivado can see a multi-bit
# bus going through a two-flop synchroniser but has no way to know it is Gray
# coded, so it flags what would otherwise be a real bug. Depth must read 2 on
# every row -- that is the synchroniser being found.

exit
