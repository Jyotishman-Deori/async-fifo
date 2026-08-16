# Does the Gray coding actually do anything?

Everything here is deliberately broken code kept for the result it produced.
None of it is part of the design. `experiments/async_fifo_exp.v` is a modified
copy of the real FIFO with two knobs: send the pointers across as Gray or as
plain binary, and delay each bit of the crossing bus by a different amount.

## Why I bothered

I wrote the FIFO, the testbench passed, and I could recite why Gray coding is
needed. Then I took the Gray coding out — swapped the crossing to raw binary
pointers, with the matching binary full/empty tests so the encoding was the only
thing that changed — and ran the same testbench again.

It passed. Zero mismatches, both clock ratios, full and empty both reached.

That is worth sitting with. The single most quoted fact about asynchronous FIFOs
is that binary pointers across a clock boundary will corrupt your data, and my
verification could not tell the two designs apart.

## Why it passed

In RTL simulation every bit of a bus changes at the same instant. There is no
skew, so there is no window in which a sampler can catch half of an old value
and half of a new one. The entire hazard Gray coding exists to prevent is
invisible at this level of abstraction. A gate-level netlist with real delays
would show it; plain RTL never will.

So I injected the skew by hand. Each bit of the crossing bus gets its own
transport delay before it reaches the synchroniser, and `n_caught_midflight`
counts how many times a domain latched that bus while it was still settling —
so a clean run can be distinguished from a run that simply never sampled at a
bad moment.

Two things had to be fixed before the experiment measured anything:

**The delay pattern must not be monotonic.** My first attempt delayed bit `i` by
`i * step`, so low bits always moved first and the transient value was always
*smaller* than both the old and the new pointer. That direction is harmless —
a pointer that reads low just makes the other side believe the FIFO is fuller,
or emptier, than it really is, which is the pessimistic direction the design
already tolerates by construction. Binary passed and told me nothing. The
pattern is now `step * ((i*3+1) % 4)`, which lets a high bit land before the
low bits have cleared, so the pointer can transiently read *high* — the
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
| 0.4 | 413 | 0 | 649 | 0 |
| 1.0 | 895 | 0 | 1391 | 0 |
| 2.0 | 1840 | 0 | 2505 | 0 |
| 3.5 | 3234 | **0** | 5785 | **3513** |

Gray is flat at zero the whole way. At the last row it was caught mid-transition
3234 times and still did not drop or corrupt a single word, because only one bit
ever moves — catch it early or late and you get the old value or the new one,
and both are safe.

Binary needs more explaining, because it survives the first three rows despite
being caught mid-transition thousands of times.

## Why binary survives small skew

A transient only exists while a pointer is *moving*, and a pointer moves only
when that side has actually done something. If the write domain latches a
corrupted read pointer, the corruption is proof that a read just happened —
which means a slot genuinely was freed. The garbage breaks the equality test for
exactly one cycle, `wfull` drops for exactly one cycle, and at most one extra
write slips through. That write had somewhere to go. Same argument on the other
side: a corrupted write pointer means a write really did happen, so the data the
read side goes after is really there.

It holds because the transient is shorter than a destination clock period, so
only one sampling edge can land inside it. That is what breaks at 3.5 ns, where
the bus spread is 10.5 ns against a 7 ns write clock: the bad value now survives
across consecutive edges, several extra operations slip through per event, and
the self-limiting argument collapses. 89% of the words read came out wrong.

So binary is not merely riskier than Gray. It is correct only while the skew
stays under a bound nobody checks, on a path that is by definition unconstrained,
and it fails completely rather than gracefully once that bound is crossed. Gray
has no such bound — the guarantee is structural, not a matter of degree.

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
