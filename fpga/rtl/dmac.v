// DMA scheduler (spec 5): decides who gets each 20 ns memory cycle, as the
// Amiga's Agnus does. sram_ctl.v does the cycle itself.
//
// Channels, each holding req until ack (a 1-clock pulse at the edge the
// cycle is issued); read data comes back on rdata with rvalid for that
// channel 40 ns later:
//   CPU   the 68000 (bus_if.v)
//   BPL   bitplane DMA (bpldma.v): hard deadline
//   SPR   sprites: hard deadline (later; tied off)
//   AUD   audio (later; tied off)
//   COP   copper (later; tied off)
//   BLT   DMA engine / blitter (later; tied off)
//   PORT  the DMA port: stands in for peripherals, used by the tests
//
// Every cycle of the 5 in a slot has a default owner. A cycle its owner
// doesn't use goes to the next in the free order, so no cycle is wasted:
//
//   1. An urgent hard-deadline request (its deadline is about to pass) gets
//      the cycle, whatever it is, even the CPU's cycle 0: the CPU's access
//      then waits one slot. Earliest deadline first. Then the copper at
//      priority 2 (nasty), cycle 0 included.
//   2. The default owner: cycle 0 CPU, cycles 1 and 3 hard-deadline
//      channels (earliest deadline first), cycle 2 AUD, cycle 4 none (the
//      copper at priority 1 or 2).
//   3. The free order: hard-deadline channels (earliest deadline first),
//      AUD, COP, BLT, PORT; the copper at priority 1 or 2 goes first.
//
// The CPU only ever uses cycle 0 (its bus timing is built round it).
module dmac (
    input  wire        clk,
    input  wire        rst,

    // From sram_ctl: a cycle starts at the next edge, and which one
    input  wire        start_next,
    input  wire [2:0]  next_cycle,

    // CPU
    input  wire        cpu_req,
    input  wire        cpu_we,
    input  wire [21:1] cpu_addr,
    input  wire [15:0] cpu_wdata,
    input  wire [1:0]  cpu_be,
    output reg         cpu_ack,
    output wire        cpu_rvalid,

    // Bitplanes (reads)
    input  wire        bpl_req,
    input  wire [21:1] bpl_addr,
    input  wire [9:0]  bpl_deadline,   // system clocks until the data is needed
    input  wire        bpl_urgent,
    output reg         bpl_ack,
    output wire        bpl_rvalid,

    // Sprites (reads), audio (reads), copper (reads)
    input  wire        spr_req,
    input  wire [21:1] spr_addr,
    input  wire [9:0]  spr_deadline,
    input  wire        spr_urgent,
    output reg         spr_ack,
    output wire        spr_rvalid,
    input  wire        aud_req,
    input  wire [21:1] aud_addr,
    output reg         aud_ack,
    output wire        aud_rvalid,
    input  wire        cop_req,
    input  wire [21:1] cop_addr,
    input  wire [1:0]  cop_pri,        // COPCON.PRI: 0 normal, 1 high, 2 nasty
    output reg         cop_ack,
    output wire        cop_rvalid,

    // DMA engine / blitter, and the DMA port (reads and writes)
    input  wire        blt_req,
    input  wire        blt_we,
    input  wire [21:1] blt_addr,
    input  wire [15:0] blt_wdata,
    input  wire [1:0]  blt_be,
    input  wire        blt_high,       // HIGH: may take the CPU's cycle 0 ...
    input  wire [1:0]  blt_share,      // ... leaving it 1 in 2, 4 or 8 of them (spec 11, section 5)
    output reg         blt_ack,
    output wire        blt_rvalid,
    input  wire        port_req,
    input  wire        port_we,
    input  wire [21:1] port_addr,
    input  wire [15:0] port_wdata,
    input  wire [1:0]  port_be,
    output reg         port_ack,
    output wire        port_rvalid,

    // To sram_ctl
    output wire        go,
    output wire        go_we,
    output wire [21:1] go_addr,
    output wire [15:0] go_wdata,
    output wire [1:0]  go_be,
    output wire [2:0]  go_tag,
    input  wire        rvalid,
    input  wire [2:0]  rtag
);
    localparam C_NONE = 3'd0, C_CPU = 3'd1, C_BPL = 3'd2, C_SPR = 3'd3,
               C_AUD  = 3'd4, C_COP = 3'd5, C_BLT = 3'd6, C_PORT = 3'd7;

    // The hard-deadline channel that is due first (bitplanes on a tie)
    wire       hard_any = bpl_req || spr_req;
    wire [2:0] hard     = (spr_req && (!bpl_req || spr_deadline < bpl_deadline)) ? C_SPR : C_BPL;
    wire       urg_any  = (bpl_req && bpl_urgent) || (spr_req && spr_urgent);
    wire [2:0] urg      = (spr_req && spr_urgent && !(bpl_req && bpl_urgent && bpl_deadline <= spr_deadline))
                          ? C_SPR : C_BPL;

    // The free order (a copper at high priority goes first)
    wire       cop_hi = cop_req && cop_pri != 2'd0;
    wire [2:0] free = cop_hi   ? C_COP :
                      hard_any ? hard :
                      aud_req  ? C_AUD :
                      cop_req  ? C_COP :
                      blt_req  ? C_BLT :
                      port_req ? C_PORT : C_NONE;

    // A HIGH DMA engine job and the CPU both want cycle 0: the CPU gets every
    // 2nd, 4th or 8th of these, the engine the rest
    reg  [2:0] shc;
    wire [2:0] shmax   = (blt_share == 2'd0) ? 3'd1 : (blt_share == 2'd1) ? 3'd3 : 3'd7;
    wire       cpu_turn = (shc == shmax);
    always @(posedge clk)
        if (rst) shc <= 3'd0;
        else if (start_next && next_cycle == 3'd0 && cpu_req && blt_req && blt_high && !urg_any
                 && !(cop_req && cop_pri == 2'd2))
            shc <= cpu_turn ? 3'd0 : shc + 1'b1;

    // Who gets the cycle that starts at the next edge
    reg  [2:0] win;
    always @(*) begin
        if (urg_any)
            win = urg;                                      // 1: urgent
        else if (cop_req && cop_pri == 2'd2)
            win = C_COP;                                    //    the copper, nasty
        else case (next_cycle)                              // 2: the default owner, else 3: free
            3'd0:          win = !cpu_req ? free : (blt_req && blt_high && !cpu_turn) ? C_BLT : C_CPU;
            3'd1, 3'd3:    win = hard_any ? hard : free;
            3'd4:          win = cop_hi ? C_COP : free;
            3'd2:          win = aud_req ? C_AUD : free;
            default:       win = free;
        endcase
        if (!start_next) win = C_NONE;
    end

    assign go       = (win != C_NONE);
    assign go_tag   = win;
    assign go_we    = (win == C_CPU) ? cpu_we : (win == C_BLT) ? blt_we : (win == C_PORT) ? port_we : 1'b0;
    assign go_addr  = (win == C_CPU) ? cpu_addr : (win == C_BPL) ? bpl_addr : (win == C_SPR) ? spr_addr :
                      (win == C_AUD) ? aud_addr : (win == C_COP) ? cop_addr : (win == C_BLT) ? blt_addr : port_addr;
    assign go_wdata = (win == C_CPU) ? cpu_wdata : (win == C_BLT) ? blt_wdata : port_wdata;
    assign go_be    = (win == C_CPU) ? cpu_be : (win == C_BLT) ? blt_be : (win == C_PORT) ? port_be : 2'b11;

    always @(posedge clk) begin
        cpu_ack  <= !rst && win == C_CPU;
        bpl_ack  <= !rst && win == C_BPL;
        spr_ack  <= !rst && win == C_SPR;
        aud_ack  <= !rst && win == C_AUD;
        cop_ack  <= !rst && win == C_COP;
        blt_ack  <= !rst && win == C_BLT;
        port_ack <= !rst && win == C_PORT;
    end

    // Read data back to its channel (rdata itself is shared)
    assign cpu_rvalid  = rvalid && rtag == C_CPU;
    assign bpl_rvalid  = rvalid && rtag == C_BPL;
    assign spr_rvalid  = rvalid && rtag == C_SPR;
    assign aud_rvalid  = rvalid && rtag == C_AUD;
    assign cop_rvalid  = rvalid && rtag == C_COP;
    assign blt_rvalid  = rvalid && rtag == C_BLT;
    assign port_rvalid = rvalid && rtag == C_PORT;
endmodule
