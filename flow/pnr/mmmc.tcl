# Multi-mode multi-corner setup for Innovus (sourced by init_design).
# Uses variables from flow/config.tcl.
create_library_set -name libs_slow -timing [list $LIB_SLOW]
create_library_set -name libs_fast -timing [list $LIB_FAST]

if {[file exists $QRC_TECH]} {
    create_rc_corner -name rc_typ -qx_tech_file $QRC_TECH -T 25
} else {
    create_rc_corner -name rc_typ -T 25
}

create_delay_corner -name dc_slow -library_set libs_slow -rc_corner rc_typ
create_delay_corner -name dc_fast -library_set libs_fast -rc_corner rc_typ

create_constraint_mode -name func -sdc_files [list $SYN_DIR/outputs/${TOP}.sdc]

create_analysis_view -name view_setup -constraint_mode func -delay_corner dc_slow
create_analysis_view -name view_hold  -constraint_mode func -delay_corner dc_fast

set_analysis_view -setup [list view_setup] -hold [list view_hold]
