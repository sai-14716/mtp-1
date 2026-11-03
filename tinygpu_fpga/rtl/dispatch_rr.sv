`default_nettype none
`timescale 1ns/1ns

// BLOCK DISPATCH (FPGA-scalable variant, drop-in replacement for dispatch.sv)
// > Same interface and behaviour as the stock dispatcher: hands thread blocks to free cores and
//   reports done once every block has finished.
// > The stock version updates blocks_dispatched / blocks_done with blocking "+1" inside a loop over
//   all cores, which builds a serial compare+increment chain whose depth grows with NUM_CORES
//   (8 cores: 30 logic levels, 16 cores: 75 logic levels / 20.8 MHz on Artix-7).
// > This version assigns at most ONE block and retires at most ONE finished block per cycle,
//   chosen with priority encoders (logarithmic depth).  The cost is at most NUM_CORES extra cycles
//   of start-up latency per kernel, negligible next to block run times of hundreds of cycles.
module dispatch #(
    parameter NUM_CORES = 2,
    parameter THREADS_PER_BLOCK = 4
) (
    input wire clk,
    input wire reset,
    input wire start,

    // Kernel Metadata
    input wire [7:0] thread_count,

    // Core States
    input reg [NUM_CORES-1:0] core_done,
    output reg [NUM_CORES-1:0] core_start,
    output reg [NUM_CORES-1:0] core_reset,
    output reg [7:0] core_block_id [NUM_CORES-1:0],
    output reg [$clog2(THREADS_PER_BLOCK):0] core_thread_count [NUM_CORES-1:0],

    // Kernel Execution
    output reg done
);
    localparam CW = (NUM_CORES > 1) ? $clog2(NUM_CORES) : 1;

    reg [7:0] total_blocks;      // registered (thread_count is static while a kernel runs)
    reg [7:0] blocks_dispatched; // How many blocks have been sent to cores?
    reg [7:0] blocks_done;       // How many blocks have finished processing?
    reg start_execution;

    // lowest-numbered core waiting for a block / lowest-numbered core that finished its block
    reg          any_free, any_fin;
    reg [CW-1:0] free_i, fin_i;
    always @* begin
        any_free = 1'b0; free_i = '0;
        any_fin  = 1'b0; fin_i  = '0;
        for (int i = NUM_CORES - 1; i >= 0; i--) begin
            if (core_reset[i])                 begin any_free = 1'b1; free_i = i; end
            if (core_start[i] && core_done[i]) begin any_fin  = 1'b1; fin_i  = i; end
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            done <= 0;
            total_blocks <= 0;
            blocks_dispatched <= 0;
            blocks_done <= 0;
            start_execution <= 0;

            for (int i = 0; i < NUM_CORES; i++) begin
                core_start[i] <= 0;
                core_reset[i] <= 1;
                core_block_id[i] <= 0;
                core_thread_count[i] <= THREADS_PER_BLOCK;
            end
        end else begin
            total_blocks <= (thread_count + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;

            // Detect rising edge of start to trigger execution
            if (start && !start_execution) begin
                start_execution <= 1;
                for (int i = 0; i < NUM_CORES; i++) begin
                    core_reset[i] <= 1;
                end
            end

            if (start_execution) begin
                // If the last block has finished processing, mark this kernel as done executing
                if (blocks_done == total_blocks) begin
                    done <= 1;
                end

                // Take one core out of reset; give it the next block if there is one
                // (a core in reset never has core_start set, so free_i != fin_i)
                if (any_free) begin
                    core_reset[free_i] <= 0;
                    if (blocks_dispatched < total_blocks) begin
                        core_start[free_i] <= 1;
                        core_block_id[free_i] <= blocks_dispatched;
                        core_thread_count[free_i] <= (blocks_dispatched == total_blocks - 1)
                            ? thread_count - (blocks_dispatched * THREADS_PER_BLOCK)
                            : THREADS_PER_BLOCK;
                        blocks_dispatched <= blocks_dispatched + 1;
                    end
                end

                // Retire one finished block: reset that core so it can take the next block
                if (any_fin) begin
                    core_reset[fin_i] <= 1;
                    core_start[fin_i] <= 0;
                    blocks_done <= blocks_done + 1;
                end
            end
        end
    end
endmodule
