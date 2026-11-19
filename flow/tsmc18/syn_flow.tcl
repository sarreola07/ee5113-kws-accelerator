#############################################################################
# syn_flow.tcl - Cadence RTL Compiler synthesis of the KWS accelerator
# EE5113 Final Project
#
# Do not run this file directly. Run one of:
#     rc -f syn_int8.g      INT8 chip, 100 MHz  -> netlist for Innovus
#     rc -f syn_int4.g      INT4 chip, 100 MHz  -> netlist for Innovus
#     rc -f fmax_int8.g     INT8 speed-pushed run -> maximum clock frequency
#     rc -f fmax_int4.g     INT4 speed-pushed run -> maximum clock frequency
# (genus -legacy_ui -f <file> also works). They set DESIGN, SDC and TAG first.
#############################################################################
set OUT out_[string range $DESIGN 4 end]     ;# out_int8 or out_int4
file mkdir $OUT
set P $OUT/${DESIGN}${TAG}                   ;# prefix of every output file

set_attribute lib_search_path .
set_attribute hdl_search_path .
set_attribute library slow.lib               ;# tsmc18 slow corner (same as HW7; copy it here, not in git)

# No scan flip-flops: this design has no scan chain (no DFT). Left alone, RC uses
# SDFF cells as cheap "flop + mux" for the enable registers, and Innovus 20.1 then
# stops placement with IMPSP-9099 ("scan chains exist ... not defined").
foreach pat {SDFF* SEDFF*} {
    foreach c [find / -libcell $pat] { set_attribute avoid true $c }
}

# RTL comes from the repo's rtl/ folder (run this flow from flow/tsmc18/)
read_hdl ../../rtl/kws_accel.v
read_hdl ../../rtl/kws_top.v
elaborate $DESIGN
catch {check_design -unresolved}
read_sdc $SDC

synthesize -to_mapped -effort high

report timing > ${P}_time.rpt
report area   > ${P}_area.rpt
report gates  > ${P}_gates.rpt
report power  > ${P}_pwr.rpt
report qor    > ${P}_qor.rpt

if {$TAG eq ""} {
    # netlist + constraints for Innovus
    write_hdl > ${P}_Net.v
    write_sdc > ${P}_syn.sdc
}

puts ""
puts "================================================================"
puts " $DESIGN synthesis finished ($SDC). Reports: ${P}_*.rpt"
puts "================================================================"
exit
