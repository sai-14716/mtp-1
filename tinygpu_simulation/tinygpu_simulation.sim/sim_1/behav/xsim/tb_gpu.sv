`default_nettype none
`timescale 1ns/1ns

module tb_gpu;

    // Clock and reset
    logic clk;
    logic reset;

    // Kernel Execution
    logic start;
    logic done;

    // Device Control Register
    logic device_control_write_enable;
    logic [7:0] device_control_data;

    // Program Memory (1 channel) - packed arrays to match DUT
    logic [0:0] program_mem_read_valid;
    logic [7:0] program_mem_read_address [0:0];
    logic [0:0] program_mem_read_ready;
    logic [15:0] program_mem_read_data [0:0];

    // Data Memory (4 channels) - unpacked arrays to match DUT
    logic [3:0] data_mem_read_valid;
    logic [7:0] data_mem_read_address [3:0];
    logic [3:0] data_mem_read_ready;
    logic [7:0] data_mem_read_data [3:0];
    logic [3:0] data_mem_write_valid;
    logic [7:0] data_mem_write_address [3:0];
    logic [7:0] data_mem_write_data [3:0];
    logic [3:0] data_mem_write_ready;

    // Memory arrays
    logic [15:0] program_memory [0:255];
    logic [7:0] data_memory [0:255];

    // Test program: simple matrix add
    // R0 = blockIdx * blockDim + threadIdx
    // R1 = baseA (0)
    // R2 = baseB (8)
    // R3 = baseC (16)
    // R4 = baseA + i
    // R4 = load A[i]
    // R5 = baseB + i
    // R5 = load B[i]
    // R6 = R4 + R5
    // R7 = baseC + i
    // store R7, R6
    // RET
    initial begin
        // Program memory
        program_memory[0]  = 16'b0101000011011110; // MUL R0, %blockIdx, %blockDim
        program_memory[1]  = 16'b0011000000001111; // ADD R0, R0, %threadIdx
        program_memory[2]  = 16'b1001000100000000; // CONST R1, #0
        program_memory[3]  = 16'b1001001000001000; // CONST R2, #8
        program_memory[4]  = 16'b1001001100010000; // CONST R3, #16
        program_memory[5]  = 16'b0011010000010000; // ADD R4, R1, R0
        program_memory[6]  = 16'b0111010001000000; // LDR R4, R4
        program_memory[7]  = 16'b0011010100100000; // ADD R5, R2, R0
        program_memory[8]  = 16'b0111010101010000; // LDR R5, R5
        program_memory[9]  = 16'b0011011001000101; // ADD R6, R4, R5
        program_memory[10] = 16'b0011011100110000; // ADD R7, R3, R0
        program_memory[11] = 16'b1000000001110110; // STR R7, R6
        program_memory[12] = 16'b1111000000000000; // RET

        // Data memory
        // Matrix A (0-7): 0, 1, 2, 3, 4, 5, 6, 7
        // Matrix B (8-15): 0, 1, 2, 3, 4, 5, 6, 7
        // Matrix C (16-23): results
        data_memory[0]  = 8'd0;  data_memory[1]  = 8'd1;
        data_memory[2]  = 8'd2;  data_memory[3]  = 8'd3;
        data_memory[4]  = 8'd4;  data_memory[5]  = 8'd5;
        data_memory[6]  = 8'd6;  data_memory[7]  = 8'd7;
        data_memory[8]  = 8'd0;  data_memory[9]  = 8'd1;
        data_memory[10] = 8'd2;  data_memory[11] = 8'd3;
        data_memory[12] = 8'd4;  data_memory[13] = 8'd5;
        data_memory[14] = 8'd6;  data_memory[15] = 8'd7;
    end

    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz
    end

    // Program memory model
    always_ff @(posedge clk) begin
        if (reset) begin
            program_mem_read_ready <= '0;
            program_mem_read_data[0] <= '0;
        end else begin
            if (program_mem_read_valid[0]) begin
                program_mem_read_ready[0] <= 1;
                program_mem_read_data[0] <= program_memory[program_mem_read_address[0]];
            end else begin
                program_mem_read_ready[0] <= 0;
            end
        end
    end

    // Data memory model
    always_ff @(posedge clk) begin
        if (reset) begin
            data_mem_read_ready <= '0;
            data_mem_write_ready <= '0;
            for (int i = 0; i < 4; i++) begin
                data_mem_read_data[i] <= '0;
            end
        end else begin
            // Read
            if (|data_mem_read_valid) begin
                data_mem_read_ready <= data_mem_read_valid;
                for (int i = 0; i < 4; i++) begin
                    if (data_mem_read_valid[i]) begin
                        data_mem_read_data[i] <= data_memory[data_mem_read_address[i]];
                    end
                end
            end else begin
                data_mem_read_ready <= '0;
            end

            // Write
            if (|data_mem_write_valid) begin
                data_mem_write_ready <= data_mem_write_valid;
                for (int i = 0; i < 4; i++) begin
                    if (data_mem_write_valid[i]) begin
                        data_memory[data_mem_write_address[i]] <= data_mem_write_data[i];
                    end
                end
            end else begin
                data_mem_write_ready <= '0;
            end
        end
    end

    // DUT
    gpu #(
        .DATA_MEM_ADDR_BITS(8),
        .DATA_MEM_DATA_BITS(8),
        .DATA_MEM_NUM_CHANNELS(4),
        .PROGRAM_MEM_ADDR_BITS(8),
        .PROGRAM_MEM_DATA_BITS(16),
        .PROGRAM_MEM_NUM_CHANNELS(1),
        .NUM_CORES(2),
        .THREADS_PER_BLOCK(4)
    ) dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .done(done),
        .device_control_write_enable(device_control_write_enable),
        .device_control_data(device_control_data),
        .program_mem_read_valid(program_mem_read_valid),
        .program_mem_read_address(program_mem_read_address),
        .program_mem_read_ready(program_mem_read_ready),
        .program_mem_read_data(program_mem_read_data),
        .data_mem_read_valid(data_mem_read_valid),
        .data_mem_read_address(data_mem_read_address),
        .data_mem_read_ready(data_mem_read_ready),
        .data_mem_read_data(data_mem_read_data),
        .data_mem_write_valid(data_mem_write_valid),
        .data_mem_write_address(data_mem_write_address),
        .data_mem_write_data(data_mem_write_data),
        .data_mem_write_ready(data_mem_write_ready)
    );

    
    
    // Test sequence with timeout
    initial begin
        reset = 1;
        start = 0;
        device_control_write_enable = 0;
        device_control_data = 0;

        // Wait a few cycles
        repeat (5) @(posedge clk);

        reset = 0;

        // Configure DCR: 8 threads
        @(posedge clk);
        device_control_write_enable = 1;
        device_control_data = 8;
        @(posedge clk);
        device_control_write_enable = 0;

        // Start GPU
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        // Wait for done with timeout (50000 cycles = 500us at 100MHz)
        repeat (50000) begin
            @(posedge clk);
            if (done) break;
        end

        if (!done) begin
            $display("ERROR: Simulation timed out - done signal never asserted");
            $display("Current state: done=%b", done);
            $display("dispatch_instance.core_done = %b", dut.dispatch_instance.core_done);
            $display("dispatch_instance.core_start = %b", dut.dispatch_instance.core_start);
            $display("thread_count = %d", dut.thread_count);
            $finish;
        end

        // Wait a few more cycles
        repeat (5) @(posedge clk);

        // Display results
        $display("=== Results ===");
        for (int i = 16; i < 24; i++) begin
            $display("data_memory[%0d] = %0d", i, data_memory[i]);
        end

        // Expected: 0, 2, 4, 6, 8, 10, 12, 14
        $display("=== Expected ===");
        for (int i = 0; i < 8; i++) begin
            $display("data_memory[%0d] = %0d", 16+i, i*2);
        end

        $finish;
    end

endmodule