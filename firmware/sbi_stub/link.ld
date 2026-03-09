/* Linker script for sbi_stub — loads at 0x8020_0000 in SDRAM. */

ENTRY(_start)

MEMORY {
    SDRAM (rwx) : ORIGIN = 0x80200000, LENGTH = 64K
}

SECTIONS {
    . = 0x80200000;

    .text : {
        *(.text.start)
        *(.text*)
        *(.rodata*)
    } > SDRAM

    .data : { *(.data*) } > SDRAM

    .bss : {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        __bss_end = .;
    } > SDRAM

    /DISCARD/ : { *(.comment) *(.eh_frame) }
}
