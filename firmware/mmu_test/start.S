/* start.S — MMU test firmware entry point */

.section .text.start
.global _start
_start:
    /* Set up a temporary stack in DMEM */
    li      sp, 0x00010FF0

    /* Clear BSS */
    la      a0, __bss_start
    la      a1, __bss_end
    beq     a0, a1, .Lbss_done
.Lbss_loop:
    sw      zero, 0(a0)
    addi    a0, a0, 4
    blt     a0, a1, .Lbss_loop
.Lbss_done:

    call    mmu_test_main

.Lhang:
    j       .Lhang
