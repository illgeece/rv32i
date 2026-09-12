#!/bin/bash
# ---------------------------------------------------------------------------
# cosim.sh -- run one test on the DUT and on the reference model, compare the
#             instruction-by-instruction execution traces.
#
# usage:  verif/cosim.sh <test.s|test.S> [extra gcc flags...]
#
# env:
#   SIM        path to the verilated binary   (default ~/build/rv32i/rv32i_sim)
#   WORK       scratch dir                    (default verif/work/<testname>)
#   RVPREFIX   toolchain prefix               (default riscv32-unknown-elf-)
#   ILIMIT     spike instruction cap          (default 200000)
#   MAXCYC     DUT cycle cap                  (default 200000)
#   KEEP       set to 1 to keep intermediate files quiet
# ---------------------------------------------------------------------------
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

TEST="${1:?usage: cosim.sh <test.s> [gcc flags...]}"; shift || true
NAME="$(basename "$TEST")"; NAME="${NAME%.*}"
# riscv-arch-test reuses basenames across groups (I/src/xor-01.S and
# hints/src/xor-01.S both exist), so qualify the work dir with the group name
# or parallel jobs will silently clobber each other's artefacts.
if [ "$(basename "$(dirname "$TEST")")" = "src" ]; then
   NAME="$(basename "$(dirname "$(dirname "$TEST")")")_$NAME"
fi

SIM="${SIM:-$HOME/build/rv32i/rv32i_sim}"
WORK="${WORK:-$ROOT/verif/work/$NAME}"
RVPREFIX="${RVPREFIX:-riscv32-unknown-elf-}"
ILIMIT="${ILIMIT:-200000}"
MAXCYC="${MAXCYC:-200000}"

GCC="${RVPREFIX}gcc"
OBJCOPY="${RVPREFIX}objcopy"
OBJDUMP="${RVPREFIX}objdump"

BASE=0x1000          # link address == entry == reset-vector stub target

mkdir -p "$WORK"
rm -f "$WORK"/{my.elf,my.bin,imem.hex,spike.log,dut.trace}

# --- 1. build -------------------------------------------------------------
# Honour the test's own RVTEST_CASE metadata: skip tests that do not apply to
# this core's ISA, and pick up the -D macros the test says it needs.
ISA="${ISA:-RV32IZicsr}"
if ! METADEFS="$(python3 "$HERE/testmeta.py" "$TEST" --isa "$ISA" 2>"$WORK/meta.log")"; then
   echo "SKIP $NAME : $(head -1 "$WORK/meta.log")"
   exit 0
fi

# arch-test sources enter at rvtest_entry_point, hand-written ones at _start.
if grep -q 'rvtest_entry_point' "$TEST" 2>/dev/null; then
   ENTRY_FLAG="-Wl,--entry=rvtest_entry_point"
else
   ENTRY_FLAG=""
fi

"$GCC" -march=rv32i_zicsr -mabi=ilp32 \
       -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
       -mno-relax -g \
       -T "${LINK:-$HERE/link.ld}" $ENTRY_FLAG \
       $METADEFS "$@" "$TEST" -o "$WORK/my.elf" 2>"$WORK/build.log"
if [ $? -ne 0 ]; then
   echo "FAIL $NAME : compile error"; sed -n '1,15p' "$WORK/build.log"; exit 3
fi

# flat image, one 32-bit little-endian word per line
"$OBJCOPY" -O binary "$WORK/my.elf" "$WORK/my.bin"
od -An -tx4 -v "$WORK/my.bin" | tr -s ' ' '\n' | grep -v '^$' > "$WORK/imem.hex"

# --- 2. reference model ---------------------------------------------------
# Stop as soon as an instruction commits twice in a row at the same pc: that
# is the terminating "j ." every test ends with.  awk exiting closes the pipe,
# spike takes SIGPIPE, and we avoid megabytes of self-loop log.
# --priv=m matters: Spike defaults to MSU, which sets the S and U bits in misa.
# The core is M-mode only, so without this the reference reports misa=40140100
# against the DUT's (correct) 40000100 and every trap test "fails".  Configuring
# the reference to match the DUT is not a detail -- it is the whole contract.
spike --isa=rv32i_zicsr --priv=m -m${BASE}:0x1FF000 --disable-dtb \
      --instructions=$ILIMIT -l --log-commits "$WORK/my.elf" 2>&1 \
  | awk '{ print
           if ($0 ~ /^core[[:space:]]+[0-9]+:[[:space:]]+[0-9]+[[:space:]]+0x/) {
              if ($4 == prev) exit; prev = $4 } }' > "$WORK/spike.log"

# --- 3. DUT ---------------------------------------------------------------
# A store to tohost is the bare-metal "test over" convention.  Spike honours it
# through HTIF; give the testbench the same stopping point so the two traces end
# together (and so the DUT does not spin to the cycle cap).
TOHOST="$("${RVPREFIX}nm" "$WORK/my.elf" 2>/dev/null | awk '$3=="tohost"{print $1; exit}')"

DUTARGS=(+imem=imem.hex +load=1000 +entry=1000
         +trace=dut.trace +nodmem +maxcyc=$MAXCYC)
[ -n "$TOHOST" ] && DUTARGS+=("+haltstore=$TOHOST")

( cd "$WORK" && "$SIM" "${DUTARGS[@]}" ) > "$WORK/sim.log" 2>&1

# --- 4. compare -----------------------------------------------------------
CMPFLAGS=()
[ -n "${QUIET:-}" ] && CMPFLAGS+=(--quiet)
[ -n "$TOHOST" ] && CMPFLAGS+=(--halt-store "0x$TOHOST")

# mtval on an illegal-instruction exception (cause 2) is optional per the
# privileged spec: Spike returns the faulting instruction bits, this core
# returns 0.  Both conform, so declare the choice rather than fail on it.
# Only the reference is normalised -- the DUT still has to write 0.
CMPFLAGS+=(--tval-zero-causes 2)

python3 "$HERE/rvtrace.py" "$WORK/spike.log" "$WORK/dut.trace" \
        --elf "$WORK/my.elf" --objdump "$OBJDUMP" \
        --skip-below $BASE --name "$NAME" "${CMPFLAGS[@]}" \
   | tee "$WORK/report.txt"
exit "${PIPESTATUS[0]}"
