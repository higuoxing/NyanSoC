/* link_ram.ld — position-independent RAM link script for uart_loader targets.
 *
 * Links the entire program (text + rodata + data + bss) into one contiguous
 * region starting at RAM_BASE.  RAM_BASE must be provided on the linker
 * command line with --defsym RAM_BASE=0x....
 *
 * Usage:
 *   $(CC) ... -T ../../link_ram.ld -Wl,--defsym,RAM_BASE=0x00010000 ...
 *
 * Typical targets:
 *   DMEM  : RAM_BASE = 0x00010000  (4 KiB)
 *   SDRAM : RAM_BASE = 0x80000000  (32 MiB)
 */

ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = RAM_BASE, LENGTH = 32M
}

SECTIONS {
    .text : {
        *(.text.start)
        *(.text*)
        *(.rodata*)
    } > RAM

    .data : { *(.data*) } > RAM

    .bss : {
        __bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        __bss_end = .;
    } > RAM

    /DISCARD/ : { *(.comment) *(.eh_frame) }
}
