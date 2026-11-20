#############################################################################
# fpga/build.tcl - builds the board bitstream for the KWS demo.
# One bitstream holds BOTH chips (INT8 and INT4); SW15 picks which one runs.
#
#   vivado -mode batch -source fpga/build.tcl -tclargs <board>
#   or:  fpga\build.bat <board> [program]      (Windows)
#        ./fpga/build.sh <board> [program]     (Linux)
#
#   <board>  nexys4ddr     Nexys 4 DDR and Nexys A7-100T (same pins)   [default]
#            nexys4        original Nexys 4 (no "DDR" on the board)
#            nexys_a7_50t  Nexys A7-50T (nexys4ddr pins, smaller FPGA)
#
# Output: project in fpga/work/<board>/ (git-ignored), and
#         results/fpga/kws_fpga_top_<board>.bit + results/fpga/<board>/*.rpt
# Takes about 25 minutes on a laptop (the ROMs with the 200 test clips are big).
#############################################################################
set BOARD [expr {[info exists argv] && [llength $argv] > 0 ? [lindex $argv 0] : "nexys4ddr"}]
switch -- $BOARD {
    nexys4ddr    { set PART xc7a100tcsg324-1;   set XDC nexys4ddr.xdc }
    nexys4       { set PART xc7a100tcsg324-1;   set XDC nexys4.xdc }
    nexys_a7_50t { set PART xc7a50ticsg324-1L;  set XDC nexys4ddr.xdc }
    default      { puts "ERROR: unknown board '$BOARD' (nexys4ddr, nexys4, nexys_a7_50t)"; exit 1 }
}
set here [file normalize [file dirname [info script]]]
set root [file normalize "$here/.."]

create_project kws_fpga "$here/work/$BOARD" -part $PART -force

# design + ROM files (the .mem files are found by name in synthesis and simulation)
# (paths go in [list] so folder names with spaces work)
add_files -norecurse [concat [list "$root/rtl/kws_accel.v" "$here/kws_fpga_core.v" "$here/kws_fpga_top.v"] \
                             [glob "$here/mem/*.mem"]]
add_files -fileset constrs_1 -norecurse [list "$here/constraints/$XDC"]
set_property top kws_fpga_top [get_filesets sources_1]

# simulation set (Run Behavioral Simulation in the GUI): one clip, then all 200 clips, INT8 and INT4
add_files -fileset sim_1 -norecurse [list "$root/tb/tb_fpga_top.v"]
set_property top tb_fpga_top [get_filesets sim_1]
set_property -name xsim.simulate.runtime -value {all} -objects [get_filesets sim_1]

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "synthesis failed" }

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "implementation failed" }

open_run impl_1
set rep "$root/results/fpga/$BOARD"
file mkdir $rep
report_timing_summary -file "$rep/timing_summary.rpt"
report_utilization    -file "$rep/utilization.rpt"
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
set bit "$root/results/fpga/kws_fpga_top_$BOARD.bit"
# A bitstream that misses timing can give wrong answers on the board, so it is
# never copied to results/ (the run folder keeps it for debugging).
if {$wns eq "" || $whs eq "" || $wns < 0 || $whs < 0} {
    puts "=================================================================="
    puts " ERROR: timing FAILED (setup WNS = $wns ns, hold WHS = $whs ns)."
    puts " The bitstream was NOT copied to results/fpga. See $rep/timing_summary.rpt"
    puts "=================================================================="
    exit 1
}
file copy -force [lindex [glob "$here/work/$BOARD/kws_fpga.runs/impl_1/*.bit"] 0] $bit   ;# lindex: glob returns a list
puts "=================================================================="
puts " Bitstream: $bit   (part $PART)"
puts " Timing met at 50 MHz: setup WNS = $wns ns, hold WHS = $whs ns"
puts " Program the board:  vivado -mode batch -source fpga/program.tcl -tclargs $BOARD"
puts "=================================================================="
