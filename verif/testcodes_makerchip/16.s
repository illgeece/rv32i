    .option norvc
    .section .text
    .globl _start

_start:
    la      x28, handler            # handler address (keep in sync with `handler`)
    csrrw   x0,  mtvec, x28         # mtvec = handler
    li      x1,  0                  # dmem base

    # ---- A: array is zero-initialised, not X ----
    lw      x6,  2044(x1)           # never written -> must read 0

    # ---- B: four addresses that all collided at index 0 in the old 32-word dmem ----
    li      x2,  0x111
    li      x3,  0x222
    li      x4,  0x333
    li      x5,  0x444
    sw      x2,  0(x1)
    sw      x3,  128(x1)
    sw      x4,  1024(x1)
    sw      x5,  1152(x1)
    lw      x7,  0(x1)
    lw      x8,  128(x1)
    lw      x9,  1024(x1)
    lw      x10, 1152(x1)

    # ---- C: store then load the same address on the next instruction ----
    li      x11, 0x2AA
    sw      x11, 64(x1)
    lw      x12, 64(x1)

    # ---- D: byte/halfword lanes, far from index 0 ----
    li      x13, 0x81
    sb      x13, 512(x1)
    li      x13, 0x02
    sb      x13, 513(x1)
    li      x13, 0x83
    sb      x13, 514(x1)
    li      x13, 0x84
    sb      x13, 515(x1)
    lw      x14, 512(x1)
    lb      x15, 515(x1)
    lbu     x16, 514(x1)
    lh      x17, 514(x1)
    lhu     x18, 512(x1)

    # ---- E: a trapping access must not touch memory or rd ----
    li      x19, 0x3FF
    li      x21, 555
    sw      x19, 2(x1)              # misaligned SW -> TRAP, cause 6
    lw      x20, 0(x1)              # [0] must still be 0x111
    lw      x21, 1(x1)              # misaligned LW -> TRAP, cause 4

    li      x22, 42                 # sentinel: main path completed
    li      x23, 4096
    jalr    x24, 0(x23)             #jump past imem border
    li      x25, 777                #must never execute
halt:
    bge     x0, x0, halt

handler:
    csrr    x29, mepc
    csrr    x27, mcause
    add     x26, x26, x27
    addi    x30, x30, 1
    addi    x13, x0, 2              # x13 is dead after the byte-store block
    beq     x27, x13, fetch_fault   # illegal instruction: nothing to skip past
    addi    x29, x29, 4             # data fault: resume after the faulting insn
    csrw    mepc, x29
    mret
fetch_fault:
    la      x29, halt
    csrw    mepc, x29
    mret
    li      x31, 999                # poison: must never execute
hhalt:
    bge     x0, x0, hhalt
