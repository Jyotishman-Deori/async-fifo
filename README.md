# Dual-Clock Asynchronous FIFO

A FIFO that moves data between two clock domains that have no relationship to each
other. RTL in Verilog-2001, verified with a SystemVerilog testbench — scoreboard,
assertions and functional coverage.

Self-project. Jyotishman Deori (25M1186), M.Tech Electronic Systems, IIT Bombay.

I picked this after working on the AXI-Stream interfaces in my M.Tech project, where
the PS and PL sides sit in different clock domains and I mostly got to rely on the
handshake. I wanted to build the crossing itself rather than use one.

**Status:** done. RTL, testbench, assertions and synthesis all run clean —
numbers in [Results](#results), raw transcripts in [`results/`](results/).

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

That last sentence turned out to be more literal than I meant it. I removed the Gray
coding to see what would break, and the entire testbench still passed — see
[`experiments/`](experiments/README.md).

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

```verilog
module async_fifo #(
    parameter DSIZE = 8,
    parameter ASIZE = 4               // depth = 2**ASIZE
) (
    input  wire             wclk, wrst_n, winc,
    input  wire [DSIZE-1:0] wdata,
    output reg              wfull,

    input  wire             rclk, rrst_n, rinc,
    output wire [DSIZE-1:0] rdata,
    output reg              rempty
);
```

Two files: `rtl/sync_2ff.v` for the synchroniser, `rtl/async_fifo.v` for everything
else. The synchroniser is its own module mostly so it's obvious I didn't forget it.

The design is Verilog-2001 and compiles without `-sv`. The testbench and the bound
checker are SystemVerilog, because a scoreboard and covergroups in plain Verilog would
be an exercise in stubbornness. Keeping the split at the RTL boundary also means the
synthesisable half stays portable to tools that only take Verilog.

```
rtl/           the design, and the only thing that gets synthesised
tb/            testbench, plus the bound SVA and covergroup checker
sim/           ModelSim and XSim run scripts
synth/         Vivado latch and CDC check
experiments/   deliberately broken variants, kept for what they showed
results/       raw transcripts of every run quoted below
```

---

## The bits that are easy to get wrong

**Pointers are one bit wider than the address.** With ASIZE address bits I use ASIZE+1
bit pointers. That extra bit is the only thing telling full apart from empty, because
in both cases the pointers are otherwise equal.

**Binary to Gray** is just `gray = bin ^ (bin >> 1)`.

**Empty** is when the read pointer has caught up — every bit equal:

```verilog
rempty = (rgraynext == rq2_wptr);
```

**Full** is when the write pointer has wrapped all the way around and caught the read
pointer. Same low bits, but the top *two* bits inverted:

```verilog
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

Each phase ends by stopping the writes and reading until the FIFO is empty, so every
word that went in is compared on the way out. Without that, a few hundred words are
still sitting in the FIFO when the phase ends and never get checked.

**A passing test proves nothing until you've seen it fail.** Before quoting any of the
numbers below I broke the design on purpose and re-ran everything:

| deliberate bug | what caught it |
|---|---|
| full compares with only the MSB inverted | occupancy check and scoreboard, within 500 ns |
| same bug, under XSim | `a_no_overflow` fired: *occupancy 17 exceeds depth 16* |
| Gray coding removed, binary pointers across the boundary | **nothing — it passed** |

That last row is the interesting one and it has its own writeup in
[`experiments/`](experiments/README.md). Short version: in RTL simulation every bit of
a bus changes at the same instant, so the hazard Gray coding prevents does not exist to
be found. I had to inject per-bit skew by hand before the difference showed up at all,
and once it did, binary failed catastrophically while Gray never dropped a word.

---

## Running it

```bash
# functional testbench, ModelSim (not on PATH by default)
export PATH="/c/intelFPGA_lite/20.1/modelsim_ase/win32aloem:$PATH"
cd sim && vsim -c -do run.do

# same testbench plus assertions and functional coverage, Vivado XSim
cd sim && ./run_xsim.sh

# latch and CDC check
export PATH="/c/Xilinx/Vivado/2020.2/bin:$PATH"
vivado -mode batch -source synth/synth_check.tcl

# the CDC encoding experiment (not the design)
cd sim && vsim -c -do run_experiment.do
```

ModelSim ASE can't do SVA or covergroups, so assertions and functional coverage run in
Vivado XSim — same split I use in my M.Tech project. The checker lives in
`tb/async_fifo_sva.sv` and is `bind`-ed onto the DUT rather than written inside it, so
nothing verification-only ends up in the synthesisable RTL.

---

## Results

Nothing in this table that I haven't actually seen in a transcript. Raw output for
every row is in [`results/`](results/).

**Functional testbench** — ModelSim ASE 20.1, `results/modelsim_tb.txt`

| | |
|---|---|
| Clock ratios tested | 7/11 ns and 11/7 ns, both directions |
| Words written and compared | 10 017 |
| Data mismatches | 0 |
| Overflows / underflows | 0 / 0 |
| Words left unchecked at end of phase | 0 |
| Cycles at full / at empty | 12 678 / 12 419 |
| Back-to-back writes | 3 025 |
| Concurrent read and write | 3 546 |

**Assertions and coverage** — Vivado XSim 2020.2, `results/xsim_tb.txt`

| | |
|---|---|
| Words written and compared | 10 015 |
| Assertion failures | 0, across 9 properties |
| Write interface coverage | 100 % |
| Read interface coverage | 100 % |
| Occupancy coverage | 100 % (empty and full bins both hit) |
| Concurrent access coverage | 100 % |

**Synthesis** — Vivado 2020.2, `xc7z020clg400-1`, out of context, `results/synth_check.txt`

| | |
|---|---|
| Errors / warnings / critical warnings | 0 / 0 / 0 |
| Latches inferred | **0** |
| Slice LUTs | 28 (20 logic, 8 distributed RAM) |
| Slice registers | 40, all flip-flops |
| Block RAM / DSP | 0 / 0 |

The 16×8 memory landed in 8 LUTs as distributed RAM rather than a block RAM, which is
what I'd expect at this size — a BRAM would be almost entirely empty.

**What Vivado's CDC report says** — `synth/cdc_report.txt`

```
CDC-3  Info      2   1-bit synchronized with ASYNC_REG property
CDC-6  Warning   2   Multi-bit synchronized with ASYNC_REG property
```

Both crossings found, both at depth 2, both covered by the asynchronous clock group.
The CDC-6 warnings are expected and I'd be worried if they were missing: Vivado can see
a multi-bit bus going into a two-flop synchroniser, which is normally a real bug, but it
has no way to know the bus is Gray coded. Depth reading 2 on every row is the tool
confirming it found the synchroniser rather than a bare crossing.

One detail I didn't predict: the report sources the top pointer bit from `wbin_reg[4]`,
not `wgray_reg[4]`. The MSB of a Gray code equals the MSB of the binary it came from, so
`bin ^ (bin >> 1)` leaves that bit untouched and synthesis just dropped the redundant
register.

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
