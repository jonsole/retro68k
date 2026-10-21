// IS61WV204816BLL-10 model: 2M x 16 asynchronous SRAM with timing checks.
// Datasheet figures used (10 ns part): tAA 10, tOHA 2.5, tDOE 4.5, tHZOE 4,
// tPWE 8, tSD 6, tHD 0, tAW 8, tSA 0, tHA 0.
`timescale 1ns/1ps
module sram_model (
    input  wire [20:0] a,
    inout  wire [15:0] dq,
    input  wire        ce_n, oe_n, we_n, ub_n, lb_n,
    input  wire        fpga_drives       // for the bus-contention check
);
    reg [15:0] mem [0:(1<<21)-1];
    integer errors = 0;

    // ---- read: data is valid once the address has been stable for tAA and
    // /OE low for tDOE; the SRAM drives from /OE low until tHZOE after it rises.
    real t_a = 0, t_we_lo = 0, t_d = 0;
    reg  [20:0] a_d;        // the address, 10 ns ago
    reg         oe_d45;     // /OE, 4.5 ns ago
    reg         oe_d3;      // /OE, 3 ns ago
    always @(a)    begin t_a = $realtime; a_d <= #10 a; end
    always @(oe_n) begin oe_d45 <= #4.5 oe_n; oe_d3 <= #3 oe_n; end
    always @(dq)   t_d = $realtime;
    initial begin a_d = 0; oe_d45 = 1; oe_d3 = 1; end

    wire        drive = !ce_n && we_n && (!oe_n || !oe_d3);
    wire        valid = !oe_n && !oe_d45 && (a_d === a);
    wire [15:0] q     = valid ? mem[a] : 16'hxxxx;
    assign dq = drive ? {ub_n ? 8'hzz : q[15:8], lb_n ? 8'hzz : q[7:0]} : 16'hzzzz;

    // ---- contention
    always @(drive or fpga_drives) if (drive && fpga_drives) begin
        $display("%t SRAM ERROR: bus contention (SRAM and FPGA both drive DQ)", $realtime);
        errors = errors + 1;
    end

    // ---- write: on /WE rising edge
    always @(negedge we_n) if (!ce_n) t_we_lo = $realtime;
    always @(a) if (!we_n && !ce_n) begin
        $display("%t SRAM ERROR: address changed while /WE low", $realtime);
        errors = errors + 1;
    end
    always @(posedge we_n) if (!ce_n) begin
        if ($realtime - t_we_lo < 8.0) begin
            $display("%t SRAM ERROR: /WE pulse %0.2f ns < tPWE 8", $realtime, $realtime - t_we_lo);
            errors = errors + 1;
        end
        if ($realtime - t_a < 8.0) begin
            $display("%t SRAM ERROR: address valid %0.2f ns before /WE high < tAW 8", $realtime, $realtime - t_a);
            errors = errors + 1;
        end
        if ($realtime - t_d < 6.0) begin
            $display("%t SRAM ERROR: data valid %0.2f ns before /WE high < tSD 6", $realtime, $realtime - t_d);
            errors = errors + 1;
        end
        if ((!ub_n && ^dq[15:8] === 1'bx) || (!lb_n && ^dq[7:0] === 1'bx)) begin
            $display("%t SRAM ERROR: writing undefined data %h", $realtime, dq);
            errors = errors + 1;
        end
        if (!ub_n) mem[a][15:8] = dq[15:8];
        if (!lb_n) mem[a][7:0]  = dq[7:0];
    end
    // Data hold after /WE rises: tHD = 0, nothing to check beyond the edge.
endmodule
