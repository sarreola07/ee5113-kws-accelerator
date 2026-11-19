# Timing constraints for kws_top (ASIC flow).  The period comes from
# CLK_PERIOD_NS in flow/config.tcl (default 5 ns = 200 MHz); sweep it to find
# Fmax:  CLK_PERIOD_NS=4 ./flow/run.sh syn int8
if {![info exists CLK_PERIOD_NS]} { set CLK_PERIOD_NS 5.0 }

create_clock -name clk -period $CLK_PERIOD_NS [get_ports clk]
set_clock_uncertainty 0.05 [get_clocks clk]
set_clock_transition  0.05 [get_clocks clk]

set in_ports [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay  [expr {0.2 * $CLK_PERIOD_NS}] -clock clk $in_ports
set_output_delay [expr {0.2 * $CLK_PERIOD_NS}] -clock clk [all_outputs]
set_load 0.005 [all_outputs]
