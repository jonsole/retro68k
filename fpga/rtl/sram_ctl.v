// SRAM controller and memory-cycle scheduler (spec 5).
//
// A 100 ns slot holds 5 memory cycles of 20 ns (2 clocks at 100 MHz).
// Owners (spec 5, section 4.3):
//   cycle 0     CPU; when the CPU doesn't use it, the DMA port
//   cycles 1-2  display fetch; when the display doesn't need them, the DMA port
//   cycle 3     display fetch with wide fetch on, otherwise the DMA port
//   cycle 4     the DMA port
// Sprites (spec 9, section 5) come first in the free pool and in display
// cycles the display doesn't need; an urgent sprite fetch may also take
// the CPU's cycle 0 (the CPU then waits one slot, 2 of its clocks).
// The DMA port stands in for the free-pool users still to come (audio,
// copper, DMA engine) and is used by the tests.
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

    // CPU port: hold req until ack
    input  wire        cpu_req,
    input  wire        cpu_we,
    input  wire [21:1] cpu_addr,
    input  wire [15:0] cpu_wdata,
    input  wire [1:0]  cpu_be,      // [1] = upper byte (D15-8), [0] = lower byte
    output reg         cpu_ack,     // 1 clock: the request was issued at this edge
    output reg         cpu_rvalid,  // 1 clock: rdata holds the CPU's read data

    // DMA port: hold req until ack
    input  wire        dma_req,
    input  wire        dma_we,
    input  wire [21:1] dma_addr,
    input  wire [15:0] dma_wdata,
    input  wire [1:0]  dma_be,
    output reg         dma_ack,
    output reg         dma_rvalid,

    // Sprite fetch port (reads only): hold req until ack
    input  wire        spr_req,
    input  wire        spr_urgent,  // may take the CPU's cycle 0
    input  wire [21:1] spr_addr,
    output reg         spr_ack,
    output reg         spr_rvalid,

    // Display fetch port (reads only): hold req until ack
    input  wire        wide,        // VIDCON.WIDE: cycle 3 is a display cycle too
    input  wire        disp_req,
    input  wire [21:1] disp_addr,
    output reg         disp_ack,
    output reg         disp_rvalid,

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
    localparam OWN_NONE = 3'd0, OWN_CPU = 3'd1, OWN_DMA = 3'd2, OWN_DISP = 3'd3, OWN_SPR = 3'd4;

    // A new memory cycle starts at the next edge when the current clock is
    // the second of a cycle (odd sc). Its number is (sc + 1) / 2, mod 5.
    wire       start_next = sc[0];
    wire       next_is_cycle0 = (sc == 4'd9);

    // Who gets the cycle that starts at the next edge
    wire next_is_disp = (sc == 4'd1) || (sc == 4'd3) || (sc == 4'd5 && wide);   // cycles 1, 2 (3)
    wire spr_takes = next_is_cycle0 && spr_req && spr_urgent;
    wire cpu_wins  = next_is_cycle0 && cpu_req && !spr_takes;
    wire disp_wins = next_is_disp && disp_req;
    wire spr_wins  = !cpu_wins && !disp_wins && spr_req;
    wire dma_wins  = !cpu_wins && !disp_wins && !spr_wins && dma_req;

    reg  [2:0] owner;      // owner of the cycle in progress
    reg        cur_we;     // the cycle in progress is a write
    reg  [2:0] prev_owner; // the previous cycle, whose read data is on the pins now
    reg        prev_rd;

    always @(posedge clk) begin
        cpu_ack    <= 1'b0;
        dma_ack    <= 1'b0;
        cpu_rvalid <= 1'b0;
        dma_rvalid <= 1'b0;
        disp_ack   <= 1'b0;
        disp_rvalid <= 1'b0;
        spr_ack    <= 1'b0;
        spr_rvalid <= 1'b0;

        if (rst) begin
            owner       <= OWN_NONE;
            cur_we      <= 1'b0;
            sram_ce_n   <= 1'b1;
            sram_ub_n   <= 1'b1;
            sram_lb_n   <= 1'b1;
            sram_oe_n_r <= 1'b1;  sram_oe_n_f <= 1'b1;
            sram_we_n_r <= 1'b1;  sram_we_n_f <= 1'b1;
            sram_dq_t_r <= 1'b1;  sram_dq_t_f <= 1'b1;
            sram_a      <= 21'd0;
            sram_dq_o   <= 16'd0;
            prev_owner  <= OWN_NONE;
            prev_rd     <= 1'b0;
        end else if (start_next) begin
            // The cycle in progress moves to its second clock on the pins
            prev_owner <= owner;
            prev_rd    <= (owner != OWN_NONE) && !cur_we;

            // Clock 0 of the next cycle
            if (cpu_wins || disp_wins || spr_wins || dma_wins) begin
                owner     <= cpu_wins ? OWN_CPU : disp_wins ? OWN_DISP : spr_wins ? OWN_SPR : OWN_DMA;
                cur_we    <= cpu_wins ? cpu_we : (disp_wins || spr_wins) ? 1'b0 : dma_we;
                cpu_ack   <= cpu_wins;
                disp_ack  <= disp_wins;
                spr_ack   <= spr_wins;
                dma_ack   <= dma_wins;
                sram_a    <= cpu_wins ? cpu_addr[21:1] : disp_wins ? disp_addr[21:1] :
                             spr_wins ? spr_addr[21:1] : dma_addr[21:1];
                sram_ce_n <= 1'b0;
                if (cpu_wins ? cpu_we : (disp_wins || spr_wins) ? 1'b0 : dma_we) begin
                    sram_ub_n   <= ~(cpu_wins ? cpu_be[1] : dma_be[1]);
                    sram_lb_n   <= ~(cpu_wins ? cpu_be[0] : dma_be[0]);
                    sram_dq_o   <= cpu_wins ? cpu_wdata : dma_wdata;
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
                owner       <= OWN_NONE;
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
                rdata      <= sram_dq_i;
                cpu_rvalid  <= (prev_owner == OWN_CPU);
                dma_rvalid  <= (prev_owner == OWN_DMA);
                disp_rvalid <= (prev_owner == OWN_DISP);
                spr_rvalid  <= (prev_owner == OWN_SPR);
            end
            // Clock 1 of the cycle in progress
            if (owner != OWN_NONE && cur_we) begin
                sram_we_n_r <= 1'b0;  sram_we_n_f <= 1'b1;   // /WE rises 5 ns into clock 1
                sram_dq_t_r <= 1'b0;  sram_dq_t_f <= 1'b0;
            end else if (owner != OWN_NONE) begin
                sram_oe_n_r <= 1'b0;  sram_oe_n_f <= 1'b0;
            end
        end
    end
endmodule
