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
 * .bss is zeroed in-place (it follows .data in the same RAM region).
 */

    .section .text.start
    .global _start
_start:
    /* Stack at top of first 2 MiB of SDRAM — safe for any load address */
    li   sp, 0x801FFFFC

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
