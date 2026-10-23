// Sprites, 100 MHz side (spec 9): registers, the fetcher and the FIFOs.
//
// Eight sprites. Each has a pointer into its image (SPRxPT), a window
// (SPRxH, SPRxV) and settings (SPRxCTL), written by the CPU or copper, and
// a 32-word FIFO: its data registers. The fetcher keeps each FIFO filled
// while the sprite's window has lines to come this frame, one word at a
// time through the scheduler's sprite channel (dmac.v), the sprite with the
// nearest deadline first. The pixel side (sprite_pix.v) takes the words.
//
// What one sprite line takes: the words that hold its shown pixels, from
// HSTART to HSTOP or the end of the line (beam pixel 864), whichever
// comes first: wv = ceil(ceil(shown width x XSTEP / 2048) x bpp / 16). An
// image line in memory is wf words: the same for the whole window width.
// The fetcher takes a line's first wv words. At the end of each screen line
// the line's start moves on by k x wf words, k the source lines YSTEP moves
// on (0 when a line shows again); a shared line-advance unit does the
// multiply, holding that sprite's fetches for two clocks.
//
// A sprite starts again at each vertical blank, and when its PT, H, V,
// CTL or STEP is written: its FIFO is emptied (both clock domains agree on it with
// a handshake), reads still on their way are dropped, and fetching
// restarts from the line start.
//
// Deadlines: one shared calculator visits a sprite each clock and works
// out, from the beam, when its FIFO will run dry.
`include "regmap.vh"

module sprites (
    input  wire        clk,
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output reg  [31:0] rb_rdata,

    input  wire [15:0] dmacon,
    input  wire        vblank,         // 1 clock: the vertical blank starts
    input  wire [10:0] beam_v,         // the beam (memory side samples)
    input  wire [10:0] beam_h,

    // Scheduler: the sprite channel
    output reg         mem_req,
    output reg  [21:1] mem_addr,
    output wire [9:0]  mem_deadline,
    output wire        mem_urgent,
    input  wire        mem_ack,
    input  wire        mem_rvalid,
    input  wire [15:0] mem_rdata,

    // To the pixel side: each sprite's settings (read once per line there)
    // Across, beam pixels (0 = the start of the line's horizontal blank,
    // 144 = the picture's first pixel, 863 its last)
    output wire [79:0] p_hs,           // 8 x 10: first pixel (0-864)
    output wire [79:0] p_xe,           // 8 x 10: pixel after the last shown (0-864)
    output wire [87:0] p_vs,           // 8 x 11: first line
    output wire [87:0] p_ve,           // 8 x 11: line after the last, no higher than 625
    output wire [15:0] p_lb,           // 8 x 2: log2 bits per pixel (1-3)
    output wire [127:0] p_xstep,       // 8 x 16: XSTEP, limited (5.11 source pixels per screen pixel)
    output wire [15:0] p_depth,
    output wire [31:0] p_pal,
    output wire [7:0]  p_dma,          // fed by the DMA

    // The FIFOs, between the domains
    input  wire [39:0] fifo_ra,        // 8 x 5: read addresses (pixel side)
    output wire [127:0] fifo_rd,       // 8 x 16: the words there
    output wire [47:0] wp_g,           // 8 x 6: write pointers, Gray-coded
    input  wire [47:0] rp_g,           // 8 x 6: read pointers, Gray-coded (pixel side)
    output reg  [7:0]  flush_t,
    input  wire [7:0]  flush_ack_t,

    // Collisions found on a line (pixel side, stable when coll_t toggles)
    input  wire [31:0] coll_line,
    input  wire        coll_t
);
    integer i;
    genvar g;
    reg [2:0] coll_s;
    always @(posedge clk) coll_s <= {coll_s[1:0], coll_t};

    // ================================================================ registers
    reg  [7:0]  sprdma;
    reg  [31:0] coll;
    // SPRxH, SPRxV, SPRxCTL, SPRxSTEP as written, in distributed RAM (one
    // write a clock: a register write, or clearing one a clock during reset)
    reg  [21:0] m_h [0:7];                     // HSTOP (21-11), HSTART (10-0)
    reg  [21:0] m_v [0:7];                     // VSTOP (21-11), VSTART (10-0)
    reg  [7:0]  m_c [0:7];                     // PAL 7-4, DEPTH 3-2, BPP 1-0
    reg  [31:0] m_s [0:7];                     // YSTEP 31-16, XSTEP 15-0
    // ... and copies of the settings, made by the size calculator below
    reg  [10:0] r_vs [0:7];
    reg  [1:0]  r_bpp [0:7], r_depth [0:7];
    reg  [3:0]  r_pal [0:7];
    reg  [15:0] r_xs [0:7], r_ys [0:7];        // the steps, limited (spec 9, section 3.2)
    function [15:0] lim(input [15:0] s);
        lim = (s == 16'd0) ? 16'h0800 : (s < 16'h0080) ? 16'h0080 : (s > 16'h8000) ? 16'h8000 : s;
    endfunction

    wire [15:0] off   = {rb_addr[15:2], 2'b00};
    wire        in_c  = (rb_addr[23:16] == 8'hE0);
    wire        sel_g = in_c && (off == `RM_SPRDMA || off == `RM_SPRCOLL);
    wire [15:0] so    = off - `RM_SPR_BASE;
    wire        sel_s = in_c && (off >= `RM_SPR_BASE) && (so < 16'h0100) && (so[4:2] <= 3'd5);
    wire [2:0]  sn    = so[7:5];
    wire [2:0]  sr    = so[4:2];               // 0 PT, 1 H, 2 V, 3 CTL, 4 DAT, 5 STEP

    function [31:0] merge(input [31:0] old, input [31:0] new, input [3:0] be);
        merge = { be[3] ? new[31:24] : old[31:24], be[2] ? new[23:16] : old[23:16],
                  be[1] ? new[15:8]  : old[15:8],  be[0] ? new[7:0]   : old[7:0] };
    endfunction

    wire        dma_on = dmacon[`RM_DMACON_DMAEN] && dmacon[`RM_DMACON_SPREN];
    wire [7:0]  active = dma_on ? sprdma : 8'd0;

    // ================================================================ per-sprite sizes
    // Worked out from the registers by one shared calculator, a sprite a
    // clock (cs), and kept in registers. A register write marks its sprite
    // not fresh until the calculator has been round again; a restart waits
    // for that.
    reg  [9:0]  hs_t [0:7], xe_t [0:7];        // the window across, on the line's timeline t
    reg  [10:0] ve_c [0:7];
    reg  signed [3:0] wsh [0:7];               // log2 of screen pixels per word, rounded down (for the deadlines)
    reg  [11:0] wf [0:7], wv [0:7];            // words per image line; per shown line
    reg  [10:0] nl [0:7];                      // screen lines shown
    reg  [7:0]  fresh = 8'd0;
    reg  [2:0]  cs = 3'd0;
    // Three stages, for timing: 1 reads sprite cs's registers and clamps
    // its window; 2 multiplies the widths by XSTEP; 3 works out the word
    // counts (sprite c3). The sprite is fresh after stage 3, unless its
    // registers were written while stage 1 or 2 had it.
    reg  [2:0]  c2, c3;
    reg         ok2, ok3;
    reg  [12:0] wfull2, wshow2;
    reg  [15:0] xs2;
    reg  [10:0] vs2, vec2, vs3, vec3;
    reg  [1:0]  bpp2, bpp3;
    reg  [28:0] pf3, ps3;              // widths x XSTEP
    // log2 of 2048 / XSTEP, rounded down (bigger across: positive)
    function signed [3:0] mag(input [15:0] s);
        integer b, top, m;
        begin
            top = 7;
            for (b = 7; b <= 15; b = b + 1) if (s[b]) top = b;
            m   = (((s & (s - 1'b1)) == 16'd0) ? 11 : 10) - top;    // a power of two exactly, or between
            mag = m;
        end
    endfunction
    always @(posedge clk) begin : sizes
        reg [10:0] hs, he, hsc, xec;
        reg [10:0] vs, ve, vec;
        reg [1:0]  bpp;
        reg [15:0] xs;
        reg [17:0] srcf, srcs;
        reg [20:0] bf, bs;
        // stage 1
        hs = m_h[cs][10:0]; he = m_h[cs][21:11]; vs = m_v[cs][10:0]; ve = m_v[cs][21:11];
        bpp = m_c[cs][1:0];
        xs  = lim(m_s[cs][15:0]);
        r_vs[cs]    <= vs;
        r_bpp[cs]   <= bpp;
        r_depth[cs] <= m_c[cs][3:2];
        r_pal[cs]   <= m_c[cs][7:4];
        r_xs[cs]    <= xs;
        r_ys[cs]    <= lim(m_s[cs][31:16]);
        // all in beam coordinates: the line is beam pixels 0-863, the frame lines 0-624
        hsc   = (hs > 11'd864) ? 11'd864 : hs;
        xec   = (he > 11'd864) ? 11'd864 : (he < hsc) ? hsc : he;
        vec   = (ve > 11'd625) ? 11'd625 : ve;
        hs_t[cs]  <= hsc[9:0];
        xe_t[cs]  <= xec[9:0];
        wsh[cs]   <= $signed({2'b00, 2'd3 - bpp}) + mag(xs);
        ve_c[cs]  <= vec;
        wfull2 <= (he > hs) ? {2'd0, he - hs} : 13'd0;
        wshow2 <= {2'd0, xec - hsc};
        xs2    <= xs;
        vs2    <= vs;
        vec2   <= vec;
        bpp2   <= bpp;
        c2     <= cs;
        ok2    <= !(rb_wr && sel_s && sn == cs);
        cs     <= cs + 1'b1;
        // stage 2
        pf3  <= wfull2 * xs2;
        ps3  <= wshow2 * xs2;
        vs3  <= vs2;
        vec3 <= vec2;
        bpp3 <= bpp2;
        c3   <= c2;
        ok3  <= ok2 && !(rb_wr && sel_s && sn == c2);
        // stage 3: source pixels = ceil(width x XSTEP / 2048), then words
        srcf  = (pf3 + 29'd2047) >> 11;
        srcs  = (ps3 + 29'd2047) >> 11;
        bf    = ({3'd0, srcf} << (bpp3 + 1'b1)) + 21'd15;
        bs    = ({3'd0, srcs} << (bpp3 + 1'b1)) + 21'd15;
        wf[c3]    <= (bf[20:4] > 17'd4095) ? 12'd4095 : bf[15:4];
        wv[c3]    <= (srcs == 18'd0) ? 12'd0 : (bs[20:4] > bf[20:4]) ? ((bf[20:4] > 17'd4095) ? 12'd4095 : bf[15:4])
                                     : (bs[20:4] > 17'd4095) ? 12'd4095 : bs[15:4];
        nl[c3]    <= (vs3 < vec3) ? vec3 - vs3 : 11'd0;
        fresh     <= (fresh | (ok3 ? (8'd1 << c3) : 8'd0)) & ~((rb_wr && sel_s) ? (8'd1 << sn) : 8'd0);
        if (rst) fresh <= 8'd0;            // (cs keeps counting: reset clears the registers one a clock)
    end

    generate for (g = 0; g < 8; g = g + 1) begin : outs
        assign p_hs[10*g +: 10]  = hs_t[g];
        assign p_xe[10*g +: 10]  = xe_t[g];
        assign p_vs[11*g +: 11]  = r_vs[g];
        assign p_ve[11*g +: 11]  = ve_c[g];
        assign p_lb[2*g +: 2]    = r_bpp[g] + 1'b1;
        assign p_xstep[16*g +: 16] = r_xs[g];
        assign p_depth[2*g +: 2] = r_depth[g];
        assign p_pal[4*g +: 4]   = r_pal[g];
        assign p_dma[g]          = active[g];
    end endgenerate

    // ================================================================ FIFOs
    reg  [5:0]  wp [0:7];
    reg  [5:0]  rp_s1 [0:7], rp_s2 [0:7];
    reg  [3:0]  infl [0:7];                    // reads on their way
    function [5:0] g2b(input [5:0] gv);
        integer k;
        begin
            g2b[5] = gv[5];
            for (k = 4; k >= 0; k = k - 1) g2b[k] = g2b[k + 1] ^ gv[k];
        end
    endfunction
    wire [5:0]  cnt [0:7];                     // words in the FIFO
    wire [7:0]  dma_wr, man_wr;                // a word into the FIFO: from memory; from SPRxDAT

    // ================================================================ fetch state
    // Each sprite's place in its image, in distributed RAM (one write a clock):
    // the next word, the line's start (SPRxPT reads it), the words of the
    // line still to fetch, the lines still to fetch (counting this one), and
    // the fraction of YSTEP. Writers, in order: a PT write (the line start),
    // the line-advance unit, a flush done, a word asked for.
    reg  [22:0] m_lst [0:7];
    reg  [22:0] m_ptr [0:7];
    reg  [11:0] m_wl  [0:7];
    reg  [10:0] m_ll  [0:7];
    reg  [10:0] m_yf  [0:7];
    reg  [7:0]  lad;                           // waiting for the line-advance unit
    reg  [7:0]  alive;                         // lines still to fetch this frame
    reg  [7:0]  epoch, flushing;
    reg  [7:0]  fa_s1, fa_s2;
    reg  [6:0]  dl [0:7];                      // deadlines, in units of 8 clocks

    // Restart requests: a register write (this clock) or the vertical blank
    wire        w_reg   = rb_wr && sel_s && sr != 3'd4;          // PT, H, V, CTL, STEP
    wire        w_pt    = rb_wr && sel_s && sr == 3'd0;
    wire [7:0]  restart = (vblank ? 8'hFF : 8'd0) | (w_reg ? (8'd1 << sn) : 8'd0);

    // A flush done: the pixel side has emptied its end, and the sizes are fresh
    wire        la_w;                          // the line-advance unit writes this clock
    wire [7:0]  fdone = flushing & ~(fa_s2 ^ flush_t) & fresh & {8{!la_w}};
    reg  [2:0]  fd;
    always @(*) begin : fdsel
        integer s;
        fd = 3'd0;
        for (s = 7; s >= 0; s = s - 1) if (fdone[s]) fd = s[2:0];
    end
    wire        fd_go = |fdone;

    // Who asks next (a clock ahead): of the sprites that want a word, the
    // nearest deadline, the lower number on a tie. For timing, which
    // sprites want a word is registered first (want), and the pick is a
    // tree of pairs. want is a clock old and the pick a clock ahead, so
    // words for the last two picks may be on their way unseen: a FIFO
    // counts as full two words early. issue checks the state of the moment.
    reg  [7:0]  want;
    reg  [2:0]  pick;
    reg         pick_v;
    reg  [2:0]  pk;                            // the pick, registered
    always @(posedge clk) begin : wants
        integer s;
        for (s = 0; s < 8; s = s + 1)
            want[s] <= !rst && active[s] && !flushing[s] && alive[s] && !lad[s] && ({1'b0, cnt[s]} + infl[s] < 7'd30);
    end
    // one pair: b wins only if it wants a word and a has none or a later deadline
    reg         t1v [0:3], t2v [0:1];
    reg  [2:0]  t1i [0:3], t2i [0:1];
    reg  [6:0]  t1d [0:3], t2d [0:1];
    always @(*) begin : choose
        integer k;
        for (k = 0; k < 4; k = k + 1)
            if (want[2*k+1] && (!want[2*k] || dl[2*k+1] < dl[2*k])) begin
                t1v[k] = 1'b1; t1i[k] = 2*k+1; t1d[k] = dl[2*k+1];
            end else begin
                t1v[k] = want[2*k]; t1i[k] = 2*k; t1d[k] = dl[2*k];
            end
        for (k = 0; k < 2; k = k + 1)
            if (t1v[2*k+1] && (!t1v[2*k] || t1d[2*k+1] < t1d[2*k])) begin
                t2v[k] = 1'b1; t2i[k] = t1i[2*k+1]; t2d[k] = t1d[2*k+1];
            end else begin
                t2v[k] = t1v[2*k]; t2i[k] = t1i[2*k]; t2d[k] = t1d[2*k];
            end
        if (t2v[1] && (!t2v[0] || t2d[1] < t2d[0])) begin
            pick_v = 1'b1; pick = t2i[1];
        end else begin
            pick_v = t2v[0]; pick = t2i[0];
        end
    end
    reg         pk_v;
    reg  [2:0]  req_s;
    assign mem_deadline = {dl[req_s], 3'b000};
    assign mem_urgent   = mem_req && (dl[req_s] < 7'd5);
    wire        issue   = pk_v && active[pk] && !flushing[pk] && alive[pk] && !lad[pk] && !restart[pk]
                          && (!mem_req || mem_ack) && !w_pt && !fd_go && !la_w;

    // The picked sprite's next pointer and line
    wire [22:0] p_cur   = m_ptr[pk];
    wire [22:0] p_lst   = m_lst[pk];
    wire        endline = (m_wl[pk] == 12'd1);
    wire [11:0] y_sum   = {1'b0, m_yf[pk]} + {1'b0, r_ys[pk][10:0]};
    wire [4:0]  y_k     = {1'b0, r_ys[pk][15:11]} + y_sum[11];    // source lines to move on: 0-16

    // The line-advance unit: line start + k x wf words, two clocks after
    // the line's last word is asked for
    reg         la_v1, la_v2;
    reg  [2:0]  la_s;
    reg  [4:0]  la_k;
    reg  [10:0] la_yf;
    reg  [22:0] la_lst;
    reg  [11:0] la_wf;
    reg  [16:0] la_p;
    reg         la_e;                          // the sprite's epoch when it was asked
    assign la_w = la_v2 && !w_pt && la_e == epoch[la_s];   // a PT write has the line-start RAM that clock
    wire [22:0] la_next = la_lst + {5'd0, la_p, 1'b0};

    // The flushed sprite's first word
    wire [22:0] f_lst   = m_lst[fd];
    wire [11:0] f_wv    = wv[fd];

    // Reads on their way: sprite and epoch
    reg  [2:0]  q_s [0:3];
    reg         q_e [0:3];
    reg  [1:0]  q_h, q_t;

    // The FIFOs
    generate for (g = 0; g < 8; g = g + 1) begin : fifos
        reg [15:0] mem [0:31];
        always @(posedge clk) if (dma_wr[g] || man_wr[g]) mem[wp[g][4:0]] <= man_wr[g] ? rb_wdata[15:0] : mem_rdata;
        assign dma_wr[g] = !rst && mem_rvalid && q_s[q_h] == g && q_e[q_h] == epoch[g] && !flushing[g] && !restart[g];
        assign man_wr[g] = !rst && rb_wr && sel_s && sr == 3'd4 && sn == g && rb_be[1:0] == 2'b11
                           && !active[g] && !flushing[g] && cnt[g] < 6'd32;
        assign fifo_rd[16*g +: 16] = mem[fifo_ra[5*g +: 5]];
        assign wp_g[6*g +: 6] = wp[g] ^ (wp[g] >> 1);
        assign cnt[g] = wp[g] - g2b(rp_s2[g]);
    end endgenerate

    // ================================================================ deadlines
    // One sprite a clock (cs): when its FIFO will run dry, in units of 8
    // system clocks (about 3.5 a pixel), counting from the beam. The beam
    // on the sprite's line timeline (t = 0-863) is registered once. Lines
    // are not looked at: a sprite not shown on this line or the next only
    // fills its FIFO a little sooner than it needs to.
    reg  [9:0]  bt, btr;                       // t; 864 - t
    always @(posedge clk) begin
        bt  <= beam_h[9:0];
        btr <= 11'd864 - beam_h;
    end
    wire [2:0]  rr = cs;
    reg  [6:0]  dl_new;
    always @(*) begin : dcalc
        reg [13:0] dpx, tot, wpx;
        reg [11:0] c7;
        if (bt < xe_t[rr])
            dpx = (bt < hs_t[rr]) ? {4'b0, hs_t[rr] - bt} : 14'd0;
        else
            dpx = {4'b0, btr} + hs_t[rr];
        // the pixels the words in hand last: words x screen pixels per word
        // (a power of two, rounded down: a shrunk sprite's words may last less than a pixel)
        wpx = (wsh[rr] >= 0) ? ({8'd0, cnt[rr]} + infl[rr]) << wsh[rr]
                             : ({8'd0, cnt[rr]} + infl[rr]) >> (-wsh[rr]);
        tot = dpx + wpx;
        // x 3.5 / 8, less 1 for the 8 clocks until this sprite's next visit
        c7  = {tot[8:0], 3'b000} - {1'b0, tot};
        dl_new = (tot >= 14'd292) ? 7'h7F : (c7[11:4] == 8'd0) ? 7'd0 : c7[10:4] - 1'b1;
    end

    // ================================================================ the RAMs
    // The registers: written by halves (merged with the old value)
    wire [31:0] h_v = merge({5'd0, m_h[sn][21:11], 5'd0, m_h[sn][10:0]}, rb_wdata, rb_be);
    wire [31:0] v_v = merge({5'd0, m_v[sn][21:11], 5'd0, m_v[sn][10:0]}, rb_wdata, rb_be);
    wire [31:0] c_v = merge({4'd0, m_c[sn][7:4], 2'd0, m_c[sn][3:2], 6'd0, 2'd0, m_c[sn][1:0], 12'd0}, rb_wdata, rb_be);
    wire [31:0] s_v = merge(m_s[sn], rb_wdata, rb_be);
    wire [2:0]  ra  = rst ? cs : sn;
    always @(posedge clk) begin
        if (rst || (rb_wr && sel_s && sr == 3'd1)) m_h[ra] <= rst ? 22'd0 : {h_v[26:16], h_v[10:0]};
        if (rst || (rb_wr && sel_s && sr == 3'd2)) m_v[ra] <= rst ? 22'd0 : {v_v[26:16], v_v[10:0]};
        if (rst || (rb_wr && sel_s && sr == 3'd3))
            m_c[ra] <= rst ? 8'd0 : {c_v[27:24], c_v[21:20], (c_v[13:12] == 2'd3) ? 2'd2 : c_v[13:12]};
        if (rst || (rb_wr && sel_s && sr == 3'd5)) m_s[ra] <= rst ? 32'd0 : s_v;
    end
    // a PT write: the new line start, merged by halves
    wire [31:0] lst_v   = merge({9'd0, m_lst[sn]}, rb_wdata, rb_be);
    wire [22:0] lst_new = {lst_v[22:1], 1'b0};
    always @(posedge clk) begin
        if (w_pt)
            m_lst[sn] <= lst_new;
        else if (la_w)
            m_lst[la_s] <= la_next;
    end
    wire [2:0]  mwa = la_w ? la_s : fd_go ? fd : pk;
    always @(posedge clk) begin
        if (la_w || fd_go || issue)
            m_ptr[mwa] <= la_w ? la_next : fd_go ? f_lst : p_cur + 23'd2;
        if (fd_go || issue) begin
            m_wl[mwa]  <= fd_go ? f_wv : endline ? wv[pk] : m_wl[pk] - 1'b1;
            m_ll[mwa]  <= fd_go ? nl[fd] : endline ? m_ll[pk] - 1'b1 : m_ll[pk];
        end
        if (la_w || fd_go)
            m_yf[mwa]  <= la_w ? la_yf : 11'd0;
    end
    integer ii;
    initial for (ii = 0; ii < 8; ii = ii + 1) begin
        m_h[ii] = 22'd0; m_v[ii] = 22'd0; m_c[ii] = 8'd0; m_s[ii] = 32'd0;
        m_lst[ii] = 23'd0; m_ptr[ii] = 23'd0; m_wl[ii] = 12'd0; m_ll[ii] = 11'd0; m_yf[ii] = 11'd0;
    end

    // ================================================================ main
    always @(posedge clk) begin
        fa_s1 <= flush_ack_t;
        fa_s2 <= fa_s1;
        for (i = 0; i < 8; i = i + 1) begin
            rp_s1[i] <= rp_g[6*i +: 6];
            rp_s2[i] <= rp_s1[i];
        end
        dl[rr] <= dl_new;
        pk     <= pick;
        pk_v   <= pick_v;

        if (rst) begin
            sprdma  <= 8'hFF;
            coll    <= 32'd0;
            mem_req <= 1'b0;
            q_h <= 2'd0; q_t <= 2'd0;
            epoch <= 8'd0; flushing <= 8'd0; alive <= 8'd0;
            flush_t <= 8'd0;
            pk_v <= 1'b0;
            la_v1 <= 1'b0; la_v2 <= 1'b0; lad <= 8'd0;
            for (i = 0; i < 8; i = i + 1) begin
                wp[i] <= 6'd0; infl[i] <= 4'd0;
                dl[i] <= 7'h7F;
            end
        end else begin
            // ---- data back: into its sprite's FIFO, unless the sprite started again since
            if (mem_rvalid) begin
                q_h <= q_h + 1'b1;
            end
            if (mem_ack) begin
                mem_req <= 1'b0;
                q_t     <= q_t + 1'b1;
            end
            for (i = 0; i < 8; i = i + 1)
                if (dma_wr[i] || man_wr[i]) wp[i] <= wp[i] + 1'b1;
            for (i = 0; i < 8; i = i + 1)
                infl[i] <= infl[i] + ((issue && pk == i) ? 4'd1 : 4'd0)
                                   - ((mem_rvalid && q_s[q_h] == i) ? 4'd1 : 4'd0);

            // ---- ask for the next word
            if (issue) begin
                mem_req  <= 1'b1;
                req_s    <= pk;
                mem_addr <= p_cur[21:1];
                q_s[q_t + (mem_ack ? 1'b1 : 1'b0)] <= pk;
                q_e[q_t + (mem_ack ? 1'b1 : 1'b0)] <= epoch[pk];
                if (endline && m_ll[pk] == 11'd1)
                    alive[pk] <= 1'b0;         // the window's last line is fetched
                else if (endline) begin
                    // the next line's start: from the line-advance unit
                    lad[pk] <= 1'b1;
                    la_v1   <= 1'b1;
                    la_s    <= pk;
                    la_k    <= y_k;
                    la_yf   <= y_sum[10:0];
                    la_lst  <= p_lst;
                    la_wf   <= wf[pk];
                    la_e    <= epoch[pk];
                end
            end
            // ---- the line-advance unit: multiply, then write (a PT write first)
            if (la_v1) begin
                la_p  <= la_k * la_wf;
                la_v1 <= 1'b0;
                la_v2 <= 1'b1;
            end
            if (la_w) begin
                la_v2     <= 1'b0;
                lad[la_s] <= 1'b0;
            end
            if (la_v2 && la_e != epoch[la_s]) begin
                la_v2     <= 1'b0;             // the sprite started again: drop it
                lad[la_s] <= 1'b0;
            end

            // ---- a flush done: all lines to come
            if (fd_go) begin
                flushing[fd] <= 1'b0;
                alive[fd]    <= (f_wv != 12'd0) && (nl[fd] != 11'd0);
            end

            // ---- register writes
            if (rb_wr && sel_g && off == `RM_SPRDMA && rb_be[1:0] == 2'b11) begin
                if (rb_wdata[15]) sprdma <= sprdma |  rb_wdata[7:0];
                else              sprdma <= sprdma & ~rb_wdata[7:0];
            end
            if (rb_wr && sel_s) begin : wspr
                reg [31:0] v;
                case (sr)
                    3'd0: ;                    // the line start: in its RAM, above
                    3'd1, 3'd2, 3'd3: ;        // in their RAMs, below
                    3'd4: if (rb_be[1:0] == 2'b11 && !active[sn] && !flushing[sn] && cnt[sn] < 6'd32) begin
                        // manual mode: the CPU or copper pushes a word
                        ;                      // written above (man_wr)
                    end
                    default: ;
                endcase
            end

            // ---- starting again: empty the FIFO (after the writes above, so they win)
            for (i = 0; i < 8; i = i + 1)
                if (restart[i]) begin
                    epoch[i]    <= ~epoch[i];
                    flushing[i] <= 1'b1;
                    flush_t[i]  <= ~flush_t[i];
                    wp[i]       <= 6'd0;
                    alive[i]    <= 1'b0;
                    lad[i]      <= 1'b0;
                end

            // ---- collisions, a line at a time from the pixel side
            if (rb_wr && sel_g && off == `RM_SPRCOLL)
                coll <= coll & ~merge(32'd0, rb_wdata, rb_be);
            if (coll_s[2] != coll_s[1]) coll <= coll | coll_line;
        end

        // ---- reads (1 clock)
        rb_rdata <= 32'd0;
        if (rb_rd && sel_g) rb_rdata <= (off == `RM_SPRDMA) ? {24'd0, sprdma} : coll;
        if (rb_rd && sel_s) case (sr)
            3'd0: rb_rdata <= {9'd0, m_lst[sn]};
            3'd1: rb_rdata <= {5'd0, m_h[sn][21:11], 5'd0, m_h[sn][10:0]};
            3'd2: rb_rdata <= {5'd0, m_v[sn][21:11], 5'd0, m_v[sn][10:0]};
            3'd3: rb_rdata <= {4'd0, m_c[sn][7:4], 2'd0, m_c[sn][3:2], 6'd0, 2'd0, m_c[sn][1:0], 12'd0};
            3'd4: rb_rdata <= {26'd0, cnt[sn]};
            3'd5: rb_rdata <= m_s[sn];
            default: ;
        endcase
    end

endmodule
