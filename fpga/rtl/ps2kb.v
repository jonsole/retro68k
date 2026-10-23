// PS/2 keyboard (spec 16). 100 MHz.
//
// Receiving: the keyboard clocks 11-bit frames (start 0, 8 data bits
// lowest first, odd parity, stop 1) at 10-17 kHz; a bit is taken at each
// falling edge of its clock. The clock line is filtered (it must hold a
// new level for 0.64 us) against noise. Good bytes go into a 16-byte FIFO
// unchanged; bad ones are dropped and flagged. A frame not finished within
// 2 ms is dropped (the next starts afresh).
//
// Sending: hold the clock low for 100 us, pull data low (the start bit),
// let the clock go; then the keyboard clocks the bits in: each is put out
// after a falling edge (8 data bits, parity, stop = data let go), and the
// keyboard answers by pulling data low for one more clock. 15 ms without
// that: TIMEOUT. Nothing is received while sending.
//
// Both lines are open collector: the outputs say when to pull a line low.
`include "regmap.vh"

module ps2kb (
    input  wire        clk,
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output reg  [31:0] rb_rdata,

    input  wire        ps2_clk_i,
    input  wire        ps2_data_i,
    output reg         ps2_clk_low,    // pull the clock line low
    output reg         ps2_data_low,   // pull the data line low

    output wire        irq
);
    wire [15:0] off = {rb_addr[15:2], 2'b00};
    wire        sel = (rb_addr[23:16] == 8'hF0) && (off[15:8] == 8'h04);

    reg         en;
    reg  [4:0]  irqf;                  // TIMEOUT 4, OVERFLOW 3, FRAME 2, PARITY 1 (DATA, bit 0, is live)
    reg  [4:0]  irqen;

    // ---------------------------------------------------------------- the lines
    reg  [1:0]  cs, ds;
    always @(posedge clk) begin
        cs <= {cs[0], ps2_clk_i};
        ds <= {ds[0], ps2_data_i};
    end
    reg         kc;                    // the clock, filtered
    reg  [5:0]  kcn;
    wire        kfall;
    always @(posedge clk)
        if (rst) begin kc <= 1'b1; kcn <= 6'd0; end
        else if (cs[1] == kc) kcn <= 6'd0;
        else if (kcn == 6'd63) begin kc <= cs[1]; kcn <= 6'd0; end
        else kcn <= kcn + 1'b1;
    reg         kc_d;
    always @(posedge clk) kc_d <= kc;
    assign      kfall = kc_d && !kc;

    // ---------------------------------------------------------------- the FIFO
    reg  [7:0]  fifo [0:15];
    reg  [3:0]  fh, ft;
    reg  [4:0]  fcount;
    wire        f_pop  = rb_rd && sel && off == `RM_KBDATA && fcount != 5'd0;
    reg         f_push;
    reg  [7:0]  f_byte;
    assign irq = |({irqf[4:1], fcount != 5'd0} & irqen);

    // ---------------------------------------------------------------- receive and send
    reg  [3:0]  rn;                    // bits of the frame so far
    reg  [9:0]  rsh;                   // data, parity, stop (start checked on its own)
    reg  [17:0] rt;                    // time since the frame's last bit
    reg         tx, tx_ack;            // sending; waiting for the keyboard's answer
    reg  [8:0]  tsh;                   // data and parity still to send
    reg  [3:0]  tn;
    reg  [20:0] tt;                    // time: the 100 us hold, then the 15 ms limit

    wire        send_w = rb_wr && sel && off == `RM_KBSEND && rb_be[0] && en && !tx;

    always @(posedge clk) begin
        f_push <= 1'b0;
        if (rst) begin
            en <= 1'b0; irqf <= 5'd0; irqen <= 5'd0;
            fh <= 4'd0; ft <= 4'd0; fcount <= 5'd0;
            rn <= 4'd0; tx <= 1'b0; tx_ack <= 1'b0;
            ps2_clk_low <= 1'b0; ps2_data_low <= 1'b0;
        end else begin
            // ---- receiving
            if (!tx) begin
                if (kfall) begin
                    rt <= 18'd0;
                    if (rn == 4'd0) begin
                        if (!ds[1]) rn <= 4'd1;            // a start bit
                        else irqf[2] <= 1'b1;               // FRAME: no start bit
                    end else begin
                        rsh <= {ds[1], rsh[9:1]};
                        if (rn == 4'd10) begin
                            rn <= 4'd0;
                            // rsh holds data and parity; ds[1] is the stop bit
                            if (!ds[1])                      irqf[2] <= 1'b1;   // FRAME: bad stop bit
                            else if ((^rsh[9:1]) != 1'b1)    irqf[1] <= 1'b1;   // PARITY: data + parity must be odd
                            else begin
                                f_push <= 1'b1;
                                f_byte <= rsh[8:1];
                            end
                        end else
                            rn <= rn + 1'b1;
                    end
                end else if (rn != 4'd0) begin
                    if (rt == 18'd200000) rn <= 4'd0;       // 2 ms without a bit: start again
                    else rt <= rt + 1'b1;
                end
            end
            // ---- sending
            if (send_w) begin
                tx <= 1'b1; tx_ack <= 1'b0;
                tsh <= {~^rb_wdata[7:0], rb_wdata[7:0]};    // odd parity
                tn  <= 4'd0;
                tt  <= 21'd0;
                rn  <= 4'd0;
                ps2_clk_low  <= 1'b1;                       // hold the clock low ...
                ps2_data_low <= 1'b0;
            end else if (tx) begin
                tt <= tt + 1'b1;
                if (ps2_clk_low) begin
                    if (tt == 21'd10000) begin              // ... 100 us; then data low, clock free
                        ps2_data_low <= 1'b1;
                        ps2_clk_low  <= 1'b0;
                    end
                end else if (kfall) begin
                    if (tx_ack) begin
                        tx <= 1'b0;                         // the keyboard took it (data low on this clock)
                    end else if (tn < 4'd9) begin
                        ps2_data_low <= !tsh[0];            // data bits, then parity
                        tsh <= {1'b0, tsh[8:1]};
                        tn  <= tn + 1'b1;
                    end else begin
                        ps2_data_low <= 1'b0;               // the stop bit: let data go
                        tx_ack <= 1'b1;
                    end
                end
                if (tt == 21'd1500000) begin                // 15 ms: give up
                    tx <= 1'b0;
                    ps2_clk_low  <= 1'b0;
                    ps2_data_low <= 1'b0;
                    irqf[4] <= 1'b1;
                end
            end
            // ---- the FIFO
            if (f_push && fcount == 5'd16) irqf[3] <= 1'b1;  // OVERFLOW: the byte is dropped
            if (f_push && fcount != 5'd16) begin
                fifo[ft] <= f_byte;
                ft <= ft + 1'b1;
            end
            if (f_pop) fh <= fh + 1'b1;
            fcount <= fcount + ((f_push && fcount != 5'd16) ? 5'd1 : 5'd0) - (f_pop ? 5'd1 : 5'd0);
            // ---- registers
            if (rb_wr && sel && rb_be[0]) case (off)
                `RM_KBCON:   en <= rb_wdata[0];
                `RM_KBIRQ:   irqf <= irqf & ~rb_wdata[4:0];
                `RM_KBIRQEN: irqen <= rb_wdata[4:0];
                default: ;
            endcase
            if (!en) begin
                fh <= 4'd0; ft <= 4'd0; fcount <= 5'd0; rn <= 4'd0;
                tx <= 1'b0; ps2_clk_low <= 1'b0; ps2_data_low <= 1'b0;
            end
        end

        rb_rdata <= 32'd0;
        if (rb_rd && sel) case (off)
            `RM_KBCON:   rb_rdata <= {31'd0, en};
            `RM_KBSTAT:  rb_rdata <= {23'd0, tx, 3'd0, fcount};
            `RM_KBDATA:  rb_rdata <= (fcount != 5'd0) ? {24'd0, fifo[fh]} : 32'h100;
            `RM_KBIRQ:   rb_rdata <= {27'd0, irqf[4:1], fcount != 5'd0};
            `RM_KBIRQEN: rb_rdata <= {27'd0, irqen};
            default: ;
        endcase
    end
endmodule
