#!/usr/bin/env python3
"""
unaligned_test.py -- constrained-random RV32I generator that exercises the
                     misaligned-access and trap paths.

THIS IS NOT REDUNDANT WITH riscv-dv.  The two generators cover different
ground, and the split is deliberate:

  riscv-dv        never emits a misaligned access, because the rv32i_tlv target
                  correctly sets support_unaligned_load_store = 0 -- this core
                  really does trap on unaligned load/store.  Across 64 riscv-dv
                  programs the only exception cause reached is 11 (the
                  terminating ecall).
  this generator  emits misaligned loads and stores on purpose (--misalign-pct,
                  default 8%) plus ecall/ebreak, and installs a handler that
                  skips the faulting instruction so one trap does not end the
                  run.  Across 30 programs it reaches causes 3, 4, 6 and 11.

So the riscv-dv target flag stays at its honest value and this file closes the
gap.  Do not "fix" one by changing the other.

Beyond traps, random generation is also how you reach microarchitectural bugs
generally: directed suites like riscv-arch-test check that each instruction
computes the right answer in isolation, but a bug in forwarding, hazard
detection or branch prediction only shows up in a particular *sequence*.

The one design decision that makes or breaks a generator like this: operands
must be BIASED TOWARDS RECENT DESTINATIONS.  With 32 registers picked
uniformly, two adjacent instructions collide about 3% of the time, so a
uniform generator almost never builds the back-to-back dependency chains that
exercise a forwarding network.  Here roughly half of all source operands are
drawn from the last few destination registers, which turns the stream into a
dense mesh of RAW hazards at every pipeline distance.

Constraints that keep the program legal and terminating:
  x31   reserved as the data base pointer, never written
  x30   reserved as trap-handler scratch, never written
  branches and jumps only ever go FORWARD, so the program cannot loop
  every load/store addresses x31 + [0, DATA_SIZE), so it cannot escape memory
  a trap handler skips the faulting instruction, so misaligned accesses and
  ecall/ebreak exercise the trap path without ending the run
"""

import argparse
import random

MEMBASE = 31
SCRATCH = 30
DATA_SIZE = 2048

# Values chosen to sit on the boundaries where sign, carry and shift bugs live.
CORNERS = [0, 1, -1, 2, -2, 0x7FFFFFFF, -0x80000000, 0xFFFF0000 - (1 << 32),
           0x0000FFFF, 0x55555555, 0xAAAAAAAA - (1 << 32), 0x7FF, -0x800,
           0x80000000 - (1 << 32), 4, 8, 31, 32]

RR = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
RI = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SH = ["slli", "srli", "srai"]
BR = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
LD = [("lw", 4), ("lh", 2), ("lhu", 2), ("lb", 1), ("lbu", 1)]
ST = [("sw", 4), ("sh", 2), ("sb", 1)]


class Gen:
    def __init__(self, rng, n, misalign_pct, trap_pct):
        self.rng = rng
        self.n = n
        self.misalign_pct = misalign_pct
        self.trap_pct = trap_pct
        self.recent = []            # recently written destination registers

    def rd(self):
        r = self.rng.randrange(0, SCRATCH)      # x0..x29
        self.recent.append(r)
        del self.recent[:-6]
        return r

    def rs(self):
        # The whole point: prefer a register some nearby instruction just wrote.
        if self.recent and self.rng.random() < 0.55:
            return self.rng.choice(self.recent)
        return self.rng.randrange(0, 32)

    def imm(self):
        if self.rng.random() < 0.4:
            v = self.rng.choice(CORNERS)
            return max(-2048, min(2047, v))
        return self.rng.randrange(-2048, 2048)

    def offset(self, align):
        off = self.rng.randrange(0, DATA_SIZE - 8) & ~(align - 1)
        if align > 1 and self.rng.random() * 100 < self.misalign_pct:
            off += self.rng.randrange(1, align)   # deliberately misaligned
        return off

    def target(self, i):
        """A label strictly ahead of slot i, so control flow always advances."""
        return min(i + self.rng.randrange(1, 9), self.n)

    def instruction(self, i):
        r = self.rng.random()
        if r < 0.30:
            return "%-6s x%d, x%d, x%d" % (self.rng.choice(RR), self.rd(),
                                           self.rs(), self.rs())
        if r < 0.48:
            return "%-6s x%d, x%d, %d" % (self.rng.choice(RI), self.rd(),
                                          self.rs(), self.imm())
        if r < 0.55:
            return "%-6s x%d, x%d, %d" % (self.rng.choice(SH), self.rd(),
                                          self.rs(), self.rng.randrange(0, 32))
        if r < 0.62:
            return "lui    x%d, %d" % (self.rd(), self.rng.randrange(0, 1 << 20))
        if r < 0.66:
            return "auipc  x%d, %d" % (self.rd(), self.rng.randrange(0, 1 << 20))
        if r < 0.78:
            op, al = self.rng.choice(LD)
            return "%-6s x%d, %d(x%d)" % (op, self.rd(), self.offset(al), MEMBASE)
        if r < 0.88:
            op, al = self.rng.choice(ST)
            return "%-6s x%d, %d(x%d)" % (op, self.rs(), self.offset(al), MEMBASE)
        if r < 0.96:
            return "%-6s x%d, x%d, L%d" % (self.rng.choice(BR), self.rs(),
                                           self.rs(), self.target(i))
        if r < 0.98:
            return "jal    x%d, L%d" % (self.rd(), self.target(i))
        if r < 0.99:
            # jalr needs a computed target; x30 is reserved so clobbering is safe
            return "la     x%d, L%d\n        jalr   x%d, 0(x%d)" % (
                SCRATCH, self.target(i), self.rd(), SCRATCH)
        if self.rng.random() * 100 < self.trap_pct:
            return self.rng.choice(["ecall", "ebreak"])
        return "csrrw  x%d, mscratch, x%d" % (self.rd(), self.rs())

    def emit(self):
        out = []
        w = out.append
        w("# generated by verif/unaligned_test.py -- constrained-random RV32I")
        w("        .option norvc")
        w("        .section .text.init")
        w("        .globl _start")
        w("_start:")
        w("        la     x%d, ut_handler" % SCRATCH)
        w("        csrw   mtvec, x%d" % SCRATCH)
        w("        la     x%d, ut_data" % MEMBASE)
        for r in range(1, SCRATCH):
            w("        li     x%d, %d" % (r, self.rng.choice(CORNERS)
                                          if self.rng.random() < 0.5
                                          else self.rng.randrange(-(1 << 31), 1 << 31)))
        w("")
        for i in range(self.n):
            w("L%d:     %s" % (i, self.instruction(i)))
        w("L%d:" % self.n)
        w("        j      .")
        w("")
        # Skip the faulting instruction and resume, so one trap does not end
        # the program.  Both models execute this identically.
        w("        .align 4")
        w("ut_handler:")
        w("        csrr   x%d, mepc" % SCRATCH)
        w("        addi   x%d, x%d, 4" % (SCRATCH, SCRATCH))
        w("        csrw   mepc, x%d" % SCRATCH)
        w("        mret")
        w("")
        w("        .section .data")
        w("        .align 4")
        w("ut_data:")
        w("        .fill %d, 4, 0" % (DATA_SIZE // 4))
        return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("-n", "--count", type=int, default=400,
                    help="number of random instructions")
    ap.add_argument("--misalign-pct", type=float, default=8.0)
    ap.add_argument("--trap-pct", type=float, default=40.0)
    ap.add_argument("-o", "--out")
    args = ap.parse_args()

    text = Gen(random.Random(args.seed), args.count,
               args.misalign_pct, args.trap_pct).emit()
    if args.out:
        open(args.out, "w").write(text)
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
