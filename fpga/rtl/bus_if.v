// 68000 bus interface (spec 1).
//
// Runs at 100 MHz. fx68k (40 MHz) changes its outputs only on the 50 ns
// grid or 25 ns after it; they are captured here only at 20 and 40 ns into
// each 50 ns. Signals to fx68k change only at 10 and 30 ns. Every crossing
// therefore has at least 15 ns (spec 1, section 3).
//
// Chip RAM reads use the CPU's memory cycle (cycle 0) at the start of the
// bus cycle's second slot. /DTACK is given as soon as that cycle is issued
// (110 ns into the bus cycle), and the data follows at 160 ns, before the
// 68000 latches it at 175 ns (spec 1, section 4.1).
//
// Chip RAM writes are posted: /UDS and /LDS only appear at S4, too late
// for that slot's cycle 0, so /DTACK is given early and the write uses the
// cycle 0 of the next slot. The CPU never reads in that slot (it is the
// first slot of its next bus cycle), so writes cost no wait states either.
//
// If a bus cycle ever starts in the middle of a slot (the wrong 50 ns of
// the grid), the early /DTACK simply comes one 68000 clock later: one wait
// state, after which the bus cycles are back in step with the slots.
module bus_if #(
    parameter CHIP_TOP = 24'h400000      // end of Chip RAM (0x200000 on 2 MB boards)
) (
    input  wire        clk,              // 100 MHz
    input  wire        rst,
    input  wire [2:0]  ph,               // timebase: edge index within 50 ns

    // fx68k outputs (40 MHz domain)
    input  wire        c_as_n, c_uds_n, c_lds_n, c_rw,
    input  wire [2:0]  c_fc,
    input  wire [23:1] c_addr,
    input  wire [15:0] c_dout,

    // to fx68k
    output reg         dtack_n,
    output reg         berr_n,
    output reg  [15:0] din,

    // settings (SYSCON)
    input  wire        overlay,
    input  wire        romwe,
    input  wire        protect,

    // Chip RAM (SRAM controller CPU port)
    output reg         m_req,
    output reg         m_we,
    output reg  [21:1] m_addr,
    output reg  [15:0] m_wdata,
    output reg  [1:0]  m_be,
    input  wire        m_ack,
    input  wire        m_rvalid,
    input  wire [15:0] m_rdata,

    // Boot ROM (block RAM, 1 clock read latency)
    output wire        rom_en,
    output wire [1:0]  rom_we,
    output wire [14:1] rom_addr,
    output wire [15:0] rom_wdata,
    input  wire [15:0] rom_rdata,

    // Register bus: 32-bit, 1 clock read latency; byte enables [3] = D31-24
    output reg         rb_rd,
    output reg         rb_wr,
    output reg  [23:2] rb_addr,
    output reg  [31:0] rb_wdata,
    output reg  [3:0]  rb_be,
    input  wire [31:0] rb_rdata,

    // Interrupt acknowledge (spec 13)
    output reg         iack,             // 1 clock
    output reg  [2:0]  iack_level,
    input  wire [7:0]  iack_vector,      // valid while iack is high

    // Last bus error (BUSERRADDR, BUSERRWHY)
    output reg         berr_ev,          // 1 clock
    output reg  [23:0] berr_addr,
    output reg  [3:0]  berr_why          // UNMAPPED (0), ROMWRITE (1), PROTECT (2), CPUSPACE (3)
);
    // ---------------------------------------------------------------- capture
    // Edges 2 and 4 of each 50 ns (the clock before them has ph 1 or 3)
    wire cap = (ph == 3'd1) || (ph == 3'd3);
    reg        q_as_n = 1'b1, q_uds_n = 1'b1, q_lds_n = 1'b1, q_rw = 1'b1;
    reg [2:0]  q_fc;
    reg [23:1] q_addr;
    reg [15:0] q_dout;
    always @(posedge clk) if (cap) begin
        q_as_n  <= c_as_n;
        q_uds_n <= c_uds_n;
        q_lds_n <= c_lds_n;
        q_rw    <= c_rw;
        q_fc    <= c_fc;
        q_addr  <= c_addr;
        q_dout  <= c_dout;
    end

    // ---------------------------------------------------------------- drive
    // Edges 1 and 3 of each 50 ns (the clock before them has ph 0 or 2)
    wire drv = (ph == 3'd0) || (ph == 3'd2);
    reg        dtack_want, berr_want;
    reg [15:0] dout_hold;
    reg        early_ack;           // combinational: /DTACK for a read being issued now
    reg        bypass_valid;        // combinational: read data arriving now
    reg [15:0] bypass_data;

    always @(posedge clk) begin
        if (rst) begin
            dtack_n <= 1'b1;
            berr_n  <= 1'b1;
            din     <= 16'd0;
        end else if (drv) begin
            dtack_n <= ~(dtack_want | early_ack);
            berr_n  <= ~berr_want;
            din     <= bypass_valid ? bypass_data : dout_hold;
        end
    end

    // ---------------------------------------------------------------- decode
    localparam T_CHIP = 3'd0, T_ROM = 3'd1, T_REG = 3'd2, T_IACK = 3'd3, T_BERR = 3'd4;
    localparam W_UNMAPPED = 4'b0001, W_ROMWRITE = 4'b0010, W_PROTECT = 4'b0100, W_CPUSPACE = 4'b1000;

    wire [23:0] a24 = {q_addr, 1'b0};
    wire        user_mode = !q_fc[2];
    wire        cpu_space = (q_fc == 3'b111);
    wire        in_rom    = (a24[23:15] == 9'b1111_1000_0);              // F80000-F87FFF
    wire        in_ovl    = overlay && q_rw && (a24[23:15] == 9'd0);     // 000000-007FFF reads
    wire        in_chip   = (a24 < CHIP_TOP);
    wire        in_custom = (a24[23:16] == 8'hE0) ||
                            (a24[23:14] == 10'b1110_0001_00);            // E00000-E13FFF
    wire        in_system = (a24[23:16] == 8'hF0);
    wire        hw_area   = (a24[23:21] == 3'b111);                      // E00000-FFFFFF

    reg [2:0] target;
    reg [3:0] why;
    always @(*) begin
        why = 4'd0;
        if (cpu_space) begin
            target = (a24[19:16] == 4'hF) ? T_IACK : T_BERR;
            why    = W_CPUSPACE;
        end else if (protect && user_mode && hw_area) begin
            target = T_BERR;
            why    = W_PROTECT;
        end else if (in_ovl) begin
            target = T_ROM;
        end else if (in_chip) begin
            target = T_CHIP;
        end else if (in_rom) begin
            target = (q_rw || romwe) ? T_ROM : T_BERR;
            why    = W_ROMWRITE;
        end else if (in_custom || in_system) begin
            target = T_REG;
        end else begin
            target = T_BERR;
            why    = W_UNMAPPED;
        end
    end

    // ---------------------------------------------------------------- bus cycle
    localparam S_IDLE = 3'd0, S_CHIP_RD = 3'd1, S_LANES = 3'd2, S_ROM_RD = 3'd3,
               S_REG_RD = 3'd4, S_IACK = 3'd5, S_DONE = 3'd6, S_REG_WAIT = 3'd7;
    reg [2:0]  state;
    reg [2:0]  tgt;            // target of the current cycle
    reg        rd_half_hi;     // register read: high half

    wire       lanes  = !q_uds_n || !q_lds_n;
    wire [1:0] be     = {!q_uds_n, !q_lds_n};

    // Posted Chip RAM write
    reg        wp;             // m_req holds a posted write

    // Register halves (spec 3, section 2)
    reg        wh_valid;       // a high half is held
    reg [23:2] wh_tag;
    reg [15:0] wh_data;
    reg [1:0]  wh_be;
    reg        rh_valid;       // a captured 32-bit value is held
    reg [23:2] rh_tag;
    reg [31:0] rh_data;

    // ROM port
    reg        rom_rd_go, rom_wr_go;
    assign rom_en    = rom_rd_go || rom_wr_go;
    assign rom_we    = rom_wr_go ? be : 2'b00;
    assign rom_addr  = q_addr[14:1];
    assign rom_wdata = q_dout;

    always @(*) begin
        rom_rd_go    = (state == S_IDLE) && !q_as_n && (target == T_ROM) && q_rw;
        rom_wr_go    = (state == S_LANES) && (tgt == T_ROM) && lanes;
        early_ack    = (state == S_CHIP_RD) && m_ack;
        bypass_valid = (state == S_CHIP_RD) && m_rvalid;
        bypass_data  = m_rdata;
    end

    always @(posedge clk) begin
        rb_rd   <= 1'b0;
        rb_wr   <= 1'b0;
        iack    <= 1'b0;
        berr_ev <= 1'b0;

        if (m_ack) begin
            m_req <= 1'b0;
            wp    <= 1'b0;
        end

        if (rst) begin
            state      <= S_IDLE;
            dtack_want <= 1'b0;
            berr_want  <= 1'b0;
            m_req      <= 1'b0;
            wp         <= 1'b0;
            wh_valid   <= 1'b0;
            rh_valid   <= 1'b0;
            dout_hold  <= 16'd0;
        end else case (state)
            S_IDLE: if (!q_as_n && !(m_req && !m_ack)) begin
                // A new bus cycle (wait for a posted write still waiting for its cycle)
                tgt <= target;
                case (target)
                    T_CHIP: begin
                        m_addr <= q_addr[21:1];
                        if (q_rw) begin
                            m_req <= 1'b1;
                            m_we  <= 1'b0;
                            state <= S_CHIP_RD;
                        end else begin
                            dtack_want <= 1'b1;
                            state      <= S_LANES;
                        end
                    end
                    T_ROM: begin
                        if (q_rw) state <= S_ROM_RD;
                        else begin
                            dtack_want <= 1'b1;
                            state      <= S_LANES;
                        end
                    end
                    T_REG: begin
                        rb_addr <= q_addr[23:2];
                        if (q_rw) begin
                            rd_half_hi <= !q_addr[1];
                            if (q_addr[1] && rh_valid && rh_tag == q_addr[23:2]) begin
                                // Low half after a high-half read: the captured value
                                dout_hold  <= rh_data[15:0];
                                rh_valid   <= 1'b0;
                                dtack_want <= 1'b1;
                                state      <= S_DONE;
                            end else begin
                                rb_rd <= 1'b1;
                                state <= S_REG_WAIT;
                            end
                        end else begin
                            dtack_want <= 1'b1;
                            state      <= S_LANES;
                        end
                    end
                    T_IACK: begin
                        iack       <= 1'b1;
                        iack_level <= q_addr[3:1];
                        state      <= S_IACK;
                    end
                    default: begin
                        berr_want <= 1'b1;
                        berr_ev   <= 1'b1;
                        berr_addr <= a24;
                        berr_why  <= why;
                        state     <= S_DONE;
                    end
                endcase
            end

            S_CHIP_RD: if (m_rvalid) begin
                dout_hold  <= m_rdata;
                dtack_want <= 1'b1;
                state      <= S_DONE;
            end

            S_ROM_RD: begin
                dout_hold  <= rom_rdata;
                dtack_want <= 1'b1;
                state      <= S_DONE;
            end

            S_REG_WAIT: state <= S_REG_RD;   // the device registers its data

            S_REG_RD: begin
                dout_hold <= rd_half_hi ? rb_rdata[31:16] : rb_rdata[15:0];
                if (rd_half_hi) begin
                    rh_valid <= 1'b1;
                    rh_tag   <= rb_addr;
                    rh_data  <= rb_rdata;
                end
                dtack_want <= 1'b1;
                state      <= S_DONE;
            end

            S_IACK: begin
                dout_hold  <= {8'd0, iack_vector};
                dtack_want <= 1'b1;
                state      <= S_DONE;
            end

            S_LANES: if (lanes) begin
                // Write strobes are out: the byte lanes and data are known
                case (tgt)
                    T_CHIP: begin
                        m_req   <= 1'b1;
                        m_we    <= 1'b1;
                        m_wdata <= q_dout;
                        m_be    <= be;
                        wp      <= 1'b1;
                    end
                    T_REG: begin
                        if (!q_addr[1]) begin
                            wh_valid <= 1'b1;
                            wh_tag   <= q_addr[23:2];
                            wh_data  <= q_dout;
                            wh_be    <= be;
                        end else begin
                            rb_wr    <= 1'b1;
                            rb_wdata <= {wh_data, q_dout};
                            rb_be    <= {(wh_valid && wh_tag == q_addr[23:2]) ? wh_be : 2'b00, be};
                            wh_valid <= 1'b0;
                        end
                    end
                    default: ;   // ROM write happens through rom_wr_go
                endcase
                state <= S_DONE;
            end

            S_DONE: if (q_as_n) begin
                dtack_want <= 1'b0;
                berr_want  <= 1'b0;
                state      <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
endmodule
