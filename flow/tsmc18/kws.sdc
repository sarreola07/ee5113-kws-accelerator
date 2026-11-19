# kws.sdc - timing constraints for the KWS accelerator chip (library units: ns, pF)
# Used for the real implementation: 100 MHz clock, synthesis + Innovus.
create_clock -name clk -period 10.0 -waveform {0 5.0} [get_ports clk]
set_clock_transition  0.10 [get_clocks clk]
set_clock_uncertainty 0.10 [get_clocks clk]

# control inputs
set_input_delay  -clock clk 0.50 [get_ports {rst_n start}]

# data coming back from the external input/weight/bias memories:
# 3 ns of the 10 ns cycle is reserved for the memory access time
set_input_delay  -clock clk 3.00 [get_ports {x_data[*] w_data[*] b_data[*]}]

# memory addresses and results
set_output_delay -clock clk 1.00 [all_outputs]
set_load 0.05 [all_outputs]
