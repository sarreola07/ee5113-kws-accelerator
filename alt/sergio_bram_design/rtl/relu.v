// ReLU + requantization: y = clamp(acc >>> SHIFT, 0, 2^(DATA_W-1)-1)
// Matches kws_common.int_forward (arithmetic shift, then saturate).
module relu #(
    parameter DATA_W = 8,
    parameter ACC_W  = 32,
    parameter SHIFT  = 0
) (
    input  wire signed [ACC_W-1:0]  acc,
    output wire signed [DATA_W-1:0] y
);
    localparam signed [ACC_W-1:0] QMAX = (1 <<< (DATA_W-1)) - 1;
    wire signed [ACC_W-1:0] shifted = acc >>> SHIFT;

    assign y = shifted[ACC_W-1]  ? {DATA_W{1'b0}} :          // negative -> 0
               (shifted > QMAX)  ? QMAX[DATA_W-1:0] :         // saturate
                                   shifted[DATA_W-1:0];
endmodule
