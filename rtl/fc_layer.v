// Fully-connected layer engine with ONE time-shared MAC.
//
// For each output neuron o (0..n_out-1):
//     acc = bias[o];  for i in 0..n_in-1: acc += x[i] * w[o*n_in + i]
//     emit y_acc (raw accumulator) with y_we / y_addr = o
//
// n_in / n_out are run-time inputs so kws_top can reuse this same engine
// (and therefore the same MAC) for layer 1 and layer 2.
// All memories (x, w, b) are synchronous: data appears 1 cycle after addr.
module fc_layer #(
    parameter DATA_W = 8,
    parameter ACC_W  = 32,
    parameter XA_W   = 8,     // input (activation) address width
    parameter WA_W   = 13,    // weight address width
    parameter OA_W   = 5      // output-neuron address width
) (
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     start,
    input  wire [XA_W:0]            n_in,
    input  wire [OA_W:0]            n_out,
    output reg                      done,
    // memory read ports
    output reg  [XA_W-1:0]          x_addr,
    input  wire signed [DATA_W-1:0] x_data,
    output reg  [WA_W-1:0]          w_addr,
    input  wire signed [DATA_W-1:0] w_data,
    output reg  [OA_W-1:0]          b_addr,
    input  wire signed [ACC_W-1:0]  b_data,
    // result port
    output reg                      y_we,
    output reg  [OA_W-1:0]          y_addr,
    output wire signed [ACC_W-1:0]  y_acc
);
    localparam S_IDLE = 3'd0, S_BIAS = 3'd1, S_RUN = 3'd2,
               S_DRAIN = 3'd3, S_WRITE = 3'd4;
    reg [2:0]  state;
    reg [XA_W:0] i;
    reg        load_bias, mac_en;

    mac #(.DATA_W(DATA_W), .ACC_W(ACC_W)) u_mac (
        .clk(clk), .rst(rst),
        .load(load_bias), .load_val(b_data),
        .en(mac_en), .a(x_data), .b(w_data),
        .acc(y_acc)
    );

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; done <= 1'b0; y_we <= 1'b0;
            load_bias <= 1'b0; mac_en <= 1'b0;
            x_addr <= 0; w_addr <= 0; b_addr <= 0; y_addr <= 0; i <= 0;
        end else begin
            done      <= 1'b0;
            y_we      <= 1'b0;
            load_bias <= 1'b0;
            mac_en    <= 1'b0;
            case (state)
            S_IDLE: if (start) begin
                b_addr <= 0; w_addr <= 0; x_addr <= 0; i <= 0;
                state  <= S_BIAS;
            end
            S_BIAS: begin                 // b_addr presented; bias valid next cycle
                load_bias <= 1'b1;        // acc <= b_data in the next cycle
                state     <= S_RUN;
            end
            S_RUN: begin                  // x_addr/w_addr presented this cycle
                mac_en <= 1'b1;           // their data arrives next cycle
                if (i == n_in - 1) begin
                    state <= S_DRAIN;
                end else begin
                    i      <= i + 1'b1;
                    x_addr <= x_addr + 1'b1;
                    w_addr <= w_addr + 1'b1;
                end
            end
            S_DRAIN: state <= S_WRITE;    // last product is accumulated now
            S_WRITE: begin
                y_we   <= 1'b1;           // y_acc is final for neuron b_addr
                y_addr <= b_addr;
                if (b_addr == n_out - 1) begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end else begin
                    b_addr <= b_addr + 1'b1;
                    w_addr <= w_addr + 1'b1;   // next row starts right after
                    x_addr <= 0;
                    i      <= 0;
                    state  <= S_BIAS;
                end
            end
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
