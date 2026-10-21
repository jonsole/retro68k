// Synchronous byte FIFO in block RAM, first-word-fall-through:
// rdata shows the oldest byte whenever valid is set, and pop removes it.
// count can be ahead of valid by a clock (a byte on its way to rdata).
// count is 0 .. 2^AW + 1 (the RAM plus the output register).
module fifo8 #(
    parameter AW = 11
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        push,
    input  wire [7:0]  wdata,
    input  wire        pop,
    output reg  [7:0]  rdata,
    output wire [AW+1:0] count,
    output wire        full,
    output wire        valid
);
    reg [7:0]    mem [0:(1<<AW)-1];
    reg [AW-1:0] wp, rp;
    reg [AW:0]   ram_count;
    reg          out_valid;

    assign count = ram_count + out_valid;
    assign full  = (ram_count == (1 << AW));
    assign valid = out_valid;

    wire do_pop  = pop && out_valid;
    // Refill the output register from the RAM (only data written in an earlier clock)
    wire refill  = (ram_count != 0) && (!out_valid || do_pop);
    wire do_push = push && (!full || refill);   // when full, room appears as a byte moves out

    always @(posedge clk) begin
        if (do_push) mem[wp] <= wdata;
        if (refill)  rdata   <= mem[rp];
    end

    always @(posedge clk) begin
        if (rst) begin
            wp <= 0; rp <= 0; ram_count <= 0; out_valid <= 1'b0;
        end else begin
            if (do_push) wp <= wp + 1'b1;
            if (refill)  rp <= rp + 1'b1;
            ram_count <= ram_count + do_push - refill;
            if (refill)      out_valid <= 1'b1;
            else if (do_pop) out_valid <= 1'b0;
        end
    end
endmodule
