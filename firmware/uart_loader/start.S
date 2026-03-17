/* start.S — CRT0 for uart_loader.
 *
 * Sets up stack in DMEM, installs a minimal trap handler, zeroes .bss,
 * calls main().  The loader never enables interrupts so the trap handler
 * is just a safety net.
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
