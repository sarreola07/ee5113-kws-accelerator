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
// The expected "words correct" counts are computed from the .mem files, so the test
// still works after the model is retrained. Debounce is shortened to 4 clocks and
// every wait has a timeout.
//============================================================================
`timescale 1ns/1ps

module tb_fpga_top;
    reg clk = 1'b0, rstn = 1'b0, btnc = 1'b0, btnu = 1'b0, sw14 = 1'b0, sw15 = 1'b0;
    reg [7:0] sw = 8'd0;
    wire [15:0] led;
    wire led16_r, led16_g, led16_b;
    wire ca, cb, cc, cd, ce, cf, cg, dp;
    wire [7:0] an;

    always #5 clk = ~clk;                    // 100 MHz like the Nexys oscillator

    kws_fpga_top #(.DEBOUNCE(4), .USE_MMCM(0)) dut (
        .CLK100MHZ(clk), .CPU_RESETN(rstn), .BTNC(btnc), .BTNU(btnu),
        .SW(sw), .SW14(sw14), .SW15(sw15), .LED(led),
        .LED16_R(led16_r), .LED16_G(led16_g), .LED16_B(led16_b),
        .CA(ca), .CB(cb), .CC(cc), .CD(cd), .CE(ce), .CF(cf), .CG(cg), .DP(dp), .AN(an));

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
        input [8*48-1:0] what;
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

    // expected "words correct" counts, from the same .mem files the board uses
    reg [7:0] e8 [0:199], l8 [0:199], e4 [0:199], l4 [0:199];
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

        if (errors == 0) $display("*** FPGA TOP TEST PASSED ***");
        else             $display("*** FPGA TOP TEST FAILED (%0d errors) ***", errors);
        $finish;
    end
endmodule
