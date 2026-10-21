// Pixel clock for simulation: the 200 MHz master gated to every Nth edge,
// as a BUFGCE would do on the Artix-7 (spec 4, section 3.1).
`timescale 1ns/1ps
module pixclk (
    input  wire       clk200,
    input  wire [3:0] n,
    output wire       clk_pix
);
    reg [3:0] c = 4'd0;
    reg       ce = 1'b0;
    // (an unknown N before reset must not leave the counter unknown)
    always @(posedge clk200)
        if (^c === 1'bx || ^n === 1'bx || c + 1'b1 >= n) c <= 4'd0;
        else c <= c + 1'b1;
    always @(negedge clk200) ce <= (c == 4'd0);    // enable changes while the clock is low
    assign clk_pix = clk200 & ce;
endmodule
