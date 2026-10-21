// DVI over HDMI on the KS3 (spec 4, section 3.3): three TMDS data pairs and
// the clock pair. Each 10-bit word goes out least significant bit first
// through a 10:1 OSERDESE2 pair (DDR at 5 x the pixel clock).
// Pair order: 0 blue, 1 green, 2 red, 3 clock, as in the Next's own
// hdmi_out_xilinx_a7.vhd (which also sends least significant bit first).
module hdmi_out (
    input  wire       clk_pix,
    input  wire       clk_pix5,
    input  wire       rst,           // synchronous to clk_pix
    input  wire [23:0] rgb,
    input  wire       hsync, vsync,  // active level as sent
    input  wire       de,
    output wire [3:0] tmds_p,
    output wire [3:0] tmds_n
);
    wire [9:0] w [0:3];
    tmds_encoder eb (.clk(clk_pix), .d(rgb[7:0]),   .c({vsync, hsync}), .de(de), .q(w[0]));
    tmds_encoder eg (.clk(clk_pix), .d(rgb[15:8]),  .c(2'b00),          .de(de), .q(w[1]));
    tmds_encoder er (.clk(clk_pix), .d(rgb[23:16]), .c(2'b00),          .de(de), .q(w[2]));
    assign w[3] = 10'b0000011111;

    genvar ch;
    generate for (ch = 0; ch < 4; ch = ch + 1) begin : lane
        wire s1, s2, ser;
        OSERDESE2 #(.DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(10),
                    .SERDES_MODE("MASTER"), .TRISTATE_WIDTH(1), .INIT_OQ(1'b0)) m (
            .OQ(ser), .OFB(), .TQ(), .TFB(), .TBYTEOUT(), .SHIFTOUT1(), .SHIFTOUT2(),
            .CLK(clk_pix5), .CLKDIV(clk_pix),
            .D1(w[ch][0]), .D2(w[ch][1]), .D3(w[ch][2]), .D4(w[ch][3]),
            .D5(w[ch][4]), .D6(w[ch][5]), .D7(w[ch][6]), .D8(w[ch][7]),
            .SHIFTIN1(s1), .SHIFTIN2(s2), .OCE(1'b1), .RST(rst),
            .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0), .TCE(1'b0), .TBYTEIN(1'b0)
        );
        OSERDESE2 #(.DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(10),
                    .SERDES_MODE("SLAVE"), .TRISTATE_WIDTH(1), .INIT_OQ(1'b0)) s (
            .OQ(), .OFB(), .TQ(), .TFB(), .TBYTEOUT(), .SHIFTOUT1(s1), .SHIFTOUT2(s2),
            .CLK(clk_pix5), .CLKDIV(clk_pix),
            .D1(1'b0), .D2(1'b0), .D3(w[ch][8]), .D4(w[ch][9]),
            .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0),
            .SHIFTIN1(1'b0), .SHIFTIN2(1'b0), .OCE(1'b1), .RST(rst),
            .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0), .TCE(1'b0), .TBYTEIN(1'b0)
        );
        OBUFDS #(.IOSTANDARD("TMDS_33")) ob (.I(ser), .O(tmds_p[ch]), .OB(tmds_n[ch]));
    end endgenerate
endmodule
