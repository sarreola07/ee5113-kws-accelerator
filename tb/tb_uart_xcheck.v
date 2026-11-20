//============================================================================
// tb_uart_xcheck.v - run by sim/uart_xcheck.py (not by run_sim).
// Sends the packets that fpga/kws_live.py made (packets.mem, one byte per
// line, 254 bytes per packet) into the board design's UART_RX pin, and writes
// every 30-byte reply from UART_TX to replies.mem. The Python script then
// decodes the replies with kws_live.py and compares them with the Python
// integer model, so the PC side (kws_live.py) and the board side
// (kws_uart_link.v + kws_fpga_top.v) of the protocol are checked against
// each other. The UART runs at 8 clocks per bit to keep the run short.
//============================================================================
`timescale 1ns/1ps

module tb_uart_xcheck;
    localparam BIT = 8, PLEN = 254;          // clocks per UART bit, bytes per packet
    reg  clk = 1'b0, rstn = 1'b0, uart_rx = 1'b1;
    wire uart_tx, r, g, b, ca, cb, cc, cd, ce, cf, cg, dp;
    wire [15:0] led;
    wire [7:0]  an;

    always #5 clk = ~clk;

    kws_fpga_top #(.DEBOUNCE(4), .USE_MMCM(0), .UART_CLKS_PER_BIT(BIT), .UART_TIMEOUT(4000)) dut (
        .CLK100MHZ(clk), .CPU_RESETN(rstn), .BTNC(1'b0), .BTNU(1'b0),
        .SW(8'd0), .SW14(1'b0), .SW15(1'b0), .LED(led),
        .LED16_R(r), .LED16_G(g), .LED16_B(b),
        .CA(ca), .CB(cb), .CC(cc), .CD(cd), .CE(ce), .CF(cf), .CG(cg), .DP(dp), .AN(an),
        .UART_RX(uart_rx), .UART_TX(uart_tx));

    task send;                               // one byte, 8N1, LSB first
        input [7:0] x;
        integer q;
        begin
            uart_rx = 1'b0; repeat (BIT) @(posedge clk);
            for (q = 0; q < 8; q = q + 1) begin uart_rx = x[q]; repeat (BIT) @(posedge clk); end
            uart_rx = 1'b1; repeat (BIT) @(posedge clk);
        end
    endtask

    integer fin, fout, nbytes, npkt, k, j, n;
    reg [7:0] v;
    initial begin
        fin  = $fopen("packets.mem", "r");
        fout = $fopen("replies.mem", "w");
        if (fin == 0) begin $display("ERROR: packets.mem not found"); $finish; end
        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (20) @(posedge clk);
        nbytes = 0; npkt = 0;
        while ($fscanf(fin, "%h\n", v) == 1) begin
            send(v);
            nbytes = nbytes + 1;
            if (nbytes % PLEN == 0) begin    // a whole packet went out: read the reply
                for (k = 0; k < 30; k = k + 1) begin
                    n = 0;
                    while (uart_tx !== 1'b0 && n < 200000) begin @(posedge clk); n = n + 1; end
                    if (uart_tx !== 1'b0) begin
                        $display("ERROR: no reply to packet %0d (byte %0d)", npkt, k);
                        $fclose(fout); $finish;
                    end
                    repeat (BIT/2) @(posedge clk);                     // middle of the start bit
                    for (j = 0; j < 8; j = j + 1) begin repeat (BIT) @(posedge clk); v[j] = uart_tx; end
                    repeat (BIT) @(posedge clk);                       // stop bit
                    $fdisplay(fout, "%02x", v);
                end
                npkt = npkt + 1;
            end
        end
        $display("tb_uart_xcheck: %0d packets sent, %0d replies saved", npkt, npkt);
        $fclose(fin);
        $fclose(fout);
        $finish;
    end
endmodule
