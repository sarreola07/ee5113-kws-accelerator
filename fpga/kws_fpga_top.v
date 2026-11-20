//============================================================================
// kws_fpga_top.v - Nexys 4 / Nexys 4 DDR / Nexys A7 (Artix-7) demo of the KWS accelerator
// EE5113 Final Project
//
// Both chips are on the FPGA (INT8 and INT4), each with its own ROMs holding
// the weights and the 200 test clips from Python.
//
// Power-on self-test (also after CPU_RESET): all 200 clips on INT8, then on INT4.
//   The display shows "PASS" (or "FAIL") for 3 s and LED11 stays on if it passed.
//   PASS means all 400 answers are the same as the Python model.
//   With all switches down the display then shows " rEAdY  " and waits.
//
// Words from the PC microphone (no switches needed): fpga/mic_demo.py records a word,
//   makes its 250 INT8 and 250 INT4 inputs and sends them over the USB-UART (UART_RXD).
//   The FPGA runs both accelerators on it and shows the word, e.g. "  3  YES"
//   (3 = words heard since reset; the INT8 answer, or INT4 with SW15 up).
//   It answers with one text line, which mic_demo.py prints.
//
// Test clips with the switches only (no button needed):
//   SW[7:0]    test clip number 0..199 in binary (values above 199 are treated as 199)
//   SW14       0 = one clip: the selected clip runs by itself when the switches change
//              1 = all clips: runs all 200 clips and shows the totals
//   SW15       0 = INT8 accelerator, 1 = INT4 accelerator
//   BTNC       run the selected clip again,  BTNU  run all 200 clips again
//   CPU_RESETN reset (runs the self-test again)
//   Clock: the 100 MHz board clock is divided to 50 MHz by an MMCM.
//
//   7-segment  SW14 = 0:  clip number (left)    recognized word (right), e.g. "  5  YES"
//              SW14 = 1:  words correct (left)  answers same as Python (right)
//                         -> expect 176 and 200 for INT8, 177 and 200 for INT4
//              while the switches move: "  5 Int8" (or "ALL Int8"), then the answer
//   LED[2:0]   recognized word (0 yes, 1 no, 2 on, 3 off, 4 left, 5 right)   (microphone: INT8 word)
//   LED[6:4]   true word of the clip                                       (microphone: INT4 word)
//   LED10      the display shows a word from the PC microphone
//   LED11      power-on self-test passed
//   LED12      last answer is correct (same as the true word)
//   LED13      one clip: answer same as Python.  all clips: all 200 same as Python
//              microphone: INT8 and INT4 answers both the same as Python
//   LED14      busy
//   LED15      INT4 selected
//   UART_TXD   one text line per result on the USB-UART, 115200 baud 8N1
//              (open the board's COM port in PuTTY / Tera Term / the Vivado serial monitor)
//   UART_RXD   words from the PC (fpga/mic_demo.py), same port and baud rate
//============================================================================
`timescale 1ns/1ps

module kws_fpga_top #(
    parameter DEBOUNCE     = 500_000,       // buttons: 10 ms at 50 MHz
    parameter SETTLE       = 1_000_000,     // switches must stay still 20 ms before an auto-run
    parameter HOLD         = 150_000_000,   // PASS/FAIL stays on the display 3 s
    parameter CLKS_PER_BIT = 434,           // UART: 50 MHz / 434 = 115200 baud
    parameter RX_GAP       = 2_500_000,     // a 50 ms pause in the middle of a PC packet drops it
    parameter USE_MMCM     = 1              // 1 on the board; the testbench sets 0
)(
    input  wire        CLK100MHZ,
    input  wire        CPU_RESETN,
    input  wire        BTNC,
    input  wire        BTNU,
    input  wire [7:0]  SW,
    input  wire        SW14,
    input  wire        SW15,
    output wire [15:0] LED,
    output wire        CA, CB, CC, CD, CE, CF, CG, DP,
    output wire [7:0]  AN,
    output wire        UART_TXD,            // FPGA -> PC (Digilent calls this pin UART_RXD_OUT / RsTx)
    input  wire        UART_RXD             // PC -> FPGA (Digilent calls this pin UART_TXD_IN / RsRx)
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

    reg [7:0] sw_s1 = 8'd0, sw_s2 = 8'd0;
    reg       p_s1 = 1'b0, p_s2 = 1'b0, m_s1 = 1'b0, m_s2 = 1'b0;
    always @(posedge clk) begin
        sw_s1 <= SW;   sw_s2 <= sw_s1;
        p_s1  <= SW15; p_s2  <= p_s1;
        m_s1  <= SW14; m_s2  <= m_s1;
    end
    wire [7:0] clip_sel = (sw_s2 > 8'd199) ? 8'd199 : sw_s2;

    // The switch setting as one key {all clips, INT4, clip}. In all-clips mode the clip
    // number does not matter. A new key that stays still for SETTLE clocks starts a run.
    wire [9:0]  key_now = {m_s2, p_s2, m_s2 ? 8'd0 : clip_sel};
    reg  [9:0]  key_prev   = 10'd0;
    reg  [31:0] settle_cnt = 32'd0;
    wire        settled    = (settle_cnt == SETTLE);
    always @(posedge clk) begin
        key_prev <= key_now;
        if (key_now != key_prev) settle_cnt <= 32'd0;
        else if (!settled)       settle_cnt <= settle_cnt + 1'b1;
    end

    //------------------------------------------------------- words from the PC microphone
    // fpga/mic_demo.py sends one packet per word (504 bytes, 44 ms at 115200 baud):
    //   "K", Python INT8 class, Python INT4 class, 250 INT8 inputs, 250 INT4 inputs, checksum
    // checksum = sum of all bytes after "K" (mod 256). The Python classes are only used for
    // the "same as Python" check; the FPGA computes its own answer from the inputs.
    localparam [2:0] P_HEAD = 3'd0, P_E8 = 3'd1, P_E4 = 3'd2, P_X8 = 3'd3, P_X4 = 3'd4, P_SUM = 3'd5;
    wire        rx_valid;
    wire [7:0]  rx_byte;
    reg  [2:0]  p_sec = P_HEAD;              // part of the packet the next byte belongs to
    reg  [7:0]  p_idx = 8'd0;                // input number 0..249
    reg  [7:0]  p_sum = 8'd0;
    reg  [2:0]  rx_e8 = 3'd0, rx_e4 = 3'd0;  // what Python says for this word
    reg  [31:0] gap_cnt = 32'd0;             // clocks since the last byte
    reg  [7:0]  pkt_count = 8'd0;            // good packets received (the controller runs each one)
    reg  [7:0]  err_count = 8'd0;            // packets with a wrong checksum
    wire        wr8 = rx_valid && (p_sec == P_X8);
    wire        wr4 = rx_valid && (p_sec == P_X4);

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rx(UART_RXD), .valid(rx_valid), .data(rx_byte));

    always @(posedge clk) begin
        if (rx_valid)               gap_cnt <= 32'd0;
        else if (gap_cnt != RX_GAP) gap_cnt <= gap_cnt + 1'b1;
        if (!rst_n) begin
            p_sec <= P_HEAD; pkt_count <= 8'd0; err_count <= 8'd0;
        end else if (rx_valid) begin
            if (p_sec != P_SUM) p_sum <= p_sum + rx_byte;
            case (p_sec)
                P_HEAD: begin
                    p_sum <= 8'd0;
                    if (rx_byte == "K") p_sec <= P_E8;           // anything else: wait for "K"
                end
                P_E8: begin rx_e8 <= rx_byte[2:0]; p_sec <= P_E4; end
                P_E4: begin rx_e4 <= rx_byte[2:0]; p_sec <= P_X8; p_idx <= 8'd0; end
                P_X8: if (p_idx == 8'd249) begin p_idx <= 8'd0; p_sec <= P_X4; end
                      else p_idx <= p_idx + 1'b1;
                P_X4: if (p_idx == 8'd249) p_sec <= P_SUM;
                      else p_idx <= p_idx + 1'b1;
                default: begin                                    // P_SUM
                    p_sec <= P_HEAD;
                    if (rx_byte == p_sum) pkt_count <= pkt_count + 1'b1;
                    else                  err_count <= err_count + 1'b1;
                end
            endcase
        end else if (gap_cnt == RX_GAP)
            p_sec <= P_HEAD;                                      // packet stopped half-way: drop it
    end

    // the inputs of the last word, one memory per precision (LUT RAM, read in the same cycle)
    (* ram_style = "distributed" *) reg [7:0] live8 [0:255];
    (* ram_style = "distributed" *) reg [3:0] live4 [0:255];
    integer li;
    initial for (li = 0; li < 256; li = li + 1) begin live8[li] = 8'd0; live4[li] = 4'd0; end
    always @(posedge clk) begin
        if (wr8) live8[p_idx] <= rx_byte;
        if (wr4) live4[p_idx] <= rx_byte[3:0];
    end

    //------------------------------------------------------- the two chips
    reg  [7:0] clip_r;
    reg        prec_r;                       // 0 = INT8, 1 = INT4
    reg        live_mode;                    // 1 = the chips read the microphone word, not a test clip
    reg  [2:0] st;
    localparam C_IDLE = 3'd0, C_START = 3'd1, C_WAIT = 3'd2, C_REPORT = 3'd3, C_VERDICT = 3'd4;

    wire       busy8, done8, busy4, done4;
    wire [2:0] cls8, exp8, lab8, cls4, exp4, lab4;
    wire [7:0] xa8, xa4;                     // input address each chip reads
    wire [7:0] xl8 = live8[xa8];
    wire [3:0] xl4 = live4[xa4];

    kws_fpga_core #(.BW(8), .ACC_W(23), .SHIFT(9),
        .X_FILE("int8_inputs256.mem"), .W_FILE("int8_weights.mem"), .B_FILE("int8_biases.mem"),
        .E_FILE("int8_expected.mem"),  .L_FILE("int8_labels.mem")) u_int8 (
        .clk(clk), .rst_n(rst_n), .start(st == C_START && !prec_r), .clip(clip_r),
        .live(live_mode), .x_live(xl8), .x_addr(xa8),
        .busy(busy8), .done(done8), .class_out(cls8), .expected(exp8), .label(lab8));

    kws_fpga_core #(.BW(4), .ACC_W(15), .SHIFT(5),
        .X_FILE("int4_inputs256.mem"), .W_FILE("int4_weights.mem"), .B_FILE("int4_biases.mem"),
        .E_FILE("int4_expected.mem"),  .L_FILE("int4_labels.mem")) u_int4 (
        .clk(clk), .rst_n(rst_n), .start(st == C_START && prec_r), .clip(clip_r),
        .live(live_mode), .x_live(xl4), .x_addr(xa4),
        .busy(busy4), .done(done4), .class_out(cls4), .expected(exp4), .label(lab4));

    wire       done_s = prec_r ? done4 : done8;
    wire [2:0] cls_s  = prec_r ? cls4  : cls8;
    wire [2:0] exp_s  = prec_r ? exp4  : exp8;
    wire [2:0] lab_s  = prec_r ? lab4  : lab8;

    //------------------------------------------------------- controller
    localparam [2:0] R_ONE = 3'd0, R_ALL = 3'd1, R_SELF = 3'd2, R_HELLO = 3'd3,   // UART line kinds
                     R_MIC = 3'd4, R_ERR = 3'd5;
    localparam [2:0] S_SET = 3'd0, S_ONE = 3'd1, S_ALL = 3'd2, S_MIC = 3'd3,      // what the display shows
                     S_READY = 3'd4;

    reg  [1:0]  phase;                       // 0 self-test INT8, 1 self-test INT4, 2 normal use
    reg  [9:0]  key_run;                     // switch key of the last run
    reg         hello_sent;
    reg         all_mode;
    reg  [7:0]  n_correct, n_match;
    reg  [2:0]  last_cls, last_lab, last_exp;
    reg         last_ok, last_match;
    reg  [2:0]  show;                        // S_SET switches moving, S_ONE, S_ALL, S_MIC, S_READY
    reg  [7:0]  pkt_done, err_done;          // PC packets already handled
    reg  [7:0]  live_cnt;                    // microphone words since reset
    reg  [2:0]  live_c8, live_c4;            // FPGA answers for the last microphone word
    reg  [2:0]  live_e8, live_e4;            // Python answers for it
    reg  [7:0]  self_c8, self_m8, self_c4, self_m4;
    reg         self_done, self_pass;
    reg  [27:0] hold_cnt;
    reg         msg_go = 1'b0;               // start a UART text line of kind msg_kind
    reg  [2:0]  msg_kind = R_HELLO;
    wire        msg_busy;

    wire want_auto = (phase == 2'd2) && settled && (key_now != key_run);
    wire go_all    = run_all | (!run_one && m_s2);

    always @(posedge clk) begin
        msg_go <= 1'b0;
        if (!rst_n) begin
            st <= C_IDLE; phase <= 2'd0; show <= S_SET; all_mode <= 1'b0;
            clip_r <= 8'd0; prec_r <= 1'b0; live_mode <= 1'b0;
            pkt_done <= 8'd0; err_done <= 8'd0; live_cnt <= 8'd0;
            live_c8 <= 3'd0; live_c4 <= 3'd0; live_e8 <= 3'd0; live_e4 <= 3'd0;
            key_run <= 10'h3FF;                         // no such key: the current setting runs once
            hello_sent <= 1'b0;                         // after the self-test
            n_correct <= 8'd0; n_match <= 8'd0;
            last_cls <= 3'd0; last_lab <= 3'd0; last_exp <= 3'd0; last_ok <= 1'b0; last_match <= 1'b0;
            self_c8 <= 8'd0; self_m8 <= 8'd0; self_c4 <= 8'd0; self_m4 <= 8'd0;
            self_done <= 1'b0; self_pass <= 1'b0; hold_cnt <= 28'd0;
            msg_kind <= R_HELLO;
        end else begin
            if (hold_cnt != 28'd0) hold_cnt <= hold_cnt - 1'b1;
            case (st)
                C_IDLE: begin
                    if (!hello_sent) begin                         // first line on the UART
                        if (!msg_busy) begin
                            msg_kind <= R_HELLO; msg_go <= 1'b1; hello_sent <= 1'b1;
                        end
                    end else if (phase != 2'd2) begin              // self-test: all clips, INT8 then INT4
                        live_mode <= 1'b0;
                        all_mode  <= 1'b1;
                        clip_r    <= 8'd0;
                        prec_r    <= phase[0];
                        n_correct <= 8'd0;
                        n_match   <= 8'd0;
                        st        <= C_START;
                    end else if (err_count != err_done) begin       // bad packet from the PC: say so
                        if (!msg_busy) begin
                            msg_kind <= R_ERR; msg_go <= 1'b1; err_done <= err_count;
                        end
                    end else if (pkt_count != pkt_done) begin       // a word from the PC microphone
                        pkt_done  <= pkt_count;
                        live_mode <= 1'b1;
                        all_mode  <= 1'b0;
                        prec_r    <= 1'b0;                         // INT8 first, then INT4
                        live_e8   <= rx_e8;
                        live_e4   <= rx_e4;
                        live_cnt  <= live_cnt + 1'b1;
                        hold_cnt  <= 28'd0;                        // stop showing PASS
                        st        <= C_START;
                    end else if (run_one || run_all || want_auto) begin
                        live_mode <= 1'b0;
                        all_mode  <= go_all;
                        clip_r    <= go_all ? 8'd0 : clip_sel;
                        prec_r    <= p_s2;
                        key_run   <= key_now;
                        n_correct <= 8'd0;
                        n_match   <= 8'd0;
                        st        <= C_START;
                    end else if (key_now != key_run)
                        show <= S_SET;                             // switches moving: show the new setting
                end
                C_START: st <= C_WAIT;                             // start pulse goes out in this state
                C_WAIT: if (done_s && live_mode) begin            // microphone word: INT8, then INT4
                    if (!prec_r) begin
                        live_c8 <= cls8;
                        prec_r  <= 1'b1;
                        st      <= C_START;
                    end else begin
                        live_c4 <= cls4;
                        st      <= C_REPORT;
                    end
                end else if (done_s) begin
                    last_cls   <= cls_s;
                    last_lab   <= lab_s;
                    last_exp   <= exp_s;
                    last_ok    <= (cls_s == lab_s);
                    last_match <= (cls_s == exp_s);
                    if (cls_s == lab_s) n_correct <= n_correct + 1'b1;
                    if (cls_s == exp_s) n_match   <= n_match + 1'b1;
                    if (all_mode && clip_r != 8'd199) begin
                        clip_r <= clip_r + 1'b1;
                        st     <= C_START;
                    end else
                        st <= C_REPORT;
                end
                C_REPORT: if (!msg_busy) begin                     // one text line per result
                    msg_kind <= live_mode ? R_MIC : all_mode ? R_ALL : R_ONE;
                    msg_go   <= 1'b1;
                    if (phase == 2'd2) begin
                        show <= live_mode ? S_MIC : all_mode ? S_ALL : S_ONE;
                        st   <= C_IDLE;
                    end else if (phase == 2'd0) begin
                        self_c8 <= n_correct; self_m8 <= n_match;
                        phase   <= 2'd1;
                        st      <= C_IDLE;
                    end else begin
                        self_c4 <= n_correct; self_m4 <= n_match;
                        st      <= C_VERDICT;
                    end
                end
                C_VERDICT: if (!msg_busy) begin                    // self-test result line + PASS/FAIL
                    self_done <= 1'b1;
                    self_pass <= (self_m8 == 8'd200) && (self_m4 == 8'd200);
                    hold_cnt  <= HOLD;
                    msg_kind  <= R_SELF;
                    msg_go    <= 1'b1;
                    phase     <= 2'd2;
                    st        <= C_IDLE;
                    if (key_now == 10'd0) begin                    // all switches down: wait for the
                        key_run <= 10'd0;                          // microphone (or a switch), show rEAdY
                        show    <= S_READY;
                    end
                end
                default: st <= C_IDLE;
            endcase
        end
    end

    //------------------------------------------------------- LEDs
    wire busy_any  = (st != C_IDLE);
    wire mic_show  = (show == S_MIC);
    wire mic_match = (live_c8 == live_e8) && (live_c4 == live_e4);
    assign LED[2:0]   = mic_show ? live_c8 : last_cls;
    assign LED[3]     = 1'b0;
    assign LED[6:4]   = mic_show ? live_c4 : last_lab;
    assign LED[9:7]   = 3'd0;
    assign LED[10]    = mic_show;
    assign LED[11]    = self_done && self_pass;
    assign LED[12]    = (show == S_ONE || show == S_ALL) && last_ok;
    assign LED[13]    = (show == S_ONE) ? last_match :
                        (show == S_ALL) ? (n_match == 8'd200) : mic_show && mic_match;
    assign LED[14]    = busy_any;
    assign LED[15]    = p_s2;

    //------------------------------------------------------- 7-segment text
    // character codes
    localparam [4:0] K_BL = 5'd10, K_DASH = 5'd11, K_Y = 5'd12, K_E = 5'd13, K_S = 5'd14,
                     K_N = 5'd15, K_O = 5'd16, K_F = 5'd17, K_L = 5'd18, K_T = 5'd19,
                     K_R = 5'd20, K_I = 5'd21, K_G = 5'd22, K_H = 5'd23, K_P = 5'd24, K_A = 5'd25,
                     K_D = 5'd26;

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

    wire [4:0] p_ch = p_s2 ? 5'd4 : 5'd8;
    reg [39:0] text;                         // 8 characters, digit 7 (left) first
    always @* begin
        if (!self_done)
            text = {8{K_DASH}};                                              // "--------" self-test
        else if (hold_cnt != 28'd0)
            text = self_pass ? {K_BL, K_BL, K_P, K_A, K_S, K_S, K_BL, K_BL}   // "  PASS  "
                             : {K_BL, K_BL, K_F, K_A, K_I, K_L, K_BL, K_BL};  // "  FAIL  "
        else case (show)
            S_ONE:   text = {dec3(clip_r), word5(last_cls)};                  // "  5  YES"
            S_ALL:   text = {dec3(n_correct), K_BL, K_BL, dec3(n_match)};     // "176  200"
            S_MIC:   text = {dec3(live_cnt), word5(p_s2 ? live_c4 : live_c8)}; // "  3  YES"
            S_READY: text = {K_BL, K_R, K_E, K_A, K_D, K_Y, K_BL, K_BL};      // " rEAdY  "
            default: text = m_s2 ? {K_A, K_L, K_L, K_BL, K_I, K_N, K_T, p_ch} // "ALL Int8"
                                 : {dec3(clip_sel), K_BL, K_I, K_N, K_T, p_ch}; // "  5 Int8"
        endcase
    end

    sevenseg u_seg (.clk(clk), .text(text),
        .seg({CG, CF, CE, CD, CC, CB, CA}), .dp(DP), .an(AN));

    //------------------------------------------------------- UART text report
    // A line is built right-aligned in MSG_N bytes; the empty (zero) bytes in front are skipped.
    localparam MSG_N = 128;

    function [23:0] a3;                      // 8-bit number as 3 ASCII digits
        input [7:0] v;
        a3 = {8'd48 + v / 8'd100, 8'd48 + (v / 8'd10) % 8'd10, 8'd48 + v % 8'd10};
    endfunction

    function [39:0] aword;                   // word name, 5 characters
        input [2:0] k;
        case (k)
            3'd0: aword = "yes  ";  3'd1: aword = "no   ";  3'd2: aword = "on   ";
            3'd3: aword = "off  ";  3'd4: aword = "left ";  3'd5: aword = "right";
            default: aword = "?????";
        endcase
    endfunction

    wire [7:0] p_asc = prec_r ? "4" : "8";
    reg [8*MSG_N-1:0] line;
    always @* begin
        case (msg_kind)
            R_ONE:   line = {"INT", p_asc, " clip ", a3(clip_r), ": heard ", aword(last_cls),
                             " | true word ", aword(last_lab), " | Python ", aword(last_exp),
                             last_ok ? " | correct | " : " | WRONG   | ",
                             last_match ? "same as Python\015\n" : "DIFFERENT from Python\015\n"};
            R_ALL:   line = {"INT", p_asc, " all 200 clips: ", a3(n_correct), "/200 correct, ",
                             a3(n_match), "/200 same as Python",
                             (n_match == 8'd200) ? " -> PASS\015\n" : " -> FAIL\015\n"};
            R_SELF:  line = {self_pass ? "SELF-TEST PASS" : "SELF-TEST FAIL",
                             ": INT8 ", a3(self_c8), "/200 correct, ", a3(self_m8), "/200 same as Python;",
                             " INT4 ", a3(self_c4), "/200 correct, ", a3(self_m4), "/200 same as Python\015\n"};
            R_MIC:   line = {"MIC ", a3(live_cnt), ": INT8 heard ", aword(live_c8), " (Python ", aword(live_e8),
                             ") | INT4 heard ", aword(live_c4), " (Python ", aword(live_e4), ")",
                             mic_match ? " -> same as Python\015\n" : " -> DIFFERENT from Python\015\n"};
            R_ERR:   line = {"MIC packet checksum error, ignored\015\n"};
            default: line = {"\015\n=== EE5113 KWS accelerator: power-on self-test,",
                             " 200 clips on INT8 then INT4 ===\015\n"};
        endcase
    end

    reg  [8*MSG_N-1:0] msg_buf = {8*MSG_N{1'b0}};
    reg  [6:0]         msg_idx = 7'd0;
    reg                msg_active = 1'b0;
    reg                tx_go = 1'b0;
    reg  [7:0]         tx_byte = 8'd0;
    wire               tx_ready;
    assign msg_busy = msg_active | msg_go;

    always @(posedge clk) begin
        tx_go <= 1'b0;
        if (!rst_n)
            msg_active <= 1'b0;
        else if (msg_go) begin
            msg_buf    <= line;
            msg_idx    <= MSG_N - 1;
            msg_active <= 1'b1;
        end else if (msg_active && tx_ready && !tx_go) begin
            if (msg_buf[8*msg_idx +: 8] != 8'd0) begin
                tx_byte <= msg_buf[8*msg_idx +: 8];
                tx_go   <= 1'b1;
            end
            if (msg_idx == 7'd0) msg_active <= 1'b0;
            else                 msg_idx    <= msg_idx - 1'b1;
        end
    end

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .go(tx_go), .data(tx_byte), .ready(tx_ready), .tx(UART_TXD));
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
// UART transmitter, 8 data bits, no parity, 1 stop bit, LSB first.
//============================================================================
module uart_tx #(parameter CLKS_PER_BIT = 434) (
    input  wire       clk,
    input  wire       go,                    // 1-cycle pulse, only when ready
    input  wire [7:0] data,
    output wire       ready,
    output reg        tx = 1'b1
);
    reg [9:0]  sh    = 10'h3FF;              // {stop, data, start}, shifted out from bit 0
    reg [3:0]  nbits = 4'd0;                 // bits still to send
    reg [15:0] cnt   = 16'd0;
    assign ready = (nbits == 4'd0);
    always @(posedge clk) begin
        if (nbits == 4'd0) begin
            tx <= 1'b1;
            if (go) begin
                sh    <= {1'b1, data, 1'b0};
                nbits <= 4'd10;
                cnt   <= 16'd0;
            end
        end else begin
            tx <= sh[0];
            if (cnt == CLKS_PER_BIT - 1) begin
                cnt   <= 16'd0;
                sh    <= {1'b1, sh[9:1]};
                nbits <= nbits - 1'b1;
            end else
                cnt <= cnt + 1'b1;
        end
    end
endmodule


//============================================================================
// UART receiver, 8N1, LSB first. valid is a 1-cycle pulse with the byte in data.
// The line is sampled in the middle of each bit; a byte without its stop bit is dropped.
//============================================================================
module uart_rx #(parameter CLKS_PER_BIT = 434) (
    input  wire       clk,
    input  wire       rx,
    output reg        valid = 1'b0,
    output reg  [7:0] data  = 8'd0
);
    reg [1:0]  s    = 2'b11;                 // synchronizer (rx is idle high)
    reg        busy = 1'b0;
    reg [3:0]  bitn = 4'd0;                  // 0 start bit, 1..8 data bits, 9 stop bit
    reg [15:0] cnt  = 16'd0;
    reg [7:0]  sh   = 8'd0;
    wire [15:0] wait_clks = (bitn == 4'd0) ? CLKS_PER_BIT / 2 - 1 : CLKS_PER_BIT - 1;
    always @(posedge clk) begin
        s     <= {s[0], rx};
        valid <= 1'b0;
        if (!busy) begin
            if (!s[1]) begin                 // falling edge: a start bit begins
                busy <= 1'b1; bitn <= 4'd0; cnt <= 16'd0;
            end
        end else if (cnt != wait_clks)
            cnt <= cnt + 1'b1;
        else begin
            cnt <= 16'd0;
            if (bitn == 4'd0) begin          // middle of the start bit
                if (s[1]) busy <= 1'b0;      // only a glitch
                else      bitn <= 4'd1;
            end else if (bitn != 4'd9) begin // middle of a data bit
                sh   <= {s[1], sh[7:1]};
                bitn <= bitn + 1'b1;
            end else begin                   // middle of the stop bit
                busy <= 1'b0;
                if (s[1]) begin data <= sh; valid <= 1'b1; end
            end
        end
    end
endmodule


//============================================================================
// 8-digit 7-segment driver (Nexys 4 / A7: segments and anodes are active low).
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
            5'd26: on = 7'b1011110;  // d
            default: on = 7'b0000000; // blank
        endcase
    end
    always @(posedge clk) begin
        seg <= ~on;
        an  <= ~(8'b1 << d);
    end
    assign dp = 1'b1;                        // decimal points off
endmodule
