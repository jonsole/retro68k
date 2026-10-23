// Sprites, 100 MHz side (spec 9): registers, the fetcher and the FIFOs.
//
// Eight sprites. Each has a pointer into its image (SPRxPT), a window
// (SPRxH, SPRxV) and settings (SPRxCTL), written by the CPU or copper, and
// a 32-word FIFO: its data registers. The fetcher fetches each line's
// words during that line, one word at a time through the scheduler's sprite
// channel (dmac.v), the sprite with the nearest deadline first. The pixel
// side (sprite_pix.v) takes the words.
//
// What one sprite line takes: the words that hold its shown pixels, from
// HSTART to HSTOP or the end of the line (beam pixel 864), whichever
// comes first: wv = ceil(ceil(shown width x XSTEP / 2048) x bpp / 16). An
// image line in memory is wf words: the same for the whole window width.
// The fetcher takes a line's first wv words.
//
// Each line's settings: the size calculator's results are written only in
// a window near the end of each line (beam pixels 840-847), so they hold
// still for the next line, and both the fetcher and the pixel side use the
// same values. At the start of each line (beam pixel 0) a short pass visits
// the sprites, one a clock: a running sprite whose window covers the line
// shows on it; its line start moves on by k x wf words (k the source lines
// YSTEP moves on, 0 when a line shows again; not on its first line or after
// a PT write), and its words are fetched from there. The pixel side takes
// which sprites show at beam pixel 12 (so HSTART must be 16 or more).
//
// A write to SPRxCTL starts a sprite; the vertical blank stops them all.
// Either way its FIFO is emptied (both clock domains agree on it with a
// handshake) and reads still on their way are dropped.
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
    output wire [7:0]  p_act,          // shows on this line (set at its start)
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
    // clock (cs), and kept in registers: written only in the window near
    // the end of each line (upd), so they are the next line's settings.
    reg  [9:0]  hs_t [0:7], xe_t [0:7];        // the window across, on the line's timeline t
    reg  [10:0] ve_c [0:7];
    reg  signed [3:0] wsh [0:7];               // log2 of screen pixels per word, rounded down (for the deadlines)
    reg  [11:0] wf [0:7], wv [0:7];            // words per image line; per shown line
    reg  [2:0]  cs = 3'd0;
    wire        upd = (beam_h >= 11'd840) && (beam_h < 11'd848);
    reg  [1:0]  upd_d;                         // ... two clocks on, for stage 3
    always @(posedge clk) upd_d <= {upd_d[0], upd};
    // Three stages, for timing: 1 reads sprite cs's registers and clamps
    // its window; 2 multiplies the widths by XSTEP; 3 works out the word
    // counts (sprite c3). Stage 3 writes for the same visits as stage 1.
    reg  [2:0]  c2, c3;
    reg  [12:0] wfull2, wshow2;
    reg  [15:0] xs2;
    reg  [10:0] vs2, vec2;
    reg  [1:0]  bpp2, bpp3;
    reg  [28:0] pf3, ps3;              // widths x XSTEP
    // log2 of 2048 / XSTEP, rounded down (bigger across: positive)
    function signed [3:0] mag(input [15:0] s);
        integer b, top, m;
        begin
            top = 7;
            for (b = 7; b <= 15; b = b + 1) if (s[b]) top = b;
            m   = (((s & (s - 1'b1)) == 16'd0) ? 11 : 10) - top;    // a power of two exactly, or between
            mag = m[3:0];
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
        // all in beam coordinates: the line is beam pixels 0-863, the frame lines 0-624
        hsc   = (hs > 11'd864) ? 11'd864 : hs;
        xec   = (he > 11'd864) ? 11'd864 : (he < hsc) ? hsc : he;
        vec   = (ve > 11'd625) ? 11'd625 : ve;
        if (upd) begin
            r_vs[cs]    <= vs;
            r_bpp[cs]   <= bpp;
            r_depth[cs] <= m_c[cs][3:2];
            r_pal[cs]   <= m_c[cs][7:4];
            r_xs[cs]    <= xs;
            r_ys[cs]    <= lim(m_s[cs][31:16]);
            hs_t[cs]    <= hsc[9:0];
            xe_t[cs]    <= xec[9:0];
            wsh[cs]     <= $signed({2'b00, 2'd3 - bpp}) + mag(xs);
            ve_c[cs]    <= vec;
        end
        wfull2 <= (he > hs) ? {2'd0, he - hs} : 13'd0;
        wshow2 <= {2'd0, xec - hsc};
        xs2    <= xs;
        vs2    <= vs;
        vec2   <= vec;
        bpp2   <= bpp;
        c2     <= cs;
        cs     <= cs + 1'b1;
        // stage 2
        pf3  <= wfull2 * xs2;
        ps3  <= wshow2 * xs2;
        bpp3 <= bpp2;
        c3   <= c2;
        // stage 3: source pixels = ceil(width x XSTEP / 2048), then words
        /* verilator lint_off WIDTHTRUNC */ srcf  = (pf3 + 29'd2047) >> 11; /* verilator lint_on WIDTHTRUNC */
        /* verilator lint_off WIDTHTRUNC */ srcs  = (ps3 + 29'd2047) >> 11; /* verilator lint_on WIDTHTRUNC */
        bf    = ({3'd0, srcf} << (bpp3 + 1'b1)) + 21'd15;
        bs    = ({3'd0, srcs} << (bpp3 + 1'b1)) + 21'd15;
        if (upd_d[1]) begin
            wf[c3]  <= (bf[20:4] > 17'd4095) ? 12'd4095 : bf[15:4];
            wv[c3]  <= (srcs == 18'd0) ? 12'd0 : (bs[20:4] > bf[20:4]) ? ((bf[20:4] > 17'd4095) ? 12'd4095 : bf[15:4])
                                     : (bs[20:4] > 17'd4095) ? 12'd4095 : bs[15:4];
        end
    end

    generate for (g = 0; g < 8; g = g + 1) begin : outs
        assign p_hs[10*g +: 10]  = hs_t[g];
        assign p_xe[10*g +: 10]  = xe_t[g];
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
    reg  [5:0]  rpb [0:7];                     // the read pointers, binary (registered: a clock old, for timing)
    wire [5:0]  cnt [0:7];                     // words in the FIFO
    wire [6:0]  fill [0:7];                    // ... and on their way
    wire [7:0]  dma_wr, man_wr;                // a word into the FIFO: from memory; from SPRxDAT

    // ================================================================ fetch state
    // Each sprite's place in its image, in distributed RAM (one write a clock):
    // the line's start (SPRxPT reads it), the next word, the words of the
    // line still to fetch, and the fraction of YSTEP. Writers: a PT write
    // (the line start), the line-start pass, a word asked for.
    reg  [22:0] m_lst [0:7];
    reg  [22:0] m_ptr [0:7];
    reg  [11:0] m_wl  [0:7];
    reg  [10:0] m_yf  [0:7];
    reg  [7:0]  run;                           // started (a CTL write) this frame
    reg  [7:0]  pend;                          // has shown a line since it started or PT was written
    reg  [7:0]  line_act;                      // shows on this line
    reg  [7:0]  alive;                         // this line's words still to fetch
    reg  [7:0]  epoch, flushing;
    assign p_act = line_act;
    reg  [7:0]  fa_s1, fa_s2;
    reg  [6:0]  dl [0:7];                      // deadlines, in units of 8 clocks

    // Starting (a CTL write) and stopping (the vertical blank) both empty the FIFO
    wire        w_ctl   = rb_wr && sel_s && sr == 3'd3;
    wire        w_pt    = rb_wr && sel_s && sr == 3'd0;
    wire [7:0]  restart = (vblank ? 8'hFF : 8'd0) | (w_ctl ? (8'd1 << sn) : 8'd0);

    // A flush done: the pixel side has emptied its end
    wire [7:0]  fdone = flushing & ~(fa_s2 ^ flush_t);

    // The line-start pass: at beam pixel 0 of each line (not line 0, where
    // the vertical blank stops every sprite), three stages, a sprite a clock:
    // A whether it shows and how far its line start moves; B the multiply;
    // C the writes. It holds still in a clock with a PT write (which has the
    // line-start RAM), and fetching waits for it.
    reg         bz;
    always @(posedge clk) bz <= (beam_h == 11'd0);
    wire        line_go = (beam_h == 11'd0) && !bz && (beam_v != 11'd0);
    reg  [3:0]  ba;                            // stage A's sprite; 8: done
    reg         b_v, cv, b_show, c_show, b_e, c_e;
    reg  [2:0]  b_s, c_s;
    reg  [4:0]  b_k;
    reg  [10:0] b_yf, c_yf;
    reg  [22:0] b_lst, c_lst;
    reg  [11:0] b_wf, b_wv, c_wv;
    reg  [16:0] c_p;
    wire        bu_go   = !w_pt;
    wire        bu_busy = !ba[3] || b_v || cv;
    wire [2:0]  a       = ba[2:0];
    wire        a_show  = run[a] && beam_v >= r_vs[a] && beam_v < ve_c[a] && wv[a] != 12'd0;
    wire [11:0] a_sum   = {1'b0, m_yf[a]} + {1'b0, r_ys[a][10:0]};
    wire [5:0]  a_kw    = {1'b0, r_ys[a][15:11]} + a_sum[11];
    wire [4:0]  a_k     = pend[a] ? a_kw[4:0] : 5'd0;   // source lines to move on: 0-16
    wire [10:0] a_yf    = pend[a] ? a_sum[10:0] : 11'd0;
    wire        c_w     = cv && bu_go && c_e == epoch[c_s];
    wire [22:0] c_next  = c_lst + {5'd0, c_p, 1'b0};

    // Who asks next (a clock ahead): of the sprites that want a word, the
    // nearest deadline, the lower number on a tie. For timing, which
    // sprites want a word is registered first (want), and the pick is a
    // tree of pairs. want is a clock old and the pick a clock ahead, so
    // words for the last two picks may be on their way unseen: a FIFO
    // counts as full two words early. issue checks the state of the moment.
    // (The read pointer is a clock old too, which only makes a FIFO look
    // fuller: safe.)
    reg  [7:0]  want;
    reg  [2:0]  pick;
    reg         pick_v;
    reg  [2:0]  pk;                            // the pick, registered
    always @(posedge clk) begin : wants
        integer s;
        for (s = 0; s < 8; s = s + 1)
            want[s] <= !rst && active[s] && !flushing[s] && alive[s] && (fill[s] < 7'd30);
    end
    // one pair: b wins only if it wants a word and a has none or a later deadline
    reg         t1v [0:3], t2v [0:1];
    reg  [2:0]  t1i [0:3], t2i [0:1];
    reg  [6:0]  t1d [0:3], t2d [0:1];
    always @(*) begin : choose
        integer k;
        for (k = 0; k < 4; k = k + 1)
            if (want[2*k+1] && (!want[2*k] || dl[2*k+1] < dl[2*k])) begin
                t1v[k] = 1'b1; t1i[k] = {k[1:0], 1'b1}; t1d[k] = dl[2*k+1];
            end else begin
                t1v[k] = want[2*k]; t1i[k] = {k[1:0], 1'b0}; t1d[k] = dl[2*k];
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
    wire        issue   = pk_v && active[pk] && !flushing[pk] && alive[pk] && !restart[pk]
                          && (!mem_req || mem_ack) && !bu_busy;

    // The picked sprite's next word
    wire [22:0] p_cur   = m_ptr[pk];
    wire        endline = (m_wl[pk] == 12'd1);

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
        always @(posedge clk) rpb[g] <= g2b(rp_s2[g]);
        assign cnt[g]  = wp[g] - rpb[g];
        assign fill[g] = {1'b0, cnt[g]} + infl[g];
    end endgenerate

    // ================================================================ deadlines
    // One sprite a clock (cs): when its FIFO will run dry, in units of 8
    // system clocks (about 3.5 a pixel), counting from the beam. The beam
    // on the sprite's line timeline (t = 0-863) is registered once. Lines
    // are not looked at: a sprite not shown on this line or the next only
    // fills its FIFO a little sooner than it needs to.
    // Three stages, for timing: 1 the pixels until the sprite's span and
    // the words in hand; 2 the pixels those words last, and the sum; 3 the
    // units. With the read pointers registered too, a deadline is written
    // from inputs about 4 clocks old and then holds for 8 clocks until the
    // sprite's next visit: 2 units (16 clocks) are taken off to be safe.
    reg  [9:0]  bt, btr;                       // t; 864 - t
    always @(posedge clk) begin
        bt  <= beam_h[9:0];
        /* verilator lint_off WIDTHTRUNC */ btr <= 11'd864 - beam_h; /* verilator lint_on WIDTHTRUNC */
    end
    wire [2:0]  rr = cs;
    reg  [2:0]  d1_rr, d2_rr, d3_rr;
    reg  [13:0] d1_dpx, d2_tot;
    reg  [6:0]  d1_w;
    reg  signed [3:0] d1_wsh;
    reg  [6:0]  d3_dl;
    always @(posedge clk) begin : dcalc
        reg [13:0] wpx;
        reg [11:0] c7;
        // 1: the pixels until the sprite's span (0 if the beam is in it)
        if (bt < xe_t[rr])
            d1_dpx <= (bt < hs_t[rr]) ? {4'b0, hs_t[rr] - bt} : 14'd0;
        else
            d1_dpx <= {4'b0, btr} + hs_t[rr];
        d1_w   <= fill[rr];
        d1_wsh <= wsh[rr];
        d1_rr  <= rr;
        // 2: the pixels the words last: words x screen pixels per word (a
        // power of two, rounded down: a shrunk sprite's words may last less
        // than a pixel), and the total
        wpx = (d1_wsh >= 0) ? ({7'd0, d1_w} << d1_wsh) : ({7'd0, d1_w} >> (-d1_wsh));
        d2_tot <= d1_dpx + wpx;
        d2_rr  <= d1_rr;
        // 3: x 3.5 / 8, less 2 units
        /* verilator lint_off WIDTHTRUNC */ c7 = {d2_tot[8:0], 3'b000} - {1'b0, d2_tot}; /* verilator lint_on WIDTHTRUNC */
        d3_dl <= (d2_tot >= 14'd292) ? 7'h7F : (c7[11:4] < 8'd2) ? 7'd0 : c7[10:4] - 2'd2;
        d3_rr <= d2_rr;
    end

    // ================================================================ the RAMs
    // The registers: written by halves (merged with the old value)
    wire [31:0] h_v = merge({5'd0, m_h[sn][21:11], 5'd0, m_h[sn][10:0]}, rb_wdata, rb_be);
    wire [31:0] v_v = merge({5'd0, m_v[sn][21:11], 5'd0, m_v[sn][10:0]}, rb_wdata, rb_be);
    wire [31:0] c_v = merge({4'd0, m_c[sn][7:4], 2'd0, m_c[sn][3:2], 6'd0, m_c[sn][1:0], 12'd0}, rb_wdata, rb_be);
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
    wire        c_set = c_w && c_show;        // the line-start pass sets up a shown line
    always @(posedge clk) begin
        if (w_pt)
            m_lst[sn] <= lst_new;
        else if (c_set)
            m_lst[c_s] <= c_next;
    end
    wire [2:0]  mwa = c_set ? c_s : pk;       // (no word is asked for during the pass)
    always @(posedge clk) begin
        if (c_set || issue) begin
            m_ptr[mwa] <= c_set ? c_next : p_cur + 23'd2;
            m_wl[mwa]  <= c_set ? c_wv : m_wl[pk] - 1'b1;
        end
        if (c_set)
            m_yf[c_s]  <= c_yf;
    end
    integer ii;
    initial for (ii = 0; ii < 8; ii = ii + 1) begin
        m_h[ii] = 22'd0; m_v[ii] = 22'd0; m_c[ii] = 8'd0; m_s[ii] = 32'd0;
        m_lst[ii] = 23'd0; m_ptr[ii] = 23'd0; m_wl[ii] = 12'd0; m_yf[ii] = 11'd0;
    end

    // ================================================================ main
    always @(posedge clk) begin
        fa_s1 <= flush_ack_t;
        fa_s2 <= fa_s1;
        for (i = 0; i < 8; i = i + 1) begin
            rp_s1[i] <= rp_g[6*i +: 6];
            rp_s2[i] <= rp_s1[i];
        end
        dl[d3_rr] <= d3_dl;
        pk     <= pick;
        pk_v   <= pick_v;

        if (rst) begin
            sprdma  <= 8'hFF;
            coll    <= 32'd0;
            mem_req <= 1'b0;
            q_h <= 2'd0; q_t <= 2'd0;
            epoch <= 8'd0; flushing <= 8'd0; alive <= 8'd0;
            run <= 8'd0; pend <= 8'd0; line_act <= 8'd0;
            flush_t <= 8'd0;
            pk_v <= 1'b0;
            ba <= 4'd8; b_v <= 1'b0; cv <= 1'b0;
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
                if (endline) alive[pk] <= 1'b0;   // the line's last word
            end

            // ---- the line-start pass
            if (line_go)
                ba <= 4'd0;
            else if (bu_go && !ba[3])
                ba <= ba + 1'b1;
            if (bu_go) begin
                b_v <= !ba[3] && !line_go;
                b_s <= a; b_show <= a_show; b_e <= epoch[a];
                b_k <= a_k; b_yf <= a_yf; b_lst <= m_lst[a]; b_wf <= wf[a]; b_wv <= wv[a];
                cv  <= b_v;
                c_s <= b_s; c_show <= b_show; c_e <= b_e;
                c_yf <= b_yf; c_lst <= b_lst; c_p <= b_k * b_wf; c_wv <= b_wv;
            end
            if (c_w) begin
                line_act[c_s] <= c_show;
                alive[c_s]    <= c_show;
                if (c_show) pend[c_s] <= 1'b1;
            end
            if (w_pt) pend[sn] <= 1'b0;        // the next line starts exactly there

            // ---- flushes done
            flushing <= flushing & ~fdone;

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
                            default: ;                 // SPRxDAT: written above (man_wr)
                endcase
            end

            // ---- starting and stopping: empty the FIFO (after the writes above, so they win)
            for (i = 0; i < 8; i = i + 1)
                if (restart[i]) begin
                    epoch[i]    <= ~epoch[i];
                    flushing[i] <= 1'b1;
                    flush_t[i]  <= ~flush_t[i];
                    wp[i]       <= 6'd0;
                    alive[i]    <= 1'b0;
                    line_act[i] <= 1'b0;
                    pend[i]     <= 1'b0;
                    run[i]      <= !vblank;    // a CTL write starts it; the vertical blank stops it
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
            3'd3: rb_rdata <= {4'd0, m_c[sn][7:4], 2'd0, m_c[sn][3:2], 6'd0, m_c[sn][1:0], 12'd0};
            3'd4: rb_rdata <= {26'd0, cnt[sn]};
            3'd5: rb_rdata <= m_s[sn];
            default: ;
        endcase
    end

endmodule
