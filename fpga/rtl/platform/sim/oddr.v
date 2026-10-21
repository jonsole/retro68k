// Behavioural DDR output register, like Artix-7 ODDR in SAME_EDGE mode:
// q shows d_r for the first half of the clock and d_f for the second half.
// The 1 ns delay stands in for the output pad's clock-to-out time.
`timescale 1ns/1ps
module oddr #(parameter W = 1, parameter [W-1:0] INIT = 0) (
    input  wire         clk,
    input  wire [W-1:0] d_r,
    input  wire [W-1:0] d_f,
    output reg  [W-1:0] q
);
    reg [W-1:0] hold_f;
    initial q = INIT;
    always @(posedge clk) begin
        q      <= #1 d_r;
        hold_f <= d_f;
    end
    always @(negedge clk) q <= #1 hold_f;
endmodule
