// fx68k clocked at 40 MHz with alternating phase enables: a 20 MHz 68000
// (spec 1, section 2).
//
// cph is the index of the current 40 MHz edge within the 50 ns grid
// (0 = on the grid, 1 = 25 ns later). enPhi1 is given in the clock before a
// grid edge, so the 68000's rising clock edges fall on the grid, and its
// falling edges 25 ns later.
module cpu_fx68k (
    input  wire        clk,       // 40 MHz
    input  wire        por,       // power-on reset, last seen high on the 50 ns grid
    input  wire        rst,       // CPU reset (any reset)
    input  wire        pwrup,     // cold start (with rst at power-on)
    output wire        as_n, uds_n, lds_n, rw,
    output wire [2:0]  fc,
    output wire [23:1] addr,
    output wire [15:0] dout,
    output wire        reset_out_n, halted_n,
    input  wire        dtack_n, berr_n,
    input  wire [2:0]  ipl_n,
    input  wire [15:0] din
);
    reg cph;
    always @(posedge clk)
        cph <= por ? 1'b0 : ~cph;

    wire en_phi1 = (cph == 1'b1);    // next edge is on the grid: 68000 clock rises
    wire en_phi2 = (cph == 1'b0);    // next edge is 25 ns later: 68000 clock falls

    wire e_unused, vma_unused, bg_unused;

    fx68k core (
        .clk(clk), .HALTn(1'b1),
        .extReset(rst), .pwrUp(pwrup),
        .enPhi1(en_phi1), .enPhi2(en_phi2),
        .eRWn(rw), .ASn(as_n), .LDSn(lds_n), .UDSn(uds_n),
        .E(e_unused), .VMAn(vma_unused),
        .FC0(fc[0]), .FC1(fc[1]), .FC2(fc[2]),
        .BGn(bg_unused),
        .oRESETn(reset_out_n), .oHALTEDn(halted_n),
        .DTACKn(dtack_n), .VPAn(1'b1), .BERRn(berr_n),
        .BRn(1'b1), .BGACKn(1'b1),
        .IPL0n(ipl_n[0]), .IPL1n(ipl_n[1]), .IPL2n(ipl_n[2]),
        .iEdb(din), .oEdb(dout), .eab(addr)
    );
endmodule
