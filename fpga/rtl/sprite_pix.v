// One sprite unit, pixel side (spec 9, section 6).
// At the sprite's first pixel on the line it takes the line's settings
// (worked out at the fetch point by sprites.v) and then draws from the
// unit's line buffer: 2, 4 or 8 bpp, 16/32/64 source pixels, 1x-4x
// scaling, horizontal flip, clipping at the left edge (acc0).
module sprite_pix (
    input  wire        clk_pix,
    input  wire        en,             // video on
    input  wire [10:0] hn,             // the next pixel's position
    input  wire        bank,           // this line's buffer bank

    // Settings of the line that starts at the next pixel's bank (see sprites.v)
    input  wire        s_valid,        // a sprite was picked for this unit
    input  wire        s_done,         // its data has arrived
    input  wire [10:0] s_xstart,       // first visible pixel
    input  wire [15:0] s_acc0,         // source position there (clipped part skipped), 8.8
    input  wire [15:0] s_hstep,
    input  wire [6:0]  s_width,        // 16, 32 or 64 source pixels
    input  wire [1:0]  s_lb,           // log2 of bits per pixel: 1, 2, 3
    input  wire        s_hflip,
    input  wire [5:0]  s_palofs,
    input  wire [2:0]  s_depth,
    input  wire [15:0] s_coll,         // sprite number 15-10, HITLAYERS 9-6, HITGROUPS 5-2, GROUP 1-0

    // Line buffer, read without a clock
    output wire [4:0]  rd_addr,        // {bank, word}
    input  wire [15:0] rd_data,

    // This pixel (registered)
    output reg         opaque,
    output reg  [9:0]  idx,
    output reg  [2:0]  depth,
    output reg  [15:0] coll,           // s_coll of the sprite being drawn
    output reg         miss_t          // toggles when a sprite's data was late
);
    reg        on;
    reg [15:0] acc;
    reg [15:0] hstep;
    reg [6:0]  width;
    reg [1:0]  lb;
    reg        hflip;
    reg [5:0]  palofs;

    // The pixel at acc
    wire [7:0]  src   = acc[15:8];
    wire        inside = on && (src < {1'b0, width});
    wire [5:0]  sp    = hflip ? (width[5:0] - 1'b1 - src[5:0]) : src[5:0];
    // word and field: 8 pixels a word at 2 bpp, 4 at 4 bpp, 2 at 8 bpp; first pixel in the top bits
    wire [3:0]  word  = (lb == 2'd1) ? {1'b0, sp[5:3]} : (lb == 2'd2) ? sp[5:2] : sp[4:1];
    assign      rd_addr = {bank, word};
    wire [1:0]  f2 = rd_data[2*(7 - sp[2:0]) +: 2];
    wire [3:0]  f4 = rd_data[4*(3 - sp[1:0]) +: 4];
    wire [7:0]  f8 = sp[0] ? rd_data[7:0] : rd_data[15:8];
    wire [7:0]  value = (lb == 2'd1) ? {6'd0, f2} : (lb == 2'd2) ? {4'd0, f4} : f8;

    always @(posedge clk_pix) begin
        if (!en) begin
            on      <= 1'b0;
            opaque  <= 1'b0;
            miss_t  <= 1'b0;
        end else begin
            opaque <= inside && value != 8'd0;
            idx    <= {palofs, 4'd0} + value;
            if (hn == s_xstart && s_valid) begin
                // The sprite starts at the next pixel
                on     <= s_done;
                if (!s_done) miss_t <= ~miss_t;
                acc    <= s_acc0;
                hstep  <= s_hstep;
                width  <= s_width;
                lb     <= s_lb;
                hflip  <= s_hflip;
                palofs <= s_palofs;
                depth  <= s_depth;
                coll   <= s_coll;
            end else begin
                acc <= acc + hstep;
                if ((on && !inside) || hn == 11'd0) on <= 1'b0;    // done, or a new line
            end
        end
    end
endmodule
