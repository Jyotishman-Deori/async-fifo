# Dual-Clock Asynchronous FIFO

A FIFO that moves data between two clock domains that have no relationship to each
other. Written in SystemVerilog, verified with a scoreboard, assertions and functional
coverage.

Self-project. Jyotishman Deori (25M1186), M.Tech Electronic Systems, IIT Bombay.

I picked this after working on the AXI-Stream interfaces in my M.Tech project, where
the PS and PL sides sit in different clock domains and I mostly got to rely on the
handshake. I wanted to build the crossing itself rather than use one.

**Status:** spec done, RTL in progress.

---

## The problem

If you sample a multi-bit counter in another clock domain, you can catch it
mid-transition. Different bits arrive from different sides of the flop, and you read a
value the counter never actually held. A binary counter going `0111 -> 1000` flips four
bits at once. Sample that at the wrong moment and you could get anything from `0000` to
`1111`.

Two separate things fix this and you need both:

Gray coding means consecutive values differ in exactly one bit, so a bad sample gives
you either the old value or the new one, never a third. Two-flop synchronisers give a
metastable first flop a full clock period to settle before anything downstream looks at
it.

They fix different problems. Gray code does nothing about metastability. Synchronisers
do nothing about multi-bit skew. Miss either one and the design is broken in a way that
simulation may not show you.

---

## How it works

```
   wdata --> +------------+
             |   memory   | --> rdata
             |  2**ASIZE  |
             +------------+
                ^        ^
             waddr     raddr      (low ASIZE bits of each binary pointer)

   wbin --> wgray -----[2FF sync into rclk]-----> rq2_wptr --> rempty
   rbin --> rgray -----[2FF sync into wclk]-----> wq2_rptr --> wfull
```

Each pointer crosses once, in one direction. The binary counters never cross — only
their Gray versions do.

```systemverilog
module async_fifo #(
    parameter int DSIZE = 8,
    parameter int ASIZE = 4     // depth = 2**ASIZE
) (
    input  logic              wclk, wrst_n, winc,
    input  logic [DSIZE-1:0]  wdata,
    output logic              wfull,

    input  logic              rclk, rrst_n, rinc,
    output logic [DSIZE-1:0]  rdata,
    output logic              rempty
);
```

Two files: `rtl/sync_2ff.sv` for the synchroniser, `rtl/async_fifo.sv` for everything
else. The synchroniser is its own module mostly so it's obvious I didn't forget it.

---

## The bits that are easy to get wrong

**Pointers are one bit wider than the address.** With ASIZE address bits I use ASIZE+1
bit pointers. That extra bit is the only thing telling full apart from empty, because
in both cases the pointers are otherwise equal.

**Binary to Gray** is just `gray = bin ^ (bin >> 1)`.

**Empty** is when the read pointer has caught up — every bit equal:

```systemverilog
rempty = (rgraynext == rq2_wptr);
```

**Full** is when the write pointer has wrapped all the way around and caught the read
pointer. Same low bits, but the top *two* bits inverted:

```systemverilog
wfull = (wgraynext == {~wq2_rptr[ASIZE], ~wq2_rptr[ASIZE-1], wq2_rptr[ASIZE-2:0]});
```

Two bits, not one. This is the part I'd expect to get wrong if I rushed it. In Gray code
both the MSB and the bit under it flip when the counter passes halfway, so comparing
with only the top bit inverted detects the wrong thing entirely.

Both flags come from the *next* pointer value rather than the registered one, so they
go high in the same cycle the FIFO actually fills or empties instead of one cycle late.

**One thing that looks like a bug and isn't.** Each side only ever sees a delayed copy
of the other pointer, so `wfull` can stay high for a moment after a read has already
freed space, and `rempty` can stay high just after a write. The FIFO reports itself
fuller or emptier than it really is. It never goes the other way, which is the only
direction that would actually break something — it cannot overflow or underflow.

---

## Verifying it

One directed test passing tells you almost nothing about a CDC design. What finds bugs
is stalling both sides at random and running the clocks at a ratio you didn't design
for.

What has to pass before I'd call this done:

- Scoreboard reports zero mismatches and data comes out in FIFO order
- Works both ways round: fast write / slow read, and slow write / fast read
- Random stalls on both interfaces, not a clean stream
- Assertions never fire: no write when full, no read when empty
- Coverage hits full, empty, simultaneous read and write, and back-to-back writes
- Synthesis infers zero latches

For the testbench I'm using 7 ns and 11 ns clocks. Related periods like 10 and 20 hide
CDC bugs by accidentally lining edges up, which defeats the point. A reference queue
gets pushed on the write side and popped and compared on the read side, with `winc` and
`rinc` randomised so full and empty actually get reached rather than just being
theoretically possible.

---

## Running it

```bash
# ModelSim (not on PATH by default)
export PATH="/c/intelFPGA_lite/20.1/modelsim_ase/win32aloem:$PATH"
cd sim && vsim -c -do run.do

# Latch and CDC check (Vivado, not on PATH by default)
export PATH="/c/Xilinx/Vivado/2020.2/bin:$PATH"
vivado -mode batch -source synth/synth_check.tcl
```

ModelSim ASE can't do SVA or covergroups, so assertions and functional coverage run in
Vivado XSim — same split I use in my M.Tech project.

---

## Results

Measured numbers go here once it runs. Nothing goes in this table that I haven't
actually seen in a transcript.

| | |
|---|---|
| Clocks tested | _TBD_ |
| Transactions passed | _TBD_ |
| Assertion failures | _TBD_ |
| Coverage bins hit | _TBD_ |
| Latches inferred | _TBD_ |

---

## Questions I should be able to answer

If I can't answer one of these, that part of the design isn't finished yet.

1. Why Gray code across the boundary instead of binary?
2. What does a two-flop synchroniser fix, and what does it not fix?
3. Why is the pointer one bit wider than the address?
4. Why invert two bits for full and none for empty?
5. Why use the next pointer value for the flags instead of the registered one?
6. What is MTBF here, and when would a third flop be worth it?
7. Can this FIFO overflow? Show why not.
8. What breaks if the depth isn't a power of two?
