`default_nettype none
`timescale 1ns/1ns

// =============================================================================
// gpu_soc_top -- TinyGPU (adam-maj/tiny-gpu) on the Nexys 4 DDR with on-chip memories.
//
// For each benchmark kernel k (repeated forever, one "round" every REPEAT_GAP cycles):
//   1. hold the GPU in reset, copy prog/init images of kernel k into program / data memory
//   2. release reset, write the thread count into the DCR, raise start
//   3. count core-clock cycles from start until the dispatcher reports done
//   4. compare all 256 data-memory bytes with the expected image
//   5. report over UART:  "K<k> N<cores> T<threads/block> P<prog ch> M<data ch> C<cycles hex> E<errors hex> R<round hex>"
//
// Memory model (1-cycle latency, valid/ready handshake as expected by tiny-gpu's controller):
//   program memory : PROG_CH read ports (LUT-RAM replicated per port)
//   data memory    : DATA_CH read ports (LUT-RAM replicated per port), ONE write per cycle (arbitrated)
//
// LEDs: led[k] = kernel k passed in the last round, led[14] = heartbeat, led[15] = all kernels passed
// =============================================================================
module gpu_soc_top #(
    parameter NUM_CORES         = 2,
    parameter THREADS_PER_BLOCK = 4,
    parameter PROG_CH           = 1,        // program-memory channels (stock tiny-gpu: 1)
    parameter DATA_CH           = 4,        // data-memory channels    (stock tiny-gpu: 4)
    parameter NUM_KERNELS       = 3,
    parameter CORE_MHZ          = 50,       // core clock from the MMCM (VCO = 1000 MHz, so 1000/CORE_MHZ must be a valid divider)
    parameter CLKS_PER_BIT      = 0,        // 0 = derive from CORE_MHZ for 115200 baud
    parameter USE_MMCM          = 1,        // 1 = board (100 MHz in -> CORE_MHZ core), 0 = simulation
    parameter REPEAT_GAP        = 25000000, // idle cycles between rounds (0.5 s at 50 MHz)
    parameter TIMEOUT           = 24'hFFFFFF,
    parameter MEM_DIR           = "C:/Users/srika/Documents/MTP-1/tinygpu_fpga/mem"
) (
    input  wire        clk,
    input  wire        btn_rst,
    output wire [15:0] led,
    output wire        uart_tx
);
    localparam CPB = (CLKS_PER_BIT != 0) ? CLKS_PER_BIT : (CORE_MHZ * 1000000) / 115200;

    // ---------------------------------------------------------------- clock / reset (same as cnn_top)
    wire sysclk, locked;
    generate
        if (USE_MMCM) begin : g_mmcm
            wire clkfb, clkfb_b, clk50_raw;
            MMCME2_BASE #(.BANDWIDTH("OPTIMIZED"), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(10.0),
                          .CLKIN1_PERIOD(10.0), .CLKOUT0_DIVIDE_F(1000.0 / CORE_MHZ)) u_mmcm (
                .CLKIN1(clk), .CLKFBIN(clkfb_b), .CLKFBOUT(clkfb), .CLKOUT0(clk50_raw),
                .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0));
            BUFG u_fb (.I(clkfb),     .O(clkfb_b));
            BUFG u_c  (.I(clk50_raw), .O(sysclk));
        end else begin : g_direct
            assign sysclk = clk;
            assign locked = 1'b1;
        end
    endgenerate

    reg [3:0] por = 4'd0;
    reg       b1 = 1'b0, b2 = 1'b0;
    always @(posedge sysclk) begin
        b1 <= btn_rst; b2 <= b1;
        if (por != 4'hF) por <= por + 4'd1;
    end
    wire rst = (por != 4'hF) | b2 | ~locked;

    // ---------------------------------------------------------------- kernel image ROMs (block RAM)
    localparam KW = (NUM_KERNELS > 1) ? $clog2(NUM_KERNELS) : 1;
    reg [15:0] prog_rom [0:NUM_KERNELS*256-1];
    reg [7:0]  init_rom [0:NUM_KERNELS*256-1];
    reg [7:0]  exp_rom  [0:NUM_KERNELS*256-1];
    reg [7:0]  kinfo    [0:15];
    initial begin
        $readmemh({MEM_DIR, "/prog.hex"},   prog_rom);
        $readmemh({MEM_DIR, "/init.hex"},   init_rom);
        $readmemh({MEM_DIR, "/expect.hex"}, exp_rom);
        $readmemh({MEM_DIR, "/kinfo.hex"},  kinfo);
    end

    reg  [KW-1:0] kidx;
    reg  [8:0]    idx;                       // 0..256 (one extra step for the 1-cycle ROM latency)
    wire [KW+7:0] rom_addr = {kidx, idx[7:0]};
    reg  [15:0]   prog_q;
    reg  [7:0]    init_q, exp_q;
    always @(posedge sysclk) begin
        prog_q <= prog_rom[rom_addr];
        init_q <= init_rom[rom_addr];
        exp_q  <= exp_rom[rom_addr];
    end

    // ---------------------------------------------------------------- GPU
    reg        gpu_reset, gpu_start, dcr_we;
    reg  [7:0] dcr_data;
    wire       gpu_done;

    wire [PROG_CH-1:0] p_valid;
    wire [7:0]         p_addr  [PROG_CH-1:0];
    reg  [PROG_CH-1:0] p_ready;
    reg  [15:0]        p_data  [PROG_CH-1:0];

    wire [DATA_CH-1:0] d_rvalid;
    wire [7:0]         d_raddr [DATA_CH-1:0];
    reg  [DATA_CH-1:0] d_rready;
    reg  [7:0]         d_rdata [DATA_CH-1:0];
    wire [DATA_CH-1:0] d_wvalid;
    wire [7:0]         d_waddr [DATA_CH-1:0];
    wire [7:0]         d_wdata [DATA_CH-1:0];
    reg  [DATA_CH-1:0] d_wready;

    gpu #(
        .DATA_MEM_ADDR_BITS(8), .DATA_MEM_DATA_BITS(8), .DATA_MEM_NUM_CHANNELS(DATA_CH),
        .PROGRAM_MEM_ADDR_BITS(8), .PROGRAM_MEM_DATA_BITS(16), .PROGRAM_MEM_NUM_CHANNELS(PROG_CH),
        .NUM_CORES(NUM_CORES), .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) u_gpu (
        .clk(sysclk), .reset(gpu_reset), .start(gpu_start), .done(gpu_done),
        .device_control_write_enable(dcr_we), .device_control_data(dcr_data),
        .program_mem_read_valid(p_valid), .program_mem_read_address(p_addr),
        .program_mem_read_ready(p_ready), .program_mem_read_data(p_data),
        .data_mem_read_valid(d_rvalid), .data_mem_read_address(d_raddr),
        .data_mem_read_ready(d_rready), .data_mem_read_data(d_rdata),
        .data_mem_write_valid(d_wvalid), .data_mem_write_address(d_waddr),
        .data_mem_write_data(d_wdata), .data_mem_write_ready(d_wready)
    );

    // ---------------------------------------------------------------- program memory: 1 write (loader), PROG_CH reads
    reg  [15:0] pmem [0:255];
    reg         pm_we;
    reg  [7:0]  pm_waddr;
    reg  [15:0] pm_wdata;
    always @(posedge sysclk) if (pm_we) pmem[pm_waddr] <= pm_wdata;

    genvar c;
    generate
        for (c = 0; c < PROG_CH; c = c + 1) begin : g_pport
            always @(posedge sysclk) begin
                p_data[c]  <= pmem[p_addr[c]];
                p_ready[c] <= p_valid[c] & ~p_ready[c] & ~gpu_reset;
            end
        end
    endgenerate

    // ---------------------------------------------------------------- data memory: 1 write per cycle, DATA_CH (+1 checker) reads
    reg  [7:0] dmem [0:255];
    reg        ld_we;
    reg  [7:0] ld_waddr, ld_wdata;

    // write arbitration: lowest-numbered channel with a pending (not yet acknowledged) write wins
    reg                     w_any;
    reg [$clog2(DATA_CH+1)-1:0] w_sel;
    always @* begin
        w_any = 1'b0; w_sel = '0;
        for (int i = DATA_CH - 1; i >= 0; i--)
            if (d_wvalid[i] && !d_wready[i]) begin w_any = 1'b1; w_sel = i; end
    end
    wire       dm_we    = ld_we | (w_any & ~gpu_reset);
    wire [7:0] dm_waddr = ld_we ? ld_waddr : d_waddr[w_sel];
    wire [7:0] dm_wdata = ld_we ? ld_wdata : d_wdata[w_sel];
    always @(posedge sysclk) if (dm_we) dmem[dm_waddr] <= dm_wdata;

    always @(posedge sysclk) begin
        for (int i = 0; i < DATA_CH; i++)
            d_wready[i] <= !gpu_reset && w_any && !ld_we && (w_sel == i);
    end

    generate
        for (c = 0; c < DATA_CH; c = c + 1) begin : g_dport
            always @(posedge sysclk) begin
                d_rdata[c]  <= dmem[d_raddr[c]];
                d_rready[c] <= d_rvalid[c] & ~d_rready[c] & ~gpu_reset;
            end
        end
    endgenerate

    reg  [7:0] chk_addr, chk_q;
    always @(posedge sysclk) chk_q <= dmem[chk_addr];

    // ---------------------------------------------------------------- run controller
    localparam [3:0] S_IDLE = 0, S_LOAD = 1, S_REL = 2, S_DCR = 3, S_START = 4, S_RUN = 5,
                     S_CHK0 = 6, S_CHK = 7, S_REP = 8, S_REPW = 9, S_GAP = 10;
    reg [3:0]  st;
    reg [31:0] cyc, gap;
    reg [3:0]  wcnt;
    reg [15:0] errs;
    reg [7:0]  round;
    reg [NUM_KERNELS-1:0] pass, pass_last;
    reg        msg_go;
    reg [31:0] m_cyc;
    reg [15:0] m_err;
    reg [KW-1:0] m_k;
    wire       msg_busy;

    always @(posedge sysclk) begin
        pm_we <= 1'b0; ld_we <= 1'b0; dcr_we <= 1'b0; msg_go <= 1'b0;
        if (rst) begin
            st <= S_IDLE; gpu_reset <= 1'b1; gpu_start <= 1'b0; kidx <= '0; idx <= 9'd0;
            round <= 8'd0; pass <= '0; pass_last <= '0; gap <= 32'd0;
        end else begin
            case (st)
                S_IDLE: begin
                    gpu_reset <= 1'b1; gpu_start <= 1'b0; idx <= 9'd0; st <= S_LOAD;
                end
                // copy images: ROM address idx at cycle t, data available at t+1 -> written at address idx-1
                S_LOAD: begin
                    if (idx != 9'd0) begin
                        pm_we <= 1'b1; pm_waddr <= idx[7:0] - 8'd1; pm_wdata <= prog_q;
                        ld_we <= 1'b1; ld_waddr <= idx[7:0] - 8'd1; ld_wdata <= init_q;
                    end
                    if (idx == 9'd256) begin wcnt <= 4'd0; st <= S_REL; end
                    else idx <= idx + 9'd1;
                end
                S_REL: begin                                   // finish the last write, then release reset
                    wcnt <= wcnt + 4'd1;
                    if (wcnt == 4'd2) gpu_reset <= 1'b0;
                    if (wcnt == 4'd4) st <= S_DCR;
                end
                S_DCR: begin
                    dcr_we <= 1'b1; dcr_data <= kinfo[kidx]; st <= S_START;
                end
                S_START: begin
                    gpu_start <= 1'b1; cyc <= 32'd0; st <= S_RUN;
                end
                S_RUN: begin
                    cyc <= cyc + 32'd1;
                    if (gpu_done || cyc[23:0] == TIMEOUT) begin
                        if (!gpu_done) cyc <= 32'hFFFFFFFF;
                        gpu_start <= 1'b0; gpu_reset <= 1'b1;
                        idx <= 9'd0; errs <= 16'd0; st <= S_CHK0;
                    end
                end
                S_CHK0: begin                                  // prime the address pipelines
                    chk_addr <= 8'd0; idx <= 9'd0; st <= S_CHK;
                end
                // chk_addr / idx issued at cycle t; chk_q / exp_q valid at t+1 (both 1-cycle reads)
                S_CHK: begin
                    if (idx != 9'd0 && chk_q != exp_q) errs <= errs + 16'd1;
                    if (idx == 9'd256) st <= S_REP;
                    else begin idx <= idx + 9'd1; chk_addr <= idx[7:0] + 8'd1; end
                end
                S_REP: begin
                    if (!msg_busy) begin
                        m_cyc <= cyc; m_err <= errs; m_k <= kidx; msg_go <= 1'b1;
                        pass[kidx] <= (errs == 16'd0) && (cyc != 32'hFFFFFFFF);
                        st <= S_REPW;
                    end
                end
                S_REPW: begin
                    if (kidx == NUM_KERNELS - 1) begin
                        kidx <= '0; gap <= 32'd0; st <= S_GAP;
                    end else begin
                        kidx <= kidx + 1'b1; st <= S_IDLE;
                    end
                end
                S_GAP: begin
                    pass_last <= pass;
                    gap <= gap + 32'd1;
                    if (gap == REPEAT_GAP) begin round <= round + 8'd1; st <= S_IDLE; end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------- UART report line
    reg [25:0] hb;
    always @(posedge sysclk) hb <= hb + 26'd1;
    assign led = {&pass_last, hb[25], {(14-NUM_KERNELS){1'b0}}, pass_last};

    function automatic [7:0] hexc(input [3:0] n);
        hexc = (n < 4'd10) ? (8'd48 + n) : (8'd55 + n);
    endfunction
    function automatic [7:0] decc(input integer n);
        decc = 8'd48 + n[7:0];
    endfunction

    localparam LINE_LEN = 40;
    reg [7:0] line [0:LINE_LEN-1];
    reg [5:0] lidx;
    reg       sending;
    reg [7:0] tx_data; reg tx_valid; wire tx_busy;
    assign msg_busy = sending | msg_go;

    uart_tx #(.CLKS_PER_BIT(CPB)) u_uart (
        .clk(sysclk), .rst(rst), .data(tx_data), .valid(tx_valid), .busy(tx_busy), .tx(uart_tx));

    always @(posedge sysclk) begin
        tx_valid <= 1'b0;
        if (rst) begin
            sending <= 1'b0;
        end else if (msg_go) begin
            // "K0 N16 T4 P01 M04 C0000ABCD E0000 R01\r\n"
            line[0]  <= "K";  line[1]  <= decc(m_k);                 line[2]  <= " ";
            line[3]  <= "N";  line[4]  <= decc(NUM_CORES / 10);      line[5]  <= decc(NUM_CORES % 10);   line[6] <= " ";
            line[7]  <= "T";  line[8]  <= decc(THREADS_PER_BLOCK % 10); line[9] <= " ";
            line[10] <= "P";  line[11] <= decc(PROG_CH / 10);        line[12] <= decc(PROG_CH % 10);     line[13] <= " ";
            line[14] <= "M";  line[15] <= decc(DATA_CH / 10);        line[16] <= decc(DATA_CH % 10);     line[17] <= " ";
            line[18] <= "C";
            for (int i = 0; i < 8; i++) line[19 + i] <= hexc(m_cyc[31 - 4*i -: 4]);
            line[27] <= " ";  line[28] <= "E";
            for (int i = 0; i < 4; i++) line[29 + i] <= hexc(m_err[15 - 4*i -: 4]);
            line[33] <= " ";  line[34] <= "R"; line[35] <= hexc(round[7:4]); line[36] <= hexc(round[3:0]);
            line[37] <= 8'd13; line[38] <= 8'd10; line[39] <= 8'd0;
            lidx <= 6'd0; sending <= 1'b1;
        end else if (sending && !tx_busy && !tx_valid) begin
            if (lidx == 6'd39) sending <= 1'b0;
            else begin tx_data <= line[lidx]; tx_valid <= 1'b1; lidx <= lidx + 6'd1; end
        end
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
