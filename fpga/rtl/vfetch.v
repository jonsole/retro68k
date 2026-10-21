// Display fetch for the 4 bitmap layers (spec 4, section 5.1; spec 5).
//
// At the start of each horizontal blank, video.v works out each layer's
// next line (start address and number of words) and toggles line_t. The
// fetcher then fills each layer's buffer from Chip RAM, one 16-bit word per
// display memory cycle (cycles 1 and 2 of every slot, and 3 with wide
// fetch), giving each cycle to the layer whose buffer is emptiest. Each
// buffer holds 24 words of the 32-word store.
module vfetch (
    input  wire        clk,            // 100 MHz
    input  wire        rst,
    input  wire        enable,         // video on, DMACON.DMAEN and VIDEN

    input  wire        line_t,         // from the pixel domain
    input  wire [3:0]  active,
    input  wire [91:0] start_addr,     // 4 x 23-bit byte address (even)
    input  wire [47:0] nwords,         // 4 x 12 bits
    input  wire [23:0] rp,             // 4 x 6 bits, from the pixel domain

    output reg  [23:0] wp,             // 4 x 6 bits: words written
    output reg         fifo_we,
    output reg  [1:0]  fifo_layer,
    output reg  [4:0]  fifo_index,
    output reg  [15:0] fifo_data,

    // SRAM controller display port
    output reg         req,
    output reg  [21:1] addr,
    input  wire        ack,
    input  wire        rvalid,
    input  wire [15:0] rdata
);
    localparam DEPTH = 6'd24;

    reg  [1:0]  line_s;
    reg  [22:0] a    [0:3];            // next word address
    reg  [11:0] left [0:3];            // words still to fetch
    reg  [5:0]  alloc[0:3];            // words asked for (written or on the way)
    reg  [3:0]  gen;                   // line generation per layer

    // Reads on the way: layer, buffer index and generation, in order
    reg  [1:0]  q_layer [0:3];
    reg  [4:0]  q_index [0:3];
    reg         q_gen   [0:3];
    reg  [1:0]  q_h, q_t;

    // Fill level per layer, counting reads on the way
    reg  [5:0]  fill [0:3];
    integer     n;
    always @(*) for (n = 0; n < 4; n = n + 1) fill[n] = alloc[n] - rp[6*n +: 6];

    // The layer that needs a word most: the emptiest buffer
    reg  [1:0]  pick;
    reg         want;
    always @(*) begin
        want = 1'b0;
        pick = 2'd0;
        for (n = 3; n >= 0; n = n - 1)
            if (left[n] != 0 && fill[n] < DEPTH && (!want || fill[n] <= fill[pick])) begin
                want = 1'b1;
                pick = n;
            end
    end

    always @(posedge clk) begin
        fifo_we <= 1'b0;
        line_s  <= {line_s[0], line_t};
        if (rst) begin
            req  <= 1'b0;
            q_h  <= 2'd0;
            q_t  <= 2'd0;
            gen  <= 4'd0;
            wp   <= 24'd0;
            for (n = 0; n < 4; n = n + 1) begin
                left[n]  <= 12'd0;
                alloc[n] <= 6'd0;
            end
        end else begin
            // Data back from the SRAM
            if (rvalid) begin
                if (q_gen[q_h] == gen[q_layer[q_h]]) begin
                    fifo_we    <= 1'b1;
                    fifo_layer <= q_layer[q_h];
                    fifo_index <= q_index[q_h];
                    fifo_data  <= rdata;
                    wp[6*q_layer[q_h] +: 6] <= wp[6*q_layer[q_h] +: 6] + 1'b1;
                end
                q_h <= q_h + 1'b1;
            end

            // A request was taken
            if (ack) begin
                req <= 1'b0;
                q_t <= q_t + 1'b1;
            end

            // New line: start each layer's buffer again
            if (line_s[1] != line_s[0]) begin
                for (n = 0; n < 4; n = n + 1) begin
                    a[n]     <= start_addr[23*n +: 23];
                    left[n]  <= (enable && active[n]) ? nwords[12*n +: 12] : 12'd0;
                    alloc[n] <= 6'd0;
                    wp[6*n +: 6] <= 6'd0;
                end
                gen <= ~gen;
                req <= 1'b0;
            end else if ((!req || ack) && want) begin
                // Ask for the next word of the neediest layer
                req              <= 1'b1;
                addr             <= a[pick][21:1];
                a[pick]          <= a[pick] + 23'd2;
                left[pick]       <= left[pick] - 1'b1;
                alloc[pick]      <= alloc[pick] + 1'b1;
                q_layer[q_t + (ack ? 1'b1 : 1'b0)] <= pick;
                q_index[q_t + (ack ? 1'b1 : 1'b0)] <= alloc[pick][4:0];
                q_gen[q_t + (ack ? 1'b1 : 1'b0)]   <= gen[pick];
            end
        end
    end
endmodule
