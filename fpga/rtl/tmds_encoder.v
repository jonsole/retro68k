// DVI TMDS encoder (DVI 1.0, section 3.2.2): 8 data bits to 10 bits with
// transition minimising and DC balance; the control codes during blanking.
module tmds_encoder (
    input  wire       clk,         // pixel clock
    input  wire [7:0] d,
    input  wire [1:0] c,           // control bits (blue: {vsync, hsync})
    input  wire       de,          // 1 = data, 0 = control period
    output reg  [9:0] q
);
    function [3:0] ones8(input [7:0] v);
        ones8 = v[0] + v[1] + v[2] + v[3] + v[4] + v[5] + v[6] + v[7];
    endfunction

    // Stage 1: transition minimising
    wire [3:0] n1d   = ones8(d);
    wire       use_x = (n1d > 4) || (n1d == 4 && d[0] == 1'b0);
    wire [8:0] qm;
    assign qm[0] = d[0];
    genvar i;
    generate for (i = 1; i < 8; i = i + 1) begin : m
        assign qm[i] = use_x ? ~(qm[i-1] ^ d[i]) : (qm[i-1] ^ d[i]);
    end endgenerate
    assign qm[8] = ~use_x;

    // Stage 2: DC balance
    wire [3:0] n1 = ones8(qm[7:0]);
    wire [3:0] n0 = 4'd8 - n1;
    reg  signed [4:0] cnt = 5'sd0;          // running disparity

    always @(posedge clk) begin
        if (!de) begin
            cnt <= 5'sd0;
            case (c)
                2'b00: q <= 10'b1101010100;
                2'b01: q <= 10'b0010101011;
                2'b10: q <= 10'b0101010100;
                2'b11: q <= 10'b1010101011;
            endcase
        end else if (cnt == 0 || n1 == n0) begin
            q   <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
            cnt <= qm[8] ? cnt + $signed({1'b0, n1}) - $signed({1'b0, n0})
                         : cnt + $signed({1'b0, n0}) - $signed({1'b0, n1});
        end else if ((cnt > 0 && n1 > n0) || (cnt < 0 && n0 > n1)) begin
            q   <= {1'b1, qm[8], ~qm[7:0]};
            cnt <= cnt + $signed({3'd0, qm[8], 1'b0}) + $signed({1'b0, n0}) - $signed({1'b0, n1});
        end else begin
            q   <= {1'b0, qm[8], qm[7:0]};
            cnt <= cnt - $signed({3'd0, ~qm[8], 1'b0}) + $signed({1'b0, n1}) - $signed({1'b0, n0});
        end
    end
endmodule
