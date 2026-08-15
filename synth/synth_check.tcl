# Vivado batch synthesis check — async FIFO
#   export PATH="/c/Xilinx/Vivado/2020.2/bin:$PATH"
#   vivado -mode batch -source synth/synth_check.tcl
#
# Purpose is not a bitstream. It answers one question: did the RTL infer any
# latches or anything unintended? Read the log, do not assume.

set outdir [file dirname [info script]]

read_verilog -sv [file join $outdir .. rtl sync_2ff.sv]
read_verilog -sv [file join $outdir .. rtl async_fifo.sv]

synth_design -top async_fifo -part xc7z020clg400-1 -mode out_of_context

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
report_cdc -details -quiet

exit
