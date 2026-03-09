/* Linker script for test_mmu — data at 0x0010_0000 (TLB entry 1, VA[21:20]=01). */

ENTRY(_start)

MEMORY {
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 4K
    DMEM (rw)  : ORIGIN = 0x00100000, LENGTH = 4K
}

SECTIONS {
    .text : {
        *(.text.start)
        *(.text*)
    } > IMEM

    .data : {
        *(.data*)
        *(.rodata*)
    } > DMEM

    .bss : {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        __bss_end = .;
    } > DMEM

    /DISCARD/ : { *(.comment) *(.eh_frame) }
}
