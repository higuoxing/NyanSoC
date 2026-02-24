/* Linker script for NyanSoC bare-metal tests.
 *
 * The testbench maps:
 *   imem: any address, indexed by addr[11:2]  (1 KiB words = 4 KiB)
 *   dmem: any address, indexed by addr[11:2]  (1 KiB words = 4 KiB)
 *
 * We place .text at 0x0000_0000 (imem) and .data/.bss at 0x0001_0000.
 * dmem word 0  (addr 0x0001_0000, bits[11:2]=0) is the PASS/FAIL flag.
 * dmem word 1+ (addr 0x0001_0004 ...) are scratch.
 */

ENTRY(_start)

MEMORY {
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 4K
    DMEM (rw)  : ORIGIN = 0x00010000, LENGTH = 4K
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

/* Convenient symbols for assembly */
RESULT_ADDR  = 0x00010000;   /* dmem[0] - write 1=PASS, 0=FAIL */
SCRATCH_ADDR = 0x00010004;   /* dmem[1] onwards - scratch space */
