// SD card: an SPI byte master (spec 15). 100 MHz.
//
// SPI mode 0, most significant bit first: SCLK rests low, MOSI changes
// after a falling edge (the first bit before the first rising edge), MISO
// is sampled at each rising edge. A byte goes out and one comes in at the
// same time; software does the commands, answers and blocks.
//
// A byte is clocked for one of three: the CPU writing SDDATA; the DMA
// engine sending a byte to port 0; or a run of reads for the DMA engine
// (SDCOUNT), where each byte read (sending 0xFF) waits in p_rxd until the
// engine takes it, and the next starts then.
//
// MISO is taken through one input register at the edge SCLK rises: the
// card changed it after the falling edge half a period before, so it is
// steady there even at 25 MHz.
`include "regmap.vh"

module sdspi (
    input  wire        clk,
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output reg  [31:0] rb_rdata,

    // The card
    output reg         sd_sclk,
    output reg         sd_mosi,
    input  wire        sd_miso,
    output wire        sd_cs0_n,
    output wire        sd_cs1_n,

    // DMA engine port 0 (spec 11, section 4)
    output wire        p_rxv,
    output wire [7:0]  p_rxd,
    input  wire        p_rxpop,
    output wire        p_txr,
    input  wire        p_txpush,
    input  wire [7:0]  p_txd
);
    wire [15:0] off  = {rb_addr[15:2], 2'b00};
    wire        sel  = (rb_addr[23:16] == 8'hF0) && (off[15:8] == 8'h03);

    reg         en, cs0, cs1;
    reg  [7:0]  clkdiv;
    reg  [15:0] count;                 // SDCOUNT: bytes still to read for the DMA engine
    reg  [7:0]  rxd;                   // the last byte received
    reg         rxv;                   // ... waiting for the DMA engine (a counted read)

    assign sd_cs0_n = !(en && cs0);
    assign sd_cs1_n = !(en && cs1);

    // The shifter
    reg         busy, cnt_rd;          // a byte is being clocked; it is a counted read
    reg  [7:0]  tx, rx;
    reg  [2:0]  bitn;
    reg  [7:0]  hc;                    // half-period counter
    reg         samp;                  // take MISO this clock (SCLK rose last clock)
    reg         miso_q;
    always @(posedge clk) miso_q <= sd_miso;
    wire [7:0]  half = (clkdiv < 8'd2) ? 8'd2 : clkdiv;

    wire        cpu_w    = rb_wr && sel && off == `RM_SDDATA && rb_be[0];
    assign      p_rxv    = rxv;
    assign      p_rxd    = rxd;
    assign      p_txr    = en && !busy && count == 16'd0 && !rxv && !cpu_w;
    wire        go_cpu   = en && !busy && cpu_w;
    wire        go_dma   = p_txr && p_txpush;
    wire        go_cnt   = en && !busy && count != 16'd0 && !rxv && !cpu_w;

    always @(posedge clk) begin
        if (rst) begin
            en <= 1'b0; cs0 <= 1'b0; cs1 <= 1'b0; clkdiv <= 8'd125;
            count <= 16'd0; rxv <= 1'b0; rxd <= 8'hFF;
            busy <= 1'b0; sd_sclk <= 1'b0; sd_mosi <= 1'b1; samp <= 1'b0;
        end else begin
            samp <= 1'b0;
            if (p_rxpop) rxv <= 1'b0;
            if (go_cpu || go_dma || go_cnt) begin
                busy    <= 1'b1;
                cnt_rd  <= go_cnt;
                tx      <= go_cpu ? rb_wdata[7:0] : go_dma ? p_txd : 8'hFF;
                sd_mosi <= go_cpu ? rb_wdata[7] : go_dma ? p_txd[7] : 1'b1;
                bitn    <= 3'd0;
                hc      <= 8'd1;
                if (go_cnt) count <= count - 1'b1;
            end else if (busy) begin
                if (hc == half) begin
                    hc <= 8'd1;
                    if (!sd_sclk) begin
                        sd_sclk <= 1'b1;           // rising: the card's bit is taken next clock
                        samp    <= 1'b1;
                    end else begin
                        sd_sclk <= 1'b0;           // falling: the next bit out, or the end
                        if (bitn == 3'd7) begin
                            busy <= 1'b0;
                            rxd  <= rx;
                            if (cnt_rd) rxv <= 1'b1;
                        end else begin
                            bitn    <= bitn + 1'b1;
                            sd_mosi <= tx[6 - bitn];
                        end
                    end
                end else
                    hc <= hc + 1'b1;
            end
            if (samp) rx <= {rx[6:0], miso_q};
            if (!en) begin
                busy <= 1'b0; sd_sclk <= 1'b0; count <= 16'd0; rxv <= 1'b0;
            end

            if (rb_wr && sel) case (off)
                `RM_SDCON: begin
                    if (rb_be[0]) begin en <= rb_wdata[0]; cs0 <= rb_wdata[1]; cs1 <= rb_wdata[2]; end
                    if (rb_be[1]) clkdiv <= rb_wdata[15:8];
                end
                `RM_SDCOUNT: if (rb_be[1:0] == 2'b11 && en) count <= rb_wdata[15:0];
                default: ;
            endcase
        end

        rb_rdata <= 32'd0;
        if (rb_rd && sel) case (off)
            `RM_SDCON:   rb_rdata <= {16'd0, clkdiv, 5'd0, cs1, cs0, en};
            `RM_SDDATA:  rb_rdata <= {23'd0, busy, rxd};
            `RM_SDCOUNT: rb_rdata <= {16'd0, count};
            default: ;
        endcase
    end
endmodule
