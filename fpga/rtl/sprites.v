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
// comes first: wv = ceil(ceil(shown width / magnify) x bpp / 16). An image
// line in memory is wf words: the same for the whole window width. The
// fetcher takes a line's first wv words. At the end of each source line the
// line's start moves on by wf words; on VMAG's repeated lines it stays.
//
// A sprite starts again at each vertical blank, and when its PT, H, V or
// CTL is written: its FIFO is emptied (both clock domains agree on it with
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
    output wire [15:0] p_hmag,
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
    // SPRxH, SPRxV, SPRxCTL as written, in distributed RAM (one write a
    // clock: a register write, or clearing one a clock during reset)
    reg  [21:0] m_h [0:7];                     // HSTOP (21-11), HSTART (10-0)
    reg  [21:0] m_v [0:7];                     // VSTOP (21-11), VSTART (10-0)
    reg  [11:0] m_c [0:7];                     // PAL 11-8, DEPTH 7-6, VMAG 5-4, HMAG 3-2, BPP 1-0
    // ... and copies of the settings, made by the size calculator below
    reg  [10:0] r_vs [0:7];
    reg  [1:0]  r_bpp [0:7], r_hmag [0:7], r_vmag [0:7], r_depth [0:7];
    reg  [3:0]  r_pal [0:7];

    wire [15:0] off   = {rb_addr[15:2], 2'b00};
    wire        in_c  = (rb_addr[23:16] == 8'hE0);
    wire        sel_g = in_c && (off == `RM_SPRDMA || off == `RM_SPRCOLL);
    wire [15:0] so    = off - `RM_SPR_BASE;
    wire        sel_s = in_c && (off >= `RM_SPR_BASE) && (so < 16'h0100) && (so[4:2] <= 3'd4);
    wire [2:0]  sn    = so[7:5];
    wire [2:0]  sr    = so[4:2];               // 0 PT, 1 H, 2 V, 3 CTL, 4 DAT

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
    reg  [2:0]  wsh [0:7];                     // log2 of screen pixels per word
    reg  [11:0] wf [0:7], wv [0:7];            // words per image line; per shown line
    reg  [10:0] nl [0:7];                      // screen lines shown
    reg  [7:0]  fresh = 8'd0;
    reg  [2:0]  cs = 3'd0;
    always @(posedge clk) begin : sizes
        reg [10:0] hs, he, hsc, xec;
        reg [10:0] vs, ve, vec;
        reg [1:0]  bpp, hmag;
        reg [12:0] wfull, wshow;
        reg [12:0] srcf, srcs;
        reg [15:0] bf, bs;
        hs = m_h[cs][10:0]; he = m_h[cs][21:11]; vs = m_v[cs][10:0]; ve = m_v[cs][21:11];
        bpp = m_c[cs][1:0]; hmag = m_c[cs][3:2];
        r_vs[cs]    <= vs;
        r_bpp[cs]   <= bpp;
        r_hmag[cs]  <= hmag;
        r_vmag[cs]  <= m_c[cs][5:4];
        r_depth[cs] <= m_c[cs][7:6];
        r_pal[cs]   <= m_c[cs][11:8];
        // all in beam coordinates: the line is beam pixels 0-863, the frame lines 0-624
        hsc   = (hs > 11'd864) ? 11'd864 : hs;
        xec   = (he > 11'd864) ? 11'd864 : (he < hsc) ? hsc : he;
        vec   = (ve > 11'd625) ? 11'd625 : ve;
        wfull = (he > hs) ? {2'd0, he - hs} : 13'd0;
        wshow = {2'd0, xec - hsc};
        srcf  = (wfull != 0) ? ((wfull + (13'd1 << hmag) - 1'b1) >> hmag) : 13'd0;
        srcs  = (wshow != 0) ? ((wshow + (13'd1 << hmag) - 1'b1) >> hmag) : 13'd0;
        bf    = ({3'd0, srcf} << (bpp + 1'b1)) + 16'd15;
        bs    = ({3'd0, srcs} << (bpp + 1'b1)) + 16'd15;
        hs_t[cs]  <= hsc[9:0];
        xe_t[cs]  <= xec[9:0];
        wsh[cs]   <= 3'd3 - bpp + hmag;
        ve_c[cs]  <= vec;
        wf[cs]    <= bf[15:4];
        wv[cs]    <= (srcs == 13'd0) ? 12'd0 : (bs[15:4] > bf[15:4]) ? bf[15:4] : bs[15:4];
        nl[cs]    <= (vs < vec) ? vec - vs : 11'd0;
        cs        <= cs + 1'b1;
        fresh     <= (fresh | (8'd1 << cs)) & ~((rb_wr && sel_s) ? (8'd1 << sn) : 8'd0);
        if (rst) fresh <= 8'd0;            // (cs keeps counting: reset clears the registers one a clock)
    end

    generate for (g = 0; g < 8; g = g + 1) begin : outs
        assign p_hs[10*g +: 10]  = hs_t[g];
        assign p_xe[10*g +: 10]  = xe_t[g];
        assign p_vs[11*g +: 11]  = r_vs[g];
        assign p_ve[11*g +: 11]  = ve_c[g];
        assign p_lb[2*g +: 2]    = r_bpp[g] + 1'b1;
        assign p_hmag[2*g +: 2]  = r_hmag[g];
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
    // the VMAG repeat. Writers, in order: a PT write (the line start), a
    // flush done, a word asked for.
    reg  [22:0] m_lst [0:7];
    reg  [22:0] m_ptr [0:7];
    reg  [11:0] m_wl  [0:7];
    reg  [10:0] m_ll  [0:7];
    reg  [1:0]  m_vr  [0:7];
    reg  [7:0]  alive;                         // lines still to fetch this frame
    reg  [7:0]  epoch, flushing;
    reg  [7:0]  fa_s1, fa_s2;
    reg  [6:0]  dl [0:7];                      // deadlines, in units of 8 clocks

    // Restart requests: a register write (this clock) or the vertical blank
    wire        w_reg   = rb_wr && sel_s && sr != 3'd4;
    wire        w_pt    = rb_wr && sel_s && sr == 3'd0;
    wire [7:0]  restart = (vblank ? 8'hFF : 8'd0) | (w_reg ? (8'd1 << sn) : 8'd0);

    // A flush done: the pixel side has emptied its end, and the sizes are fresh
    wire [7:0]  fdone = flushing & ~(fa_s2 ^ flush_t) & fresh;
    reg  [2:0]  fd;
    always @(*) begin : fdsel
        integer s;
        fd = 3'd0;
        for (s = 7; s >= 0; s = s - 1) if (fdone[s]) fd = s[2:0];
    end
    wire        fd_go = |fdone;

    // Who asks next (a clock ahead): of the sprites that want a word, the
    // nearest deadline. A word may be on its way for the last pick, so a
    // FIFO counts as full one word early.
    reg  [7:0]  want;
    reg  [2:0]  pick;
    reg         pick_v;
    reg  [2:0]  pk;                            // the pick, registered
    always @(*) begin : choose
        integer s;
        pick_v = 1'b0;
        pick   = 3'd0;
        for (s = 0; s < 8; s = s + 1) begin
            want[s] = active[s] && !flushing[s] && alive[s] && ({1'b0, cnt[s]} + infl[s] < 7'd31);
            if (want[s] && (!pick_v || dl[s] < dl[pick])) begin
                pick_v = 1'b1;
                pick   = s[2:0];
            end
        end
    end
    reg         pk_v;
    reg  [2:0]  req_s;
    assign mem_deadline = {dl[req_s], 3'b000};
    assign mem_urgent   = mem_req && (dl[req_s] < 7'd5);
    wire        issue   = pk_v && active[pk] && !flushing[pk] && alive[pk] && !restart[pk]
                          && (!mem_req || mem_ack) && !w_pt && !fd_go;

    // The picked sprite's next pointer and line
    wire [22:0] p_cur   = m_ptr[pk];
    wire [22:0] p_lst   = m_lst[pk];
    wire [1:0]  p_vr    = m_vr[pk];
    wire [11:0] p_wf    = wf[pk];
    wire        endline = (m_wl[pk] == 12'd1);
    wire [1:0]  vmax    = 2'd3 >> (2'd2 - r_vmag[pk]);
    wire [22:0] stride  = {10'd0, p_wf, 1'b0};
    wire [22:0] l_next  = (p_vr != vmax) ? p_lst
                        : p_lst + stride;

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
        reg [11:0] dpx, tot, wpx;
        reg [11:0] c7;
        if (bt < xe_t[rr])
            dpx = (bt < hs_t[rr]) ? {2'b0, hs_t[rr] - bt} : 12'd0;
        else
            dpx = {2'b0, btr} + hs_t[rr];
        // the pixels the words in hand last: words x pixels per word x magnify
        wpx = ({6'd0, cnt[rr]} + infl[rr]) << wsh[rr];
        tot = dpx + wpx;
        // x 3.5 / 8, less 1 for the 8 clocks until this sprite's next visit
        c7  = {tot[8:0], 3'b000} - {1'b0, tot};
        dl_new = (tot >= 12'd292) ? 7'h7F : (c7[11:4] == 8'd0) ? 7'd0 : c7[10:4] - 1'b1;
    end

    // ================================================================ the RAMs
    // The registers: written by halves (merged with the old value)
    wire [31:0] h_v = merge({5'd0, m_h[sn][21:11], 5'd0, m_h[sn][10:0]}, rb_wdata, rb_be);
    wire [31:0] v_v = merge({5'd0, m_v[sn][21:11], 5'd0, m_v[sn][10:0]}, rb_wdata, rb_be);
    wire [31:0] c_v = merge({4'd0, m_c[sn][11:8], 2'd0, m_c[sn][7:2], 2'd0, m_c[sn][1:0], 12'd0}, rb_wdata, rb_be);
    wire [2:0]  ra  = rst ? cs : sn;
    always @(posedge clk) begin
        if (rst || (rb_wr && sel_s && sr == 3'd1)) m_h[ra] <= rst ? 22'd0 : {h_v[26:16], h_v[10:0]};
        if (rst || (rb_wr && sel_s && sr == 3'd2)) m_v[ra] <= rst ? 22'd0 : {v_v[26:16], v_v[10:0]};
        if (rst || (rb_wr && sel_s && sr == 3'd3))
            m_c[ra] <= rst ? 12'd0 : {c_v[27:24], c_v[21:20],
                                      (c_v[19:18] == 2'd3) ? 2'd2 : c_v[19:18],
                                      (c_v[17:16] == 2'd3) ? 2'd2 : c_v[17:16],
                                      (c_v[13:12] == 2'd3) ? 2'd2 : c_v[13:12]};
    end
    // a PT write: the new line start, merged by halves
    wire [31:0] lst_v   = merge({9'd0, m_lst[sn]}, rb_wdata, rb_be);
    wire [22:0] lst_new = {lst_v[22:1], 1'b0};
    always @(posedge clk) begin
        if (w_pt)
            m_lst[sn] <= lst_new;
        else if (issue && endline)
            m_lst[pk] <= l_next;
    end
    wire [2:0]  mwa = fd_go ? fd : pk;
    always @(posedge clk) if (fd_go || issue) begin
        m_ptr[mwa] <= fd_go ? f_lst : endline ? l_next : p_cur + 23'd2;
        m_wl[mwa]  <= fd_go ? f_wv : endline ? wv[pk] : m_wl[pk] - 1'b1;
        m_ll[mwa]  <= fd_go ? nl[fd] : endline ? m_ll[pk] - 1'b1 : m_ll[pk];
        m_vr[mwa]  <= fd_go ? 2'd0 : !endline ? p_vr : (p_vr == vmax) ? 2'd0 : p_vr + 1'b1;
    end
    integer ii;
    initial for (ii = 0; ii < 8; ii = ii + 1) begin
        m_h[ii] = 22'd0; m_v[ii] = 22'd0; m_c[ii] = 12'd0;
        m_lst[ii] = 23'd0; m_ptr[ii] = 23'd0; m_wl[ii] = 12'd0; m_ll[ii] = 11'd0; m_vr[ii] = 2'd0;
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
            3'd3: rb_rdata <= {4'd0, m_c[sn][11:8], 2'd0, m_c[sn][7:2], 2'd0, m_c[sn][1:0], 12'd0};
            3'd4: rb_rdata <= {26'd0, cnt[sn]};
            default: ;
        endcase
    end

endmodule
