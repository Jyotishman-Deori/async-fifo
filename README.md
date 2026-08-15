# Dual-Clock Asynchronous FIFO

**Self-Project** · Jyotishman Deori (25M1186) · M.Tech Electronic Systems, IIT Bombay

A parameterised asynchronous FIFO for safe data transfer between two independent
clock domains, written in SystemVerilog and verified with a scoreboard, assertions
and functional coverage.

> **Status:** specification written, RTL in progress.
> This README is the contract the RTL is built against — written before the code,
> so the design is decided rather than discovered.

---

## 1. Why this design is not trivial

Two clocks with no fixed phase relationship means a multi-bit pointer sampled in the
other domain can be caught **mid-transition** — different bits arriving from different
sides of the flop, producing a value the counter never actually held. A binary counter
going `0111 → 1000` changes four bits at once; sample it wrong and you can read
anything from `0000` to `1111`.

Two mechanisms fix this, and the design needs both:

- **Gray coding** — successive values differ in exactly one bit, so a mid-transition
  sample yields either the old value or the new one, never a third.
- **Two-flop synchronisers** — give a metastable first flop a full clock period to
  resolve before the second flop samples it.

Gray coding alone does not fix metastability; synchronisers alone do not fix multi-bit
skew. This is the single most important thing to be able to say about this project.

---

## 2. Interface

```systemverilog
module async_fifo #(
    parameter int DSIZE = 8,    // data width
    parameter int ASIZE = 4     // address width -> depth = 2**ASIZE
) (
    // write domain
    input  logic              wclk,
    input  logic              wrst_n,
    input  logic              winc,
    input  logic [DSIZE-1:0]  wdata,
    output logic              wfull,

    // read domain
    input  logic              rclk,
    input  logic              rrst_n,
    input  logic              rinc,
    output logic [DSIZE-1:0]  rdata,
    output logic              rempty
);
```

---

## 3. Architecture

Pointers are **ASIZE+1 bits** — one bit wider than the address. That extra bit is what
separates *full* from *empty*, since both conditions otherwise have the pointers equal.

```
   wdata ──► ┌──────────────┐
             │  memory      │ ──► rdata
             │  2**ASIZE    │
             └──────────────┘
                ▲        ▲
             waddr     raddr        (low ASIZE bits of each binary pointer)

   wbin ──► wgray ──────[2FF sync into rclk]──────► rq2_wptr ──► rempty
   rbin ──► rgray ──────[2FF sync into wclk]──────► wq2_rptr ──► wfull
```

Each pointer crosses **once**, in one direction only. Never synchronise a pointer back
and forth, and never synchronise the binary counters — only the Gray versions cross.

### Blocks to write

| File | Contents |
|---|---|
| `rtl/sync_2ff.sv` | Parameterised two-flop synchroniser |
| `rtl/async_fifo.sv` | Memory, both pointer counters, full/empty logic, instantiates the synchronisers |

Splitting the synchroniser into its own module is deliberate: it is the block a
reviewer looks for, and keeping it separate makes it obvious it was not forgotten.

---

## 4. The logic that must be exactly right

**Binary to Gray**

```
gray = bin ^ (bin >> 1);
```

**Empty** — the read pointer has caught up with the write pointer. All bits equal:

```
rempty = (rgraynext == rq2_wptr);
```

**Full** — the write pointer has wrapped and caught the read pointer. Equal in the
low bits, with the **top two bits inverted**:

```
wfull = (wgraynext == {~wq2_rptr[ASIZE], ~wq2_rptr[ASIZE-1], wq2_rptr[ASIZE-2:0]});
```

The top *two* bits, not one — that is the part people get wrong. In Gray code the MSB
and the bit below it both flip when the counter passes the halfway point, so a
one-bit-inverted comparison detects the wrong condition.

Both flags are computed from the **next** pointer value, not the registered one, so
they assert in the same cycle the FIFO actually becomes full or empty rather than one
cycle late.

**Conservatism is a feature, not a bug.** Because each side sees a *delayed* copy of
the other pointer, `wfull` may stay high briefly after a read has freed space, and
`rempty` may stay high briefly after a write. The FIFO can therefore look fuller or
emptier than it is — never the reverse. It never overflows or underflows, which is the
only property that matters. Be ready to say this; it is a standard interview question.

---

## 5. Verification gates

Each gate passes only with the output pasted into the commit message. Same standard
as the MTP repo.

| Gate | Bar |
|---|---|
| Scoreboard | **0 mismatches**, and data comes out in FIFO order |
| Clock ratios | Passes **both** fast-write/slow-read and slow-write/fast-read |
| Backpressure | Randomised stalls on both interfaces, not a clean stream |
| Assertions | Never write when full, never read when empty — 0 failures |
| Coverage | `wfull` hit, `rempty` hit, simultaneous read+write, back-to-back writes |
| Synthesis | **0 latches**, 0 inferred oddities |

A single passing directed test proves nothing about a CDC design. The stalls and the
reversed clock ratio are where the real bugs surface.

### Testbench requirements

- Two genuinely independent clock generators — use awkward, non-integer-related
  periods (e.g. 7 ns and 11 ns), not 10 ns and 20 ns
- A reference queue driven by the write side, popped and compared on the read side
- Randomised `winc` / `rinc` so both full and empty are actually reached
- Independent resets per domain

---

## 6. Running it

```bash
# ModelSim (not on PATH by default)
export PATH="/c/intelFPGA_lite/20.1/modelsim_ase/win32aloem:$PATH"
cd sim && vsim -c -do run.do

# Synthesis check (Vivado, not on PATH by default)
export PATH="/c/Xilinx/Vivado/2020.2/bin:$PATH"
vivado -mode batch -source synth/synth_check.tcl
```

---

## 7. Results

Fill this in with **measured** numbers once it runs — this table is what the resume
bullet is written from, so no adjectives where a number belongs.

| Metric | Result |
|---|---|
| Write clock / read clock | _TBD_ |
| Transactions passed | _TBD_ |
| Assertion failures | _TBD_ |
| Coverage bins hit | _TBD_ |
| Latches inferred | _TBD_ |

---

## 8. Questions to be ready for

Write your own answers here as you build. If a question has no answer, that part of
the design is not finished.

1. Why Gray code rather than binary across the boundary?
2. Why does a two-flop synchroniser help, and what does it *not* fix?
3. Why are the pointers one bit wider than the address?
4. Why invert the top **two** bits for full, not one?
5. Why compute the flags from the next pointer instead of the registered one?
6. What is MTBF, and what does adding a third flop buy you?
7. Can this FIFO ever overflow? Prove it.
8. What changes if the depth is not a power of two?
