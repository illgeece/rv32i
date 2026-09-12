# Directed test for the roadmap.md requirements that nothing else in the
# regression reaches.  Measured holes this closes:
#
#   Tier 1  cause 0 (instruction-address-misaligned) -- never raised by any
#           other source, because arch-test's misalign-* tests are skipped
#           (they need the C extension and assert the opposite behaviour)
#   Tier 1  cause 2 (illegal instruction) -- never raised by any other source
#   Tier 6  csrrwi / csrrsi / csrrci / csrrc -- never executed anywhere else,
#           leaving the $csr_src immediate mux and the "& ~" clear path unverified
#   Tier 6  write to a read-only CSR, and access to a non-existent CSR
#   Tier 6  CSRRS/CSRRC with rs1=x0 (and the -I forms with uimm=0) must suppress
#           the write AND the read-only trap
#   Tier 5  minstret must not count an instruction that traps
#   Tier 2  mepc low bits are hardwired 0 (IALIGN=32, no C extension)
#   Tier 0  reserved FENCE encodings must be ignored, not trapped
#
# x30/x31 are reserved for the trap handler and must not be used below.

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      x30, trap_handler
        csrw    mtvec, x30

# --- Tier 6: the four Zicsr instructions no other test executes ------------
        li      x1, 0x0F0F0F0F
        csrw    mscratch, x1        # CSRRW with rd=x0 still writes
        csrrwi  x2, mscratch, 21     # reads 0x0F0F0F0F, writes 21
        csrrsi  x3, mscratch, 10     # reads 21,  sets bits  -> 31
        csrrci  x4, mscratch, 3      # reads 31,  clears     -> 28
        li      x5, 0xFF
        csrrc   x6, mscratch, x5     # reads 28,  clears 0xFF -> 0
        csrrs   x7, mscratch, x5     # reads 0,   sets 0xFF   -> 0xFF

# --- Tier 6: rs1=x0 / uimm=0 must suppress the write entirely --------------
        csrrsi  x8, mscratch, 0      # no write
        csrrci  x9, mscratch, 0      # no write
        csrrc   x10, mscratch, x0    # no write
        csrr    x11, mscratch        # must still read 0xFF

# --- Tier 6: read-only CSRs -----------------------------------------------
        csrrs   x12, mvendorid, x0   # rs1=x0 -> no write -> must NOT trap
        csrrsi  x13, mhartid, 0      # uimm=0 -> no write -> must NOT trap
                                     # (mhartid, not marchid: marchid is an
                                     #  implementation-defined value -- Spike
                                     #  reports 5, this core legally reports 0.
                                     #  mhartid must be 0 for a single hart, so
                                     #  it is comparable across models.)
        csrrw   x14, mvendorid, x1   # write to read-only -> illegal (cause 2)
        csrrwi  x15, mimpid, 7       # write to read-only -> illegal (cause 2)

# --- Tier 6: non-existent CSR ---------------------------------------------
        csrr    x16, 0xbc0           # unallocated -> illegal (cause 2)

# --- Tier 1 cause 2: illegal encodings ------------------------------------
        .word   0x00000000           # all zeros
        .word   0xffffffff           # all ones

# --- Tier 1 cause 0: instruction-address-misaligned -----------------------
# Branch and jump immediates always have bit 0 clear, so a target can still be
# 2 mod 4 -- misaligned for IALIGN=32.  Reported on the branch, not the target.
        li      x17, 2
        jalr    x18, 0(x17)          # target (2 & ~1) = 2 -> misaligned
        .word   0x0020006f           # jal x0, +2  -> misaligned target
        .word   0x00000163           # beq x0,x0,+2 (taken) -> misaligned target

# --- Tier 0: reserved FENCE encodings are ignored, not trapped ------------
        fence
        .word   0x8330000f           # FENCE.TSO (fm=1000)
        .word   0x5ab0000f           # reserved fm/pred/succ -> treat as FENCE

# --- Tier 2: mepc low bits hardwired 0 on a software write ---------------
        li      x19, 0xfffffffe
        csrw    mepc, x19
        csrr    x20, mepc            # low 2 bits must read back 0

# --- Tier 5: minstret must not count an instruction that traps -----------
# Absolute counter values differ between a pipeline and an ISS, but the DELTA
# across a fixed instruction sequence must match exactly -- which lets the GPR
# comparison check a counter property the CSR trace cannot.
# Zeroing first is what makes this comparable at all: the DUT retires one extra
# instruction the reference never sees (the reset-vector stub the testbench
# plants at pc 0), so raw counter values are permanently off by one.  The write
# also covers the roadmap's "M-mode software must be able to write these".
        csrw    minstret, x0
        csrr    x21, minstret
        .word   0x00000000           # illegal: traps, so must not retire
        csrr    x22, minstret
        sub     x23, x22, x21

done:   j       done

        .align  4
trap_handler:
        csrr    x30, mepc
        addi    x30, x30, 4          # skip the faulting instruction
        csrw    mepc, x30
        mret
