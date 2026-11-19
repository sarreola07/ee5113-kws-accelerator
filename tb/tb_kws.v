//============================================================================
// tb_kws.v - Self-checking testbench for the KWS accelerator
// EE5113 Final Project
//
// Loads the files written by python/export_hw.py (in weights/int8 or weights/int4):
//   weights.mem, biases.mem        -> model memories (connected to the chip)
//   test_inputs.mem                -> 200 test clips (250 MFCC values each)
//   test_hidden.mem / test_logits  -> expected layer-1 / layer-2 values
//   test_expected.mem              -> class the Python integer model predicts
//   test_labels.mem                -> the true spoken word
// kws_params.vh decides the precision: weights/int8 or weights/int4, and the
// define KWS_TOP picks the matching chip top (kws_int8 or kws_int4).
//
// Every hidden value, every output score and every final class is compared
// with Python. The test passes only if all of them match bit for bit.
//============================================================================
`timescale 1ns/1ps
`include "kws_params.vh"

module tb_kws;
    localparam BW     = `KWS_BW;
    localparam ACC_W  = `KWS_ACC_W;
    localparam N_IN   = `KWS_N_IN;
    localparam N_HID  = `KWS_N_HID;
    localparam N_OUT  = `KWS_N_OUT;
    localparam N_TEST = `KWS_N_TEST;
    parameter  N_RUN  = N_TEST;          // number of test clips to run

    //---------------------------------------------------------------- clock
    reg clk = 1'b0, rst_n = 1'b0, start = 1'b0;
    always #5 clk = ~clk;                // 10 ns period = 100 MHz

    //------------------------------------------------------------- memories
    reg [BW-1:0]    wmem    [0:`KWS_N_WEIGHTS-1];
    reg [ACC_W-1:0] bmem    [0:`KWS_N_BIASES-1];
    reg [BW-1:0]    xmem    [0:N_TEST*N_IN-1];
    reg [7:0]       exp_cls [0:N_TEST-1];
    reg [7:0]       label   [0:N_TEST-1];
    reg [BW-1:0]    exp_h   [0:N_TEST*N_HID-1];
    reg [ACC_W-1:0] exp_o   [0:N_TEST*N_OUT-1];

    integer vec = 0;                     // current test clip

    wire [7:0]       x_addr;
    wire [12:0]      w_addr;
    wire [5:0]       b_addr;
    wire [BW-1:0]    x_data = xmem[vec*N_IN + x_addr];   // memories answer in
    wire [BW-1:0]    w_data = wmem[w_addr];              // the same cycle
    wire [ACC_W-1:0] b_data = bmem[b_addr];
    wire             busy, done;
    wire [2:0]       class_out;

    //------------------------------------------------- chip under test
    // KWS_TOP is kws_int8 or kws_int4 (set per simulation set in Vivado)
`ifndef KWS_TOP
  `define KWS_TOP kws_int8
`endif
    `KWS_TOP dut (.clk(clk), .rst_n(rst_n), .start(start),
                  .x_addr(x_addr), .x_data(x_data),
                  .w_addr(w_addr), .w_data(w_data),
                  .b_addr(b_addr), .b_data(b_data),
                  .busy(busy), .done(done), .class_out(class_out));

    initial if (dut.u_core.BW != BW) begin
        $display("ERROR: KWS_TOP is INT%0d but kws_params.vh is INT%0d", dut.u_core.BW, BW);
        $finish;
    end

    //------------------------------------------ readable names for waves
    reg [8*4-1:0] state_name;
    always @(dut.u_core.state)
        case (dut.u_core.state)
            3'd0: state_name = "IDLE";
            3'd1: state_name = "BIAS";
            3'd2: state_name = "MAC";
            3'd3: state_name = "POST";
            3'd4: state_name = "DONE";
            default: state_name = "????";
        endcase

    function [8*5-1:0] word;
        input [7:0] c;
        case (c)
            0: word = "yes";   1: word = "no";   2: word = "on";
            3: word = "off";   4: word = "left"; 5: word = "right";
            default: word = "?";
        endcase
    endfunction

    //--------------------------------- layer-by-layer bit-exact checking
    integer n_hid_err = 0, n_out_err = 0, n_cls_err = 0, n_correct = 0;
    integer n_hid_chk = 0, n_out_chk = 0;

    always @(posedge clk) if (vec < N_RUN) begin
        if (dut.u_core.hid_wr) begin
            n_hid_chk = n_hid_chk + 1;
            if (dut.u_core.h_new !== exp_h[vec*N_HID + dut.u_core.neu_cnt]) begin
                n_hid_err = n_hid_err + 1;
                if (n_hid_err <= 10)
                    $display("  HIDDEN MISMATCH clip %0d neuron %0d: hw=%0d python=%0d", vec,
                             dut.u_core.neu_cnt, dut.u_core.h_new,
                             exp_h[vec*N_HID + dut.u_core.neu_cnt]);
            end
        end
        if (dut.u_core.out_wr) begin
            n_out_chk = n_out_chk + 1;
            if (dut.u_core.acc !== exp_o[vec*N_OUT + dut.u_core.neu_cnt]) begin
                n_out_err = n_out_err + 1;
                if (n_out_err <= 10)
                    $display("  SCORE MISMATCH clip %0d class %0d: hw=%0d python=%0d", vec,
                             dut.u_core.neu_cnt, dut.u_core.acc,
                             $signed(exp_o[vec*N_OUT + dut.u_core.neu_cnt]));
            end
        end
    end

    //------------------------------------------------------------ stimulus
    integer t_start, cycles;
    real    acc_pct;

    initial begin
        $readmemh("weights.mem",       wmem);
        $readmemh("biases.mem",        bmem);
        $readmemh("test_inputs.mem",   xmem);
        $readmemh("test_expected.mem", exp_cls);
        $readmemh("test_labels.mem",   label);
        $readmemh("test_hidden.mem",   exp_h);
        $readmemh("test_logits.mem",   exp_o);

        $display("==================================================================");
        $display(" KWS accelerator testbench - INT%0d  (ACC_W=%0d, SHIFT=%0d)",
                 BW, ACC_W, `KWS_SHIFT);
        $display(" Network %0d -> %0d (ReLU) -> %0d -> argmax, %0d test clips",
                 N_IN, N_HID, N_OUT, N_RUN);
        $display("==================================================================");
        $display(" clip | true word | python | hardware | cycles");
        $display("------+-----------+--------+----------+-------");

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        for (vec = 0; vec < N_RUN; vec = vec + 1) begin
            @(negedge clk) start = 1'b1;
            t_start = $time;
            @(negedge clk) start = 1'b0;
            @(posedge done);
            @(negedge clk);
            cycles = ($time - t_start) / 10;

            if (class_out !== exp_cls[vec]) n_cls_err = n_cls_err + 1;
            if (class_out == label[vec])    n_correct = n_correct + 1;
            if (vec < 10 || class_out !== exp_cls[vec])
                $display(" %4d | %-9s | %-6s | %-8s | %0d %s", vec, word(label[vec]),
                         word(exp_cls[vec]), word(class_out), cycles,
                         (class_out !== exp_cls[vec]) ? "<-- MISMATCH" : "");
            else if (vec == 10)
                $display("  ...  (remaining clips are checked silently)");
        end

        acc_pct = 100.0 * n_correct / N_RUN;
        $display("==================================================================");
        $display(" Hidden activations checked : %0d, mismatches: %0d", n_hid_chk, n_hid_err);
        $display(" Output scores checked      : %0d, mismatches: %0d", n_out_chk, n_out_err);
        $display(" Final classes checked      : %0d, mismatches: %0d", N_RUN, n_cls_err);
        $display(" Cycles per inference       : %0d  (%.1f us at 100 MHz)", cycles, cycles * 0.01);
        $display(" Accuracy vs true labels    : %0d / %0d = %.2f %%", n_correct, N_RUN, acc_pct);
        if (n_hid_err == 0 && n_out_err == 0 && n_cls_err == 0)
            $display(" *** TEST PASSED: INT%0d hardware matches the Python model bit for bit ***", BW);
        else
            $display(" *** TEST FAILED ***");
        $display("==================================================================");
        $finish;
    end
endmodule
