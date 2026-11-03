// =============================================================================
// cnn_top.v -- board-level wrapper.
// After reset: load init weights, then for ep = 0..EPOCHS:
//      evaluate (forward-only) on all 200 samples -> count correct
//      report over UART "E<ep> <count>\r\n" and on LEDs
//      if ep < EPOCHS: train one epoch (200 samples, in order, SGD batch 1)
// Expected results (from golden_model.py): E0 100, E1 132, E2 160, E3 179, E4 189, E5 194
//
// LEDs: led[7:0]  = number correct (of 200) from the latest evaluation
//       led[10:8] = epoch index of that evaluation
//       led[14]   = running (blinks off when finished)
//       led[15]   = all epochs finished
// =============================================================================
`timescale 1ns/1ps
module cnn_top #(
    parameter EPOCHS       = 5,
    parameter NSAMP        = 200,
    parameter CLKS_PER_BIT = 434,             // 50 MHz / 115200 baud
    parameter USE_MMCM     = 1,               // 1 = board (100 MHz in -> 50 MHz core), 0 = simulation
    parameter INIT_FILE  = "C:/Users/srika/Documents/MTP-1/golden_model/init_weights.hex",
    parameter DATA_FILE  = "C:/Users/srika/Documents/MTP-1/golden_model/data.hex",
    parameter LABEL_FILE = "C:/Users/srika/Documents/MTP-1/golden_model/labels.hex",
    parameter LUT_FILE   = "C:/Users/srika/Documents/MTP-1/golden_model/sigmoid_lut.hex"
)(
    input  wire        clk,          // 100 MHz
    input  wire        btn_rst,      // active-high push button: restart everything
    output wire [15:0] led,
    output wire        uart_tx
);
    // ---------------------------------------------------------------- clock: 100 MHz -> 50 MHz (relaxes timing)
    wire sysclk, locked;
    generate
        if (USE_MMCM) begin : g_mmcm
            wire clkfb, clkfb_b, clk50_raw;
            MMCME2_BASE #(.BANDWIDTH("OPTIMIZED"), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(10.0),
                          .CLKIN1_PERIOD(10.0), .CLKOUT0_DIVIDE_F(20.0)) u_mmcm (
                .CLKIN1(clk), .CLKFBIN(clkfb_b), .CLKFBOUT(clkfb), .CLKOUT0(clk50_raw),
                .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0));
            BUFG u_fb (.I(clkfb),     .O(clkfb_b));
            BUFG u_c  (.I(clk50_raw), .O(sysclk));
        end else begin : g_direct
            assign sysclk = clk;
            assign locked = 1'b1;
        end
    endgenerate

    // ---------------------------------------------------------------- reset: power-on + button
    reg [3:0] por = 4'd0;
    reg       b1 = 1'b0, b2 = 1'b0;
    always @(posedge sysclk) begin
        b1 <= btn_rst; b2 <= b1;
        if (por != 4'hF) por <= por + 4'd1;
    end
    wire rst = (por != 4'hF) | b2 | ~locked;

    // ---------------------------------------------------------------- core
    reg        load_params, start, train_en;
    reg  [7:0] sample_idx;
    wire       busy, done, pred, correct;

    cnn_core #(.INIT_FILE(INIT_FILE), .DATA_FILE(DATA_FILE),
               .LABEL_FILE(LABEL_FILE), .LUT_FILE(LUT_FILE)) u_core (
        .clk(sysclk), .rst(rst), .load_params(load_params), .start(start),
        .sample_idx(sample_idx), .train_en(train_en),
        .busy(busy), .done(done), .pred(pred), .correct(correct));

    // ---------------------------------------------------------------- controller
    localparam [2:0] C_LOADP = 0, C_LOADW = 1, C_START = 2, C_WAIT = 3,
                     C_NEXT  = 4, C_EVDONE = 5, C_FIN = 6;
    reg [2:0] cst;
    reg       mode;                // 0 = evaluate, 1 = train
    reg [7:0] samp, cnt, acc_last;
    reg [3:0] ep;
    reg       msg_go, finished;

    // performance counters (core clock cycles)
    reg [31:0] pass_cyc;           // cycles since the current pass (200 samples) started
    reg [31:0] tot_cyc;            // cycles from end of weight load to end of last evaluation
    reg        run_en;
    reg [7:0]  msg_type;           // "E" = evaluation pass, "T" = training epoch, "D" = total
    reg [3:0]  msg_ep;
    reg [7:0]  msg_cnt;
    reg [31:0] msg_cyc;

    always @(posedge sysclk) begin
        load_params <= 1'b0; start <= 1'b0; msg_go <= 1'b0;
        pass_cyc <= pass_cyc + 32'd1;
        if (run_en) tot_cyc <= tot_cyc + 32'd1;
        if (rst) begin
            cst <= C_LOADP; mode <= 1'b0; samp <= 8'd0; cnt <= 8'd0; ep <= 4'd0;
            acc_last <= 8'd0; finished <= 1'b0; sample_idx <= 8'd0; train_en <= 1'b0;
            run_en <= 1'b0; tot_cyc <= 32'd0;
        end else begin
            case (cst)
                C_LOADP: begin load_params <= 1'b1; cst <= C_LOADW; end
                C_LOADW: if (done) begin
                    mode <= 1'b0; samp <= 8'd0; cnt <= 8'd0; ep <= 4'd0; cst <= C_START;
                    pass_cyc <= 32'd0; tot_cyc <= 32'd0; run_en <= 1'b1;
                end
                C_START: begin
                    sample_idx <= samp; train_en <= mode; start <= 1'b1; cst <= C_WAIT;
                end
                C_WAIT: if (done) begin
                    if (!mode && correct) cnt <= cnt + 8'd1;
                    cst <= C_NEXT;
                end
                C_NEXT: begin
                    if (samp == NSAMP - 1) begin
                        samp <= 8'd0;
                        msg_cyc <= pass_cyc + 32'd1;
                        if (!mode) cst <= C_EVDONE;
                        else begin                       // finished a training epoch
                            msg_type <= "T"; msg_ep <= ep + 4'd1; msg_cnt <= 8'd0; msg_go <= 1'b1;
                            pass_cyc <= 32'd0;
                            mode <= 1'b0; cnt <= 8'd0; ep <= ep + 4'd1; cst <= C_START;
                        end
                    end else begin
                        samp <= samp + 8'd1; cst <= C_START;
                    end
                end
                C_EVDONE: begin
                    acc_last <= cnt; msg_go <= 1'b1;
                    msg_type <= "E"; msg_ep <= ep; msg_cnt <= cnt;
                    pass_cyc <= 32'd0;
                    if (ep == EPOCHS) begin cst <= C_FIN; run_en <= 1'b0; end
                    else begin mode <= 1'b1; cst <= C_START; end
                end
                C_FIN: finished <= 1'b1;
                default: cst <= C_LOADP;
            endcase
        end
    end

    assign led = {finished, ~finished & ~rst, 3'b000, ep[2:0], acc_last};
    // note: led[14] lights while running; led[13:11] unused

    // ---------------------------------------------------------------- UART report
    // one line per event:  "<type><ep> <ddd> <hhhhhhhh>\r\n"
    //   E<ep> <correct of 200> <cycles of the 200-sample evaluation pass>
    //   T<ep> 000 <cycles of training epoch ep>
    //   D0 000 <total cycles, first evaluation .. last evaluation>   (sent once, after the last E line)
    reg  [7:0] tx_data; reg tx_valid; wire tx_busy;
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart (
        .clk(sysclk), .rst(rst), .data(tx_data), .valid(tx_valid), .busy(tx_busy), .tx(uart_tx));

    localparam [1:0] U_IDLE = 0, U_PUSH = 1, U_ACK = 2;
    reg [1:0] ust; reg [3:0] uidx; reg [7:0] m_cnt; reg [3:0] m_ep; reg [7:0] m_type; reg [31:0] m_cyc;
    reg        d_sent;
    wire [7:0] hund = m_cnt / 8'd100;
    wire [7:0] tens = (m_cnt % 8'd100) / 8'd10;
    wire [7:0] ones = m_cnt % 8'd10;
    reg  [3:0] nib;
    reg  [7:0] ch;
    always @* begin
        case (uidx)
            4'd7:  nib = m_cyc[31:28];
            4'd8:  nib = m_cyc[27:24];
            4'd9:  nib = m_cyc[23:20];
            4'd10: nib = m_cyc[19:16];
            4'd11: nib = m_cyc[15:12];
            4'd12: nib = m_cyc[11:8];
            4'd13: nib = m_cyc[7:4];
            default: nib = m_cyc[3:0];
        endcase
        case (uidx)
            4'd0:  ch = m_type;
            4'd1:  ch = 8'd48 + m_ep;
            4'd2:  ch = " ";
            4'd3:  ch = 8'd48 + hund;
            4'd4:  ch = 8'd48 + tens;
            4'd5:  ch = 8'd48 + ones;
            4'd6:  ch = " ";
            4'd15: ch = 8'd13;
            default: ch = (nib < 4'd10) ? (8'd48 + nib) : (8'd55 + nib);   // hex digit (uidx 7..14)
        endcase
    end
    always @(posedge sysclk) begin
        tx_valid <= 1'b0;
        if (rst) begin ust <= U_IDLE; d_sent <= 1'b0; end
        else case (ust)
            U_IDLE: if (msg_go) begin
                        m_type <= msg_type; m_cnt <= msg_cnt; m_ep <= msg_ep; m_cyc <= msg_cyc;
                        uidx <= 4'd0; ust <= U_PUSH;
                    end else if (finished && !d_sent) begin
                        m_type <= "D"; m_cnt <= 8'd0; m_ep <= 4'd0; m_cyc <= tot_cyc;
                        d_sent <= 1'b1; uidx <= 4'd0; ust <= U_PUSH;
                    end
            U_PUSH: if (!tx_busy) begin tx_data <= ch; tx_valid <= 1'b1; ust <= U_ACK; end
            U_ACK:  begin
                        if (uidx == 4'd15) begin                 // CR sent -> send LF directly
                            uidx <= 4'd0; ust <= 3;
                        end else begin uidx <= uidx + 4'd1; ust <= U_PUSH; end
                    end
            default: if (!tx_busy && !tx_valid) begin tx_data <= 8'd10; tx_valid <= 1'b1; ust <= U_IDLE; end
        endcase
    end
endmodule
// -----------------------------------------------------------------------------
module uart_tx #(parameter CLKS_PER_BIT = 868)(
    input  wire       clk, rst,
    input  wire [7:0] data,
    input  wire       valid,
    output reg        busy,
    output reg        tx
);
    reg [3:0]  bitn;
    reg [15:0] cnt;
    reg [9:0]  sh;
    initial begin tx = 1'b1; busy = 1'b0; end
    always @(posedge clk) begin
        if (rst) begin tx <= 1'b1; busy <= 1'b0; end
        else if (!busy) begin
            if (valid) begin sh <= {1'b1, data, 1'b0}; busy <= 1'b1; cnt <= 16'd0; bitn <= 4'd0; tx <= 1'b0; end
        end else begin
            if (cnt == CLKS_PER_BIT - 1) begin
                cnt <= 16'd0;
                if (bitn == 4'd9) begin busy <= 1'b0; tx <= 1'b1; end
                else begin bitn <= bitn + 4'd1; tx <= sh[bitn + 4'd1]; end
            end else cnt <= cnt + 16'd1;
        end
    end
endmodule
