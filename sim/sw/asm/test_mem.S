/* test_mem.S
 * Tests all load/store variants:
 *   SW / LW
 *   SH / LH / LHU  (aligned, both halves)
 *   SB / LB / LBU  (all four byte lanes)
 * Scratch memory starts at SCRATCH_ADDR = 0x00010004 (dmem[1]).
 * Returns 1 in a0 on PASS, 0 on FAIL.
 */

.macro CHECK reg, expected, lbl
    li   t6, \expected
    bne  \reg, t6, \lbl
.endm

    .text
    .global test_main
test_main:
    li   s0, 0x00010004     /* scratch word (dmem[1]) */

    /* ---- SW / LW ---- */
    li   t0, 0xDEADBEEF
    sw   t0, 0(s0)
    lw   t1, 0(s0)
    CHECK t1, 0xDEADBEEF, fail

    li   t0, 0
    sw   t0, 0(s0)
    lw   t1, 0(s0)
    CHECK t1, 0, fail

    li   t0, -1
    sw   t0, 0(s0)
    lw   t1, 0(s0)
    CHECK t1, -1, fail

    /* ---- SH / LH (low half, addr+0) ---- */
    li   t0, 0x00000000
    sw   t0, 0(s0)          /* clear */
    li   t0, 0x1234
    sh   t0, 0(s0)          /* write to bytes [1:0] */
    lh   t1, 0(s0)
    CHECK t1, 0x1234, fail

    li   t0, 0x00000000
    sw   t0, 0(s0)
    li   t0, 0xFFFF
    sh   t0, 0(s0)
    lh   t1, 0(s0)
    CHECK t1, -1, fail      /* sign extended */

    li   t0, 0x00000000
    sw   t0, 0(s0)
    li   t0, 0x8000
    sh   t0, 0(s0)
    lh   t1, 0(s0)
    CHECK t1, 0xFFFF8000, fail   /* sign bit set -> sign extend */

    /* ---- SH / LH (high half, addr+2) ---- */
    li   t0, 0x00000000
    sw   t0, 0(s0)
    li   t0, 0xABCD
    sh   t0, 2(s0)          /* write to bytes [3:2] */
    lh   t1, 2(s0)
    CHECK t1, 0xFFFFABCD, fail   /* 0xABCD sign-extended */

    /* ---- LHU (low half) ---- */
    li   t0, 0x00000000
    sw   t0, 0(s0)
    li   t0, 0x8001
    sh   t0, 0(s0)
    lhu  t1, 0(s0)
    CHECK t1, 0x8001, fail       /* zero-extended */

    /* ---- LHU (high half) ---- */
    li   t0, 0x00000000
    sw   t0, 0(s0)
    li   t0, 0xFFFF
    sh   t0, 2(s0)
    lhu  t1, 2(s0)
    CHECK t1, 0x0000FFFF, fail   /* zero-extended */

    /* ---- SB / LB / LBU (all four byte lanes) ---- */
    /* byte 0 */
    li   t0, 0x00000000
    sw   t0, 0(s0)
    li   t0, 0xA5
    sb   t0, 0(s0)
    lb   t1, 0(s0)
    CHECK t1, 0xFFFFFFA5, fail   /* sign extended */
    lbu  t1, 0(s0)
    CHECK t1, 0xA5, fail

    /* byte 1 */
    li   t0, 0x00000000
    sw   t0, 0(s0)
    li   t0, 0x5A
    sb   t0, 1(s0)
    lb   t1, 1(s0)
    CHECK t1, 0x5A, fail
    lbu  t1, 1(s0)
    CHECK t1, 0x5A, fail

    /* byte 2 */
    li   t0, 0x00000000
    sw   t0, 0(s0)
    li   t0, 0xFF
    sb   t0, 2(s0)
    lb   t1, 2(s0)
    CHECK t1, -1, fail
    lbu  t1, 2(s0)
    CHECK t1, 0xFF, fail

    /* byte 3 */
    li   t0, 0x00000000
    sw   t0, 0(s0)
    li   t0, 0x7E
    sb   t0, 3(s0)
    lb   t1, 3(s0)
    CHECK t1, 0x7E, fail
    lbu  t1, 3(s0)
    CHECK t1, 0x7E, fail

    /* ---- Multiple bytes independent ---- */
    /* Write all four bytes, read back as word */
    li   t0, 0x00000000
    sw   t0, 0(s0)
    li   t0, 0x11
    sb   t0, 0(s0)
    li   t0, 0x22
    sb   t0, 1(s0)
    li   t0, 0x33
    sb   t0, 2(s0)
    li   t0, 0x44
    sb   t0, 3(s0)
    lw   t1, 0(s0)
    li   t6, 0x44332211
    bne  t1, t6, fail

    /* ---- Positive offsets in load/store ---- */
    li   t0, 0xCAFEBABE
    sw   t0, 4(s0)          /* dmem[2] */
    lw   t1, 4(s0)
    li   t6, 0xCAFEBABE
    bne  t1, t6, fail

    /* ---- Negative signed offset ---- */
    li   t0, 0x12345678
    li   t1, 0x00010008     /* dmem[2] base */
    sw   t0, -4(t1)         /* writes to dmem[1] */
    lw   t2, -4(t1)
    li   t6, 0x12345678
    bne  t2, t6, fail

pass:
    li   a0, 1
    ret

fail:
    li   a0, 0
    ret
