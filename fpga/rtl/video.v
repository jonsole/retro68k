// Video (spec 4): programmable timing, palette, background colour, four
// layers (bitmap at 1/2/4/8 bpp fetched from Chip RAM as the beam scans, or
// the text layer), priority, beam position, VBLANK, LINE and OVERRUN.
// Also DMACON (spec 5, section 8), which sits in this register block, and
// the sprites (sprites.v, spec 9).
//
// Two clock domains:
//   clk     100 MHz: registers, palette / text / font writes, interrupts
//   clk_pix 200 MHz / N: the beam and the pixel pipeline
// Both come from the same 200 MHz master (clk_pix is the master gated to
// every Nth edge), so signals cross between them as ordinary related-clock
// paths. Timing registers only change while video is off; layer registers
// are copied into the pixel domain at the start of each horizontal blank.
`include "regmap.vh"

module video #(
    parameter FONT_INIT = "font8x16.hex"
) (
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

    output wire [3:0]  pclkdiv,        // N, for the pixel clock generator
    input  wire        pclk_locked,    // HDMI multiplier locked (PCLKLOCK)

    // DMACON, and the display fetch port of the SRAM controller
    output reg  [15:0] dmacon,
    output wire        wide,
    output wire        disp_req,
    output wire [21:1] disp_addr,
    input  wire        disp_ack,
    input  wire        disp_rvalid,
    input  wire [15:0] disp_rdata,

    // ... and its sprite port (spec 9)
    output wire        spr_req,
    output wire        spr_urgent,
    output wire [21:1] spr_addr,
    input  wire        spr_ack,
    input  wire        spr_rvalid,

    input  wire        clk_pix,
    output reg  [23:0] rgb,
    output reg         hsync,
    output reg         vsync,
    output reg         de
);
    // ================================================================ registers (100 MHz)
    wire [15:0] off      = {rb_addr[15:2], 2'b00};
    wire in_custom = (rb_addr[23:16] == 8'hE0);
    wire sel_reg   = in_custom && (off[15:9] == 7'd0);         // 0x000-0x1FF: global and layers
    wire sel_pal   = in_custom && (off[15:12] == 4'h4);        // 0x4000-0x4FFF
    wire sel_text  = (rb_addr[23:16] == 8'hE1) && (off[15:13] == 3'd0);   // 0xE10000-0xE11FFF
    wire sel_font  = (rb_addr[23:16] == 8'hE1) && (off[15:12] == 4'h2);   // 0xE12000-0xE12FFF

    reg  [2:0]  vidcon;                // BLANKALL, WIDE, EN
    reg  [13:0] vidstat;               // sticky flags (bits 8 and 9 are live, below)
    reg  [13:0] vidinten;
    reg  [10:0] lc_v, lc_h;            // LINECMP
    reg  [23:0] bgcolor;
    reg  [7:0]  prio;
    reg  [10:0] hvis, hss, hse, htot, vvis, vss, vse, vtot;
    reg  [1:0]  syncpol;
    reg  [3:0]  pdiv;
    assign pclkdiv = pdiv;

    // Layers
    reg  [15:0] l_ctrl  [0:3];
    reg  [22:0] l_ptr   [0:3];
    reg  [15:0] l_stride[0:3];
    reg  [10:0] l_xs [0:3], l_xe [0:3], l_ys [0:3], l_ye [0:3];
    reg  [15:0] l_sx [0:3], l_sy [0:3], l_hstep [0:3], l_vstep [0:3];

    // From the pixel domain
    reg  [10:0] p_hc, p_vc;            // beam position
    reg  [15:0] p_frames;
    reg         p_vb_t, p_line_t;      // toggles: vertical blank started, line compare hit
    wire        p_invblank;

    function [31:0] merge(input [31:0] old, input [31:0] new, input [3:0] be);
        merge = { be[3] ? new[31:24] : old[31:24], be[2] ? new[23:16] : old[23:16],
                  be[1] ? new[15:8]  : old[15:8],  be[0] ? new[7:0]   : old[7:0] };
    endfunction

    // HTOTAL x N must be a multiple of 20, with N = 3..8 (section 3.2): a
    // multiple of 4, and of 5. For 5: 16 is 1 more than a multiple of 5, so
    // a number and the sum of its hex digits leave the same remainder.
    // (A plain "% 20" costs a divider: about 2,000 LUTs.)
    wire [14:0] line_master = htot * pdiv;
    wire [5:0]  hexsum      = line_master[3:0] + line_master[7:4] + line_master[11:8] + line_master[14:12];
    wire        five        = (hexsum == 0)  || (hexsum == 5)  || (hexsum == 10) || (hexsum == 15) ||
                              (hexsum == 20) || (hexsum == 25) || (hexsum == 30) || (hexsum == 35) ||
                              (hexsum == 40) || (hexsum == 45) || (hexsum == 50);
    wire        timing_ok   = (pdiv >= 4'd3) && (pdiv <= 4'd8) && (line_master[1:0] == 2'b00) && five &&
                              (hvis != 0) && (hvis < htot) && (vvis != 0) && (vvis < vtot);

    reg  [1:0] vb_s, ln_s, sm_s;
    wire       spr_miss_t, spr_ovf;
    reg  [1:0] ov_s [0:3];
    wire [3:0] ov_t;
    integer    i;
    reg [31:0] reg_q;

    always @(posedge clk) begin
        if (rst) begin
            vidcon   <= 3'd0;
            vidstat  <= 14'd0;
            vidinten <= 14'd0;
            lc_v     <= 11'd0;  lc_h <= 11'd0;
            bgcolor  <= 24'd0;
            prio     <= 8'hE4;          // L0 in front, L3 at the back
            // 640x480 at 59.5 Hz, N = 8 (section 3.5)
            hvis <= 11'd640; hss <= 11'd656; hse <= 11'd752; htot <= 11'd800;
            vvis <= 11'd480; vss <= 11'd490; vse <= 11'd492; vtot <= 11'd525;
            syncpol <= 2'b00;
            pdiv    <= 4'd8;
            for (i = 0; i < 4; i = i + 1) begin
                l_ctrl[i] <= 16'd0;  l_ptr[i] <= 23'd0;  l_stride[i] <= 16'd0;
                l_xs[i] <= 11'd0;    l_xe[i] <= 11'd640; l_ys[i] <= 11'd0;   l_ye[i] <= 11'd480;
                l_sx[i] <= 16'd0;    l_sy[i] <= 16'd0;
                l_hstep[i] <= 16'h0100; l_vstep[i] <= 16'h0100;
            end
            vb_s <= 2'b00; ln_s <= 2'b00;
            dmacon <= 16'd0;
            for (i = 0; i < 4; i = i + 1) ov_s[i] <= 2'b00;
        end else begin
            for (i = 0; i < 4; i = i + 1) begin
                ov_s[i] <= {ov_s[i][0], ov_t[i]};
                if (ov_s[i][1] != ov_s[i][0]) vidstat[4 + i] <= 1'b1;
            end
            // Events from the pixel domain
            sm_s <= {sm_s[0], spr_miss_t};
            if (sm_s[1] != sm_s[0]) vidstat[11] <= 1'b1;      // SPRMISS
            if (spr_ovf)            vidstat[12] <= 1'b1;      // SPROVF
            vb_s <= {vb_s[0], p_vb_t};
            ln_s <= {ln_s[0], p_line_t};
            if (vb_s[1] != vb_s[0]) vidstat[0] <= 1'b1;
            if (ln_s[1] != ln_s[0]) vidstat[1] <= 1'b1;

            if (rb_wr && sel_reg) begin
                if (off[8]) begin : wlayer
                    integer n;
                    reg [31:0] v;
                    n = off[7:6];
                    case (off[5:0])
                        6'h00: begin v = merge({16'd0, l_ctrl[n]}, rb_wdata, rb_be);   l_ctrl[n]   <= v[15:0]; end
                        6'h04: begin v = merge({9'd0, l_ptr[n]}, rb_wdata, rb_be);     l_ptr[n]    <= v[22:0]; end
                        6'h08: begin v = merge({16'd0, l_stride[n]}, rb_wdata, rb_be); l_stride[n] <= v[15:0]; end
                        6'h0C: begin v = merge({5'd0, l_xs[n], 5'd0, l_xe[n]}, rb_wdata, rb_be);
                                     l_xs[n] <= v[26:16]; l_xe[n] <= v[10:0]; end
                        6'h10: begin v = merge({5'd0, l_ys[n], 5'd0, l_ye[n]}, rb_wdata, rb_be);
                                     l_ys[n] <= v[26:16]; l_ye[n] <= v[10:0]; end
                        6'h14: begin v = merge({16'd0, l_sx[n]}, rb_wdata, rb_be);     l_sx[n]     <= v[15:0]; end
                        6'h18: begin v = merge({16'd0, l_sy[n]}, rb_wdata, rb_be);     l_sy[n]     <= v[15:0]; end
                        6'h1C: begin v = merge({16'd0, l_hstep[n]}, rb_wdata, rb_be);  l_hstep[n]  <= v[15:0]; end
                        6'h20: begin v = merge({16'd0, l_vstep[n]}, rb_wdata, rb_be);  l_vstep[n]  <= v[15:0]; end
                        default: ;
                    endcase
                end else begin : wglobal
                    reg [31:0] v;
                    case (off)
                        `RM_VIDCON: begin
                            v = merge({29'd0, vidcon}, rb_wdata, rb_be);
                            if (v[0] && !vidcon[0] && !timing_ok) begin
                                vidstat[10] <= 1'b1;            // BADTIMING: stay off
                                vidcon <= {v[2:1], 1'b0};
                            end else
                                vidcon <= v[2:0];
                        end
                        `RM_VIDSTAT:   if (rb_be[0] | rb_be[1]) vidstat <= vidstat & ~rb_wdata[13:0];
                        `RM_VIDINTEN:  begin v = merge({18'd0, vidinten}, rb_wdata, rb_be); vidinten <= v[13:0]; end
                        `RM_LINECMP:   begin v = merge({5'd0, lc_v, 5'd0, lc_h}, rb_wdata, rb_be);
                                             lc_v <= v[26:16]; lc_h <= v[10:0]; end
                        `RM_BGCOLOR:   begin v = merge({8'd0, bgcolor}, rb_wdata, rb_be); bgcolor <= v[23:0]; end
                        `RM_PRIO:      begin v = merge({24'd0, prio}, rb_wdata, rb_be); prio <= v[7:0]; end
                        `RM_DMACON:    if (rb_be[1:0] == 2'b11) begin              // set/clear (spec 3, rule 6)
                            if (rb_wdata[15]) dmacon <= dmacon | (rb_wdata[14:0] & 15'h03F8);
                            else              dmacon <= dmacon & ~(rb_wdata[14:0] & 15'h03F8);
                        end
                        default: if (!vidcon[0]) case (off)          // timing: video off only
                            `RM_HVISIBLE:   begin v = merge({21'd0, hvis}, rb_wdata, rb_be); hvis <= v[10:0]; end
                            `RM_HSYNCSTART: begin v = merge({21'd0, hss},  rb_wdata, rb_be); hss  <= v[10:0]; end
                            `RM_HSYNCEND:   begin v = merge({21'd0, hse},  rb_wdata, rb_be); hse  <= v[10:0]; end
                            `RM_HTOTAL:     begin v = merge({21'd0, htot}, rb_wdata, rb_be); htot <= v[10:0]; end
                            `RM_VVISIBLE:   begin v = merge({21'd0, vvis}, rb_wdata, rb_be); vvis <= v[10:0]; end
                            `RM_VSYNCSTART: begin v = merge({21'd0, vss},  rb_wdata, rb_be); vss  <= v[10:0]; end
                            `RM_VSYNCEND:   begin v = merge({21'd0, vse},  rb_wdata, rb_be); vse  <= v[10:0]; end
                            `RM_VTOTAL:     begin v = merge({21'd0, vtot}, rb_wdata, rb_be); vtot <= v[10:0]; end
                            `RM_SYNCPOL:    begin v = merge({30'd0, syncpol}, rb_wdata, rb_be); syncpol <= v[1:0]; end
                            `RM_PCLKDIV:    begin v = merge({28'd0, pdiv}, rb_wdata, rb_be); pdiv <= v[3:0]; end
                            default: ;
                        endcase
                    endcase
                end
            end
        end

        reg_q <= 32'd0;
        if (rb_rd && sel_reg) begin
            if (off[8]) begin : rlayer
                integer n;
                n = off[7:6];
                case (off[5:0])
                    6'h00: reg_q <= {16'd0, l_ctrl[n]};
                    6'h04: reg_q <= {9'd0, l_ptr[n]};
                    6'h08: reg_q <= {16'd0, l_stride[n]};
                    6'h0C: reg_q <= {5'd0, l_xs[n], 5'd0, l_xe[n]};
                    6'h10: reg_q <= {5'd0, l_ys[n], 5'd0, l_ye[n]};
                    6'h14: reg_q <= {16'd0, l_sx[n]};
                    6'h18: reg_q <= {16'd0, l_sy[n]};
                    6'h1C: reg_q <= {16'd0, l_hstep[n]};
                    6'h20: reg_q <= {16'd0, l_vstep[n]};
                    default: ;
                endcase
            end else case (off)
                `RM_VIDCON:     reg_q <= {29'd0, vidcon};
                `RM_VIDSTAT:    reg_q <= {18'd0, vidstat[13:10], pclk_locked, p_invblank, vidstat[7:0]};
                `RM_VIDINTEN:   reg_q <= {18'd0, vidinten};
                `RM_BEAMPOS:    reg_q <= {5'd0, p_vc, 5'd0, p_hc};
                `RM_FRAMECOUNT: reg_q <= {16'd0, p_frames};
                `RM_LINECMP:    reg_q <= {5'd0, lc_v, 5'd0, lc_h};
                `RM_BGCOLOR:    reg_q <= {8'd0, bgcolor};
                `RM_PRIO:       reg_q <= {24'd0, prio};
                `RM_DMACON:     reg_q <= {16'd0, dmacon};
                `RM_HVISIBLE:   reg_q <= {21'd0, hvis};
                `RM_HSYNCSTART: reg_q <= {21'd0, hss};
                `RM_HSYNCEND:   reg_q <= {21'd0, hse};
                `RM_HTOTAL:     reg_q <= {21'd0, htot};
                `RM_VVISIBLE:   reg_q <= {21'd0, vvis};
                `RM_VSYNCSTART: reg_q <= {21'd0, vss};
                `RM_VSYNCEND:   reg_q <= {21'd0, vse};
                `RM_VTOTAL:     reg_q <= {21'd0, vtot};
                `RM_SYNCPOL:    reg_q <= {30'd0, syncpol};
                `RM_PCLKDIV:    reg_q <= {28'd0, pdiv};
                default: ;      // SLOTPOS: with the display fetch
            endcase
        end
    end

    reg  [2:0] lt_s;
    always @(posedge clk) lt_s <= {lt_s[1:0], line_t};
    assign line_tick  = lt_s[2] != lt_s[1];
    assign frame_tick = vb_s[1] != vb_s[0];

    wire [13:0] irqflags = vidstat & vidinten;
    assign irq_vblank = irqflags[0];
    assign irq_line   = irqflags[1];
    assign irq_viderr = |irqflags[7:4] | irqflags[10] | irqflags[11] | irqflags[12];

    // ================================================================ block RAMs
    // Each memory is kept twice, written together from the CPU side
    // (100 MHz, 32-bit with byte enables): one copy is read back by the CPU,
    // the other by the pixel side. Simple one-write, one-read block RAMs map
    // the same way in every tool.
    reg [31:0] pal  [0:1023], pal_c  [0:1023];   // 0x00RRGGBB
    reg [31:0] text [0:2047], text_c [0:2047];   // two 16-bit cells per word, even cell in bits 31-16
    reg [31:0] font [0:1023], font_c [0:1023];   // 4 font rows per word, first row in bits 31-24
    initial $readmemh(FONT_INIT, font);
    initial $readmemh(FONT_INIT, font_c);
    integer k;
    initial for (k = 0; k < 2048; k = k + 1) begin text[k] = 32'd0; text_c[k] = 32'd0; end
    initial for (k = 0; k < 1024; k = k + 1) begin pal[k] = 32'd0;  pal_c[k] = 32'd0;  end

    reg [31:0] pal_qa, text_qa, font_qa;
    reg [1:0]  rd_area;                // which memory the last read came from
    localparam A_REG = 2'd0, A_PAL = 2'd1, A_TEXT = 2'd2, A_FONT = 2'd3;

    always @(posedge clk) if (rb_wr && sel_pal) begin
        if (rb_be[3]) pal[rb_addr[11:2]][31:24] <= rb_wdata[31:24];
        if (rb_be[2]) pal[rb_addr[11:2]][23:16] <= rb_wdata[23:16];
        if (rb_be[1]) pal[rb_addr[11:2]][15:8]  <= rb_wdata[15:8];
        if (rb_be[0]) pal[rb_addr[11:2]][7:0]   <= rb_wdata[7:0];
    end
    always @(posedge clk) begin
        if (rb_wr && sel_pal) begin
            if (rb_be[3]) pal_c[rb_addr[11:2]][31:24] <= rb_wdata[31:24];
            if (rb_be[2]) pal_c[rb_addr[11:2]][23:16] <= rb_wdata[23:16];
            if (rb_be[1]) pal_c[rb_addr[11:2]][15:8]  <= rb_wdata[15:8];
            if (rb_be[0]) pal_c[rb_addr[11:2]][7:0]   <= rb_wdata[7:0];
        end
        pal_qa <= pal_c[rb_addr[11:2]];
    end
    always @(posedge clk) if (rb_wr && sel_text) begin
        if (rb_be[3]) text[rb_addr[12:2]][31:24] <= rb_wdata[31:24];
        if (rb_be[2]) text[rb_addr[12:2]][23:16] <= rb_wdata[23:16];
        if (rb_be[1]) text[rb_addr[12:2]][15:8]  <= rb_wdata[15:8];
        if (rb_be[0]) text[rb_addr[12:2]][7:0]   <= rb_wdata[7:0];
    end
    always @(posedge clk) begin
        if (rb_wr && sel_text) begin
            if (rb_be[3]) text_c[rb_addr[12:2]][31:24] <= rb_wdata[31:24];
            if (rb_be[2]) text_c[rb_addr[12:2]][23:16] <= rb_wdata[23:16];
            if (rb_be[1]) text_c[rb_addr[12:2]][15:8]  <= rb_wdata[15:8];
            if (rb_be[0]) text_c[rb_addr[12:2]][7:0]   <= rb_wdata[7:0];
        end
        text_qa <= text_c[rb_addr[12:2]];
    end
    always @(posedge clk) if (rb_wr && sel_font) begin
        if (rb_be[3]) font[rb_addr[11:2]][31:24] <= rb_wdata[31:24];
        if (rb_be[2]) font[rb_addr[11:2]][23:16] <= rb_wdata[23:16];
        if (rb_be[1]) font[rb_addr[11:2]][15:8]  <= rb_wdata[15:8];
        if (rb_be[0]) font[rb_addr[11:2]][7:0]   <= rb_wdata[7:0];
    end
    always @(posedge clk) begin
        if (rb_wr && sel_font) begin
            if (rb_be[3]) font_c[rb_addr[11:2]][31:24] <= rb_wdata[31:24];
            if (rb_be[2]) font_c[rb_addr[11:2]][23:16] <= rb_wdata[23:16];
            if (rb_be[1]) font_c[rb_addr[11:2]][15:8]  <= rb_wdata[15:8];
            if (rb_be[0]) font_c[rb_addr[11:2]][7:0]   <= rb_wdata[7:0];
        end
        font_qa <= font_c[rb_addr[11:2]];
    end
    reg rd_hit;
    always @(posedge clk) begin
        rd_hit  <= rb_rd && (sel_pal || sel_text || sel_font);
        rd_area <= sel_pal ? A_PAL : sel_text ? A_TEXT : sel_font ? A_FONT : A_REG;
    end
    wire [31:0] spr_rdata;
    assign rb_rdata = reg_q | spr_rdata | (!rd_hit ? 32'd0 :
                               rd_area == A_PAL  ? {8'd0, pal_qa[23:0]} :
                               rd_area == A_TEXT ? text_qa :
                               rd_area == A_FONT ? font_qa : 32'd0);

    // ================================================================ pixel domain
    reg [1:0] rst_p;
    always @(posedge clk_pix) rst_p <= {rst_p[0], rst};
    wire prst = rst_p[1];

    reg en_p;
    always @(posedge clk_pix) en_p <= !prst && vidcon[0];

    // ---- beam
    reg [10:0] hc, vc;
    wire hlast = (hc == htot - 1'b1);
    wire vlast = (vc == vtot - 1'b1);
    wire [10:0] hn = hlast ? 11'd0 : hc + 1'b1;
    wire [10:0] vn = hlast ? (vlast ? 11'd0 : vc + 1'b1) : vc;
    assign p_invblank = (p_vc >= vvis);

    reg ls_t = 1'b0;                   // toggles when a line starts (hc becomes 0)
    always @(posedge clk_pix) begin
        if (!en_p) begin
            hc <= 11'd0;
            vc <= 11'd0;
        end else begin
            hc <= hn;
            vc <= vn;
            if (hn == 11'd0) ls_t <= ~ls_t;
        end
        p_hc <= hc;
        p_vc <= vc;
        if (prst) begin
            p_vb_t   <= 1'b0;
            p_line_t <= 1'b0;
            p_frames <= 16'd0;
        end else if (en_p) begin
            if (hc == 11'd0 && vc == vvis) begin
                p_vb_t   <= ~p_vb_t;
                p_frames <= p_frames + 1'b1;
            end
            if (hc == lc_h && vc == lc_v) p_line_t <= ~p_line_t;
        end
    end

    // ---- text layer: the lowest-numbered layer with EN and TYPE = text
    reg [1:0] tsel;
    reg       tfound;
    always @(*) begin
        tfound = 1'b0;
        tsel   = 2'd0;
        for (i = 3; i >= 0; i = i - 1)
            if (l_ctrl[i][0] && l_ctrl[i][1]) begin tfound = 1'b1; tsel = i; end
    end

    // Copied at the start of each horizontal blank (section 5.6)
    reg        t_on, t_transp;
    reg [1:0]  t_layer;
    reg [9:0]  t_palofs;
    reg [11:0] t_ptr;
    reg [10:0] t_xs, t_xe, t_ys, t_ye;
    reg [15:0] t_sx, t_sy, t_hstep, t_vstep;
    always @(posedge clk_pix) if (!en_p || hc == hvis) begin
        t_on     <= tfound;
        t_layer  <= tsel;
        t_transp <= l_ctrl[tsel][4];
        t_palofs <= l_ctrl[tsel][15:6];
        t_ptr    <= l_ptr[tsel][11:0];
        t_xs     <= l_xs[tsel];  t_xe <= l_xe[tsel];
        t_ys     <= l_ys[tsel];  t_ye <= l_ye[tsel];
        t_sx     <= l_sx[tsel];  t_sy <= l_sy[tsel];
        t_hstep  <= l_hstep[tsel];
        t_vstep  <= l_vstep[tsel];
    end

    // Source position, 16.8 fixed point (section 4.5)
    reg [23:0] hacc, vacc;
    always @(posedge clk_pix) begin
        if (!en_p) begin
            hacc <= {t_sx, 8'd0};
            vacc <= {t_sy, 8'd0};
        end else begin
            hacc <= (hn == t_xs) ? {t_sx, 8'd0} : hacc + t_hstep;
            if (hlast) vacc <= (vn == t_ys) ? {t_sy, 8'd0} : vacc + t_vstep;
        end
    end

    // ---- bitmap layers: settings for the next line, worked out in the
    // horizontal blank (clocks hvis to hvis + 2), then handed to the fetcher
    wire [10:0] next_line = (vc == vtot - 1'b1) ? 11'd0 : vc + 1'b1;
    reg  [23:0] b_vacc   [0:3];        // source line, 16.8
    reg  [22:0] b_ptr_was[0:3];
    reg  [3:0]  b_act;                 // active on the next line
    reg  [22:0] b_line   [0:3];        // byte address of the next line
    reg  [91:0] f_addr;                // for the fetcher
    reg  [47:0] f_words;
    reg  [3:0]  f_act;
    reg         line_t;
    // This line's settings, for the layer units
    reg  [3:0]  c_act;
    reg  [10:0] c_xs [0:3], c_xe [0:3];
    reg  [15:0] c_sx [0:3], c_hstep [0:3];
    reg  [1:0]  c_lb [0:3];
    reg  [3:0]  c_pos0 [0:3];
    reg  [3:0]  c_transp;
    reg  [9:0]  c_palofs [0:3];
    reg  [3:0]  n_pos0 [0:3];

    always @(posedge clk_pix) begin : bmline
        integer n;
        reg [23:0] v;
        reg [31:0] off_l;
        reg [26:0] span;
        reg [19:0] bitoff, bits;
        reg [22:0] st;
        reg [10:0] w;
        if (prst) begin
            line_t <= 1'b0;
            c_act  <= 4'd0;
            f_act  <= 4'd0;
        end else if (hc == hvis || !en_p) begin
            // 1: which layers show on the next line, and their source line
            for (n = 0; n < 4; n = n + 1) begin
                b_act[n] <= en_p && l_ctrl[n][0] && !l_ctrl[n][1] && next_line < vvis &&
                            next_line >= l_ys[n] && next_line < l_ye[n];
                if (next_line == l_ys[n])           v = {l_sy[n], 8'd0};
                else if (l_ptr[n] != b_ptr_was[n])  v = 24'd0;           // PTR written: restart there
                else                                v = b_vacc[n] + l_vstep[n];
                if (next_line >= l_ys[n] && next_line < l_ye[n]) begin
                    b_vacc[n]    <= v;
                    b_ptr_was[n] <= l_ptr[n];
                end
                off_l = $signed({1'b0, v[23:8]}) * $signed(l_stride[n]);
                b_line[n] <= l_ptr[n] + off_l[22:0];
            end
        end else if (hc == hvis + 1'b1) begin
            // 2: first word, bit of the first pixel, words to fetch
            for (n = 0; n < 4; n = n + 1) begin
                w      = l_xe[n] - l_xs[n];
                span   = ((w - 1'b1) * l_hstep[n]) >> 8;                  // source pixels - 1
                bitoff = {b_line[n][0], 3'd0} + ({4'd0, l_sx[n]} << l_ctrl[n][3:2]);
                st     = {b_line[n][22:1], 1'b0} + {bitoff[19:4], 1'b0};
                bits   = bitoff[3:0] + ((span[19:0] + 1'b1) << l_ctrl[n][3:2]);
                f_addr[23*n +: 23]  <= st;
                f_words[12*n +: 12] <= (bits + 5'd31) >> 4;               // one word spare
                n_pos0[n]           <= bitoff[3:0];
            end
        end else if (hc == hvis + 2'd2) begin
            // 3: hand over to the fetcher and the layer units
            f_act  <= b_act;
            line_t <= ~line_t;
            c_act  <= b_act;
            for (n = 0; n < 4; n = n + 1) begin
                c_xs[n]     <= l_xs[n];
                c_xe[n]     <= l_xe[n];
                c_sx[n]     <= l_sx[n];
                c_hstep[n]  <= l_hstep[n];
                c_lb[n]     <= l_ctrl[n][3:2];
                c_pos0[n]   <= n_pos0[n];
                c_transp[n] <= l_ctrl[n][4];
                c_palofs[n] <= l_ctrl[n][15:6];
            end
        end
    end

    // ---- layer buffers: written by the fetcher (100 MHz), read by the layer units
    reg  [15:0] lbuf0 [0:31], lbuf1 [0:31], lbuf2 [0:31], lbuf3 [0:31];
    wire        f_we;
    wire [1:0]  f_layer;
    wire [4:0]  f_index;
    wire [15:0] f_data;
    always @(posedge clk) if (f_we) case (f_layer)
        2'd0: lbuf0[f_index] <= f_data;
        2'd1: lbuf1[f_index] <= f_data;
        2'd2: lbuf2[f_index] <= f_data;
        2'd3: lbuf3[f_index] <= f_data;
    endcase
    wire [23:0] f_wp, f_rp;
    wire [15:0] head [0:3];
    assign head[0] = lbuf0[f_rp[4:0]];
    assign head[1] = lbuf1[f_rp[10:6]];
    assign head[2] = lbuf2[f_rp[16:12]];
    assign head[3] = lbuf3[f_rp[22:18]];

    assign wide = vidcon[1];
    vfetch fetch (
        .clk(clk), .rst(rst), .enable(vidcon[0] && dmacon[9] && dmacon[8]),
        .line_t(line_t), .active(f_act), .start_addr(f_addr), .nwords(f_words), .rp(f_rp),
        .wp(f_wp), .fifo_we(f_we), .fifo_layer(f_layer), .fifo_index(f_index), .fifo_data(f_data),
        .req(disp_req), .addr(disp_addr), .ack(disp_ack), .rvalid(disp_rvalid), .rdata(disp_rdata)
    );

    wire [3:0] bl_op;
    wire [9:0] bl_idx [0:3];
    genvar g;
    generate for (g = 0; g < 4; g = g + 1) begin : lay
        layer_pix u (
            .clk_pix(clk_pix), .en(en_p), .hc(hc), .hn(hn), .new_line(hc == hvis),
            .active(c_act[g]), .xs(c_xs[g]), .xe(c_xe[g]), .sx(c_sx[g]), .hstep(c_hstep[g]),
            .lb(c_lb[g]), .pos0(c_pos0[g]), .transp(c_transp[g]), .palofs(c_palofs[g]),
            .head(head[g]), .wp(f_wp[6*g +: 6]), .rp(f_rp[6*g +: 6]),
            .opaque(bl_op[g]), .idx(bl_idx[g]), .overrun_t(ov_t[g])
        );
    end endgenerate

    // ---- stage 0: where the beam is
    wire [15:0] sx = hacc[23:8];
    wire [15:0] sy = vacc[23:8];
    wire        vis0 = en_p && (hc < hvis) && (vc < vvis);
    wire        win0 = t_on && (hc >= t_xs) && (hc < t_xe) && (vc >= t_ys) && (vc < t_ye);
    wire [11:0] cell0 = t_ptr + {sy[8:4], sx[9:3]};          // wraps round the 128 x 32 buffer
    wire        hs0 = en_p && (hc >= hss) && (hc < hse);
    wire        vs0 = en_p && (vc >= vss) && (vc < vse);

    // ---- pipeline: 1 text read, 2 font read, 3 pixel, 4 palette read, 5 out
    reg [10:0] text_a1;   reg half1;   reg [2:0] px1, px2, px3;   reg [3:0] row1, row2;
    reg [31:0] text_q2, font_q3, pal_q5;
    reg [4:0]  vis_d, win_d, hs_d, vs_d;
    reg [7:0]  attr3;     reg [1:0] rsel3;
    reg [9:0]  pidx4;     reg opaque4, opaque5;
    reg [3:0]  bl_op2, bl_op3;
    reg [9:0]  bl_idx2 [0:3], bl_idx3 [0:3];

    // Stage 4 inputs: each layer's pixel (bitmap units, or the text layer)
    reg  [3:0] lay_op;
    reg  [9:0] lay_ix [0:3];
    always @(*) begin : layers4
        integer p;
        reg [7:0] fbyte;
        reg       bit_on;
        reg [3:0] colour;
        fbyte  = font_q3 >> (8 * (3 - rsel3));
        bit_on = fbyte[7 - px3];
        colour = bit_on ? attr3[3:0] : attr3[7:4];
        for (p = 0; p < 4; p = p + 1) begin
            lay_op[p] = bl_op3[p];
            lay_ix[p] = bl_idx3[p];
        end
        if (t_on) begin
            lay_op[t_layer] = win_d[2] && (bit_on || !(t_transp && attr3[7:4] == 4'd0));
            lay_ix[t_layer] = {t_palofs, 4'd0} + colour;
        end
    end

    // ---- sprites
    wire       spr_op3;
    wire [9:0] spr_idx3;
    wire [2:0] spr_depth3;
    sprites spr (
        .clk(clk), .rst(rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(spr_rdata),
        .dma_on(vidcon[0] && dmacon[9] && dmacon[5]),
        .htot(htot), .hvis(hvis), .vvis(vvis), .vtot(vtot), .pdiv(pdiv), .ovf_ev(spr_ovf),
        .spr_req(spr_req), .spr_urgent(spr_urgent), .spr_addr(spr_addr),
        .spr_ack(spr_ack), .spr_rvalid(spr_rvalid), .rdata(disp_rdata),
        .clk_pix(clk_pix), .en_p(en_p), .vc(vc), .hn(hn), .ls_t(ls_t),
        .vb_start(en_p && hc == 11'd0 && vc == vvis), .vis3(vis_d[2]), .lay_op(lay_op),
        .spr_op(spr_op3), .spr_idx(spr_idx3), .spr_depth(spr_depth3), .miss_t(spr_miss_t)
    );

    reg         half2;
    wire [15:0] cell2 = half2 ? text_q2[15:0] : text_q2[31:16];

    always @(posedge clk_pix) begin
        // 1
        text_a1 <= cell0[11:1];
        half1   <= cell0[0];
        px1     <= sx[2:0];
        row1    <= sy[3:0];
        vis_d   <= {vis_d[3:0], vis0};
        win_d   <= {win_d[3:0], win0};
        hs_d    <= {hs_d[3:0], hs0};
        vs_d    <= {vs_d[3:0], vs0};
        // 2
        text_q2 <= text[text_a1];
        half2   <= half1;
        px2     <= px1;
        row2    <= row1;
        // 3
        font_q3 <= font[{cell2[7:0], row2[3:2]}];
        attr3   <= cell2[15:8];
        rsel3   <= row2[1:0];
        px3     <= px2;
        // bitmap layers: their units give stage 1; delay to stage 3
        bl_op2 <= bl_op;
        bl_op3 <= bl_op2;
        for (i = 0; i < 4; i = i + 1) begin
            bl_idx2[i] <= bl_idx[i];
            bl_idx3[i] <= bl_idx2[i];
        end
        // 4: the front-most of the layers (section 4.8) and the sprite (spec 9, section 6)
        begin : pix
            integer p;
            reg [2:0] front;           // position in PRIO order of the front opaque layer, 4 = none
            reg [9:0] fix;
            front = 3'd4;
            fix   = 10'd0;
            for (p = 3; p >= 0; p = p - 1)
                if (lay_op[prio[2*p +: 2]]) begin front = p; fix = lay_ix[prio[2*p +: 2]]; end
            if (spr_op3 && spr_depth3 <= front) begin
                opaque4 <= 1'b1;
                pidx4   <= spr_idx3;
            end else begin
                opaque4 <= (front != 3'd4);
                pidx4   <= fix;
            end
        end
        // 5
        pal_q5  <= pal[pidx4];
        opaque5 <= opaque4 && !vidcon[2];
        // out
        de    <= vis_d[4];
        hsync <= hs_d[4] ^ !syncpol[0];
        vsync <= vs_d[4] ^ !syncpol[1];
        rgb   <= !vis_d[4] ? 24'd0 : opaque5 ? pal_q5[23:0] : bgcolor;
    end
endmodule
