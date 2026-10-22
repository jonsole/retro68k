// One bitmap layer, pixel side (spec 4, sections 4.2-4.6 and 5.1).
//
// Eight 16-bit shifters, loaded all at once from the layer's BPLxDAT
// registers (bpldma.v). The first group of a line is taken as soon as it
// is complete, in the horizontal blank (so the DMA fetches the second one
// before the window starts); after that, each time a group is used up. If
// BPL0DAT has not been written by then, the layer shows transparent pixels
// for that group (OVERRUN).
//
// A group is always 16 source pixels:
//   planar: one word from each of 1-8 planes, leftmost pixel in bit 15
//   chunky: 1, 2, 4 or 8 consecutive words (bits per pixel), packed pixels,
//           leftmost pixel in the top bits of the first word, which is in
//           the highest data register used (BPL0DAT holds the last word)
//
// Scaling repeats each source pixel 1, 2, 4 or 8 times.
module layer_pix (
    input  wire         clk_pix,
    input  wire         clk_pix5,      // 5 x clk_pix, edges lined up (same MMCM): for the fast synchroniser
    input  wire         en,            // video on
    input  wire [10:0]  hc,            // beam, and the next pixel's position
    input  wire [10:0]  hn,
    input  wire         line_start,    // start of horizontal blank: a new line's setup begins
    input  wire         ready,         // the data registers hold this line's data (after the DMA restarted)

    // This line's settings (from video.v, stable through the line)
    input  wire         active,        // the layer shows on this line
    input  wire [10:0]  xs, xe,        // window
    input  wire         planar,
    input  wire [1:0]   lb,            // chunky: log2 of bits per pixel
    input  wire [2:0]   planes,        // planar: planes - 1
    input  wire [1:0]   hs,            // log2 of the horizontal scale
    input  wire [3:0]   pos0,          // first pixel in the first group (fine scroll)
    input  wire         transp,
    input  wire [3:0]   palofs,

    // The data registers, and the full / taken handshake (toggles)
    input  wire [127:0] dat,           // BPL0DAT in the lowest 16 bits
    input  wire         fill_t,        // from the 100 MHz side
    output reg          take_t,

    // This pixel
    output reg          opaque,
    output reg  [7:0]   idx,
    output reg  [7:0]   raw,           // the pixel value itself (direct colour)
    output reg          overrun_t      // toggles when a group was missing
);
    // "Full" from the 100 MHz side, through two flip-flops at 135 MHz rather
    // than 27: about 15-22 ns instead of up to 111 ns (spec 4, section 5.6).
    // The second stage is then read by the pixel side as a related clock.
    reg  [1:0]  fill_s;
    always @(posedge clk_pix5) fill_s <= {fill_s[0], fill_t};
    wire        avail  = fill_s[1] != take_t;
    wire        in_win = active && (hc >= xs) && (hc < xe);

    reg  [15:0] sh [0:7];              // shifters
    reg         ok;                    // the current group arrived
    reg         primed;                // the line's first group is in the shifters
    reg  [3:0]  pos;                   // pixel in the group
    reg  [2:0]  hsub;                  // screen pixels shown of this source pixel

    // The pixel at pos
    wire [4:0]  bpp   = 5'd1 << lb;
    wire [6:0]  bitp  = {3'd0, pos} << lb;                 // chunky: bit of the pixel in the group
    wire [2:0]  wi    = ((3'd1 << lb) - 1'b1) - bitp[6:4]; // ... and its data register
    wire [15:0] cw    = sh[wi] << bitp[3:0];
    reg  [7:0]  value;
    always @(*) begin : px
        integer p;
        if (planar) begin
            for (p = 0; p < 8; p = p + 1)
                value[p] = (p <= planes) ? sh[p][4'd15 - pos] : 1'b0;
        end else
            value = cw[15:8] >> (5'd8 - bpp);
    end
    wire deep = planar ? planes[2] : (lb == 2'd3);         // more than 4 bits: no palette offset

    // Moving on by one source pixel
    wire [4:0]  np    = pos + 1'b1;
    wire        last  = np[4];                             // the group is used up
    wire        step  = (hsub == (3'd7 >> (2'd3 - hs)));   // last screen pixel of this source pixel
    wire        first = active && (hn == xs);              // the window starts with the next pixel

    // Load the shifters from the data registers
    task load;
        integer i;
        begin
            if (avail) begin
                for (i = 0; i < 8; i = i + 1) sh[i] <= dat[16*i +: 16];
                take_t <= ~take_t;
                ok     <= 1'b1;
            end else begin
                ok        <= 1'b0;
                overrun_t <= ~overrun_t;
            end
        end
    endtask

    always @(posedge clk_pix) begin
        if (!en) begin
            opaque    <= 1'b0;
            ok        <= 1'b0;
            overrun_t <= 1'b0;
            take_t    <= fill_s[1];        // nothing waiting
            primed    <= 1'b0;
        end else if (line_start) begin
            opaque <= 1'b0;
            ok     <= 1'b0;
            primed <= 1'b0;
        end else begin
            opaque <= in_win && ok && !(transp && value == 8'd0);
            idx    <= deep ? value : {palofs, value[3:0]};
            raw    <= (in_win && ok) ? value : 8'd0;
            if (!primed && ready && avail) begin
                load;                          // the first group, ahead of the window
                primed <= 1'b1;
            end
            if (first) begin
                pos  <= pos0;
                hsub <= 3'd0;
                if (!primed) load;             // (counts as OVERRUN if it is not there)
                primed <= 1'b1;
            end else if (in_win) begin
                if (step) begin
                    hsub <= 3'd0;
                    pos  <= np[3:0];
                    if (last && hn < xe) load;
                end else
                    hsub <= hsub + 1'b1;
            end
        end
    end
endmodule
