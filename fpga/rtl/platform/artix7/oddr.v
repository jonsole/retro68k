// DDR output register (Artix-7 ODDR, SAME_EDGE): q shows d_r for the first
// half of the clock and d_f for the second half. Same ports as the
// simulation model in platform/sim/oddr.v.
module oddr #(parameter W = 1, parameter [W-1:0] INIT = 0) (
    input  wire         clk,
    input  wire [W-1:0] d_r,
    input  wire [W-1:0] d_f,
    output wire [W-1:0] q
);
    genvar i;
    generate for (i = 0; i < W; i = i + 1) begin : b
        ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(INIT[i]), .SRTYPE("SYNC")) o (
            .Q(q[i]), .C(clk), .CE(1'b1), .D1(d_r[i]), .D2(d_f[i]), .R(1'b0), .S(1'b0)
        );
    end endgenerate
endmodule
