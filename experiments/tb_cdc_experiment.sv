// EXPERIMENT ONLY -- NOT PART OF THE DESIGN.
//
// Sweeps bus skew and reports, for Gray and for binary, how often each domain
// latched the far pointer mid-transition and how many words came out wrong.
//
// This started as "prove the Gray coding matters" and did not go how I
// expected. Notes in experiments/README.md; the short version is that binary
// survives small skew for a reason worth understanding, and Gray is flat at
// zero errors no matter how far the skew is pushed.
//
// All cases share one set of clocks and one winc/rinc stream so the only
// variable is the encoding and the skew.

`timescale 1ns/1ps

module tb_cdc_experiment;

    localparam int DSIZE = 8;
    localparam int ASIZE = 4;
    localparam int N_TXN = 4000;

    logic wclk = 1'b0, rclk = 1'b0;
    logic wrst_n, rrst_n;
    logic winc_req, rinc_req;
    bit   stim_on = 1'b0;

    // 7 and 11.3, not 7 and 11. Integer periods are rationally related, so the
    // read edge only ever lands at whole-nanosecond offsets from the write
    // edge -- eleven fixed sampling phases, which step right over most of the
    // sub-nanosecond windows where the bus is mid-transition. With 11.3 the
    // phase drifts through everything, the way two real oscillators do.
    always #3.50 wclk = ~wclk;   // 7.0 ns
    always #5.65 rclk = ~rclk;   // 11.3 ns

    int seed_ret;
    initial seed_ret = $urandom(20250815);

    always @(posedge wclk) begin
        if (!wrst_n) winc_req <= 1'b0;
        else         winc_req <= stim_on && ($urandom_range(0, 99) < 70);
    end

    always @(posedge rclk) begin
        if (!rrst_n) rinc_req <= 1'b0;
        else         rinc_req <= stim_on && ($urandom_range(0, 99) < 40);
    end

    // Skew is a per-bit step; bit i is delayed by step * ((i*3+1)%4), so the
    // worst-case spread across the bus is 3x the number quoted.
    cdc_case #(.ASIZE(ASIZE), .GRAY_CDC(1), .SKEW_NS(0.0)) g0 (.*);
    cdc_case #(.ASIZE(ASIZE), .GRAY_CDC(1), .SKEW_NS(0.4)) g1 (.*);
    cdc_case #(.ASIZE(ASIZE), .GRAY_CDC(1), .SKEW_NS(1.0)) g2 (.*);
    cdc_case #(.ASIZE(ASIZE), .GRAY_CDC(1), .SKEW_NS(2.0)) g3 (.*);
    cdc_case #(.ASIZE(ASIZE), .GRAY_CDC(1), .SKEW_NS(3.5)) g4 (.*);

    cdc_case #(.ASIZE(ASIZE), .GRAY_CDC(0), .SKEW_NS(0.0)) b0 (.*);
    cdc_case #(.ASIZE(ASIZE), .GRAY_CDC(0), .SKEW_NS(0.4)) b1 (.*);
    cdc_case #(.ASIZE(ASIZE), .GRAY_CDC(0), .SKEW_NS(1.0)) b2 (.*);
    cdc_case #(.ASIZE(ASIZE), .GRAY_CDC(0), .SKEW_NS(2.0)) b3 (.*);
    cdc_case #(.ASIZE(ASIZE), .GRAY_CDC(0), .SKEW_NS(3.5)) b4 (.*);

    initial begin
        $display("=============================================================");
        $display(" CDC encoding vs bus skew");
        $display(" wclk 7.0 ns, rclk 11.3 ns, %0d transactions per case", N_TXN);
        $display("=============================================================");

        stim_on = 1'b0;
        wrst_n  = 1'b0;
        rrst_n  = 1'b0;
        repeat (10) @(posedge wclk);
        repeat (10) @(posedge rclk);
        @(posedge wclk); wrst_n = 1'b1;
        @(posedge rclk); rrst_n = 1'b1;
        repeat (10) @(posedge wclk);

        stim_on = 1'b1;
        wait (g0.n_read >= N_TXN);
        stim_on = 1'b0;
        repeat (200) @(posedge rclk);

        $display("\n  GRAY CODED POINTERS");
        header();
        row("0.0", g0.dut.n_caught_midflight, g0.n_read, g0.n_err);
        row("0.4", g1.dut.n_caught_midflight, g1.n_read, g1.n_err);
        row("1.0", g2.dut.n_caught_midflight, g2.n_read, g2.n_err);
        row("2.0", g3.dut.n_caught_midflight, g3.n_read, g3.n_err);
        row("3.5", g4.dut.n_caught_midflight, g4.n_read, g4.n_err);

        $display("\n  BINARY POINTERS");
        header();
        row("0.0", b0.dut.n_caught_midflight, b0.n_read, b0.n_err);
        row("0.4", b1.dut.n_caught_midflight, b1.n_read, b1.n_err);
        row("1.0", b2.dut.n_caught_midflight, b2.n_read, b2.n_err);
        row("2.0", b3.dut.n_caught_midflight, b3.n_read, b3.n_err);
        row("3.5", b4.dut.n_caught_midflight, b4.n_read, b4.n_err);

        $display("\n  skew      per-bit step in ns; worst-case bus spread is 3x");
        $display("  midflight times a domain latched the far pointer while it");
        $display("            was still settling");
        $display("  errors    words that came out wrong or were never written");
        $display("=============================================================");
        $finish;
    end

    task automatic header();
        $display("    skew   midflight     read    errors");
        $display("    -------------------------------------");
    endtask

    task automatic row(input string skew, input int m, r, e);
        $display("    %4s   %9d %8d %9d", skew, m, r, e);
    endtask

    initial begin
        #2_000_000;
        $display("\nTIMEOUT");
        $finish;
    end

endmodule


// One FIFO under test plus its own reference model.
module cdc_case #(
    parameter int  DSIZE    = 8,
    parameter int  ASIZE    = 4,
    parameter bit  GRAY_CDC = 1,
    parameter real SKEW_NS  = 0.0
) (
    input logic wclk, rclk, wrst_n, rrst_n,
    input logic winc_req, rinc_req
);

    logic [DSIZE-1:0] wdata, rdata;
    logic             wfull, rempty;

    async_fifo_exp #(
        .DSIZE (DSIZE), .ASIZE (ASIZE),
        .GRAY_CDC (GRAY_CDC), .SKEW_NS (SKEW_NS)
    ) dut (
        .wclk (wclk), .wrst_n (wrst_n), .winc (winc_req),
        .wdata (wdata), .wfull (wfull),
        .rclk (rclk), .rrst_n (rrst_n), .rinc (rinc_req),
        .rdata (rdata), .rempty (rempty)
    );

    logic [DSIZE-1:0] ref_mem [0:65535];
    int wr_idx = 0, rd_idx = 0;
    int n_written = 0, n_read = 0, n_err = 0;

    always @(posedge wclk) begin
        if (!wrst_n) wdata <= '0;
        else if (winc_req && !wfull) wdata <= wdata + 1'b1;
    end

    always @(posedge wclk) begin
        if (wrst_n && winc_req && !wfull) begin
            ref_mem[wr_idx] = wdata;
            wr_idx    = wr_idx + 1;
            n_written = n_written + 1;
        end
    end

    always @(posedge rclk) begin
        if (rrst_n && rinc_req && !rempty) begin
            if (rd_idx >= wr_idx || rdata !== ref_mem[rd_idx])
                n_err = n_err + 1;
            rd_idx = rd_idx + 1;
            n_read = n_read + 1;
        end
    end

endmodule
