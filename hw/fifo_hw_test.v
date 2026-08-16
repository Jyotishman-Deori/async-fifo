// Self-checking hardware test for async_fifo, for the PYNQ-Z2.
//
// Same idea as the simulation testbench, rebuilt as synthesisable logic: an
// LFSR generates the write data, an identical LFSR on the read side predicts
// what should come back, and a comparator counts the words that don't match.
// A second pair of LFSRs stalls both interfaces so full and empty are actually
// reached instead of just being theoretically possible.
//
// The reason for running this on hardware at all is the clocks. In simulation
// I could only ever sample at a fixed set of relative phases, and every bit of
// a bus changed at the same instant. Here wclk comes off the PS PLL and rclk
// off the board's 125 MHz oscillator, which are two independent crystals. They
// drift against each other continuously, so over a few seconds the sampling
// point sweeps through every phase relationship there is, including the ones
// that put a synchroniser input right on its setup/hold edge.
//
// w_rate and r_rate set how often each side asks for a transfer, out of 16.
// They only change while run is low, so the multi-bit values are static across
// the clock boundary and there is nothing to catch mid-transition. The
// counters work the same way in reverse: they are read back once run has gone
// low and both sides have stopped, so nothing is moving while they are sampled.

module fifo_hw_test #(
    parameter DSIZE = 8,
    parameter ASIZE = 4
) (
    input  wire        wclk,
    input  wire        wrst_n,
    input  wire        rclk,
    input  wire        rrst_n,

    input  wire        run_w,       // already synchronised into wclk
    input  wire        run_r,       // already synchronised into rclk
    input  wire [3:0]  w_rate,      // static while run is low
    input  wire [3:0]  r_rate,

    output reg  [31:0] words_written,
    output reg  [31:0] words_read,
    output reg  [31:0] errors,
    output reg         full_seen,
    output reg         empty_seen
);

    wire [DSIZE-1:0] wdata, rdata;
    wire             wfull, rempty;
    reg              winc, rinc;

    // maximal-length LFSRs: 8-bit for data, 16-bit for the stall pattern
    reg [7:0]  wlfsr, rlfsr;
    reg [15:0] wstall, rstall;

    function [7:0] lfsr8;
        input [7:0] s;
        lfsr8 = {s[6:0], s[7] ^ s[5] ^ s[4] ^ s[3]};
    endfunction

    function [15:0] lfsr16;
        input [15:0] s;
        lfsr16 = {s[14:0], s[15] ^ s[13] ^ s[12] ^ s[10]};
    endfunction

    async_fifo #(
        .DSIZE (DSIZE),
        .ASIZE (ASIZE)
    ) dut (
        .wclk (wclk), .wrst_n (wrst_n), .winc (winc), .wdata (wdata), .wfull (wfull),
        .rclk (rclk), .rrst_n (rrst_n), .rinc (rinc), .rdata (rdata), .rempty (rempty)
    );

    // ---------------------------------------------------------------------
    // write side
    // ---------------------------------------------------------------------
    assign wdata = wlfsr;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wstall <= 16'hACE1;
            winc   <= 1'b0;
        end else begin
            wstall <= lfsr16(wstall);
            winc   <= run_w && (wstall[3:0] < w_rate);
        end
    end

    // The data only advances on an accepted write, which is what keeps the
    // two LFSRs in lockstep. If the FIFO ever drops or duplicates a word the
    // replica falls out of step and every word after it counts as an error,
    // so a single lost word shows up as a large error count rather than a
    // quiet one.
    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wlfsr         <= 8'hA5;
            words_written <= 32'd0;
            full_seen     <= 1'b0;
        end else begin
            if (wfull) full_seen <= 1'b1;
            if (winc && !wfull) begin
                wlfsr         <= lfsr8(wlfsr);
                words_written <= words_written + 32'd1;
            end
        end
    end

    // ---------------------------------------------------------------------
    // read side
    // ---------------------------------------------------------------------
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rstall <= 16'h1234;
            rinc   <= 1'b0;
        end else begin
            rstall <= lfsr16(rstall);
            rinc   <= run_r && (rstall[3:0] < r_rate);
        end
    end

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rlfsr      <= 8'hA5;
            words_read <= 32'd0;
            errors     <= 32'd0;
            empty_seen <= 1'b0;
        end else begin
            if (rempty) empty_seen <= 1'b1;
            if (rinc && !rempty) begin
                if (rdata != rlfsr) errors <= errors + 32'd1;
                rlfsr      <= lfsr8(rlfsr);
                words_read <= words_read + 32'd1;
            end
        end
    end

endmodule
