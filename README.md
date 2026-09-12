# rv32i-tlv

A 5-stage pipelined **RV32I + Zicsr** processor core, written in TL-Verilog, verified by
**instruction-by-instruction co-simulation against Spike**.

```
riscv-arch-test     68 passed,  0 failed, 24 skipped (not applicable to this ISA)
directed tests       2 passed,  0 failed
unaligned/trap fuzz 30 passed,  0 failed
riscv-dv            64 passed,  0 failed
coverage            47/47 instructions, 6/6 mandatory exception causes
```

Every number above is reproducible from a clean checkout in about five minutes. Coverage is
**measured from execution traces**, not asserted — `verif/coverage.py` exits non-zero if any
instruction or mandatory exception cause was never reached.

---

## The core

Machine-mode only, no interrupts, no virtual memory. Written in
[TL-Verilog](https://tl-x.org) and translated to SystemVerilog by SandPiper.

```
   @0  IF              @1  ID                @2  EX                @3  MEM        @4  WB
   ───────────────     ─────────────────     ──────────────────    ───────────    ──────────
   next-PC mux         IMem read             operand forwarding    DMem read/     writeback
   BTB / BHT lookup    decode + imm gen      ALU                   write          mux
   predict taken       register file read    branch resolve        sub-word       (load vs
                       JAL redirect          JALR / MRET redirect  extract +      ALU result)
                       trap detect           CSR read-modify-write sign/zero
                       predictor update      trap entry            extend
```

**It never stalls.** There is no stall, bubble or ready/valid logic anywhere in the design.
Every hazard is resolved by forwarding, and control-flow changes are handled by *killing*
in-flight instructions rather than freezing the pipe — an `$on_path` term at `@1` retroactively
invalidates instructions that a later-resolving redirect has orphaned.

| Mechanism | Detail |
|---|---|
| Forwarding | Two paths, EX←MEM and EX←WB. Load-use is covered without a stall: a load resolves at `@3` while its consumer is at `@2`, so the data is forwarded in the same cycle. |
| Branch prediction | 32-entry BTB + BHT, 2-bit saturating counters, indexed by `pc[6:2]`, tagged on `pc[31:7]`. |
| Redirect penalty | Correctly predicted branch: 0 cycles. JAL (resolves at ID): 1. JALR, MRET, mispredict, trap (resolve at EX): 2. |
| Memory | 2 MiB instruction + 2 MiB data. Sub-word loads sign/zero-extend by `funct3`; sub-word stores are read-modify-write on the containing word. |
| Traps | `mtvec` direct mode. Causes 0, 2, 3, 4, 6, 11. `MRET` restores `MIE←MPIE`, `MPIE←1`. |
| CSRs | `mstatus`, `misa`, `mie`, `mtvec`, `mstatush`, `mscratch`, `mepc`, `mcause`, `mtval`, `mip`, `mcycle(h)`, `minstret(h)`, `mvendorid`, `marchid`, `mimpid`, `mhartid`, `mconfigptr`, and the `mhpmcounter`/`mhpmevent` ranges as read-only zero. |

## Verification

This is the part of the project I would most want reviewed.

The core is run against **Spike**, the reference ISA simulator, and the two
**retirement traces** are compared instruction by instruction — PC, instruction word, register
writeback, memory write, and trap cause/`mtval`. The comparator reports the *first* point of
disagreement:

```
FAIL privilege_ecall : diverged at committed instruction #25 of 286(ref)/286(dut)
       reference retired at this pc, DUT trapped
  --- first divergence ---
  REF  25  000010f0 34409073   csrw mip,ra
  DUT  25  000010f0          TRAP cause=2 (trap_illegal_instruction)   csrw mip,ra
```

That is a bug report rather than a puzzle, and it is the reason the bugs below took minutes
instead of days. The project originally used RISCOF, which compares a single signature blob at
the end of a test; a failure there tells you only that *something* went wrong somewhere in a few
thousand instructions. Replacing it with trace comparison is what made the rest tractable.

Four independent stimulus sources feed the same comparator, each reaching something the others
structurally cannot:

| Source | Role |
|---|---|
| **riscv-arch-test** | official per-instruction semantics; compiled directly, with each test's `RVTEST_CASE` metadata parsed for its ISA gate and required macros |
| **riscv-dv** (ChipsAlliance) | datapath volume: dense RAW chains at every pipeline distance, and 15 843 branches over the 64-program run. This is where forwarding and prediction bugs live. |
| **`unaligned_test.py`** | misaligned accesses and trap paths, which riscv-dv cannot emit because the target correctly declares `support_unaligned_load_store = 0` |
| **`tests/spec_gaps.s`** | 75 instructions covering what nothing else reaches — exception causes 0 and 2 are raised by no other source at all |

Full detail, including reference-model configuration and the remaining gaps, is in
**[`verif/README.md`](verif/README.md)**.

## Bugs this found

| Bug | Symptom | Root cause |
|---|---|---|
| `$dmem_index[13:0] = $addr[20:2]` | data memory aliased every 64 KiB | 19-bit slice assigned into a 14-bit signal |
| `$imem_index[16:0] = $pc[20:2]` | `jal` to `0xabc90` fetched a stray `nop` and ran away for 200 k cycles | same truncation on the fetch path, above 512 KiB |
| `mie` / `mip` missing from CSR decode | *every* standard trap prolog took a spurious illegal-instruction trap | two mandatory M-mode CSRs absent from `$csr_addr_valid` |
| `ebreak` wrote `mtval = 0` | trap taken with the correct cause but no faulting address for the handler | privileged spec requires the breakpoint instruction's address |

The first two are the interesting ones. Under RISCOF they presented as **six failing branch
tests**, which is a convincing disguise — branch logic was the obvious suspect. They are not
branch bugs at all. The branch tests are simply the *largest* binaries in the suite, so they were
the first to place their signature above the truncated address window. One step-and-compare report
showed `sw` landing at `0x0a114` where the reference wrote `0x3a114`, and the actual bug was
immediate.

Verilator never flagged either truncation, because the SandPiper-generated module carries a
blanket `/* verilator lint_off WIDTH */`.

Two further differences turned out **not** to be core bugs, which is its own kind of finding:
Spike defaults to `--priv=msu` and so reports `misa` with the S and U bits set, and `marchid` is
an implementation-defined value. Both were fixed by configuring the reference to match the design,
not by changing the design.

## Layout

```
rv32i.tlv                  the core (TL-Verilog)
tb.sv                      testbench + RVFI-style retirement trace
build.sh                   SandPiper -> SystemVerilog -> Verilator
out/                       generated SystemVerilog (build product)
roadmap.md                 conformance gap analysis: what "done" means, tier by tier
verif/                     the verification flow  -- see verif/README.md
  cosim.sh  rvtrace.py     one test, end to end; trace normalisation + first-divergence report
  regress.sh  coverage.py  parallel regression; measured instruction/exception coverage
  dvgen.sh  dv.sh          riscv-dv integration
  unaligned_test.py/.sh    constrained-random misaligned + trap generator
  tests/                   directed tests
  testcodes_makerchip/     legacy Makerchip-era programs, kept for their test intent
```

`roadmap.md` is worth a look on its own. Written once the datapath was running, it is a
tier-by-tier reading of the unprivileged and privileged specifications establishing what an
M-mode-only RV32I+Zicsr core must *actually* implement to be conformant: WARL/WLRL/WPRI field
semantics, synchronous exception priority, which CSRs are mandatory versus implementation-defined,
and which apparent gaps legitimately belong to a later phase. It drove the Tier 0–6 work, and the
verification is now measured against it directly — `coverage.py` reports against its Tier 1 table.

## Build and run

Requires a RISC-V toolchain, Spike, Verilator and SandPiper. See
[`verif/README.md`](verif/README.md) for the full setup, including the isolated Python 3.12
environment riscv-dv needs.

```bash
export PATH=$HOME/riscv/bin:$HOME/venv/bin:$PATH
./build.sh                                                  # SandPiper + Verilator

verif/regress.sh        verif/tests                         # directed        (~1 s)
verif/regress.sh        --arch I privilege hints Zifencei   # riscv-arch-test (~11 s)
verif/unaligned_test.sh 30 500                              # misalign+traps  (~5 s)
verif/dv.sh             64 4000                             # riscv-dv        (~4 min)

python3 verif/coverage.py verif/work                        # what was actually exercised
```

## Techniques and tools

**Microarchitecture** — 5-stage pipelining; RAW hazard resolution by forwarding rather than
stalling, including load-use; BTB/BHT branch prediction with 2-bit saturating counters; precise
exceptions via speculative-instruction kill rather than pipeline freeze.

**Specification work** — RISC-V Unprivileged and Privileged ISA manuals; WARL/WLRL/WPRI CSR field
semantics; synchronous exception priority; separating mandated behaviour from
implementation-defined behaviour, which turned out to matter repeatedly (`misa` under
`--priv=msu`, `marchid`, `mtval` on illegal instruction).

**HDL** — TL-Verilog: implicit pipelining, `>>n` transaction alignment, hierarchical `/name[n]`
structures for the register file and predictor arrays; SandPiper translation to SystemVerilog;
a SystemVerilog testbench that re-pipelines DUT signals through hierarchical references to
observe the commit point without adding flops to the design.

**Verification** — reference-model co-simulation (step-and-compare); RVFI-style retirement
tracing; constrained-random stimulus, including the operand-biasing needed to actually build
dependency chains; coverage measurement against a specification checklist; parallel regression
automation.

**Toolchain** — Verilator, Spike, riscv-gcc/binutils, custom linker scripts and flat-image
loading, ELF/objcopy, riscv-arch-test, riscv-dv with PyVSC, RISCOF (used, then deliberately
replaced), Python, Bash, WSL.

## Scope

Implemented and verified: RV32I base, Zicsr, machine mode, synchronous exceptions, the trap/MRET
path, and the counters.

Deliberately **not** implemented — these are Phase 2, not oversights:

- **Interrupts.** `mie`/`mip` decode and read as zero; there is no interrupt controller or timer.
- **U-mode, PMP, virtual memory.** M-mode only, so `mcounteren` is correctly absent.
- **Memory access faults.** Every address in the map is defined, so causes 1/5/7 are legitimately
  unimplemented — but the consequence is that addresses above 2 MiB alias downward silently rather
  than trapping. This is recorded as a known gap rather than papered over.
- **Physical implementation.** Memories are behavioural arrays, not SRAM macros or caches. The
  design has not been synthesised, so there are no area, frequency or power numbers, and none are
  claimed.

Also untested, and listed as such in `verif/README.md`: exception priority when two exceptions
apply to one instruction, `mstatus` WPRI behaviour, and `mcycle` — which cannot be compared
against an ISS at all, since cycle counts differ between a 5-stage pipeline and a functional model
by construction.
