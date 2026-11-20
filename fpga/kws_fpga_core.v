//============================================================================
// kws_fpga_core.v - one precision of the KWS accelerator plus its memories,
// for the FPGA demo. The ASIC core (kws_accel.v) is used unchanged; the
// memories that sit outside the ASIC chip are ROMs here, loaded from mem/.
//
// The core reads memories in the same clock cycle (asynchronous read), so the
// ROMs are built from LUTs (distributed ROM), not block RAM.
// Clip c of the 200 test clips starts at address c*256, so the input address
// is just {clip, x_addr} (no adder needed).
//
// Self-check: every output score the core produces (dbg_out_wr / dbg_acc) is
// compared with the score Python computed for that clip (G_FILE). logits_ok
// stays 1 only if all 6 scores of the run were equal. K_FILE holds a magic
// word and checksums so the top can tell a missing .mem file from a real
// mismatch. 'fault' flips the lowest bit of every input of clip 0, so the
// board must report a FAIL at clip 0 (proves the checker is not stuck on PASS).
// use_ext / ext_x: the inputs come from the live-input RAM in the top instead
// (250 values sent by fpga/kws_live.py over the UART).
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
    parameter L_FILE = "int8_labels.mem",
    parameter G_FILE = "int8_logits8.mem",
    parameter K_FILE = "int8_check.mem"
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             start,      // 1-cycle pulse
    input  wire [7:0]       clip,       // test clip 0..199, held during an inference
    input  wire             fault,      // test switch: corrupt the inputs of clip 0
    input  wire             use_ext,    // 1 = read the inputs from ext_x (live audio from the PC)
    input  wire [BW-1:0]    ext_x,      // input value at address x_addr
    output wire [7:0]       x_addr,     // input index 0..249 the core is reading
    output wire             busy,
    output wire             done,       // 1-cycle pulse, class_out and logits_ok are valid
    output wire [2:0]       class_out,  // recognized word
    output wire [2:0]       expected,   // what the Python model says for this clip
    output wire [2:0]       label,      // the true word of this clip
    output wire             logits_ok,  // all 6 scores of the last run equal Python's
    output wire             score_wr,   // 1 cycle: output score score_idx is ready
    output wire [2:0]       score_idx,
    output wire [ACC_W-1:0] score_val,  // the score the hardware computed
    output wire [ACC_W-1:0] score_gold, // the score Python computed for this clip
    output wire [63:0]      check       // {magic, sum expected, sum labels, sum scores}
);
    (* rom_style = "distributed" *) reg [BW-1:0]    xrom [0:200*256-1];
    (* rom_style = "distributed" *) reg [BW-1:0]    wrom [0:8191];
    (* rom_style = "distributed" *) reg [ACC_W-1:0] brom [0:63];
    (* rom_style = "distributed" *) reg [ACC_W-1:0] grom [0:200*8-1];
    reg [7:0]  erom [0:199];
    reg [7:0]  lrom [0:199];
    reg [15:0] krom [0:3];

    initial begin
        $readmemh(X_FILE, xrom);
        $readmemh(W_FILE, wrom);
        $readmemh(B_FILE, brom);
        $readmemh(E_FILE, erom);
        $readmemh(L_FILE, lrom);
        $readmemh(G_FILE, grom);
        $readmemh(K_FILE, krom);
    end

    wire [12:0]      w_addr;
    wire [5:0]       b_addr;
    wire             flip   = fault && (clip == 8'd0);
    wire [BW-1:0]    x_data = use_ext ? ext_x : (xrom[{clip, x_addr}] ^ {{(BW-1){1'b0}}, flip});
    wire [BW-1:0]    w_data = wrom[w_addr];
    wire [ACC_W-1:0] b_data = brom[b_addr];

    wire             dbg_out_wr;
    wire [4:0]       dbg_out_idx;
    wire [ACC_W-1:0] dbg_acc;

    kws_accel #(.BW(BW), .ACC_W(ACC_W), .SHIFT(SHIFT)) u_core (
        .clk(clk), .rst_n(rst_n), .start(start),
        .x_addr(x_addr), .x_data(x_data),
        .w_addr(w_addr), .w_data(w_data),
        .b_addr(b_addr), .b_data(b_data),
        .busy(busy), .done(done), .class_out(class_out),
        .dbg_out_wr(dbg_out_wr), .dbg_out_idx(dbg_out_idx), .dbg_acc(dbg_acc));

    // compare every output score with Python's
    wire [ACC_W-1:0] gold = grom[{clip, dbg_out_idx[2:0]}];
    reg ok_r;
    always @(posedge clk) begin
        if (!rst_n)                           ok_r <= 1'b0;
        else if (start)                       ok_r <= 1'b1;
        else if (dbg_out_wr && dbg_acc != gold) ok_r <= 1'b0;
    end

    assign logits_ok  = ok_r;
    assign score_wr   = dbg_out_wr;
    assign score_idx  = dbg_out_idx[2:0];
    assign score_val  = dbg_acc;
    assign score_gold = gold;
    assign check      = {krom[0], krom[1], krom[2], krom[3]};
    assign expected   = erom[clip][2:0];
    assign label      = lrom[clip][2:0];
endmodule
