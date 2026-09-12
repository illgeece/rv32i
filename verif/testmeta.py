#!/usr/bin/env python3
"""
testmeta.py -- read the RVTEST_CASE metadata out of a riscv-arch-test source.

Every arch-test carries its own build requirements inline, e.g.

  RVTEST_CASE(1,"//check ISA:=regex(.*32.*); check ISA:=regex(.*I.*Zicsr.*); \\
                 def rvtest_mtrap_routine=True; def TEST_CASE_1=True",ecall)

Two things live in there:

  check ISA:=regex(RE)   the test only applies to a core whose ISA string
                         matches RE.  A core without the C extension must not
                         be judged by a test that assembles compressed
                         instructions.
  def NAME=VALUE         a macro the test needs on the command line.  Miss one
                         and the test silently assembles into something else --
                         omitting rvtest_mtrap_routine, for instance, drops the
                         trap handler entirely and leaves mtvec at 0.

This is the part of RISCOF's job that actually matters for correctness, in
about forty lines instead of a framework.

exit 0 : applicable; prints the -D flags on stdout
exit 1 : not applicable; prints the reason on stderr
"""

import argparse
import re
import sys

RE_CASE = re.compile(r'RVTEST_CASE\s*\(\s*\d+\s*,\s*"(.*?)"\s*,', re.S)
RE_ISA = re.compile(r'check\s+ISA\s*:=\s*regex\(([^)]*)\)')
RE_DEF = re.compile(r'def\s+([A-Za-z_]\w*)\s*=\s*([^\s;"]+)')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("test")
    ap.add_argument("--isa", default="RV32IZicsr")
    args = ap.parse_args()

    try:
        src = open(args.test, errors="replace").read()
    except OSError as e:
        sys.stderr.write("cannot read %s: %s\n" % (args.test, e))
        return 2

    # Line continuations inside the metadata string must go before matching.
    src = src.replace("\\\n", " ")

    bodies = RE_CASE.findall(src)
    if not bodies:
        print("")                       # plain test, no metadata, always build
        return 0

    defs, seen = [], set()
    for body in bodies:
        for pat in RE_ISA.findall(body):
            try:
                if not re.search(pat, args.isa):
                    sys.stderr.write(
                        "requires ISA matching %r, core is %s\n" % (pat, args.isa))
                    return 1
            except re.error:
                sys.stderr.write("warning: bad ISA regex %r, ignoring\n" % pat)
        for name, val in RE_DEF.findall(body):
            if name not in seen:
                seen.add(name)
                defs.append("-D%s=%s" % (name, val))

    print(" ".join(defs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
