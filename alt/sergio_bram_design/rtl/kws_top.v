// Keyword-spotting accelerator top level.
//
//   1. Host writes one clip (N_IN quantized MFCC features) through load_*.
//   2. Pulse `start`.  Layer 1 (N_IN -> N_HID, ReLU+requant) runs, then
//      layer 2 (N_HID -> N_OUT) runs on the SAME fc_layer engine / MAC.
//   3. `done` pulses; `class_out` holds the recognized word index.
//
// Sizes / bit width / shift come from kws_params.vh, generated per precision
// by python/quantize_export.py into weights/<int8|int4>/ (add that directory
// to the include path: +incdir+weights/int8, -include_dirs, init_hdl_search_path).
`include "kws_params.vh"

module kws_top #(
    parameter DATA_W = `KWS_DATA_W,
    parameter ACC_W  = `KWS_ACC_W,
    parameter N_IN   = `KWS_N_IN,
    parameter N_HID  = `KWS_N_HID,
    parameter N_OUT  = `KWS_N_OUT,
    parameter SHIFT1 = `KWS_SHIFT1,
    parameter XA_W   = $clog2(N_IN),
    parameter HA_W   = $clog2(N_HID),
    parameter OA_W   = $clog2(N_OUT),
    parameter W1A_W  = $clog2(N_IN*N_HID),
    parameter W2A_W  = $clog2(N_HID*N_OUT)
) (
    input  wire                     clk,
    input  wire                     rst,
    // clip loading
    input  wire                     load_we,
    input  wire [XA_W-1:0]          load_addr,
    input  wire signed [DATA_W-1:0] load_data,
    // control / result
    input  wire                     start,
    output wire                     busy,
    output reg                      done,
    output reg  [OA_W-1:0]          class_out
);
    // address widths of the shared engine = the larger of the two layers
    localparam EX_W = (XA_W  > HA_W)  ? XA_W  : HA_W;
    localparam EW_W = (W1A_W > W2A_W) ? W1A_W : W2A_W;
    localparam EO_W = (HA_W  > OA_W)  ? HA_W  : OA_W;
    localparam [EX_W:0] N_IN_C  = N_IN;
    localparam [EX_W:0] N_HID_X = N_HID;
    localparam [EO_W:0] N_HID_O = N_HID;
    localparam [EO_W:0] N_OUT_C = N_OUT;

    localparam T_IDLE = 2'd0, T_L1 = 2'd1, T_L2 = 2'd2, T_FIN = 2'd3;
    reg [1:0] state;
    reg       layer2;                          // 0 = layer 1, 1 = layer 2
    assign busy = (state != T_IDLE);

    // ---------------- buffers -------------------------------------------
    reg signed [DATA_W-1:0] in_buf  [0:N_IN-1];
    reg signed [DATA_W-1:0] hid_buf [0:N_HID-1];
    reg signed [DATA_W-1:0] in_q, hid_q;      // synchronous read registers

    // ---------------- engine wiring -------------------------------------
    wire [EX_W-1:0]          x_addr;
    wire [EW_W-1:0]          w_addr;
    wire [EO_W-1:0]          b_addr, y_addr;
    wire signed [ACC_W-1:0]  y_acc;
    wire                     y_we, eng_done;
    wire signed [DATA_W-1:0] w1_q, w2_q;
    wire signed [ACC_W-1:0]  b1_q, b2_q;
    wire signed [DATA_W-1:0] hid_new;
    reg                      eng_start;

    always @(posedge clk) begin
        if (load_we) in_buf[load_addr] <= load_data;
        in_q  <= in_buf[x_addr[XA_W-1:0]];
        hid_q <= hid_buf[x_addr[HA_W-1:0]];
        if (y_we && !layer2) hid_buf[y_addr[HA_W-1:0]] <= hid_new;
    end

    kws_w1_rom u_w1 (.clk(clk), .addr(w_addr[W1A_W-1:0]), .data(w1_q));
    kws_b1_rom u_b1 (.clk(clk), .addr(b_addr[HA_W-1:0]),  .data(b1_q));
    kws_w2_rom u_w2 (.clk(clk), .addr(w_addr[W2A_W-1:0]), .data(w2_q));
    kws_b2_rom u_b2 (.clk(clk), .addr(b_addr[OA_W-1:0]),  .data(b2_q));

    fc_layer #(.DATA_W(DATA_W), .ACC_W(ACC_W),
               .XA_W(EX_W), .WA_W(EW_W), .OA_W(EO_W)) u_fc (
        .clk(clk), .rst(rst), .start(eng_start),
        .n_in (layer2 ? N_HID_X : N_IN_C),
        .n_out(layer2 ? N_OUT_C : N_HID_O),
        .done(eng_done),
        .x_addr(x_addr), .x_data(layer2 ? hid_q : in_q),
        .w_addr(w_addr), .w_data(layer2 ? w2_q  : w1_q),
        .b_addr(b_addr), .b_data(layer2 ? b2_q  : b1_q),
        .y_we(y_we), .y_addr(y_addr), .y_acc(y_acc)
    );

    relu #(.DATA_W(DATA_W), .ACC_W(ACC_W), .SHIFT(SHIFT1)) u_relu (
        .acc(y_acc), .y(hid_new));

    wire [OA_W-1:0] best_idx;
    wire signed [ACC_W-1:0] best_val;
    argmax #(.ACC_W(ACC_W), .IDX_W(OA_W)) u_argmax (
        .clk(clk), .rst(rst), .clear(start && !busy),
        .valid(y_we && layer2), .idx(y_addr[OA_W-1:0]), .val(y_acc),
        .best_idx(best_idx), .best_val(best_val));

    // ---------------- sequencer -----------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state <= T_IDLE; layer2 <= 1'b0; eng_start <= 1'b0;
            done <= 1'b0; class_out <= {OA_W{1'b0}};
        end else begin
            eng_start <= 1'b0;
            done      <= 1'b0;
            case (state)
            T_IDLE: if (start) begin
                layer2 <= 1'b0; eng_start <= 1'b1; state <= T_L1;
            end
            T_L1: if (eng_done) begin
                layer2 <= 1'b1; eng_start <= 1'b1; state <= T_L2;
            end
            T_L2: if (eng_done) state <= T_FIN;   // last logit enters argmax now
            T_FIN: begin
                class_out <= best_idx; done <= 1'b1; state <= T_IDLE;
            end
            endcase
        end
    end
endmodule
