// Two flip-flop synchroniser.
//
// The first flop is the one allowed to go metastable. It gets a full clock
// period to settle before the second flop samples it, so what leaves q is
// either the old value or the new one and never something in between.
//
// This only buys you anything if the input is a signal where a stale sample is
// harmless. Multi-bit buses have to be Gray coded before they get here --
// synchronising a binary counter this way is still broken.

module sync_2ff #(
    parameter int WIDTH = 1
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic [WIDTH-1:0] d,
    output logic [WIDTH-1:0] q
);

    // ASYNC_REG keeps the pair placed together and stops the tools from
    // retiming anything into the middle of them.
    (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] q1;
    (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] q2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q1 <= '0;
            q2 <= '0;
        end else begin
            q1 <= d;
            q2 <= q1;
        end
    end

    assign q = q2;

endmodule
