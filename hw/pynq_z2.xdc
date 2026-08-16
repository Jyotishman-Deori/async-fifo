# PYNQ-Z2 constraints for the async FIFO hardware test.
# Pin numbers are from the board file shipped with Vivado 2020.2
# (data/boards/board_files/pynq-z2/A.0/part0_pins.xml).

set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports sys_clk]
create_clock -period 8.000 -name sys_clk [get_ports sys_clk]

set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

# sys_clk is the 125 MHz board oscillator, clk_fpga_0 is FCLK_CLK0 off the PS
# PLL. Separate crystals with no common reference, so there is no meaningful
# phase relationship for the timer to hold them to. Saying so is what stops
# Vivado trying to close timing on paths between them, and it is also the
# statement the whole design depends on being true.
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk] \
    -group [get_clocks clk_fpga_0]
