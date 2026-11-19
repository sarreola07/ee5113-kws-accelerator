//============================================================================
// tb_fpga_top.v - checks the Nexys A7 demo the same way a person would use it:
//   1. select clip 2 with the switches, press BTNC  -> word "LEFt" (class 4, same as
//      Python; the true word of clip 2 is "yes", so this is a known wrong answer)
//   2. press BTNU with INT8 selected               -> 176 correct, 200 match Python
//   3. flip SW15 to INT4, press BTNU               -> 177 correct, 200 match Python
// The debounce time is shortened to 4 clocks so the simulation is fast.
//============================================================================
`timescale 1ns/1ps

module tb_fpga_top;
    reg clk = 1'b0, rstn = 1'b0, btnc = 1'b0, btnu = 1'b0, sw15 = 1'b0;
    reg [7:0] sw = 8'd0;
    wire [15:0] led;
    wire ca, cb, cc, cd, ce, cf, cg, dp;
    wire [7:0] an;

    always #5 clk = ~clk;                    // 100 MHz like the Nexys A7 oscillator

    kws_fpga_top #(.DEBOUNCE(4), .USE_MMCM(0)) dut (
        .CLK100MHZ(clk), .CPU_RESETN(rstn), .BTNC(btnc), .BTNU(btnu),
        .SW(sw), .SW15(sw15), .LED(led),
        .CA(ca), .CB(cb), .CC(cc), .CD(cd), .CE(ce), .CF(cf), .CG(cg), .DP(dp), .AN(an));

    // character code -> ASCII, to print what the 7-segment display shows
    function [7:0] chr;
        input [4:0] k;
        case (k)
            0,1,2,3,4,5,6,7,8,9: chr = "0" + k;
            11: chr = "-"; 12: chr = "Y"; 13: chr = "E"; 14: chr = "S"; 15: chr = "n";
            16: chr = "O"; 17: chr = "F"; 18: chr = "L"; 19: chr = "t"; 20: chr = "r";
            21: chr = "I"; 22: chr = "G"; 23: chr = "H";
            default: chr = " ";
        endcase
    endfunction

    task show_display;
        integer i;
        reg [8*8-1:0] s;
        begin
            for (i = 0; i < 8; i = i + 1)
                s[8*(7-i) +: 8] = chr(dut.text[5*(7-i) +: 5]);
            $display("    7-segment shows: [%s]", s);
        end
    endtask

    task press_and_wait;
        input which;                         // 0 = BTNC, 1 = BTNU
        begin
            if (which) btnu = 1'b1; else btnc = 1'b1;
            repeat (20) @(posedge clk);
            btnu = 1'b0; btnc = 1'b0;
            wait (led[14] == 1'b1);
            wait (led[14] == 1'b0);
            repeat (5) @(posedge clk);
        end
    endtask

    integer errors = 0;

    initial begin
        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (10) @(posedge clk);

        $display("== idle, clip 2, INT8 selected");
        sw = 8'd2; sw15 = 1'b0;
        repeat (10) @(posedge clk);
        show_display;

        $display("== BTNC: run clip 2 on INT8 (true word yes; the model, like Python, answers left)");
        press_and_wait(0);
        show_display;
        $display("    LED[2:0] class = %0d, LED[6:4] true word = %0d, LED12 correct = %b, LED13 matches Python = %b",
                 led[2:0], led[6:4], led[12], led[13]);
        if (led[2:0] !== 3'd4 || led[13] !== 1'b1) errors = errors + 1;

        $display("== BTNU: run all 200 clips on INT8");
        press_and_wait(1);
        show_display;
        $display("    correct = %0d (expect 176), match Python = %0d (expect 200), LED13 = %b",
                 dut.n_correct, dut.n_match, led[13]);
        if (dut.n_correct !== 8'd176 || dut.n_match !== 8'd200) errors = errors + 1;

        $display("== SW15 = 1, BTNU: run all 200 clips on INT4");
        sw15 = 1'b1;
        repeat (10) @(posedge clk);
        press_and_wait(1);
        show_display;
        $display("    correct = %0d (expect 177), match Python = %0d (expect 200), LED13 = %b",
                 dut.n_correct, dut.n_match, led[13]);
        if (dut.n_correct !== 8'd177 || dut.n_match !== 8'd200) errors = errors + 1;

        if (errors == 0) $display("*** FPGA TOP TEST PASSED ***");
        else             $display("*** FPGA TOP TEST FAILED (%0d errors) ***", errors);
        $finish;
    end
endmodule
