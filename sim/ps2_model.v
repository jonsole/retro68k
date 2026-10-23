// A PS/2 keyboard, for the I/O test (spec 16). Both lines are open
// collector: the model pulls them low through clk_low and data_low, and
// reads the wired-AND lines.
//
//   send(b, bad)   a frame from the keyboard (bad: wrong parity), clocked at
//                  50 kHz (a real keyboard: 10-17 kHz; the controller does
//                  not mind, and the simulation is shorter)
//   host to keyboard: when the host holds the clock low and then pulls data
//                  low, the model clocks the byte in, answers with the ack
//                  bit, and then sends 0xFA. last_rx is the byte; rx_bad
//                  counts bad frames.
`timescale 1ns/1ps
module ps2_model (
    input  wire clk_line,
    input  wire data_line,
    output reg  clk_low = 1'b0,
    output reg  data_low = 1'b0
);
    localparam HALF = 10000;           // ns: half a clock period, 50 kHz
    reg  [7:0] last_rx = 8'h00;
    integer    rx_bad = 0, nrx = 0;
    reg        busy = 1'b0;

    task bit_out(input b);
        begin
            data_low = !b;
            #(HALF / 2);
            clk_low = 1'b1;            // the host takes the bit at this falling edge
            #HALF;
            clk_low = 1'b0;
            #(HALF / 2);
        end
    endtask

    task send(input [7:0] b, input bad);
        integer k;
        begin
            wait (!busy);
            busy = 1'b1;
            bit_out(1'b0);
            for (k = 0; k < 8; k = k + 1) bit_out(b[k]);
            bit_out(~^b ^ bad);        // odd parity (inverted when bad)
            bit_out(1'b1);
            data_low = 1'b0;
            #(4 * HALF);
            busy = 1'b0;
        end
    endtask

    // host to keyboard: the host pulls the clock low (for 100 us), then data
    // low, and lets the clock go
    always @(negedge clk_line) if (!clk_low && !busy) begin : host
        integer k;
        reg [9:0] r;
        #1;
        if (!clk_line) begin
            wait (clk_line);           // the host lets the clock go ...
            #100;
            if (!data_line) begin      // ... with data low: a request to send
                busy = 1'b1;
                #(HALF);
                for (k = 0; k < 10; k = k + 1) begin   // 8 data bits, parity, stop
                    clk_low = 1'b1;    // the host puts the bit out after this falling edge
                    #HALF;
                    clk_low = 1'b0;
                    #(HALF / 2);
                    r[k] = data_line;  // ... and it is taken while the clock is high
                    #(HALF / 2);
                end
                data_low = 1'b1;       // the ack bit
                clk_low  = 1'b1;
                #HALF;
                clk_low  = 1'b0;
                #(HALF / 2);
                data_low = 1'b0;
                #(HALF / 2);
                if ((^r[8:0]) != 1'b1 || !r[9]) rx_bad = rx_bad + 1;
                last_rx = r[7:0];
                nrx = nrx + 1;
                #(4 * HALF);
                busy = 1'b0;
                send(8'hFA, 1'b0);     // acknowledge
            end
        end
    end
endmodule
