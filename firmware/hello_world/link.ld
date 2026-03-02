/* Linker script for NyanSoC firmware running on Tang Nano 20K.
 *
 * Memory map:
 *   IMEM: 0x0000_0000 - 0x0000_0FFF  (4 KiB, BRAM initialized at synthesis)
 *   DMEM: 0x0001_0000 - 0x0001_0FFF  (4 KiB, BRAM, read/write)
 *   GPIO: 0x0002_0000                (GPIO output register)
 */

ENTRY(_start)

MEMORY {
    IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 4K
    DMEM (rw) : ORIGIN = 0x00010000, LENGTH = 4K
}

SECTIONS {
    .text : {
        *(.text.start)
        *(.text*)
        *(.rodata*)
    } > IMEM

    .data : { *(.data*) } > DMEM

    .bss : {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        __bss_end = .;
    } > DMEM

    /DISCARD/ : { *(.comment) *(.eh_frame) }
}
