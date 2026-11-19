# kws_fast.sdc - speed-pushed constraints, ONLY used to measure the maximum clock
# frequency (fmax_int8.g / fmax_int4.g). The 2 ns clock is too fast on purpose,
# so the synthesis tool builds the fastest logic it can and reports a negative slack:
#     critical path delay = 2.0 ns - slack        Fmax = 1 / critical path delay
# Input/output delays are 0 here, so Fmax is for the accelerator core itself
# (the external memory access time is not included).
create_clock -name clk -period 2.0 -waveform {0 1.0} [get_ports clk]
set_clock_transition  0.10 [get_clocks clk]
set_clock_uncertainty 0.10 [get_clocks clk]
set_input_delay  -clock clk 0.0 [get_ports {rst_n start x_data[*] w_data[*] b_data[*]}]
set_output_delay -clock clk 0.0 [all_outputs]
set_load 0.05 [all_outputs]
