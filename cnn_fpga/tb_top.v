// tb_top.v : runs the whole board design (5 epochs of training + evaluation after each) and
//            decodes the UART text. Expected final lines: E0 100 / E1 132 / E2 160 / E3 179 / E4 189 / E5 194
`timescale 1ns/1ps
module tb_top;
    localparam CPB = 16;                     // fast "baud" for simulation
    reg clk = 0; always #5 clk = ~clk;
    reg btn = 0;
    wire [15:0] led;
    wire tx;

    cnn_top #(.CLKS_PER_BIT(CPB), .USE_MMCM(0)) dut (.clk(clk), .btn_rst(btn), .led(led), .uart_tx(tx));

    // ---- tiny UART receiver
    reg [7:0] rx;
    integer k;
    initial begin
        forever begin
            @(negedge tx);
            repeat (CPB + CPB/2) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                rx[k] = tx;
                repeat (CPB) @(posedge clk);
            end
            $write("%c", rx);
        end
    end

    initial begin
        wait (led[15] === 1'b1);
        repeat (8000) @(posedge clk);          // let the last E line and the D (total cycles) line finish
        $display("\nfinished: led[7:0]=%0d (expect 194), epoch led=%0d", led[7:0], led[10:8]);
        $finish;
    end
    initial begin repeat (20) #100000000; $display("TIMEOUT"); $finish; end   // 2 s; a single #4000000000 overflows 32 bits -> fires at t=0
endmodule