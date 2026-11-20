//============================================================================
// tb_fpga_top.v - checks the Nexys demo the same way a person uses it:
//   1. select clip 2, press BTNC (INT8)  -> word "LEFt" (class 4), the same as Python,
//      with all 6 output scores equal to Python's (the true word of clip 2 is "yes",
//      so this is a known wrong answer of the model, not of the hardware)
//   2. press BTNU (INT8)                 -> PASS: all 200 clips match Python bit exactly
//   3. SW15 up, press BTNU (INT4)        -> PASS
//   4. SW15 back down                    -> the INT4 result is cleared from the display
//   5. SW14 up (fault test), BTNU        -> FAIL at clip 0, 199 clips match
//   6. damaged checksum word, BTNU       -> Err (a missing .mem file can't give a false PASS)
//   7. UART (live words): send test clips the way fpga/kws_live.py does, for INT8 and
//      INT4; the reply must hold Python's class and all 6 scores, the display "LI <word>".
//      A bad checksum must not start a run, a ping must answer, a half-sent packet
//      must be dropped after the timeout, and a reply that is ready while another one
//      is still going out must wait and follow it (two pings back to back -> two pongs).
// The expected "words correct" counts are computed from the .mem files, so the test
// still works after the model is retrained. Debounce is shortened to 4 clocks and
// every wait has a timeout.
//============================================================================
`timescale 1ns/1ps

module tb_fpga_top;
    reg clk = 1'b0, rstn = 1'b0, btnc = 1'b0, btnu = 1'b0, sw14 = 1'b0, sw15 = 1'b0;
    reg uart_rx = 1'b1;                      // PC -> board (idle high)
    wire uart_tx;                            // board -> PC
    localparam BIT = 8;                      // clocks per UART bit in this test
    reg [7:0] sw = 8'd0;
    wire [15:0] led;
    wire led16_r, led16_g, led16_b;
    wire ca, cb, cc, cd, ce, cf, cg, dp;
    wire [7:0] an;

    always #5 clk = ~clk;                    // 100 MHz like the Nexys oscillator

    kws_fpga_top #(.DEBOUNCE(4), .USE_MMCM(0), .UART_CLKS_PER_BIT(BIT), .UART_TIMEOUT(4000)) dut (
        .CLK100MHZ(clk), .CPU_RESETN(rstn), .BTNC(btnc), .BTNU(btnu),
        .SW(sw), .SW14(sw14), .SW15(sw15), .LED(led),
        .LED16_R(led16_r), .LED16_G(led16_g), .LED16_B(led16_b),
        .CA(ca), .CB(cb), .CC(cc), .CD(cd), .CE(ce), .CF(cf), .CG(cg), .DP(dp), .AN(an),
        .UART_RX(uart_rx), .UART_TX(uart_tx));

    // character code -> ASCII, to print what the 7-segment display shows
    function [7:0] chr;
        input [4:0] k;
        case (k)
            0,1,2,3,4,5,6,7,8,9: chr = "0" + k;
            11: chr = "-"; 12: chr = "Y"; 13: chr = "E"; 14: chr = "S"; 15: chr = "n";
            16: chr = "O"; 17: chr = "F"; 18: chr = "L"; 19: chr = "t"; 20: chr = "r";
            21: chr = "I"; 22: chr = "G"; 23: chr = "H"; 24: chr = "P"; 25: chr = "A";
            default: chr = " ";
        endcase
    endfunction

    integer errors = 0;
    reg [8*8-1:0] shown, want;

    task read_display;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1)
                shown[8*(7-i) +: 8] = chr(dut.text[5*(7-i) +: 5]);
            $display("    7-segment shows: [%s]", shown);
        end
    endtask

    task expect_display;
        input [8*8-1:0] w;
        begin
            read_display;
            if (shown !== w) begin
                $display("    ERROR: expected [%s]", w);
                errors = errors + 1;
            end
        end
    endtask

    task check;
        input ok;
        input [8*64-1:0] what;
        begin
            if (ok !== 1'b1) begin
                $display("    ERROR: %0s", what);
                errors = errors + 1;
            end
        end
    endtask

    // press a button, wait for the run to start and to finish (with timeouts)
    task press_and_wait;
        input which;                         // 0 = BTNC, 1 = BTNU
        integer n;
        begin
            if (which) btnu = 1'b1; else btnc = 1'b1;
            repeat (20) @(posedge clk);
            btnu = 1'b0; btnc = 1'b0;
            n = 0;
            while (led[14] !== 1'b1 && n < 1000) begin @(posedge clk); n = n + 1; end
            if (led[14] !== 1'b1) begin
                $display("    ERROR: the run never started (LED14 stayed off)");
                $display("*** FPGA TOP TEST FAILED ***");
                $finish;
            end
            n = 0;
            while (led[14] !== 1'b0 && n < 3_000_000) begin @(posedge clk); n = n + 1; end
            if (led[14] !== 1'b0) begin
                $display("    ERROR: timeout, the run never finished");
                $display("*** FPGA TOP TEST FAILED ***");
                $finish;
            end
            repeat (5) @(posedge clk);
        end
    endtask


    reg [7:0] e8 [0:199], l8 [0:199], e4 [0:199], l4 [0:199];   // Python's class, true word

    //---------------------------------------------------------------- UART (PC side)
    localparam ACC8 = 23, ACC4 = 15;         // = KWS_ACC_W of weights/int8 and int4 (as in the top)
    reg [7:0]   x8 [0:200*256-1];           // the same inputs the board's ROMs hold
    reg [3:0]   x4 [0:200*256-1];
    reg [ACC8-1:0] g8 [0:200*8-1];          // Python's 6 scores per clip
    reg [ACC4-1:0] g4 [0:200*8-1];
    initial begin
        $readmemh("int8_inputs256.mem", x8); $readmemh("int4_inputs256.mem", x4);
        $readmemh("int8_logits8.mem", g8);   $readmemh("int4_logits8.mem", g4);
    end

    integer runs = 0;                        // count inference starts (LED14 rising)
    always @(posedge led[14]) runs = runs + 1;

    task uart_send;
        input [7:0] b;
        integer k;
        begin
            uart_rx = 1'b0; repeat (BIT) @(posedge clk);          // start bit
            for (k = 0; k < 8; k = k + 1) begin
                uart_rx = b[k]; repeat (BIT) @(posedge clk);       // LSB first
            end
            uart_rx = 1'b1; repeat (BIT) @(posedge clk);          // stop bit
        end
    endtask

    reg [7:0] rep_b [0:29];
    task uart_recv_reply;                    // 30 bytes from the board, with a timeout
        integer k, j, n;
        reg [7:0] b;
        begin
            for (k = 0; k < 30; k = k + 1) begin
                n = 0;
                while (uart_tx !== 1'b0 && n < 200000) begin @(posedge clk); n = n + 1; end
                if (uart_tx !== 1'b0) begin
                    $display("    ERROR: no reply from the board (byte %0d)", k);
                    $display("*** FPGA TOP TEST FAILED ***");
                    $finish;
                end
                repeat (BIT/2) @(posedge clk);                    // middle of the start bit
                for (j = 0; j < 8; j = j + 1) begin
                    repeat (BIT) @(posedge clk);
                    b[j] = uart_tx;
                end
                repeat (BIT) @(posedge clk);                      // stop bit
                if (uart_tx !== 1'b1) begin $display("    ERROR: framing error in the reply"); errors = errors + 1; end
                rep_b[k] = b;
            end
        end
    endtask

    // decode the reply; returns status (or 255 if the frame itself is bad)
    integer r_status, r_class, r_cycles;
    integer r_score [0:5];
    task decode_reply;
        integer k;
        reg [7:0] sum;
        begin
            sum = 8'd0;
            for (k = 1; k <= 28; k = k + 1) sum = sum + rep_b[k];
            if (rep_b[0] !== 8'h5A || rep_b[29] !== sum) begin
                $display("    ERROR: bad reply frame (first byte %h, checksum %h vs %h)", rep_b[0], rep_b[29], sum);
                errors = errors + 1;
                r_status = 255;
            end else r_status = rep_b[1];
            r_class  = rep_b[2];
            for (k = 0; k < 6; k = k + 1)
                r_score[k] = {rep_b[6+4*k], rep_b[5+4*k], rep_b[4+4*k], rep_b[3+4*k]};
            r_cycles = {rep_b[28], rep_b[27]};
        end
    endtask

    // send test clip c through the UART, like fpga/kws_live.py --selftest
    task live_clip;
        input       prec;                    // 0 = INT8, 1 = INT4
        input [7:0] c;
        input       corrupt;                 // 1 = wrong checksum
        integer k, sc;
        reg [7:0] v, chk;
        begin
            chk = 8'h49 + prec;
            uart_send(8'hA5); uart_send(8'h49); uart_send({7'd0, prec});
            for (k = 0; k < 250; k = k + 1) begin
                v = prec ? {{4{x4[c*256+k][3]}}, x4[c*256+k]} : x8[c*256+k];
                chk = chk + v;
                uart_send(v);
            end
            uart_send(corrupt ? chk + 8'd1 : chk);
            uart_recv_reply;
            decode_reply;
        end
    endtask

    task check_live;
        input       prec;
        input [7:0] c;
        integer k, want_s, bad_s;
        reg [2:0] want_c;
        begin
            live_clip(prec, c, 1'b0);
            want_c = prec ? e4[c] : e8[c];
            bad_s = 0;
            for (k = 0; k < 6; k = k + 1) begin
                want_s = prec ? {{(32-ACC4){g4[c*8+k][ACC4-1]}}, g4[c*8+k]}
                              : {{(32-ACC8){g8[c*8+k][ACC8-1]}}, g8[c*8+k]};
                if (r_score[k] !== want_s) bad_s = bad_s + 1;
            end
            repeat (5) @(posedge clk);
            read_display;
            $display("    INT%0d clip %0d: status %0d, class %0d (Python %0d), scores differing %0d, %0d cycles",
                     prec ? 4 : 8, c, r_status, r_class, want_c, bad_s, r_cycles);
            check(r_status == 0 && r_class == want_c && bad_s == 0, "live reply must equal Python");
            check(dut.show == 2'd3 && shown[8*8-1 -: 16] == "LI", "display should show LI + the word");
        end
    endtask

    // expected "words correct" counts, from the same .mem files the board uses
    integer i, want8, want4;
    initial begin
        $readmemh("int8_expected.mem", e8); $readmemh("int8_labels.mem", l8);
        $readmemh("int4_expected.mem", e4); $readmemh("int4_labels.mem", l4);
        want8 = 0; want4 = 0;
        for (i = 0; i < 200; i = i + 1) begin
            if (e8[i] == l8[i]) want8 = want8 + 1;
            if (e4[i] == l4[i]) want4 = want4 + 1;
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (10) @(posedge clk);

        $display("== idle, clip 2, INT8 selected");
        sw = 8'd2; sw15 = 1'b0;
        repeat (10) @(posedge clk);
        read_display;

        $display("== 1. BTNC: run clip 2 on INT8 (true word yes; the model, like Python, answers left)");
        press_and_wait(0);
        read_display;
        $display("    LED[2:0] class = %0d, LED[6:4] true word = %0d, LED12 correct = %b, LED13 matches Python = %b",
                 led[2:0], led[6:4], led[12], led[13]);
        check(led[2:0] === 3'd4, "clip 2 should give class 4 (left)");
        check(led[13] === 1'b1, "clip 2 should match Python (class and all 6 scores)");

        $display("== 2. BTNU: run all 200 clips on INT8");
        press_and_wait(1);
        $sformat(want, "PASS %3d", want8);
        expect_display(want);
        $display("    correct = %0d (expect %0d), match Python = %0d (expect 200), LED13 = %b",
                 dut.n_correct, want8, dut.n_match, led[13]);
        check(dut.n_correct == want8 && dut.n_match == 8'd200, "INT8 counts");
        check(dut.pass_all === 1'b1 && led[13] === 1'b1 && dut.res_good === 1'b1, "INT8 PASS / LED13 / green");

        $display("== 3. SW15 up, BTNU: run all 200 clips on INT4");
        sw15 = 1'b1;
        repeat (10) @(posedge clk);
        press_and_wait(1);
        $sformat(want, "PASS %3d", want4);
        expect_display(want);
        $display("    correct = %0d (expect %0d), match Python = %0d (expect 200)", dut.n_correct, want4, dut.n_match);
        check(dut.n_correct == want4 && dut.n_match == 8'd200 && dut.pass_all === 1'b1, "INT4 PASS");

        $display("== 4. SW15 back down: the INT4 result must disappear");
        sw15 = 1'b0;
        repeat (10) @(posedge clk);
        read_display;
        check(dut.show == 2'd0 && led[13] === 1'b0, "result should be cleared when SW15 moves");

        $display("== 5. SW14 up (fault test), BTNU on INT8: must FAIL at clip 0");
        sw14 = 1'b1;
        repeat (10) @(posedge clk);
        check(led[11] === 1'b1, "LED11 should show the fault switch");
        press_and_wait(1);
        expect_display("F000 199");
        check(dut.pass_all === 1'b0 && dut.chk_ok === 1'b1 && dut.first_fail == 8'd0 &&
              dut.n_match == 8'd199 && led[13] === 1'b0 && dut.res_good === 1'b0, "fault run should FAIL at clip 0");
        sw14 = 1'b0;

        $display("== 6. damaged golden-data checksum, BTNU on INT8: must show Err");
        dut.u_int8.krom[1] = dut.u_int8.krom[1] + 16'd1;
        press_and_wait(1);
        expect_display("Err ----");
        check(dut.chk_ok === 1'b0 && dut.pass_all === 1'b0 && led[13] === 1'b0, "bad checksum should give Err");
        dut.u_int8.krom[1] = dut.u_int8.krom[1] - 16'd1;


        $display("== 7. UART: live inputs from the PC (test clips sent like fpga/kws_live.py)");
        check_live(1'b0, 8'd2);
        check_live(1'b0, 8'd77);
        check_live(1'b1, 8'd2);
        check_live(1'b1, 8'd199);

        $display("== 7b. UART: a wrong checksum must be rejected without running");
        i = runs;
        live_clip(1'b0, 8'd5, 1'b1);
        $display("    status %0d (expect 1 = bad packet), runs started %0d (expect 0)", r_status, runs - i);
        check(r_status == 1 && runs == i, "bad checksum must give status 1 and no run");

        $display("== 7c. UART: ping");
        uart_send(8'hA5); uart_send(8'h50); uart_send(8'h50);
        uart_recv_reply; decode_reply;
        $display("    status %0d (expect 2 = pong)", r_status);
        check(r_status == 2, "ping must answer status 2");

        $display("== 7d. UART: a half-sent packet is dropped after the timeout");
        uart_send(8'hA5); uart_send(8'h49); uart_send(8'h00);
        for (i = 0; i < 10; i = i + 1) uart_send(8'h01);
        repeat (6000) @(posedge clk);                  // longer than UART_TIMEOUT
        check_live(1'b0, 8'd2);

        $display("== 7e. UART: two pings back to back; the second pong waits for the first");
        fork
            begin
                uart_send(8'hA5); uart_send(8'h50); uart_send(8'h50);
                uart_send(8'hA5); uart_send(8'h50); uart_send(8'h50);   // while pong 1 goes out
            end
            begin
                uart_recv_reply; decode_reply; i = r_status;
                uart_recv_reply; decode_reply;
            end
        join
        $display("    status %0d and %0d (expect 2 and 2)", i, r_status);
        check(i == 2 && r_status == 2, "both pings must get a pong");

        if (errors == 0) $display("*** FPGA TOP TEST PASSED ***");
        else             $display("*** FPGA TOP TEST FAILED (%0d errors) ***", errors);
        $finish;
    end
endmodule
