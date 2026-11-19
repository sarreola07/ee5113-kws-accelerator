#############################################################################
# pnr_flow.tcl - Cadence Innovus place & route of the KWS accelerator
# EE5113 Final Project (same steps as the HW7 MAF flow, tsmc18 library)
#
# Do not run this file directly. After synthesis, run:
#     innovus -files pnr_int8.tcl        (or pnr_int4.tcl)
# Those files set DESIGN first. Everything is written to out_int8/ or out_int4/.
#############################################################################
set OUT out_[string range $DESIGN 4 end]
set NET $OUT/${DESIGN}_Net.v
set SDC $OUT/${DESIGN}_syn.sdc
if {![file exists $NET]} {
    puts "ERROR: $NET not found. Run synthesis first:  rc -f syn_[string range $DESIGN 4 end].g"
    return
}
setMultiCpuUsage -localCpu 4

# Save a picture of the layout window (works when the Innovus GUI is open).
# Take your own screenshots too - see the guide.
proc snap {name} {
    global OUT
    catch {gui_fit}
    catch {fit}
    if {[catch {gui_dump_picture $OUT/$name.png -format PNG}]} {
        catch {dumpToGIF $OUT/$name.gif}
    }
}

#---------------- 1. Design import ----------------------------------------
# multi-mode multi-corner setup (same as HW7 mmmc.tcl, with this design's SDC)
set mmmc $OUT/${DESIGN}_mmmc.tcl
set f [open $mmmc w]
puts $f "create_rc_corner -name default_rc_corner -preRoute_res 1 -preRoute_cap 1 -preRoute_clkres 0 -preRoute_clkcap 0 -postRoute_res 1 -postRoute_cap 1 -postRoute_xcap 1 -postRoute_clkres 0 -postRoute_clkcap 0"
puts $f "create_library_set -name default_libs_max -timing {slow.lib}"
puts $f "create_library_set -name default_libs_min -timing {slow.lib}"
puts $f "create_constraint_mode -name default_mode_setup -sdc_files {$SDC}"
puts $f "create_constraint_mode -name default_mode_hold -sdc_files {$SDC}"
puts $f "create_delay_corner -name default_corner_min -rc_corner {default_rc_corner} -early_library_set {default_libs_min} -late_library_set {default_libs_max}"
puts $f "create_delay_corner -name default_corner_max -rc_corner {default_rc_corner} -early_library_set {default_libs_min} -late_library_set {default_libs_max}"
puts $f "create_analysis_view -name default_view_hold -constraint_mode {default_mode_hold} -delay_corner {default_corner_min}"
puts $f "create_analysis_view -name default_view_setup -constraint_mode {default_mode_setup} -delay_corner {default_corner_max}"
puts $f "set_analysis_view -setup {default_view_setup} -hold {default_view_hold}"
close $f

set init_gnd_net   gnd
set init_pwr_net   vdd
set init_lef_file  all.lef
set init_verilog   $NET
set init_top_cell  $DESIGN
set init_io_file   ${DESIGN}.io
init_design
# Load the timing setup AFTER the LEF, in the same order as HW7. If the MMMC
# file is given as init_mmmc_file, Innovus 20.1 reads slow.lib before the LEF
# and drops every cell ("Read 0 cells in library 'tsmc18'"), so there is no
# timing and CTS finds no clock buffers.
source $mmmc

globalNetConnect vdd -type pgpin -pin VDD -inst * -override
globalNetConnect gnd -type pgpin -pin VSS -inst * -override
globalNetConnect vdd -type tiehi -inst * -override
globalNetConnect gnd -type tielo -inst * -override

#---------------- 2. Floorplan ---------------------------------------------
# aspect ratio 1.0, 60 % core utilization, 15 um core-to-IO spacing
floorPlan -site tsm3site -r 1.0 0.60 15 15 15 15
loadIoFile ${DESIGN}.io
snap 1_floorplan

#---------------- 3. Power planning ----------------------------------------
setAddRingMode -stacked_via_top_layer Metal6 -stacked_via_bottom_layer Metal1
addRing -nets {vdd gnd} -type core_rings -follow core \
        -layer {top Metal3 bottom Metal3 left Metal2 right Metal2} \
        -width 2.0 -spacing 1.0 -offset 1.0 -center 1
addStripe -nets {vdd gnd} -layer Metal4 -direction vertical \
        -width 2.0 -spacing 1.0 -set_to_set_distance 60 \
        -start_from left -start_offset 30
sroute -connect {blockPin padPin padRing corePin floatingStripe} \
        -layerChangeRange {Metal1 Metal6} -blockPinTarget {nearestTarget} \
        -allowJogging 1 -crossoverViaLayerRange {Metal1 Metal6} \
        -allowLayerChange 1 -targetViaLayerRange {Metal1 Metal6}
snap 2_power_grid

#---------------- 4. Placement ---------------------------------------------
setPlaceMode -fp false
place_design
checkPlace $OUT/${DESIGN}.checkPlace
timeDesign -preCTS -pathReports -drvReports -slackReports -numPaths 50 \
        -prefix ${DESIGN}_preCTS -outDir $OUT/timingReports
optDesign -preCTS -outDir $OUT/timingReports -prefix ${DESIGN}_preCTS_opt
snap 3_placement

#---------------- 5. Clock tree synthesis ----------------------------------
set_ccopt_property buffer_cells   [dbGet [dbGet -p head.libCells.name CLKBUFX*].name]
set_ccopt_property inverter_cells [dbGet [dbGet -p head.libCells.name CLKINVX*].name]
set_ccopt_property target_max_trans 0.4
create_ccopt_clock_tree_spec -file $OUT/${DESIGN}_ccopt.spec
ccopt_design
report_ccopt_clock_trees -file $OUT/${DESIGN}_clock_tree.rpt
timeDesign -postCTS -pathReports -drvReports -slackReports -numPaths 50 \
        -prefix ${DESIGN}_postCTS -outDir $OUT/timingReports
optDesign -postCTS -hold -outDir $OUT/timingReports -prefix ${DESIGN}_postCTS_hold
snap 4_cts

#---------------- 6. Routing -----------------------------------------------
setNanoRouteMode -quiet -routeWithTimingDriven true
setNanoRouteMode -quiet -routeWithSiDriven false
routeDesign -globalDetail
setExtractRCMode -engine postRoute
setAnalysisMode -analysisType onChipVariation -cppr both
timeDesign -postRoute -pathReports -drvReports -slackReports -numPaths 50 \
        -prefix ${DESIGN}_postRoute -outDir $OUT/timingReports
optDesign -postRoute -outDir $OUT/timingReports -prefix ${DESIGN}_postRoute_opt
timeDesign -postRoute -hold -pathReports -slackReports -numPaths 50 \
        -prefix ${DESIGN}_postRoute_hold -outDir $OUT/timingReports
snap 5_routed

#---------------- 7. Filler cells ------------------------------------------
set fillers [dbGet [dbGet -p head.libCells.name FILL*].name]
if {$fillers ne "0x0" && $fillers ne ""} {
    addFiller -cell $fillers -prefix FILLER
}

#---------------- 8. Verification ------------------------------------------
verify_drc -report $OUT/${DESIGN}.drc.rpt -limit 1000
verifyConnectivity -type all -error 1000 -warning 50 -report $OUT/${DESIGN}.conn.rpt
verifyProcessAntenna -report $OUT/${DESIGN}.antenna.rpt

#---------------- 9. Final reports -----------------------------------------
report_timing -max_paths 5 > $OUT/${DESIGN}_final_timing.rpt
report_power -outfile $OUT/${DESIGN}_innovus_power.rpt
reportGateCount -level 5 -limit 100 -outfile $OUT/${DESIGN}_gatecount.rpt
summaryReport -noHtml -outfile $OUT/${DESIGN}_summary.rpt

#---------------- 10. Netlist, GDS2, database ------------------------------
saveNetlist $OUT/${DESIGN}_final_Net.v
streamOut $OUT/${DESIGN}.gds -mapFile gds2_innovus-2.map -libName DesignLib -units 2000 -mode ALL
saveDesign $OUT/${DESIGN}_final.enc
snap 6_final_layout

puts ""
puts "================================================================"
puts " $DESIGN place & route finished. Reports and pictures: $OUT/"
puts " Now take the Innovus screenshots listed in the guide."
puts " When finished, type  exit"
puts "================================================================"
