`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/10/2026 10:27:14 AM
// Design Name: 
// Module Name: design
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module design(
    parameter LINE_BITS = 256,
    parameter TLB_MAX_ENTRIES = 128
    )(
   input wire a[31:0],
   input wire b[31:0],
   output wire c[31:0]
    );
    
    c = a + b;
endmodule
