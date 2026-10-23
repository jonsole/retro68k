// An SD card in SPI mode, for the I/O test (spec 15): enough of one to
// start it and read and write blocks.
//
//   CMD0  R1 0x01 (idle)          CMD8   R7: 01 00 00 01 AA
//   CMD55 R1                      ACMD41 R1 0x01 the first time, then 0x00 (ready)
//   CMD58 R3: 00 C0 FF 80 00 (SDHC: block numbers)
//   CMD17 R1, a gap, the token 0xFE, 512 bytes, 2 CRC bytes
//   CMD24 R1; then the host sends 0xFE, 512 bytes, 2 CRC bytes; the card
//         answers 0x05 (accepted) and is busy (0x00) for a few bytes
//
// SPI mode 0: MOSI is taken at each rising edge of SCLK, MISO changes after
// each falling edge (a byte's first bit when the last byte ends). Blocks
// 0-3 exist; block b byte i starts as (7b + 3i) mod 256.
`timescale 1ns/1ps
module sd_model (
    input  wire sclk,
    input  wire mosi,
    input  wire cs_n,
    output reg  miso = 1'b1
);
    reg  [7:0] mem [0:2047];
    integer i;
    initial for (i = 0; i < 2048; i = i + 1) mem[i] = (7 * (i / 512) + 3 * (i % 512)) & 8'hFF;

    reg  [7:0] q [0:1023];             // bytes to send
    integer    qh = 0, qt = 0;
    reg  [7:0] cmd [0:5];
    integer    cn = 0;                 // command bytes so far
    reg        idle = 1'b1, app = 1'b0, acmd41_seen = 1'b0;
    integer    wst = 0, wn = 0, wblk = 0;   // block write: 0 none, 1 waiting for the token, 2 data, 3 CRC
    integer    busy = 0;
    integer    errors = 0;
    integer    nblocks_w = 0;

    reg  [7:0] rx = 8'h00, tx = 8'hFF;
    integer    bits = 0;

    task put(input [7:0] b); begin q[qt % 1024] = b; qt = qt + 1; end endtask

    // the next byte out: queued, else busy (0x00), else 0xFF
    task next_tx;
        begin
            if (qh != qt) begin tx = q[qh % 1024]; qh = qh + 1; end
            else if (busy > 0) begin tx = 8'h00; busy = busy - 1; end
            else tx = 8'hFF;
        end
    endtask

    always @(negedge cs_n) begin bits = 0; next_tx; miso = tx[7]; end
    always @(posedge cs_n) begin miso = 1'b1; cn = 0; end

    always @(posedge sclk) if (!cs_n) begin
        rx = {rx[6:0], mosi};
        bits = bits + 1;
        if (bits == 8) begin
            bits = 0;
            got(rx);
        end
    end
    always @(negedge sclk) if (!cs_n) begin
        if (bits == 0) next_tx;
        miso = tx[7 - bits];
    end

    task got(input [7:0] b);
        integer a, k;
        begin
            if (wst == 1) begin
                if (b == 8'hFE) begin wst = 2; wn = 0; end
            end else if (wst == 2) begin
                mem[wblk * 512 + wn] = b;
                wn = wn + 1;
                if (wn == 512) begin wst = 3; wn = 0; end
            end else if (wst == 3) begin
                wn = wn + 1;
                if (wn == 2) begin wst = 0; put(8'h05); busy = 4; nblocks_w = nblocks_w + 1; end
            end else if (cn == 0) begin
                if (b[7:6] == 2'b01) begin cmd[0] = b; cn = 1; end
            end else begin
                cmd[cn] = b;
                cn = cn + 1;
                if (cn == 6) begin
                    cn = 0;
                    a = {cmd[1], cmd[2], cmd[3], cmd[4]};
                    put(8'hFF);                                   // one byte before the answer
                    case (cmd[0][5:0])
                        0:  begin idle = 1'b1; put(8'h01); end
                        8:  begin put(8'h01); put(8'h00); put(8'h00); put(8'h01); put(8'hAA); end
                        55: begin app = 1'b1; put(idle ? 8'h01 : 8'h00); end
                        41: begin
                                if (!app) errors = errors + 1;
                                app = 1'b0;
                                if (acmd41_seen) idle = 1'b0;
                                acmd41_seen = 1'b1;
                                put(idle ? 8'h01 : 8'h00);
                            end
                        58: begin put(8'h00); put(8'hC0); put(8'hFF); put(8'h80); put(8'h00); end
                        17: begin
                                put(8'h00);
                                put(8'hFF); put(8'hFF);                   // the card takes a moment
                                put(8'hFE);
                                for (k = 0; k < 512; k = k + 1) put(mem[(a % 4) * 512 + k]);
                                put(8'hAB); put(8'hCD);                   // CRC (not checked)
                            end
                        24: begin put(8'h00); wst = 1; wblk = a % 4; end
                        default: put(8'h04);                          // illegal command
                    endcase
                end
            end
        end
    endtask
endmodule
