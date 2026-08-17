# Does the Gray coding actually do anything?

Everything here is deliberately broken code kept for the result it produced.
None of it is part of the design. `experiments/async_fifo_exp.v` is a modified
copy of the real FIFO with two knobs: send the pointers across as Gray or as
plain binary, and delay each bit of the crossing bus by a different amount.

## Why I bothered

I wrote the FIFO, the testbench passed, and I could recite why Gray coding is
needed. Then I took the Gray coding out, swapping the crossing to raw binary
pointers and using the matching binary full/empty tests so the encoding was the
only thing that changed, and ran the same testbench again.

It passed. Zero mismatches, both clock ratios, full and empty both reached.

The single most quoted fact about asynchronous FIFOs is that binary pointers
across a clock boundary will corrupt your data, and my verification could not
tell the two designs apart.

## Why it passed

In RTL simulation every bit of a bus changes at the same instant. There is no
skew, so there is no window in which a sampler can catch half of an old value
and half of a new one. The entire hazard Gray coding exists to prevent is
invisible at this level of abstraction. A gate-level netlist with real delays
would show it; plain RTL never will.

So I injected the skew by hand. Each bit of the crossing bus gets its own
transport delay before it reaches the synchroniser, and `n_caught_midflight`
counts how many times a domain latched that bus while it was still settling, so
a clean run can be told apart from a run that simply never sampled at a bad
moment.

Two things had to be fixed before the experiment measured anything:

**The delay pattern must not be monotonic.** My first attempt delayed bit `i` by
`i * step`, so low bits always moved first and the transient value was always
*smaller* than both the old and the new pointer. That direction is harmless. A
pointer that reads low just makes the other side believe the FIFO is fuller, or
emptier, than it really is, which is the pessimistic direction the design
already tolerates by construction. Binary passed and told me nothing. The
pattern is now `step * ((i*3+1) % 4)`, which lets a high bit land before the
low bits have cleared, so the pointer can transiently read *high*, which is the
direction that loses data.

**The clocks must not be rationally related.** The main testbench uses 7 ns and
11 ns, which is fine for functional verification but wrong here: 7 and 11 are
integers, so a read edge only ever falls at a whole number of nanoseconds after
a write edge. Eleven fixed sampling phases, stepping over most of the
sub-nanosecond windows I was trying to hit. Changing the read clock to 11.3 ns
lets the phase drift through everything, which is what two real oscillators do.

## Result

4000 transactions per case, wclk 7.0 ns, rclk 11.3 ns. Skew is the per-bit step;
worst-case spread across the bus is 3x that.

| skew (ns) | Gray midflight | Gray errors | binary midflight | binary errors |
|---|---|---|---|---|
| 0.0 | 0 | 0 | 0 | 0 |
| 0.4 | 427 | 0 | 637 | 0 |
| 1.0 | 899 | 0 | 1401 | 0 |
| 2.0 | 1816 | 0 | 2525 | 0 |
| 3.5 | 3270 | **0** | 5691 | **3664** |

Gray is flat at zero the whole way. At the last row it was caught mid-transition
3270 times and still did not drop or corrupt a single word, because only one bit
ever moves. Catch it early or late and you get the old value or the new one, and
both are safe.

Binary needs more explaining, because it survives the first three rows despite
being caught mid-transition thousands of times.

## What the numbers do and do not show

Binary survives the first three rows despite thousands of mid-transition
captures, and only fails in the last, where the spread across the bus is
10.5 ns against a 7 ns write clock and a corrupted value can survive across
consecutive sampling edges rather than a single one.

That threshold is the important caveat. A 10.5 ns spread is far larger than
routing skew on a real design, so the honest reading is narrow: this shows the
failure mechanism is real and that Gray coding is immune to it. It does not
show that binary pointers would fail in a typical implementation, and the
zeroes in the first three rows are evidence against that stronger claim rather
than for it.

Two of the choices needed to produce a failure at all were changes I made after
earlier versions showed nothing: the non-monotonic delay pattern and the
incommensurate clocks. Both make the model more physically realistic, which is
why I made them, but it is a further reason to read the table as a
demonstration rather than a measurement.

What it does establish is an asymmetry. Gray coding has no threshold to find,
because only one bit moves and there is no amount of skew at which a sampler can
read a value the counter never held. Binary has one, and nothing in the design
flow tells you where it is.

## Running it

```bash
export PATH="/c/intelFPGA_lite/20.1/modelsim_ase/win32aloem:$PATH"
cd sim && vsim -c -do run_experiment.do
```

## What I would still not claim

This models bus skew, not metastability. The synchroniser is still two ideal
flops that resolve instantly; nothing here says anything about MTBF, and no
amount of Gray coding removes the need for the two-flop synchroniser. They fix
different problems and this experiment only exercises one of them.
