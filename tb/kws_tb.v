// Self-checking testbench: runs every exported test clip through kws_top and
// compares the predicted class with golden.mem (the bit-exact Python model).
// Also reports accuracy against the true labels.
//
// Run with sim/run_sim.sh (it sets +incdir+weights/<prec> and the .mem paths).
`timescale 1ns/1ps
`include "kws_params.vh"

module kws_tb;
    localparam DATA_W = `KWS_DATA_W;
    localparam N_IN   = `KWS_N_IN;
    localparam N_OUT  = `KWS_N_OUT;
    localparam N_TEST = `KWS_N_TEST;
    localparam XA_W   = $clog2(N_IN);
    localparam OA_W   = $clog2(N_OUT);

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;                 // 100 MHz

    reg                      load_we = 0;
    reg  [XA_W-1:0]          load_addr = 0;
    reg  signed [DATA_W-1:0] load_data = 0;
    reg                      start = 0;
    wire                     busy, done;
    wire [OA_W-1:0]          class_out;

    kws_top dut (.clk(clk), .rst(rst), .load_we(load_we), .load_addr(load_addr),
                 .load_data(load_data), .start(start), .busy(busy), .done(done),
                 .class_out(class_out));

    reg [DATA_W-1:0] test_x [0:N_TEST*N_IN-1];
    reg [7:0]        golden [0:N_TEST-1];
    reg [7:0]        label  [0:N_TEST-1];

    integer t, i, pass, correct, cycles, total_cycles;
    initial begin
        $readmemh("test_x.mem", test_x);
        $readmemh("golden.mem", golden);
        $readmemh("test_label.mem", label);
        pass = 0; correct = 0; total_cycles = 0;
        repeat (4) @(posedge clk);
        rst = 0;
        for (t = 0; t < N_TEST; t = t + 1) begin
            for (i = 0; i < N_IN; i = i + 1) begin
                @(negedge clk);
                load_we = 1; load_addr = i; load_data = test_x[t*N_IN + i];
            end
            @(negedge clk) load_we = 0; start = 1;
            @(negedge clk) start = 0;
            cycles = 1;
            while (!done) begin @(posedge clk); #1; cycles = cycles + 1; end
            total_cycles = total_cycles + cycles;
            if (class_out == golden[t]) pass = pass + 1;
            else $display("MISMATCH clip %0d: hw=%0d golden=%0d", t, class_out, golden[t]);
            if (class_out == label[t]) correct = correct + 1;
        end
        $display("------------------------------------------------------------");
        $display("DATA_W=%0d  clips=%0d  match_golden=%0d/%0d  accuracy=%0d/%0d  cycles/clip=%0d",
                 DATA_W, N_TEST, pass, N_TEST, correct, N_TEST, total_cycles / N_TEST);
        if (pass == N_TEST) $display("TEST PASSED");
        else                $display("TEST FAILED");
        $display("------------------------------------------------------------");
        $finish;
    end

    initial begin
        if ($test$plusargs("vcd")) begin $dumpfile("kws_tb.vcd"); $dumpvars(0, kws_tb); end
    end
endmodule
