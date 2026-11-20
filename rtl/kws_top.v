//============================================================================
// kws_top.v - Chip top levels for the two precisions (EE5113 Final Project)
//   kws_int8 : 8-bit weights/activations, 23-bit accumulator, SHIFT = 9
//   kws_int4 : 4-bit weights/activations, 15-bit accumulator, SHIFT = 5
// Values come from weights/int*/kws_params.vh.
// Synthesis picks one of them with:  elaborate kws_int8   (or kws_int4)
//============================================================================
`timescale 1ns/1ps

module kws_int8 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    output wire [7:0]  x_addr,
    input  wire [7:0]  x_data,
    output wire [12:0] w_addr,
    input  wire [7:0]  w_data,
    output wire [5:0]  b_addr,
    input  wire [22:0] b_data,
    output wire        busy,
    output wire        done,
    output wire [2:0]  class_out
);
    kws_accel #(.BW(8), .ACC_W(23), .SHIFT(9)) u_core (
        .clk(clk), .rst_n(rst_n), .start(start),
        .x_addr(x_addr), .x_data(x_data),
        .w_addr(w_addr), .w_data(w_data),
        .b_addr(b_addr), .b_data(b_data),
        .busy(busy), .done(done), .class_out(class_out),
        .dbg_out_wr(), .dbg_out_idx(), .dbg_acc());          // FPGA self-check only
endmodule


module kws_int4 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    output wire [7:0]  x_addr,
    input  wire [3:0]  x_data,
    output wire [12:0] w_addr,
    input  wire [3:0]  w_data,
    output wire [5:0]  b_addr,
    input  wire [14:0] b_data,
    output wire        busy,
    output wire        done,
    output wire [2:0]  class_out
);
    kws_accel #(.BW(4), .ACC_W(15), .SHIFT(5)) u_core (
        .clk(clk), .rst_n(rst_n), .start(start),
        .x_addr(x_addr), .x_data(x_data),
        .w_addr(w_addr), .w_data(w_data),
        .b_addr(b_addr), .b_data(b_data),
        .busy(busy), .done(done), .class_out(class_out),
        .dbg_out_wr(), .dbg_out_idx(), .dbg_acc());          // FPGA self-check only
endmodule
