// Power-on reset that ends on the 50 ns grid (spec 1, section 3; timebase.v).
//
// clk100 and clk40 come from the same MMCM; their rising edges line up every
// 50 ns. To find where, clk40 toggles t40 on every edge and clk100 samples
// it. Calling the five clk100 edges in each 50 ns e0 (on the grid) to e4,
// t40 is X from 0 to 25 ns and ~X from 25 to 50 ns, and the sample taken on
// the shared edge e0 still sees the old value, so the samples read:
//
//     e0  e1  e2  e3  e4
//     ~X   X   X  ~X  ~X
//
// The only run of exactly two equal samples is e1, e2. Once the newest
// sample (from e3) follows such a run, the clock now running started at e3.
// The reset is released by a register that changes on an e0 edge, so both
// clock domains see it go away at the same moment: the last edge that sees
// it high is a grid edge.
module por_align (
    input  wire clk100,
    input  wire clk40,
    input  wire locked,
    output reg  por = 1'b1        // to por100 and por40
);
    reg t40 = 1'b0;
    always @(posedge clk40) t40 <= ~t40;

    reg [1:0]  lk = 2'b00;
    reg [3:0]  smp = 4'd0;         // smp[0] newest
    reg [2:0]  ph = 3'd0;
    reg        found = 1'b0;
    reg [15:0] wait_c = 16'd0;

    wire run2 = (smp[3] != smp[2]) && (smp[2] == smp[1]) && (smp[1] != smp[0]);

    always @(posedge clk100) begin
        lk  <= {lk[0], locked};
        smp <= {smp[2:0], t40};
        ph  <= (ph == 3'd4) ? 3'd0 : ph + 1'b1;

        if (!lk[1]) begin
            found  <= 1'b0;
            wait_c <= 16'd0;
            por    <= 1'b1;
        end else begin
            if (!found && run2) begin
                // This clock started at e3, so the next one starts at e4
                found <= 1'b1;
                ph    <= 3'd4;
            end
            if (found && wait_c != 16'hFFFF) wait_c <= wait_c + 1'b1;
            // Release on a grid edge, after the clocks have run for 655 us
            if (found && wait_c == 16'hFFFF && ph == 3'd4) por <= 1'b0;
        end
    end
endmodule
