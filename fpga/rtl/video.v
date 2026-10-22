// Video (spec 4): 576p (720x576 at 50 Hz, CEA-861, 27 MHz), a 256-colour
// palette, background colour,
// three bitmap layers (chunky 1/2/4/8 bpp or planar 1-8 planes, Amiga-style:
// plane pointers, modulo and data registers, bpldma.v), priority, beam
// position, VBLANK, LINE and OVERRUN.
// Also DMACON (spec 5, section 8), which sits in this register block.
//
// Two clock domains, asynchronous to each other:
//   clk     100 MHz: registers, bitplane DMA, palette writes, interrupts
//   clk_pix  27 MHz: the beam and the pixel pipeline
// Crossings: events are toggles through two flip-flops; the data registers
// cross under the full/taken handshake (bpldma.v, layer_pix.v); the beam
// position is sampled until two samples agree; layer settings, PRIO,
// BGCOLOR and VIDCON are settings, copied into the pixel domain once per
// line (a write that lands exactly on that copy may take effect one line
// later, or show for one line in part); the palette is a two-clock RAM.
`include "regmap.vh"

module video (
    input  wire        clk,            // 100 MHz
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output wire [31:0] rb_rdata,

    output wire        irq_vblank,
    output wire        irq_line,
    output wire        irq_viderr,
    output wire        line_tick,      // 1 clock (100 MHz) per video line, for the timers
    output wire        frame_tick,     // 1 clock at the start of each vertical blank
    output wire [10:0] beam_v,         // the beam position, memory side (for the copper)
    output wire [10:0] beam_h,

    // DMACON, and the display fetch port of the SRAM controller
    output reg  [15:0] dmacon,
    output wire        disp_req,
    output wire        disp_urgent,
    output wire [9:0]  disp_deadline,
    output wire [21:1] disp_addr,
    input  wire        disp_ack,
    input  wire        disp_rvalid,
    input  wire [15:0] disp_rdata,

    input  wire        clk_pix,
    input  wire        clk_pix5,       // 5 x clk_pix (135 MHz), edges lined up
    output reg  [23:0] rgb,
    output reg         hsync,
    output reg         vsync,
    output reg         de
);
    // ================================================================ the mode (section 3.2)
    // 576p50 (CEA-861 format 17/18): 864 x 625 at 27 MHz, both syncs active low
    localparam [10:0] HVIS = 11'd720;
    localparam [10:0] HSS  = 11'd732;       // front porch 12
    localparam [10:0] HSE  = 11'd796;       // sync 64, back porch 68
    localparam [10:0] HTOT = 11'd864;
    localparam [10:0] VVIS = 11'd576;
    localparam [10:0] VSS  = 11'd581;       // front porch 5
    localparam [10:0] VSE  = 11'd586;       // sync 5, back porch 39
    localparam [10:0] VTOT = 11'd625;
    localparam        SPOL = 1'b0;          // 1: active-high sync

    // ================================================================ registers (100 MHz)
    wire [15:0] off      = {rb_addr[15:2], 2'b00};
    wire in_custom = (rb_addr[23:16] == 8'hE0);
    wire sel_glob  = in_custom && (off[15:8] == 8'd0);         // 0x000-0x0FF
    wire [8:0] blk = off[15:7];                                // layers: 2, 3, 4
    wire sel_lay   = in_custom && (blk >= 9'd2) && (blk <= 9'd4) && (off[6:5] == 2'b00);
    wire [1:0] ln  = blk[1:0] - 2'd2;
    wire sel_pal   = in_custom && (off[15:10] == 6'b010000);   // 0x4000-0x43FF

    reg  [4:0]  vidcon;                // DIRECT (4), BLANKALL (2), EN (0)
    reg  [6:0]  vidstat;               // sticky flags; INVBLANK (bit 8) is live, below
    reg  [6:0]  vidinten;
    reg  [10:0] lc_v;                  // LINECMP
    reg  [23:0] bgcolor;
    reg  [5:0]  prio;

    // Layers 0-2: CTRL, window, fine scroll (pointers, modulo and data are in bpldma.v)
    reg  [23:0] l_ctrl [0:2];
    reg  [10:0] l_xs [0:2], l_xe [0:2], l_ys [0:2], l_ye [0:2];
    reg  [3:0]  l_sx [0:2];

    // From the pixel domain
    reg  [10:0] p_hc, p_vc;            // beam position (pixel domain)
    reg  [15:0] p_frames;
    // ... sampled on this side until two samples agree, so a read is never torn
    reg  [37:0] bs1, bs2, bsync;
    always @(posedge clk) begin
        bs1 <= {p_frames, p_vc, p_hc};
        bs2 <= bs1;
        if (bs1 == bs2) bsync <= bs2;
    end
    wire [10:0] s_hc = bsync[10:0], s_vc = bsync[21:11];
    wire [15:0] s_frames = bsync[37:22];
    assign beam_v = s_vc;
    assign beam_h = s_hc;
    reg         p_vb_t, p_line_t;      // toggles: vertical blank started, line compare hit
    wire        p_invblank = (s_vc >= VVIS);

    function [31:0] merge(input [31:0] old, input [31:0] new, input [3:0] be);
        merge = { be[3] ? new[31:24] : old[31:24], be[2] ? new[23:16] : old[23:16],
                  be[1] ? new[15:8]  : old[15:8],  be[0] ? new[7:0]   : old[7:0] };
    endfunction

    reg  [1:0] vb_s, ln_s;
    reg  [1:0] ov_s [0:2];
    wire [2:0] ov_t;
    wire       fetch_en = vidcon[0] && dmacon[9] && dmacon[8];
    integer    i;
    reg [31:0] reg_q;

    always @(posedge clk) begin
        if (rst) begin
            vidcon   <= 5'd0;
            vidstat  <= 7'd0;
            vidinten <= 7'd0;
            lc_v     <= 11'd0;
            bgcolor  <= 24'd0;
            prio     <= 6'b10_01_00;    // L0 in front, then L1, then L2
            for (i = 0; i < 3; i = i + 1) begin
                l_ctrl[i] <= 24'd0;
                l_xs[i] <= 11'd0;  l_xe[i] <= HVIS;  l_ys[i] <= 11'd0;  l_ye[i] <= VVIS;
                l_sx[i] <= 4'd0;
                ov_s[i] <= 2'b00;
            end
            vb_s <= 2'b00; ln_s <= 2'b00;
            dmacon <= 16'd0;
        end else begin
            for (i = 0; i < 3; i = i + 1) begin
                ov_s[i] <= {ov_s[i][0], ov_t[i]};
                if (ov_s[i][1] != ov_s[i][0]) vidstat[4 + i] <= 1'b1;
            end
            // Events from the pixel domain
            vb_s <= {vb_s[0], p_vb_t};
            ln_s <= {ln_s[0], p_line_t};
            if (vb_s[1] != vb_s[0]) vidstat[0] <= 1'b1;
            if (ln_s[1] != ln_s[0]) vidstat[1] <= 1'b1;

            if (rb_wr && sel_lay) begin : wlayer
                reg [31:0] v;
                case (off[4:0])
                    5'h00: begin v = merge({8'd0, l_ctrl[ln]}, rb_wdata, rb_be); l_ctrl[ln] <= v[23:0]; end
                    5'h04: begin v = merge({5'd0, l_xs[ln], 5'd0, l_xe[ln]}, rb_wdata, rb_be);
                                 l_xs[ln] <= v[26:16]; l_xe[ln] <= v[10:0]; end
                    5'h08: begin v = merge({5'd0, l_ys[ln], 5'd0, l_ye[ln]}, rb_wdata, rb_be);
                                 l_ys[ln] <= v[26:16]; l_ye[ln] <= v[10:0]; end
                    5'h0C: if (rb_be[0]) l_sx[ln] <= rb_wdata[3:0];
                    default: ;
                endcase
            end
            if (rb_wr && sel_glob) begin : wglobal
                reg [31:0] v;
                case (off)
                    `RM_VIDCON:   begin v = merge({27'd0, vidcon}, rb_wdata, rb_be); vidcon <= {v[4], 1'b0, v[2], 1'b0, v[0]}; end
                    `RM_VIDSTAT:  if (rb_be[0]) vidstat <= vidstat & ~rb_wdata[6:0];
                    `RM_VIDINTEN: begin v = merge({25'd0, vidinten}, rb_wdata, rb_be); vidinten <= v[6:0] & 7'h73; end
                    `RM_LINECMP:  begin v = merge({5'd0, lc_v, 16'd0}, rb_wdata, rb_be); lc_v <= v[26:16]; end
                    `RM_BGCOLOR:  begin v = merge({8'd0, bgcolor}, rb_wdata, rb_be); bgcolor <= v[23:0]; end
                    `RM_PRIO:     begin v = merge({26'd0, prio}, rb_wdata, rb_be); prio <= v[5:0]; end
                    `RM_DMACON:   if (rb_be[1:0] == 2'b11) begin              // set/clear (spec 3, rule 6)
                        if (rb_wdata[15]) dmacon <= dmacon | (rb_wdata[14:0] & 15'h03EF);
                        else              dmacon <= dmacon & ~(rb_wdata[14:0] & 15'h03EF);
                    end
                    default: ;
                endcase
            end
        end

        reg_q <= 32'd0;
        if (rb_rd && sel_lay) case (off[4:0])
            5'h00: reg_q <= {8'd0, l_ctrl[ln]};
            5'h04: reg_q <= {5'd0, l_xs[ln], 5'd0, l_xe[ln]};
            5'h08: reg_q <= {5'd0, l_ys[ln], 5'd0, l_ye[ln]};
            5'h0C: reg_q <= {28'd0, l_sx[ln]};
            default: ;
        endcase
        if (rb_rd && sel_glob) case (off)
            `RM_VIDCON:     reg_q <= {27'd0, vidcon};
            `RM_VIDSTAT:    reg_q <= {23'd0, p_invblank, 1'b0, vidstat};
            `RM_VIDINTEN:   reg_q <= {25'd0, vidinten};
            `RM_BEAMPOS:    reg_q <= {5'd0, s_vc, 5'd0, s_hc};
            `RM_FRAMECOUNT: reg_q <= {16'd0, s_frames};
            `RM_LINECMP:    reg_q <= {5'd0, lc_v, 16'd0};
            `RM_BGCOLOR:    reg_q <= {8'd0, bgcolor};
            `RM_PRIO:       reg_q <= {26'd0, prio};
            `RM_VIDSIZE:    reg_q <= {5'd0, VVIS, 5'd0, HVIS};
            `RM_DMACON:     reg_q <= {16'd0, dmacon};
            default: ;
        endcase
    end

    reg  [2:0] lt_s;
    always @(posedge clk) lt_s <= {lt_s[1:0], line_t};
    assign line_tick  = lt_s[2] != lt_s[1];
    assign frame_tick = vb_s[1] != vb_s[0];

    wire [6:0] irqflags = vidstat & vidinten;
    assign irq_vblank = irqflags[0];
    assign irq_line   = irqflags[1];
    assign irq_viderr = |irqflags[6:4];

    // ================================================================ palette
    // Kept twice, written together from the CPU side (100 MHz, 32-bit with
    // byte enables): one copy is read back by the CPU, the other by the
    // pixel side. Simple one-write, one-read block RAMs map the same way in
    // every tool.
    reg [31:0] pal [0:255], pal_c [0:255];       // 0x00RRGGBB
    integer k;
    initial for (k = 0; k < 256; k = k + 1) begin pal[k] = 32'd0; pal_c[k] = 32'd0; end

    reg [31:0] pal_qa;
    always @(posedge clk) if (rb_wr && sel_pal) begin
        if (rb_be[3]) pal[rb_addr[9:2]][31:24] <= rb_wdata[31:24];
        if (rb_be[2]) pal[rb_addr[9:2]][23:16] <= rb_wdata[23:16];
        if (rb_be[1]) pal[rb_addr[9:2]][15:8]  <= rb_wdata[15:8];
        if (rb_be[0]) pal[rb_addr[9:2]][7:0]   <= rb_wdata[7:0];
    end
    always @(posedge clk) begin
        if (rb_wr && sel_pal) begin
            if (rb_be[3]) pal_c[rb_addr[9:2]][31:24] <= rb_wdata[31:24];
            if (rb_be[2]) pal_c[rb_addr[9:2]][23:16] <= rb_wdata[23:16];
            if (rb_be[1]) pal_c[rb_addr[9:2]][15:8]  <= rb_wdata[15:8];
            if (rb_be[0]) pal_c[rb_addr[9:2]][7:0]   <= rb_wdata[7:0];
        end
        pal_qa <= pal_c[rb_addr[9:2]];
    end
    reg pal_hit;
    always @(posedge clk) pal_hit <= rb_rd && sel_pal;

    wire [31:0] dma_q;
    assign rb_rdata = reg_q | dma_q | (pal_hit ? {8'd0, pal_qa[23:0]} : 32'd0);

    // ================================================================ pixel domain
    reg [1:0] rst_p;
    always @(posedge clk_pix) rst_p <= {rst_p[0], rst};
    wire prst = rst_p[1];

    reg en_p;
    reg [1:0] en_s;
    always @(posedge clk_pix) begin
        en_s <= {en_s[0], vidcon[0]};
        en_p <= !prst && en_s[1];
    end

    // ---- beam
    reg [10:0] hc, vc;
    wire hlast = (hc == HTOT - 1'b1);
    wire vlast = (vc == VTOT - 1'b1);
    wire [10:0] hn = hlast ? 11'd0 : hc + 1'b1;
    wire [10:0] vn = hlast ? (vlast ? 11'd0 : vc + 1'b1) : vc;

    reg [5:0]  prio_l;                 // PRIO and BGCOLOR, taken at the start of each line (section 5.4)
    reg [23:0] bg_l;
    always @(posedge clk_pix) begin
        if (!en_p) begin
            hc <= 11'd0;
            vc <= 11'd0;
        end else begin
            hc <= hn;
            vc <= vn;
            if (hn == 11'd0) begin
                prio_l <= prio;
                bg_l   <= bgcolor;
            end
        end
        p_hc <= hc;
        p_vc <= vc;
        if (prst) begin
            p_vb_t   <= 1'b0;
            p_line_t <= 1'b0;
            p_frames <= 16'd0;
        end else if (en_p) begin
            if (hc == 11'd0 && vc == VVIS) begin
                p_vb_t   <= ~p_vb_t;
                p_frames <= p_frames + 1'b1;
            end
            if (hc == 11'd0 && vc == lc_v) p_line_t <= ~p_line_t;
        end
    end

    // ---- settings for the next line, worked out in the horizontal blank
    // (clocks HVIS to HVIS + 2), then handed to the DMA and the layer units
    wire [10:0] next_line = vlast ? 11'd0 : vc + 1'b1;
    reg  [2:0]  b_vsub [0:2];          // screen lines shown of this source line
    reg  [2:0]  b_act, b_adv;
    reg  [3:0]  n_pos0 [0:2];
    reg  [11:0] n_groups [0:2], n_len [0:2];
    reg  [2:0]  f_act, f_adv, f_chunky;
    reg  [11:0] f_groups [0:2], f_len [0:2];
    reg  [2:0]  f_planes [0:2];
    reg  [1:0]  f_hs [0:2];
    reg         line_t;
    // This line's settings, for the layer units
    reg  [2:0]  c_act, c_planar, c_transp;
    reg  [10:0] c_xs [0:2], c_xe [0:2];
    reg  [1:0]  c_lb [0:2], c_hs [0:2];
    reg  [2:0]  c_planes [0:2];
    reg  [3:0]  c_pos0 [0:2], c_palofs [0:2];

    always @(posedge clk_pix) begin : setup
        integer n;
        reg [2:0]  vmax, vs_n;
        reg [10:0] w, srcpix;
        reg [13:0] bits;
        reg [3:0]  fine;
        if (prst) begin
            line_t <= 1'b0;
            c_act  <= 3'd0;
            f_act  <= 3'd0;
            f_adv  <= 3'd0;
            for (n = 0; n < 3; n = n + 1) b_vsub[n] <= 3'd0;
        end else if (hc == HVIS || !en_p) begin
            // 1: which layers show on the next line, and whether their pointers move on after it
            for (n = 0; n < 3; n = n + 1) begin
                vmax = 3'd7 >> (2'd3 - l_ctrl[n][9:8]);
                vs_n = (next_line == l_ys[n] || b_vsub[n] == vmax) ? 3'd0 : b_vsub[n] + 1'b1;
                b_act[n] <= en_p && l_ctrl[n][0] && next_line < VVIS &&
                            next_line >= l_ys[n] && next_line < l_ye[n];
                b_adv[n] <= (vs_n == vmax);
                if (next_line >= l_ys[n] && next_line < l_ye[n]) b_vsub[n] <= vs_n;
            end
        end else if (hc == HVIS + 1'b1) begin
            // 2: first pixel, groups to fetch, line length
            for (n = 0; n < 3; n = n + 1) begin
                w      = l_xe[n] - l_xs[n];
                srcpix = (w + (3'd7 >> (2'd3 - l_ctrl[n][7:6]))) >> l_ctrl[n][7:6];
                // a group is 16 source pixels in either format
                bits = l_ctrl[n][1] ? {3'd0, srcpix} : {3'd0, srcpix} << l_ctrl[n][3:2];   // per plane line
                fine = l_sx[n];
                n_pos0[n]   <= fine;
                n_groups[n] <= ({10'd0, fine} + {3'd0, srcpix} + 14'd15) >> 4;
                n_len[n]    <= (bits + 14'd15) >> 4;
            end
        end else if (hc == HVIS + 2'd2) begin
            // 3: hand over
            f_act  <= b_act;
            f_adv  <= b_adv;
            line_t <= ~line_t;
            c_act  <= b_act;
            for (n = 0; n < 3; n = n + 1) begin
                f_groups[n] <= n_groups[n];
                f_len[n]    <= n_len[n];
                f_planes[n] <= l_ctrl[n][1] ? l_ctrl[n][18:16] : (3'd1 << l_ctrl[n][3:2]) - 1'b1;
                f_chunky[n] <= !l_ctrl[n][1];
                f_hs[n]     <= l_ctrl[n][7:6];
                c_xs[n]     <= l_xs[n];
                c_xe[n]     <= l_xe[n];
                c_planar[n] <= l_ctrl[n][1];
                c_lb[n]     <= l_ctrl[n][3:2];
                c_transp[n] <= l_ctrl[n][4];
                c_hs[n]     <= l_ctrl[n][7:6];
                c_palofs[n] <= l_ctrl[n][15:12];
                c_planes[n] <= l_ctrl[n][18:16];
                c_pos0[n]   <= n_pos0[n];
            end
        end
    end

    // ---- bitplane DMA and registers (100 MHz)
    wire [383:0] dat;
    wire [2:0]   fill_t, take_t;
    wire         line_go, line_gen;
    bpldma dma (
        .clk(clk), .rst(rst), .enable(fetch_en),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(dma_q),
        .line_t(line_t), .act(f_act), .adv(f_adv),
        .planes({f_planes[2], f_planes[1], f_planes[0]}), .chunky(f_chunky), .hscale({f_hs[2], f_hs[1], f_hs[0]}),
        .wrap({l_ctrl[2][23:20], l_ctrl[1][23:20], l_ctrl[0][23:20]}),
        .ngroups({f_groups[2], f_groups[1], f_groups[0]}),
        .len({f_len[2], f_len[1], f_len[0]}),
        .line_go(line_go), .line_gen(line_gen),
        .dat(dat), .fill_t(fill_t), .take_t(take_t),
        .req(disp_req), .urgent(disp_urgent), .deadline(disp_deadline), .addr(disp_addr), .ack(disp_ack), .rvalid(disp_rvalid), .rdata(disp_rdata)
    );

    // ---- layer units: their output is stage 1
    wire [2:0] bl_op;
    wire [7:0] bl_idx [0:2], bl_raw [0:2];
    // The layer units may take this line's first group once the DMA has
    // restarted (line_gen caught up) and the handshake has crossed back
    reg  [1:0] lg_s;
    always @(posedge clk_pix) lg_s <= {lg_s[0], line_gen};
    wire       buf_ready = (lg_s[1] == line_t) && (hc >= HVIS + 4'd8 || hc < HVIS);
    genvar g;
    generate for (g = 0; g < 3; g = g + 1) begin : lay
        layer_pix u (
            .clk_pix(clk_pix), .clk_pix5(clk_pix5), .en(en_p), .hc(hc), .hn(hn), .line_start(hc == HVIS), .ready(buf_ready),
            .active(c_act[g]), .xs(c_xs[g]), .xe(c_xe[g]), .planar(c_planar[g]), .lb(c_lb[g]),
            .planes(c_planes[g]), .hs(c_hs[g]), .pos0(c_pos0[g]), .transp(c_transp[g]),
            .palofs(c_palofs[g]),
            .dat(dat[128*g +: 128]), .fill_t(fill_t[g]), .take_t(take_t[g]),
            .opaque(bl_op[g]), .idx(bl_idx[g]), .raw(bl_raw[g]), .overrun_t(ov_t[g])
        );
    end endgenerate

    // ---- pipeline: 0 beam, 1 layer pixels, 2 priority, 3 palette read, 4 out
    wire       vis0 = en_p && (hc < HVIS) && (vc < VVIS);
    wire       hs0  = en_p && (hc >= HSS) && (hc < HSE);
    wire       vs0  = en_p && (vc >= VSS) && (vc < VSE);
    reg  [2:0] vis_d, hs_d, vs_d;
    reg  [7:0] pidx2;
    reg        opaque2, opaque3;
    reg [31:0] pal_q3;
    reg [23:0] dc3;                    // direct colour (section 4.9)
    reg        direct2, direct3;

    // Direct colour: each layer gives one channel (L0 red, L1 green, L2 blue),
    // as deep as the layer, widened to 8 bits by repeating its bits
    function [7:0] widen(input [7:0] v, input [3:0] d);
        integer k;
        reg [7:0] top;
        begin
            top   = v << (4'd8 - d);
            widen = top;
            for (k = 1; k < 8; k = k + 1)
                if (k * d < 8) widen = widen | (top >> (k * d));
        end
    endfunction
    wire [3:0] depth [0:2];
    reg  [7:0] ch2 [0:2];
    generate for (g = 0; g < 3; g = g + 1) begin : dep
        assign depth[g] = c_planar[g] ? {1'b0, c_planes[g]} + 4'd1 : 4'd1 << c_lb[g];
    end endgenerate

    always @(posedge clk_pix) begin
        vis_d <= {vis_d[1:0], vis0};
        hs_d  <= {hs_d[1:0], hs0};
        vs_d  <= {vs_d[1:0], vs0};
        // 2: the front-most opaque layer (section 4.8); PRIO value 3 names no layer
        begin : pix
            integer p;
            reg       any;
            reg [7:0] fix;
            reg [1:0] l;
            any = 1'b0;
            fix = 8'd0;
            for (p = 2; p >= 0; p = p - 1) begin
                l = prio_l[2*p +: 2];
                if (l != 2'd3 && bl_op[l]) begin any = 1'b1; fix = bl_idx[l]; end
            end
            opaque2 <= any;
            pidx2   <= fix;
            // Direct colour: on every visible pixel; a layer not showing gives 0
            direct2 <= vidcon[4];
            if (vidcon[4]) opaque2 <= 1'b1;
            for (p = 0; p < 3; p = p + 1) ch2[p] <= widen(bl_raw[p], depth[p]);
        end
        // 3
        pal_q3  <= pal[pidx2];
        opaque3 <= opaque2 && !vidcon[2];
        dc3     <= {ch2[0], ch2[1], ch2[2]};
        direct3 <= direct2;
        // 4: out
        de    <= vis_d[2];
        hsync <= hs_d[2] ^ !SPOL;
        vsync <= vs_d[2] ^ !SPOL;
        rgb   <= !vis_d[2] ? 24'd0 : !opaque3 ? bg_l : direct3 ? dc3 : pal_q3[23:0];
    end
endmodule
