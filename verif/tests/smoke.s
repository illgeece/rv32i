# Smoke test for the co-simulation harness: touches one instruction from every
# major RV32I group so that a broken harness fails loudly and immediately.
        .section .text.init
        .globl _start
_start:
        lui   x1, 0x12345
        addi  x1, x1, 0x678         # x1 = 0x12345678
        auipc x2, 0
        addi  x3, x0, -1
        add   x4, x1, x3
        sub   x5, x1, x3
        and   x6, x1, x3
        or    x7, x1, x3
        xor   x8, x1, x3
        sll   x9, x1, x3            # shift amount is x3[4:0] = 31
        srl   x10, x1, x3
        sra   x11, x3, x3
        slt   x12, x3, x1
        sltu  x13, x3, x1
        slti  x14, x3, 1
        sltiu x15, x3, 1

        la    x16, scratch
        sw    x1, 0(x16)
        lw    x17, 0(x16)
        sh    x3, 8(x16)
        lh    x18, 8(x16)
        lhu   x19, 8(x16)
        sb    x1, 12(x16)
        lb    x20, 12(x16)
        lbu   x21, 12(x16)

        beq   x1, x1, 1f
        addi  x22, x0, 0x5ad
1:      bne   x1, x0, 2f
        addi  x22, x0, 0x5ad
2:      blt   x3, x1, 3f
        addi  x22, x0, 0x5ad
3:      bge   x1, x3, 4f
        addi  x22, x0, 0x5ad
4:      bltu  x1, x3, 5f
        addi  x22, x0, 0x5ad
5:      bgeu  x3, x1, 6f
        addi  x22, x0, 0x5ad

6:      jal   x23, 7f
        addi  x22, x0, 0x5ad
7:      la    x24, 8f
        jalr  x25, 0(x24)
        addi  x22, x0, 0x5ad

8:      csrw  mscratch, x1
        csrr  x26, mscratch
        csrrs x27, mscratch, x0

done:   j     done

        .section .data
        .align 4
scratch:
        .word 0, 0, 0, 0, 0, 0, 0, 0
