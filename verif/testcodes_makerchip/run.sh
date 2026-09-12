#!/bin/bash
set -e
TEST="$1"

riscv64-unknown-elf-as -march=rv32i_zicsr -mabi=ilp32 "$TEST.s" -o /tmp/t.o
riscv64-unknown-elf-ld -m elf32lriscv -Ttext=0 -e _start -o /tmp/t.elf /tmp/t.o
riscv64-unknown-elf-objdump -d /tmp/t.elf > /tmp/t.dump
awk -F'\t' '/^ *[0-9a-f]+:/ {gsub(/ /,"",$2); print $2}' /tmp/t.dump > imem.hex
echo "$(wc -l < imem.hex) words -> imem.hex"

rm -f regs.out dmem.out          # never diff against a stale run
~/build/rv32i/rv32i_sim

FAILED=0
check() {
   if ! diff -q "$1" "$2" > /dev/null 2>&1; then
      echo "FAIL $TEST ($1)"; diff "$1" "$2" | head -20; FAILED=1
   fi
}
check_prefix() {   # <produced> <expected> — compares only as far as the golden goes
   n=$(wc -l < "$2")
   if ! head -n "$n" "$1" | diff -q - "$2" > /dev/null 2>&1; then
      echo "FAIL $TEST ($1)"; head -n "$n" "$1" | diff - "$2" | head -20; FAILED=1
   fi
}
check        regs.out "$TEST.expected"
check_prefix dmem.out "$TEST.dmem.expected"

if [ $FAILED -eq 0 ]; then echo "PASS $TEST"; fi
exit $FAILED
