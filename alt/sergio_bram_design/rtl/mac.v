// Multiply-accumulate unit (the single MAC reused for every neuron).
//   load : acc <= load_val            (preload the neuron's bias)
//   en   : acc <= acc + a * b         (signed DATA_W x DATA_W -> ACC_W)
module mac #(
    parameter DATA_W = 8,
    parameter ACC_W  = 32
) (
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     load,
    input  wire signed [ACC_W-1:0]  load_val,
    input  wire                     en,
    input  wire signed [DATA_W-1:0] a,
    input  wire signed [DATA_W-1:0] b,
    output reg  signed [ACC_W-1:0]  acc
);
    wire signed [2*DATA_W-1:0] prod = a * b;

    always @(posedge clk) begin
        if (rst)       acc <= {ACC_W{1'b0}};
        else if (load) acc <= load_val;
        else if (en)   acc <= acc + {{(ACC_W-2*DATA_W){prod[2*DATA_W-1]}}, prod};
    end
endmodule
