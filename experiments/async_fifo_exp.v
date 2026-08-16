// EXPERIMENT ONLY -- NOT PART OF THE DESIGN.
//
// A deliberately modified copy of rtl/async_fifo.v with two knobs:
//
//   GRAY_CDC = 1  pointers cross Gray coded (what the real design does)
//   GRAY_CDC = 0  pointers cross as plain binary, with the matching binary
//                 full/empty tests so that the *encoding* is the only thing
//                 that changed and not the comparison logic
//
//   SKEW_NS > 0   each bit of the crossing bus is delayed by a different
//                 amount before it reaches the synchroniser, which is what
//                 real routing does and what plain RTL simulation does not
//
// Why this file exists: I removed the Gray coding from the real FIFO, ran the
// full testbench, and it passed. That bothered me. It passes because in RTL
// simulation every bit of a bus changes at exactly the same femtosecond, so
// there is no skew for Gray code to protect against. The protection only
// matters once the bits arrive at different times. Turning SKEW_NS up is how
// I made that visible without a gate-level netlist.
//
// Do not synthesise this. See experiments/README.md for the numbers.

module async_fifo_exp #(
    parameter      DSIZE    = 8,
    parameter      ASIZE    = 4,
    parameter      GRAY_CDC = 1,
    parameter real SKEW_NS  = 0.0    // per-bit step, see the pattern below
) (
    input  wire             wclk,
    input  wire             wrst_n,
    input  wire             winc,
    input  wire [DSIZE-1:0] wdata,
    output reg              wfull,

    input  wire             rclk,
    input  wire             rrst_n,
    input  wire             rinc,
    output wire [DSIZE-1:0] rdata,
    output reg              rempty
);

    localparam DEPTH = 1 << ASIZE;

    reg  [ASIZE:0] wbin, wgray;
    reg  [ASIZE:0] rbin, rgray;
    wire [ASIZE:0] wbin_next, wgray_next;
    wire [ASIZE:0] rbin_next, rgray_next;
    wire [ASIZE:0] wq2_rptr, rq2_wptr;
    wire           wfull_next, rempty_next;

    // what actually leaves each domain
    wire [ASIZE:0] wptr_out = GRAY_CDC ? wgray : wbin;
    wire [ASIZE:0] rptr_out = GRAY_CDC ? rgray : rbin;

    // ---------------------------------------------------------------------
    // skew injection
    //
    // Transport delay per bit, so a multi-bit change arrives spread out in
    // time instead of all at once. With Gray coding only one bit ever moves,
    // so this does nothing. With binary it is the whole problem.
    //
    // The delay pattern is deliberately not monotonic. My first attempt
    // delayed bit i by i*SKEW_NS, so the low bits always moved first and the
    // transient value was always *smaller* than both the old and new pointer.
    // That direction is harmless -- a pointer that reads low just makes the
    // other side think the FIFO is fuller (or emptier) than it is, which is
    // the pessimistic direction the design already tolerates. Binary passed.
    //
    // Real routing skew has no such ordering. (i*3+1)%4 gives 1,0,3,2,1
    // quarter-steps, which lets a high bit land before the low bits clear and
    // the pointer transiently read *high*. That is the direction that loses
    // data, because the far side thinks writes exist that do not.
    // ---------------------------------------------------------------------
    reg  [ASIZE:0] wptr_skewed_r, rptr_skewed_r;
    wire [ASIZE:0] wptr_skewed, rptr_skewed;

    genvar i;
    generate
        if (SKEW_NS == 0.0) begin : g_no_skew
            assign wptr_skewed = wptr_out;
            assign rptr_skewed = rptr_out;
        end else begin : g_skew
            for (i = 0; i <= ASIZE; i = i + 1) begin : g_bit
                localparam real DLY = SKEW_NS * ((i * 3 + 1) % 4);
                initial begin
                    wptr_skewed_r[i] = 1'b0;
                    rptr_skewed_r[i] = 1'b0;
                end
                always @(wptr_out[i]) wptr_skewed_r[i] <= #(DLY) wptr_out[i];
                always @(rptr_out[i]) rptr_skewed_r[i] <= #(DLY) rptr_out[i];
            end
            assign wptr_skewed = wptr_skewed_r;
            assign rptr_skewed = rptr_skewed_r;
        end
    endgenerate

    sync_2ff #(.WIDTH(ASIZE+1)) sync_r2w (
        .clk (wclk), .rst_n (wrst_n), .d (rptr_skewed), .q (wq2_rptr)
    );

    sync_2ff #(.WIDTH(ASIZE+1)) sync_w2r (
        .clk (rclk), .rst_n (rrst_n), .d (wptr_skewed), .q (rq2_wptr)
    );

    // How often a domain actually latched the far pointer while it was still
    // mid-transition. Without this number a clean run is ambiguous: it could
    // mean the encoding saved us, or it could mean we never once sampled at a
    // bad moment and the test proved nothing.
    integer n_caught_midflight;
    initial n_caught_midflight = 0;

    always @(posedge rclk) if (rrst_n && (wptr_skewed !== wptr_out))
        n_caught_midflight <= n_caught_midflight + 1;

    always @(posedge wclk) if (wrst_n && (rptr_skewed !== rptr_out))
        n_caught_midflight <= n_caught_midflight + 1;

    // ---------------------------------------------------------------------
    // storage
    // ---------------------------------------------------------------------
    reg [DSIZE-1:0] mem [0:DEPTH-1];

    always @(posedge wclk) begin
        if (winc && !wfull) mem[wbin[ASIZE-1:0]] <= wdata;
    end

    assign rdata = mem[rbin[ASIZE-1:0]];

    // ---------------------------------------------------------------------
    // write pointer and full
    // ---------------------------------------------------------------------
    assign wbin_next  = wbin + {{ASIZE{1'b0}}, (winc && !wfull)};
    assign wgray_next = wbin_next ^ (wbin_next >> 1);

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin  <= {(ASIZE+1){1'b0}};
            wgray <= {(ASIZE+1){1'b0}};
        end else begin
            wbin  <= wbin_next;
            wgray <= wgray_next;
        end
    end

    // Gray: low bits equal, top two inverted.
    // Binary: low bits equal, MSB inverted. Different test, same meaning.
    assign wfull_next = GRAY_CDC
        ? (wgray_next == {~wq2_rptr[ASIZE], ~wq2_rptr[ASIZE-1], wq2_rptr[ASIZE-2:0]})
        : (wbin_next  == {~wq2_rptr[ASIZE],  wq2_rptr[ASIZE-1:0]});

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) wfull <= 1'b0;
        else         wfull <= wfull_next;
    end

    // ---------------------------------------------------------------------
    // read pointer and empty
    // ---------------------------------------------------------------------
    assign rbin_next  = rbin + {{ASIZE{1'b0}}, (rinc && !rempty)};
    assign rgray_next = rbin_next ^ (rbin_next >> 1);

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin  <= {(ASIZE+1){1'b0}};
            rgray <= {(ASIZE+1){1'b0}};
        end else begin
            rbin  <= rbin_next;
            rgray <= rgray_next;
        end
    end

    assign rempty_next = GRAY_CDC ? (rgray_next == rq2_wptr)
                                  : (rbin_next  == rq2_wptr);

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) rempty <= 1'b1;
        else         rempty <= rempty_next;
    end

endmodule
