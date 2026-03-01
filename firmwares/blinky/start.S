/* start.S - Minimal CRT0 for NyanSoC bare-metal firmwares.
 *
 * Sets up the stack, zeroes .bss, then jumps to main().
 * The linker script places .text.start first, so _start is the
 * very first instruction fetched after reset.
 */

    .section .text.start
    .global _start
_start:
    /* Stack pointer: top of DMEM (4 KiB at 0x0001_0000) */
    li   sp, 0x00010FFC

    /* Zero .bss */
    la   a0, __bss_start
    la   a1, __bss_end
1:  bge  a0, a1, 2f
    sw   zero, 0(a0)
    addi a0, a0, 4
    j    1b
2:
    call main

    /* main() returned — halt */
halt:
    j    halt
