// =============================================================================
// cnn_core.v  --  trains / evaluates one sample of:
//   x 8x8 -> Conv1 3x3 (1->2) -> ReLU -> Conv2 2x2 (2->2) -> GAP -> 2 logits -> sigmoid-CE
// Bit-exact with golden_model.py.  Q4.12 data, 40-bit accumulator, ONE shared MAC.
// Each MAC step takes 2 cycles (S_RD registers operands, S_MAC accumulates) -> easy 100 MHz timing.
//
// Parameter memory layout (identical to golden pack()):
//   par[0..17]  W1[o][u][v]  (o*9+u*3+v)     par[18..19] b1
//   par[20..35] W2[k][c][u][v] (k*8+c*4+u*2+v) par[36..37] b2
// =============================================================================
`timescale 1ns/1ps
module cnn_core #(
    parameter INIT_FILE  = "C:/Users/srika/Documents/MTP-1/golden_model/init_weights.hex",
    parameter DATA_FILE  = "C:/Users/srika/Documents/MTP-1/golden_model/data.hex",
    parameter LABEL_FILE = "C:/Users/srika/Documents/MTP-1/golden_model/labels.hex",
    parameter LUT_FILE   = "C:/Users/srika/Documents/MTP-1/golden_model/sigmoid_lut.hex"
)(
    input  wire       clk,
    input  wire       rst,           // synchronous, active high
    input  wire       load_params,   // 1-cycle pulse (core idle): par <= init ROM
    input  wire       start,         // 1-cycle pulse (core idle): process sample_idx
    input  wire [7:0] sample_idx,    // 0..199
    input  wire       train_en,      // 1 = forward+backward+update, 0 = forward only (evaluate)
    output reg        busy,
    output reg        done,          // 1-cycle pulse when finished
    output reg        pred,          // valid at done: logit1 > logit0
    output reg        correct        // valid at done: pred == label
);
    // ------------------------------------------------------------------ constants
    localparam ACCW  = 40;
    localparam FRAC  = 12;
    localparam signed [15:0] INV25 = 16'sd164;

    // phases
    localparam [2:0] PH_C1 = 3'd0, PH_C2 = 3'd1, PH_DA1 = 3'd2,
                     PH_DW2 = 3'd3, PH_DW1 = 3'd4, PH_DB1 = 3'd5;
    // states
    localparam [4:0] S_IDLE = 0, S_INIT = 1, S_LD0 = 2, S_LD1 = 3, S_LD2 = 4,
                     S_ACC = 5, S_RD = 6, S_MAC = 7, S_FIN = 8,
                     S_LG0 = 9, S_LG1 = 10, S_LG2 = 11, S_LG3 = 12, S_LG4 = 13,
                     S_DZ0 = 14, S_DZ1 = 15, S_B2U = 16, S_DONE = 17, S_DZ2 = 18;

    // ------------------------------------------------------------------ memories
    reg signed [15:0] par     [0:37];
    reg signed [15:0] init_rom[0:37];
    reg signed [15:0] xmem    [0:63];
    reg signed [15:0] z1mem   [0:71];
    reg signed [15:0] dz1mem  [0:71];
    reg signed [15:0] data_rom[0:12799];     // synchronous read -> block RAM
    reg        [15:0] lut_rom [0:511];
    reg        [3:0]  label_rom[0:199];

    initial begin
        // initial weights are embedded (same values as init_weights.hex) -> no file lookup needed
        init_rom[0] = 2168;
        init_rom[1] = 492;
        init_rom[2] = 1203;
        init_rom[3] = 2754;
        init_rom[4] = 2295;
        init_rom[5] = -1201;
        init_rom[6] = 1167;
        init_rom[7] = -186;
        init_rom[8] = -127;
        init_rom[9] = 505;
        init_rom[10] = 177;
        init_rom[11] = 1787;
        init_rom[12] = 935;
        init_rom[13] = 150;
        init_rom[14] = 545;
        init_rom[15] = 410;
        init_rom[16] = 1836;
        init_rom[17] = -252;
        init_rom[18] = 0;
        init_rom[19] = 0;
        init_rom[20] = 385;
        init_rom[21] = -1050;
        init_rom[22] = -3137;
        init_rom[23] = 803;
        init_rom[24] = 1062;
        init_rom[25] = -912;
        init_rom[26] = 2789;
        init_rom[27] = -1787;
        init_rom[28] = 56;
        init_rom[29] = -230;
        init_rom[30] = 1883;
        init_rom[31] = 1806;
        init_rom[32] = 190;
        init_rom[33] = 465;
        init_rom[34] = -1091;
        init_rom[35] = -2434;
        init_rom[36] = 0;
        init_rom[37] = 0;
        $readmemh(DATA_FILE,  data_rom);
        $readmemh(LABEL_FILE, label_rom);
        $readmemh(LUT_FILE,   lut_rom);
    end

    reg  [13:0]        data_addr;
    reg  signed [15:0] data_q;
    always @(posedge clk) data_q <= data_rom[data_addr];

    // ------------------------------------------------------------------ helper functions
    function signed [15:0] sat16(input signed [ACCW-1:0] v);
        begin
            if (v > 40'sd32767)       sat16 = 16'sh7FFF;
            else if (v < -40'sd32768) sat16 = 16'sh8000;
            else                      sat16 = v[15:0];
        end
    endfunction

    // ------------------------------------------------------------------ registers
    reg [4:0] state;
    reg [2:0] ph;
    reg [2:0] o0, o1, o2, i0, i1, i2;        // outer / inner loop counters
    reg [5:0] init_idx, ld_idx;
    reg [7:0] sample_r;
    reg       train_r;
    reg       label_r;

    reg signed [ACCW-1:0] acc;
    reg signed [15:0]     opa, opb;

    reg signed [31:0]     s0, s1;            // GAP sums
    reg signed [ACCW-1:0] pr0, pr1;
    reg signed [15:0]     logit0, logit1, d;
    reg        [8:0]      lut_idx;
    reg signed [15:0]     p1;
    reg signed [16:0]     dlog1;
    reg signed [15:0]     dz2_0, dz2_1;

    // ------------------------------------------------------------------ combinational loop / operand logic
    reg signed [15:0]     opa_n, opb_n;
    reg signed [ACCW-1:0] acc_init;
    reg [2:0]             il0, il1, il2, ol0, ol1, ol2;
    reg signed [15:0]     zt;
    integer               ii, jj;

    always @* begin
        opa_n = 16'sd0; opb_n = 16'sd0; acc_init = {ACCW{1'b0}};
        il0 = 0; il1 = 0; il2 = 0; ol0 = 0; ol1 = 0; ol2 = 0;
        zt = 16'sd0; ii = 0; jj = 0;
        case (ph)
            PH_C1: begin        // outer: o=k, i, j   inner: u, v
                il0 = 2; il1 = 2; il2 = 0;  ol0 = 1; ol1 = 5; ol2 = 5;
                opa_n    = xmem[(o1 + i0) * 8 + (o2 + i1)];
                opb_n    = par[o0 * 9 + i0 * 3 + i1];
                acc_init = $signed(par[18 + o0]) <<< FRAC;
            end
            PH_C2: begin        // outer: k, i, j     inner: c, u, v
                il0 = 1; il1 = 1; il2 = 1;  ol0 = 1; ol1 = 4; ol2 = 4;
                zt       = z1mem[i0 * 36 + (o1 + i1) * 6 + (o2 + i2)];
                opa_n    = zt[15] ? 16'sd0 : zt;                       // ReLU
                opb_n    = par[20 + o0 * 8 + i0 * 4 + i1 * 2 + i2];
                acc_init = $signed(par[36 + o0]) <<< FRAC;
            end
            PH_DA1: begin       // outer: c, m, n     inner: k, u, v
                il0 = 1; il1 = 1; il2 = 1;  ol0 = 1; ol1 = 5; ol2 = 5;
                ii = o1; ii = ii - i1;
                jj = o2; jj = jj - i2;
                if (ii >= 0 && ii <= 4 && jj >= 0 && jj <= 4)
                    opa_n = (i0 == 0) ? dz2_0 : dz2_1;
                else
                    opa_n = 16'sd0;
                opb_n    = par[20 + i0 * 8 + o0 * 4 + i1 * 2 + i2];
                acc_init = {ACCW{1'b0}};
            end
            PH_DW2: begin       // outer: k, c, (u,v)=o2   inner: i, j
                il0 = 4; il1 = 4; il2 = 0;  ol0 = 1; ol1 = 1; ol2 = 3;
                opa_n    = (o0 == 0) ? dz2_0 : dz2_1;
                zt       = z1mem[o1 * 36 + (i0 + o2[1]) * 6 + (i1 + o2[0])];
                opb_n    = zt[15] ? 16'sd0 : zt;                       // a1 = ReLU(z1)
                acc_init = {ACCW{1'b0}};
            end
            PH_DW1: begin       // outer: o, u, v     inner: i, j
                il0 = 5; il1 = 5; il2 = 0;  ol0 = 1; ol1 = 2; ol2 = 2;
                opa_n    = dz1mem[o0 * 36 + i0 * 6 + i1];
                opb_n    = xmem[(i0 + o1) * 8 + (i1 + o2)];
                acc_init = {ACCW{1'b0}};
            end
            PH_DB1: begin       // outer: o           inner: i, j   (plain sum of dz1)
                il0 = 5; il1 = 5; il2 = 0;  ol0 = 1; ol1 = 0; ol2 = 0;
                opa_n    = dz1mem[o0 * 36 + i0 * 6 + i1];
                opb_n    = 16'sd1;
                acc_init = {ACCW{1'b0}};
            end
            default: ;
        endcase
    end

    wire in_last  = (i0 == il0) && (i1 == il1) && (i2 == il2);
    wire out_last = (o0 == ol0) && (o1 == ol1) && (o2 == ol2);

    // ------------------------------------------------------------------ finish-of-output-item datapath
    wire signed [ACCW-1:0] rq_full = (acc + 40'sd2048) >>> FRAC;
    wire signed [15:0]     rq      = sat16(rq_full);

    wire [6:0]  zidx = o0 * 36 + o1 * 6 + o2;
    wire signed [15:0] z1_here = z1mem[zidx];

    reg  [5:0] widx;
    always @* begin
        case (ph)
            PH_DW2:  widx = 20 + o0 * 8 + o1 * 4 + o2;
            PH_DW1:  widx = o0 * 9 + o1 * 3 + o2;
            default: widx = 18 + o0;                 // PH_DB1
        endcase
    end
    wire signed [15:0]     par_old = par[widx];
    wire signed [ACCW-1:0] sh15    = (acc + 40'sd16384) >>> 15;   // lr = 2^-3 on Q8.24 gradient
    wire signed [ACCW-1:0] sh3     = (acc + 40'sd4)     >>> 3;    // lr = 2^-3 on bias gradient
    wire signed [ACCW-1:0] sh_sel  = (ph == PH_DB1) ? sh3 : sh15;
    wire signed [ACCW-1:0] w_full  = par_old - sh_sel;
    wire signed [15:0]     w_new   = sat16(w_full);

    // bias-2 update (db2 = 25*dz2)
    wire signed [ACCW-1:0] db2_0 = dz2_0 * 25;
    wire signed [ACCW-1:0] db2_1 = dz2_1 * 25;
    wire signed [ACCW-1:0] b2s0  = (db2_0 + 40'sd4) >>> 3;
    wire signed [ACCW-1:0] b2s1  = (db2_1 + 40'sd4) >>> 3;
    wire signed [ACCW-1:0] b2f0  = $signed(par[36]) - b2s0;
    wire signed [ACCW-1:0] b2f1  = $signed(par[37]) - b2s1;

    // logits / softmax helper wires
    wire signed [ACCW-1:0] lg0_full = (pr0 + 40'sd2048) >>> FRAC;
    wire signed [ACCW-1:0] lg1_full = (pr1 + 40'sd2048) >>> FRAC;
    wire signed [ACCW-1:0] dz_full0 = (pr0 + 40'sd2048) >>> FRAC;
    wire signed [ACCW-1:0] dz_full1 = (pr1 + 40'sd2048) >>> FRAC;
    wire signed [16:0]     diff     = logit1 - logit0;
    wire signed [16:0]     dlab     = label_r ? 17'sd4096 : 17'sd0;

    // ------------------------------------------------------------------ FSM
    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            state <= S_IDLE; busy <= 1'b0; done <= 1'b0;
        end else begin
            case (state)
            // ----------------------------------------------------------- idle / init / load
            S_IDLE: begin
                if (load_params) begin
                    init_idx <= 6'd0; busy <= 1'b1; state <= S_INIT;
                end else if (start) begin
                    sample_r <= sample_idx; train_r <= train_en;
                    label_r  <= label_rom[sample_idx][0];
                    ld_idx   <= 6'd0; busy <= 1'b1; state <= S_LD0;
                end
            end
            S_INIT: begin
                par[init_idx] <= init_rom[init_idx];
                if (init_idx == 6'd37) state <= S_DONE;
                else init_idx <= init_idx + 6'd1;
            end
            S_LD0: begin data_addr <= {sample_r, ld_idx}; state <= S_LD1; end
            S_LD1: state <= S_LD2;
            S_LD2: begin
                xmem[ld_idx] <= data_q;
                if (ld_idx == 6'd63) begin
                    ph <= PH_C1; o0 <= 0; o1 <= 0; o2 <= 0; state <= S_ACC;
                end else begin
                    ld_idx <= ld_idx + 6'd1; state <= S_LD0;
                end
            end
            // ----------------------------------------------------------- generic MAC loop engine
            S_ACC: begin
                acc <= acc_init; i0 <= 0; i1 <= 0; i2 <= 0; state <= S_RD;
            end
            S_RD: begin
                opa <= opa_n; opb <= opb_n; state <= S_MAC;
            end
            S_MAC: begin
                acc <= acc + opa * opb;
                if (in_last) state <= S_FIN;
                else begin
                    if (i2 != il2) i2 <= i2 + 3'd1;
                    else begin
                        i2 <= 0;
                        if (i1 != il1) i1 <= i1 + 3'd1;
                        else begin i1 <= 0; i0 <= i0 + 3'd1; end
                    end
                    state <= S_RD;
                end
            end
            S_FIN: begin
                case (ph)
                    PH_C1:  z1mem[zidx] <= rq;
                    PH_C2:  if (o0 == 0) s0 <= s0 + rq; else s1 <= s1 + rq;
                    PH_DA1: dz1mem[zidx] <= (z1_here > 16'sd0) ? rq : 16'sd0;
                    default: par[widx] <= w_new;     // PH_DW2, PH_DW1, PH_DB1
                endcase
                if (out_last) begin
                    o0 <= 0; o1 <= 0; o2 <= 0;
                    case (ph)
                        PH_C1:  begin ph <= PH_C2; s0 <= 32'sd0; s1 <= 32'sd0; state <= S_ACC; end
                        PH_C2:  state <= S_LG0;
                        PH_DA1: begin ph <= PH_DW2; state <= S_ACC; end
                        PH_DW2: state <= S_B2U;
                        PH_DW1: begin ph <= PH_DB1; state <= S_ACC; end
                        default: state <= S_DONE;    // PH_DB1
                    endcase
                end else begin
                    if (o2 != ol2) o2 <= o2 + 3'd1;
                    else begin
                        o2 <= 0;
                        if (o1 != ol1) o1 <= o1 + 3'd1;
                        else begin o1 <= 0; o0 <= o0 + 3'd1; end
                    end
                    state <= S_ACC;
                end
            end
            // ----------------------------------------------------------- GAP -> logits -> softmax -> dlogits
            S_LG0: begin pr0 <= s0 * INV25; pr1 <= s1 * INV25; state <= S_LG1; end
            S_LG1: begin logit0 <= sat16(lg0_full); logit1 <= sat16(lg1_full); state <= S_LG2; end
            S_LG2: begin
                if (diff > 17'sd32767)       d <= 16'sh7FFF;
                else if (diff < -17'sd32768) d <= 16'sh8000;
                else                         d <= diff[15:0];
                state <= S_LG3;
            end
            S_LG3: begin
                lut_idx <= {~d[15], d[14:7]};                   // (d>>7)+256
                state   <= S_LG4;
            end
            S_LG4: begin
                p1      <= lut_rom[lut_idx];
                pred    <= (logit1 > logit0);
                correct <= ((logit1 > logit0) == label_r);
                state   <= train_r ? S_DZ0 : S_DONE;
            end
            S_DZ0: begin
                dlog1 <= $signed({1'b0, p1}) - dlab;            // p1 - label*4096
                state <= S_DZ1;
            end
            S_DZ1: begin
                // dlog0 = -dlog1 ; dz2 = round(dlog*INV25 / 4096)
                pr0   <= (-dlog1) * INV25;
                pr1   <= dlog1 * INV25;
                state <= S_DZ2;
            end
            S_DZ2: begin
                dz2_0 <= dz_full0[15:0];                        // |dz2| <= 164, no saturation needed
                dz2_1 <= dz_full1[15:0];
                ph <= PH_DA1; o0 <= 0; o1 <= 0; o2 <= 0;
                state <= S_ACC;
            end
            S_B2U: begin
                par[36] <= sat16(b2f0);
                par[37] <= sat16(b2f1);
                ph <= PH_DW1; o0 <= 0; o1 <= 0; o2 <= 0;
                state <= S_ACC;
            end
            S_DONE: begin
                done <= 1'b1; busy <= 1'b0; state <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule 