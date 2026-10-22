// SRAM controller (spec 5): the timing of each 20 ns memory cycle on the
// SRAM pins. Who gets each cycle is decided by the DMA scheduler (dmac.v).
//
// A 100 ns slot holds 5 memory cycles of 20 ns (2 clocks at 100 MHz),
// numbered 0-4; next_cycle tells the scheduler which one comes next.
//
// The pin outputs below are registered again in the I/O pads (output
// flip-flops, or ODDR for the half-clock signals), so the pins show them one
// clock later. A memory cycle issued at edge E is on the pins from E + 10 ns
// to E + 30 ns:
//   read : address, /CE, byte selects at E + 10; /OE low from E + 15;
//          data captured at E + 30 (put rdata in the input pad flip-flops)
//   write: address and byte selects at E + 10; data driven from E + 15;
//          /WE low from E + 15 to E + 25 (10 ns pulse, 5 ns address setup
//          and hold, 10 ns data setup)
// *_r is the value for the first half of a clock, *_f for the second half.
//
// For the CPU, a read issued at the start of a slot has its data in rdata
// 40 ns later (rvalid), so bus_if gives it to fx68k at 60 ns into the slot.
module sram_ctl (
    input  wire        clk,         // 100 MHz
    input  wire        rst,
    input  wire [3:0]  sc,          // timebase: edge index within the slot

    // The cycle the scheduler (dmac.v) gives out, starting at the next edge
    // where a new cycle starts (sc odd); the tag comes back with read data
    input  wire        go,
    input  wire        go_we,
    input  wire [21:1] go_addr,
    input  wire [15:0] go_wdata,
    input  wire [1:0]  go_be,       // [1] = upper byte (D15-8), [0] = lower byte
    input  wire [2:0]  go_tag,
    output wire        start_next,  // a new cycle starts at the next edge
    output wire [2:0]  next_cycle,  // ... and this is its number in the slot (0-4)
    output reg         rvalid,      // 1 clock: rdata holds read data for rtag
    output reg  [2:0]  rtag,
    output reg  [15:0] rdata,

    // SRAM pins (before the DDR output registers)
    output reg  [20:0] sram_a,
    output reg         sram_ce_n,
    output reg         sram_ub_n,
    output reg         sram_lb_n,
    output reg         sram_oe_n_r, sram_oe_n_f,
    output reg         sram_we_n_r, sram_we_n_f,
    output reg  [15:0] sram_dq_o,
    output reg         sram_dq_t_r, sram_dq_t_f,   // 1 = not driving
    input  wire [15:0] sram_dq_i
);
    // A new memory cycle starts at the next edge when the current clock is
    // the second of a cycle (odd sc). Its number is (sc + 1) / 2, mod 5.
    assign start_next = sc[0];
    assign next_cycle = (sc == 4'd9) ? 3'd0 : sc[3:1] + 1'b1;

    reg        owner;      // a cycle is in progress
    reg  [2:0] tag;        // ... for this channel
    reg        cur_we;     // the cycle in progress is a write
    reg  [2:0] prev_tag;   // the previous cycle, whose read data is on the pins now
    reg        prev_rd;

    always @(posedge clk) begin
        rvalid <= 1'b0;

        if (rst) begin
            owner       <= 1'b0;
            tag         <= 3'd0;
            cur_we      <= 1'b0;
            sram_ce_n   <= 1'b1;
            sram_ub_n   <= 1'b1;
            sram_lb_n   <= 1'b1;
            sram_oe_n_r <= 1'b1;  sram_oe_n_f <= 1'b1;
            sram_we_n_r <= 1'b1;  sram_we_n_f <= 1'b1;
            sram_dq_t_r <= 1'b1;  sram_dq_t_f <= 1'b1;
            sram_a      <= 21'd0;
            sram_dq_o   <= 16'd0;
            prev_tag    <= 3'd0;
            prev_rd     <= 1'b0;
        end else if (start_next) begin
            // The cycle in progress moves to its second clock on the pins
            prev_tag <= tag;
            prev_rd  <= owner && !cur_we;

            // Clock 0 of the next cycle
            if (go) begin
                owner     <= 1'b1;
                tag       <= go_tag;
                cur_we    <= go_we;
                sram_a    <= go_addr[21:1];
                sram_ce_n <= 1'b0;
                if (go_we) begin
                    sram_ub_n   <= ~go_be[1];
                    sram_lb_n   <= ~go_be[0];
                    sram_dq_o   <= go_wdata;
                    sram_oe_n_r <= 1'b1;  sram_oe_n_f <= 1'b1;
                    sram_we_n_r <= 1'b1;  sram_we_n_f <= 1'b0;
                    sram_dq_t_r <= 1'b1;  sram_dq_t_f <= 1'b0;
                end else begin
                    sram_ub_n   <= 1'b0;
                    sram_lb_n   <= 1'b0;
                    sram_oe_n_r <= 1'b1;  sram_oe_n_f <= 1'b0;
                    sram_we_n_r <= 1'b1;  sram_we_n_f <= 1'b1;
                    sram_dq_t_r <= 1'b1;  sram_dq_t_f <= 1'b1;
                end
            end else begin
                owner       <= 1'b0;
                tag         <= 3'd0;
                cur_we      <= 1'b0;
                sram_ce_n   <= 1'b1;
                sram_ub_n   <= 1'b1;
                sram_lb_n   <= 1'b1;
                sram_oe_n_r <= 1'b1;  sram_oe_n_f <= 1'b1;
                sram_we_n_r <= 1'b1;  sram_we_n_f <= 1'b1;
                sram_dq_t_r <= 1'b1;  sram_dq_t_f <= 1'b1;
            end
        end else begin
            // The previous cycle ends on the pins at this edge: collect read data
            if (prev_rd) begin
                rdata  <= sram_dq_i;
                rvalid <= 1'b1;
                rtag   <= prev_tag;
            end
            // Clock 1 of the cycle in progress
            if (owner && cur_we) begin
                sram_we_n_r <= 1'b0;  sram_we_n_f <= 1'b1;   // /WE rises 5 ns into clock 1
                sram_dq_t_r <= 1'b0;  sram_dq_t_f <= 1'b0;
            end else if (owner) begin
                sram_oe_n_r <= 1'b0;  sram_oe_n_f <= 1'b0;
            end
        end
    end
endmodule
