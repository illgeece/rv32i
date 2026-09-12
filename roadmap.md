# RV32I + Zicsr Conformance Gap Analysis: What "Done" Really Means for a Machine-Mode-Only Core

## TL;DR
- **No — your three-item list (byte/halfword load-store, the misaligned exception causes, and mtval) is necessary but far from sufficient.** You are missing an entire class of privileged-architecture obligations, most importantly the `mstatus` register with correct MRET state semantics (MIE/MPIE/MPP), the four mandatory read-only ID CSRs (`mvendorid`, `marchid`, `mimpid`, `mhartid`), correct WARL/WLRL field behavior across your existing CSRs, and several unprivileged correctness details (HINT no-op semantics, FENCE reserved-encoding handling, JALR bit-0 clearing, taken-branch-only misalignment).
- **The precise "Phase 1 = conformant M-mode RV32I+Zicsr" target is roughly a dozen workstreams**, of which your list covers three. The single highest-risk omission is `mstatus`/MRET: your MRET restores only PC, which is a guaranteed RISCOF `privilege`-suite failure.
- **Interrupts, `mie`/`mip`, `mtvec` vectored mode, WFI, and the memory-mapped timer (`mtime`/`mtimecmp`) legitimately belong to your later Phase 2** — they are not required for a conformant machine-mode RV32I+Zicsr core and you can defer them without compromising Phase-1 conformance.

## Key Findings

1. **Byte/halfword loads and stores** must sign-extend (LB, LH) or zero-extend (LBU, LHU) to XLEN; stores (SB, SH) write only the low 8/16 bits. This is correct on your list.
2. **Misaligned access support is optional but must be *deterministic*.** The ratified Unprivileged ISA lets a simple core raise a load/store-address-misaligned exception instead of supporting misaligned accesses. RISCOF's misalign tests explicitly waive cores that trap — but only if trapping is *consistent* (the arch-test disclaimers state that "signature mismatches will occur if misaligned accesses can sometimes succeed (without an exception) and sometimes fail on the DUT").
3. **mtval is mandatory in practice for a conformant modern core, and read-only-zero is permitted only in a narrow case.** Per the ratified Machine-Level ISA v1.13: "If the hardware platform specifies that no exceptions set mtval to a nonzero value, then mtval is read-only zero" — i.e., read-only-zero is legal *only* when the platform guarantees no exception sets it informatively, which is false once you have misaligned/illegal traps. The RISC-V Platform Spec goes further: "mtval must not be hardwired to 0 and in all cases must be written with non-zero and zero values as architecturally defined." On your list; correct to include.
4. **The largest gap is `mstatus` + MRET semantics.** Per Machine-Level ISA v1.13: "When executing an xRET instruction, supposing xPP holds the value y, xIE is set to xPIE; the privilege mode is changed to y; xPIE is set to 1; and xPP is set to the least-privileged supported mode (U if U-mode is implemented, else M). If y≠M, xRET also sets MPRV=0." Yours restores only PC. Even with no interrupts, the MIE/MPIE/MPP state machine is exercised by the conformance `privilege` suite.
5. **Four ID CSRs are mandatory-readable**: `mvendorid`, `marchid`, `mimpid`, `mhartid`. They may read zero (except `mhartid`, which must read the correct hart ID, zero for a single-hart core), but they must not trap. `misa` "must be readable in any implementation, but a value of zero can be returned to indicate the misa register has not been implemented."
6. **Unprivileged correctness items commonly missed**: JALR must clear result bit 0; instruction-address-misaligned fires only on *taken* branches/jumps and is reported on the branch instruction (target address in mepc/mtval); HINTs (integer computational ops with rd=x0) must execute as no-ops, not trap; loads to x0 must still take exceptions; minstret must not count trapped instructions.

## Details

### (A) Definitive answer: is your three-item list sufficient?

**No.** Your list — (1) byte/halfword load-store, (2) the two address-misaligned exception causes, (3) mtval — addresses roughly a quarter of what separates your current core from a conformant machine-mode RV32I+Zicsr implementation. It correctly covers the *unprivileged memory* gap and *part* of the trap gap, but omits:

- **The `mstatus` CSR and correct MRET state transition** (biggest single omission).
- **The four machine information CSRs** (`mvendorid`, `marchid`, `mimpid`, `mhartid`) and `misa`.
- **Correct WARL/WLRL/WPRI field behavior** on the CSRs you already have (mtvec BASE alignment + MODE field, mcause legal codes, mepc bit-0/bit-1 hardwiring).
- **Several unprivileged details**: JALR bit-0 clear, taken-branch-only misalignment reporting, HINT no-op execution, FENCE reserved-encoding non-trapping, x0 semantics, minstret not counting excepted instructions.
- **The full synchronous exception cause set and their priority ordering.**
- **The `mcountinhibit` / high-half counter behavior** on RV32.

Honest quantification: your list is **3 of ~12** Phase-1 workstreams.

### (B) The complete Phase-1 checklist, ordered by dependency

**Tier 0 — Unprivileged ISA correctness (do first; cheap and gate everything).**

- **Byte/halfword memory ops.** In a 5-stage pipeline the byte-lane logic lives in the **MEM stage**: an address-low-bits decoder selects which byte lane(s) of the aligned memory word to route; the load result then passes through a sign/zero-extend mux (controlled by funct3[2]) before the writeback mux in **WB**. For stores, a byte-enable/lane-replicate network in MEM generates the write strobes. LB/LH sign-extend from bit 7/15; LBU/LHU zero-extend; SB/SH write only the low 8/16 bits.
- **JALR bit-0 clearing.** The target adder (rs1 + sign-ext imm) must force bit 0 to zero: "The target address is obtained by adding the sign-extended 12-bit I-immediate to the register rs1, then setting the least-significant bit of the result to zero." This lives in the **EX/branch-resolution stage**. Missing it is a classic conformance failure.
- **Taken-branch-only misalignment.** Per the Unprivileged ISA: "An instruction-address-misaligned exception is generated on a taken branch or unconditional jump if the target address is not four-byte aligned. This exception is reported on the branch or jump instruction, not on the target instruction. No instruction-address-misaligned exception is generated for a conditional branch that is not taken." The misaligned *target* address is written to mtval. Detection lives in **EX** (target computation), delivered as a trap in the stage that resolves the branch. (Note: with only RV32I 4-byte instructions and a 4-aligned fetch PC, JALR/JAL/branch targets are the only source of this exception.)
- **HINT no-op semantics.** Per the Unprivileged ISA: "Most RV32I HINTs are encoded as integer computational instructions with rd=x0... 91% of the HINT space is reserved for standard HINTs." Integer-computational encodings with rd=x0 (ADDI x0,x0,0 is the canonical NOP, but *any* such op with rd=x0) are HINTs and must execute as no-ops — they must NOT raise illegal-instruction. Your illegal-instruction logic must treat rd=x0 computational ops as legal-but-inert. Subtle and frequently missed.
- **FENCE / FENCE.TSO.** FENCE (funct3=000) is legal; in a simple in-order single-hart core it may be a NOP. **Reserved FENCE encodings must be *ignored*, not trapped**: per the Unprivileged ISA, "For forward compatibility, base implementations shall ignore these fields, and standard software shall zero these fields... Base implementations shall treat all such reserved configurations as FENCE instructions (with fm=0000)." FENCE.TSO (fm=1000, pred=RW, succ=RW) should decode as legal and may be treated as an ordinary fence/NOP. Zifencei's FENCE.I is a separate extension (may be NOP with no I-cache) and is not part of base RV32I.
- **x0 semantics.** Writes to x0 discarded; reads return 0. Per the ISA, "Loads with a destination of x0 must still raise any exceptions and cause any other side effects even though the load value is discarded." Watch the forwarding path: do not forward a result to a consumer when the producer's rd=x0 (a real bug found in shipping cores such as BlackParrot, where a division bypassed to x0).

**Tier 1 — Exception detection completeness.** The synchronous exception causes an RV32I+Zicsr M-mode core must raise, with their exact mcause codes (Machine-Level ISA v1.13, Table 6):
- 0 — Instruction address misaligned (taken branch/jump targets; **EX** stage)
- 2 — Illegal instruction (you have this; **ID** stage)
- 3 — Breakpoint (EBREAK; you have this)
- 4 — Load address misaligned (**MEM** stage)
- 6 — Store/AMO address misaligned (**MEM** stage)
- 11 — Environment call from M-mode (ECALL; you have this)

Access faults (1 = instruction, 5 = load, 7 = store/AMO) are **optional** and required only if your memory system can actually generate a bus/permission error; if every address in your map is always accessible, you legitimately need not implement them. Page faults (12/13/15) require virtual memory (S-mode) and are out of scope for M-mode-only.

**Exception priority** (needed when several apply to one instruction). Per the ratified Machine-Level ISA v1.13 Table 7, "Synchronous exception priority in decreasing priority order," introduced by: "If an instruction may raise multiple synchronous exceptions, the decreasing priority order of Table 7 indicates which exception is taken and reported in mcause." The ordering (highest → lowest):
1. Instruction address breakpoint (3)
2. Instruction page/access fault during translation (12, 1)
3. Instruction access fault with physical address (1)
4. **Illegal instruction (2)**
5. **Instruction address misaligned (0)**
6. **Environment call (8, 9, 11)**
7. **Environment break (3)**
8. Load/store/AMO address breakpoint (3)
9. Load/store/AMO address misaligned (4, 6) — *optionally here*
10. Load/store page/access faults during translation (13, 15, 5, 7)
11. Load/store/AMO access fault with physical address (5, 7)
12. Load/store/AMO address misaligned (4, 6) — *if not higher priority*

The spec states verbatim: "Load/store/AMO address-misaligned exceptions may have either higher or lower priority than load/store/AMO page-fault and access-fault exceptions" — hence misaligned appears twice, and its relative priority is **implementation-defined**. The spec's rationale: implementations that never support misaligned accesses can raise the misaligned-address exception unconditionally without doing translation/protection checks first. Also note: "Instruction address-misaligned exceptions are raised by control-flow instructions with misaligned targets, rather than by the act of fetching an instruction. Therefore, these exceptions have lower priority than other instruction address exceptions." For your core, the cases that matter: illegal-instruction (ID) is detected well before load/store misalignment (MEM), and ECALL/EBREAK are distinguished from illegal at decode anyway.

**Tier 2 — Trap CSR field semantics (WARL/WLRL/WPRI).**
- **mtval** (0x343): read-write; on a trap, write the faulting address for address-misaligned/access-fault exceptions. "The mtval register can optionally also be used to return the faulting instruction bits on an illegal-instruction exception" (or zero). For EBREAK, "mtval is written with either zero or the virtual address of the instruction" — both legal (Spike writes the PC; Rocket writes 0). For ECALL, 0. For instruction-address-misaligned, mtval = the misaligned *target* address (different from mepc).
- **mepc** (0x341): "When a trap is taken into M-mode, mepc is written with the virtual address of the instruction that ... encountered the exception." Bit 0 hardwired 0 always; since IALIGN=32 for base RV32I (no C extension), **bit 1 is also effectively hardwired 0** (mepc is WARL and may hardwire the low 2 bits). Mask writes to those low bits. Note the ProcessorFuzz finding that some cores wrongly allowed software to modify mepc's low bits — a real conformance bug.
- **mcause** (0x342): WLRL; "only guaranteed to hold supported exception codes." Implement enough bits for your causes, but return the full encoding of any supported value. Interrupt bit (31) = 0 for exceptions.
- **mtvec** (0x305): "must always be implemented, but can contain a read-only value." BASE is 4-byte aligned (low 2 bits are the MODE field). **For Phase 1, MODE=Direct (0) is sufficient and is what the conformance privilege suite requires** — that suite needs "mtvec which is completely writable by the test in machine mode" so it can install its trap handler. Vectored mode (1) is optional and only affects *interrupts* — defer to Phase 2. If unimplemented, the MODE field is WARL and should read back Direct.

**Tier 3 — mstatus and MRET (the big one).**
- Implement `mstatus` (0x300) with at least **MIE (bit 3), MPIE (bit 7), MPP (bits 12:11)**. For an M-mode-only core, MPP is a WARL field that can hold *only* 11 (M) — it may be hardwired to 11, and "any write to mstatus.MPP of an unsupported value will be interpreted as Machine Mode" (per the CV32E20/CVE2 M-mode-only precedent).
- On **trap entry**: MPIE←MIE, MIE←0, MPP←current mode (always M here), mepc←PC of faulting instruction, mcause←cause, mtval←datum, PC←mtvec.BASE.
- On **MRET**: per the ratified rule quoted above — with MPP=M (y=M): **MIE←MPIE; MPIE←1; MPP←least-privileged supported mode (M here, U if U-mode existed); PC←mepc.** MPRV is cleared only if y≠M (N/A without U-mode). Your current MRET restores only PC — this is the fix that unblocks the conformance `privilege` tests.
- `mstatush` (0x310) on RV32: implement as read-only zero for an M-mode-only little-endian core (MBE/SBE/UBE all read-only 0). Must not trap.
- WPRI fields in mstatus must read 0 and ignore writes.

**Tier 4 — Mandatory machine-information CSRs.**
- `mvendorid` (0xF11), `marchid` (0xF12), `mimpid` (0xF13): read-only; may return 0 (0 = non-commercial / not-implemented); must not trap on read; writes raise illegal-instruction (they're read-only). The ProcessorFuzz work found a real bug where BlackParrot failed to raise illegal-instruction on a write to read-only `mhartid` — verify your read-only-write trap path.
- `mhartid` (0xF14): read-only; must return the hart's ID — **0 for a single-hart core**. Must not trap.
- `misa` (0x301): "must be readable in any implementation, but a value of zero can be returned"; better to report MXL=1 (RV32) with the I bit set. WARL.
- You already have `mscratch` (0x340) — fine.

**Tier 5 — Counters (Zicntr / hardware performance monitor).**
- `mcycle`/`mcycleh` (0xB00/0xB80) and `minstret`/`minstreth` (0xB02/0xB82): 64-bit, read-write, split into low/high halves on RV32 ("reads of the mcycleh, minstreth ... CSRs return bits 63-32 ... and writes change only bits 63-32"). You have mcycle/minstret; ensure the **h** high-half CSRs exist and that writes touch only the addressed half. **minstret must NOT increment for instructions that trap**: per the ISA, "As ECALL and EBREAK cause synchronous exceptions, they are not considered to retire, and should not increment the minstret CSR." The same holds for illegal and faulting loads/stores. Note M-mode software must be able to *write* these (a real gem5 bug ignored writes to minstret/mcycle).
- `mhpmcounter3–31` / `mhpmevent3–31` (and their `h` halves): mandatory to *exist* (must not trap) but **may be hardwired read-only zero**. This is the cheap, spec-legal way to satisfy the requirement.
- `mcountinhibit` (0x320): optional — "If the mcountinhibit register is not implemented, the implementation behaves as though the register were set to zero" (counters always run). Implementing it is trivial (CY bit gates mcycle, IR bit gates minstret) but not strictly required for Phase 1.
- `mcounteren` (0x306): required only when U-mode exists — "In harts without U-mode, the mcounteren register should not exist." **M-mode-only ⇒ omit it.**
- User-level shadow counters `cycle`/`time`/`instret` and the `time` CSR / memory-mapped `mtime`: these require U-mode or the timer; **defer to Phase 2**. `time` is a read-only shadow of memory-mapped `mtime`, not an independently-implementable CSR.

**Tier 6 — CSR access-fault correctness (Zicsr).**
- Access to a non-existent CSR ⇒ illegal-instruction ("Reads or writes to a CSR that is not implemented will result in an illegal instruction exception").
- Write (CSRRW, or CSRRS/CSRRC with rs1≠x0) to a read-only CSR ⇒ illegal-instruction.
- **CSRRS/CSRRC with rs1=x0, and CSRRSI/CSRRCI with uimm=0, perform no write.** Per the ratified Zicsr chapter: "For both CSRRS and CSRRC, if rs1=x0, then the instruction will not write to the CSR at all, and so shall not cause any of the side effects that might otherwise occur on a CSR write, nor raise illegal-instruction exceptions on accesses to read-only CSRs." You already have this write-suppression — verify it also suppresses the read-only-CSR trap.
- **CSRRW/CSRRWI with rd=x0 still writes** the CSR but suppresses the read side-effect ("A CSRRW with rs1=x0 will attempt to write zero to the destination CSR").
- Reads of high-half CSRs must work on RV32; on RV64 they'd be reserved (N/A for you).

### (C) Items that look like Phase-1 gaps but belong to Phase 2 (interrupts/privileged)

- **`mie` (0x304) and `mip` (0x344).** No architectural interrupts ⇒ these can wait. Needed the moment you add timer/software/external interrupts. You may stub them as read-write-zero now so software doesn't trap, but full behavior is Phase 2.
- **mstatus.MIE actually gating interrupts.** The bit must exist and be maintained by trap/MRET (Phase 1), but its *effect* (masking async interrupts) is Phase 2.
- **mtvec Vectored mode (MODE=1).** Only affects interrupt dispatch: "When MODE=Vectored, all synchronous exceptions ... cause the pc to be set to the address in the BASE field, whereas interrupts cause the pc to be set to BASE plus four times the interrupt cause number." Direct mode fully satisfies Phase-1 synchronous-exception conformance.
- **WFI (0x10500073).** Not required for base conformance; in Phase 1 you may decode it as a legal NOP (the spec permits WFI to be implemented as a NOP; note it is explicitly "not a HINT" and must not be illegal). Its interrupt-wait behavior is Phase 2.
- **The memory-mapped timer (`mtime`/`mtimecmp`) and the `time` CSR.** Platform/timer feature — Phase 2.
- **medeleg/mideleg.** Per the Privileged change log: "In systems with only M-mode, or with both M-mode and U-mode but without U-mode trap support, the medeleg and mideleg registers now do not exist, whereas previously they returned zero." Do **not** implement them — not a gap at all.
- **PMP, S-mode, U-mode, page faults, mcounteren.** Out of scope entirely for an M-mode-only core.

### Design rationale (professor's notes)

- **Why misaligned support is optional.** Supporting arbitrary misaligned access in hardware needs either two stitched memory accesses or a byte-shifter across word boundaries — expensive in a small core. The ISA lets the *execution environment* decide: handle it (in HW or via invisible trap) or raise a contained/fatal address-misaligned trap. The only hard rule is determinism, which is why the arch-test suite waives trapping cores but not inconsistent ones.
- **Why mtval may be zero.** mtval is an *accelerator*, not a semantic necessity — it saves the trap handler from re-deriving the faulting address/instruction; it "is provided to simplify and accelerate the handling of restartable exceptions." Zero is a sentinel meaning "software, derive it yourself." Modern platform specs nonetheless forbid hardwiring it to zero because it materially speeds up misaligned/access-fault and illegal-instruction handling.
- **Why HINTs exist.** They reserve encoding space (computational ops with rd=x0 produce no architectural effect anyway) for future micro-architectural hints (prefetch, branch-prediction, pause) that older cores can safely ignore as no-ops. Trapping them would break forward compatibility — hence they must execute as no-ops.
- **Why MRET sets MPIE←1.** It "pops" a one-level interrupt-enable stack: MIE takes the pre-trap value (from MPIE), and MPIE resets to 1 so a subsequent return leaves interrupts enabled by default. This one-level stack is why two MRETs in a row leave MIE=1 (as noted in isa-manual issue #882).
- **Why instruction-address-misaligned is reported on the branch, not the target.** Reporting at the source (with the bogus target in mepc/mtval) is safer and easier to debug than faulting mid-fetch at an unaligned PC, and it avoids the class of security bugs (cf. the Intel SYSRET issue) where a return transfers control before the address is validated.

### What the conformance suite actually tests (your practical "done")

RISCOF drives your DUT against a golden reference (Spike/Sail) and compares a memory *signature*. For `rv32i_m`:
- **`I` (base integer)** — every RV32I instruction including LB/LH/LBU/LHU/SB/SH, JALR bit-0, branch behavior.
- **`privilege`** — machine-mode trap behavior. It **requires mtvec be writable** so the test can install its own trap handler; it exercises ECALL/EBREAK, illegal-instruction, the `misalign-[lb|lh|lw|sb|sh|sw]-01.S` tests (which your consistent-trapping core can waive per the documented disclaimers), and CSR read/write semantics including the MRET state machine. This suite is precisely where a PC-only MRET fails.
- **`Zifencei`** — only if you claim it; FENCE.I as NOP is acceptable for a no-cache core.

The `riscv-config` YAML you supply must honestly describe which CSRs/features you implement; the framework selects tests accordingly (e.g., it checks `ISA:=regex(.*I.*Zicsr.*)` and `hw_data_misaligned_support`). Reference cores such as AngeloJacobo's 5-stage RV32I+Zicsr confirm the practical target: "passed the rv32ui ... and rv32mi (RV32 Machine-Mode Integer-Only) tests." **Phase-1 "done" = pass `rv32i_m/I` and `rv32i_m/privilege` with a machine-mode-only, Direct-mtvec, interrupt-free configuration.**

## Recommendations

1. **Fix MRET and add `mstatus` first** (Tier 3). Highest-leverage change; unblocks the entire `privilege` suite. Implement MIE/MPIE/MPP with the trap-entry and MRET transitions above. *Benchmark:* the rv32mi `privilege` MRET/mstatus tests pass.
2. **Then close Tier 0 unprivileged correctness** (byte/halfword ops, JALR bit-0, taken-branch misalignment, HINT no-ops, FENCE reserved-encoding ignore, x0 forwarding). Cheap and each is independently testable. *Benchmark:* `rv32i_m/I` passes.
3. **Add the mandatory ID CSRs and misa** (Tier 4) as read-only registers — an afternoon of work; make sure writes to them raise illegal-instruction. *Benchmark:* CSR-access tests stop trapping on `mhartid`/`mvendorid` reads.
4. **Complete trap CSR field semantics** (Tier 2): mepc low-bit masking, mcause legal codes, mtvec BASE alignment + Direct MODE, mtval population per cause. *Benchmark:* misalign and CSR tests produce matching signatures.
5. **Finish the counters** (Tier 5): add mcycleh/minstreth, make them software-writable, ensure minstret excludes trapped instructions, hardwire mhpmcounter*/mhpmevent* to zero. *Benchmark:* counter CSR tests pass; minstret matches the reference across a trap.
6. **Stand up RISCOF locally** against Sail or Spike with an M-mode, Direct-mtvec, no-interrupt `riscv-config`. Treat green on `rv32i_m/I` + `rv32i_m/privilege` as the Phase-1 exit criterion.
7. **Defer Phase 2** (interrupts: mie/mip, mtvec vectored, WFI wait behavior, mtime/mtimecmp, mstatus.MIE masking) until Phase 1 is green. Threshold to start Phase 2: all Phase-1 suites pass and you want asynchronous event handling.

**Thresholds that change the plan:** If your memory map can generate bus errors, promote access faults (causes 1/5/7) into Phase 1. If you later add the C extension, instruction-address-misaligned becomes impossible (all PCs 2-aligned) and IALIGN=16 changes mepc bit-1 handling. If you add U-mode, `mcounteren`, `medeleg`/`mideleg`, MPP=U semantics, and the user-mode shadow counters all re-enter scope.

## Caveats
- Spec references are to the ratified RISC-V Unprivileged ISA (RV32I v2.1, Zicsr v2.0, Zicntr v2.0) and the ratified Privileged Architecture Machine-Level ISA v1.13, as published in the RISC-V Ratified Specifications Library (version dated 2026-01-20). Chapter/table numbers shift slightly between editions; verify against the exact version you target.
- "Mandatory" here means mandatory *for conformance of a machine-mode-only RV32I+Zicsr hart*. Platform profiles (e.g., RVA/RVM) impose stricter requirements (e.g., mtval must not be hardwired zero, both mtvec modes required) — flagged where the Platform Spec is stricter than the base ISA.
- RISCOF test *coverage* is not exhaustive: passing the arch-tests is necessary but not sufficient for "professional" quality. Directed random testing against Spike/Sail (e.g., riscv-dv) will catch pipeline hazards the arch-tests miss — several real bugs cited here (BlackParrot mepc low-bits, x0 bypass; gem5 minstret writes) were found by fuzzing, not the arch-tests.
- The exact set of CSRs a given RISCOF `privilege` test touches depends on the suite version; treat the checklist as the spec-derived superset and let your `riscv-config` gate what actually runs.
