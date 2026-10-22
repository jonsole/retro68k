// Audio (spec 6): four sample channels, mixed to stereo at a fixed output
// rate, out through sigma-delta DACs.
//
// Every AUDRATE clocks one engine visits the channels in turn. For each
// playing channel it reads the word holding the sample at its position
// (and the word holding the next sample, if that is another word),
// interpolates between the two, multiplies by the left and right volumes
// into the mix, and moves the position on by STEP, taking the next block
// at the end of this one. After the fourth channel the mix goes to the DACs.
`include "regmap.vh"

module audio (
    input  wire        clk,            // 100 MHz
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output reg  [31:0] rb_rdata,

    input  wire [15:0] dmacon,

    // Memory (dmac.v audio channel): reads
    output reg         mem_req,
    output reg  [21:1] mem_addr,
    input  wire        mem_ack,
    input  wire        mem_rvalid,
    input  wire [15:0] mem_rdata,

    output wire        irq,

    output reg  signed [15:0] out_l,   // the last output sample
    output reg  signed [15:0] out_r,
    output reg         tick_done,      // 1 clock: out_l and out_r are new
    output wire        dac_l,          // sigma-delta streams
    output wire        dac_r,
    output wire        dac_m
);
    // ================================================================ registers
    reg  [15:0] rate;
    reg  [3:0]  stat, inten;
    reg  [1:0]  ctrl [0:3];            // NEAREST (1), BITS16 (0)
    reg  [22:0] lc   [0:3];
    reg  [22:0] len  [0:3];
    reg  [19:0] step [0:3];
    reg  [6:0]  vl   [0:3], vr [0:3];

    // Channel state
    reg  [3:0]  on;
    reg  [22:0] b_start [0:3];         // the block being played
    reg  [22:0] b_len   [0:3];
    reg  [38:0] pos     [0:3];         // 23.16 within the block

    assign irq = |(stat & inten);

    wire [15:0] off = {rb_addr[15:2], 2'b00};
    wire in_custom = (rb_addr[23:16] == 8'hE0);
    wire sel_g  = in_custom && off[15:6] == 10'h010;                     // 0x400-0x43F
    wire [2:0] chn = off[7:5] - 3'd2;                                    // channel n at 0x440 + n x 0x20
    wire sel_c  = in_custom && off[15:8] == 8'h04 && off[7:5] >= 3'd2 && off[7:5] <= 3'd5;

    function [31:0] merge(input [31:0] old, input [31:0] new, input [3:0] be);
        merge = { be[3] ? new[31:24] : old[31:24], be[2] ? new[23:16] : old[23:16],
                  be[1] ? new[15:8]  : old[15:8],  be[0] ? new[7:0]   : old[7:0] };
    endfunction
    function [6:0] vclip(input [6:0] v);
        vclip = (v > 7'd64) ? 7'd64 : v;
    endfunction

    // ================================================================ engine
    localparam E_IDLE = 3'd0, E_CH = 3'd1, E_RD0 = 3'd2, E_RD1 = 3'd3, E_INT = 3'd4,
               E_VOL = 3'd5, E_ADV = 3'd6, E_OUT = 3'd7;
    reg  [2:0]  es;
    reg  [1:0]  ch;
    reg  [15:0] cnt;
    reg  [22:0] a0, a1;                // byte addresses of s0 and s1
    reg  [15:0] d0, d1;
    reg  signed [15:0] s0, s1, smp;
    reg  signed [25:0] acc_l, acc_r;

    wire [15:0] rate_c = (rate < 16'd200) ? 16'd200 : rate;
    wire        tick = (cnt == 16'd0);

    // Positions of the channel being worked on
    wire [22:0] ip   = pos[ch][38:16];
    wire [22:0] ip1  = (ip + 1'b1 < b_len[ch]) ? ip + 1'b1 : ip;
    wire        b16  = ctrl[ch][0];
    wire [22:0] pa0  = b16 ? b_start[ch] + {ip[21:0], 1'b0}  : b_start[ch] + ip;
    wire [22:0] pa1  = b16 ? b_start[ch] + {ip1[21:0], 1'b0} : b_start[ch] + ip1;

    function signed [15:0] pick(input [15:0] w, input [22:0] a, input b16_);
        pick = b16_ ? w : {(a[0] ? w[7:0] : w[15:8]), 8'd0};
    endfunction

    // The next position, and the block it falls in
    wire [38:0] pnext = pos[ch] + {19'd0, step[ch]};
    wire        past  = pnext[38:16] >= b_len[ch];
    wire [38:0] pwrap = pnext - {b_len[ch], 16'd0};

    integer i;
    always @(posedge clk) begin
        tick_done <= 1'b0;
        if (rst) begin
            rate  <= 16'd2083;
            stat  <= 4'd0;
            inten <= 4'd0;
            for (i = 0; i < 4; i = i + 1) begin
                ctrl[i] <= 2'd0; lc[i] <= 23'd0; len[i] <= 23'd0; step[i] <= 20'h10000;
                b_start[i] <= 23'd0; b_len[i] <= 23'd0; pos[i] <= 39'd0;
            end
            vl[0] <= 7'd64; vr[0] <= 7'd0;
            vl[1] <= 7'd0;  vr[1] <= 7'd64;
            vl[2] <= 7'd0;  vr[2] <= 7'd64;
            vl[3] <= 7'd64; vr[3] <= 7'd0;
            on    <= 4'd0;
            es    <= E_IDLE;
            cnt   <= 16'd0;
            mem_req <= 1'b0;
            out_l <= 16'sd0; out_r <= 16'sd0;
        end else begin
            cnt <= tick ? rate_c - 1'b1 : cnt - 1'b1;
            if (mem_ack) mem_req <= 1'b0;

            case (es)
                E_IDLE: if (tick) begin
                    // Channels turned on take their registers; turned off, stop
                    for (i = 0; i < 4; i = i + 1) begin
                        if (dmacon[`RM_DMACON_DMAEN] && dmacon[i]) begin
                            if (!on[i]) begin
                                on[i]      <= 1'b1;
                                b_start[i] <= lc[i];
                                b_len[i]   <= len[i];
                                pos[i]     <= 39'd0;
                                stat[i]    <= 1'b1;
                            end
                        end else on[i] <= 1'b0;
                    end
                    acc_l <= 26'sd0;
                    acc_r <= 26'sd0;
                    ch    <= 2'd0;
                    es    <= E_CH;
                end

                E_CH: if (on[ch] && b_len[ch] != 23'd0) begin
                    a0 <= pa0;
                    a1 <= pa1;
                    mem_req  <= 1'b1;
                    mem_addr <= pa0[21:1];
                    es       <= E_RD0;
                end else es <= E_ADV;

                E_RD0: if (mem_rvalid) begin
                    d0 <= mem_rdata;
                    if (a1[22:1] != a0[22:1]) begin
                        mem_req  <= 1'b1;
                        mem_addr <= a1[21:1];
                        es       <= E_RD1;
                    end else begin
                        d1 <= mem_rdata;
                        es <= E_INT;
                    end
                end

                E_RD1: if (mem_rvalid) begin
                    d1 <= mem_rdata;
                    es <= E_INT;
                end

                E_INT: begin : interp
                    reg signed [16:0] diff;
                    reg signed [33:0] prod;
                    s0   = pick(d0, a0, b16);
                    s1   = pick(d1, a1, b16);
                    diff = s1 - s0;
                    prod = diff * $signed({1'b0, pos[ch][15:0]});
                    smp  <= ctrl[ch][1] ? s0 : s0 + prod[31:16];
                    es   <= E_VOL;
                end

                E_VOL: begin
                    acc_l <= acc_l + smp * $signed({1'b0, vclip(vl[ch])});
                    acc_r <= acc_r + smp * $signed({1'b0, vclip(vr[ch])});
                    es    <= E_ADV;
                end

                E_ADV: begin
                    if (on[ch] && b_len[ch] != 23'd0) begin
                        if (past) begin
                            // On into the next block: take the registers again
                            b_start[ch] <= lc[ch];
                            b_len[ch]   <= len[ch];
                            pos[ch]     <= (pwrap[38:16] < len[ch]) ? pwrap : {23'd0, pwrap[15:0]};
                            stat[ch]    <= 1'b1;
                        end else
                            pos[ch] <= pnext;
                    end
                    if (ch == 2'd3) es <= E_OUT;
                    else begin
                        ch <= ch + 1'b1;
                        es <= E_CH;
                    end
                end

                E_OUT: begin
                    out_l <= acc_l[23:8];
                    out_r <= acc_r[23:8];
                    tick_done <= 1'b1;
                    es <= E_IDLE;
                end
                default: es <= E_IDLE;
            endcase

            // Register writes
            if (rb_wr && sel_g) case (off)
                `RM_AUDRATE:  begin : wr_rate
                    reg [31:0] v;
                    v = merge({16'd0, rate}, rb_wdata, rb_be);
                    rate <= v[15:0];
                end
                `RM_AUDSTAT:  if (rb_be[0]) stat <= stat & ~rb_wdata[3:0];
                `RM_AUDINTEN: if (rb_be[0]) inten <= rb_wdata[3:0];
                default: ;
            endcase
            if (rb_wr && sel_c) begin : wr_ch
                reg [31:0] v;
                case (off[4:0])
                    5'h00: if (rb_be[0]) ctrl[chn] <= {rb_wdata[2], rb_wdata[1]};
                    5'h04: begin v = merge({9'd0, lc[chn]}, rb_wdata, rb_be);  lc[chn]  <= v[22:0]; end
                    5'h08: begin v = merge({9'd0, len[chn]}, rb_wdata, rb_be); len[chn] <= v[22:0]; end
                    5'h0C: begin v = merge({12'd0, step[chn]}, rb_wdata, rb_be); step[chn] <= v[19:0]; end
                    5'h10: begin v = merge({9'd0, vl[chn], 9'd0, vr[chn]}, rb_wdata, rb_be);
                                 vl[chn] <= v[22:16]; vr[chn] <= v[6:0]; end
                    default: ;
                endcase
            end
        end

        // Reads (1 clock)
        rb_rdata <= 32'd0;
        if (rb_rd && sel_g) case (off)
            `RM_AUDRATE:  rb_rdata <= {16'd0, rate};
            `RM_AUDSTAT:  rb_rdata <= {28'd0, stat};
            `RM_AUDINTEN: rb_rdata <= {28'd0, inten};
            default: ;
        endcase
        if (rb_rd && sel_c) case (off[4:0])
            5'h00: rb_rdata <= {29'd0, ctrl[chn][1], ctrl[chn][0], 1'b0};
            5'h04: rb_rdata <= {9'd0, lc[chn]};
            5'h08: rb_rdata <= {9'd0, len[chn]};
            5'h0C: rb_rdata <= {12'd0, step[chn]};
            5'h10: rb_rdata <= {9'd0, vl[chn], 9'd0, vr[chn]};
            5'h14: rb_rdata <= {9'd0, pos[chn][38:16]};
            default: ;
        endcase
    end

    // ================================================================ DACs
    sigma_delta2 sd_l (.clk(clk), .rst(rst), .x(out_l), .y(dac_l));
    sigma_delta2 sd_r (.clk(clk), .rst(rst), .x(out_r), .y(dac_r));
    wire signed [16:0] mono = out_l + out_r;
    sigma_delta2 sd_m (.clk(clk), .rst(rst), .x(mono[16:1]), .y(dac_m));
endmodule

// Second-order sigma-delta modulator: x (16 bits signed) at half of full
// scale, so it stays stable for every input. The average of y is
// 1/2 + x / 2^17.
module sigma_delta2 (
    input  wire               clk,
    input  wire               rst,
    input  wire signed [15:0] x,
    output reg                y
);
    reg signed [23:0] i1, i2;
    wire signed [23:0] fb = y ? 24'sd65536 : -24'sd65536;
    wire signed [23:0] n1 = i1 + x - fb;
    wire signed [23:0] n2 = i2 + n1 - fb;
    always @(posedge clk) begin
        if (rst) begin
            i1 <= 24'sd0;
            i2 <= 24'sd0;
            y  <= 1'b0;
        end else begin
            i1 <= n1;
            i2 <= n2;
            y  <= !n2[23];
        end
    end
endmodule
