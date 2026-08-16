# Program the PL and run the FIFO test on hardware.
#
#   export PATH="/c/Xilinx/Vivado/2020.2/bin:$PATH"
#   xsdb hw/program.tcl              ;# first: PS clocks, bitstream, release
#   vivado -mode batch -source hw/run_hw_test.tcl
#
# Two phases, the same shape as the simulation: write fast against a slow
# reader so the FIFO jams up against full, then the reverse so it runs dry.
# Counters are not cleared between phases, so the totals accumulate and the
# full/empty sticky bits report whether both corners were actually reached.
#
# Rates only ever change while run is low. The rate values cross into the
# write clock domain as plain multi-bit buses, so they must be static before
# anything samples them; the counters go the other way for the same reason,
# and are only read once both sides have stopped.

set here [file dirname [file normalize [info script]]]

set PHASE_SECONDS 10

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target

current_hw_device [lindex [get_hw_devices xc7z020*] 0]
set dev [current_hw_device]

# The PL is already loaded by hw/program.tcl, which also had to run
# ps7_post_config afterwards to release FCLK_RESET0_N. Programming again from
# here would drop the design back into reset and every counter would read zero.
set_property PROBES.FILE [file join $here fifo_hw.ltx] $dev
refresh_hw_device -update_hw_probes true $dev

set vio [lindex [get_hw_vios -of_objects $dev] 0]

# The .ltx maps probes back to the net names they were connected to, so they
# come out as words_written, errors and so on rather than probe_in0.
proc probe {vio name} {
    set p [lsearch -inline [get_hw_probes -of_objects $vio] $name]
    if {$p eq ""} { error "no probe named $name" }
    return [get_hw_probes $p -of_objects $vio]
}

proc rd {vio pat} {
    set p [probe $vio $pat]
    set_property INPUT_VALUE_RADIX UNSIGNED $p
    refresh_hw_vio $vio
    return [get_property INPUT_VALUE $p]
}

proc wr {vio pat val} {
    set p [probe $vio $pat]
    set_property OUTPUT_VALUE_RADIX UNSIGNED $p
    set_property OUTPUT_VALUE $val $p
    commit_hw_vio $p
}

puts "probes found:"
foreach p [get_hw_probes -of_objects $vio] { puts "   $p" }

# Clear once, here, and not again between the phases. Stopping a phase only
# pauses both LFSRs; they stay in lockstep, so phase 2 picks up exactly where
# phase 1 left off and the totals accumulate.
wr $vio vio_run 0
wr $vio vio_rst 1
after 300
wr $vio vio_rst 0
after 300

proc phase {vio name wr_rate rd_rate secs} {
    puts "\n-- $name: w_rate $wr_rate/16, r_rate $rd_rate/16, $secs s"
    wr $vio vio_w_rate $wr_rate
    wr $vio vio_r_rate $rd_rate
    after 300
    wr $vio vio_run 1

    # Chunked rather than one long "after". Blocking the Tcl event loop for
    # ten seconds straight starves the hw_server connection and it drops with
    # "hw_server failed during internal command" partway through the run.
    for {set t 0} {$t < $secs} {incr t} {
        after 1000
        refresh_hw_vio $vio
    }

    wr $vio vio_run 0
    after 500

    set written [rd $vio words_written]
    set read    [rd $vio words_read]
    set errors  [rd $vio errors]
    set full    [rd $vio full_seen_r]
    set empty   [rd $vio empty_seen]
    puts [format "   words written %-12s read %-12s errors %s" $written $read $errors]
    puts [format "   full seen %s   empty seen %s" $full $empty]
    return [list $written $read $errors $full $empty]
}

phase $vio "phase 1  write fast, read slow" 15 2 $PHASE_SECONDS
set r [phase $vio "phase 2  write slow, read fast" 2 15 $PHASE_SECONDS]

lassign $r written read errors full_seen empty_seen

puts "\n============================================================="
puts " HARDWARE RESULT   PYNQ-Z2, xc7z020clg400-1"
puts "============================================================="
puts [format "  wclk   FCLK_CLK0, 100 MHz off the PS PLL"]
puts [format "  rclk   sys_clk,   125 MHz board oscillator"]
puts [format "  independent crystals, so the phase between them drifts"]
puts ""
puts [format "  words written        %s" $written]
puts [format "  words read+checked   %s" $read]
puts [format "  data errors          %s" $errors]
puts [format "  reached full         %s" [expr {$full_seen ? "yes" : "no"}]]
puts [format "  reached empty        %s" [expr {$empty_seen ? "yes" : "no"}]]
puts "-------------------------------------------------------------"
if {!$full_seen || !$empty_seen} {
    puts " INCONCLUSIVE: a corner was never reached, so the rates were wrong"
} elseif {$errors == 0} {
    puts " PASS"
} else {
    puts " FAIL: $errors bad words"
}
puts "============================================================="

close_hw_target
exit
