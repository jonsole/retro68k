// One bitmap layer, pixel side (spec 4, sections 4.3-4.6 and 5.1).
// Takes 16-bit words from the front of the layer's buffer and turns them
// into pixels: 1, 2, 4 or 8 bits per pixel, most significant pixel first,
// with SCROLLX and 8.8 horizontal scaling. Words arrive from the fetcher
// (vfetch.v) in the 100 MHz domain; rp and avail cross between the two.
module layer_pix (
    input  wire        clk_pix,
    input  wire        en,             // video on
    input  wire [10:0] hc,             // beam, and the next pixel's position
    input  wire [10:0] hn,
    input  wire        new_line,       // start of horizontal blank: the next line's settings follow

    // This line's settings (copied at new_line by video.v)
    input  wire        active,         // the layer shows on this line
    input  wire [10:0] xs, xe,         // window
    input  wire [15:0] sx,             // SCROLLX
    input  wire [15:0] hstep,
    input  wire [1:0]  lb,             // log2 of bits per pixel
    input  wire [3:0]  pos0,           // bit of the first pixel in the first word
    input  wire        transp,
    input  wire [9:0]  palofs,

    // Buffer
    input  wire [15:0] head,           // the word at rp
    input  wire [5:0]  wp,             // words written by the fetcher (from the 100 MHz side)
    output reg  [5:0]  rp,

    // This pixel
    output reg         opaque,
    output reg  [9:0]  idx,
    output reg         overrun_t       // toggles when the buffer ran dry
);
    reg  [23:0] hacc;
    reg  [3:0]  pos;
    wire [5:0]  avail = wp - rp;
    wire        in_win = active && (hc >= xs) && (hc < xe);

    // Source pixels moved on by the next screen pixel
    wire [23:0] hacc_n = hacc + hstep;
    wire [15:0] d      = hacc_n[23:8] - hacc[23:8];
    wire [5:0]  np     = pos + (d[5:0] << lb);            // budget: at most one word per pixel

    // The pixel at pos
    wire [4:0]  bpp    = 5'd1 << lb;
    wire [4:0]  shift  = 5'd16 - bpp - pos;
    wire [15:0] w      = head >> shift;
    wire [7:0]  mask   = (8'd1 << bpp) - 1'b1;
    wire [7:0]  value  = w[7:0] & mask;

    always @(posedge clk_pix) begin
        if (!en || new_line) begin
            rp <= 6'd0;
        end
        if (!en) begin
            hacc      <= {sx, 8'd0};
            pos       <= pos0;
            opaque    <= 1'b0;
            overrun_t <= 1'b0;
        end else begin
            hacc <= (hn == xs) ? {sx, 8'd0} : hacc_n;
            if (hn == xs) pos <= pos0;

            opaque <= 1'b0;
            if (in_win) begin
                if (avail != 0) begin
                    opaque <= !(transp && value == 8'd0);
                    idx    <= {palofs, 4'd0} + value;
                    if (np >= 6'd16) begin
                        if (!new_line) rp <= rp + 1'b1;
                        pos <= np - 6'd16;
                    end else
                        pos <= np[3:0];
                end else
                    overrun_t <= ~overrun_t;
            end
        end
    end
endmodule
