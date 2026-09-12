#!/usr/bin/env python3
"""
coverage.py -- what did the regression actually exercise?

usage:  python3 verif/coverage.py verif/work

A green regression measures the tests, not the core.  This reads every
dut.trace under the given directory and reports two things the "68 passed"
line cannot tell you:

  * which RV32I+Zicsr instructions were executed at least once
  * which of the six mandatory synchronous exception causes were actually
    raised (roadmap.md Tier 1)

Note on ecall/ebreak: a trapping instruction never retires, so it never
appears in the retirement trace as an executed instruction.  They are counted
here from their TRAP records instead -- getting this wrong makes them look
uncovered when they are not.
"""

import collections
import glob
import sys

# name -> (opcode, funct3 or None, funct7 or None)
R = {}


def add(n, op, f3=None, f7=None):
    R[n] = (op, f3, f7)


for n, f3 in [("beq", 0), ("bne", 1), ("blt", 4), ("bge", 5),
              ("bltu", 6), ("bgeu", 7)]:
    add(n, 0b1100011, f3)
for n, f3 in [("lb", 0), ("lh", 1), ("lw", 2), ("lbu", 4), ("lhu", 5)]:
    add(n, 0b0000011, f3)
for n, f3 in [("sb", 0), ("sh", 1), ("sw", 2)]:
    add(n, 0b0100011, f3)
for n, f3 in [("addi", 0), ("slti", 2), ("sltiu", 3), ("xori", 4),
              ("ori", 6), ("andi", 7)]:
    add(n, 0b0010011, f3)
add("slli", 0b0010011, 1, 0)
add("srli", 0b0010011, 5, 0)
add("srai", 0b0010011, 5, 0b0100000)
add("add", 0b0110011, 0, 0)
add("sub", 0b0110011, 0, 0b0100000)
add("sll", 0b0110011, 1, 0)
add("slt", 0b0110011, 2, 0)
add("sltu", 0b0110011, 3, 0)
add("xor", 0b0110011, 4, 0)
add("srl", 0b0110011, 5, 0)
add("sra", 0b0110011, 5, 0b0100000)
add("or", 0b0110011, 6, 0)
add("and", 0b0110011, 7, 0)
add("lui", 0b0110111)
add("auipc", 0b0010111)
add("jal", 0b1101111)
add("jalr", 0b1100111, 0)
add("fence", 0b0001111, 0)
for n, f3 in [("csrrw", 1), ("csrrs", 2), ("csrrc", 3),
              ("csrrwi", 5), ("csrrsi", 6), ("csrrci", 7)]:
    add(n, 0b1110011, f3)

WHOLE = {"mret": 0x30200073}          # retires, so visible in the trace
# ecall/ebreak trap instead of retiring; counted from TRAP records by cause
TRAP_INSTR = {"ecall": 11, "ebreak": 3}

# roadmap.md Tier 1: the causes an RV32I+Zicsr M-mode core must raise
MANDATORY = {
    0:  "instruction address misaligned",
    2:  "illegal instruction",
    3:  "breakpoint (EBREAK)",
    4:  "load address misaligned",
    6:  "store address misaligned",
    11: "environment call from M-mode",
}


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "verif/work"
    files = glob.glob(root + "/*/dut.trace")
    if not files:
        sys.stderr.write("no traces under %s -- run a regression first\n" % root)
        return 2

    seen = collections.Counter()
    causes = collections.Counter()
    retired = 0

    for fn in files:
        for line in open(fn, errors="replace"):
            if line.startswith("TRAP"):
                p = line.split()
                if len(p) >= 3:
                    causes[int(p[2], 16)] += 1
                continue
            p = line.split()
            if len(p) < 2:
                continue
            try:
                i = int(p[1], 16)
            except ValueError:
                continue
            retired += 1
            for n, w in WHOLE.items():
                if i == w:
                    seen[n] += 1
            op, f3, f7 = i & 0x7f, (i >> 12) & 7, (i >> 25) & 0x7f
            for n, (o, e3, e7) in R.items():
                if op == o and (e3 is None or f3 == e3) and (e7 is None or f7 == e7):
                    seen[n] += 1

    for n, c in TRAP_INSTR.items():
        seen[n] += causes.get(c, 0)

    all_names = set(R) | set(WHOLE) | set(TRAP_INSTR)
    miss = sorted(n for n in all_names if not seen[n])

    print("traces          : %d" % len(files))
    print("retired instrs  : %d" % retired)
    print("instr coverage  : %d / %d" % (len(all_names) - len(miss), len(all_names)))
    if miss:
        print("NEVER EXECUTED  : " + ", ".join(miss))
    print()
    print("mandatory exception causes (roadmap.md Tier 1):")
    for c in sorted(MANDATORY):
        n = causes.get(c, 0)
        print("   %-4s %-32s %s" % (c, MANDATORY[c],
                                    ("%d raised" % n) if n else "*** NEVER RAISED ***"))
    other = sorted(set(causes) - set(MANDATORY))
    if other:
        print("   other causes seen: " + ", ".join(str(c) for c in other))
    print()
    print("least-exercised instructions:")
    for n, c in sorted(((n, seen[n]) for n in all_names if seen[n]),
                       key=lambda kv: kv[1])[:10]:
        print("   %-8s %d" % (n, c))

    return 1 if (miss or any(c not in causes for c in MANDATORY)) else 0


if __name__ == "__main__":
    sys.exit(main())
