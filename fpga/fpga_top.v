// Nexys 4 / Nexys 4 DDR (Artix-7 XC7A100T) board demo for the KWS accelerator.
//
//   SW[3:0]   select one of 16 test clips stored on-chip (fpga_clips_rom.v)
//   BTNC      run the accelerator on the selected clip
//   CPU_RESET reset (active low)
//   7-seg     leftmost digit = clip number (hex); right 4 digits = recognized word
//             YES / no / on / OFF / UP / dn
//   LED[5:0]  one-hot recognized word,  LED[11:8] = selected clip,
//   LED[14]   result valid,             LED[15]   busy
//
// The true word of each stored clip is listed in weights/<prec>/summary.json
// ("fpga_clip_labels") so you can check the board against it.
`include "kws_params.vh"

module fpga_top #(
    parameter DB_W = 20               // debounce counter bits (2^20 / 100 MHz ~ 10 ms)
) (
    input  wire        clk,          // 100 MHz
    input  wire        cpu_resetn,
    input  wire        btnc,
    input  wire [3:0]  sw,
    output wire [15:0] led,
    output reg  [6:0]  seg,          // seg[0]=CA(a) ... seg[6]=CG(g), active low
    output wire        dp,
    output reg  [7:0]  an            // active low
);
    localparam DATA_W = `KWS_DATA_W;
    localparam N_IN   = `KWS_N_IN;
    localparam N_OUT  = `KWS_N_OUT;
    localparam NCLIP  = `KWS_N_FPGA_CLIPS;
    localparam XA_W   = $clog2(N_IN);
    localparam OA_W   = $clog2(N_OUT);
    localparam CA_W   = $clog2(NCLIP*N_IN);

    // ---------------- reset synchronizer --------------------------------
    reg [2:0] rst_sync = 3'b111;
    always @(posedge clk) rst_sync <= {rst_sync[1:0], ~cpu_resetn};
    wire rst = rst_sync[2];

    // ---------------- button debounce + rising edge (~10 ms) -----------
    reg [DB_W-1:0] db_cnt = 0;
    reg [1:0]  btn_s = 0;
    reg        btn_db = 0, btn_db_q = 0;
    always @(posedge clk) begin
        btn_s <= {btn_s[0], btnc};
        if (btn_s[1] == btn_db) db_cnt <= 0;
        else if (&db_cnt) begin btn_db <= btn_s[1]; db_cnt <= 0; end
        else db_cnt <= db_cnt + 1'b1;
        btn_db_q <= btn_db;
    end
    wire go = btn_db & ~btn_db_q;

    // ---------------- clip loader ----------------------------------------
    reg  [CA_W-1:0]          clip_addr;
    wire signed [DATA_W-1:0] clip_data;
    fpga_clips_rom u_clips (.clk(clk), .addr(clip_addr), .data(clip_data));

    localparam F_IDLE = 2'd0, F_LOAD = 2'd1, F_RUN = 2'd2;
    reg [1:0]       fstate;
    reg [XA_W:0]    cnt;
    reg [3:0]       clip_sel;
    reg             load_we, start, valid;
    reg [XA_W-1:0]  load_addr;
    reg signed [DATA_W-1:0] load_data;   // registered with load_we/load_addr
    wire            busy, done;
    wire [OA_W-1:0] class_out;
    reg  [OA_W-1:0] result;

    always @(posedge clk) begin
        if (rst) begin
            fstate <= F_IDLE; load_we <= 0; start <= 0; valid <= 0;
            cnt <= 0; clip_addr <= 0; clip_sel <= 0; result <= 0; load_addr <= 0; load_data <= 0;
        end else begin
            start   <= 1'b0;
            load_we <= 1'b0;
            case (fstate)
            F_IDLE: if (go && !busy) begin
                clip_sel  <= sw;
                clip_addr <= sw * N_IN;
                cnt       <= 0;
                valid     <= 1'b0;
                fstate    <= F_LOAD;
            end
            F_LOAD: begin                         // ROM data is 1 cycle behind addr
                if (cnt != 0) begin
                    load_we   <= 1'b1;
                    load_addr <= cnt - 1'b1;
                    load_data <= clip_data;      // = clip[cnt-1]
                end
                if (cnt == N_IN) begin
                    start  <= 1'b1;
                    fstate <= F_RUN;
                end else begin
                    cnt       <= cnt + 1'b1;
                    clip_addr <= clip_addr + 1'b1;
                end
            end
            F_RUN: if (done) begin
                result <= class_out;
                valid  <= 1'b1;
                fstate <= F_IDLE;
            end
            default: fstate <= F_IDLE;
            endcase
        end
    end

    kws_top u_kws (.clk(clk), .rst(rst), .load_we(load_we), .load_addr(load_addr),
                   .load_data(load_data), .start(start), .busy(busy), .done(done),
                   .class_out(class_out));

    // ---------------- LEDs -----------------------------------------------
    wire [5:0] onehot = valid ? (6'b1 << result) : 6'b0;
    assign led = {busy || fstate != F_IDLE, valid, 2'b00, clip_sel, 2'b00, onehot};

    // ---------------- 7-segment display ---------------------------------
    // character codes, bits = {g,f,e,d,c,b,a}, 1 = segment on
    localparam [6:0] C_BL = 7'b0000000, C_Y = 7'b1101110, C_E = 7'b1111001,
                     C_S = 7'b1101101, C_n = 7'b1010100, C_o = 7'b1011100,
                     C_O = 7'b0111111, C_F = 7'b1110001, C_U = 7'b0111110,
                     C_P = 7'b1110011, C_d = 7'b1011110, C_DASH = 7'b1000000;

    // word = 4 characters, digit3..digit0.  Order must match WORDS in
    // python/kws_common.py: yes, no, on, off, up, down
    reg [27:0] word;
    always @(*) begin
        if (!valid) word = {C_DASH, C_DASH, C_DASH, C_DASH};
        else case (result)
            0: word = {C_BL, C_Y,  C_E, C_S};    // YES
            1: word = {C_BL, C_BL, C_n, C_o};    // no
            2: word = {C_BL, C_BL, C_o, C_n};    // on
            3: word = {C_BL, C_O,  C_F, C_F};    // OFF
            4: word = {C_BL, C_BL, C_U, C_P};    // UP
            5: word = {C_BL, C_BL, C_d, C_n};    // dn (down)
            default: word = {C_E, C_E, C_E, C_E};
        endcase
    end

    function [6:0] hex7(input [3:0] h);
        case (h)
            4'h0: hex7 = 7'b0111111; 4'h1: hex7 = 7'b0000110; 4'h2: hex7 = 7'b1011011;
            4'h3: hex7 = 7'b1001111; 4'h4: hex7 = 7'b1100110; 4'h5: hex7 = 7'b1101101;
            4'h6: hex7 = 7'b1111101; 4'h7: hex7 = 7'b0000111; 4'h8: hex7 = 7'b1111111;
            4'h9: hex7 = 7'b1101111; 4'hA: hex7 = 7'b1110111; 4'hB: hex7 = 7'b1111100;
            4'hC: hex7 = 7'b0111001; 4'hD: hex7 = 7'b1011110; 4'hE: hex7 = 7'b1111001;
            default: hex7 = 7'b1110001;
        endcase
    endfunction

    reg [19:0] refresh = 0;
    always @(posedge clk) refresh <= refresh + 1'b1;
    wire [2:0] digit = refresh[19:17];          // ~1.3 ms per digit
    always @(*) begin
        an = ~(8'b1 << digit);
        case (digit)
            3'd0: seg = ~word[6:0];
            3'd1: seg = ~word[13:7];
            3'd2: seg = ~word[20:14];
            3'd3: seg = ~word[27:21];
            3'd7: seg = ~hex7(sw);
            default: begin seg = 7'h7F; an = 8'hFF; end
        endcase
    end
    assign dp = 1'b1;
endmodule
