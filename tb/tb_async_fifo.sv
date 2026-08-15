// Testbench for the dual-clock async FIFO.
//
// Two phases in one run, because a CDC design that only works one way round
// isn't working:
//   phase 1  fast write (7 ns), slow read (11 ns)   -> exercises full
//   phase 2  slow write (11 ns), fast read (7 ns)   -> exercises empty
//
// 7 and 11 are deliberate. Related periods like 10 and 20 line their edges up
// and hide exactly the bugs this is meant to catch.
//
// Checks are procedural rather than SVA because ModelSim ASE supports neither
// assertions nor covergroups. The same design is checked again with real SVA
// and covergroups in tb/async_fifo_sva.sv under Vivado XSim.

`timescale 1ns/1ps

module tb_async_fifo;

    localparam int DSIZE = 8;
    localparam int ASIZE = 4;
    localparam int DEPTH = 1 << ASIZE;

    localparam int TXN_PER_PHASE = 5000;

    // Half periods, as variables so phase 2 can swap them over.
    real whalf = 3.5;
    real rhalf = 5.5;

    logic             wclk = 1'b0, rclk = 1'b0;
    logic             wrst_n, rrst_n;
    logic             winc, rinc;
    logic [DSIZE-1:0] wdata, rdata;
    logic             wfull, rempty;

    always #(whalf) wclk = ~wclk;
    always #(rhalf) rclk = ~rclk;

    async_fifo #(
        .DSIZE (DSIZE),
        .ASIZE (ASIZE)
    ) dut (
        .wclk (wclk), .wrst_n (wrst_n), .winc (winc), .wdata (wdata), .wfull (wfull),
        .rclk (rclk), .rrst_n (rrst_n), .rinc (rinc), .rdata (rdata), .rempty (rempty)
    );

    // -----------------------------------------------------------------
    // reference model
    //
    // A plain circular array rather than a queue, so this compiles on ASE.
    // Depth is far more than the FIFO needs; it only has to outlive a phase.
    // -----------------------------------------------------------------
    logic [DSIZE-1:0] ref_mem [0:65535];
    int wr_idx = 0, rd_idx = 0;

    // per-phase, cleared by do_reset
    int n_written = 0, n_read = 0;
    // whole run
    int tot_written = 0, tot_read = 0;

    int n_data_err = 0, n_overflow = 0, n_underflow = 0, n_residual_err = 0;

    // coverage, counted by hand
    int cov_full = 0, cov_empty = 0, cov_concurrent = 0, cov_b2b_write = 0;
    logic wrote_last_cycle = 1'b0;

    bit stim_on  = 1'b0;
    bit drain_on = 1'b0;

    int seed_ret;
    initial seed_ret = $urandom(20250815);

    int wr_rate = 70;   // percent of cycles winc is asserted
    int rd_rate = 40;

    // -----------------------------------------------------------------
    // write side: stimulus and push into the reference model
    // -----------------------------------------------------------------
    always @(posedge wclk) begin
        if (!wrst_n) begin
            winc  <= 1'b0;
            wdata <= '0;
        end else begin
            // advance the data only once the previous word was actually taken
            if (winc && !wfull) wdata <= wdata + 1'b1;
            winc <= stim_on && ($urandom_range(0, 99) < wr_rate);
        end
    end

    always @(posedge wclk) begin
        if (wrst_n && winc && !wfull) begin
            ref_mem[wr_idx] = wdata;
            wr_idx    = wr_idx + 1;
            n_written = n_written + 1;

            if (wrote_last_cycle) cov_b2b_write = cov_b2b_write + 1;
            wrote_last_cycle = 1'b1;
        end else if (wrst_n) begin
            wrote_last_cycle = 1'b0;
        end

        if (wrst_n && wfull)                    cov_full       = cov_full + 1;
        if (wrst_n && winc && !wfull && rinc && !rempty)
                                                cov_concurrent = cov_concurrent + 1;
    end

    // -----------------------------------------------------------------
    // overflow check, straight off the DUT's own pointers
    //
    // Counting testbench-side writes and reads instead would mean comparing
    // two numbers maintained on two different clocks, which goes wrong by one
    // whenever the edges happen to coincide. wbin - rbin is the real
    // occupancy and it is unambiguous. Sampled just off the edge so both
    // domains have settled.
    // -----------------------------------------------------------------
    logic [ASIZE:0] occ;

    always @(posedge wclk) begin
        #0.1;
        if (wrst_n && rrst_n) begin
            occ = dut.wbin - dut.rbin;
            if (occ > DEPTH[ASIZE:0]) begin
                n_overflow = n_overflow + 1;
                if (n_overflow <= 10)
                    $display("[%0t] OVERFLOW: occupancy %0d, depth is %0d",
                             $time, occ, DEPTH);
            end
        end
    end

    // -----------------------------------------------------------------
    // read side: pop and compare
    // -----------------------------------------------------------------
    always @(posedge rclk) begin
        if (!rrst_n) begin
            rinc <= 1'b0;
        end else begin
            rinc <= drain_on || (stim_on && ($urandom_range(0, 99) < rd_rate));
        end
    end

    always @(posedge rclk) begin
        if (rrst_n && rinc && !rempty) begin
            if (rd_idx >= wr_idx) begin
                n_underflow = n_underflow + 1;
                if (n_underflow <= 10)
                    $display("[%0t] UNDERFLOW: read accepted with nothing written",
                             $time);
            end else if (rdata !== ref_mem[rd_idx]) begin
                n_data_err = n_data_err + 1;
                if (n_data_err <= 10)
                    $display("[%0t] MISMATCH at word %0d: got 0x%02h, expected 0x%02h",
                             $time, rd_idx, rdata, ref_mem[rd_idx]);
            end
            rd_idx = rd_idx + 1;
            n_read = n_read + 1;
        end

        if (rrst_n && rempty) cov_empty = cov_empty + 1;
    end

    // -----------------------------------------------------------------
    // phase control
    // -----------------------------------------------------------------
    task automatic do_reset();
        stim_on  = 1'b0;
        drain_on = 1'b0;
        wrst_n   = 1'b0;
        rrst_n   = 1'b0;
        repeat (5) @(posedge wclk);
        repeat (5) @(posedge rclk);
        wr_idx    = 0;
        rd_idx    = 0;
        n_written = 0;
        n_read    = 0;
        @(posedge wclk);
        wrst_n = 1'b1;
        @(posedge rclk);
        rrst_n = 1'b1;
        repeat (5) @(posedge wclk);
    endtask

    // Stop writing, then read until the FIFO is empty, so every word that went
    // in gets compared on the way out instead of being abandoned mid-phase.
    task automatic drain(input string name);
        stim_on  = 1'b0;
        repeat (20) @(posedge wclk);
        drain_on = 1'b1;
        for (int i = 0; i < 1000 && n_read < n_written; i++) @(posedge rclk);
        repeat (10) @(posedge rclk);
        drain_on = 1'b0;

        if (n_read != n_written) begin
            n_residual_err = n_residual_err + 1;
            $display(" %s: FIFO did not drain -- %0d written, %0d read",
                     name, n_written, n_read);
        end else begin
            $display("   %s: %0d words written, all %0d read back and checked",
                     name, n_written, n_read);
        end

        tot_written = tot_written + n_written;
        tot_read    = tot_read    + n_read;
    endtask

    initial begin
        $display("=========================================================");
        $display(" async FIFO  --  DSIZE=%0d  ASIZE=%0d  depth=%0d",
                 DSIZE, ASIZE, DEPTH);
        $display("=========================================================");

        // ---------------- phase 1: fast write, slow read -------------
        whalf   = 3.5;   // 7 ns
        rhalf   = 5.5;   // 11 ns
        wr_rate = 70;
        rd_rate = 40;
        do_reset();

        $display("\n-- phase 1: wclk 7 ns, rclk 11 ns  (write fast, read slow)");
        stim_on = 1'b1;
        wait (n_read >= TXN_PER_PHASE);
        drain("phase 1");

        // ---------------- phase 2: slow write, fast read -------------
        whalf   = 5.5;   // 11 ns
        rhalf   = 3.5;   // 7 ns
        wr_rate = 40;
        rd_rate = 70;
        do_reset();

        $display("\n-- phase 2: wclk 11 ns, rclk 7 ns  (write slow, read fast)");
        stim_on = 1'b1;
        wait (n_read >= TXN_PER_PHASE);
        drain("phase 2");

        report();
        $finish;
    end

    task automatic report();
        int fails;
        fails = n_data_err + n_overflow + n_underflow + n_residual_err;

        $display("\n=========================================================");
        $display(" RESULTS");
        $display("=========================================================");
        $display("  words written              : %0d", tot_written);
        $display("  words read and compared    : %0d", tot_read);
        $display("  data mismatches            : %0d", n_data_err);
        $display("  overflows                  : %0d", n_overflow);
        $display("  underflows                 : %0d", n_underflow);
        $display("  undrained words            : %0d", n_residual_err);
        $display("  ---- coverage ----");
        $display("  cycles with wfull high     : %0d", cov_full);
        $display("  cycles with rempty high    : %0d", cov_empty);
        $display("  back-to-back writes        : %0d", cov_b2b_write);
        $display("  concurrent read and write  : %0d", cov_concurrent);
        $display("---------------------------------------------------------");

        if (cov_full == 0 || cov_empty == 0 ||
            cov_b2b_write == 0 || cov_concurrent == 0) begin
            $display(" INCONCLUSIVE: a coverage point was never reached, so the");
            $display(" stimulus is not exercising the design properly.");
        end else if (fails == 0) begin
            $display(" TEST PASSED");
        end else begin
            $display(" TEST FAILED: %0d error(s)", fails);
        end
        $display("=========================================================");
    endtask

    // watchdog
    initial begin
        #500_000;
        $display("\nTIMEOUT: simulation did not finish");
        $display(" written=%0d read=%0d", n_written, n_read);
        $finish;
    end

endmodule
