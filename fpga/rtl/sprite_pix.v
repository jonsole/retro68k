// One sprite, pixel side (spec 9). Pixel clock domain.
//
// The sprite's line runs from pixel 720 of the line before (x = -144, in
// the horizontal blank) to pixel 719 of its own line, so that a sprite can
// start up to 144 pixels left of the screen: those pixels go by in the
// blank and are not shown. Inside its span the unit takes words from the
// front of its FIFO (sprites.v writes them at the back, at 100 MHz) and
// shows their pixels, scaled by XSTEP: screen pixel i shows source pixel
// floor(i x XSTEP / 2048). Its place in the image is a pixel in the front
// word and a fraction; each screen pixel adds XSTEP, and the words passed
// go (several at once when the sprite is shrunk).
//
// Each line takes exactly the words the fetcher computes for it: a word is
// taken when it is passed, and the word in use after the span's last pixel
// is taken then, used up or not. If the FIFO is empty when a word is
// needed, a DMA sprite underruns: it shows nothing more until the FIFO is
// flushed (each vertical blank). A sprite fed by the CPU (DMA off) just
// shows nothing until a word comes.
module sprite_pix (
    input  wire               clk_pix,
    input  wire               en,              // video on
    input  wire [9:0]         t,               // the place on the sprite's line: 0 at pixel 720 of the line before, 144 at pixel 0

    // This sprite line's settings (from video.v, taken at pixel 719)
    input  wire               act,             // the sprite shows on this line
    input  wire [9:0]         hs,              // first pixel, as t (0-864)
    input  wire [9:0]         xe,              // pixel after the last shown, as t (0-864)
    input  wire [1:0]         lb,              // log2 of bits per pixel: 1, 2, 3
    input  wire [15:0]        xstep,           // source pixels per screen pixel, 5.11 (0x0080-0x8000)
    input  wire [3:0]         pal,
    input  wire               dma,             // fed by the DMA (an underrun hides it)

    // The FIFO: its front word, and the pointers (6 bits: 5 address, 1 lap)
    input  wire [15:0]        head,            // the word at rp (asynchronous read)
    output reg  [5:0]         rp,
    output wire [5:0]         rp_g,            // ... Gray-coded, for the 100 MHz side
    input  wire [5:0]         wp_g,            // the write pointer, Gray-coded, from the 100 MHz side
    input  wire               flush_t,         // toggles: the FIFO was emptied (pointers to 0)
    output reg                flush_ack_t,

    // This pixel (stage 1)
    output reg                opaque,
    output reg  [7:0]         idx,
    output reg                underrun_t
);
    function [5:0] g2b(input [5:0] g);
        integer i;
        begin
            g2b[5] = g[5];
            for (i = 4; i >= 0; i = i - 1) g2b[i] = g2b[i + 1] ^ g[i];
        end
    endfunction
    assign rp_g = rp ^ (rp >> 1);

    reg [5:0] wg1, wg2;
    reg [1:0] fl_s;
    always @(posedge clk_pix) begin
        wg1  <= wp_g;
        wg2  <= wg1;
        fl_s <= {fl_s[0], flush_t};
    end
    wire [5:0] wp    = g2b(wg2);
    wire [5:0] cnt   = wp - rp;
    wire       avail = cnt[5] ? (cnt == 6'd32) : (cnt != 6'd0);   // (more than 32: the reads have passed the writes)

    wire in_span = act && (t >= hs) && (t < xe);
    wire last_px = (t + 1'b1 == xe);

    reg  [2:0]  p;                     // pixel in the word
    reg  [10:0] f;                     // ... and the fraction
    reg         dead;                  // underran: nothing more this frame

    wire [3:0] ppw   = 4'd8 >> (lb - 1'b1);                // pixels per word: 8, 4, 2
    wire [3:0] ppm1  = ppw - 1'b1;
    wire [2:0] pi    = p;                                  // the pixel's place in the word
    wire [1:0] v2    = head[(4'd14 - {pi, 1'b0}) +: 2];
    wire [3:0] v4    = head[(4'd12 - {pi[1:0], 2'b00}) +: 4];
    wire [7:0] v8    = pi[0] ? head[7:0] : head[15:8];
    wire [7:0] value = (lb == 2'd1) ? {6'd0, v2} : (lb == 2'd2) ? {4'd0, v4} : v8;
    // The next place: pixels on from the word's start, the words passed
    wire [16:0] pos  = {3'd0, p, f} + {1'b0, xstep};
    wire [5:0]  npix = pos[16:11];
    wire [10:0] nf   = pos[10:0];
    wire [5:0]  wc   = npix >> (3'd4 - lb);                // pixels per word: 8, 4, 2
    wire [2:0]  np   = npix[2:0] & ppm1[2:0];

    always @(posedge clk_pix) begin
        if (!en) begin
            rp          <= 6'd0;
            p           <= 3'd0;
            f           <= 11'd0;
            dead        <= 1'b0;
            opaque      <= 1'b0;
            flush_ack_t <= fl_s[1];
            underrun_t  <= 1'b0;
        end else if (fl_s[1] != flush_ack_t) begin
            // The FIFO was emptied: start again
            rp          <= 6'd0;
            p           <= 3'd0;
            f           <= 11'd0;
            dead        <= 1'b0;
            opaque      <= 1'b0;
            flush_ack_t <= fl_s[1];
        end else if (in_span && !dead && avail) begin
            opaque <= (value != 8'd0) && (t >= 10'd144);
            idx    <= (lb == 2'd3) ? value : {pal, value[3:0]};
            if (last_px) begin
                // the words passed go, and the one in use, used up or not
                rp <= rp + wc + ((np != 3'd0 || nf != 11'd0) ? 6'd1 : 6'd0);
                p  <= 3'd0;
                f  <= 11'd0;
            end else begin
                rp <= rp + wc;
                p  <= np;
                f  <= nf;
            end
        end else begin
            opaque <= 1'b0;
            if (in_span && !dead && !avail && dma) begin
                dead       <= 1'b1;        // underrun
                underrun_t <= ~underrun_t;
            end
        end
    end
endmodule
