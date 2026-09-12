#!/usr/bin/env python3
"""
rvtrace.py -- step-and-compare for the rv32i-tlv core.

Normalises an execution trace from the DUT (Verilator testbench) and from a
reference model (Spike commit log) into the same canonical form, then reports
the FIRST point at which they disagree.

Canonical record, per architecturally committed instruction:

    pc    : int          program counter
    insn  : int          32-bit encoding
    rd    : (n, val)     integer register write, or None
    mem   : (sz, a, v)   memory *write*, or None
    trap  : (cause,tval) taken exception instead of a retirement, or None

Why this and not a signature diff: a signature comparison tells you the final
memory image differs.  A trace comparison tells you which instruction first
behaved differently, which is the thing you actually need in order to debug.
"""

import argparse
import re
import subprocess
import sys

# --------------------------------------------------------------------------
# Spike exception names -> mcause values (RISC-V privileged spec, table 3.6)
# --------------------------------------------------------------------------
SPIKE_CAUSE = {
    "trap_instruction_address_misaligned": 0,
    "trap_instruction_access_fault":       1,
    "trap_illegal_instruction":            2,
    "trap_breakpoint":                     3,
    "trap_load_address_misaligned":        4,
    "trap_load_access_fault":              5,
    "trap_store_address_misaligned":       6,
    "trap_store_access_fault":             7,
    "trap_user_ecall":                     8,
    "trap_supervisor_ecall":               9,
    "trap_machine_ecall":                 11,
}
CAUSE_NAME = {v: k for k, v in SPIKE_CAUSE.items()}


class Rec:
    __slots__ = ("pc", "insn", "rd", "mem", "trap")

    def __init__(self, pc, insn, rd=None, mem=None, trap=None):
        self.pc, self.insn, self.rd, self.mem, self.trap = pc, insn, rd, mem, trap

    def key(self):
        """The tuple that must match between DUT and reference."""
        return (self.pc, self.insn, self.rd, self.mem, self.trap)

    def __str__(self):
        if self.trap is not None:
            c, t = self.trap
            return "%08x %-8s TRAP cause=%d (%s) tval=%08x" % (
                self.pc, "", c, CAUSE_NAME.get(c, "?"), t)
        s = "%08x %08x" % (self.pc, self.insn)
        if self.rd:
            s += "  x%-2d=%08x" % self.rd
        if self.mem:
            sz, a, v = self.mem
            s += "  m%d[%08x]=%0*x" % (sz, a, sz * 2, v)
        return s


def mask(sz):
    return (1 << (8 * sz)) - 1


# --------------------------------------------------------------------------
# Spike log  ->  records
# --------------------------------------------------------------------------
# commit:    core   0: 3 0x00001000 (0x12300093) x1  0x00000123
# store:     core   0: 3 0x0000100c (0x00112023) mem 0x00001080 0x00000123
# load:      core   0: 3 0x00001010 (0x00012183) x3  0x00000123 mem 0x00001080
# exception: core   0: exception trap_load_address_misaligned, epc 0x0000104c
#            core   0:           tval 0x00001081

RE_COMMIT = re.compile(
    r"^core\s+\d+:\s+\d+\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)\s*(.*)$")
RE_EXC = re.compile(r"^core\s+\d+:\s+exception\s+(\S+?),\s+epc\s+0x([0-9a-f]+)")
RE_TVAL = re.compile(r"^core\s+\d+:\s+tval\s+0x([0-9a-f]+)")
RE_XREG = re.compile(r"^x(\d+)\s+0x([0-9a-f]+)")
RE_MEM = re.compile(r"^mem\s+0x([0-9a-f]+)(?:\s+0x([0-9a-f]+))?")


def parse_spike(path):
    recs = []
    pending_trap = None
    for line in open(path, errors="replace"):
        line = line.strip()

        m = RE_EXC.match(line)
        if m:
            cause = SPIKE_CAUSE.get(m.group(1))
            if cause is None:
                sys.stderr.write("warning: unknown spike trap %r\n" % m.group(1))
                cause = -1
            pending_trap = Rec(int(m.group(2), 16), 0, trap=(cause, 0))
            recs.append(pending_trap)
            continue

        m = RE_TVAL.match(line)
        if m and pending_trap is not None:
            pending_trap.trap = (pending_trap.trap[0], int(m.group(1), 16))
            pending_trap = None
            continue

        m = RE_COMMIT.match(line)
        if not m:
            continue
        pending_trap = None
        pc, insn, rest = int(m.group(1), 16), int(m.group(2), 16), m.group(3).strip()

        rd = memw = None
        while rest:
            mx = RE_XREG.match(rest)
            if mx:
                n, v = int(mx.group(1)), int(mx.group(2), 16)
                if n != 0:                      # x0 writes are architecturally void
                    rd = (n, v)
                rest = rest[mx.end():].strip()
                continue
            mm = RE_MEM.match(rest)
            if mm:
                # "mem <addr> <val>" is a store; "mem <addr>" alone is a load's
                # read address, which the DUT does not trace.
                if mm.group(2) is not None:
                    hexdigits = len(mm.group(2))
                    sz = max(1, (hexdigits + 1) // 2)
                    sz = 1 if sz <= 1 else (2 if sz <= 2 else 4)
                    memw = (sz, int(mm.group(1), 16), int(mm.group(2), 16) & mask(sz))
                rest = rest[mm.end():].strip()
                continue
            break                                # CSR writes etc. -- ignored for now
        recs.append(Rec(pc, insn, rd, memw))
    return recs


# --------------------------------------------------------------------------
# DUT trace  ->  records
# --------------------------------------------------------------------------
RE_DUT = re.compile(
    r"^([0-9a-f]{8}) ([0-9a-f]{8})"
    r"(?: x(\d+)=([0-9a-f]{8}))?"
    r"(?: m(\d+)\[([0-9a-f]{8})\]=([0-9a-f]{8}))?\s*$")
RE_DUT_TRAP = re.compile(r"^TRAP ([0-9a-f]{8}) ([0-9a-f]{8}) ([0-9a-f]{8})\s*$")


def parse_dut(path, skip_below=0):
    recs = []
    for line in open(path, errors="replace"):
        line = line.rstrip()
        m = RE_DUT_TRAP.match(line)
        if m:
            pc = int(m.group(1), 16)
            if pc >= skip_below:
                recs.append(Rec(pc, 0,
                                trap=(int(m.group(2), 16), int(m.group(3), 16))))
            continue
        m = RE_DUT.match(line)
        if not m:
            if line:
                sys.stderr.write("warning: unparsed DUT line %r\n" % line)
            continue
        pc = int(m.group(1), 16)
        if pc < skip_below:                      # the synthetic reset-vector jump
            continue
        rd = None
        if m.group(3) is not None:
            n, v = int(m.group(3)), int(m.group(4), 16)
            if n != 0:
                rd = (n, v)
        memw = None
        if m.group(5) is not None:
            sz = int(m.group(5))
            memw = (sz, int(m.group(6), 16), int(m.group(7), 16) & mask(sz))
        recs.append(Rec(pc, m and int(m.group(2), 16), rd, memw))
    return recs


# --------------------------------------------------------------------------
# Trim a trace at the first self-loop (pc repeats), which is how both the DUT
# testbench and every test's RVMODEL_HALT signal "done".  Applying the same
# rule to both sides keeps termination symmetric.
# --------------------------------------------------------------------------
def zero_ref_tval(ref, causes):
    """Account for an implementation-defined mtval choice.

    The privileged spec makes mtval on an illegal-instruction exception
    optional: "The mtval register can optionally also be used to return the
    faulting instruction bits."  Spike returns the instruction bits; this core
    returns 0.  Both are conformant, so the comparison must not treat the
    difference as a bug -- exactly like Spike's --priv=m setting.

    Only the REFERENCE side is rewritten.  The DUT's value is left alone and
    still has to equal 0, so a DUT that starts writing something unexpected is
    still caught rather than silently excused.
    """
    for r in ref:
        if r.trap is not None and r.trap[0] in causes:
            r.trap = (r.trap[0], 0)
    return ref


def trim_halt_store(recs, addr):
    """Cut both traces after the first store to `tohost`.

    The self-loop rule below does not fire on riscv-dv programs, whose
    write_tohost is a three-instruction loop rather than a `j .`, so the pc
    never repeats on consecutive commits.  A store to tohost is the standard
    bare-metal "test is over" signal and gives both sides one stopping point.
    """
    if addr is None:
        return recs
    for i, r in enumerate(recs):
        if r.mem and r.mem[1] == addr:
            return recs[:i + 1]
    return recs


def trim_selfloop(recs):
    for i in range(1, len(recs)):
        if recs[i].pc == recs[i - 1].pc and recs[i].trap is None:
            return recs[:i]
    return recs


# --------------------------------------------------------------------------
# Disassembly, for readable reports.  Taken from objdump so it cannot disagree
# with the toolchain.
# --------------------------------------------------------------------------
def load_disasm(elf, objdump):
    if not elf:
        return {}
    try:
        out = subprocess.run([objdump, "-d", "--no-show-raw-insn", elf],
                             capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        sys.stderr.write("warning: objdump failed (%s)\n" % e)
        return {}
    d = {}
    for line in out.splitlines():
        m = re.match(r"^\s*([0-9a-f]+):\s+(.*?)\s*$", line)
        if m:
            d[int(m.group(1), 16)] = re.sub(r"\s+", " ", m.group(2))
    return d


def show(idx, r, dis):
    if r is None:
        return "  %5s  <end of trace>" % idx
    return "  %5s  %s   %s" % (idx, r, dis.get(r.pc, ""))


def why(a, b):
    """Human-readable classification of the first difference."""
    if a is None:
        return "reference retired more instructions than the DUT (DUT stopped early)"
    if b is None:
        return "DUT retired more instructions than the reference"
    if a.pc != b.pc:
        return ("control flow diverged: reference went to %08x, DUT went to %08x"
                % (a.pc, b.pc))
    if (a.trap is None) != (b.trap is None):
        return ("reference %s at this pc, DUT %s"
                % ("trapped" if a.trap else "retired",
                   "trapped" if b.trap else "retired"))
    if a.trap is not None and b.trap is not None:
        if a.trap[0] != b.trap[0]:
            return ("trap cause differs: reference=%d (%s), DUT=%d (%s)"
                    % (a.trap[0], CAUSE_NAME.get(a.trap[0], "?"),
                       b.trap[0], CAUSE_NAME.get(b.trap[0], "?")))
        return "trap tval differs: reference=%08x, DUT=%08x" % (a.trap[1], b.trap[1])
    if a.insn != b.insn:
        return ("fetched a different instruction: reference=%08x, DUT=%08x "
                "(instruction memory or fetch path problem)" % (a.insn, b.insn))
    if a.rd != b.rd:
        if a.rd and b.rd and a.rd[0] == b.rd[0]:
            return ("wrong result written to x%d: reference=%08x, DUT=%08x"
                    % (a.rd[0], a.rd[1], b.rd[1]))
        return ("register writeback differs: reference=%s, DUT=%s"
                % (("x%d=%08x" % a.rd) if a.rd else "none",
                   ("x%d=%08x" % b.rd) if b.rd else "none"))
    if a.mem != b.mem:
        f = lambda m: "m%d[%08x]=%0*x" % (m[0], m[1], m[0] * 2, m[2]) if m else "none"
        return "memory write differs: reference=%s, DUT=%s" % (f(a.mem), f(b.mem))
    return "records differ"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("spike_log")
    ap.add_argument("dut_trace")
    ap.add_argument("--elf", help="ELF, used to annotate the report with disassembly")
    ap.add_argument("--objdump", default="riscv32-unknown-elf-objdump")
    ap.add_argument("--skip-below", type=lambda s: int(s, 0), default=0,
                    help="drop DUT records below this pc (the reset-vector stub)")
    ap.add_argument("--tval-zero-causes", default="",
                    help="comma-separated mcause values for which this "
                         "implementation legitimately writes mtval=0; the "
                         "reference's tval is zeroed to match (the DUT's is not)")
    ap.add_argument("--halt-store", type=lambda s: int(s, 0), default=None,
                    help="stop both traces after the first store to this "
                         "address (normally the tohost symbol)")
    ap.add_argument("--context", type=int, default=6)
    ap.add_argument("--name", default="")
    ap.add_argument("--quiet", action="store_true",
                    help="print one PASS/FAIL line only")
    args = ap.parse_args()

    tvz = {int(c) for c in args.tval_zero_causes.split(",") if c.strip()}
    ref = trim_selfloop(trim_halt_store(zero_ref_tval(parse_spike(args.spike_log), tvz),
                                        args.halt_store))
    dut = trim_selfloop(trim_halt_store(parse_dut(args.dut_trace, args.skip_below),
                                        args.halt_store))
    dis = load_disasm(args.elf, args.objdump)
    tag = args.name or args.dut_trace

    if not ref:
        print("FAIL %s : reference model produced no committed instructions" % tag)
        return 2
    if not dut:
        print("FAIL %s : DUT produced no committed instructions" % tag)
        return 2

    n = min(len(ref), len(dut))
    bad = None
    for i in range(n):
        if ref[i].key() != dut[i].key():
            bad = i
            break
    if bad is None and len(ref) != len(dut):
        bad = n

    if bad is None:
        print("PASS %s : %d instructions matched" % (tag, len(ref)))
        return 0

    print("FAIL %s : diverged at committed instruction #%d of %d(ref)/%d(dut)"
          % (tag, bad, len(ref), len(dut)))
    if args.quiet:
        return 1

    a = ref[bad] if bad < len(ref) else None
    b = dut[bad] if bad < len(dut) else None
    print("       %s" % why(a, b))
    lo = max(0, bad - args.context)
    print()
    print("  --- last %d matching instructions ---" % (bad - lo))
    for i in range(lo, bad):
        print(show(i, ref[i], dis))
    print()
    print("  --- first divergence ---")
    print("  REF" + show(bad, a, dis)[3:])
    print("  DUT" + show(bad, b, dis)[3:])
    print()
    print("  --- what each side did next ---")
    for i in range(bad + 1, min(bad + 1 + args.context, max(len(ref), len(dut)))):
        print("  REF" + show(i, ref[i] if i < len(ref) else None, dis)[3:])
        print("  DUT" + show(i, dut[i] if i < len(dut) else None, dis)[3:])
    return 1


if __name__ == "__main__":
    sys.exit(main())
