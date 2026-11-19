#############################################################################
# waves.tcl - used by Vivado when the simulation starts (xsim.simulate.custom_tcl)
# Adds the important signals to the waveform window, then runs the full test.
#############################################################################
set core /tb_kws/dut/u_core
if {[catch {
    add_wave_divider "Chip interface"
    add_wave /tb_kws/clk /tb_kws/rst_n /tb_kws/start /tb_kws/busy /tb_kws/done
    add_wave -radix unsigned /tb_kws/class_out /tb_kws/vec
    add_wave_divider "Memory ports"
    add_wave -radix unsigned /tb_kws/x_addr
    add_wave -radix dec      /tb_kws/x_data
    add_wave -radix unsigned /tb_kws/w_addr
    add_wave -radix dec      /tb_kws/w_data
    add_wave -radix unsigned /tb_kws/b_addr
    add_wave -radix dec      /tb_kws/b_data
    add_wave_divider "Datapath (MAC, ReLU, argmax)"
    add_wave -radix ascii    /tb_kws/state_name
    add_wave                 $core/layer
    add_wave -radix unsigned $core/neu_cnt $core/in_cnt
    add_wave -radix dec      $core/act $core/prod $core/acc
    add_wave -radix unsigned $core/h_new
    add_wave -radix dec      $core/best_val
    add_wave -radix unsigned $core/best_idx
} msg]} {
    # batch mode has no waveform window
    puts "waves.tcl: $msg"
}
run -all
