#############################################################################
# create_project.tcl - Vivado GUI project for simulating the KWS accelerator
#
# In Vivado:  Tools > Run Tcl Script...  and pick this file.
# It creates sim/vivado/kws_sim/kws_sim.xpr (git-ignored) with two simulation sets:
#     sim_int8  -> tb/tb_kws.v with weights/int8   [active]
#     sim_int4  -> tb/tb_kws.v with weights/int4
# Then: Flow Navigator > SIMULATION > Run Simulation > Run Behavioral Simulation.
# To switch precision: Sources > Simulation Sources > right-click sim_int4 > Make Active.
# (Command line, no GUI: sim/run_sim.ps1 or sim/run_sim.sh)
#############################################################################
set here [file normalize [file dirname [info script]]]
set root [file normalize "$here/../.."]

# The part only matters for FPGA implementation; this project only simulates.
set part xc7a100tcsg324-1
if {[llength [get_parts -quiet $part]] == 0} { set part [lindex [get_parts] 0] }

create_project kws_sim "$here/kws_sim" -part $part -force

# Design sources (the same Verilog that goes to Cadence and to the FPGA)
add_files -norecurse [list "$root/rtl/kws_accel.v" "$root/rtl/kws_top.v"]
set_property top kws_int8 [get_filesets sources_1]

# One simulation set per precision. The .mem files are copied next to the
# simulator automatically, so the testbench can open them by name.
foreach bits {8 4} {
    set fs   sim_int$bits
    set data "$root/weights/int$bits"
    create_fileset -simset $fs
    # kws_params.vh is found through include_dirs (it is not added as a file,
    # so the INT8 and INT4 headers can never be mixed up)
    add_files -fileset $fs -norecurse [concat [list "$root/tb/tb_kws.v"] [glob "$data/*.mem"]]
    set_property include_dirs   [list $data]                [get_filesets $fs]
    set_property verilog_define [list KWS_TOP=kws_int$bits] [get_filesets $fs]
    set_property top tb_kws                                  [get_filesets $fs]
    set_property top_lib xil_defaultlib                      [get_filesets $fs]
    # run the whole test (the testbench ends itself with $finish)
    set_property -name xsim.simulate.runtime    -value {all} -objects [get_filesets $fs]
    # readable waveform window. Path is relative to kws_sim/kws_sim.sim/<simset>/behav/xsim
    # (xsim cannot handle spaces in an absolute path here)
    set_property -name xsim.simulate.custom_tcl -value "../../../../../waves.tcl" -objects [get_filesets $fs]
}
current_fileset -simset [get_filesets sim_int8]
delete_fileset -quiet [get_filesets -quiet sim_1]

puts "=================================================================="
puts " Project created: $here/kws_sim/kws_sim.xpr"
puts " Next: Flow Navigator > Run Simulation > Run Behavioral Simulation"
puts "=================================================================="
