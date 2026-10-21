// All clocks for the KS3 build from one MMCM (spec 4, section 3.1).
// 50 MHz in, VCO 1000 MHz; every output is the VCO divided by a whole
// number, so all of them start together and keep a fixed phase:
//   clk100   100 MHz   (/10)  system, SRAM controller
//   clk40     40 MHz   (/25)  fx68k (a 20 MHz 68000)
//   clk_pix  200/N MHz (/5N)  pixel clock
//   clk_pix5 1000/N MHz (/N)  HDMI serialiser (10 bits per pixel, both edges)
//   clk_pixd 200/N MHz, 3 ns late: VGA DAC data (as on the Next)
// N is fixed when the FPGA is built (PIX_N); version 1 does not change it at
// run time (VIDSTAT.PCLKLOCK shows whether PCLKDIV matches it).
module ks3_clocks #(
    parameter PIX_N = 8
) (
    input  wire clk50,
    output wire clk100,
    output wire clk40,
    output wire clk_pix,
    output wire clk_pix5,
    output wire clk_pixd,
    output wire locked
);
    wire fb, fb_buf, c0, c1, c2, c3, c4;

    MMCME2_BASE #(
        .CLKIN1_PERIOD     (20.0),
        .DIVCLK_DIVIDE     (1),
        .CLKFBOUT_MULT_F   (20.0),          // VCO 1000 MHz
        .CLKOUT0_DIVIDE_F  (10.0),          // 100 MHz
        .CLKOUT1_DIVIDE    (25),            // 40 MHz
        .CLKOUT2_DIVIDE    (5 * PIX_N),     // pixel
        .CLKOUT3_DIVIDE    (PIX_N),         // 5 x pixel
        .CLKOUT4_DIVIDE    (5 * PIX_N),     // pixel, delayed
        .CLKOUT4_PHASE     (216.0 / PIX_N)  // 3 ns of a 5N ns period
    ) mmcm (
        .CLKIN1(clk50), .CLKFBIN(fb_buf), .CLKFBOUT(fb),
        .CLKOUT0(c0), .CLKOUT1(c1), .CLKOUT2(c2), .CLKOUT3(c3), .CLKOUT4(c4),
        .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(), .CLKFBOUTB(),
        .CLKOUT5(), .CLKOUT6(),
        .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0)
    );

    BUFG b_fb (.I(fb), .O(fb_buf));
    BUFG b0   (.I(c0), .O(clk100));
    BUFG b1   (.I(c1), .O(clk40));
    BUFG b2   (.I(c2), .O(clk_pix));
    BUFG b3   (.I(c3), .O(clk_pix5));
    BUFG b4   (.I(c4), .O(clk_pixd));
endmodule
