// DMA engine and blitter (spec 11). 100 MHz.
//
// Four channels share one datapath, which works on one channel at a time
// (the area technique): each channel's job registers (CPU-visible, laid out
// as a descriptor) and its progress through its job are kept in small RAMs.
// The engine picks the next channel with work (round robin), restores its
// progress, runs one group of up to 8 destination words, saves the progress
// and picks again.
//
// A job is rows of pixels, each row a stream of bits. Each destination
// pixel D is MINTERM(A, B, C) bit by bit (BLIT), or C + B (ADD): A the mask
// (a 1 bpp image, B compared with a key colour, or all ones), B the image or
// VALUE, C the destination's old contents. For each destination word of a
// row the B bits are lined up with a barrel shifter fed by the previous and
// the current B word, as in the Amiga's blitter; the A bits come from a
// 32-bit shift register, taking one bit per destination pixel, widened to
// the pixel's bits.
// A backwards (DESC) job uses the same shifter: words are bit-reversed on
// the way in and back again before the combine stage, so only the
// addresses and the edge masks run the other way.
//
// A group is four phases: read up to 9 B words, read up to 9 A words (a mask
// image), read the C words that are needed (when the minterm or ADD uses C,
// and edge words that cover part of a byte), then work out and write each
// destination word.
// Writes are pipelined so a request is ready as each one is taken.
//
// Every word access goes through one access unit, which sends it by address:
//   Chip RAM          the scheduler's DMA engine channel (dmac.v)
//   the custom block  the register bus, a word (a register half) at a time,
//                     as the CPU and copper write them (spec 3, section 2)
//   boot ROM          its second read port
// Reads come back in the order asked. The unit waits for reads of one kind
// (Chip RAM or the rest) to come back before starting the other.
//
// A port job (spec 11, section 4) moves a byte at a time between a port's
// FIFO and memory; a channel whose port is not ready gives up its turn.
`include "regmap.vh"

module dmx #(
    parameter [23:0] CHIP_TOP = 24'h400000
) (
    input  wire        clk,
    input  wire        rst,

    // Register bus (slave)
    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output wire [31:0] rb_rdata,

    // Register bus (master, after the CPU and the copper: muxed in retro68k.v)
    output reg         dx_req,         // held until dx_go
    output reg         dx_we,
    output reg  [23:2] dx_addr,
    output reg  [31:0] dx_wdata,
    output reg  [3:0]  dx_be,
    input  wire        dx_go,          // on the bus this clock
    input  wire [31:0] rb_rdall,       // the bus's read data (every unit's), the clock after a read

    // Memory (dmac.v BLT channel)
    output reg         mem_req,
    output reg         mem_we,
    output reg  [21:1] mem_addr,
    output reg  [15:0] mem_wdata,
    output reg  [1:0]  mem_be,
    input  wire        mem_ack,
    input  wire        mem_rvalid,
    input  wire [15:0] mem_rdata,

    // Boot ROM, second port (read only)
    output reg         rom_en,
    output reg  [14:1] rom_addr,
    input  wire [15:0] rom_rdata,

    // Ports: 0 the SD card (spec 15), 1 the USB serial FIFOs (spec 14)
    input  wire        p0_rxv,         // a received byte is there ...
    input  wire [7:0]  p0_rxd,
    output wire        p0_rxpop,       // ... take it
    input  wire        p0_txr,         // room to send a byte ...
    output wire        p0_txpush,      // ... send this one
    input  wire        p1_rxv,
    input  wire [7:0]  p1_rxd,
    output wire        p1_rxpop,
    input  wire        p1_txr,
    output wire        p1_txpush,
    output reg  [7:0]  p_txd,          // the byte to send, for either

    // The scheduler: the running job's HIGH bit and its channel's CPUSHARE (spec 11, section 5)
    output wire        blt_high,
    output wire [1:0]  blt_share,

    // Timers starting channels (spec 12): as a START written to CHCTRL
    input  wire [3:0]  tmr_start,
    input  wire [7:0]  tmr_ch,

    input  wire [15:0] dmacon,
    output wire        idle,           // no channel busy (the copper's WAIT B)
    output wire [3:0]  irq             // DMA0-DMA3
);
    localparam [22:0] CHIP_WORDS = CHIP_TOP[23:1];

    // The running port job's port (its SRC or DST field: 0 or 1)
    wire        psel;
    wire        p_rxv = psel ? p1_rxv : p0_rxv;
    wire [7:0]  p_rxd = psel ? p1_rxd : p0_rxd;
    wire        p_txr = psel ? p1_txr : p0_txr;
    wire        p_rxpop, p_txpush;
    assign p0_rxpop  = p_rxpop  && !psel;
    assign p1_rxpop  = p_rxpop  &&  psel;
    assign p0_txpush = p_txpush && !psel;
    assign p1_txpush = p_txpush &&  psel;

    // ================================================================ register decode
    wire [15:0] off      = {rb_addr[15:2], 2'b00};
    wire in_custom = (rb_addr[23:16] == 8'hE0);
    wire sel_dmx   = in_custom && off[15:8] == 8'h03;          // 0x300-0x3FF
    wire [1:0] rch = off[7:6];
    wire [3:0] rri = off[5:2];                                 // 0-7 job, 8 CHDESC, 9 CHCTRL, 10 CHSTAT, 11 CHERR
    wire sel_jr    = sel_dmx && !rri[3];
    wire sel_int   = sel_dmx && off[7:0] == 8'hF0;
    wire sel_inten = sel_dmx && off[7:0] == 8'hF4;
    wire sel_dram  = in_custom && off[15:11] == 5'b01100;     // 0x6000-0x67FF

    function [31:0] merge(input [31:0] old, input [31:0] new, input [3:0] be);
        merge = { be[3] ? new[31:24] : old[31:24], be[2] ? new[23:16] : old[23:16],
                  be[1] ? new[15:8]  : old[15:8],  be[0] ? new[7:0]   : old[7:0] };
    endfunction

    // ================================================================ channel registers
    reg  [23:0] chdesc [0:3];
    reg  [23:0] cherr  [0:3];
    reg  [1:0]  cpushare [0:3];
    reg  [3:0]  pause, busy, done, err, stopreq;
    reg  [3:0]  dint, dinten;
    reg  [1:0]  mode [0:3];            // where the channel is in its job
    localparam M_LOAD = 2'd0, M_SETUP = 2'd1, M_ROW = 2'd2, M_RUN = 2'd3;

    assign idle = ~|busy;
    assign irq  = dint & dinten;

    // Job registers: 4 channels x 8 long words, in distributed RAM. Written
    // by the CPU (channel not busy) or by a descriptor load; one write a
    // clock, the CPU first (the load's write waits).
    reg  [31:0] jr [0:31];
    wire        cpu_jw  = rb_wr && sel_jr && !busy[rch];
    reg         eng_jw;
    reg  [4:0]  eng_ja;
    reg  [31:0] eng_jd;
    integer k;
    initial for (k = 0; k < 32; k = k + 1) jr[k] = 32'd0;
    always @(posedge clk) begin
        if (cpu_jw)      jr[{rch, rri[2:0]}] <= merge(jr[{rch, rri[2:0]}], rb_wdata, rb_be);
        else if (eng_jw) jr[eng_ja] <= eng_jd;
    end

    // Descriptor RAM: 512 x 32, on the register bus (the CPU, the copper, or
    // this engine through its own bus master)
    reg  [31:0] dram [0:511];
    reg  [31:0] dq;
    always @(posedge clk) begin
        if (rb_wr && sel_dram) begin
            if (rb_be[3]) dram[rb_addr[10:2]][31:24] <= rb_wdata[31:24];
            if (rb_be[2]) dram[rb_addr[10:2]][23:16] <= rb_wdata[23:16];
            if (rb_be[1]) dram[rb_addr[10:2]][15:8]  <= rb_wdata[15:8];
            if (rb_be[0]) dram[rb_addr[10:2]][7:0]   <= rb_wdata[7:0];
        end
        dq <= dram[rb_addr[10:2]];
    end
    reg dhit;
    always @(posedge clk) dhit <= rb_rd && sel_dram;

    reg [31:0] reg_q;
    assign rb_rdata = reg_q | (dhit ? dq : 32'd0);
    always @(posedge clk) begin
        reg_q <= 32'd0;
        if (rb_rd && sel_dmx) begin
            if (sel_int)        reg_q <= {28'd0, dint};
            else if (sel_inten) reg_q <= {28'd0, dinten};
            else case (rri)
                4'd8:  reg_q <= {8'd0, chdesc[rch]};
                4'd9:  reg_q <= {26'd0, cpushare[rch], pause[rch], 3'd0};
                4'd10: reg_q <= {28'd0, busy[rch] && pause[rch], err[rch], done[rch], busy[rch]};
                4'd11: reg_q <= {8'd0, cherr[rch]};
                default: if (!rri[3]) reg_q <= jr[{rch, rri[2:0]}];
            endcase
        end
    end

    // ================================================================ the working job
    // The channel being worked on. Saved to st[] between groups.
    reg  [2:0]  w_op;
    reg  [7:0]  w_mt;                  // MINTERM
    reg  [1:0]  w_as;                  // ADD: SIGNED, SAT
    reg  [1:0]  w_mask;                // MASK: 0 none, 1 image at APT, 2 key compare
    reg  [1:0]  w_lb;                  // log2 of bits per pixel
    reg         w_desc, w_irq, w_high;
    reg  [1:0]  w_sk, w_dk;            // SRCKIND, DSTKIND
    reg  [31:0] w_val;
    reg  [15:0] w_sstr, w_dstr;
    reg  [26:0] w_nbits;               // bits per row
    reg  [15:0] w_apx;                 // pixels per row (the mask's bits)
    reg  [23:0] w_next;
    reg  [2:0]  w_sbit, w_dbit;
    reg  [15:0] w_rows;                // rows still to do, this one included
    reg  [23:0] w_srow, w_drow;        // this row's first bytes
    reg  [22:0] w_dw, w_sw;            // next destination and source words
    reg  [23:0] w_dleft, w_sleft;      // words of this row still to write and to read
    reg  [3:0]  w_od;                  // the first pixel's bit in its word (from the start side)
    reg  [3:0]  w_t;                   // the shift
    reg         w_pre;                 // read one source word ahead first
    reg         w_first;               // the next word is the row's first
    reg  [3:0]  w_le;                  // bits used in the row's last word (0 = 16)
    reg  [15:0] w_carry;               // the last source word taken
    // The mask image A (MASK = 1): a 1 bpp stream with B's stride
    reg  [23:0] w_arow;                // this row's first byte
    reg  [2:0]  w_abit;
    reg  [22:0] w_aw;                  // next word to read
    reg  [15:0] w_aleft;               // words of this row still to read
    reg  [3:0]  w_ao;                  // the row's first bit in its word (from the start side)
    reg  [31:0] w_areg;                // bits not yet used, from bit 31
    reg  [4:0]  w_acnt;                // how many

    localparam SW = 3+8+2+2+2+1+1+1+2+2+32+16+16+27+16+24+3+3 + 16+24+24 + 23+23+24+24+4+4+1+1+4+16
                    + 24+3+23+16+4+32+5;
    wire [SW-1:0] w_pack = {w_op, w_mt, w_as, w_mask, w_lb, w_desc, w_irq, w_high, w_sk, w_dk, w_val, w_sstr, w_dstr,
                            w_nbits, w_apx, w_next,
                            w_sbit, w_dbit, w_rows, w_srow, w_drow, w_dw, w_sw, w_dleft, w_sleft,
                            w_od, w_t, w_pre, w_first, w_le, w_carry,
                            w_arow, w_abit, w_aw, w_aleft, w_ao, w_areg, w_acnt};
    reg  [SW-1:0] st [0:3];
    reg  [1:0]    cur;
    initial for (k = 0; k < 4; k = k + 1) st[k] = {SW{1'b0}};

    // ================================================================ the datapath
    wire        srcmem  = (w_sk == 2'd0);
    wire        maskimg = (w_mask == 2'd1);
    // Does a minterm nibble (the four B, C combinations) depend on C?
    function cdep(input [3:0] n);
        cdep = (n[3] ^ n[2]) | (n[1] ^ n[0]);
    endfunction
    // Where A is 0 and the minterm's low nibble is 0xA (D = C), or for ADD,
    // the pixel is left alone: at 8 bpp a byte not written, C not read
    wire        keep0   = (w_op == `RM_DMX_OP_ADD) || (w_mt[3:0] == 4'hA);
    // Reads every C word: ADD, or the minterm uses C where A can be 1 (the
    // high nibble), or where A can be 0 (the low nibble, or keeping C in
    // part of a byte)
    wire        op_rd   = (w_op == `RM_DMX_OP_ADD) || cdep(w_mt[7:4])
                          || (w_mask != 2'd0 && (keep0 ? (w_lb != 2'd3) : cdep(w_mt[3:0])));

    function [15:0] rev16(input [15:0] v);
        integer i;
        for (i = 0; i < 16; i = i + 1) rev16[i] = v[15 - i];
    endfunction
    // FILL's value (and the VALUE source) for a destination word
    function [15:0] pattern(input [31:0] v, input [1:0] lb, input odd);
        case (lb)
            2'd3: pattern = odd ? v[15:0] : v[31:16];
            2'd2: pattern = {4{v[3:0]}};
            2'd1: pattern = {8{v[1:0]}};
            default: pattern = {16{v[0]}};
        endcase
    endfunction
    function [15:0] msbs(input [1:0] lb);      // each pixel's top bit
        case (lb)
            2'd3: msbs = 16'h8080;
            2'd2: msbs = 16'h8888;
            2'd1: msbs = 16'hAAAA;
            default: msbs = 16'hFFFF;
        endcase
    endfunction
    function [15:0] smear(input [15:0] f, input [1:0] lb);   // a pixel's top bit to the whole pixel
        integer i;
        begin
            smear = f;
            for (i = 1; i < 8; i = i + 1)
                if (i < (1 << lb)) smear = smear | (f >> i);
        end
    endfunction
    // A's bits for a destination word: bit i of t (from bit 15) to the
    // whole of pixel i
    function [15:0] widen(input [15:0] t, input [1:0] lb);
        integer i;
        for (i = 0; i < 16; i = i + 1) widen[15 - i] = t[15 - (i >> lb)];
    endfunction
    // The Amiga's minterm: each bit of the result is m[a*4 + b*2 + c]
    function [15:0] minterm(input [7:0] m, input [15:0] a, input [15:0] b, input [15:0] c);
        minterm = ({16{m[7]}} &  a &  b &  c) | ({16{m[6]}} &  a &  b & ~c)
                | ({16{m[5]}} &  a & ~b &  c) | ({16{m[4]}} &  a & ~b & ~c)
                | ({16{m[3]}} & ~a &  b &  c) | ({16{m[2]}} & ~a &  b & ~c)
                | ({16{m[1]}} & ~a & ~b &  c) | ({16{m[0]}} & ~a & ~b & ~c);
    endfunction
    // Pixels of s that are not the key colour (all their bits set)
    function [15:0] notkey(input [15:0] s, input [7:0] key, input [1:0] lb);
        reg [15:0] kk, x;
        begin
            kk = pattern({key, key, key, key}, lb, 1'b1);
            x  = s ^ kk;
            case (lb)
                2'd3: notkey = {{8{|x[15:8]}}, {8{|x[7:0]}}};
                2'd2: notkey = {{4{|x[15:12]}}, {4{|x[11:8]}}, {4{|x[7:4]}}, {4{|x[3:0]}}};
                2'd1: notkey = {{2{|x[15:14]}}, {2{|x[13:12]}}, {2{|x[11:10]}}, {2{|x[9:8]}},
                                {2{|x[7:6]}},   {2{|x[5:4]}},   {2{|x[3:2]}},   {2{|x[1:0]}}};
                default: notkey = x;
            endcase
        end
    endfunction
    // Per-pixel add, wrapping or saturating (spec 11, section 3)
    function [15:0] padd(input [15:0] d, input [15:0] s, input [1:0] lb, input sat, input sgn);
        reg [15:0] h, l, t, sum, co, ov, f, dneg;
        begin
            h    = msbs(lb);
            l    = ~h;
            t    = (d & l) + (s & l);                 // no carry crosses a pixel
            sum  = t ^ ((d ^ s) & h);
            co   = ((d & s) | ((d ^ s) & t)) & h;     // carry out of each pixel
            ov   = ~(d ^ s) & (d ^ sum) & h;          // signed overflow
            dneg = smear(d & h, lb);
            if (!sat)
                padd = sum;
            else if (!sgn)
                padd = sum | smear(co, lb);
            else begin
                f    = smear(ov, lb);
                padd = (sum & ~f) | (f & ((dneg & h) | (~dneg & l)));
            end
        end
    endfunction

    // What an address is (spec 11, section 4)
    localparam C_CHIP = 3'd0, C_IMEM = 3'd1, C_ROM = 3'd3, C_BAD = 3'd4;
    function [2:0] cls(input [22:0] w);        // a word address
        if (w < CHIP_WORDS)
            cls = C_CHIP;
        else if (w[22:15] == 8'hE0)            // the custom block
            cls = C_IMEM;
        else if (w[22:14] == 9'b1111_1000_0)   // 0xF80000-0xF87FFF
            cls = C_ROM;
        else
            cls = C_BAD;
    endfunction

    // ================================================================ group buffers
    reg  [15:0] sbuf [0:8];            // source words, in the order read
    reg  [15:0] abuf [0:8];            // mask words, in the order read
    reg  [3:0]  g_na;                  // mask words to read
    reg  [15:0] dbuf [0:7];            // destination words, by position in the group
    reg  [3:0]  g_n;                   // destination words in this group (1-8)
    reg  [3:0]  g_nr;                  // source words to read
    reg  [7:0]  g_dneed;               // destination words to read
    reg  [3:0]  g_last;                // the row's last word in this group (8: none)
    // Known contents from the start: a C word not read still goes through
    // the minterm (its result does not depend on it), and the simulator
    // would carry the unknown bits through
    initial for (k = 0; k < 9; k = k + 1) begin sbuf[k] = 16'd0; abuf[k] = 16'd0; end
    initial for (k = 0; k < 8; k = k + 1) dbuf[k] = 16'd0;

    // ================================================================ engine state
    localparam S_IDLE = 5'd0, S_REST = 5'd1, S_DESC = 5'd2, S_SETUP = 5'd3, S_CHECK = 5'd4,
               S_MUL = 5'd5, S_ROW1 = 5'd6, S_ROW2 = 5'd7, S_ROW3 = 5'd8, S_GRP = 5'd9,
               S_RD = 5'd10, S_DR = 5'd11, S_WR = 5'd12, S_SAVE = 5'd13, S_DRAIN = 5'd14, S_PORT = 5'd15,
               S_RA = 5'd16;
    reg  [4:0]  es;
    reg  [1:0]  last_ch;
    wire        en = dmacon[`RM_DMACON_DMAEN] && dmacon[`RM_DMACON_BLTEN];
    wire [3:0]  runnable = busy & ~pause & {4{en}};

    reg  [4:0]  r_tot, r_iss, r_got;   // reads to make, made, back
    reg  [22:0] r_a;                   // the next address (S_RD, S_DESC)
    reg  [2:0]  q_j [0:7];             // S_DR: each read's place in the group
    reg  [15:0] d_hi;                  // S_DESC: the high half of a long word
    reg         e_bad;                 // stop: an error
    reg  [23:0] e_addr;
    reg  [2:0]  su_i;                  // S_SETUP: job register being read

    // S_DR: the next destination word to read
    reg  [2:0]  dr_j;
    always @(*) begin : drpick
        integer i;
        dr_j = 3'd0;
        for (i = 7; i >= 0; i = i - 1) if (g_dneed[i]) dr_j = i[2:0];
    end
    wire [22:0] dr_a = w_desc ? w_dw - dr_j : w_dw + dr_j;

    // S_WR pipeline: stage A (line up), stage B (combine), then the request
    reg  [3:0]  wj;                    // next word to start
    reg  [3:0]  sptr, aptr;
    reg         a_v, b_v;
    reg  [15:0] a_s, a_m, a_d, a_a;
    reg  [22:0] a_w, b_w;
    reg  [15:0] b_out;
    reg  [1:0]  b_be;
    reg         b_skip;

    // S_PORT
    reg  [3:0]  pc_n;                  // bytes moved in this group
    reg         p_rd, p_have;          // memory to port: the byte asked for; here

    // ================================================================ the access unit
    // The phase's next access
    reg         xq_v, xq_we;
    reg  [22:0] xq_w;
    reg  [15:0] xq_wd;
    reg  [1:0]  xq_be;
    always @(*) begin
        xq_v = 1'b0; xq_we = 1'b0; xq_w = r_a; xq_wd = b_out; xq_be = b_be;
        case (es)
            S_DESC: xq_v = (r_iss < 5'd16) && !e_bad;
            S_RD, S_RA: xq_v = (r_iss < r_tot) && !e_bad;
            S_DR:   begin xq_v = (g_dneed != 8'd0) && !e_bad; xq_w = dr_a; end
            S_WR:   begin xq_v = b_v && !b_skip && !e_bad; xq_we = 1'b1; xq_w = b_w; end
            S_PORT: if (w_sk == 2'd1) begin            // port to memory: a byte at a time
                        xq_v  = p_rxv && pc_n < 4'd8 && w_dleft != 24'd0 && !e_bad;
                        xq_we = 1'b1;
                        xq_w  = w_drow[23:1];
                        xq_wd = {p_rxd, p_rxd};
                        xq_be = w_drow[0] ? 2'b01 : 2'b10;
                    end else begin                     // memory to port: read the byte
                        xq_v  = !p_have && !p_rd && pc_n < 4'd8 && w_dleft != 24'd0 && !e_bad;
                        xq_w  = w_srow[23:1];
                    end
            default: ;
        endcase
    end

    reg  [4:0]  chip_out;              // Chip RAM reads not yet back
    reg         p_lo;                  // the register bus access waiting: its half
    reg         rr_v, rr_lo;           // a register bus read comes back this clock (its half taken from p_lo when it went)
    reg         rom_q, rom_v;          // a ROM read: address out, data back

    wire [2:0]  xq_c    = cls(xq_w);
    wire        xq_bad  = xq_v && (xq_c == C_BAD || (xq_c == C_ROM && xq_we));
    wire        int_ret = rr_v || rom_q || rom_v;                         // internal reads coming back
    wire        chip_ok = (!mem_req || mem_ack) && !dx_req && !int_ret;
    wire        bus_ok  = (!dx_req || dx_go) && chip_out == 5'd0 && !rom_q && !rom_v;
    wire        idle_ok = !dx_req && chip_out == 5'd0 && !int_ret;
    wire        xq_take = xq_v && !xq_bad &&
                          ((xq_c == C_CHIP) ? chip_ok : (xq_c == C_ROM) ? idle_ok : bus_ok);
    assign psel      = (w_sk == 2'd1) ? w_srow[0] : w_drow[0];
    assign p_rxpop   = (es == S_PORT) && (w_sk == 2'd1) && xq_take;
    assign p_txpush  = (es == S_PORT) && (w_dk == 2'd1) && p_have && p_txr;
    assign blt_high  = w_high;
    assign blt_share = cpushare[cur];
    // Reads back, in order
    wire        x_rv = mem_rvalid || rr_v || rom_v;
    wire [15:0] x_rd = mem_rvalid ? mem_rdata :
                       rr_v ? (rr_lo ? rb_rdall[15:0] : rb_rdall[31:16]) : rom_rdata;

    // ================================================================ the write pipeline
    wire        b_take   = b_v && (b_skip || xq_take);
    wire        a_move   = a_v && (!b_v || b_take);
    wire        a_new    = (wj < g_n) && (!a_v || a_move) && !e_bad;

    // Stage A for word wj
    wire        a_hasn   = srcmem && (sptr < g_nr);
    wire [15:0] a_B      = a_hasn ? sbuf[sptr] : 16'd0;
    wire [31:0] a_cat    = {w_carry, a_B} << w_t;
    wire [15:0] a_shp    = a_cat[31:16];
    wire [15:0] m_first  = (w_first && wj == 4'd0) ? (16'hFFFF >> w_od) : 16'hFFFF;
    wire [15:0] m_last   = (wj == g_last) ? ((w_le == 4'd0) ? 16'hFFFF : ~(16'hFFFF >> w_le)) : 16'hFFFF;
    wire [15:0] a_mp     = m_first & m_last;
    wire [22:0] a_wa     = w_desc ? w_dw - wj : w_dw + wj;
    wire [15:0] a_st     = srcmem ? (w_desc ? rev16(a_shp) : a_shp) : pattern(w_val, w_lb, a_wa[0]);
    wire [15:0] a_mt     = w_desc ? rev16(a_mp) : a_mp;
    // the mask image: take 16 >> BPP bits (one a pixel), adding a word first if short
    wire [4:0]  a_k      = 5'd16 >> w_lb;
    wire        a_ins    = (w_acnt < a_k);
    wire [15:0] a_word   = (aptr < g_na) ? abuf[aptr] : 16'd0;
    wire [31:0] a_regi   = a_ins ? (w_areg | ({a_word, 16'd0} >> w_acnt)) : w_areg;
    wire [15:0] a_wide   = widen(a_regi[31:16], w_lb);
    wire [15:0] a_at     = w_desc ? rev16(a_wide) : a_wide;

    // Stage B
    wire [15:0] b_A      = (w_mask == 2'd2) ? notkey(a_s, w_val[7:0], w_lb)
                         : (w_mask == 2'd1) ? a_a : 16'hFFFF;
    wire [15:0] res      = (w_op == `RM_DMX_OP_ADD) ? padd(a_d, a_s, w_lb, w_as[0], w_as[1])
                         : minterm(w_mt, b_A, a_s, a_d);
    wire [15:0] mfin     = a_m & ~(keep0 ? ~b_A : 16'd0);

    // Job setup: checks
    wire        bad_op   = (w_op > `RM_DMX_OP_ADD) || (w_mask == 2'd3);
    wire        portjob  = (w_sk == 2'd1) || (w_dk == 2'd1);
    // DKIND 2 and 3 and BKIND 2 are reserved. A port job is a plain copy:
    // BLIT 0xCC, no mask, memory to port or port to memory
    wire        bad_kind = w_dk[1] || (w_sk == 2'd2)
                         || (portjob && (w_op != `RM_DMX_OP_BLIT || w_mt != 8'hCC || w_mask != 2'd0
                                         || w_sk == 2'd3 || (w_sk == 2'd1 && w_dk == 2'd1)));
    // A port job: linear, 8 bpp, port 0 or 1 (its memory side is checked word by word)
    wire        bad_port = portjob && (w_lb != 2'd3 || w_rows != 16'd1 || w_desc
                           || (w_sk == 2'd1 ? w_srow : w_drow) > 24'd1);

    // Row start
    reg  [26:0] rs_sba, rs_dba, rs_aba;  // the row's first bits
    reg  [32:0] mul_s, mul_d;

    integer i;
    always @(posedge clk) begin
        if (eng_jw && !cpu_jw) eng_jw <= 1'b0;     // a job register write waits for a clock the CPU leaves
        if (rst) begin
            eng_jw <= 1'b0;
            es <= S_IDLE;
            mem_req <= 1'b0; dx_req <= 1'b0; rom_en <= 1'b0;
            chip_out <= 5'd0; rr_v <= 1'b0; rom_q <= 1'b0; rom_v <= 1'b0;
            busy <= 4'd0; done <= 4'd0; err <= 4'd0; pause <= 4'd0; stopreq <= 4'd0;
            dint <= 4'd0; dinten <= 4'd0;
            last_ch <= 2'd3;
            for (i = 0; i < 4; i = i + 1) begin
                cpushare[i] <= 2'd1; chdesc[i] <= 24'd0; cherr[i] <= 24'd0; mode[i] <= M_LOAD;
            end
        end else begin
            // ---------------------------------------------------- the access unit
            if (xq_bad && !e_bad) begin
                e_bad  <= 1'b1;
                e_addr <= {xq_w, 1'b0};
            end
            // Chip RAM: one request, held until taken
            if (xq_take && xq_c == C_CHIP) begin
                mem_req   <= 1'b1;
                mem_we    <= xq_we;
                mem_addr  <= xq_w[20:0];
                mem_wdata <= xq_wd;
                mem_be    <= xq_be;
            end else if (mem_ack)
                mem_req <= 1'b0;
            chip_out <= chip_out + ((xq_take && xq_c == C_CHIP && !xq_we) ? 5'd1 : 5'd0)
                                 - (mem_rvalid ? 5'd1 : 5'd0);
            // The register bus: a register half (or palette word) at a time,
            // the half on the byte enables for reads too
            if (xq_take && xq_c == C_IMEM) begin
                dx_req   <= 1'b1;
                dx_we    <= xq_we;
                dx_addr  <= xq_w[22:1];
                dx_wdata <= {xq_wd, xq_wd};
                dx_be    <= xq_w[0] ? {2'b00, xq_we ? xq_be : 2'b11} : {xq_we ? xq_be : 2'b11, 2'b00};
                p_lo     <= xq_w[0];
            end else if (dx_go)
                dx_req <= 1'b0;
            rr_v <= dx_go && !dx_we;
            if (dx_go) rr_lo <= p_lo;
            // The boot ROM
            rom_q <= xq_take && xq_c == C_ROM;
            if (xq_take && xq_c == C_ROM) rom_addr <= xq_w[13:0];
            rom_en <= xq_take && xq_c == C_ROM;
            rom_v  <= rom_q;

            case (es)
            // ---------------------------------------------------- pick a channel
            S_IDLE: if (|runnable) begin : pick
                integer o;
                reg [1:0] c;
                reg       f;
                f = 1'b0;
                c = last_ch;
                for (o = 0; o < 4; o = o + 1) begin
                    c = c + 1'b1;
                    if (!f && runnable[c]) begin f = 1'b1; cur <= c; end
                end
                es <= S_REST;
            end

            S_REST: begin
                {w_op, w_mt, w_as, w_mask, w_lb, w_desc, w_irq, w_high, w_sk, w_dk, w_val, w_sstr, w_dstr,
                 w_nbits, w_apx, w_next,
                 w_sbit, w_dbit, w_rows, w_srow, w_drow, w_dw, w_sw, w_dleft, w_sleft,
                 w_od, w_t, w_pre, w_first, w_le, w_carry,
                 w_arow, w_abit, w_aw, w_aleft, w_ao, w_areg, w_acnt} <= st[cur];
                last_ch <= cur;
                e_bad   <= 1'b0;
                r_tot <= 5'd0; r_iss <= 5'd0; r_got <= 5'd0;
                su_i  <= 3'd0;
                case (mode[cur])
                    M_LOAD: begin
                        // the descriptor: long-word aligned, in Chip RAM or the descriptor RAM
                        r_a <= chdesc[cur][23:1];
                        if (chdesc[cur][1:0] != 2'd0 ||
                            !((chdesc[cur][23:11] == 13'b1110_0000_0110_0) ||
                              (cls(chdesc[cur][23:1]) == C_CHIP && cls(chdesc[cur][23:1] + 23'd15) == C_CHIP))) begin
                            e_addr <= chdesc[cur];
                            e_bad  <= 1'b1;
                            es     <= S_SAVE;
                        end else
                            es <= S_DESC;
                    end
                    M_SETUP: es <= S_SETUP;
                    M_ROW:   es <= S_ROW1;
                    default: es <= S_GRP;
                endcase
            end

            // ---------------------------------------------------- load a descriptor
            // 16 words, each pair a job register (a long word comes at most
            // every other clock: a waiting job register write has landed by
            // the next)
            S_DESC: begin
                if (xq_take) begin
                    r_a   <= r_a + 1'b1;
                    r_iss <= r_iss + 1'b1;
                end
                if (x_rv) begin
                    r_got <= r_got + 1'b1;
                    if (!r_got[0]) d_hi <= x_rd;
                    else begin
                        eng_jw <= 1'b1;
                        eng_ja <= {cur, r_got[3:1]};
                        eng_jd <= {d_hi, x_rd};
                    end
                end
                if (r_got == 5'd16 && !eng_jw) begin
                    mode[cur] <= M_SETUP;
                    su_i <= 3'd0;
                    es   <= S_SETUP;
                end
            end

            // ---------------------------------------------------- start a job
            S_SETUP: begin : setup
                reg [31:0] v;
                v = jr[{cur, su_i}];
                case (su_i)
                    3'd0: begin w_op <= v[2:0]; w_as <= v[5:4]; w_lb <= v[9:8]; w_desc <= v[10];
                                w_high <= v[11]; w_irq <= v[12]; w_sk <= v[14:13]; w_dk <= v[16:15];
                                w_mask <= v[18:17]; w_mt <= v[31:24]; end
                    3'd1: begin w_srow <= v[23:0]; w_sbit <= v[26:24]; end
                    3'd2: begin w_drow <= v[23:0]; w_dbit <= v[26:24]; end
                    3'd3: begin w_nbits <= {11'd0, v[15:0]};          // the width, for now
                                w_apx <= v[15:0]; w_rows <= v[31:16]; end
                    3'd4: begin w_arow <= v[23:0]; w_abit <= v[26:24]; end
                    3'd5: begin w_sstr <= v[31:16]; w_dstr <= v[15:0]; end
                    3'd6: w_val   <= v;
                    3'd7: w_next  <= v[23:0];
                endcase
                su_i <= su_i + 1'b1;
                if (su_i == 3'd7) es <= S_CHECK;
            end

            S_CHECK: begin
                w_nbits <= w_nbits << w_lb;
                mul_s   <= $signed({1'b0, w_rows - 1'b1}) * $signed(w_sstr);
                mul_d   <= $signed({1'b0, w_rows - 1'b1}) * $signed(w_dstr);
                if (bad_op || bad_kind || bad_port) begin
                    e_addr <= chdesc[cur];
                    e_bad  <= 1'b1;
                    es     <= S_SAVE;
                end else if (w_nbits == 27'd0 || w_rows == 16'd0) begin
                    w_rows <= 16'd0;                 // nothing to do: the job ends
                    es     <= S_SAVE;
                end else if (portjob) begin
                    w_dleft   <= w_nbits[23:0];      // bytes
                    mode[cur] <= M_RUN;
                    es        <= S_GRP;
                end else
                    es <= S_MUL;
            end

            S_MUL: begin
                // backwards: start from the last row
                if (w_desc) begin
                    w_srow <= w_srow + mul_s[23:0];
                    w_arow <= w_arow + mul_s[23:0];
                    w_drow <= w_drow + mul_d[23:0];
                end
                es <= S_ROW1;
            end

            // ---------------------------------------------------- start a row
            S_ROW1: begin
                rs_sba <= {w_srow, 3'b000} + ({24'd0, w_sbit} << w_lb);
                rs_dba <= {w_drow, 3'b000} + ({24'd0, w_dbit} << w_lb);
                rs_aba <= {w_arow, 3'b000} + {24'd0, w_abit};
                es <= S_ROW2;
            end
            S_ROW2: begin : row2
                reg [26:0] se, de, ae;
                se = rs_sba + w_nbits;
                de = rs_dba + w_nbits;
                ae = rs_aba + {11'd0, w_apx};
                if (!w_desc) begin
                    w_ao <= rs_aba[3:0];
                    w_aw <= rs_aba[26:4];
                end else begin
                    w_ao <= 4'd0 - ae[3:0];
                    /* verilator lint_off WIDTHTRUNC */ w_aw <= (ae - 1'b1) >> 4; /* verilator lint_on WIDTHTRUNC */
                end
                if (!w_desc) begin
                    w_od <= rs_dba[3:0];
                    w_dw <= rs_dba[26:4];
                    w_t  <= rs_sba[3:0];          // the source's start bit, for now
                    w_sw <= rs_sba[26:4];
                end else begin
                    w_od <= 4'd0 - de[3:0];
                    /* verilator lint_off WIDTHTRUNC */ w_dw <= (de - 1'b1) >> 4; /* verilator lint_on WIDTHTRUNC */
                    w_t  <= 4'd0 - se[3:0];
                    /* verilator lint_off WIDTHTRUNC */ w_sw <= (se - 1'b1) >> 4; /* verilator lint_on WIDTHTRUNC */
                end
                es <= S_ROW3;
            end
            S_ROW3: begin : row3
                reg [27:0] dn, sn;
                dn = {1'b0, w_nbits} + w_od + 4'd15;
                sn = {1'b0, w_nbits} + w_t + 4'd15;
                w_dleft <= dn[27:4];
                w_sleft <= srcmem ? sn[27:4] : 24'd0;
                w_pre   <= srcmem && (w_t >= w_od);
                w_t     <= srcmem ? w_t - w_od : 4'd0;
                w_le    <= w_od + w_nbits[3:0];
                w_first <= 1'b1;
                /* verilator lint_off WIDTHTRUNC */ w_aleft <= ({4'd0, w_apx} + w_ao + 20'd15) >> 4; /* verilator lint_on WIDTHTRUNC */
                w_acnt  <= 5'd0;
                mode[cur] <= M_RUN;
                es <= S_GRP;
            end

            // ---------------------------------------------------- a group
            S_GRP: if (portjob) begin
                pc_n   <= 4'd0;
                p_rd   <= 1'b0;
                p_have <= 1'b0;
                es     <= S_PORT;
            end else begin : grp
                reg [3:0] n, nr;
                reg [24:0] want;
                reg [7:0] need, avail, extra, na;
                integer j;
                n    = (w_dleft > 24'd8) ? 4'd8 : w_dleft[3:0];
                want = n + w_pre;
                nr   = (want > w_sleft) ? w_sleft[3:0] : want[3:0];
                // mask words: the row's first, then enough for n words of pixels
                need  = {4'd0, n} << (3'd4 - {1'b0, w_lb});
                avail = w_first ? {4'd0, w_od >> w_lb} + 8'd16 - {4'd0, w_ao} : {3'd0, w_acnt};
                extra = (need > avail) ? (need - avail + 8'd15) >> 4 : 8'd0;
                na    = extra + (w_first ? 8'd1 : 8'd0);
                g_na  <= !maskimg ? 4'd0 : ({8'd0, na} > w_aleft) ? w_aleft[3:0] : na[3:0];
                g_n  <= n;
                g_nr <= nr;
                g_last <= (w_dleft > 24'd8) ? 4'd8 : w_dleft[3:0] - 1'b1;
                for (j = 0; j < 8; j = j + 1)
                    g_dneed[j] <= (j < n) && (op_rd || (w_first && j == 0 && w_od[2:0] != 3'd0)
                                              || (j == w_dleft - 1 && w_le[2:0] != 3'd0));
                r_tot <= nr; r_iss <= 5'd0; r_got <= 5'd0;
                r_a   <= w_sw;
                es    <= S_RD;
            end

            S_RD: begin
                if (xq_take) begin
                    r_a   <= w_desc ? r_a - 1'b1 : r_a + 1'b1;
                    r_iss <= r_iss + 1'b1;
                end
                if (x_rv) begin
                    sbuf[r_got[3:0]] <= w_desc ? rev16(x_rd) : x_rd;
                    r_got <= r_got + 1'b1;
                end
                // (a bad access sets e_bad the clock it is seen, so only
                // "nothing left" or e_bad need looking at here: short paths)
                if (r_got == r_iss && (r_iss == r_tot || e_bad) && !mem_req && !dx_req) begin
                    if (e_bad) es <= S_DRAIN;
                    else begin
                        w_sw    <= r_a;
                        w_sleft <= w_sleft - g_nr;
                        r_iss <= 5'd0; r_got <= 5'd0;
                        r_tot <= {1'b0, g_na};
                        r_a   <= w_aw;
                        es    <= (g_na != 4'd0) ? S_RA : S_DR;
                    end
                end
            end

            // the mask image's words, as S_RD
            S_RA: begin
                if (xq_take) begin
                    r_a   <= w_desc ? r_a - 1'b1 : r_a + 1'b1;
                    r_iss <= r_iss + 1'b1;
                end
                if (x_rv) begin
                    abuf[r_got[3:0]] <= w_desc ? rev16(x_rd) : x_rd;
                    r_got <= r_got + 1'b1;
                end
                if (r_got == r_iss && (r_iss == r_tot || e_bad) && !mem_req && !dx_req) begin
                    if (e_bad) es <= S_DRAIN;
                    else begin
                        w_aw    <= r_a;
                        w_aleft <= w_aleft - g_na;
                        r_tot <= 5'd0; r_iss <= 5'd0; r_got <= 5'd0;
                        es <= S_DR;
                    end
                end
            end

            S_DR: begin
                if (xq_take) begin
                    q_j[r_iss[2:0]] <= dr_j;
                    g_dneed[dr_j] <= 1'b0;
                    r_iss <= r_iss + 1'b1;
                end
                if (x_rv) begin
                    dbuf[q_j[r_got[2:0]]] <= x_rd;
                    r_got <= r_got + 1'b1;
                end
                if (r_got == r_iss && (g_dneed == 8'd0 || e_bad) && !mem_req && !dx_req) begin
                    if (e_bad) es <= S_DRAIN;
                    else begin
                        wj <= 4'd0;
                        sptr <= w_pre ? 4'd1 : 4'd0;
                        if (w_pre) w_carry <= sbuf[0];
                        // the row's first mask word: its first bit lined up
                        // with the destination's first pixel
                        aptr <= 4'd0;
                        if (w_first && maskimg) begin : apre
                            reg [3:0] pd;
                            pd = w_od >> w_lb;
                            w_areg <= ({abuf[0], 16'd0} << w_ao) >> pd;
                            w_acnt <= 5'd16 + pd - w_ao;
                            aptr   <= 4'd1;
                        end
                        a_v <= 1'b0; b_v <= 1'b0;
                        es <= S_WR;
                    end
                end
            end

            S_WR: begin
                if (b_take) b_v <= 1'b0;
                // stage B
                if (a_move) begin
                    b_v    <= 1'b1;
                    b_w    <= a_w;
                    b_out  <= (res & mfin) | (a_d & ~mfin);
                    b_be   <= {|mfin[15:8], |mfin[7:0]};
                    b_skip <= (mfin == 16'd0);
                    a_v    <= 1'b0;
                end
                // stage A
                if (a_new) begin
                    a_v <= 1'b1;
                    a_s <= a_st;
                    a_m <= a_mt;
                    a_d <= dbuf[wj[2:0]];
                    a_a <= a_at;
                    a_w <= a_wa;
                    if (maskimg) begin
                        w_areg <= a_regi << a_k;
                        w_acnt <= (a_ins ? w_acnt + 5'd16 : w_acnt) - a_k;
                        if (a_ins) aptr <= aptr + 1'b1;
                    end
                    if (a_hasn) begin
                        w_carry <= a_B;
                        sptr    <= sptr + 1'b1;
                    end
                    wj <= wj + 1'b1;
                end
                if (e_bad) begin
                    a_v <= 1'b0; b_v <= 1'b0;
                    if (!mem_req && !dx_req) es <= S_DRAIN;
                end else if (!a_v && !b_v && !mem_req && !dx_req && wj == g_n) begin
                    // the group is done
                    w_dw    <= w_desc ? w_dw - g_n : w_dw + g_n;
                    w_dleft <= w_dleft - g_n;
                    w_first <= 1'b0;
                    w_pre   <= 1'b0;
                    if (w_dleft == g_n) begin
                        // the row is done
                        w_rows <= w_rows - 1'b1;
                        w_srow <= w_desc ? w_srow - {{8{w_sstr[15]}}, w_sstr} : w_srow + {{8{w_sstr[15]}}, w_sstr};
                        w_arow <= w_desc ? w_arow - {{8{w_sstr[15]}}, w_sstr} : w_arow + {{8{w_sstr[15]}}, w_sstr};
                        w_drow <= w_desc ? w_drow - {{8{w_dstr[15]}}, w_dstr} : w_drow + {{8{w_dstr[15]}}, w_dstr};
                        mode[cur] <= M_ROW;
                    end
                    es <= S_SAVE;
                end
            end

            // ---------------------------------------------------- a port job
            // Up to 8 bytes, then the next channel's turn; sooner if the port
            // is not ready (a byte read for the port but not sent is read
            // again next time)
            S_PORT: begin : port
                reg stop;
                if (w_sk == 2'd1) begin
                    if (xq_take) begin
                        w_drow  <= w_drow + 1'b1;
                        w_dleft <= w_dleft - 1'b1;
                        pc_n    <= pc_n + 1'b1;
                    end
                    stop = !xq_take && (!p_rxv || pc_n == 4'd8 || w_dleft == 24'd0);
                end else begin
                    if (xq_take) p_rd <= 1'b1;
                    if (x_rv) begin
                        p_txd  <= w_srow[0] ? x_rd[7:0] : x_rd[15:8];
                        p_have <= 1'b1;
                        p_rd   <= 1'b0;
                    end
                    if (p_txpush) begin
                        p_have  <= 1'b0;
                        w_srow  <= w_srow + 1'b1;
                        w_dleft <= w_dleft - 1'b1;
                        pc_n    <= pc_n + 1'b1;
                    end
                    stop = !p_rd && !xq_take && !x_rv && ((p_have && !p_txr) || (!p_have && (pc_n == 4'd8 || w_dleft == 24'd0)));
                end
                if ((stop || e_bad) && !mem_req && !dx_req && !p_rd) begin
                    p_have <= 1'b0;
                    if (e_bad) es <= S_DRAIN;
                    else begin
                        if (w_dleft == 24'd0) begin
                            w_rows    <= 16'd0;
                            mode[cur] <= M_ROW;
                        end
                        es <= S_SAVE;
                    end
                end
            end

            // after an error: wait for every read asked for to come back
            S_DRAIN: if (chip_out == 5'd0 && !int_ret && !mem_req && !dx_req) es <= S_SAVE;

            // ---------------------------------------------------- end of a group or job
            S_SAVE: begin
                st[cur] <= w_pack;
                es <= S_IDLE;
                if (e_bad) begin
                    busy[cur]  <= 1'b0;
                    err[cur]   <= 1'b1;
                    dint[cur]  <= 1'b1;
                    cherr[cur] <= e_addr;
                end else if (w_rows == 16'd0 && (mode[cur] == M_ROW || mode[cur] == M_SETUP)) begin
                    // the job is done
                    if (w_irq) dint[cur] <= 1'b1;
                    if (w_next != 24'd0 && !stopreq[cur]) begin
                        chdesc[cur] <= w_next;
                        mode[cur]   <= M_LOAD;
                    end else begin
                        busy[cur]    <= 1'b0;
                        done[cur]    <= 1'b1;
                        stopreq[cur] <= 1'b0;
                    end
                end else if (stopreq[cur]) begin
                    busy[cur]    <= 1'b0;
                    done[cur]    <= 1'b1;
                    stopreq[cur] <= 1'b0;
                end
            end
            default: es <= S_IDLE;
            endcase

            // ---------------------------------------------------- register writes
            if (rb_wr && sel_dmx && rb_be[0]) begin
                if (sel_int)        dint   <= dint & ~rb_wdata[3:0];
                else if (sel_inten) dinten <= rb_wdata[3:0];
                else case (rri)
                    4'd9: begin
                        if ((rb_wdata[0] || rb_wdata[1]) && !busy[rch]) begin
                            busy[rch]    <= 1'b1;
                            stopreq[rch] <= 1'b0;
                            mode[rch]    <= rb_wdata[0] ? M_LOAD : M_SETUP;
                        end
                        if (rb_wdata[2] && busy[rch]) stopreq[rch] <= 1'b1;
                        pause[rch]    <= rb_wdata[3];
                        cpushare[rch] <= rb_wdata[5:4];
                    end
                    4'd10: begin
                        if (rb_wdata[1]) done[rch] <= 1'b0;
                        if (rb_wdata[2]) err[rch]  <= 1'b0;
                    end
                    default: ;
                endcase
            end
            for (i = 0; i < 4; i = i + 1)
                if (tmr_start[i] && !busy[tmr_ch[2*i +: 2]]) begin
                    busy[tmr_ch[2*i +: 2]]    <= 1'b1;
                    stopreq[tmr_ch[2*i +: 2]] <= 1'b0;
                    mode[tmr_ch[2*i +: 2]]    <= M_LOAD;
                end
            if (rb_wr && sel_dmx && rri == 4'd8 && !sel_int && !sel_inten && !busy[rch])
                /* verilator lint_off WIDTHTRUNC */ chdesc[rch] <= merge({8'd0, chdesc[rch]}, rb_wdata, rb_be); /* verilator lint_on WIDTHTRUNC */
        end
    end
endmodule
