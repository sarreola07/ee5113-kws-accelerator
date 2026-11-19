//============================================================================
// kws_fpga_top.v - Nexys 4 / Nexys 4 DDR / Nexys A7 (Artix-7) demo of the KWS accelerator
// EE5113 Final Project
//
// Both chips are on the FPGA (INT8 and INT4), each with its own ROMs holding
// the weights and the 200 test clips from Python.
//
//   SW[7:0]    test clip number 0..199 (values above 199 are treated as 199)
//   SW15       0 = INT8 accelerator, 1 = INT4 accelerator
//   BTNC       run the selected clip
//   BTNU       run all 200 clips and count the results
//   CPU_RESETN reset
//   Clock: the 100 MHz board clock is divided to 50 MHz by an MMCM.
//
//   7-segment  idle:      clip number (left)   "Int8" / "Int4" (right)
//              BTNC:      clip number (left)   recognized word (right)
//              BTNU:      words correct (left) clips that match Python (right)
//                         -> expect 176 and 200 for INT8, 177 and 200 for INT4
//   LED[2:0]   recognized word (0 yes, 1 no, 2 on, 3 off, 4 left, 5 right)
//   LED[6:4]   true word of the clip
//   LED12      last answer is correct (same as the true word)
//   LED13      BTNC: answer matches Python. BTNU: all 200 matched Python
//   LED14      busy
//   LED15      INT4 selected
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
    input  wire        SW15,
    output wire [15:0] LED,
    output wire        CA, CB, CC, CD, CE, CF, CG, DP,
    output wire [7:0]  AN
);
    //------------------------------------------------------------ 50 MHz clock
    // The memory read + MAC path needs about 14 ns on the Artix-7, so the design
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
    reg       p_s1, p_s2;
    always @(posedge clk) begin
        sw_s1 <= SW;   sw_s2 <= sw_s1;
        p_s1  <= SW15; p_s2  <= p_s1;
    end
    wire [7:0] clip_sel = (sw_s2 > 8'd199) ? 8'd199 : sw_s2;

    //------------------------------------------------------- the two chips
    reg  [7:0] clip_r;
    reg        prec_r;                       // 0 = INT8, 1 = INT4
    reg  [1:0] st;
    localparam C_IDLE = 2'd0, C_START = 2'd1, C_WAIT = 2'd2;

    wire       busy8, done8, busy4, done4;
    wire [2:0] cls8, exp8, lab8, cls4, exp4, lab4;

    kws_fpga_core #(.BW(8), .ACC_W(23), .SHIFT(9),
        .X_FILE("int8_inputs256.mem"), .W_FILE("int8_weights.mem"), .B_FILE("int8_biases.mem"),
        .E_FILE("int8_expected.mem"),  .L_FILE("int8_labels.mem")) u_int8 (
        .clk(clk), .rst_n(rst_n), .start(st == C_START && !prec_r), .clip(clip_r),
        .busy(busy8), .done(done8), .class_out(cls8), .expected(exp8), .label(lab8));

    kws_fpga_core #(.BW(4), .ACC_W(15), .SHIFT(5),
        .X_FILE("int4_inputs256.mem"), .W_FILE("int4_weights.mem"), .B_FILE("int4_biases.mem"),
        .E_FILE("int4_expected.mem"),  .L_FILE("int4_labels.mem")) u_int4 (
        .clk(clk), .rst_n(rst_n), .start(st == C_START && prec_r), .clip(clip_r),
        .busy(busy4), .done(done4), .class_out(cls4), .expected(exp4), .label(lab4));

    wire       done_s = prec_r ? done4 : done8;
    wire [2:0] cls_s  = prec_r ? cls4  : cls8;
    wire [2:0] exp_s  = prec_r ? exp4  : exp8;
    wire [2:0] lab_s  = prec_r ? lab4  : lab8;

    //------------------------------------------------------- controller
    reg       all_mode;
    reg [7:0] n_correct, n_match;
    reg [2:0] last_cls, last_lab;
    reg       last_ok, last_match;
    reg [1:0] show;                          // 0 idle, 1 one clip, 2 all clips

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= C_IDLE; show <= 2'd0; all_mode <= 1'b0; clip_r <= 8'd0; prec_r <= 1'b0;
            n_correct <= 8'd0; n_match <= 8'd0;
            last_cls <= 3'd0; last_lab <= 3'd0; last_ok <= 1'b0; last_match <= 1'b0;
        end else case (st)
            C_IDLE: begin
                if (show == 2'd0) clip_r <= clip_sel;   // idle display follows the switches
                if (run_one || run_all) begin
                    all_mode  <= run_all;
                    clip_r    <= run_all ? 8'd0 : clip_sel;
                    prec_r    <= p_s2;
                    n_correct <= 8'd0;
                    n_match   <= 8'd0;
                    st        <= C_START;
                end else if (show != 2'd0 && (clip_sel != clip_r || p_s2 != prec_r) && show == 2'd1)
                    show <= 2'd0;                       // switches moved: back to idle view
            end
            C_START: st <= C_WAIT;                       // start pulse goes out in this state
            C_WAIT: if (done_s) begin
                last_cls   <= cls_s;
                last_lab   <= lab_s;
                last_ok    <= (cls_s == lab_s);
                last_match <= (cls_s == exp_s);
                if (cls_s == lab_s) n_correct <= n_correct + 1'b1;
                if (cls_s == exp_s) n_match   <= n_match + 1'b1;
                if (all_mode && clip_r != 8'd199) begin
                    clip_r <= clip_r + 1'b1;
                    st     <= C_START;
                end else begin
                    show <= all_mode ? 2'd2 : 2'd1;
                    st   <= C_IDLE;
                end
            end
            default: st <= C_IDLE;
        endcase
    end

    //------------------------------------------------------- LEDs
    wire busy_any = (st != C_IDLE);
    assign LED[2:0]   = last_cls;
    assign LED[3]     = 1'b0;
    assign LED[6:4]   = last_lab;
    assign LED[11:7]  = 5'd0;
    assign LED[12]    = (show != 2'd0) && last_ok;
    assign LED[13]    = (show == 2'd1) ? last_match : (show == 2'd2) && (n_match == 8'd200);
    assign LED[14]    = busy_any;
    assign LED[15]    = p_s2;

    //------------------------------------------------------- 7-segment text
    // character codes
    localparam [4:0] K_BL = 5'd10, K_DASH = 5'd11, K_Y = 5'd12, K_E = 5'd13, K_S = 5'd14,
                     K_N = 5'd15, K_O = 5'd16, K_F = 5'd17, K_L = 5'd18, K_T = 5'd19,
                     K_R = 5'd20, K_I = 5'd21, K_G = 5'd22, K_H = 5'd23;

    // three decimal digits of an 8-bit number
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
            2'd2:    text = {dec3(n_correct), K_BL, K_BL, dec3(n_match)};
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
            default: on = 7'b0000000; // blank
        endcase
    end
    always @(posedge clk) begin
        seg <= ~on;
        an  <= ~(8'b1 << d);
    end
    assign dp = 1'b1;                        // decimal points off
endmodule
