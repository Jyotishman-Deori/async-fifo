# Dual-Clock Asynchronous FIFO

A FIFO that moves data between two clock domains that have no relationship to each
other. Everything is Verilog-2001: the design, the testbench and the hardware test
harness. Checked with a randomised scoreboard, procedural protocol checks and coverage
counters.

Self-project. Jyotishman Deori (25M1186), M.Tech. Electrical Engineering
(Electronic Systems), IIT Bombay.

I picked this after working on the AXI-Stream interfaces in my M.Tech project, where
the PS and PL sides sit in different clock domains and I mostly got to rely on the
handshake. I wanted to build the crossing itself rather than use one.

**Status:** done, and running on hardware. RTL, testbench and synthesis all clean, plus
286 million words through the real thing on a PYNQ-Z2 with zero errors.
Numbers are in [Results](#results), raw transcripts in [`results/`](results/).

There is a written-up version of all of this as a report:
[`docs/Async_FIFO_Report.pdf`](docs/Async_FIFO_Report.pdf).

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
coding to see what would break, and the entire testbench still passed. That got its own
writeup in [`experiments/`](experiments/README.md).

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

Each pointer crosses once, in one direction. The binary counters never cross. Only
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

Everything compiles without `-sv`, including the testbench. Verilog has no assertions
and no covergroups, so the checks are procedural and the coverage points are counted by
hand; the testbench reports them and refuses to call a run a pass if any of them was
never reached.

```
rtl/           the design, and the only thing that gets synthesised
tb/            scoreboard testbench, procedural checks, coverage counters
sim/           ModelSim and XSim run scripts
synth/         Vivado latch and CDC check
hw/            the PYNQ-Z2 build: same FIFO, real clocks, real silicon
experiments/   deliberately broken variants, kept for what they showed
results/       raw transcripts of every run quoted below
docs/          the report, and the source it is built from
```

---

## The bits that are easy to get wrong

**Pointers are one bit wider than the address.** With ASIZE address bits I use ASIZE+1
bit pointers. That extra bit is the only thing telling full apart from empty, because
in both cases the pointers are otherwise equal.

**Binary to Gray** is just `gray = bin ^ (bin >> 1)`.

**Empty** is when the read pointer has caught up, so every bit is equal:

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
direction that would actually break something. It cannot overflow or underflow.

---

## Verifying it

One directed test passing tells you almost nothing about a CDC design. What finds bugs
is stalling both sides at random and running the clocks at a ratio you didn't design
for.

What has to pass before I'd call this done:

- Scoreboard reports zero mismatches and data comes out in FIFO order
- Works both ways round: fast write / slow read, and slow write / fast read
- Random stalls on both interfaces, not a clean stream
- Protocol checks never fire: no overflow, no underflow, no undrained words
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
| Gray coding removed, binary pointers across the boundary | **nothing, it passed** |

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

# the same testbench under a second simulator, Vivado XSim
cd sim && ./run_xsim.sh

# latch and CDC check
export PATH="/c/Xilinx/Vivado/2020.2/bin:$PATH"
vivado -mode batch -source synth/synth_check.tcl

# the CDC encoding experiment (not the design)
cd sim && vsim -c -do run_experiment.do

# hardware: build the bitstream, start the PS clocks and load it, then run
vivado -mode batch -source hw/build.tcl
xsdb hw/program.tcl
vivado -mode batch -source hw/run_hw_test.tcl

# rebuild the report from docs/report.html
python docs/make_pdf.py
```

The same testbench runs under both ModelSim and XSim. That is the point of running it
twice: a design that passes on one simulator and fails on another usually has a race
that the first tool happened to resolve in its favour. Both report the same counts.

---

## Results

Every number below came out of a transcript in [`results/`](results/). Nothing here is
estimated or rounded up.

The functional testbench on ModelSim ASE 20.1 put 10,017 words through, both clock
ratios, and compared every one of them on the way out:

| | |
|---|---|
| Data mismatches | 0 |
| Overflows / underflows | 0 / 0 |
| Words left unchecked | 0 |
| Cycles spent full / empty | 12,579 / 12,611 |
| Back-to-back writes | 2,991 |
| Concurrent read and write | 3,630 |

The same testbench under XSim reports exactly the same 10,017 words and the same zero
mismatches, with the coverage counters landing within a few counts of the ModelSim run.
Both transcripts are in `results/`.

Synthesis for `xc7z020clg400-1`, out of context: 0 errors, 0 warnings, **0 latches**,
28 slice LUTs (20 logic, 8 as distributed RAM) and 40 flip-flops. The 16x8 memory went
to distributed RAM rather than a block RAM, which is what I expected at this size. A
BRAM would have sat almost entirely empty.

Vivado's CDC report finds both crossings, at depth 2, with the ASYNC_REG property and
the asynchronous clock group exception applied:

```
CDC-3  Info      2   1-bit synchronized with ASYNC_REG property
CDC-6  Warning   2   Multi-bit synchronized with ASYNC_REG property
```

The CDC-6 warnings are correct and I'd be more worried if they were missing. Vivado can
see a multi-bit bus going into a two-flop synchroniser, which is usually a real bug, and
nothing tells it this particular bus is Gray coded.

One detail I hadn't predicted: the report sources the top pointer bit from `wbin_reg[4]`
rather than `wgray_reg[4]`. The MSB of a Gray code is the same as the MSB of the binary
it came from, so `bin ^ (bin >> 1)` leaves that bit alone and synthesis dropped the
duplicate register.

### On hardware

The same FIFO on a PYNQ-Z2, with `wclk` on the PS PLL and `rclk` on the board's 125 MHz
oscillator. Two separate crystals, so the phase between them drifts instead of repeating
and the sampling point sweeps through everything over a run:

| | |
|---|---|
| Words written and checked | **286,176,459** |
| Data errors | **0** |
| Reached full / empty | yes / yes |
| Timing | WNS 1.997 ns, WHS 0.061 ns |

Roughly 28,000 times more words than the simulation, on real routing, in twenty seconds.

Phase 1 finishes 16 words short of what it wrote, and that number is the FIFO depth. It
stops with the writer running flat out against a slow reader, so the FIFO is full at the
instant writes stop and is still holding a full 16 words. Phase 2 inverts the rates, the
reader drains them, and the totals come out exactly equal.

Full writeup, including the CDC-10 I put in my own reset logic and had to fix, is in
[`hw/`](hw/README.md).
