# Program the Nexys 4 over USB (board plugged in and powered on).
#   vivado -mode batch -source fpga/program.tcl -tclargs <int8|int4> <nexys4ddr|nexys4>
set PREC  [expr {[llength $argv] > 0 ? [lindex $argv 0] : "int8"}]
set BOARD [expr {[llength $argv] > 1 ? [lindex $argv 1] : "nexys4ddr"}]
set BIT [file normalize [file dirname [info script]]/work/${PREC}_${BOARD}/fpga_top.bit]
if {![file exists $BIT]} { puts "ERROR: $BIT not found - run build first"; exit 1 }

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $dev
set_property PROGRAM.FILE $BIT $dev
program_hw_devices $dev
puts "Programmed $BIT"
close_hw_manager
