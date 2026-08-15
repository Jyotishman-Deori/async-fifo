// Assertions and functional coverage for async_fifo.
//
// Bound to the DUT rather than written inside it, so the synthesisable RTL
// stays free of verification code. ModelSim ASE supports neither SVA nor
// covergroups, so this file only ever runs under Vivado XSim -- see
// sim/run_xsim.sh. The ASE testbench checks the same behaviour procedurally.

module async_fifo_sva #(
    parameter int ASIZE = 4
) (
    input logic             wclk, wrst_n, winc, wfull,
    input logic             rclk, rrst_n, rinc, rempty,
    input logic [ASIZE:0]   wbin, rbin, wgray, rgray,
    input logic [ASIZE:0]   wq2_rptr, rq2_wptr
);

    localparam int DEPTH = 1 << ASIZE;

    default clocking @(posedge wclk); endclocking

    // -----------------------------------------------------------------
    // the Gray property itself
    //
    // This is the one that would have caught me if I had got the encoding
    // wrong: consecutive pointer values must differ in exactly one bit, or
    // the whole reason for crossing Gray instead of binary is gone.
    // -----------------------------------------------------------------
    // $past stays inside the property. XSim 2020.2 will not infer a clocking
    // event for it in the action block and errors out at elaboration.
    a_wgray_one_bit: assert property (
        @(posedge wclk) disable iff (!wrst_n)
        $countones(wgray ^ $past(wgray)) <= 1
    ) else $error("write Gray pointer changed more than one bit at once");

    a_rgray_one_bit: assert property (
        @(posedge rclk) disable iff (!rrst_n)
        $countones(rgray ^ $past(rgray)) <= 1
    ) else $error("read Gray pointer changed more than one bit at once");

    // -----------------------------------------------------------------
    // occupancy
    //
    // wbin - rbin in ASIZE+1 bit arithmetic is the true occupancy. If the
    // read pointer ever ran ahead of the write pointer the subtraction wraps
    // to something huge, so this single bound catches underflow as well as
    // overflow.
    //
    // Reaching across into the other clock domain is fine here because this
    // is a checker, not hardware.
    // -----------------------------------------------------------------
    a_no_overflow: assert property (
        @(posedge wclk) disable iff (!wrst_n || !rrst_n)
        (wbin - rbin) <= DEPTH[ASIZE:0]
    ) else $error("occupancy %0d exceeds depth %0d", wbin - rbin, DEPTH);

    // -----------------------------------------------------------------
    // the flags actually gate the pointers
    // -----------------------------------------------------------------
    a_no_write_when_full: assert property (
        @(posedge wclk) disable iff (!wrst_n)
        (wfull && winc) |=> (wbin == $past(wbin))
    ) else $error("write pointer moved while full");

    a_no_read_when_empty: assert property (
        @(posedge rclk) disable iff (!rrst_n)
        (rempty && rinc) |=> (rbin == $past(rbin))
    ) else $error("read pointer moved while empty");

    // pointers only ever stand still or step by one
    a_wptr_step: assert property (
        @(posedge wclk) disable iff (!wrst_n)
        (wbin - $past(wbin)) inside {0, 1}
    ) else $error("write pointer jumped");

    a_rptr_step: assert property (
        @(posedge rclk) disable iff (!rrst_n)
        (rbin - $past(rbin)) inside {0, 1}
    ) else $error("read pointer jumped");

    // -----------------------------------------------------------------
    // reset
    // -----------------------------------------------------------------
    a_reset_not_full: assert property (
        @(posedge wclk) !wrst_n |-> !wfull
    ) else $error("wfull high during reset");

    a_reset_empty: assert property (
        @(posedge rclk) !rrst_n |-> rempty
    ) else $error("rempty low during reset");

    // -----------------------------------------------------------------
    // functional coverage
    // -----------------------------------------------------------------
    logic wrote_d;
    always_ff @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) wrote_d <= 1'b0;
        else         wrote_d <= winc && !wfull;
    end

    covergroup cg_write @(posedge wclk);
        option.per_instance = 1;

        cp_full: coverpoint wfull iff (wrst_n) {
            bins not_full = {0};
            bins full     = {1};
        }
        cp_winc: coverpoint winc iff (wrst_n) {
            bins idle    = {0};
            bins request = {1};
        }
        // asking to write while full is the interesting corner: the request
        // has to be dropped, not queued
        x_write_when_full: cross cp_full, cp_winc;

        cp_b2b: coverpoint {winc && !wfull, wrote_d} iff (wrst_n) {
            bins back_to_back = {2'b11};
        }
    endgroup

    covergroup cg_read @(posedge rclk);
        option.per_instance = 1;

        cp_empty: coverpoint rempty iff (rrst_n) {
            bins not_empty = {0};
            bins empty     = {1};
        }
        cp_rinc: coverpoint rinc iff (rrst_n) {
            bins idle    = {0};
            bins request = {1};
        }
        x_read_when_empty: cross cp_empty, cp_rinc;
    endgroup

    // Occupancy is sampled on wclk. It is a cross-domain quantity so the exact
    // value is only meaningful as "did we ever get here", which is all
    // coverage is asking.
    covergroup cg_occupancy @(posedge wclk);
        option.per_instance = 1;

        cp_occ: coverpoint (wbin - rbin) iff (wrst_n && rrst_n) {
            bins empty     = {0};
            bins nearly_e  = {[1:2]};
            bins middle    = {[3:DEPTH-3]};
            bins nearly_f  = {[DEPTH-2:DEPTH-1]};
            bins full      = {DEPTH};
        }
    endgroup

    // simultaneous activity on both interfaces
    covergroup cg_concurrent @(posedge wclk);
        option.per_instance = 1;

        cp_both: coverpoint {winc && !wfull, rinc && !rempty} iff (wrst_n && rrst_n) {
            bins write_only = {2'b10};
            bins read_only  = {2'b01};
            bins both       = {2'b11};
        }
    endgroup

    cg_write      cgw  = new();
    cg_read       cgr  = new();
    cg_occupancy  cgo  = new();
    cg_concurrent cgc  = new();

    final begin
        $display("\n---- functional coverage (bound checker) ----");
        $display("  write interface  : %5.1f %%", cgw.get_inst_coverage());
        $display("  read interface   : %5.1f %%", cgr.get_inst_coverage());
        $display("  occupancy        : %5.1f %%", cgo.get_inst_coverage());
        $display("  concurrent access: %5.1f %%", cgc.get_inst_coverage());
        $display("---------------------------------------------");
    end

endmodule


bind async_fifo async_fifo_sva #(.ASIZE(ASIZE)) u_sva (
    .wclk     (wclk),
    .wrst_n   (wrst_n),
    .winc     (winc),
    .wfull    (wfull),
    .rclk     (rclk),
    .rrst_n   (rrst_n),
    .rinc     (rinc),
    .rempty   (rempty),
    .wbin     (wbin),
    .rbin     (rbin),
    .wgray    (wgray),
    .rgray    (rgray),
    .wq2_rptr (wq2_rptr),
    .rq2_wptr (rq2_wptr)
);
