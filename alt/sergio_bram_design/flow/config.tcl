# =====================================================================
#  Shared configuration for Genus (syn) and Innovus (pnr).
#  THE ONLY FILE you should need to edit to point at the 45 nm libraries.
#
#  First time on crosby3:  ./flow/find_libs.sh   -> prints candidate paths,
#  copy the right ones below, commit, and push so your partner gets them.
# =====================================================================

# --- run selection (set by flow/run.sh through environment variables) --
set REPO_ROOT [expr {[info exists ::env(REPO_ROOT)] ? $::env(REPO_ROOT) : [file normalize [file dirname [info script]]/..]}]
set PREC      [expr {[info exists ::env(KWS_PREC)]  ? $::env(KWS_PREC)  : "int8"}]
set TOP       kws_top
set CLK_PERIOD_NS [expr {[info exists ::env(CLK_PERIOD_NS)] ? $::env(CLK_PERIOD_NS) : 5.0}]   ;# 200 MHz target

# --- RTL -----------------------------------------------------------------
set RTL_DIR   $REPO_ROOT/rtl
set WGT_DIR   $REPO_ROOT/weights/$PREC
set RTL_FILES [concat [lsort [glob $RTL_DIR/*.v]] [list $WGT_DIR/kws_rom.v]]
set SDC_FILE  $REPO_ROOT/flow/constraints.sdc

# --- 45 nm standard-cell library (Cadence GPDK045 / gsclib045) ------------
# TODO(crosby3): verify these with ./flow/find_libs.sh and fix if different.
set GPDK_ROOT  /home/opt2/gpdk045_v_6_0
set STDCELL    $GPDK_ROOT/gsclib045_all_v4.4/gsclib045

set LIB_SLOW   $STDCELL/timing/slow_vdd1v0_basicCells.lib     ;# setup (worst) corner
set LIB_FAST   $STDCELL/timing/fast_vdd1v2_basicCells.lib     ;# hold  (best)  corner
set LIB_TYP    $STDCELL/timing/slow_vdd1v0_basicCells.lib     ;# used by Genus for reports
set LEF_FILES  [list $STDCELL/lef/gsclib045_tech.lef \
                     $STDCELL/lef/gsclib045_macro.lef]
set QRC_TECH   $STDCELL/qrc/qx/gpdk045.tch                    ;# RC extraction (optional)
set GDS_MAP    $GPDK_ROOT/gpdk045/gds2_icfb.map               ;# for streamOut (optional)
set STD_GDS    $STDCELL/gds/gsclib045.gds                     ;# std-cell GDS for merge (optional)

# --- physical setup --------------------------------------------------------
set SITE         CoreSite
set PWR_NET      VDD
set GND_NET      VSS
set CORE_UTIL    0.60          ;# target placement density
set CORE_MARGIN  10            ;# um, room for the power ring
set RING_LAYERS  {top Metal11 bottom Metal11 left Metal10 right Metal10}
set STRIPE_LAYER Metal10
set ROUTE_TOP    Metal9

# --- sanity check ----------------------------------------------------------
proc kws_check_files {args} {
    foreach f $args {
        if {![file exists $f]} {
            puts "**ERROR** missing file: $f"
            puts "          edit flow/config.tcl (run ./flow/find_libs.sh to locate libraries)"
            exit 1
        }
    }
}
