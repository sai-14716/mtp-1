// tb_core.v : trains NSTEPS samples and compares all 38 parameters after EVERY step
//             against params_log.hex produced by golden_model.py (bit-exact).
`timescale 1ns/1ps
module tb_core;
    parameter NSTEPS = 20;               // 1000 = full 5 epochs
    parameter PARAMS_LOG = "C:/Users/srika/Documents/MTP-1/golden_model/params_log.hex";

    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1, load_params = 0, start = 0, train_en = 1;
    reg [7:0] sample_idx = 0;
    wire busy, done, pred, correct;

    cnn_core dut (.clk(clk), .rst(rst), .load_params(load_params), .start(start),
                  .sample_idx(sample_idx), .train_en(train_en),
                  .busy(busy), .done(done), .pred(pred), .correct(correct));

    reg [15:0] ref_log [0:37999];
    integer step, i, errors, first_bad;
    reg signed [15:0] got, exp;
    integer cyc0;

    task wait_done;
        begin
            @(negedge clk);
            while (!done) @(negedge clk);
        end
    endtask

    initial begin
        $readmemh(PARAMS_LOG, ref_log);
        errors = 0; first_bad = -1;
        repeat (4) @(negedge clk); rst = 0; @(negedge clk);

        // --- load initial weights
        load_params = 1; @(negedge clk); load_params = 0;
        wait_done;
        $display("params loaded: W1[0]=%0d b1[0]=%0d W2[0]=%0d b2[1]=%0d",
                 dut.par[0], dut.par[18], dut.par[20], dut.par[37]);

        // --- train
        for (step = 0; step < NSTEPS && first_bad < 0; step = step + 1) begin
            sample_idx = step % 200; train_en = 1; @(negedge clk);
            cyc0 = $time;
            start = 1; @(negedge clk); start = 0;
            wait_done;
            if (step == 0)
                $display("step0: logit0=%0d logit1=%0d d=%0d p1=%0d dz2=(%0d,%0d)  cycles=%0d",
                         dut.logit0, dut.logit1, dut.d, dut.p1, dut.dz2_0, dut.dz2_1, ($time-cyc0)/10);
            for (i = 0; i < 38; i = i + 1) begin
                got = dut.par[i]; exp = ref_log[step*38 + i];
                if (got !== exp) begin
                    if (first_bad < 0) first_bad = step;
                    errors = errors + 1;
                    $display("MISMATCH step %0d param %0d : got %0d expected %0d", step, i, got, exp);
                end
            end
            if (step % 50 == 0 && first_bad < 0) $display("step %0d OK", step);
        end

        if (errors == 0) $display("PASS: %0d steps bit-exact (all 38 params after every step)", NSTEPS);
        else             $display("FAIL: %0d mismatches, first bad step = %0d", errors, first_bad);
        $finish;
    end

    initial begin #2000000000; $display("TIMEOUT"); $finish; end
endmodule
