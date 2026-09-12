#!/bin/bash
# ---------------------------------------------------------------------------
# regress.sh -- run cosim.sh over a set of tests and summarise.
#
# usage:
#   verif/regress.sh verif/tests                       # directed tests
#   verif/regress.sh --arch I                          # riscv-arch-test group
#   verif/regress.sh --arch I privilege                # several groups
#   verif/regress.sh path/to/one.S path/to/two.S
#
# env:
#   JOBS       parallel jobs                  (default: nproc)
#   ARCHTEST   riscv-arch-test checkout       (default ~/riscv-arch-test)
#   MODELENV   dir holding model_test.h       (default verif/env)
# ---------------------------------------------------------------------------
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
JOBS="${JOBS:-$(nproc)}"
ARCHTEST="${ARCHTEST:-$HOME/riscv-arch-test}"
MODELENV="${MODELENV:-$ROOT/verif/env}"

EXTRA=()
FILES=()

if [ "${1:-}" = "--arch" ]; then
   shift
   EXTRA=(-I "$ARCHTEST/riscv-test-suite/env" -I "$MODELENV" -DXLEN=32)
   for grp in "$@"; do
      while IFS= read -r f; do FILES+=("$f"); done \
         < <(find "$ARCHTEST/riscv-test-suite/rv32i_m/$grp/src" -name '*.S' | sort)
   done
else
   for a in "$@"; do
      if [ -d "$a" ]; then
         while IFS= read -r f; do FILES+=("$f"); done \
            < <(find "$a" -name '*.s' -o -name '*.S' | sort)
      else
         FILES+=("$a")
      fi
   done
fi

if [ ${#FILES[@]} -eq 0 ]; then echo "no tests found"; exit 2; fi

RESULTS="$ROOT/verif/work/results.txt"
mkdir -p "$ROOT/verif/work"
: > "$RESULTS"

# cosim.sh writes the full report into its own work dir; we surface line 1.
run_one() {
   local t="$1"; shift
   bash "$HERE/cosim.sh" "$t" "$@" 2>&1 | sed -n '1p'
}
export -f run_one
export HERE ROOT

printf '%s\0' "${FILES[@]}" \
  | xargs -0 -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {} "${EXTRA[@]}" \
  | tee "$RESULTS"

echo
echo "======================================================================"
P=$(grep -c '^PASS' "$RESULTS"); F=$(grep -c '^FAIL' "$RESULTS")
S=$(grep -c '^SKIP' "$RESULTS")
echo "  $P passed, $F failed, $S skipped (not applicable to this ISA)"
if [ "$F" -gt 0 ]; then
   echo
   echo "  failures:"
   grep '^FAIL' "$RESULTS" | sed 's/^/    /'
   echo
   echo "  full report for a failure:  cat verif/work/<name>/report.txt"
fi
echo "======================================================================"
[ "$F" -eq 0 ]
