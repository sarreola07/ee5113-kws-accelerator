//============================================================================
// uart.v - 8N1 UART receiver and transmitter for the board's USB-UART bridge.
// CLKS_PER_BIT = clock / baud: 50 MHz / 115200 -> 434. The testbench uses a
// small value so simulation is fast.
//============================================================================
`timescale 1ns/1ps

module uart_rx #(parameter CLKS_PER_BIT = 434) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,                    // idle high
    output reg  [7:0] data,
    output reg        valid                  // 1 cycle: data holds a new byte
);
    localparam S_IDLE = 2'd0, S_START = 2'd1, S_BITS = 2'd2, S_STOP = 2'd3;
    reg [1:0]  s_rx = 2'b11;                 // synchronizer
    reg [1:0]  state;
    reg [15:0] cnt;
    reg [2:0]  nbit;
    reg [7:0]  sh;
    wire       r = s_rx[1];

    always @(posedge clk) s_rx <= {s_rx[0], rx};

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; cnt <= 16'd0; nbit <= 3'd0; sh <= 8'd0; data <= 8'd0; valid <= 1'b0;
        end else begin
            valid <= 1'b0;
            case (state)
                S_IDLE: if (!r) begin cnt <= 16'd0; state <= S_START; end
                S_START: if (cnt == CLKS_PER_BIT/2 - 1) begin      // middle of the start bit
                    cnt   <= 16'd0;
                    nbit  <= 3'd0;
                    state <= r ? S_IDLE : S_BITS;                  // glitch: back to idle
                end else cnt <= cnt + 1'b1;
                S_BITS: if (cnt == CLKS_PER_BIT - 1) begin         // middle of a data bit
                    cnt <= 16'd0;
                    sh  <= {r, sh[7:1]};                           // LSB first
                    if (nbit == 3'd7) state <= S_STOP;
                    nbit <= nbit + 1'b1;
                end else cnt <= cnt + 1'b1;
                S_STOP: if (cnt == CLKS_PER_BIT - 1) begin         // middle of the stop bit
                    cnt   <= 16'd0;
                    state <= S_IDLE;
                    if (r) begin data <= sh; valid <= 1'b1; end    // framing error: byte dropped
                end else cnt <= cnt + 1'b1;
            endcase
        end
    end
endmodule


module uart_tx #(parameter CLKS_PER_BIT = 434) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       send,                  // 1 cycle, only while busy == 0
    output reg        tx,                    // idle high
    output wire       busy
);
    reg [3:0]  nbit;                         // 0 = idle, 1..10 = start, 8 data, stop
    reg [15:0] cnt;
    reg [9:0]  frame;                        // {stop, data, start}, sent LSB first
    assign busy = (nbit != 4'd0);

    always @(posedge clk) begin
        if (!rst_n) begin
            tx <= 1'b1; nbit <= 4'd0; cnt <= 16'd0; frame <= 10'h3FF;
        end else if (nbit == 4'd0) begin
            tx <= 1'b1;
            if (send) begin
                frame <= {1'b1, data, 1'b0};
                nbit  <= 4'd1;
                cnt   <= 16'd0;
            end
        end else begin
            tx <= frame[0];
            if (cnt == CLKS_PER_BIT - 1) begin
                cnt   <= 16'd0;
                frame <= {1'b1, frame[9:1]};
                nbit  <= (nbit == 4'd10) ? 4'd0 : nbit + 1'b1;
            end else cnt <= cnt + 1'b1;
        end
    end
endmodule
