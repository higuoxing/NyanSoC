/* start.S — CRT0 for plic_test.
 *
 * Sets up stack, installs a minimal trap handler, zeroes .bss, calls main().
 * We poll mip rather than taking actual interrupts, so the trap handler is
 * a safety fallback that just returns (mret) to avoid a hang if an interrupt
 * somehow fires before we can claim it.
 */

    .section .text.start
    .global _start
_start:
    li   sp, 0x00010FFC

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

    .balign 4
trap_handler:
    mret
