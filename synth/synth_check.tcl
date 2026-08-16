# Vivado batch synthesis check — async FIFO
#   export PATH="/c/Xilinx/Vivado/2020.2/bin:$PATH"
#   vivado -mode batch -source synth/synth_check.tcl
#
# Not building a bitstream. Three questions only: did it infer any latches,
# is the size sane, and did the tool actually recognise both crossings.
#
# report_utilization prints nine sections and for a design this small seven of
# them are solid zeros, so only Slice Logic and Memory get echoed. Those are
# the tool's own numbers -- counting primitives myself gives a different and
# more confusing answer, because two RAMD32 share one LUT site.

set outdir [file dirname [info script]]

read_verilog [file join $outdir .. rtl sync_2ff.v]
read_verilog [file join $outdir .. rtl async_fifo.v]

synth_design -top async_fifo -part xc7z020clg400-1 -mode out_of_context

# Without clocks report_cdc returns an empty report, which reads exactly like
# a clean one. Declaring them asynchronous is what sends it looking.
create_clock -name wclk -period 7.0  [get_ports wclk]
create_clock -name rclk -period 11.0 [get_ports rclk]
set_clock_groups -asynchronous -group [get_clocks wclk] -group [get_clocks rclk]

puts "\n==================== SIZE ===================="

set util_file [file join $outdir utilization.txt]
report_utilization -file $util_file

set fh [open $util_file r]
set lines [split [read $fh] "\n"]
close $fh

# Match the section headings, not the identical-looking table of contents
# entries near the top. The real ones are underlined with dashes.
set start 0
set stop  [llength $lines]
for {set i 0} {$i < [llength $lines] - 1} {incr i} {
    set this [lindex $lines $i]
    set next [lindex $lines [expr {$i + 1}]]
    if {![regexp {^-+$} $next]} { continue }
    if {$start == 0 && [regexp {^1\. Slice Logic} $this]} { set start $i }
    if {$start != 0 && [regexp {^3\. DSP}         $this]} { set stop  $i ; break }
}

foreach line [lrange $lines $start [expr {$stop - 1}]] { puts $line }

puts "\n==================== LATCHES ===================="
set latches [get_cells -hier -quiet -filter {PRIMITIVE_TYPE =~ REGISTER.latch.*}]
if {[llength $latches] == 0} {
    puts "PASS: 0 latches inferred"
} else {
    puts "FAIL: [llength $latches] latch(es) inferred:"
    foreach l $latches { puts "  $l" }
}

puts "\n==================== CDC ===================="

# report_cdc only writes anything useful with -file, so it goes to a scratch
# file and gets echoed back. The file itself is disposable.
set cdc_file [file join $outdir cdc_report.txt]
report_cdc -details -file $cdc_file

set fh [open $cdc_file r]
foreach line [split [read $fh] "\n"] {
    # skip the tool banner and the copyright block
    if {[regexp {^(Copyright|-----|\| Tool|\| Date|\| Host|\| Command|\| Design|\| Device|\| Speed)} $line]} { continue }
    puts $line
}
close $fh

# Expect CDC-6 "Multi-bit synchronized with ASYNC_REG property" on both
# crossings. That warning is correct and I would be worried if it were
# missing: Vivado can see a multi-bit bus entering a two-flop synchroniser,
# which is normally a real bug, but it cannot know the bus is Gray coded.
# Depth must read 2 on every row — that is the synchroniser being found.

exit
