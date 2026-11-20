//============================================================================
// kws_uart_link.v - PC <-> board packets over the USB-UART (115200 8N1).
// Used by fpga/kws_live.py for live words from a microphone and for the
// --selftest that streams the 200 test clips through the UART.
//
// PC -> board
//   infer: A5 49 prec x0 .. x249 chk     prec 0 = INT8, 1 = INT4
//          x = the 250 quantized inputs, two's complement bytes (INT4: -7..7)
//          chk = (0x49 + prec + x0 + .. + x249) mod 256
//   ping : A5 50 50                      (the PC uses it to find the right port)
// board -> PC, always 30 bytes
//   5A status class s0 .. s5 cyc_lo cyc_hi chk
//   status 0 = result, 1 = bad packet (no run), 2 = pong
//   s0..s5 = the 6 output scores, 32-bit little-endian, sign-extended
//   cyc    = clock cycles of the inference
//   chk    = (sum of bytes 1..28) mod 256
// The input bytes go straight into the live-input RAM (ram_*); 'req' asks the
// controller to run them and stays high until 'ack'. A packet that stops in
// the middle is dropped after TIMEOUT clocks without a byte.
// One request at a time: the PC waits for the reply before it sends the next
// packet (fpga/kws_live.py does). Bytes that arrive while an inference is
// waiting to run are ignored. A reply that becomes ready while the previous
// one is still going out waits in a one-entry slot ('pend').
//============================================================================
`timescale 1ns/1ps

module kws_uart_link #(
    parameter CLKS_PER_BIT = 434,
    parameter TIMEOUT      = 2_000_000       // 40 ms at 50 MHz
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rx,
    output wire        tx,
    // live-input RAM write port
    output reg         ram_we,
    output reg  [7:0]  ram_addr,
    output reg  [7:0]  ram_data,
    // inference request / result
    output reg         req,                  // level: please run the live input
    output reg         req_prec,             // 0 = INT8, 1 = INT4
    input  wire        ack,                  // 1 cycle: request taken
    input  wire        res_valid,            // 1 cycle: result below is new
    input  wire [2:0]  res_class,
    input  wire [191:0] res_scores,          // {s5, .., s0}, 32 bits each
    input  wire [15:0] res_cycles
);
    wire [7:0] rx_data;
    wire       rx_valid, tx_busy;
    reg  [7:0] tx_data;
    reg        tx_send;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (.clk(clk), .rst_n(rst_n), .rx(rx),
        .data(rx_data), .valid(rx_valid));
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (.clk(clk), .rst_n(rst_n), .data(tx_data),
        .send(tx_send), .tx(tx), .busy(tx_busy));

    //---------------------------------------------------------------- receive
    localparam R_SYNC = 3'd0, R_CMD = 3'd1, R_PREC = 3'd2, R_DATA = 3'd3, R_CHK = 3'd4,
               R_PCHK = 3'd5, R_WAIT = 3'd6;
    reg [2:0]  rs;
    reg [7:0]  sum, n;
    reg [21:0] idle;                         // clocks since the last byte

    // reply waiting for the transmitter: 0 = none, 1 = result, 2 = bad packet, 3 = pong
    reg [1:0]  pend;
    reg        sending;                      // a reply is going out
    wire       take = (pend != 2'd0) && !sending;   // the transmitter takes 'pend' this cycle

    always @(posedge clk) begin
        if (!rst_n) begin
            rs <= R_SYNC; sum <= 8'd0; n <= 8'd0; idle <= 22'd0;
            ram_we <= 1'b0; ram_addr <= 8'd0; ram_data <= 8'd0;
            req <= 1'b0; req_prec <= 1'b0; pend <= 2'd0;
        end else begin
            ram_we <= 1'b0;
            if (take) pend <= 2'd0;          // a new reply set below in the same cycle wins
            if (ack) req <= 1'b0;
            if (rx_valid) idle <= 22'd0;
            else if (idle != 22'h3FFFFF) idle <= idle + 1'b1;

            if (rs != R_SYNC && rs != R_WAIT && idle >= TIMEOUT)
                rs <= R_SYNC;                // half a packet: drop it
            else if (rs == R_WAIT) begin     // waiting for the inference result
                if (res_valid) begin pend <= 2'd1; rs <= R_SYNC; end
            end else if (rx_valid) case (rs)
                R_SYNC: if (rx_data == 8'hA5) rs <= R_CMD;
                R_CMD:  begin
                    sum <= rx_data;
                    if      (rx_data == 8'h49) rs <= R_PREC;      // 'I' infer
                    else if (rx_data == 8'h50) rs <= R_PCHK;      // 'P' ping
                    else                       rs <= R_SYNC;
                end
                R_PREC: begin
                    sum      <= sum + rx_data;
                    req_prec <= rx_data[0];
                    n        <= 8'd0;
                    rs       <= R_DATA;
                end
                R_DATA: begin
                    sum      <= sum + rx_data;
                    ram_we   <= 1'b1;
                    ram_addr <= n;
                    ram_data <= rx_data;
                    n        <= n + 1'b1;
                    if (n == 8'd249) rs <= R_CHK;
                end
                R_CHK: if (rx_data == sum) begin
                    req <= 1'b1;
                    rs  <= R_WAIT;
                end else begin
                    pend <= 2'd2; rs <= R_SYNC;
                end
                R_PCHK: begin
                    pend <= (rx_data == 8'h50) ? 2'd3 : 2'd2;
                    rs   <= R_SYNC;
                end
                default: rs <= R_SYNC;
            endcase
        end
    end

    //---------------------------------------------------------------- transmit
    reg [2:0]   r_class;
    reg [191:0] r_scores;
    reg [15:0]  r_cycles;
    reg [7:0]   r_status;
    reg [4:0]   ti;                          // byte index 0..29
    reg [7:0]   csum;

    reg [7:0] byte_at;
    always @* begin
        case (ti)
            5'd0:  byte_at = 8'h5A;
            5'd1:  byte_at = r_status;
            5'd2:  byte_at = {5'd0, r_class};
            5'd27: byte_at = r_cycles[7:0];
            5'd28: byte_at = r_cycles[15:8];
            5'd29: byte_at = csum;
            default: byte_at = r_scores[(ti - 5'd3)*8 +: 8];   // ti 3..26
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            sending <= 1'b0; ti <= 5'd0; csum <= 8'd0; tx_send <= 1'b0; tx_data <= 8'd0;
            r_class <= 3'd0; r_scores <= 192'd0; r_cycles <= 16'd0; r_status <= 8'd0;
        end else begin
            tx_send <= 1'b0;
            if (take) begin
                sending  <= 1'b1;
                ti       <= 5'd0;
                csum     <= 8'd0;
                r_status <= (pend == 2'd1) ? 8'd0 : (pend == 2'd2) ? 8'd1 : 8'd2;
                r_class  <= (pend == 2'd1) ? res_class  : 3'd0;
                r_scores <= (pend == 2'd1) ? res_scores : 192'd0;
                r_cycles <= (pend == 2'd1) ? res_cycles : 16'd0;
            end else if (sending && !tx_busy && !tx_send) begin
                tx_data <= byte_at;
                tx_send <= 1'b1;
                if (ti >= 5'd1 && ti <= 5'd28) csum <= csum + byte_at;
                if (ti == 5'd29) sending <= 1'b0;
                else             ti <= ti + 1'b1;
            end
        end
    end
endmodule
