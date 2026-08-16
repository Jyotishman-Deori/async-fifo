// Dual-clock asynchronous FIFO.
//
// wclk and rclk have no relationship to each other. Everything that crosses
// between them is Gray coded and passed through a two-flop synchroniser.
//
// Structure follows Cliff Cummings, "Simulation and Synthesis Techniques for
// Asynchronous FIFO Design" (SNUG 2002). The pointer comparison tricks below
// are his; the notes are mine, written while working out why they hold.
//
// Verilog-2001. The testbench and the bound assertion checker are
// SystemVerilog -- design in Verilog, verification in SystemVerilog.

module async_fifo #(
    parameter DSIZE = 8,
    parameter ASIZE = 4               // depth = 2**ASIZE
) (
    // write domain
    input  wire             wclk,
    input  wire             wrst_n,
    input  wire             winc,
    input  wire [DSIZE-1:0] wdata,
    output reg              wfull,

    // read domain
    input  wire             rclk,
    input  wire             rrst_n,
    input  wire             rinc,
    output wire [DSIZE-1:0] rdata,
    output reg              rempty
);

    localparam DEPTH = 1 << ASIZE;

    // Pointers are ASIZE+1 bits. The low ASIZE bits address the memory; the
    // extra top bit is a wrap flag and it is the only thing that tells full
    // apart from empty, since the addresses match in both cases.
    reg  [ASIZE:0] wbin, wgray;
    reg  [ASIZE:0] rbin, rgray;
    wire [ASIZE:0] wbin_next, wgray_next;
    wire [ASIZE:0] rbin_next, rgray_next;

    // each side's view of the other pointer, two clocks stale
    wire [ASIZE:0] wq2_rptr;   // read pointer, seen from the write domain
    wire [ASIZE:0] rq2_wptr;   // write pointer, seen from the read domain

    wire wfull_next, rempty_next;

    // ---------------------------------------------------------------------
    // storage
    //
    // No reset and no read enable: this is meant to infer block or
    // distributed RAM rather than a pile of flops. Reading is combinational,
    // so rdata is valid in the same cycle rempty is low.
    // ---------------------------------------------------------------------
    reg [DSIZE-1:0] mem [0:DEPTH-1];

    always @(posedge wclk) begin
        if (winc && !wfull) mem[wbin[ASIZE-1:0]] <= wdata;
    end

    assign rdata = mem[rbin[ASIZE-1:0]];

    // ---------------------------------------------------------------------
    // clock domain crossings
    //
    // Only the Gray pointers cross. The binary counters stay home.
    // ---------------------------------------------------------------------
    sync_2ff #(.WIDTH(ASIZE+1)) sync_r2w (
        .clk   (wclk),
        .rst_n (wrst_n),
        .d     (rgray),
        .q     (wq2_rptr)
    );

    sync_2ff #(.WIDTH(ASIZE+1)) sync_w2r (
        .clk   (rclk),
        .rst_n (rrst_n),
        .d     (wgray),
        .q     (rq2_wptr)
    );

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

    // Full means the write pointer has wrapped once more than the read
    // pointer and caught up to it. In Gray code both the MSB and the bit
    // below it flip when the counter passes halfway, so the test is: low bits
    // equal, top two bits inverted. Inverting only the MSB detects the
    // halfway point instead, which is not the same thing at all.
    assign wfull_next = (wgray_next ==
                         {~wq2_rptr[ASIZE], ~wq2_rptr[ASIZE-1], wq2_rptr[ASIZE-2:0]});

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

    // Empty is the easy one: the read pointer has caught the write pointer
    // with no wrap between them, so every bit matches.
    assign rempty_next = (rgray_next == rq2_wptr);

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) rempty <= 1'b1;   // empty out of reset
        else         rempty <= rempty_next;
    end

    // Both flags are computed from the *next* pointer, so they land on the
    // same edge that the pointer moves rather than a cycle behind it.
    //
    // Each side only ever sees a stale copy of the other pointer, so wfull can
    // stay high briefly after a read has freed space and rempty can stay high
    // briefly after a write. That is pessimistic, never optimistic, so it
    // cannot overflow or underflow.

endmodule
