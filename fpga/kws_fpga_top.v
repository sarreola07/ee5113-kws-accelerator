//============================================================================
// kws_fpga_top.v - Nexys 4 / Nexys 4 DDR / Nexys A7 (Artix-7) demo of the KWS accelerator
// EE5113 Final Project
//
// Both chips are on the FPGA (INT8 and INT4), each with its own ROMs holding
// the weights, the 200 test clips and Python's answers for them.
//
//   SW[7:0]    test clip number 0..199 (values above 199 are treated as 199)
//   SW15       0 = INT8 accelerator, 1 = INT4 accelerator
//   SW14       fault test: corrupts clip 0, so a run-all MUST end in FAIL at clip 0
//   BTNC       run the selected clip
//   BTNU       run all 200 clips and check every class AND every output score
//              against the Python integer model (bit exact)
//   CPU_RESETN reset
//   Clock: the 100 MHz board clock is divided to 50 MHz by an MMCM.
//
//   7-segment  idle:      clip number (left)   "Int8" / "Int4" (right)
//              BTNC:      clip number (left)   recognized word (right)
//              BTNU:      "PASS 176"  every clip matched Python; 176 words correct
//                                     (expect PASS 176 for INT8, PASS 177 for INT4)
//                         "F000 199"  FAIL: first clip that differs (000), clips that match (199)
//                         "Err ----"  the golden-data checksum is wrong: a .mem file is
//                                     missing or damaged, so no PASS/FAIL can be given
//   LED16 (RGB) green = PASS / matches Python, red = FAIL / Err / differs, blue = running
//   LED[2:0]   recognized word (0 yes, 1 no, 2 on, 3 off, 4 left, 5 right)
//   LED[6:4]   true word of the clip
//   LED11      fault test switch (SW14) is on
//   LED12      last answer is correct (same as the true word)
//   LED13      BTNC: answer and all 6 scores match Python. BTNU: PASS
//   LED14      busy
//   LED15      INT4 selected
//   Flipping SW15 clears a result, so INT8 counts are never read as INT4.
//============================================================================
`timescale 1ns/1ps

module kws_fpga_top #(
    parameter DEBOUNCE = 500_000,           // 10 ms at 50 MHz (small in simulation)
    parameter USE_MMCM = 1                  // 1 on the board; the testbench sets 0
)(
    input  wire        CLK100MHZ,
    input  wire        CPU_RESETN,
    input  wire        BTNC,
    input  wire        BTNU,
    input  wire [7:0]  SW,
    input  wire        SW14,
    input  wire        SW15,
    output wire [15:0] LED,
    output wire        LED16_R, LED16_G, LED16_B,
    output wire        CA, CB, CC, CD, CE, CF, CG, DP,
    output wire [7:0]  AN
);
    //------------------------------------------------------------ 50 MHz clock
    // The memory read + MAC path needs about 17 ns on the Artix-7, so the design
    // runs at 50 MHz (20 ns). The MMCM makes 50 MHz from the 100 MHz oscillator.
    wire clk, locked;
    generate
        if (USE_MMCM) begin : g_mmcm
            wire clk50, clkfb;
            MMCME2_BASE #(
                .CLKIN1_PERIOD(10.0),        // 100 MHz in
                .DIVCLK_DIVIDE(1),
                .CLKFBOUT_MULT_F(10.0),      // VCO = 1000 MHz
                .CLKOUT0_DIVIDE_F(20.0)      // 1000 / 20 = 50 MHz
            ) u_mmcm (
                .CLKIN1(CLK100MHZ), .CLKFBIN(clkfb), .CLKFBOUT(clkfb),
                .CLKOUT0(clk50), .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0),
                .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
                .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6());
            BUFG u_bufg (.I(clk50), .O(clk));
        end else begin : g_noclk
            assign clk    = CLK100MHZ;       // simulation: no MMCM model needed
            assign locked = 1'b1;
        end
    endgenerate

    //------------------------------------------------------------ reset sync
    reg [1:0] rst_sync = 2'b00;
    always @(posedge clk) rst_sync <= {rst_sync[0], CPU_RESETN & locked};
    wire rst_n = rst_sync[1];

    //------------------------------------------------------- buttons/switches
    wire run_one, run_all;
    debounce #(.N(DEBOUNCE)) u_db_c (.clk(clk), .btn(BTNC), .pulse(run_one));
    debounce #(.N(DEBOUNCE)) u_db_u (.clk(clk), .btn(BTNU), .pulse(run_all));

    reg [7:0] sw_s1, sw_s2;
    reg       p_s1, p_s2, f_s1, f_s2;
    always @(posedge clk) begin
        sw_s1 <= SW;   sw_s2 <= sw_s1;
        p_s1  <= SW15; p_s2  <= p_s1;
        f_s1  <= SW14; f_s2  <= f_s1;
    end
    wire [7:0] clip_sel = (sw_s2 > 8'd199) ? 8'd199 : sw_s2;

    //------------------------------------------------------- the two chips
    reg  [7:0] clip_r;
    reg        prec_r;                       // 0 = INT8, 1 = INT4
    reg        fault_r;                      // SW14 when the run started
    reg  [1:0] st;
    localparam C_IDLE = 2'd0, C_START = 2'd1, C_WAIT = 2'd2;

    wire        busy8, done8, busy4, done4, lok8, lok4, swr8, swr4;
    wire [2:0]  cls8, exp8, lab8, cls4, exp4, lab4;
    wire [22:0] sg8;
    wire [14:0] sg4;
    wire [63:0] chk8, chk4;

    kws_fpga_core #(.BW(8), .ACC_W(23), .SHIFT(9),
        .X_FILE("int8_inputs256.mem"), .W_FILE("int8_weights.mem"), .B_FILE("int8_biases.mem"),
        .E_FILE("int8_expected.mem"),  .L_FILE("int8_labels.mem"),
        .G_FILE("int8_logits8.mem"),   .K_FILE("int8_check.mem")) u_int8 (
        .clk(clk), .rst_n(rst_n), .start(st == C_START && !prec_r), .clip(clip_r), .fault(fault_r),
        .busy(busy8), .done(done8), .class_out(cls8), .expected(exp8), .label(lab8),
        .logits_ok(lok8), .score_wr(swr8), .score_gold(sg8), .check(chk8));

    kws_fpga_core #(.BW(4), .ACC_W(15), .SHIFT(5),
        .X_FILE("int4_inputs256.mem"), .W_FILE("int4_weights.mem"), .B_FILE("int4_biases.mem"),
        .E_FILE("int4_expected.mem"),  .L_FILE("int4_labels.mem"),
        .G_FILE("int4_logits8.mem"),   .K_FILE("int4_check.mem")) u_int4 (
        .clk(clk), .rst_n(rst_n), .start(st == C_START && prec_r), .clip(clip_r), .fault(fault_r),
        .busy(busy4), .done(done4), .class_out(cls4), .expected(exp4), .label(lab4),
        .logits_ok(lok4), .score_wr(swr4), .score_gold(sg4), .check(chk4));

    wire        done_s = prec_r ? done4 : done8;
    wire [2:0]  cls_s  = prec_r ? cls4  : cls8;
    wire [2:0]  exp_s  = prec_r ? exp4  : exp8;
    wire [2:0]  lab_s  = prec_r ? lab4  : lab8;
    wire        lok_s  = prec_r ? lok4  : lok8;
    wire        swr_s  = prec_r ? swr4  : swr8;
    wire [22:0] sg_s   = prec_r ? {8'd0, sg4} : sg8;
    wire [63:0] chk_s  = prec_r ? chk4  : chk8;
    wire        match_now = (cls_s == exp_s) && lok_s;   // class AND all 6 scores equal Python

    //------------------------------------------------------- controller
    reg        all_mode;
    reg [7:0]  n_correct, n_match;
    reg [2:0]  last_cls, last_lab;
    reg        last_ok, last_match;
    reg [1:0]  show;                         // 0 idle, 1 one clip, 2 all clips
    reg        ff_valid;                     // a failing clip was seen
    reg [7:0]  first_fail;
    reg [15:0] sum_exp, sum_lab, sum_sg;     // checksums of the golden data that was read

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= C_IDLE; show <= 2'd0; all_mode <= 1'b0; clip_r <= 8'd0; prec_r <= 1'b0;
            fault_r <= 1'b0; n_correct <= 8'd0; n_match <= 8'd0;
            last_cls <= 3'd0; last_lab <= 3'd0; last_ok <= 1'b0; last_match <= 1'b0;
            ff_valid <= 1'b0; first_fail <= 8'd0; sum_exp <= 16'd0; sum_lab <= 16'd0; sum_sg <= 16'd0;
        end else case (st)
            C_IDLE: begin
                if (show == 2'd0) clip_r <= clip_sel;   // idle display follows the switches
                if (run_one || run_all) begin
                    all_mode  <= run_all;
                    clip_r    <= run_all ? 8'd0 : clip_sel;
                    prec_r    <= p_s2;
                    fault_r   <= f_s2;
                    n_correct <= 8'd0;
                    n_match   <= 8'd0;
                    ff_valid  <= 1'b0;
                    first_fail <= 8'd0;
                    sum_exp   <= 16'd0;
                    sum_lab   <= 16'd0;
                    sum_sg    <= 16'd0;
                    st        <= C_START;
                end else if ((show == 2'd1 && (clip_sel != clip_r || p_s2 != prec_r)) ||
                             (show == 2'd2 && p_s2 != prec_r))
                    show <= 2'd0;                       // switches moved: back to idle view
            end
            C_START: st <= C_WAIT;                       // start pulse goes out in this state
            C_WAIT: begin
                if (swr_s) sum_sg <= sum_sg + sg_s[15:0];
                if (done_s) begin
                    last_cls   <= cls_s;
                    last_lab   <= lab_s;
                    last_ok    <= (cls_s == lab_s);
                    last_match <= match_now;
                    sum_exp    <= sum_exp + exp_s;
                    sum_lab    <= sum_lab + lab_s;
                    if (cls_s == lab_s) n_correct <= n_correct + 1'b1;
                    if (match_now) n_match <= n_match + 1'b1;
                    else if (!ff_valid) begin
                        ff_valid   <= 1'b1;
                        first_fail <= clip_r;
                    end
                    if (all_mode && clip_r != 8'd199) begin
                        clip_r <= clip_r + 1'b1;
                        st     <= C_START;
                    end else begin
                        show <= all_mode ? 2'd2 : 2'd1;
                        st   <= C_IDLE;
                    end
                end
            end
            default: st <= C_IDLE;
        endcase
    end

    // run-all verdict
    wire chk_ok   = (chk_s[63:48] == 16'h4B57) && (chk_s[47:32] == sum_exp) &&
                    (chk_s[31:16] == sum_lab)  && (chk_s[15:0]  == sum_sg);
    wire pass_all = chk_ok && (n_match == 8'd200);

    //------------------------------------------------------- LEDs
    wire busy_any = (st != C_IDLE);
    assign LED[2:0]   = last_cls;
    assign LED[3]     = 1'b0;
    assign LED[6:4]   = last_lab;
    assign LED[10:7]  = 4'd0;
    assign LED[11]    = f_s2;
    assign LED[12]    = (show != 2'd0) && last_ok;
    assign LED[13]    = (show == 2'd1) ? last_match : (show == 2'd2) && pass_all;
    assign LED[14]    = busy_any;
    assign LED[15]    = p_s2;

    // RGB LED16, dimmed to 1/16 because the RGB LEDs are very bright
    reg [3:0] pwm = 4'd0;
    always @(posedge clk) pwm <= pwm + 1'b1;
    wire dim      = (pwm == 4'd0);
    wire res_good = (show == 2'd2) ? pass_all : last_match;
    assign LED16_B = dim && busy_any;
    assign LED16_G = dim && !busy_any && (show != 2'd0) &&  res_good;
    assign LED16_R = dim && !busy_any && (show != 2'd0) && !res_good;

    //------------------------------------------------------- 7-segment text
    // character codes
    localparam [4:0] K_BL = 5'd10, K_DASH = 5'd11, K_Y = 5'd12, K_E = 5'd13, K_S = 5'd14,
                     K_N = 5'd15, K_O = 5'd16, K_F = 5'd17, K_L = 5'd18, K_T = 5'd19,
                     K_R = 5'd20, K_I = 5'd21, K_G = 5'd22, K_H = 5'd23, K_P = 5'd24,
                     K_A = 5'd25;

    // three decimal digits of an 8-bit number, leading zeros blank
    function [14:0] dec3;
        input [7:0] v;
        reg   [7:0] h, t, o;
        begin
            h = v / 8'd100;
            t = (v / 8'd10) % 8'd10;
            o = v % 8'd10;
            dec3 = {(h == 8'd0) ? K_BL : h[4:0],
                    (h == 8'd0 && t == 8'd0) ? K_BL : t[4:0],
                    o[4:0]};
        end
    endfunction

    // three decimal digits of an 8-bit number, with leading zeros (clip numbers)
    function [14:0] dec3z;
        input [7:0] v;
        reg   [7:0] h, t, o;
        begin
            h = v / 8'd100;
            t = (v / 8'd10) % 8'd10;
            o = v % 8'd10;
            dec3z = {h[4:0], t[4:0], o[4:0]};
        end
    endfunction

    // recognized word, right-aligned on 5 digits
    function [24:0] word5;
        input [2:0] k;
        case (k)
            3'd0: word5 = {K_BL, K_BL, K_Y,  K_E, K_S};   //   YES
            3'd1: word5 = {K_BL, K_BL, K_BL, K_N, K_O};   //    nO
            3'd2: word5 = {K_BL, K_BL, K_BL, K_O, K_N};   //    On
            3'd3: word5 = {K_BL, K_BL, K_O,  K_F, K_F};   //   OFF
            3'd4: word5 = {K_BL, K_L,  K_E,  K_F, K_T};   //  LEFt
            3'd5: word5 = {K_R,  K_I,  K_G,  K_H, K_T};   // rIGHt
            default: word5 = {5{K_DASH}};
        endcase
    endfunction

    reg [39:0] text;                         // 8 characters, digit 7 (left) first
    always @* begin
        case (show)
            2'd1:    text = {dec3(clip_r), word5(last_cls)};
            2'd2:    if (!chk_ok)
                         text = {K_E, K_R, K_R, K_BL, K_DASH, K_DASH, K_DASH, K_DASH};    // Err ----
                     else if (pass_all)
                         text = {K_P, K_A, K_S, K_S, K_BL, dec3(n_correct)};               // PASS 176
                     else
                         text = {K_F, dec3z(first_fail), K_BL, dec3(n_match)};             // F000 199
            default: text = {dec3(clip_sel), K_BL, K_I, K_N, K_T, p_s2 ? 5'd4 : 5'd8};
        endcase
    end

    sevenseg u_seg (.clk(clk), .text(text),
        .seg({CG, CF, CE, CD, CC, CB, CA}), .dp(DP), .an(AN));
endmodule


//============================================================================
// Button debouncer: 2-FF synchronizer, the input must be stable for N clocks,
// then one clock-wide pulse on the press.
//============================================================================
module debounce #(parameter N = 1_000_000) (
    input  wire clk,
    input  wire btn,
    output reg  pulse = 1'b0
);
    reg [1:0]  s = 2'b00;
    reg        stable = 1'b0;
    reg [31:0] cnt = 32'd0;
    always @(posedge clk) begin
        s     <= {s[0], btn};
        pulse <= 1'b0;
        if (s[1] == stable) cnt <= 32'd0;
        else if (cnt == N - 1) begin
            cnt    <= 32'd0;
            stable <= s[1];
            pulse  <= s[1];                  // pulse on press only
        end else cnt <= cnt + 1'b1;
    end
endmodule


//============================================================================
// 8-digit 7-segment driver (Nexys A7: segments and anodes are active low).
// text holds 8 character codes, digit 7 (left) in the top 5 bits.
//============================================================================
module sevenseg (
    input  wire        clk,
    input  wire [39:0] text,
    output reg  [6:0]  seg,                  // {g,f,e,d,c,b,a}, active low
    output wire        dp,
    output reg  [7:0]  an                    // active low
);
    reg [19:0] refresh = 20'd0;
    always @(posedge clk) refresh <= refresh + 1'b1;
    wire [2:0] d = refresh[18:16];           // about 1.3 ms per digit at 50 MHz

    wire [4:0] ch = text[d*5 +: 5];
    reg  [6:0] on;                           // {g,f,e,d,c,b,a}, 1 = segment on
    always @* begin
        case (ch)
            5'd0:  on = 7'b0111111;  5'd1:  on = 7'b0000110;  5'd2:  on = 7'b1011011;
            5'd3:  on = 7'b1001111;  5'd4:  on = 7'b1100110;  5'd5:  on = 7'b1101101;
            5'd6:  on = 7'b1111101;  5'd7:  on = 7'b0000111;  5'd8:  on = 7'b1111111;
            5'd9:  on = 7'b1101111;
            5'd11: on = 7'b1000000;  // -
            5'd12: on = 7'b1101110;  // Y
            5'd13: on = 7'b1111001;  // E
            5'd14: on = 7'b1101101;  // S
            5'd15: on = 7'b1010100;  // n
            5'd16: on = 7'b0111111;  // O
            5'd17: on = 7'b1110001;  // F
            5'd18: on = 7'b0111000;  // L
            5'd19: on = 7'b1111000;  // t
            5'd20: on = 7'b1010000;  // r
            5'd21: on = 7'b0110000;  // I
            5'd22: on = 7'b0111101;  // G
            5'd23: on = 7'b1110110;  // H
            5'd24: on = 7'b1110011;  // P
            5'd25: on = 7'b1110111;  // A
            default: on = 7'b0000000; // blank
        endcase
    end
    always @(posedge clk) begin
        seg <= ~on;
        an  <= ~(8'b1 << d);
    end
    assign dp = 1'b1;                        // decimal points off
endmodule
