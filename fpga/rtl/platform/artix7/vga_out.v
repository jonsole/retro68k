// VGA through the KS3's ADV7125 DAC, as the Next drives it: 4 pins per
// colour at double rate. The low 4 bits go out in the first half of each
// pixel and are latched by a 74ALVC574 on vgaclkn; the high 4 bits go out
// in the second half, and vgaclk makes the ADV7125 take all 8 bits. The
// data is clocked 3 ns after the pixel clock for the DAC's hold time.
module vga_out (
    input  wire        clk_pix,
    input  wire        clk_pixd,     // clk_pix, 3 ns later
    input  wire [23:0] rgb,
    input  wire        hsync, vsync,
    output wire [3:0]  r, g, b,
    output wire        hs, vs,
    output wire        vgaclk, vgaclkn
);
    // Half a pixel of setup into the delayed clock's registers
    reg [23:0] rgb_n;
    reg        hs_n, vs_n;
    always @(negedge clk_pix) begin
        rgb_n <= rgb;
        hs_n  <= hsync;
        vs_n  <= vsync;
    end

    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b1), .SRTYPE("SYNC")) o_clk
        (.Q(vgaclk),  .C(clk_pix), .CE(1'b1), .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b1), .SRTYPE("SYNC")) o_clkn
        (.Q(vgaclkn), .C(clk_pix), .CE(1'b1), .D1(1'b0), .D2(1'b1), .R(1'b0), .S(1'b0));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b1), .SRTYPE("SYNC")) o_hs
        (.Q(hs), .C(clk_pixd), .CE(1'b1), .D1(hs_n), .D2(hs_n), .R(1'b0), .S(1'b0));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b1), .SRTYPE("SYNC")) o_vs
        (.Q(vs), .C(clk_pixd), .CE(1'b1), .D1(vs_n), .D2(vs_n), .R(1'b0), .S(1'b0));

    genvar i;
    generate for (i = 0; i < 4; i = i + 1) begin : bit
        ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) o_r
            (.Q(r[i]), .C(clk_pixd), .CE(1'b1), .D1(rgb_n[16+i]), .D2(rgb_n[20+i]), .R(1'b0), .S(1'b0));
        ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) o_g
            (.Q(g[i]), .C(clk_pixd), .CE(1'b1), .D1(rgb_n[8+i]),  .D2(rgb_n[12+i]), .R(1'b0), .S(1'b0));
        ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) o_b
            (.Q(b[i]), .C(clk_pixd), .CE(1'b1), .D1(rgb_n[0+i]),  .D2(rgb_n[4+i]),  .R(1'b0), .S(1'b0));
    end endgenerate
endmodule
