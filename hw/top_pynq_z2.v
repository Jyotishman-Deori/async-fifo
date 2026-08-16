// Top level for the PYNQ-Z2 hardware test.
//
// The Zynq PS is here for one reason only: FCLK_CLK0 comes off the PS PLL,
// which is fed by the board's 33.333 MHz crystal, while sys_clk comes off a
// separate 125 MHz oscillator. Two crystals, no common reference, so the phase
// between them drifts instead of repeating. Deriving the second clock from an
// MMCM off sys_clk would have been far less work and would also have been a
// much weaker test: the two clocks would be phase locked, sampling would
// happen at the same handful of relative phases forever, and the synchroniser
// might never once be caught in its setup/hold window.
//
// LEDs, left to right:
//   0  heartbeat, so you can see the read clock is alive
//   1  test running
//   2  ERROR: at least one word came back wrong
//   3  both full and empty were reached, so the run actually stressed it
//
// A run with LED3 on and LED2 off is a pass. LED3 off means the rates were
// wrong and the run proved little, whatever LED2 says.

module top_pynq_z2 (
    input  wire        sys_clk,    // H16, 125 MHz board oscillator
    output wire [3:0]  led,

    // Dedicated PS pins. Nothing here is used by the test; the PS7 hard block
    // will not build without them brought out, and they need no constraints
    // because the pin assignment is fixed in silicon.
    inout  wire [14:0] DDR_addr,
    inout  wire [2:0]  DDR_ba,
    inout  wire        DDR_cas_n,
    inout  wire        DDR_ck_n,
    inout  wire        DDR_ck_p,
    inout  wire        DDR_cke,
    inout  wire        DDR_cs_n,
    inout  wire [3:0]  DDR_dm,
    inout  wire [31:0] DDR_dq,
    inout  wire [3:0]  DDR_dqs_n,
    inout  wire [3:0]  DDR_dqs_p,
    inout  wire        DDR_odt,
    inout  wire        DDR_ras_n,
    inout  wire        DDR_reset_n,
    inout  wire        DDR_we_n,
    inout  wire        FIXED_IO_ddr_vrn,
    inout  wire        FIXED_IO_ddr_vrp,
    inout  wire [53:0] FIXED_IO_mio,
    inout  wire        FIXED_IO_ps_clk,
    inout  wire        FIXED_IO_ps_porb,
    inout  wire        FIXED_IO_ps_srstb
);

    // -----------------------------------------------------------------
    // clocks and reset
    // -----------------------------------------------------------------
    wire wclk;                     // FCLK_CLK0, off the PS PLL
    wire fclk_rst_n;
    wire rclk = sys_clk;

    ps_wrapper u_ps (
        .FCLK_CLK0          (wclk),
        .FCLK_RESET0_N      (fclk_rst_n),
        .DDR_addr           (DDR_addr),
        .DDR_ba             (DDR_ba),
        .DDR_cas_n          (DDR_cas_n),
        .DDR_ck_n           (DDR_ck_n),
        .DDR_ck_p           (DDR_ck_p),
        .DDR_cke            (DDR_cke),
        .DDR_cs_n           (DDR_cs_n),
        .DDR_dm             (DDR_dm),
        .DDR_dq             (DDR_dq),
        .DDR_dqs_n          (DDR_dqs_n),
        .DDR_dqs_p          (DDR_dqs_p),
        .DDR_odt            (DDR_odt),
        .DDR_ras_n          (DDR_ras_n),
        .DDR_reset_n        (DDR_reset_n),
        .DDR_we_n           (DDR_we_n),
        .FIXED_IO_ddr_vrn   (FIXED_IO_ddr_vrn),
        .FIXED_IO_ddr_vrp   (FIXED_IO_ddr_vrp),
        .FIXED_IO_mio       (FIXED_IO_mio),
        .FIXED_IO_ps_clk    (FIXED_IO_ps_clk),
        .FIXED_IO_ps_porb   (FIXED_IO_ps_porb),
        .FIXED_IO_ps_srstb  (FIXED_IO_ps_srstb)
    );

    wire vio_run, vio_rst;
    wire [3:0] vio_w_rate, vio_r_rate;

    // Reset is built in three stages, and the shape of it is deliberate.
    //
    // My first version was one line: arst_n = fclk_rst_n && !vio_rst, feeding
    // both synchronisers. Vivado flagged it CDC-10, combinational logic
    // before a synchroniser, and it was right. That AND gate sat directly on
    // the clear pin of a synchroniser flop, so a glitch on it would have
    // reset one clock domain and not the other and left the FIFO's two
    // pointers disagreeing about where the data starts. Exactly the failure
    // this whole project exists to avoid, in the harness meant to prove it
    // doesn't happen.
    //
    // Now the only asynchronous reset is fclk_rst_n, a single source with no
    // logic in front of it, and the soft reset is combined afterwards and
    // registered before it goes anywhere.

    // stage 1: the PS reset into each domain, async assert, sync deassert
    reg [1:0] w_por, r_por;

    always @(posedge wclk or negedge fclk_rst_n) begin
        if (!fclk_rst_n) w_por <= 2'b00;
        else             w_por <= {w_por[0], 1'b1};
    end

    always @(posedge rclk or negedge fclk_rst_n) begin
        if (!fclk_rst_n) r_por <= 2'b00;
        else             r_por <= {r_por[0], 1'b1};
    end

    // stage 2: the VIO soft reset, crossing into the write domain like any
    // other control bit. The VIO already runs on rclk, so that side is direct.
    wire vio_rst_w;
    sync_2ff #(.WIDTH(1)) sync_softrst (
        .clk (wclk), .rst_n (w_por[1]), .d (vio_rst), .q (vio_rst_w)
    );

    // stage 3: one registered reset per domain, so what reaches the FIFO is a
    // flop output rather than a gate
    reg wrst_n_q, rrst_n_q;

    always @(posedge wclk or negedge fclk_rst_n) begin
        if (!fclk_rst_n) wrst_n_q <= 1'b0;
        else             wrst_n_q <= w_por[1] && !vio_rst_w;
    end

    always @(posedge rclk or negedge fclk_rst_n) begin
        if (!fclk_rst_n) rrst_n_q <= 1'b0;
        else             rrst_n_q <= r_por[1] && !vio_rst;
    end

    wire wrst_n = wrst_n_q;
    wire rrst_n = rrst_n_q;

    // -----------------------------------------------------------------
    // control, crossing from the VIO's clock (rclk) into the write domain
    //
    // Reusing the design's own synchroniser rather than writing another one.
    // The rate values are multi-bit and not Gray coded, which is only safe
    // because they are held static while run is low and are never changed
    // during a run.
    // -----------------------------------------------------------------
    wire run_w;
    wire [3:0] w_rate_w;

    sync_2ff #(.WIDTH(1)) sync_run (
        .clk (wclk), .rst_n (wrst_n), .d (vio_run), .q (run_w)
    );

    sync_2ff #(.WIDTH(4)) sync_wrate (
        .clk (wclk), .rst_n (wrst_n), .d (vio_w_rate), .q (w_rate_w)
    );

    // -----------------------------------------------------------------
    // the test
    // -----------------------------------------------------------------
    wire [31:0] words_written, words_read, errors;
    wire        full_seen, empty_seen;

    fifo_hw_test #(
        .DSIZE (8),
        .ASIZE (4)
    ) u_test (
        .wclk          (wclk),
        .wrst_n        (wrst_n),
        .rclk          (rclk),
        .rrst_n        (rrst_n),
        .run_w         (run_w),
        .run_r         (vio_run),
        .w_rate        (w_rate_w),
        .r_rate        (vio_r_rate),
        .words_written (words_written),
        .words_read    (words_read),
        .errors        (errors),
        .full_seen     (full_seen),
        .empty_seen    (empty_seen)
    );

    // full_seen is set in the write domain and only read here for the LED and
    // the VIO, both of which are on rclk. It is a sticky bit that goes high
    // once and stays there, so two flops are all it needs.
    wire full_seen_r;
    sync_2ff #(.WIDTH(1)) sync_full (
        .clk (rclk), .rst_n (rrst_n), .d (full_seen), .q (full_seen_r)
    );

    // -----------------------------------------------------------------
    // readback
    //
    // words_written is counted on wclk and sampled here on rclk. That is only
    // safe because the counters are read after run has gone low and both
    // sides have stopped, so the value is static by the time anything looks
    // at it. Sampling a live counter across a clock boundary would be the
    // exact mistake this project is about.
    // -----------------------------------------------------------------
    vio_0 u_vio (
        .clk        (rclk),
        .probe_in0  (words_written),
        .probe_in1  (words_read),
        .probe_in2  (errors),
        .probe_in3  ({full_seen_r, empty_seen}),
        .probe_out0 (vio_run),
        .probe_out1 (vio_rst),
        .probe_out2 (vio_w_rate),
        .probe_out3 (vio_r_rate)
    );

    // -----------------------------------------------------------------
    // LEDs
    // -----------------------------------------------------------------
    reg [25:0] heartbeat;
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) heartbeat <= 26'd0;
        else         heartbeat <= heartbeat + 26'd1;
    end

    assign led[0] = heartbeat[25];
    assign led[1] = vio_run;
    assign led[2] = (errors != 32'd0);
    assign led[3] = full_seen_r && empty_seen;

endmodule
