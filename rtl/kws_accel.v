//============================================================================
// kws_accel.v - Low-precision keyword-spotting (KWS) accelerator core
// EE5113 VLSI System Design - Final Project
//
// Network (trained and quantized in Python, python/):
//     250 MFCC inputs -> FC 250x32 -> ReLU -> requantize -> FC 32x6 -> argmax
//
// One multiply-accumulate (MAC) unit is reused for every product.
// The bit width BW is a parameter, so the same RTL builds the INT8 and the
// INT4 chip (see kws_top.v).
//
// Memories: the input features, weights and biases live in memories outside
// this core (an SRAM macro or off-chip memory; the class 180 nm library has no
// memory compiler). The core sends an address and reads the data back in the
// same clock cycle. The 32 hidden activations are kept on-chip in registers.
//
// Bit-exact with python/quant.py:
//   acc  = b[j] + sum_i W[j][i] * a[i]        (ACC_W-bit signed accumulator)
//   h[j] = min((max(acc,0) + 2^(SHIFT-1)) >> SHIFT, QMAX)       (layer 1 only)
//   class = index of the largest layer-2 acc  (strict '>', lowest index wins)
//
// Schedule: per neuron 1 BIAS cycle + N MAC cycles + 1 POST cycle.
//   Layer 1: 32 x (1 + 250 + 1) = 8064 cycles
//   Layer 2:  6 x (1 +  32 + 1) =  204 cycles
//   + START/DONE overhead       -> about 8270 cycles per inference
//============================================================================
`timescale 1ns/1ps

module kws_accel #(
    parameter BW      = 8,     // weight / activation bit width (8 or 4)
    parameter ACC_W   = 23,    // accumulator width (from kws_params.vh)
    parameter SHIFT   = 9,     // requantization right shift (must be >= 1)
    parameter N_IN    = 250,   // input features
    parameter N_HID   = 32,    // hidden neurons
    parameter N_OUT   = 6,     // output classes (words)
    parameter CLASS_W = 3,     // bits for a class index
    parameter XA_W    = 8,     // input-memory address width  (250 entries)
    parameter WA_W    = 13,    // weight-memory address width (8192 entries)
    parameter BA_W    = 6,     // bias-memory address width   (38 entries)
    parameter CNT_W   = 8,     // MAC counter width (counts to N_IN-1)
    parameter NEU_W   = 5      // neuron counter width (counts to N_HID-1)
)(
    input  wire                 clk,
    input  wire                 rst_n,      // asynchronous, active low
    input  wire                 start,      // 1-cycle pulse starts one inference
    // input-feature memory
    output wire [XA_W-1:0]      x_addr,
    input  wire [BW-1:0]        x_data,
    // weight memory: W1 row-major (j*N_IN+i), then W2 (W2_BASE + k*N_HID + j)
    output wire [WA_W-1:0]      w_addr,
    input  wire [BW-1:0]        w_data,
    // bias memory: b1[0..N_HID-1], then b2
    output wire [BA_W-1:0]      b_addr,
    input  wire [ACC_W-1:0]     b_data,
    // result
    output reg                  busy,       // high while an inference runs
    output reg                  done,       // 1-cycle pulse: class_out is new
    output reg  [CLASS_W-1:0]   class_out,  // 0=yes 1=no 2=on 3=off 4=left 5=right
    // observation ports (read-only copies of internal signals) for the FPGA
    // self-check; the ASIC tops in kws_top.v leave them unconnected
    output wire                 dbg_out_wr,  // 1 cycle: dbg_acc is output score dbg_out_idx
    output wire [NEU_W-1:0]     dbg_out_idx,
    output wire [ACC_W-1:0]     dbg_acc
);

    localparam [BW-1:0] QMAX = (1 << (BW - 1)) - 1;    // 127 (INT8) or 7 (INT4)

    // FSM states
    localparam [2:0] S_IDLE = 3'd0,
                     S_BIAS = 3'd1,   // load bias into accumulator
                     S_MAC  = 3'd2,   // one multiply-accumulate per cycle
                     S_POST = 3'd3,   // ReLU+requantize (layer 1) or argmax (layer 2)
                     S_DONE = 3'd4;

    reg  [2:0]              state;
    reg                     layer;      // 0 = hidden layer, 1 = output layer
    reg  [CNT_W-1:0]        in_cnt;     // input index inside the current neuron
    reg  [NEU_W-1:0]        neu_cnt;    // current neuron
    reg  [WA_W-1:0]         w_ptr;      // weights are read in address order
    reg  [BA_W-1:0]         b_ptr;      // biases are read in address order
    reg  signed [ACC_W-1:0] acc;
    reg  signed [ACC_W-1:0] best_val;   // argmax: largest score so far
    reg  [CLASS_W-1:0]      best_idx;
    reg  [BW-1:0]           hbuf [0:N_HID-1];  // hidden activations (on-chip)

    assign x_addr = in_cnt;
    assign w_addr = w_ptr;
    assign b_addr = b_ptr;

    //------------------------------------------------------------------ MAC
    // Layer 1 multiplies by the input feature, layer 2 by a hidden activation.
    wire signed [BW-1:0]    act  = layer ? hbuf[in_cnt[NEU_W-1:0]] : x_data;
    wire signed [2*BW-1:0]  prod = $signed(w_data) * act;
    wire signed [ACC_W-1:0] mac_sum = acc + prod;     // prod is sign-extended

    //------------------------------------------- ReLU + requantize (layer 1)
    localparam [ACC_W:0] ROUND = 1 << (SHIFT - 1);
    wire [ACC_W:0] relu    = acc[ACC_W-1] ? {(ACC_W+1){1'b0}} : {1'b0, acc};
    wire [ACC_W:0] rounded = (relu + ROUND) >> SHIFT;
    wire [BW-1:0]  h_new   = (rounded > QMAX) ? QMAX : rounded[BW-1:0];

    //------------------------------------------------------- loop control
    wire last_in  = layer ? (in_cnt  == N_HID - 1) : (in_cnt  == N_IN  - 1);
    wire last_neu = layer ? (neu_cnt == N_OUT - 1) : (neu_cnt == N_HID - 1);

    // Debug strobes (also used by the testbench to check each layer)
    wire hid_wr = (state == S_POST) && !layer;   // hidden value h_new is ready
    wire out_wr = (state == S_POST) &&  layer;   // output score acc is ready

    assign dbg_out_wr  = out_wr;
    assign dbg_out_idx = neu_cnt;
    assign dbg_acc     = acc;

    //------------------------------------------------------------- FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            layer     <= 1'b0;
            in_cnt    <= {CNT_W{1'b0}};
            neu_cnt   <= {NEU_W{1'b0}};
            w_ptr     <= {WA_W{1'b0}};
            b_ptr     <= {BA_W{1'b0}};
            acc       <= {ACC_W{1'b0}};
            best_val  <= {ACC_W{1'b0}};
            best_idx  <= {CLASS_W{1'b0}};
            busy      <= 1'b0;
            done      <= 1'b0;
            class_out <= {CLASS_W{1'b0}};
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: if (start) begin
                    busy    <= 1'b1;
                    layer   <= 1'b0;
                    neu_cnt <= {NEU_W{1'b0}};
                    w_ptr   <= {WA_W{1'b0}};
                    b_ptr   <= {BA_W{1'b0}};
                    state   <= S_BIAS;
                end

                S_BIAS: begin
                    acc    <= b_data;              // accumulator starts at the bias
                    in_cnt <= {CNT_W{1'b0}};
                    state  <= S_MAC;
                end

                S_MAC: begin
                    acc   <= mac_sum;
                    w_ptr <= w_ptr + 1'b1;
                    if (last_in) state  <= S_POST;
                    else         in_cnt <= in_cnt + 1'b1;
                end

                S_POST: begin
                    b_ptr <= b_ptr + 1'b1;
                    if (!layer) begin              // hidden neuron finished
                        if (last_neu) begin
                            layer   <= 1'b1;
                            neu_cnt <= {NEU_W{1'b0}};
                        end else
                            neu_cnt <= neu_cnt + 1'b1;
                        state <= S_BIAS;
                    end else begin                 // output neuron finished: argmax
                        if (neu_cnt == 0 || acc > best_val) begin
                            best_val <= acc;
                            best_idx <= neu_cnt[CLASS_W-1:0];
                        end
                        if (last_neu) state <= S_DONE;
                        else begin
                            neu_cnt <= neu_cnt + 1'b1;
                            state   <= S_BIAS;
                        end
                    end
                end

                S_DONE: begin
                    class_out <= best_idx;
                    done      <= 1'b1;
                    busy      <= 1'b0;
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // Hidden-activation buffer (no reset needed: always written before read)
    always @(posedge clk) begin
        if (hid_wr)
            hbuf[neu_cnt] <= h_new;
    end

endmodule
