# EE5113 Final Project - speed-pushed synthesis of the INT8 chip (measures Fmax only)
#   run:  rc -f fmax_int8.g
set DESIGN kws_int8
set SDC    kws_fast.sdc
set TAG    _fmax
source syn_flow.tcl
