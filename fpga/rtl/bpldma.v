// Bitplane DMA and the bitplane registers (spec 4, sections 4.4 and 5).
// 100 MHz domain.
//
// As on the Amiga, each plane of each layer has a pointer BPLxPT, which
// counts up as words are fetched, and a data register BPLxDAT. There are no
// other buffers: a layer's data registers hold its next 16-pixel group
// while its shifters (layer_pix.v) show the current one.
//
// A layer is "full" once its group is complete: when the DMA has fetched
// the last of the planes it fetches (high to low), or, for a layer with no
// DMA, when the CPU or copper writes BPL0DAT. Planes whose DMA is off
// (BPLDMA) keep their data register's value, which the shifters take again
// every group. The
// pixel side then takes the group into its shifters when it needs it, and
// the DMA fetches the next group. Full and taken cross between the clock
// domains as toggles (fill_t here, take_t there).
//
// The DMA uses the display's memory cycles (1 and 3 of each slot). Each
// word goes to the layer whose deadline is nearest (earliest deadline
// first): when a layer's shifters take a group, its countdown loads the
// time that group lasts (16 source pixels, about 59 system clocks x the
// horizontal scale). Layers with equal countdowns take turns.
//
// Line by line: at line_go (start of horizontal blank, from the pixel
// domain) the next line's fetch starts. Each word fetched moves its pointer
// on by 2. The line's first word from a pointer saves the pointer (the
// line's start); its last word sets the pointer to that start + BPLSTRIDE,
// or back to the start on a repeated line of a vertically scaled layer. So
// how many words are fetched (whole groups, fine scroll) never matters, and
// every pointer move goes through the one fetch path: a CPU or copper write
// in the same clock wins, and also sets the saved start.
`include "regmap.vh"

module bpldma (
    input  wire         clk,
    input  wire         rst,
    input  wire         enable,        // video on, DMACON.DMAEN and BPLEN

    input  wire         rb_rd,
    input  wire         rb_wr,
    input  wire [23:2]  rb_addr,
    input  wire [31:0]  rb_wdata,
    input  wire [3:0]   rb_be,
    output reg  [31:0]  rb_rdata,

    // The next line, from the pixel domain (stable when line_t toggles)
    input  wire         line_t,
    input  wire [2:0]   act,           // the layer shows on the next line
    input  wire [2:0]   adv,           // ... and its pointers move on after it (last copy of a source line)
    input  wire [8:0]   planes,        // 3 x 3 bits: words per group - 1 (planes, or chunky bits per pixel)
    input  wire [2:0]   chunky,        // the layer's words all come from BPL0PT
    input  wire [5:0]   hscale,        // 3 x 2 bits: log2 of the horizontal scale (for the deadlines)
    input  wire [11:0]  wrap,          // 3 x 4 bits: CTRL.WRAP: 0 off, n = pointers wrap in 2^(n+9) bytes
    input  wire [35:0]  ngroups,       // 3 x 12: groups to fetch
    output wire         line_go,       // 1 clock: a new line started here
    output wire         line_gen,      // toggles with line_go

    // To and from the pixel domain
    output wire [383:0] dat,           // 3 layers x 8 planes x 16 bits, layer 0 plane 0 lowest
    output reg  [2:0]   fill_t,
    input  wire [2:0]   take_t,

    // SRAM controller display port
    output reg          req,
    output wire         urgent,        // req must not wait: may take the CPU's cycle 0
    output wire [9:0]   deadline,      // system clocks until req's data is needed (for the scheduler)
    output reg  [21:1]  addr,
    input  wire         ack,
    input  wire         rvalid,
    input  wire [15:0]  rdata
);
    // ---------------------------------------------------------------- registers
    wire [15:0] off = {rb_addr[15:2], 2'b00};
    // Layers at 0x100 + n x 0x80: BPLMOD +0x10, BPLxPT +0x20, BPLxDAT +0x40
    wire [8:0]  blk = off[15:7];                           // 2, 3, 4 for layers 0, 1, 2
    wire [1:0]  rn  = blk[1:0] - 2'd2;
    wire        sel = (rb_addr[23:16] == 8'hE0) && (blk >= 9'd2) && (blk <= 9'd4);
    wire        sel_mod = sel && off[6:0] == 7'h10;
    wire        sel_dma = sel && off[6:0] == 7'h14;
    wire        sel_pt  = sel && off[6:5] == 2'b01;
    wire        sel_dat = sel && off[6:5] == 2'b10;
    wire [4:0]  ri      = {rn, off[4:2]};                  // layer x 8 + plane

    reg  [22:0] pt  [0:23];            // BPLxPT (a small RAM, below)
    reg  [15:0] dr  [0:23];
    reg  [15:0] mod [0:2];             // BPLSTRIDE
    reg  [7:0]  pm  [0:2];             // BPLDMA: DMA enable per plane (chunky: bit 0 for the layer)

    // Pointer wrap (spec 4, section 4.4): only the bits below the region size
    // change; the region is aligned to its size
    wire [22:0] wmask [0:2];
    genvar g;
    generate for (g = 0; g < 3; g = g + 1) begin : wraps
        assign wmask[g] = (wrap[4*g +: 4] == 4'd0) ? 23'h7FFFFF
                        : ~(23'h7FFFFF << ({1'b0, wrap[4*g +: 4]} + 5'd9));
    end endgenerate
    function [22:0] wadd(input [22:0] p, input [22:0] d, input [22:0] m);
        wadd = (p & ~m) | ((p + d) & m);
    endfunction
    generate for (g = 0; g < 24; g = g + 1) begin : dout
        assign dat[16*g +: 16] = dr[g];
    end endgenerate

    // ---------------------------------------------------------------- fetch state
    reg  [1:0]  line_s;
    assign line_go = line_s[1] != line_s[0];
    reg  [2:0]  gen;
    assign line_gen = gen[0];
    reg  [2:0]  take_s1, take_s2, take_s3;
    wire [2:0]  full = fill_t ^ take_s2;

    reg  [11:0] left   [0:2];          // groups still to start
    reg  [11:0] ngr    [0:2];          // groups to fetch on this line
    reg  [2:0]  firstg, lastg;         // the group being fetched is the line's first, last
    reg  [7:0]  rem    [0:2];          // data registers of the current group still to ask for
    reg  [2:0]  busy;                  // a group is on its way (until its last word arrives)
    // The line being fetched
    reg  [2:0]  pv_adv;                // its pointers move on after it (else back to its start)

    // Reads on the way: layer, data register, last word of its group, generation
    reg  [1:0]  q_layer [0:3];
    reg  [2:0]  q_plane [0:3];
    reg         q_last  [0:3];
    reg         q_gen   [0:3];
    reg  [1:0]  q_h, q_t;

    // The data registers the DMA fills for each layer: its planes with DMA on
    // (chunky: all its words, if bit 0 is on). The others keep what the CPU
    // or copper last wrote, and the shifters take that every group.
    reg  [7:0]  emask [0:2];
    reg  [2:0]  has_dma;
    always @(*) begin : masks
        integer m;
        reg [7:0] used;
        for (m = 0; m < 3; m = m + 1) begin
            used     = 8'hFF >> (3'd7 - planes[3*m +: 3]);
            emask[m] = chunky[m] ? (pm[m][0] ? used : 8'd0) : (pm[m] & used);
            has_dma[m] = enable && (emask[m] != 8'd0);
        end
    end
    function [2:0] top(input [7:0] v);                 // highest set bit
        integer b;
        begin
            top = 3'd0;
            for (b = 0; b < 8; b = b + 1) if (v[b]) top = b;
        end
    endfunction

    // Deadlines: system clocks until each layer's shifters use up the group
    // they took last, so the next one must be in by then. The line's first
    // take (the group loaded ahead of the window) sets no deadline: the next
    // one is not needed until the window has started.
    reg  [9:0]  dl [0:2];
    reg  [2:0]  first_take;
    reg  [1:0]  req_layer;
    function [3:0] ones(input [7:0] v);
        integer b;
        begin
            ones = 4'd0;
            for (b = 0; b < 8; b = b + 1) ones = ones + v[b];
        end
    endfunction
    // A request is urgent when its layer's deadline is close: the words
    // still to come at 50 ns each, plus about 140 ns for the read and the
    // crossing back. Then it takes the CPU's cycle 0 too (spec 4, 5.6).
    wire [3:0]  words_left = ones(rem[req_layer]) + 1'b1;
    assign      urgent = req && (dl[req_layer] < 10'd14 + {words_left, 2'b00} + words_left);
    assign      deadline = dl[req_layer];

    // Who asks next: of the layers with a group being asked for, or able to
    // start one, the one with the nearest deadline; on a tie, the next after
    // the last one served
    reg  [2:0]  want;
    reg  [1:0]  pick, last;
    integer n;
    always @(*) begin : choose
        integer o;
        reg [1:0] c;
        reg       found;
        for (n = 0; n < 3; n = n + 1)
            want[n] = (rem[n] != 0) || (left[n] != 0 && !busy[n] && !full[n] && emask[n] != 8'd0);
        found = 1'b0;
        pick  = 2'd0;
        c     = last;
        for (o = 1; o <= 3; o = o + 1) begin
            c = (c == 2'd2) ? 2'd0 : c + 1'b1;        // round-robin order after the last
            if (want[c] && (!found || dl[c] < dl[pick])) begin
                found = 1'b1;
                pick  = c;
            end
        end
    end
    // The data register to fill next: high to low
    wire        gstart  = (rem[pick] == 8'd0);                     // a new group
    wire [7:0]  gmask   = gstart ? emask[pick] : rem[pick];
    wire [2:0]  pl_n    = top(gmask);
    wire [7:0]  rem_n   = gmask & ~(8'd1 << pl_n);
    wire [4:0]  di      = {pick, pl_n};                            // data register
    wire [4:0]  pi      = {pick, chunky[pick] ? 3'd0 : pl_n};      // pointer

    // The line's first and last words from each pointer (a chunky layer
    // fetches all its words from BPL0PT: its first word of the first group,
    // its last of the last group)
    wire        first_g = gstart ? (left[pick] == ngr[pick]) : firstg[pick];
    wire        last_g  = gstart ? (left[pick] == 12'd1)     : lastg[pick];
    wire        first_w = first_g && (!chunky[pick] || gstart);
    wire        last_w  = last_g  && (!chunky[pick] || rem_n == 8'd0);

    // The plane pointers and their saved line starts, in two small RAMs
    // (distributed RAM: one write port, reads any time). A pointer changes
    // only when the DMA asks for a word from it, or when the CPU or copper
    // writes it: a write has the RAMs to itself for that clock (the fetch
    // waits one clock), wins, and sets the saved start too.
    reg  [22:0] svm [0:23];
    integer k;
    initial for (k = 0; k < 24; k = k + 1) begin pt[k] = 23'd0; svm[k] = 23'd0; end
    wire        cpu_pw   = rb_wr && sel_pt;
    wire [22:0] cpu_old  = pt[ri];
    wire [22:0] cpu_new  = {rb_be[2] ? rb_wdata[22:16] : cpu_old[22:16], rb_be[1] ? rb_wdata[15:8] : cpu_old[15:8],
                            rb_be[0] ? rb_wdata[7:1] : cpu_old[7:1], 1'b0};
    wire        fetch_go = !rst && !line_go && !cpu_pw && (!req || ack) && |want;
    wire [22:0] pt_cur   = pt[pi];
    wire [22:0] start    = first_w ? pt_cur : svm[pi];       // this line's start
    wire [22:0] stride   = pv_adv[pick] ? {{7{mod[pick][15]}}, mod[pick]} : 23'd0;
    wire [22:0] pt_next  = last_w ? wadd(start, stride, wmask[pick]) : wadd(pt_cur, 23'd2, wmask[pick]);
    always @(posedge clk) begin
        if (cpu_pw) begin
            pt[ri]  <= cpu_new;
            svm[ri] <= cpu_new;
        end else if (fetch_go) begin
            pt[pi] <= pt_next;
            if (first_w) svm[pi] <= pt_cur;
        end
    end

    integer i;
    always @(posedge clk) begin
        line_s  <= {line_s[0], line_t};
        take_s1 <= take_t;
        take_s2 <= take_s1;
        take_s3 <= take_s2;
        for (n = 0; n < 3; n = n + 1)
            if (take_s3[n] != take_s2[n]) begin                     // a group was taken
                dl[n] <= first_take[n] ? 10'h3FF : 10'd59 << hscale[2*n +: 2];
                first_take[n] <= 1'b0;
            end else if (dl[n] != 10'd0 && dl[n] != 10'h3FF) dl[n] <= dl[n] - 1'b1;
        if (rst) begin
            req    <= 1'b0;
            last   <= 2'd2;
            q_h    <= 2'd0;
            q_t    <= 2'd0;
            gen    <= 3'd0;
            fill_t <= 3'd0;
            busy   <= 3'd0;
            pv_adv <= 3'd0;
            firstg <= 3'd0;
            lastg  <= 3'd0;
            first_take <= 3'd0;
            req_layer <= 2'd0;
            for (n = 0; n < 3; n = n + 1) begin
                left[n] <= 12'd0;  ngr[n] <= 12'd0;  rem[n] <= 8'd0;  dl[n] <= 10'h3FF;
                mod[n]  <= 16'd0;
                pm[n]   <= 8'hFF;              // every plane's DMA on
            end
            for (i = 0; i < 24; i = i + 1) dr[i] <= 16'd0;
        end else begin
            // Data back from the SRAM
            if (rvalid) begin
                if (q_gen[q_h] == gen[q_layer[q_h]]) begin
                    dr[{q_layer[q_h], q_plane[q_h]}] <= rdata;
                    if (q_last[q_h]) begin
                        fill_t[q_layer[q_h]] <= ~fill_t[q_layer[q_h]];
                        busy[q_layer[q_h]]   <= 1'b0;
                    end
                end
                q_h <= q_h + 1'b1;
            end

            // A request was taken
            if (ack) begin
                req <= 1'b0;
                q_t <= q_t + 1'b1;
            end

            if (line_go) begin
                // Start the next line
                for (n = 0; n < 3; n = n + 1) begin
                    left[n]   <= (has_dma[n] && act[n]) ? ngroups[12*n +: 12] : 12'd0;
                    ngr[n]    <= (has_dma[n] && act[n]) ? ngroups[12*n +: 12] : 12'd0;
                    rem[n]    <= 8'd0;
                    dl[n]     <= 10'h3FF;                     // no deadline until the first in-window take
                    first_take[n] <= 1'b1;
                    fill_t[n] <= take_s2[n];                 // empty: last line's spare group is dropped
                end
                pv_adv <= adv;
                busy   <= 3'd0;
                gen    <= ~gen;
                req    <= 1'b0;
            end else if (fetch_go) begin
                // Ask for the next word
                req        <= 1'b1;
                req_layer  <= pick;
                last       <= pick;
                addr       <= pt_cur[21:1];
                rem[pick]  <= rem_n;
                if (gstart) begin
                    left[pick]   <= left[pick] - 1'b1;
                    firstg[pick] <= (left[pick] == ngr[pick]);
                    lastg[pick]  <= (left[pick] == 12'd1);
                    busy[pick]   <= 1'b1;
                end
                q_layer[q_t + (ack ? 1'b1 : 1'b0)] <= pick;
                q_plane[q_t + (ack ? 1'b1 : 1'b0)] <= di[2:0];
                q_last[q_t + (ack ? 1'b1 : 1'b0)]  <= (rem_n == 8'd0);
                q_gen[q_t + (ack ? 1'b1 : 1'b0)]   <= gen[pick];
            end

            // CPU (and later copper) writes win over the DMA's own changes
            if (rb_wr && sel_mod) begin
                if (rb_be[1]) mod[rn][15:8] <= rb_wdata[15:8];
                if (rb_be[0]) mod[rn][7:1]  <= rb_wdata[7:1];
                mod[rn][0] <= 1'b0;
            end
            if (rb_wr && sel_dat) begin
                if (rb_be[1]) dr[ri][15:8] <= rb_wdata[15:8];
                if (rb_be[0]) dr[ri][7:0]  <= rb_wdata[7:0];
                // With no DMA for the layer, writing BPL0DAT makes the group complete (spec 4, 5.1)
                if (off[4:2] == 3'd0 && rb_be[0] && !has_dma[rn]) fill_t[rn] <= ~take_s2[rn];
            end
            if (rb_wr && sel_dma && rb_be[1:0] == 2'b11) begin     // set/clear (spec 3, rule 6)
                if (rb_wdata[15]) pm[rn] <= pm[rn] |  rb_wdata[7:0];
                else              pm[rn] <= pm[rn] & ~rb_wdata[7:0];
            end
        end

        rb_rdata <= 32'd0;
        if (rb_rd) begin
            if (sel_mod) rb_rdata <= {16'd0, mod[rn]};
            if (sel_dma) rb_rdata <= {24'd0, pm[rn]};
            if (sel_pt)  rb_rdata <= {9'd0, pt[ri]};
            if (sel_dat) rb_rdata <= {16'd0, dr[ri]};
        end
    end
endmodule
