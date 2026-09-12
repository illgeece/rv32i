#!/bin/bash
# ---------------------------------------------------------------------------
# unaligned_test.sh -- generate N random programs and step-and-compare each one.
#
# usage:  verif/unaligned_test.sh [count] [instructions-per-program]
#
# env:  SEED0  first seed (default 1)
#       JOBS   parallel jobs (default nproc)
#
# A failing seed is fully reproducible:
#   python3 verif/unaligned_test.py --seed <n> -n <k> -o /tmp/bad.s && verif/cosim.sh /tmp/bad.s
# ---------------------------------------------------------------------------
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

COUNT="${1:-50}"
NINSN="${2:-400}"
SEED0="${SEED0:-1}"
JOBS="${JOBS:-$(nproc)}"

GENDIR="$ROOT/verif/work/unaligned"
mkdir -p "$GENDIR"
RESULTS="$ROOT/verif/work/unaligned-results.txt"
: > "$RESULTS"

for ((i = 0; i < COUNT; i++)); do
   s=$((SEED0 + i))
   python3 "$HERE/unaligned_test.py" --seed "$s" -n "$NINSN" -o "$GENDIR/unaligned$s.s"
done

find "$GENDIR" -name 'unaligned*.s' -print0 \
  | xargs -0 -P "$JOBS" -I{} bash -c 'bash "$0"/cosim.sh "$1" 2>&1 | sed -n "1p"' \
        "$HERE" {} \
  | tee "$RESULTS"

echo
echo "======================================================================"
P=$(grep -c '^PASS' "$RESULTS"); F=$(grep -c '^FAIL' "$RESULTS")
echo "  $P passed, $F failed   ($NINSN random instructions each)"
if [ "$F" -gt 0 ]; then
   echo
   grep '^FAIL' "$RESULTS" | sed 's/^/    /'
   echo
   echo "  reproduce:  cat verif/work/<name>/report.txt"
fi
echo "======================================================================"
[ "$F" -eq 0 ]
