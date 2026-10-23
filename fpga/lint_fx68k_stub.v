// Stand-in for the fx68k core when linting (fpga/lint.sh): the same ports,
// no logic. The core is third-party code and is not linted (older
// versions of the linter also reject its style outright).
module fx68k (
    input  wire        clk, HALTn, extReset, pwrUp, enPhi1, enPhi2,
    output wire        eRWn, ASn, LDSn, UDSn, E, VMAn, FC0, FC1, FC2, BGn,
    output wire        oRESETn, oHALTEDn,
    input  wire        DTACKn, VPAn, BERRn, BRn, BGACKn, IPL0n, IPL1n, IPL2n,
    input  wire [15:0] iEdb,
    output wire [15:0] oEdb,
    output wire [23:1] eab
);
    assign {eRWn, ASn, LDSn, UDSn, E, VMAn, FC0, FC1, FC2, BGn, oRESETn, oHALTEDn} = 12'hFFF;
    assign oEdb = 16'd0;
    assign eab  = 23'd0;
endmodule