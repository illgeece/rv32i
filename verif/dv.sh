#!/bin/bash
# ---------------------------------------------------------------------------
# dv.sh -- generate riscv-dv programs and step-and-compare every one of them.
#
# usage:  verif/dv.sh [count] [instr_cnt]
#
# env:  SKIPGEN=1  reuse the programs already in verif/work/dv
#       JOBS       parallel jobs (default nproc)
#
# Reproduce a single failure:
#   verif/dvgen.sh 1 && LINK=verif/link_dv.ld verif/cosim.sh \
#       verif/work/dv/dv_0.S -I ~/riscv-dv/user_extension
# ---------------------------------------------------------------------------
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

COUNT="${1:-10}"
NINSN="${2:-2500}"
DVROOT="${DVROOT:-$HOME/riscv-dv}"
OUT="${OUT:-$ROOT/verif/work/dv}"
JOBS="${JOBS:-$(nproc)}"

[ -n "${SKIPGEN:-}" ] || bash "$HERE/dvgen.sh" "$COUNT" "$NINSN"

RESULTS="$ROOT/verif/work/dv-results.txt"
: > "$RESULTS"

# riscv-dv programs .include user_define.h / user_init.s from user_extension/,
# and need the section layout in link_dv.ld (.page_table, .kernel_stack, ...).
export LINK="$HERE/link_dv.ld"

find "$OUT" -name 'dv_*.S' -print0 \
  | xargs -0 -P "$JOBS" -I{} bash -c \
        'bash "$0"/cosim.sh "$1" -I "$2/user_extension" 2>&1 | sed -n "1p"' \
        "$HERE" {} "$DVROOT" \
  | tee "$RESULTS"

echo
echo "======================================================================"
P=$(grep -c '^PASS' "$RESULTS"); F=$(grep -c '^FAIL' "$RESULTS")
echo "  $P passed, $F failed   (riscv-dv, $NINSN generated instructions each)"
if [ "$F" -gt 0 ]; then
   echo
   grep '^FAIL' "$RESULTS" | sed 's/^/    /'
   echo
   echo "  full report:  cat verif/work/<name>/report.txt"
fi
echo "======================================================================"
[ "$F" -eq 0 ]
