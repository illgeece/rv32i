/* Linker script for riscv-dv generated programs.
 *
 * Derived from riscv-dv's scripts/link.ld, with the base moved from
 * 0x80000000 to 0x1000 to match this core's memory map (see verif/link.ld for
 * why 0x1000 rather than 0).  riscv-dv's generated code is position
 * independent -- it addresses everything through `la` -- so only the base
 * changes.
 *
 * The extra sections over verif/link.ld (.page_table, .user_stack,
 * .kernel_data, .kernel_stack) are emitted by riscv-dv's gen_kernel_sections,
 * which is also where the trap handlers live.  Leave them placed or the link
 * silently drops the handlers.
 */
OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
  . = 0x00001000;
  .text : { *(.text) }
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
  . = ALIGN(0x1000);
  .page_table   : { *(.page_table) }
  .data         : { *(.data) }
  .user_stack   : { *(.user_stack) }
  .kernel_data  : { *(.kernel_data) }
  .kernel_stack : { *(.kernel_stack) }
  .bss          : { *(.bss) }
  _end = .;

  ASSERT(_end <= 0x00200000, "Image exceeds the core's 2 MiB address space")
}
