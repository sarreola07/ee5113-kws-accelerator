#############################################################################
# fpga/program.tcl - loads the bitstream into a Nexys board connected by USB
# (USB-PROG port, board powered on).
#
#   vivado -mode batch -source fpga/program.tcl -tclargs <nexys4ddr|nexys4|nexys_a7_50t>
#   or:  fpga\program.bat <board>
#
# Uses results/fpga/kws_fpga_top_<board>.bit (prebuilt and committed, or made by build.tcl).
#############################################################################
set BOARD [expr {[info exists argv] && [llength $argv] > 0 ? [lindex $argv 0] : "nexys4ddr"}]
set root  [file normalize "[file dirname [info script]]/.."]
set bit   "$root/results/fpga/kws_fpga_top_$BOARD.bit"
if {![file exists $bit]} { puts "ERROR: $bit not found - run fpga/build.tcl -tclargs $BOARD first"; exit 1 }

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices xc7a*] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "Programmed $dev with $bit"
close_hw_target
disconnect_hw_server
close_hw_manager
