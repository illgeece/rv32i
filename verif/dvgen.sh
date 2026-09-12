#!/bin/bash
# ---------------------------------------------------------------------------
# dvgen.sh -- generate random RV32I programs with riscv-dv (ChipsAlliance).
#
# usage:  verif/dvgen.sh [count] [instr_cnt]
#
# riscv-dv is used as a GENERATOR ONLY.  It ships its own Spike-comparison
# flow, but ours reports the first diverging instruction rather than a
# signature diff, so we keep riscv-dv to one job and feed its .S files into
# verif/cosim.sh.  That keeps its configuration surface small.
#
# env:
#   DVROOT   riscv-dv checkout        (default ~/riscv-dv)
#   DVPY     python with PyVSC        (default ~/venv-dv/bin/python)
#   OUT      output dir               (default verif/work/dv)
#   JOBS     parallel generators      (default nproc)
# ---------------------------------------------------------------------------
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

COUNT="${1:-10}"
NINSN="${2:-2500}"
DVROOT="${DVROOT:-$HOME/riscv-dv}"
DVPY="${DVPY:-$HOME/venv-dv/bin/python}"
OUT="${OUT:-$ROOT/verif/work/dv}"
JOBS="${JOBS:-$(nproc)}"

if [ ! -x "$DVPY" ]; then
   echo "error: $DVPY not found -- see verif/README.md for the riscv-dv setup" >&2
   exit 2
fi

mkdir -p "$OUT"
rm -f "$OUT"/*.S

# Two riscv-dv pyflow options are deliberately left alone, both because of
# upstream bugs in the Python port (the SystemVerilog flow is unaffected):
#
#   --num_of_sub_program 0   gen_callstack() calls self.callstack_gen, which is
#                            never assigned, and riscv_callstack_gen.init()
#                            passes a name to riscv_program.__init__(), which
#                            takes none.  Costs us cross-procedure call/return
#                            coverage.
#   --no_fence left at 1     enabling FENCE trips "unhashable type: 'list'" in
#                            riscv_instr.get_rand_instr().  FENCE is covered by
#                            arch-test fence-01 and is a nop on this core.
gen_one() {
   local i="$1" ninsn="$2" dvroot="$3" dvpy="$4" out="$5"
   PYTHONPATH="$dvroot/pygen" "$dvpy" \
      "$dvroot/pygen/pygen_src/test/riscv_instr_base_test.py" \
      --target        rv32i_tlv \
      --num_of_tests  1 \
      --start_idx     "$i" \
      --seed          "$i" \
      --instr_cnt     "$ninsn" \
      --num_of_sub_program 0 \
      --asm_file_name "$out/dv" \
      --log_file_name "$out/gen_$i.log" >/dev/null 2>&1 \
      || echo "generation failed for seed $i (see $out/gen_$i.log)" >&2
}
export -f gen_one

seq 0 $((COUNT - 1)) \
  | xargs -P "$JOBS" -I{} bash -c 'gen_one "$@"' _ {} "$NINSN" "$DVROOT" "$DVPY" "$OUT"

echo "generated $(ls "$OUT"/*.S 2>/dev/null | wc -l) programs in $OUT"
