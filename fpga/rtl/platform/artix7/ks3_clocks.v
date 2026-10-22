// All clocks for the KS3 build (spec 4, section 3.1), from the board's
// 50 MHz oscillator through two MMCMs.
//
// MMCM 1: VCO 1000 MHz
//   clk100   100 MHz   (/10)  system, SRAM controller
//   clk40     40 MHz   (/25)  fx68k (a 20 MHz 68000)
// MMCM 2: 50 MHz / 5 x 108 = VCO 1080 MHz, for 576p (CEA-861, 27 MHz)
//   clk_pix   27 MHz   (/40)  pixel clock
//   clk_pix5 135 MHz   (/8)   HDMI serialiser (10 bits per pixel, both edges)
//   clk_pixd  27 MHz, 3 ns late: VGA DAC data (as on the Next)
//
// Both come from the same oscillator, so the frequencies are exact: a 576p
// line (864 pixels) is exactly 3200 system clocks (320 memory slots). The
// phase between the two MMCMs is fixed but unknown, so the video side is
// treated as an asynchronous clock domain.
module ks3_clocks (
    input  wire clk50,
    output wire clk100,
    output wire clk40,
    output wire clk_pix,
    output wire clk_pix5,
    output wire clk_pixd,
    output wire locked
);
    wire clk50_b;
    BUFG b_in (.I(clk50), .O(clk50_b));

    // ---- MMCM 1: system clocks
    wire fb1, fb1_buf, c0, c1, l1;
    MMCME2_BASE #(
        .CLKIN1_PERIOD     (20.0),
        .DIVCLK_DIVIDE     (1),
        .CLKFBOUT_MULT_F   (20.0),          // VCO 1000 MHz
        .CLKOUT0_DIVIDE_F  (10.0),          // 100 MHz
        .CLKOUT1_DIVIDE    (25)             // 40 MHz
    ) mmcm_sys (
        .CLKIN1(clk50_b), .CLKFBIN(fb1_buf), .CLKFBOUT(fb1),
        .CLKOUT0(c0), .CLKOUT1(c1), .CLKOUT2(), .CLKOUT3(), .CLKOUT4(),
        .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(), .CLKFBOUTB(),
        .CLKOUT5(), .CLKOUT6(),
        .LOCKED(l1), .PWRDWN(1'b0), .RST(1'b0)
    );
    BUFG b_fb1 (.I(fb1), .O(fb1_buf));
    BUFG b0    (.I(c0), .O(clk100));
    BUFG b1    (.I(c1), .O(clk40));

    // ---- MMCM 2: 576p pixel clocks
    wire fb2, fb2_buf, p0, p1, p2, l2;
    MMCME2_BASE #(
        .CLKIN1_PERIOD     (20.0),
        .DIVCLK_DIVIDE     (5),             // 10 MHz at the phase detector
        .CLKFBOUT_MULT_F   (108.0),         // VCO 1080 MHz
        .CLKOUT0_DIVIDE_F  (40.0),          // 27 MHz
        .CLKOUT1_DIVIDE    (8),             // 135 MHz
        .CLKOUT2_DIVIDE    (40),            // 27 MHz, delayed
        .CLKOUT2_PHASE     (29.25)          // about 3 ns of 37 ns
    ) mmcm_pix (
        .CLKIN1(clk50_b), .CLKFBIN(fb2_buf), .CLKFBOUT(fb2),
        .CLKOUT0(p0), .CLKOUT1(p1), .CLKOUT2(p2), .CLKOUT3(), .CLKOUT4(),
        .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(), .CLKFBOUTB(),
        .CLKOUT5(), .CLKOUT6(),
        .LOCKED(l2), .PWRDWN(1'b0), .RST(1'b0)
    );
    BUFG b_fb2 (.I(fb2), .O(fb2_buf));
    BUFG b2    (.I(p0), .O(clk_pix));
    BUFG b3    (.I(p1), .O(clk_pix5));
    BUFG b4    (.I(p2), .O(clk_pixd));

    assign locked = l1 && l2;
endmodule
