// Streaming argmax: feed one logit per cycle with `valid` (index 0 first).
// Strict '>' keeps the FIRST maximum, matching numpy.argmax.
module argmax #(
    parameter ACC_W = 32,
    parameter IDX_W = 3
) (
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    clear,      // start of a new clip
    input  wire                    valid,
    input  wire [IDX_W-1:0]        idx,
    input  wire signed [ACC_W-1:0] val,
    output reg  [IDX_W-1:0]        best_idx,
    output reg  signed [ACC_W-1:0] best_val
);
    reg have;
    always @(posedge clk) begin
        if (rst || clear) begin
            have     <= 1'b0;
            best_idx <= {IDX_W{1'b0}};
            best_val <= {ACC_W{1'b0}};
        end else if (valid && (!have || val > best_val)) begin
            have     <= 1'b1;
            best_idx <= idx;
            best_val <= val;
        end
    end
endmodule
