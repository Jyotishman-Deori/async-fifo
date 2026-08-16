# xsdb script: bring up the PS clocks, load the PL, release the PL resets.
#
#   "C:/Xilinx/Vivado/2020.2/bin/xsdb.bat" hw/program.tcl
#
# On a board that has not booted, the PS PLLs are off and FCLK_CLK0 is dead,
# so a PL bitstream loaded straight over JTAG gets one clock instead of two
# and the FIFO sits there doing nothing. ps7_init is what the first stage
# bootloader would normally run: it brings up the PLLs and the FCLKs.
#
# The order below matters and I got it wrong the first time. ps7_post_config
# is what enables the PS-to-PL level shifters and releases FCLK_RESET0_N, so
# it has to run *after* the bitstream is loaded. Running it before, then
# programming, leaves the whole design sitting in reset: the VIO still answers
# because it runs off the board oscillator, but every counter reads zero.
#
# No SD card and no software. hw/run_hw_test.tcl then drives the run.

set here [file dirname [file normalize [info script]]]

connect

# 1. PS clocks
targets -set -nocase -filter {name =~ "APU*"}
rst -system
after 2000

targets -set -nocase -filter {name =~ "APU*"}
source [file join $here ps7_init.tcl]
ps7_init

# 2. the PL
targets -set -nocase -filter {name =~ "xc7z*"}
fpga -file [file join $here fifo_hw.bit]

# 3. release the PL, now that there is something in it
targets -set -nocase -filter {name =~ "APU*"}
ps7_post_config

puts "PROGRAMMED_AND_RELEASED"
exit
