# =====================================================================
#  Xilinx Vivado NON-PROJECT build for the Nexys 4 demo.
#  (No .xpr project file: nothing machine-specific gets committed.)
#
#  vivado -mode batch -source fpga/build.tcl -tclargs <int8|int4> <nexys4ddr|nexys4>
#  or simply:  fpga\build.bat int8 nexys4ddr      (Windows)
#              ./fpga/build.sh int8 nexys4ddr     (Linux)
#
#  Outputs in fpga/work/<prec>_<board>/  (git-ignored):
#     fpga_top.bit, utilization.rpt, timing.rpt, power.rpt
# =====================================================================
set PREC  [expr {[llength $argv] > 0 ? [lindex $argv 0] : "int8"}]
set BOARD [expr {[llength $argv] > 1 ? [lindex $argv 1] : "nexys4ddr"}]
set PART  xc7a100tcsg324-1

set FPGA_DIR [file normalize [file dirname [info script]]]
set ROOT     [file normalize $FPGA_DIR/..]
set WGT      $ROOT/weights/$PREC
set OUT      $FPGA_DIR/work/${PREC}_${BOARD}
file mkdir $OUT

foreach f [list $WGT/kws_rom.v $WGT/fpga_clips_rom.v $FPGA_DIR/constraints/$BOARD.xdc] {
    if {![file exists $f]} { puts "ERROR: missing $f"; exit 1 }
}

read_verilog [glob $ROOT/rtl/*.v]
read_verilog [list $WGT/kws_rom.v $WGT/fpga_clips_rom.v $FPGA_DIR/fpga_top.v]
read_xdc $FPGA_DIR/constraints/$BOARD.xdc

synth_design -top fpga_top -part $PART -include_dirs [list $WGT]
opt_design
place_design
phys_opt_design
route_design

report_utilization    -file $OUT/utilization.rpt
report_timing_summary -file $OUT/timing.rpt
report_power          -file $OUT/power.rpt
write_bitstream -force $OUT/fpga_top.bit

set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
puts "=================================================================="
puts " Bitstream: $OUT/fpga_top.bit"
puts " Worst setup slack @100 MHz: $wns ns  (negative = timing FAILED)"
puts " Program the board:  vivado -mode batch -source fpga/program.tcl -tclargs $PREC $BOARD"
puts "=================================================================="
