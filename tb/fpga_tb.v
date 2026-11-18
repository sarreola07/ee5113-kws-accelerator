// Board-level check of fpga/fpga_top.v: press BTNC for a few switch settings
// and compare the result with golden.mem.  Run: ./sim/run_sim.sh int8 fpga
`timescale 1ns/1ps
`include "kws_params.vh"
module fpga_tb;
    reg clk = 0, cpu_resetn = 0, btnc = 0;
    reg [3:0] sw = 0;
    wire [15:0] led; wire [6:0] seg; wire dp; wire [7:0] an;
    always #5 clk = ~clk;

    fpga_top #(.DB_W(4)) dut (.clk(clk), .cpu_resetn(cpu_resetn), .btnc(btnc), .sw(sw),
                              .led(led), .seg(seg), .dp(dp), .an(an));

    reg [7:0] golden [0:`KWS_N_TEST-1];
    integer k, errors = 0;
    initial begin
        $readmemh("golden.mem", golden);
        #100 cpu_resetn = 1;
        for (k = 0; k < 4; k = k + 1) begin
            sw = k * 5;                                  // clips 0, 5, 10, 15
            #200 btnc = 1; #400 btnc = 0;
            wait (led[15] == 1'b1);
            wait (led[15] == 1'b0 && led[14] == 1'b1);
            #20;
            if (led[5:0] !== (6'b1 << golden[sw])) begin
                errors = errors + 1;
                $display("clip %0d: FAIL leds=%b golden=%0d", sw, led[5:0], golden[sw]);
            end else
                $display("clip %0d: ok   word index %0d", sw, golden[sw]);
        end
        if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED");
        $finish;
    end
endmodule
