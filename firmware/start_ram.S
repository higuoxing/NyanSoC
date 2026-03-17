/* start_ram.S — CRT0 for uart_loader-uploaded programs.
 *
 * Used when a firmware binary is loaded into RAM (DMEM or SDRAM) via the
 * UART loader rather than baked into the IMEM LUT-ROM.
 *
 * Stack is placed at the top of the first 2 MiB of SDRAM (0x801F_FFFC).
 * This is safe for both DMEM-loaded programs (stack is far above the code)
 * and SDRAM-loaded programs (stack is within SDRAM, above the typical load
 * address of 0x8000_0000).
 *
 * Interrupts are fully disabled so bare-metal programs are not disturbed by
 * the timer (mtime >= mtimecmp is true from reset since both start at 0).
 * mtvec is pointed at a local halt so any unexpected trap is visible as a
 * hang rather than a silent jump back to the LUT-ROM at address 0.
 *
 * .bss is zeroed in-place (it follows .data in the same RAM region).
 */

    .section .text.start
    .global _start
_start:
    /* Stack at top of first 2 MiB of SDRAM — safe for any load address */
    li   sp, 0x801FFFFC

    /* Point mtvec at a local trap handler so any trap halts visibly here
     * instead of jumping to address 0 (the LUT-ROM / uart_loader). */
    la   t0, trap_halt
    csrw mtvec, t0

    /* Disable all M-mode interrupts (MIE=0 in mstatus) and clear mie. */
    csrwi mstatus, 0
    csrwi mie, 0

    /* Push mtimecmp far into the future so the timer never fires.
     * Write the high word first (0xFFFFFFFF) to avoid a spurious compare
     * match while the low word is still 0. */
    li   t0, 0x02000000          /* CLINT base */
    li   t1, -1                  /* 0xFFFFFFFF */
    sw   t1, 0x4(t0)             /* mtimecmp hi = 0xFFFFFFFF */
    sw   t1, 0x0(t0)             /* mtimecmp lo = 0xFFFFFFFF */

    /* Zero .bss */
    la   a0, __bss_start
    la   a1, __bss_end
1:  bge  a0, a1, 2f
    sw   zero, 0(a0)
    addi a0, a0, 4
    j    1b
2:
    call main

    /* main() returned — spin forever */
halt:
    j    halt

    /* Unexpected trap — halt with a visible pattern on the trap output.
     * The CPU asserts o_trap for one cycle on any taken exception/interrupt,
     * which lights the red LED on the Tang Nano 20K board. */
    .balign 4
trap_halt:
    j    trap_halt
