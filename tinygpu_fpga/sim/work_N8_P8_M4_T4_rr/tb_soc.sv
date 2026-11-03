`timescale 1ns/1ns
// tb_soc: runs one round of all kernels on gpu_soc_top and prints the UART report lines.
// Configuration is set by the localparams below (sim/run_sim.sh rewrites them per configuration).
module tb_soc;
    localparam NUM_CORES = 8;
    localparam TPB       = 4;
    localparam PROG_CH   = 8;
    localparam DATA_CH   = 4;
    localparam NK        = 3;
    localparam CPB       = 8;
    reg clk = 0; always #5 clk = ~clk;
    wire [15:0] led; wire tx;
    gpu_soc_top #(.NUM_CORES(NUM_CORES), .THREADS_PER_BLOCK(TPB), .PROG_CH(PROG_CH), .DATA_CH(DATA_CH),
                  .NUM_KERNELS(NK), .CLKS_PER_BIT(CPB), .USE_MMCM(0), .REPEAT_GAP(100))
        dut (.clk(clk), .btn_rst(1'b0), .led(led), .uart_tx(tx));

    reg [7:0] rx; integer k, nl = 0;
    initial forever begin
        @(negedge tx);
        repeat (CPB + CPB/2) @(posedge clk);
        for (k = 0; k < 8; k = k + 1) begin rx[k] = tx; repeat (CPB) @(posedge clk); end
        if (rx != 8'd13) $write("%c", rx);
        if (rx == 8'd10) begin nl = nl + 1; if (nl == NK) begin #1000; $finish; end end
    end
    initial begin #50000000; $display("TIMEOUT"); $finish; end
endmodule
