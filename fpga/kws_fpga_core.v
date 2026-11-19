//============================================================================
// kws_fpga_core.v - one precision of the KWS accelerator plus its memories,
// for the FPGA demo. The ASIC core (kws_accel.v) is used unchanged; the
// memories that sit outside the ASIC chip are ROMs here, loaded from mem/.
//
// The core reads memories in the same clock cycle (asynchronous read), so the
// ROMs are built from LUTs (distributed ROM), not block RAM.
// Clip c of the 200 test clips starts at address c*256, so the input address
// is just {clip, x_addr} (no adder needed).
//============================================================================
`timescale 1ns/1ps

module kws_fpga_core #(
    parameter BW     = 8,
    parameter ACC_W  = 23,
    parameter SHIFT  = 9,
    parameter X_FILE = "int8_inputs256.mem",
    parameter W_FILE = "int8_weights.mem",
    parameter B_FILE = "int8_biases.mem",
    parameter E_FILE = "int8_expected.mem",
    parameter L_FILE = "int8_labels.mem"
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,      // 1-cycle pulse
    input  wire [7:0] clip,       // test clip 0..199, held during an inference
    output wire       busy,
    output wire       done,       // 1-cycle pulse, class_out is valid
    output wire [2:0] class_out,  // recognized word
    output wire [2:0] expected,   // what the Python model says for this clip
    output wire [2:0] label       // the true word of this clip
);
    (* rom_style = "distributed" *) reg [BW-1:0]    xrom [0:200*256-1];
    (* rom_style = "distributed" *) reg [BW-1:0]    wrom [0:8191];
    (* rom_style = "distributed" *) reg [ACC_W-1:0] brom [0:63];
    reg [7:0] erom [0:199];
    reg [7:0] lrom [0:199];

    initial begin
        $readmemh(X_FILE, xrom);
        $readmemh(W_FILE, wrom);
        $readmemh(B_FILE, brom);
        $readmemh(E_FILE, erom);
        $readmemh(L_FILE, lrom);
    end

    wire [7:0]       x_addr;
    wire [12:0]      w_addr;
    wire [5:0]       b_addr;
    wire [BW-1:0]    x_data = xrom[{clip, x_addr}];
    wire [BW-1:0]    w_data = wrom[w_addr];
    wire [ACC_W-1:0] b_data = brom[b_addr];

    kws_accel #(.BW(BW), .ACC_W(ACC_W), .SHIFT(SHIFT)) u_core (
        .clk(clk), .rst_n(rst_n), .start(start),
        .x_addr(x_addr), .x_data(x_data),
        .w_addr(w_addr), .w_data(w_data),
        .b_addr(b_addr), .b_data(b_data),
        .busy(busy), .done(done), .class_out(class_out));

    assign expected = erom[clip][2:0];
    assign label    = lrom[clip][2:0];
endmodule
