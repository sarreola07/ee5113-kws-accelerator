// Self-checking testbench: runs the exported test clips through kws_top and
// compares the predicted class with golden.mem (the bit-exact Python model).
// It also reports accuracy against the true labels.
//
// Run it with sim/run_sim.sh (RTL) or flow/run.sh gls (gate level). Options:
//   TB_CLK_NS (define)  clock period in ns, default 10. Use the synthesis period
//                       for gate-level and power runs.
//   +vcd [+vcd_clip=N]  dump ONLY the DUT, for exactly one inference: clip N
//                       (default 1). Clip 0 is a warm-up, so the window starts
//                       from realistic register contents. Runs clips 0..N only
//                       and prints a VCD_WINDOW line with the window's start and
//                       end times for power tools.
//   +waves              debug only: dump every signal of the whole run (large).
//   SDF (define)        annotate kws_top.sdf (gate-level timing simulation).
//
// Timing follows constraints.sdc: inputs change 0.2*T after the clock edge
// (set_input_delay) and outputs are sampled 0.8*T after it (T - set_output_delay).
`timescale 1ns/1ps
`include "kws_params.vh"
`ifndef TB_CLK_NS
`define TB_CLK_NS 10.0
`endif

module kws_tb;
    localparam DATA_W  = `KWS_DATA_W;
    localparam N_IN    = `KWS_N_IN;
    localparam N_OUT   = `KWS_N_OUT;
    localparam N_TEST  = `KWS_N_TEST;
    localparam XA_W    = $clog2(N_IN);
    localparam OA_W    = $clog2(N_OUT);
    localparam MAX_CYC = 100000;             // watchdog per clip (nominal 8,312)
    localparam real T_CLK = `TB_CLK_NS;
    localparam real T_IN  = 0.2 * T_CLK;     // drive inputs
    localparam real T_OUT = 0.8 * T_CLK;     // sample outputs

    reg clk = 0, rst = 1;
    always #(T_CLK / 2.0) clk = ~clk;

    reg                      load_we = 0;
    reg  [XA_W-1:0]          load_addr = 0;
    reg  signed [DATA_W-1:0] load_data = 0;
    reg                      start = 0;
    wire                     busy, done;
    wire [OA_W-1:0]          class_out;

    kws_top dut (.clk(clk), .rst(rst), .load_we(load_we), .load_addr(load_addr),
                 .load_data(load_data), .start(start), .busy(busy), .done(done),
                 .class_out(class_out));

`ifdef SDF
    initial $sdf_annotate("kws_top.sdf", dut, , "sdf_annotate.log", "MAXIMUM");
`endif

    reg [DATA_W-1:0] test_x [0:N_TEST*N_IN-1];
    reg [7:0]        golden [0:N_TEST-1];
    reg [7:0]        label  [0:N_TEST-1];

    integer t, i, pass, correct, cycles, total_cycles, n_run, vcd_clip, n_x;
    reg     vcd_mode;
    real    t_vcd0, t_vcd1;

    initial begin
        $readmemh("test_x.mem", test_x);
        $readmemh("golden.mem", golden);
        $readmemh("test_label.mem", label);
        vcd_mode = $test$plusargs("vcd");
        if (!$value$plusargs("vcd_clip=%d", vcd_clip)) vcd_clip = 1;
        if (vcd_clip > N_TEST - 1) vcd_clip = N_TEST - 1;
        if (vcd_clip < 0) vcd_clip = 0;
        n_run = vcd_mode ? vcd_clip + 1 : N_TEST;
        pass = 0; correct = 0; total_cycles = 0; n_x = 0;

        repeat (4) @(posedge clk);
        #(T_IN) rst = 0;                       // released between edges: no race

        for (t = 0; t < n_run; t = t + 1) begin
            for (i = 0; i < N_IN; i = i + 1) begin
                @(posedge clk);
                if (vcd_mode && t == vcd_clip && i == 0) begin
                    $dumpfile("kws_tb.vcd");
                    $dumpvars(0, dut);
                    t_vcd0 = $realtime;
                end
                #(T_IN);
                load_we = 1; load_addr = i; load_data = test_x[t*N_IN + i];
            end
            @(posedge clk); #(T_IN);
            load_we = 0; start = 1;
            @(posedge clk); #(T_IN);
            start = 0;
            cycles = 1;
            while (done !== 1'b1 && cycles <= MAX_CYC) begin   // an X 'done' must not end the wait
                @(posedge clk); #(T_OUT);
                cycles = cycles + 1;
            end
            if (cycles > MAX_CYC) begin
                $display("TIMEOUT: clip %0d never raised done", t);
                $display("TEST FAILED");
                $finish;
            end
            if (vcd_mode && t == vcd_clip) begin
                @(posedge clk);
                t_vcd1 = $realtime;
                $dumpflush;
                $display("VCD_WINDOW clip=%0d start_ns=%0.3f end_ns=%0.3f cycles=%0d period_ns=%0.3f",
                         t, t_vcd0, t_vcd1, $rtoi((t_vcd1 - t_vcd0) / T_CLK + 0.5), T_CLK);
            end
            total_cycles = total_cycles + cycles;
            if (^class_out === 1'bx) n_x = n_x + 1;
            if (class_out === golden[t]) pass = pass + 1;
            else $display("MISMATCH clip %0d: hw=%b golden=%0d", t, class_out, golden[t]);
            if (class_out === label[t]) correct = correct + 1;
        end

        $display("------------------------------------------------------------");
        $display("DATA_W=%0d  clips=%0d  match_golden=%0d/%0d  accuracy=%0d/%0d  cycles/clip=%0d",
                 DATA_W, n_run, pass, n_run, correct, n_run, total_cycles / n_run);
        if (n_x != 0) $display("X on class_out in %0d clips", n_x);
        if (pass == n_run && n_x == 0) $display("TEST PASSED");
        else                           $display("TEST FAILED");
        $display("------------------------------------------------------------");
        $finish;
    end

    initial begin                              // debug only; don't combine with +vcd
        if ($test$plusargs("waves")) begin
            $dumpfile("kws_tb_waves.vcd");
            $dumpvars(0, kws_tb);
        end
    end
endmodule
