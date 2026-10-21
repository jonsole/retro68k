// System control registers at 0xF00800 (spec 7, section 9; spec 1, section 9).
// Version 1: identification, SYSCON, SYSRESET, SYSBTN, SYSSTAT and the bus
// error registers. The I2C master (0x840-0x84C) comes later.
`include "regmap.vh"

module sysregs #(
    parameter [31:0] VERSION = 32'h0000_0001,
    parameter [5:0]  CHIPMB  = 6'd4
) (
    input  wire        clk,
    input  wire        rst,           // any reset
    input  wire        por,           // power-on reset only (ROMLOCK)

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output reg  [31:0] rb_rdata,

    input  wire [7:0]  resetwhy,      // RESETWHY bits, from the reset logic
    input  wire [1:0]  buttons,       // MULTIFACE (0), DIVMMC (1), 1 = pressed
    input  wire        halted,
    input  wire        berr_ev,
    input  wire [23:0] berr_addr,
    input  wire [3:0]  berr_why,

    output wire        overlay,
    output wire        romwe,
    output wire        protect,
    output wire        haltreset,
    output reg         soft_reset     // 1 clock: SYSRESET written with 0xA55A
);
    wire [15:0] off = {rb_addr[15:2], 2'b00};
    wire sel = (rb_addr[23:16] == 8'hF0) && (off[15:8] == 8'h08);

    reg [4:0]  syscon;               // HALTRESET, PROTECT, ROMLOCK, ROMWE, OVERLAY
    reg        romlock;
    reg [23:0] beaddr;
    reg [3:0]  bewhy;

    assign overlay   = syscon[0];
    assign romwe     = syscon[1] && !romlock;
    assign protect   = syscon[3];
    assign haltreset = syscon[4];

    // Byte-enable merge for 32-bit registers
    function [31:0] merge(input [31:0] old, input [31:0] new, input [3:0] be);
        merge = { be[3] ? new[31:24] : old[31:24], be[2] ? new[23:16] : old[23:16],
                  be[1] ? new[15:8]  : old[15:8],  be[0] ? new[7:0]   : old[7:0] };
    endfunction

    wire [31:0] syscfg = (32'd0 << 16) | ({26'd0, CHIPMB} << 10) | (32'd20 << 2) | 32'd0;

    always @(posedge clk) begin
        soft_reset <= 1'b0;
        if (por) romlock <= 1'b0;
        if (rst) begin
            syscon <= 5'b00001;          // overlay on at every reset
        end else if (rb_wr && sel) begin
            case (off)
                `RM_SYSCON: begin : wsyscon
                    reg [31:0] v;
                    v = merge({27'd0, syscon}, rb_wdata, rb_be);
                    syscon <= v[4:0];
                    if (v[2]) romlock <= 1'b1;
                end
                `RM_SYSRESET: if (rb_be[1:0] == 2'b11 && rb_wdata[15:0] == 16'hA55A) soft_reset <= 1'b1;
                default: ;
            endcase
        end

        if (berr_ev) begin
            beaddr <= berr_addr;
            bewhy  <= berr_why;
        end

        rb_rdata <= 32'd0;
        if (rb_rd && sel) case (off)
            `RM_SYSID:      rb_rdata <= 32'h5236384B;     // "R68K"
            `RM_SYSVER:     rb_rdata <= VERSION;
            `RM_SYSCFG:     rb_rdata <= syscfg;
            `RM_RESETWHY:   rb_rdata <= {24'd0, resetwhy};
            `RM_SYSCON:     rb_rdata <= {27'd0, syscon[4:3], romlock, syscon[1:0]};
            `RM_SYSBTN:     rb_rdata <= {30'd0, buttons};
            `RM_SYSSTAT:    rb_rdata <= {31'd0, halted};
            `RM_BUSERRADDR: rb_rdata <= {8'd0, beaddr};
            `RM_BUSERRWHY:  rb_rdata <= {28'd0, bewhy};
            default: ;
        endcase
    end
endmodule
