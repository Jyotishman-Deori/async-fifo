# Running it on a PYNQ-Z2

The simulation says the FIFO works. Simulation also said it worked with the
Gray coding removed, so I wanted it on silicon.

Result: **286,176,459 words through the FIFO, zero errors**, both full and
empty reached. Transcript in [`../results/hardware_test.txt`](../results/hardware_test.txt).

## Why the PS is in this design

The whole value of a hardware run is the clocks, so the clocks are the one
thing worth getting right.

The obvious approach is to take the board's 125 MHz oscillator and derive a
second frequency from it with an MMCM. That would have been half the work and
most of the point would have been lost, because two clocks out of one MMCM are
phase locked. The relationship between their edges is fixed and repeats, so
sampling happens at the same handful of relative phases forever and the
synchroniser might never once be caught inside its setup/hold window. It would
have looked like a hardware test while proving less than the simulation did.

So `wclk` is `FCLK_CLK0`, which comes off the PS PLL and the 33.333 MHz
crystal, and `rclk` is the 125 MHz board oscillator. Two crystals, no common
reference. They drift against each other continuously, so over a ten second run
the sampling point sweeps through every phase relationship there is, including
the ones that land a synchroniser input right on its edge. The Zynq PS is in
the design for that reason alone. Nothing else in it is used.

## What runs

`fifo_hw_test.v` is the simulation testbench rebuilt as synthesisable logic.
An LFSR generates the write data, an identical LFSR on the read side predicts
what should come back, and a comparator counts words that do not match. A
second pair of LFSRs stalls both interfaces so full and empty are actually
reached. `top_pynq_z2.v` adds the clocking, the reset synchronisers, the VIO
and the LEDs.

If the FIFO ever drops or duplicates a single word, the read side's replica
falls out of step and every word after it counts as an error. A one word
failure shows up as tens of millions of errors rather than as one, which is
the behaviour I want from a checker.

Two phases, the same shape as the simulation: write fast against a slow reader
so the FIFO jams against full, then the reverse so it runs dry. Counters are
not cleared in between, because stopping a phase only pauses both LFSRs and
they stay in lockstep.

## Results

```
phase 1  write fast, read slow    159,905,237 written   159,905,221 read   0 errors
phase 2  write slow, read fast    286,176,459 written   286,176,459 read   0 errors
                                  full seen: yes        empty seen: yes
```

Phase 1 ends 16 words short, which is the detail I like most in this whole
project. The FIFO is exactly 16 deep, and phase 1 stops with the writer running
flat out against a slow reader, so the FIFO is full at the instant writes stop
and is holding a full 16 words that have not been read yet. Phase 2 inverts the
rates, the reader drains those 16 and then keeps pace, and the totals come out
exactly equal. The residual is not noise, it is the depth.

For scale: the simulation checked 10,017 words. This is roughly 28,000 times
more, on real routing with real metastability, in twenty seconds.

Implementation timing, from `build.tcl`:

```
worst setup slack (WNS)  1.997 ns
worst hold slack  (WHS)  0.061 ns
```

## What Vivado's CDC report says about the full design

```
CDC-1  Critical  32  1-bit unknown CDC circuitry
CDC-3  Info      14  1-bit synchronized with ASYNC_REG property
CDC-5  Warning    1  Multi-bit synchronized with missing ASYNC_REG property
CDC-6  Warning    3  Multi-bit synchronized with ASYNC_REG property
CDC-9  Info       2  Asynchronous reset synchronized with ASYNC_REG property
```

The 32 CDC-1 criticals all run from the FIFO's memory to the comparator:

```
u_test/dut/mem_reg_0_15_6_7/RAMA_D1/CLK  ->  u_test/errors_reg[*]/CE
```

That is the FIFO's read data path, and it is correct. Data is written on
`wclk` and read on `rclk` with no synchroniser anywhere near it, which is
exactly what a CDC checker should shout about, except that the pointer protocol
guarantees the read side only ever addresses words written at least two
synchroniser stages earlier. The data has been sitting still for several
clocks by the time anything reads it. Vivado can see wires, not protocols.

This one did not appear in the standalone `synth/synth_check.tcl` run, because
there `rdata` goes straight to a top level port and there is no consumer logic
to trace into. Wrapping the FIFO in something that actually uses the data is
what surfaced it.

CDC-5 is `words_written` being sampled by the VIO across domains. It is real
and I left it: the counter is only read after `run` has gone low and both sides
have stopped, so what the VIO samples is static. That is safe by protocol
rather than by structure, which is worth being honest about rather than
papering over with an ASYNC_REG that would not actually make it correct.

## The mistake worth recording

The first build came back with a CDC-10, combinational logic before a
synchroniser:

```
u_vio/.../Probe_out_reg[0]/C  ->  wrst_sync_reg[0]/CLR
```

I had written the reset as one line, `arst_n = fclk_rst_n && !vio_rst`, feeding
both reset synchronisers. That AND gate sat directly on the asynchronous clear
pin of a synchroniser flop. A glitch on it resets one clock domain and not the
other, which leaves the FIFO's two pointers disagreeing about where the data
starts. That is the precise failure this project exists to prevent, sitting in
the harness built to demonstrate it does not happen.

The reset is now built in three stages: `fclk_rst_n` is the only asynchronous
reset and has no logic in front of it, the VIO's soft reset crosses into the
write domain through a `sync_2ff` like any other control bit, and the two are
combined and registered before anything downstream sees them.

## Running it

Needs no SD card and no software on the PS. The board can sit at any boot mode
setting.

```bash
export PATH="/c/Xilinx/Vivado/2020.2/bin:$PATH"

# build (project goes to TEMP; Vivado cannot build inside a OneDrive folder)
vivado -mode batch -source hw/build.tcl

# PS clocks, bitstream, then release the PL
xsdb hw/program.tcl

# run both phases and read the counters back
vivado -mode batch -source hw/run_hw_test.tcl
```

The order inside `program.tcl` matters and I got it wrong first time.
`ps7_post_config` enables the PS to PL level shifters and releases
`FCLK_RESET0_N`, so it has to run *after* the bitstream is loaded. Running it
before leaves the whole design in reset: the VIO still answers, because it runs
off the board oscillator, but every counter reads zero.

LEDs, left to right:

```
0  heartbeat, the read clock is alive
1  test running
2  ERROR, at least one word came back wrong
3  both full and empty were reached
```

LED3 on with LED2 off is a pass. LED3 off means the rates were wrong and the
run proved little, whatever LED2 says.

## What this still does not prove

It says nothing about MTBF. Twenty seconds of two drifting clocks is a good
sweep of the phase space but it is not a synchroniser reliability measurement,
and a two-flop synchroniser has a finite failure rate no run of this length
would expose. Nothing here justifies the second flop over a third at a higher
frequency; that is an MTBF calculation, not a test.
