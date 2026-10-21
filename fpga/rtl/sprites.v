// Sprites (spec 9): sprite table, selection, fetch, 16 sprite units,
// depth sort and collision detection.
//
// 100 MHz side:
//   - The sprite table (64 x 32 bytes at 0xE05000). Two copies (one read
//     back by the CPU, one by the fetcher), plus a small copy of the fields
//     selection needs (EN, X, Y, HEIGHT, VSTEP).
//   - Selection, 136 slots before each line: the 64 entries are scanned,
//     one a clock, and up to 16 that cover the line get a sprite unit.
//     More than 16 sets SPROVF.
//   - Fetch: a unit becomes due exactly 128 slots before the slot of its
//     first visible pixel. Due units are fetched one after another: the
//     settings are read from the table, then the line's 1-16 words come
//     through the SRAM controller's sprite port (free-pool cycles first;
//     the CPU's cycle only when the sprite is about to be late).
//   Each unit has two banks of settings and line data, one per line, so a
//   unit can be fetched for the next line while it draws this one.
// Pixel side: the 16 units (sprite_pix.v), the front-most sprite pixel by
// DEPTH then table order, and collisions, collected per frame.
`include "regmap.vh"

module sprites #(
    parameter UNITS = 16                // sprites per line: 16, or 8 (spec 9, open point S1)
) (
    input  wire        clk,            // 100 MHz
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output wire [31:0] rb_rdata,

    input  wire        dma_on,         // DMACON.DMAEN and SPREN, and video on
    input  wire [10:0] htot, hvis, vvis, vtot,         // (hvis is also read on the pixel side)
    input  wire [3:0]  pdiv,
    output reg         ovf_ev,         // 1 clock: SPROVF

    // SRAM controller sprite port
    output reg         spr_req,
    output wire        spr_urgent,
    output reg  [21:1] spr_addr,
    input  wire        spr_ack,
    input  wire        spr_rvalid,
    input  wire [15:0] rdata,

    // Pixel side
    input  wire        clk_pix,
    input  wire        en_p,           // video on
    input  wire [10:0] vc,             // beam line (pixel domain)
    input  wire [10:0] hn,             // the next pixel's position
    input  wire        ls_t,           // toggles at the start of each line (when hc becomes 0)
    input  wire        vb_start,       // 1 pixel clock at the start of vertical blanking
    input  wire        vis3,           // the pixel at stage 3 is visible
    input  wire [3:0]  lay_op,         // stage 4: which layers have a pixel there
    output reg         spr_op,         // stage 3: the front sprite pixel
    output reg  [9:0]  spr_idx,
    output reg  [2:0]  spr_depth,
    output reg         miss_t          // toggles when a sprite missed its deadline
);
    integer n;
    localparam NU = UNITS;
    localparam UW = (NU == 16) ? 4 : 3;    // unit number bits; {bank, unit} is UW + 1 bits

    // ================================================================ registers and the table
    wire [15:0] off      = {rb_addr[15:2], 2'b00};
    wire        in_cust  = (rb_addr[23:16] == 8'hE0);
    wire        sel_reg  = in_cust && (off[15:4] == 12'h020);       // 0x200-0x20F
    wire        sel_tab  = in_cust && (off[15:11] == 5'b01010);     // 0x5000-0x57FF
    wire [5:0]  t_entry  = rb_addr[10:5];
    wire [2:0]  t_word   = rb_addr[4:2];

    reg         sprcon;
    reg  [31:0] hit0_c, hit1_c;        // from the pixel side, last complete frame
    reg  [15:0] clx_c;

    reg [31:0] tab_c [0:511], tab_f [0:511];
    integer i_t;
    initial for (i_t = 0; i_t < 512; i_t = i_t + 1) begin tab_c[i_t] = 32'd0; tab_f[i_t] = 32'd0; end
    reg [31:0] tab_qc, tab_qf;
    reg [8:0]  tf_addr;

    always @(posedge clk) if (rb_wr && sel_tab) begin
        if (rb_be[3]) tab_c[rb_addr[10:2]][31:24] <= rb_wdata[31:24];
        if (rb_be[2]) tab_c[rb_addr[10:2]][23:16] <= rb_wdata[23:16];
        if (rb_be[1]) tab_c[rb_addr[10:2]][15:8]  <= rb_wdata[15:8];
        if (rb_be[0]) tab_c[rb_addr[10:2]][7:0]   <= rb_wdata[7:0];
    end
    always @(posedge clk) tab_qc <= tab_c[rb_addr[10:2]];
    always @(posedge clk) if (rb_wr && sel_tab) begin
        if (rb_be[3]) tab_f[rb_addr[10:2]][31:24] <= rb_wdata[31:24];
        if (rb_be[2]) tab_f[rb_addr[10:2]][23:16] <= rb_wdata[23:16];
        if (rb_be[1]) tab_f[rb_addr[10:2]][15:8]  <= rb_wdata[15:8];
        if (rb_be[0]) tab_f[rb_addr[10:2]][7:0]   <= rb_wdata[7:0];
    end
    always @(posedge clk) tab_qf <= tab_f[tf_addr];

    // The fields selection needs, one byte per memory (LUT RAM)
    reg [7:0]  sh_x0 [0:63], sh_x1 [0:63], sh_y0 [0:63], sh_y1 [0:63];
    reg [7:0]  sh_h0 [0:63], sh_h1 [0:63], sh_v0 [0:63], sh_v1 [0:63];
    reg [63:0] sh_en;
    integer i_s;
    initial for (i_s = 0; i_s < 64; i_s = i_s + 1) begin
        sh_x0[i_s] = 0; sh_x1[i_s] = 0; sh_y0[i_s] = 0; sh_y1[i_s] = 0;
        sh_h0[i_s] = 0; sh_h1[i_s] = 0; sh_v0[i_s] = 0; sh_v1[i_s] = 0;
    end
    always @(posedge clk) if (rb_wr && sel_tab) case (t_word)
        3'd0: begin   // POS
            if (rb_be[0]) sh_x0[t_entry] <= rb_wdata[7:0];
            if (rb_be[1]) sh_x1[t_entry] <= rb_wdata[15:8];
            if (rb_be[2]) sh_y0[t_entry] <= rb_wdata[23:16];
            if (rb_be[3]) sh_y1[t_entry] <= rb_wdata[31:24];
        end
        3'd2: begin   // SIZE
            if (rb_be[0]) sh_h0[t_entry] <= rb_wdata[7:0];
            if (rb_be[1]) sh_h1[t_entry] <= rb_wdata[15:8];
        end
        3'd4: begin   // SCALE: VSTEP
            if (rb_be[2]) sh_v0[t_entry] <= rb_wdata[23:16];
            if (rb_be[3]) sh_v1[t_entry] <= rb_wdata[31:24];
        end
        default: ;
    endcase
    always @(posedge clk)
        if (rst) sh_en <= 64'd0;
        else if (rb_wr && sel_tab && t_word == 3'd3 && rb_be[0]) sh_en[t_entry] <= rb_wdata[0];

    reg [31:0] reg_q;
    reg        rd_tab;
    always @(posedge clk) begin
        if (rst) sprcon <= 1'b0;
        else if (rb_wr && sel_reg && off == `RM_SPRCON && rb_be[0]) sprcon <= rb_wdata[0];
        rd_tab <= rb_rd && sel_tab;
        reg_q  <= 32'd0;
        if (rb_rd && sel_reg) case (off)
            `RM_SPRCON:  reg_q <= {31'd0, sprcon};
            `RM_SPRHIT0: reg_q <= hit0_c;
            `RM_SPRHIT1: reg_q <= hit1_c;
            `RM_CLXGRP:  reg_q <= {16'd0, clx_c};
            default: ;
        endcase
    end
    assign rb_rdata = reg_q | (rd_tab ? tab_qc : 32'd0);

    // ================================================================ beam, in slots
    reg  [2:0]  ls_s;
    always @(posedge clk) ls_s <= {ls_s[1:0], ls_t};
    wire        line_start = (ls_s[2] != ls_s[1]);
    wire        cur_bank   = ls_s[1];                  // bank of the line now on screen
    wire [14:0] cpl        = (htot * pdiv) >> 1;       // clocks per line: HTOTAL x N / 2
    reg  [14:0] lclk;                                  // clocks since the line started
    reg  [3:0]  tdiv;
    reg  [9:0]  T;                                     // slot counter
    always @(posedge clk) begin
        lclk <= line_start ? 15'd0 : lclk + 1'b1;
        if (rst) begin
            tdiv <= 4'd0;
            T    <= 10'd0;
        end else begin
            tdiv <= (tdiv == 4'd9) ? 4'd0 : tdiv + 1'b1;
            if (tdiv == 4'd9) T <= T + 1'b1;
        end
    end
    wire sel_now = (lclk == cpl - 15'd1360);           // 136 slots before the next line

    // ================================================================ units: two banks of 16
    // index {bank, unit}
    (* mem2reg, ram_style = "registers" *) reg u_valid [0:2*NU-1];
    (* mem2reg, ram_style = "registers" *) reg u_issued[0:2*NU-1];
    (* mem2reg, ram_style = "registers" *) reg u_done  [0:2*NU-1];
    // read only by the fetcher, one at a time: small LUT RAMs
    (* ram_style = "distributed" *) reg [5:0]  u_spr [0:2*NU-1];   // sprite number
    (* ram_style = "distributed" *) reg [9:0]  u_src [0:2*NU-1];   // source line (before VFLIP)
    (* ram_style = "distributed" *) reg [11:0] u_x   [0:2*NU-1];   // X (signed)
    (* mem2reg, ram_style = "registers" *) reg [9:0] u_fslot [0:2*NU-1];         // T when the fetch is due
    (* mem2reg, ram_style = "registers" *) reg u_due   [0:2*NU-1];         // the fetch point has been reached
    // drawing settings, written at the fetch point
    (* mem2reg, ram_style = "registers" *) reg [10:0] u_xstart[0:2*NU-1];
    (* mem2reg, ram_style = "registers" *) reg [15:0] u_acc0  [0:2*NU-1];
    (* mem2reg, ram_style = "registers" *) reg [8:0] u_hstep [0:2*NU-1];   // 0x040-0x100
    (* mem2reg, ram_style = "registers" *) reg [1:0] u_wcode [0:2*NU-1];   // width 16 << wcode
    (* mem2reg, ram_style = "registers" *) reg [1:0] u_lb    [0:2*NU-1];
    (* mem2reg, ram_style = "registers" *) reg u_hflip [0:2*NU-1];
    (* mem2reg, ram_style = "registers" *) reg [5:0] u_palofs[0:2*NU-1];
    (* mem2reg, ram_style = "registers" *) reg [2:0] u_depth [0:2*NU-1];
    (* mem2reg, ram_style = "registers" *) reg [15:0] u_coll  [0:2*NU-1];

    // ================================================================ selection
    reg        selecting;
    reg [6:0]  si;                     // entry being read
    reg [10:0] L;                      // the line being selected for
    reg        nb;                     // its bank
    reg [9:0]  t_sel;
    reg [4:0]  nunits;
    // stage A
    reg        a_v;  reg [5:0] a_i;  reg a_en;  reg signed [12:0] a_dy;
    reg [15:0] a_vs; reg [9:0] a_h;  reg signed [11:0] a_x;
    // stage B
    reg        b_v;  reg [5:0] b_i;  reg b_ok;  reg [9:0] b_src; reg signed [11:0] b_x; reg [14:0] b_xn;
    reg [28:0] b_prod;

    wire [11:0] e_x = {sh_x1[si[5:0]][3:0], sh_x0[si[5:0]]};
    wire [11:0] e_y = {sh_y1[si[5:0]][3:0], sh_y0[si[5:0]]};
    wire [9:0]  e_h = {sh_h1[si[5:0]][1:0], sh_h0[si[5:0]]};
    wire [15:0] e_v = {sh_v1[si[5:0]], sh_v0[si[5:0]]};

    wire [28:0] c_fsx  = b_xn * 14'd3277;              // x x N / 20 (exact for these sizes)
    wire [9:0]  c_fs   = c_fsx[25:16];                 // slot of the first visible pixel

    // ================================================================ fetch
    localparam F_IDLE = 3'd0, F_READ = 3'd1, F_CALC = 3'd2, F_ISSUE = 3'd3;
    reg [2:0]  fs;
    reg [UW:0] f_ub;                   // {bank, unit}
    reg [2:0]  f_rc;
    reg [31:0] f_ptr, f_size, f_ctrl, f_scale, f_coll;
    reg [22:0] f_addr;
    reg [4:0]  f_k, f_words;
    reg        f_bad;

    // Due and not yet started: the current line's bank first, then unit order
    reg [2*NU-1:0] due;
    always @(*) for (n = 0; n < 2*NU; n = n + 1)
        due[n] = u_valid[n] && !u_issued[n] && (u_due[n] || T == u_fslot[n]);
    always @(posedge clk) for (n = 0; n < 2*NU; n = n + 1)
        if (!u_valid[n] || u_issued[n]) u_due[n] <= 1'b0;
        else if (T == u_fslot[n])       u_due[n] <= 1'b1;
    reg [UW:0] pick;
    reg        any_due;
    always @(*) begin
        any_due = 1'b0;
        pick    = 0;
        for (n = 2*NU-1; n >= 0; n = n - 1)
            if (due[n ^ (cur_bank << UW)]) begin any_due = 1'b1; pick = n ^ (cur_bank << UW); end
    end
    // Urgent: within 16 slots of the sprite's first pixel
    wire [9:0] f_age = T - u_fslot[f_ub];
    assign spr_urgent = (fs == F_ISSUE) && (f_age >= 10'd112) && (f_age < 10'd512);

    // Reads on the way: {bank, unit, word}
    reg [UW+5:0] q_tag [0:3];          // {bank, unit, last word, word}
    reg [1:0]  q_h, q_t;

    // Line buffers: 16 units x 2 banks x 16 words
    reg        b_we;
    reg [UW-1:0] b_unit;
    reg [4:0]  b_a;
    reg [15:0] b_d;

    // multipliers for the fetch point
    wire signed [27:0] f_off  = $signed({1'b0, f_ctrl[6] ? (f_size[9:0] - u_src[f_ub]) : u_src[f_ub]}) *
                                $signed(f_size[31:16]);
    wire        [11:0] f_negx = 12'd0 - u_x[f_ub];
    wire        [27:0] f_clip = f_negx * f_scale[15:0];                  // (-X) x HSTEP

    always @(posedge clk) begin
        ovf_ev <= 1'b0;
        b_we   <= 1'b0;
        if (rst) begin
            selecting <= 1'b0;
            a_v <= 1'b0; b_v <= 1'b0;
            fs      <= F_IDLE;
            spr_req <= 1'b0;
            q_h <= 2'd0; q_t <= 2'd0;
            for (n = 0; n < 2*NU; n = n + 1) begin
                u_valid[n] <= 1'b0; u_issued[n] <= 1'b0; u_done[n] <= 1'b0;
            end
        end else begin
            // ---- selection
            if (sel_now && !selecting) begin
                selecting <= 1'b1;
                si        <= 7'd0;
                L         <= (vc == vtot - 1'b1) ? 11'd0 : vc + 1'b1;
                nb        <= ~cur_bank;
                t_sel     <= T;
                nunits    <= 5'd0;
                for (n = 0; n < NU; n = n + 1) u_valid[({~cur_bank} << UW) | n] <= 1'b0;
            end
            a_v <= 1'b0;
            if (selecting) begin
                a_v  <= (si < 7'd64);
                a_i  <= si[5:0];
                a_en <= sh_en[si[5:0]] && dma_on && sprcon && (L < vvis);
                a_dy <= $signed({2'b00, L}) - $signed({e_y[11], e_y});
                a_vs <= e_v;
                a_h  <= e_h;
                a_x  <= e_x;
                si   <= si + 1'b1;
                if (si == 7'd66) selecting <= 1'b0;       // stages A and B drained
            end
            b_v <= a_v;
            if (a_v) begin
                b_i    <= a_i;
                b_prod <= a_dy * $signed({1'b0, a_vs});
                b_ok   <= a_en && !a_dy[12] && ($signed(a_x) < $signed({1'b0, hvis}));
                b_x    <= a_x;
                b_xn   <= (a_x[11] ? 11'd0 : a_x[10:0]) * pdiv;
            end
            if (b_v) begin
                if (b_ok && b_prod[27:8] <= {10'd0, a_h_b}) begin
                    if (nunits < NU) begin
                        u_valid [{nb, nunits[UW-1:0]}] <= 1'b1;
                        u_issued[{nb, nunits[UW-1:0]}] <= 1'b0;
                        u_done  [{nb, nunits[UW-1:0]}] <= 1'b0;
                        u_spr   [{nb, nunits[UW-1:0]}] <= b_i;
                        u_src   [{nb, nunits[UW-1:0]}] <= b_prod[17:8];
                        u_x     [{nb, nunits[UW-1:0]}] <= b_x;
                        u_fslot [{nb, nunits[UW-1:0]}] <= t_sel + 10'd8 + c_fs;
                        nunits <= nunits + 1'b1;
                    end else
                        ovf_ev <= 1'b1;
                end
            end

            // ---- fetch: settings from the table, then the line's words
            case (fs)
                F_IDLE: if (any_due) begin
                    f_ub   <= pick;
                    u_issued[pick] <= 1'b1;
                    tf_addr <= {u_spr[pick], 3'd1};            // PTR
                    f_rc   <= 3'd0;
                    fs     <= F_READ;
                end
                F_READ: begin
                    // reads at words 1-5 (PTR, SIZE, CTRL, SCALE, COLL); data a clock later
                    f_rc    <= f_rc + 1'b1;
                    tf_addr <= tf_addr + 1'b1;
                    case (f_rc)
                        3'd1: f_ptr   <= tab_qf;
                        3'd2: f_size  <= tab_qf;
                        3'd3: f_ctrl  <= tab_qf;
                        3'd4: f_scale <= tab_qf;
                        3'd5: begin f_coll <= tab_qf; fs <= F_CALC; end
                        default: ;
                    endcase
                end
                F_CALC: begin : calc
                    reg [6:0] w;
                    reg [1:0] lb;
                    reg [8:0] bits;
                    w  = (f_ctrl[2:1] == 2'd0) ? 7'd16 : (f_ctrl[2:1] == 2'd1) ? 7'd32 : 7'd64;
                    lb = (f_ctrl[4:3] == 2'd0) ? 2'd1 : (f_ctrl[4:3] == 2'd1) ? 2'd2 : 2'd3;
                    bits = {2'b00, w} << lb;
                    f_bad  <= (bits > 9'd256);                   // 64 pixels at 8 bpp: not allowed
                    f_words <= (bits > 9'd256) ? 5'd0 : bits[8:4];
                    f_addr  <= f_ptr[22:0] + f_off[22:0];
                    f_k     <= 5'd0;
                    u_xstart[f_ub] <= u_x[f_ub][11] ? 11'd0 : u_x[f_ub][10:0];
                    u_acc0  [f_ub] <= !u_x[f_ub][11] ? 16'd0 :
                                      (f_clip[27:16] != 0) ? 16'hFFFF : f_clip[15:0];   // off the left: skip
                    u_hstep [f_ub] <= (f_scale[15:0] < 16'h0040) ? 9'h040 :
                                      (f_scale[15:0] > 16'h0100) ? 9'h100 : f_scale[8:0];
                    u_wcode [f_ub] <= (f_ctrl[2:1] == 2'd3) ? 2'd2 : f_ctrl[2:1];
                    u_lb    [f_ub] <= lb;
                    u_hflip [f_ub] <= f_ctrl[5];
                    u_palofs[f_ub] <= f_ctrl[21:16];
                    u_depth [f_ub] <= f_ctrl[10:8];
                    u_coll  [f_ub] <= {u_spr[f_ub], f_coll[11:8], f_coll[7:4], f_coll[1:0]};
                    if (bits > 9'd256) u_valid[f_ub] <= 1'b0;
                    fs <= (bits > 9'd256) ? F_IDLE : F_ISSUE;
                end
                F_ISSUE: if ((!spr_req || spr_ack) && f_k != f_words) begin
                    spr_req  <= 1'b1;
                    spr_addr <= f_addr[21:1];
                    f_addr   <= f_addr + 23'd2;
                    q_tag[q_t + (spr_ack ? 1'b1 : 1'b0)] <= {f_ub, f_k == f_words - 1'b1, f_k[3:0]};
                    f_k      <= f_k + 1'b1;
                end else if (f_k == f_words && (!spr_req || spr_ack))
                    fs <= F_IDLE;
                default: fs <= F_IDLE;
            endcase

            if (spr_ack) begin
                q_t <= q_t + 1'b1;
                if (!(fs == F_ISSUE && f_k != f_words)) spr_req <= 1'b0;
            end
            if (spr_rvalid) begin : back
                reg [UW+5:0] tg;
                reg [UW:0]   ub;
                tg = q_tag[q_h];
                ub = tg[UW+5:5];
                q_h    <= q_h + 1'b1;
                b_we   <= 1'b1;
                b_unit <= ub[UW-1:0];
                b_a    <= {ub[UW], tg[3:0]};
                b_d    <= rdata;
                if (tg[4]) u_done[ub] <= 1'b1;            // the line's last word
            end
        end
    end
    // HEIGHT of the entry in stage B (read again: stage A's copy has moved on)
    reg [9:0] a_h_b;
    always @(posedge clk) if (a_v) a_h_b <= a_h;

    // ================================================================ pixel side
    wire [NU-1:0] u_op;
    wire [9:0]  u_ix [0:NU-1];
    wire [2:0]  u_dp [0:NU-1];
    wire [15:0] u_cl [0:NU-1];
    wire [NU-1:0] u_miss;
    wire        mb = (hn == 11'd0) ? ~ls_t : ls_t;     // bank of the line the next pixel is on

    genvar g;
    generate for (g = 0; g < NU; g = g + 1) begin : unit
        reg  [15:0] lbuf [0:2*NU-1];
        always @(posedge clk) if (b_we && b_unit == g) lbuf[b_a] <= b_d;
        wire [4:0] ra;
        sprite_pix u (
            .clk_pix(clk_pix), .en(en_p), .hn(hn), .bank(ls_t),
            .s_valid(u_valid[(mb * NU + g)]), .s_done(u_done[(mb * NU + g)]),
            .s_xstart(u_xstart[(mb * NU + g)]), .s_acc0(u_acc0[(mb * NU + g)]),
            .s_hstep(u_hstep[(mb * NU + g)]), .s_wcode(u_wcode[(mb * NU + g)]),
            .s_lb(u_lb[(mb * NU + g)]), .s_hflip(u_hflip[(mb * NU + g)]),
            .s_palofs(u_palofs[(mb * NU + g)]), .s_depth(u_depth[(mb * NU + g)]),
            .s_coll(u_coll[(mb * NU + g)]),
            .rd_addr(ra), .rd_data(lbuf[ra]),
            .opaque(u_op[g]), .idx(u_ix[g]), .depth(u_dp[g]), .coll(u_cl[g]), .miss_t(u_miss[g])
        );
    end endgenerate

    // Stage 2: the front sprite pixel: smallest DEPTH, then lowest unit (= table order)
    reg        w_op2;  reg [9:0] w_ix2;  reg [2:0] w_dp2;
    reg [NU-1:0] op2, op3;
    reg [15:0] cl2 [0:NU-1], cl3 [0:NU-1];
    reg [NU-1:0] miss_d;
    always @(posedge clk_pix) begin : front
        integer k;
        reg found;
        reg [2:0] bd;
        reg [9:0] bi;
        found = 1'b0; bd = 3'd7; bi = 10'd0;
        for (k = NU-1; k >= 0; k = k - 1)
            if (u_op[k] && (!found || u_dp[k] <= bd)) begin
                found = 1'b1; bd = u_dp[k]; bi = u_ix[k];
            end
        w_op2 <= found;
        w_ix2 <= bi;
        w_dp2 <= bd;
        // stage 3: out
        spr_op    <= w_op2;
        spr_idx   <= w_ix2;
        spr_depth <= w_dp2;
        // collision data along the same pipeline
        op2 <= u_op;
        op3 <= op2;
        for (k = 0; k < NU; k = k + 1) begin
            cl2[k] <= u_cl[k];
            cl3[k] <= cl2[k];
        end
        // sprite deadlines missed
        miss_d <= u_miss;
        if (|(miss_d ^ u_miss)) miss_t <= ~miss_t;
    end

    // Stage 4: collisions (spec 9, section 7). Each unit collects its hits
    // over the line; in the horizontal blank they are merged into the 64
    // sprite flags, one unit a clock, and the flags are kept over the frame.
    reg [NU-1:0] hit_line;
    reg [63:0] hit_acc;
    reg [15:0] clx_acc;
    reg [63:0] hit_frame;
    reg [15:0] clx_frame;
    reg [4:0]  mi;                     // unit being merged, 16 = none
    always @(posedge clk_pix) begin : coll
        integer k, a, b;
        reg [1:0]  cnt [0:3];
        reg [3:0]  pres;
        reg [NU-1:0] h;
        reg [15:0] c;
        reg [3:0]  other;
        for (a = 0; a < 4; a = a + 1) cnt[a] = 2'd0;
        for (k = 0; k < NU; k = k + 1)
            if (op3[k] && cnt[cl3[k][1:0]] != 2'd2) cnt[cl3[k][1:0]] = cnt[cl3[k][1:0]] + 1'b1;
        for (a = 0; a < 4; a = a + 1) pres[a] = (cnt[a] != 2'd0);
        for (k = 0; k < NU; k = k + 1) begin
            for (a = 0; a < 4; a = a + 1)
                other[a] = (a == cl3[k][1:0]) ? (cnt[a] == 2'd2) : pres[a];
            h[k] = op3[k] && (|(cl3[k][5:2] & other) || |(cl3[k][9:6] & lay_op));
        end
        c = 16'd0;
        for (a = 0; a < 4; a = a + 1)
            for (b = 0; b < 4; b = b + 1)
                if ((a != b) ? (pres[a] && pres[b]) : (cnt[a] == 2'd2)) c[4*a + b] = 1'b1;

        if (!en_p) begin
            hit_line <= 0;
            hit_acc  <= 64'd0;
            clx_acc  <= 16'd0;
            mi       <= 5'd31;
        end else begin
            if (vis3) begin
                hit_line <= hit_line | h;
                clx_acc  <= clx_acc | c;
            end
            // merge, starting at the end of the visible line
            if (hn == hvis + 11'd8) mi <= 5'd0;
            else if (mi < NU) begin
                if (hit_line[mi]) hit_acc[u_cl[mi][15:10]] <= 1'b1;
                hit_line[mi] <= 1'b0;
                mi <= mi + 1'b1;
            end
            if (vb_start) begin
                hit_frame <= hit_acc;
                clx_frame <= clx_acc;
                hit_acc   <= 64'd0;
                clx_acc   <= 16'd0;
            end
        end
    end
    always @(posedge clk) begin
        hit0_c <= hit_frame[31:0];
        hit1_c <= hit_frame[63:32];
        clx_c  <= clx_frame;
    end
endmodule
