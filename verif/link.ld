/* Link tests at 0x1000.
 *
 * The core resets to pc == 0, but Spike permanently reserves [0, 0x1000) for
 * its debug module and refuses to map RAM there.  Rather than change the RTL's
 * reset vector for the benefit of the testbench, tests are linked at 0x1000
 * and the testbench plants a single "jal x0, 0x1000" at word 0.  The trace
 * comparator drops that synthetic instruction (--skip-below 0x1000).
 *
 * Everything is one contiguous image so that "objcopy -O binary" produces a
 * flat file that maps 1:1 onto the core's memory arrays.
 */
OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
  . = 0x00001000;

  .text.init   : { *(.text.init) }
  .text        : { *(.text) *(.text.*) }

  . = ALIGN(0x40);
  .tohost      : { *(.tohost) }

  . = ALIGN(0x40);
  .data        : { *(.data) *(.data.*) *(.sdata*) *(.rodata*) }
  .data.string : { *(.data.string) }

  . = ALIGN(0x40);
  .bss         : { *(.bss) *(.sbss*) *(COMMON) }

  . = ALIGN(0x40);
  _end = .;

  /* The core advertises a 2 MiB space ($imem_in_range = $pc[31:21] == 0). */
  ASSERT(_end <= 0x00200000, "Image exceeds the core's 2 MiB address space")
}
