# EE5113 Final Project - speed-pushed synthesis of the INT4 chip (measures Fmax only)
#   run:  rc -f fmax_int4.g
set DESIGN kws_int4
set SDC    kws_fast.sdc
set TAG    _fmax
source syn_flow.tcl
