/* start.S — CRT0 for clint_test.
 *
 * Installs the trap vector, sets up the stack, zeroes .bss, calls main().
 * The trap vector must be set up before enabling interrupts.
 */

    .section .text.start
    .global _start
_start:
    /* Stack pointer: top of DMEM */
    li   sp, 0x00010FFC

    /* Install machine trap vector (direct mode, address must be 4-byte aligned) */
    la   t0, trap_handler
    csrw mtvec, t0

    /* Zero .bss */
    la   a0, __bss_start
    la   a1, __bss_end
1:  bge  a0, a1, 2f
    sw   zero, 0(a0)
    addi a0, a0, 4
    j    1b
2:
    call main

halt:
    j    halt


/* ── Trap / interrupt handler ─────────────────────────────────────────── */
/* Minimal handler: saves ra, delegates to C handler, restores ra, mrets. */
    .global trap_handler
    .balign 4
trap_handler:
    /* Save caller-saved registers we use */
    addi sp, sp, -64
    sw   ra,  0(sp)
    sw   t0,  4(sp)
    sw   t1,  8(sp)
    sw   t2, 12(sp)
    sw   a0, 16(sp)
    sw   a1, 20(sp)
    sw   a2, 24(sp)
    sw   a3, 28(sp)
    sw   a4, 32(sp)
    sw   a5, 36(sp)
    sw   a6, 40(sp)
    sw   a7, 44(sp)

    call c_trap_handler

    lw   ra,  0(sp)
    lw   t0,  4(sp)
    lw   t1,  8(sp)
    lw   t2, 12(sp)
    lw   a0, 16(sp)
    lw   a1, 20(sp)
    lw   a2, 24(sp)
    lw   a3, 28(sp)
    lw   a4, 32(sp)
    lw   a5, 36(sp)
    lw   a6, 40(sp)
    lw   a7, 44(sp)
    addi sp, sp,  64

    mret
