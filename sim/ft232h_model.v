// FT232H in asynchronous 245 FIFO mode, as seen from the FPGA, with the PC
// on the other side. Bytes for the computer are queued with send(); bytes
// from the computer are printed and kept in a buffer the testbench reads.
// Timing (FT232H datasheet, async FIFO): RD# low to data valid 14 ns max;
// RXF# goes high within 14 ns of RD# rising and stays high at least 49 ns;
// data must be stable 5 ns before WR# falls and 5 ns after.
`timescale 1ns/1ps
module ft232h_model (
    inout  wire [7:0] d,
    output reg        rxf_n,
    output reg        txe_n,
    input  wire       rd_n,
    input  wire       wr_n,
    input  wire       siwu_n
);
    reg  [7:0] to_fpga [0:4095];
    integer    head = 0, tail = 0;
    reg  [7:0] from_fpga [0:65535];
    integer    nout = 0;
    integer    errors = 0;
    integer    siwu_count = 0;

    reg  [7:0] dout;
    reg        drive = 0;
    assign d = drive ? dout : 8'hzz;

    initial begin rxf_n = 1; txe_n = 0; end

    task send(input [7:0] b);
        begin
            to_fpga[tail] = b;
            tail = tail + 1;
            if (rd_n) rxf_n = 0;
        end
    endtask

    // PC -> computer
    reg reading = 0;
    always @(negedge rd_n) begin
        reading = 1;
        if (rxf_n) begin
            $display("%t FT232H ERROR: RD# while RXF# high", $realtime);
            errors = errors + 1;
        end
        #14 dout = to_fpga[head];
        drive = 1;
    end
    always @(posedge rd_n) if (reading) begin
        reading = 0;
        #2 drive = 0;
        head = head + 1;
        #5 rxf_n = 1;
        #49 if (head != tail) rxf_n = 0;
    end

    // Computer -> PC
    real t_dchange = 0, t_fall = 0;
    always @(d) t_dchange = $realtime;
    always @(negedge wr_n) if ($realtime > 0) begin
        if (txe_n) begin
            $display("%t FT232H ERROR: WR# while TXE# high", $realtime);
            errors = errors + 1;
        end
        if ($realtime - t_dchange < 5.0) begin
            $display("%t FT232H ERROR: data set up only %0.2f ns before WR#", $realtime, $realtime - t_dchange);
            errors = errors + 1;
        end
        from_fpga[nout] = d;
        nout = nout + 1;
        $write("%c", d);
        $fflush;
        t_fall = $realtime;
        #5 if (t_dchange > t_fall) begin
            $display("%t FT232H ERROR: data not held 5 ns after WR#", $realtime);
            errors = errors + 1;
        end
        txe_n = 1;
        #50 txe_n = 0;
    end
    always @(negedge siwu_n) siwu_count = siwu_count + 1;
endmodule
