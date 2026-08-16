// Two flip-flop synchroniser.
//
// The first flop is the one allowed to go metastable. It gets a full clock
// period to settle before the second flop samples it, so what leaves q is
// either the old value or the new one and never something in between.
//
// This only buys you anything if the input is a signal where a stale sample is
// harmless. Multi-bit buses have to be Gray coded before they get here --
// synchronising a binary counter this way is still broken.
//
// Verilog-2001.

module sync_2ff #(
    parameter WIDTH = 1
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire [WIDTH-1:0] d,
    output wire [WIDTH-1:0] q
);

    // ASYNC_REG keeps the pair placed together and stops the tools from
    // retiming anything into the middle of them.
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] q1;
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] q2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q1 <= {WIDTH{1'b0}};
            q2 <= {WIDTH{1'b0}};
        end else begin
            q1 <= d;
            q2 <= q1;
        end
    end

    assign q = q2;

endmodule
