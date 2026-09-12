# Verification flow

Step-and-compare co-simulation for the rv32i-tlv core.

Every test is run twice — once on the Verilated RTL, once on **Spike** — and the two
**instruction-by-instruction execution traces** are compared. The comparator reports the
*first* instruction at which the two disagree.

This is the method the RISC-V Foundation's "Getting Started with RISC-V Verification" post
leads with, and it is strictly stronger than a signature diff. RISCOF compares one memory blob
at the end of a test, so a failure tells you "something went wrong somewhere in 3000
instructions". A trace comparison tells you:

```
FAIL privilege_ecall : diverged at committed instruction #25 of 286(ref)/286(dut)
       reference retired at this pc, DUT trapped
  --- first divergence ---
  REF  25  000010f0 34409073   csrw mip,ra
  DUT  25  000010f0          TRAP cause=2 (trap_illegal_instruction)   csrw mip,ra
```

That is a bug report, not a puzzle.

## Quick start

```bash
export PATH=$HOME/riscv/bin:$HOME/venv/bin:$PATH
./build.sh                                              # sandpiper + verilator

verif/regress.sh        verif/tests                       # directed        (~1 s)
verif/regress.sh        --arch I privilege hints Zifencei # riscv-arch-test (~11 s)
verif/unaligned_test.sh 30 500                            # misalign+traps  (~5 s)
verif/dv.sh             64 4000                           # riscv-dv        (~4 min)

python3 verif/coverage.py verif/work                      # what was actually exercised
verif/cosim.sh verif/tests/smoke.s                        # a single test
```

A failing test writes a full report to `verif/work/<name>/report.txt`.

## How it works

| File | Role |
|---|---|
| `tb.sv` | emits an RVFI-style retirement trace: pc, instruction, register write, memory write, traps |
| `rvtrace.py` | normalises the DUT trace and Spike's `--log-commits` log into one form, finds the first divergence |
| `cosim.sh` | build, run reference, run DUT, compare — for one test |
| `regress.sh` | parallel regression; `--arch <group>` pulls straight from riscv-arch-test |
| `testmeta.py` | reads each arch-test's `RVTEST_CASE` metadata: ISA applicability + required `-D` macros |
| `unaligned_test.py` / `.sh` | constrained-random generator for the misaligned-access and trap paths |
| `dvgen.sh` / `dv.sh` | riscv-dv generation + co-simulation |
| `link.ld` / `link_dv.ld` | linker scripts, based at `0x1000` (the second adds riscv-dv's sections) |
| `env/model_test.h` | `RVMODEL_*` macros: how an arch-test boots, halts and lays out its signature |
| `tests/` | directed tests — `smoke.s` (harness sanity), `spec_gaps.s` (roadmap items no other suite reaches) |
| `coverage.py` | what the regression actually exercised: instructions + mandatory exception causes |
| `testcodes_makerchip/` | **legacy, not part of this flow.** `1`–`15` are Makerchip `m4_asm(...)` programs that nothing can execute any more; `16.s` + its `.expected` files run only under the old `run.sh` in that directory. Kept because they encode real test intent worth porting to `tests/`. |

Three things are worth knowing:

**Commit point.** The core's architectural commit point is stage `@4`, where `$rf_wr_data` is
final (loads only resolve at `@3`). SandPiper only pipelines a signal as far as the design uses
it, so `$pc` stops at `@2` and `$instr` at `@1`. Rather than add flops to the RTL for
observability, `tb.sv` re-pipelines them itself — free, because a testbench is never synthesised.

**Address 0.** The core resets to `pc == 0`, but Spike permanently reserves `[0, 0x1000)` for its
debug module. Tests are linked at `0x1000` and the testbench plants a single `jal x0, 0x1000` at
word 0; the comparator drops it (`--skip-below 0x1000`).

**Termination.** Both sides must stop at the same instruction. Two rules, applied identically to
both traces: stop when the same pc commits twice in a row (a `j .`), or when a store hits the
`tohost` symbol. riscv-dv needs the second rule, because its `write_tohost` is a three-instruction
loop rather than a self-loop.

## riscv-arch-test setup

The suite lives at `~/riscv-arch-test` (override with `ARCHTEST`):

```bash
git clone https://github.com/riscv-non-isa/riscv-arch-test ~/riscv-arch-test
```

It is used directly — compiled by `cosim.sh` and checked by trace comparison. RISCOF is not
involved. The one piece of RISCOF's job that genuinely mattered is reimplemented in
`testmeta.py`: reading each test's `RVTEST_CASE` metadata for its ISA gate and its required `-D`
macros. Miss the macros and tests silently assemble into something else — omitting
`rvtest_mtrap_routine`, for instance, drops the trap handler entirely and leaves `mtvec` at 0.

The suite's sources `#include "model_test.h"` for the `RVMODEL_*` macros that tell a test how to
boot, halt and lay out its signature on this particular core. That file lives at
`verif/env/model_test.h` (override the directory with `MODELENV`).

The project's old `riscof/` directory (driver config, DUT and Sail plugins, yamls) was deleted on
2026-09-02 once this file and the test suite had been moved out. Nothing references it.

## Reference model configuration

`--priv=m` is not optional. Spike defaults to `MSU`, which sets the S and U bits in `misa`; the
core is M-mode only. Without the flag the reference reports `misa=40140100` against the DUT's
(correct) `40000100`, and every trap test "fails". **Configuring the reference to match the DUT is
not a detail — it is the entire contract.** This is the one job RISCOF's ISA/platform YAML does
that genuinely matters.

## Stimulus sources

The four are complementary — each reaches something the others structurally cannot. Figures are
measured from the traces, not assumed:

| Source | Committed instrs | Traps | Trap causes reached |
|---|---|---|---|
| riscv-arch-test | ~90 k | 18 | 3, 4, 6, 11 |
| `unaligned_test.py` (30 progs) | 14 645 | 196 | 3, 4, 6, 11 |
| riscv-dv (8 progs) | ~11 k | 8 | 11 only |
| `tests/spec_gaps.s` | 75 | 9 | **0, 2**, 3, 11 |

Note how much the last row carries for its size: **causes 0 and 2 are reached by nothing else at
all.** Volume is not coverage.

**Why the two random generators are both kept.** riscv-dv dominates on datapath volume — 15.8 k
branches, dense RAW chains at every pipeline distance — which is where forwarding and
branch-prediction bugs live. But it emits **no misaligned accesses at all**, because the
`rv32i_tlv` target sets `support_unaligned_load_store = 0`.

That flag is correct and stays that way: this core genuinely does trap on an unaligned load or
store, so telling riscv-dv otherwise would be lying to the generator about the design. The right
answer is not to bend the flag, it is to cover that space deliberately — which is what
`unaligned_test.py` is for. It emits misaligned loads and stores on purpose (`--misalign-pct`,
default 8%) plus `ecall`/`ebreak`, and installs a handler that skips the faulting instruction so a
single trap does not end the program.

So: riscv-dv owns the datapath and hazard space, `unaligned_test.py` owns the misaligned and trap
space, arch-test pins the per-instruction semantics. Changing one to compensate for the other
would reopen the gap — the file is named for the coverage it carries so this stays visible.

## riscv-dv setup

riscv-dv's free path is **pyflow**, which needs PyVSC and `pyboolector`, a compiled extension with
no wheel for CPython 3.13/3.14. Ubuntu 26.04 ships only 3.14, so riscv-dv gets its own Python:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
uv venv --python 3.12 ~/venv-dv
uv pip install --python ~/venv-dv/bin/python pyvsc bitstring PyYAML tabulate pandas
git clone https://github.com/chipsalliance/riscv-dv ~/riscv-dv
```

Then two local changes to the checkout:

1. `pygen/pygen_src/isa/riscv_instr.py`: `from imp import reload` becomes
   `from importlib import reload` (`imp` was removed in Python 3.12).
2. Copy `pygen/pygen_src/target/rv32i` to `target/rv32i_tlv`, then in its
   `riscv_core_setting.py` drop `MCOUNTEREN` from `implemented_csr` (only required when U-mode
   exists; this core does not decode `0x306`) and set `support_unaligned_load_store = 0`.

   `support_unaligned_load_store = 0` is correct and should stay — this core really does trap on
   an unaligned load or store, and the flag tells riscv-dv the truth about the design. The
   consequence is that riscv-dv emits no misaligned accesses; that space is covered deliberately
   by `unaligned_test.py` instead. Setting the flag to 1 would make riscv-dv generate unaligned
   accesses it assumes will *complete*, and its generated handler does not emulate them.

Nothing else — riscv-dv is used as a generator only. Its own Spike-comparison flow is unused,
which keeps its configuration surface small.

Two pyflow options must stay at their safe values. Both are upstream bugs in the Python port,
not in the SystemVerilog flow:

- `--num_of_sub_program 0` — `gen_callstack()` calls `self.callstack_gen`, which is never
  assigned, and `riscv_callstack_gen.init()` passes a name to `riscv_program.__init__()`, which
  takes none. Costs cross-procedure call/return coverage.
- leave `--no_fence` at `1` — enabling FENCE trips `unhashable type: 'list'` in
  `riscv_instr.get_rand_instr()`. FENCE is covered by arch-test `fence-01` and is a nop here.

## Bugs this flow found

| # | Bug | Fix |
|---|---|---|
| 1 | `$dmem_index[13:0] = $addr[20:2]` — 19-bit slice into 14 bits, so data memory aliased every 64 KiB | widened to `[18:0]` |
| 2 | `$imem_index[16:0] = $pc[20:2]` — same truncation; fetch aliased above 512 KiB, so `jal` to `0xabc90` fetched a stray `nop` and ran away | widened to `[18:0]` |
| 3 | `mie` (0x304) and `mip` (0x344) missing from `$csr_addr_valid` — mandatory M-mode CSRs, so every standard trap prolog took a spurious illegal-instruction trap | added to the decode; reads already default to 0 and writes already drop, which is correct read-only-zero behaviour for a core with no interrupt sources |
| 4 | `ebreak` wrote `mtval = 0`; the privileged spec puts the breakpoint address there | `$exception_tvalue` returns `$pc` for `$is_ebreak` |

Bugs 1 and 2 alone accounted for every branch-test failure in the old RISCOF run — they were never
branch bugs. The branch tests are simply the largest, so they were the first to run off the end of
the reachable memory window.

## Measuring coverage

A green regression measures the tests, not the core. `coverage.py` reads every trace and reports
what was actually exercised:

```bash
python3 verif/coverage.py verif/work
```

Current state, after a full run of all four suites:

```
traces          : 108
retired instrs  : 114106
instr coverage  : 47 / 47

mandatory exception causes (roadmap.md Tier 1):
   0    instruction address misaligned   3 raised
   2    illegal instruction              6 raised
   3    breakpoint (EBREAK)              44 raised
   4    load address misaligned          73 raised
   6    store address misaligned         58 raised
   11   environment call from M-mode     47 raised
```

It exits non-zero if any instruction or mandatory cause is unreached, so it can gate CI.

One subtlety it handles: a trapping instruction never retires, so `ecall` and `ebreak` never
appear in the retirement trace as executed instructions. They are counted from their TRAP records
instead. Getting that wrong makes them look uncovered when they are not.

**`tests/spec_gaps.s` exists to close holes the other suites structurally cannot reach.** Causes 0
and 2 were raised by nothing at all before it: arch-test's `misalign-*` tests are *skipped* here
(they require the C extension and assert the opposite behaviour), and neither random generator
emits illegal encodings. It also covers `csrrwi`/`csrrsi`/`csrrci`/`csrrc` — four of the six Zicsr
instructions, which nothing else executes — plus write-to-read-only-CSR, non-existent CSR,
`rs1=x0` write suppression, reserved FENCE encodings, `mepc` low-bit masking, and `minstret` not
counting a trapping instruction.

### What is still not covered

- **Exception priority** (roadmap Tier 1, Table 7) — no test raises two simultaneous exceptions on
  one instruction.
- **`mstatus` WPRI fields** reading as zero, and `mstatus` behaviour under arbitrary writes.
- **`mcycle`** — differs between a 5-stage pipeline and an ISS by construction, so it cannot be
  compared this way at all. `minstret` is checkable only because it counts retirements, which both
  models agree on once zeroed (see the note in `spec_gaps.s`).
- **CSR writes are not compared** as trace records; CSR state is verified only where a later read
  feeds a compared register write.

## Known gaps

- **No data-side access-fault checking.** Any address in `[0, 2 MiB)` reads as 0 and is writable,
  and addresses above 2 MiB silently alias downward — `$dmem_index` just truncates `$addr[31:21]`
  with no fault. A store to `0x80000000` lands at `0x0`. This is also why
  `verif/testcodes_makerchip/16.s` cannot run under co-simulation: it uses absolute address
  `0x7fc` as a data base, which is below the reference model's mapped RAM, so Spike raises a load
  access fault and the DUT does not. Run it with `verif/testcodes_makerchip/run.sh 16` instead.
- **`mtval` on illegal instruction** is 0; Spike writes the faulting instruction bits. The spec
  makes this optional ("*may* be used to return the faulting instruction"), so the core is
  conformant — but enabling illegal-instruction generation in riscv-dv would report it as a
  divergence.
- **Split imem/dmem.** Both arrays are loaded with the same image, but stores only update `dmem`.
  Self-modifying code would diverge from Spike's unified memory. Nothing generated today hits this.
- **CSR writes are not compared.** The trace carries GPR and memory writes; Spike's CSR write
  records are parsed and discarded. CSR *reads* are covered indirectly, since a wrong read feeds a
  compared register write.
- **No cross-procedure call/return stimulus** from riscv-dv (see `--num_of_sub_program` above).
