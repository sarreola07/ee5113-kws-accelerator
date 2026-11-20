//============================================================================
// tb_fpga_top.v - checks the Nexys board demo the same way a person would use it:
//   0. power on        -> self-test: INT8 176/200 correct, INT4 177/200, all 400 same as
//                         Python; display "PASS", LED11 on, UART line "SELF-TEST PASS"
//   1. SW = 2          -> clip 2 runs by itself: "LEFt" (the true word is "yes"; Python
//                         makes the same mistake, so LED13 "same as Python" is on)
//   2. SW = 5          -> "YES", correct
//   3. SW14 up         -> all 200 clips on INT8: "176  200"
//   4. SW15 up         -> all 200 clips on INT4: "177  200"
//   5. SW14 down       -> clip 5 on INT4: "YES"
//   6. BTNC            -> clip 5 again (button path)
//   7. BTNU            -> all 200 clips on INT4 again (button path): "177  200"
// The debounce, settle, display-hold and UART bit times are shortened so the
// simulation is fast. The text the board sends on the UART is printed as "UART>".
//============================================================================
`timescale 1ns/1ps

module tb_fpga_top;
    localparam CPB = 4;                      // UART clocks per bit in this test

    reg clk = 1'b0, rstn = 1'b0, btnc = 1'b0, btnu = 1'b0, sw14 = 1'b0, sw15 = 1'b0;
    reg [7:0] sw = 8'd2;
    wire [15:0] led;
    wire ca, cb, cc, cd, ce, cf, cg, dp, uart;
    wire [7:0] an;

    always #5 clk = ~clk;                    // 100 MHz like the board oscillator

    kws_fpga_top #(.DEBOUNCE(4), .SETTLE(16), .HOLD(200), .CLKS_PER_BIT(CPB), .USE_MMCM(0)) dut (
        .CLK100MHZ(clk), .CPU_RESETN(rstn), .BTNC(btnc), .BTNU(btnu),
        .SW(sw), .SW14(sw14), .SW15(sw15), .LED(led),
        .CA(ca), .CB(cb), .CC(cc), .CD(cd), .CE(ce), .CF(cf), .CG(cg), .DP(dp), .AN(an),
        .UART_TXD(uart));

    integer errors = 0;

    //------------------------------------------------------------ 7-segment
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

    reg [8*8-1:0] disp;
    task show_display;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1)
                disp[8*(7-i) +: 8] = chr(dut.text[5*(7-i) +: 5]);
            $display("    7-segment shows: [%s]   LED[2:0]=%0d LED[6:4]=%0d LED11=%b LED12=%b LED13=%b LED15=%b",
                     disp, led[2:0], led[6:4], led[11], led[12], led[13], led[15]);
        end
    endtask

    task expect_display;
        input [8*8-1:0] want;
        begin
            show_display;
            if (disp !== want) begin
                $display("    ERROR: expected [%s]", want);
                errors = errors + 1;
            end
        end
    endtask

    //------------------------------------------------------------ UART receiver
    reg [7:0]      rx;
    reg [8*24-1:0] tail = 0;                 // last 24 characters received
    reg            at_line_start = 1'b1;
    integer        n_selfpass = 0, n_pass = 0, n_fail = 0, n_diff = 0, n_lines = 0;
    integer        b;
    always begin
        @(negedge uart);                     // start bit
        repeat (CPB / 2) @(posedge clk);
        for (b = 0; b < 8; b = b + 1) begin
            repeat (CPB) @(posedge clk);
            rx[b] = uart;
        end
        repeat (CPB) @(posedge clk);         // stop bit
        if (uart !== 1'b1) begin $display("    ERROR: UART stop bit"); errors = errors + 1; end
        tail = {tail[8*23-1:0], rx};
        if (rx == 8'h0A) begin
            $write("\n"); at_line_start = 1'b1; n_lines = n_lines + 1;
        end else if (rx != 8'h0D) begin
            if (at_line_start) $write("    UART> ");
            at_line_start = 1'b0;
            $write("%c", rx);
        end
        if (tail[8*14-1:0] == "SELF-TEST PASS")        n_selfpass = n_selfpass + 1;
        if (tail[8*7-1:0]  == "-> PASS")               n_pass     = n_pass + 1;
        if (tail[8*7-1:0]  == "-> FAIL")               n_fail     = n_fail + 1;
        if (tail[8*9-1:0]  == "DIFFERENT")             n_diff     = n_diff + 1;
    end

    //------------------------------------------------------------ helpers
    // after a switch change: wait until the automatic run is done and its UART line is out
    task wait_result;
        begin
            repeat (60) @(posedge clk);
            wait (dut.st == 3'd0 && dut.key_run == dut.key_now && dut.show != 2'd0 &&
                  dut.hold_cnt == 0 && !dut.msg_busy);
            repeat (CPB * 12) @(posedge clk);
        end
    endtask

    task press_and_wait;
        input which;                         // 0 = BTNC, 1 = BTNU
        begin
            if (which) btnu = 1'b1; else btnc = 1'b1;
            repeat (20) @(posedge clk);
            btnu = 1'b0; btnc = 1'b0;
            wait (led[14] == 1'b1);
            wait (led[14] == 1'b0 && !dut.msg_busy);
            repeat (CPB * 12) @(posedge clk);
        end
    endtask

    task check;
        input cond;
        input [8*40-1:0] what;
        begin
            if (!cond) begin $display("    ERROR: %0s", what); errors = errors + 1; end
        end
    endtask

    //------------------------------------------------------------ test
    initial begin
        repeat (5) @(posedge clk);
        rstn = 1'b1;

        $display("== 0. power on: self-test, all 200 clips on INT8 then INT4");
        wait (dut.self_done == 1'b1);
        repeat (2) @(posedge clk);
        expect_display("  PASS  ");
        $display("    INT8 %0d correct, %0d same as Python | INT4 %0d correct, %0d same as Python",
                 dut.self_c8, dut.self_m8, dut.self_c4, dut.self_m4);
        check(dut.self_c8 == 176 && dut.self_m8 == 200, "self-test INT8 counts");
        check(dut.self_c4 == 177 && dut.self_m4 == 200, "self-test INT4 counts");
        check(led[11] == 1'b1, "LED11 self-test passed");

        $display("== 1. SW = 2 (clip 2, INT8): runs by itself after the PASS display");
        wait_result;
        expect_display("  2 LEFt");
        check(led[2:0] == 3'd4 && led[6:4] == 3'd0 && led[12] == 1'b0 && led[13] == 1'b1, "clip 2 LEDs");

        $display("== 2. SW = 5 (clip 5, INT8)");
        sw = 8'd5;
        wait_result;
        expect_display("  5  YES");
        check(led[2:0] == 3'd0 && led[12] == 1'b1 && led[13] == 1'b1, "clip 5 LEDs");

        $display("== 3. SW14 up: all 200 clips on INT8");
        sw14 = 1'b1;
        wait_result;
        expect_display("176  200");
        check(led[13] == 1'b1, "LED13 all same as Python (INT8)");

        $display("== 4. SW15 up: all 200 clips on INT4");
        sw15 = 1'b1;
        wait_result;
        expect_display("177  200");
        check(led[13] == 1'b1 && led[15] == 1'b1, "LED13/LED15 (INT4)");

        $display("== 5. SW14 down: clip 5 on INT4");
        sw14 = 1'b0;
        wait_result;
        expect_display("  5  YES");

        $display("== 6. BTNC: clip 5 again");
        press_and_wait(0);
        expect_display("  5  YES");

        $display("== 7. BTNU: all 200 clips on INT4 again");
        press_and_wait(1);
        expect_display("177  200");

        $display("== UART: %0d lines, SELF-TEST PASS %0d (expect 1), -> PASS %0d (expect 5), -> FAIL %0d, DIFFERENT %0d",
                 n_lines, n_selfpass, n_pass, n_fail, n_diff);
        check(n_selfpass == 1 && n_pass == 5 && n_fail == 0 && n_diff == 0 && n_lines == 12, "UART report");

        if (errors == 0) $display("*** FPGA TOP TEST PASSED ***");
        else             $display("*** FPGA TOP TEST FAILED (%0d errors) ***", errors);
        $finish;
    end
endmodule
