/* crt0.S - minimal startup for NyanSoC bare-metal tests */
    .section .text.start
    .global _start
_start:
    /* Set up stack pointer at top of DMEM (0x00010000 + 4K - 4) */
    li   sp, 0x00010000 + 4096 - 4

    /* Zero .bss */
    la   a0, __bss_start
    la   a1, __bss_end
1:  bge  a0, a1, 2f
    sw   zero, 0(a0)
    addi a0, a0, 4
    j    1b
2:
    /* Call the test */
    call test_main

    /* test_main returns 0=fail 1=pass in a0.
     * Store result to RESULT_ADDR (dmem[0]) and halt via ebreak. */
    li   t0, 0x00010000
    sw   a0, 0(t0)
    ebreak
