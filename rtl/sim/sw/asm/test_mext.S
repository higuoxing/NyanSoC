/* test_mext.S
 * Tests all RV32M instructions: MUL, MULH, MULHSU, MULHU,
 * DIV, DIVU, REM, REMU, including edge cases (divide-by-zero,
 * INT_MIN/-1 overflow, sign combinations).
 * Returns 1 in a0 on PASS, 0 on FAIL.
 */

.macro CHECK reg, expected, lbl
    li   t6, \expected
    bne  \reg, t6, \lbl
.endm

    .text
    .global test_main
test_main:

    /* ---- MUL: lower 32 bits of signed × signed ---- */
    li   a1, 3
    li   a2, 7
    mul  a3, a1, a2
    CHECK a3, 21, fail

    /* negative × positive */
    li   a1, -3
    li   a2, 7
    mul  a3, a1, a2
    CHECK a3, -21, fail

    /* negative × negative */
    li   a1, -3
    li   a2, -7
    mul  a3, a1, a2
    CHECK a3, 21, fail

    /* overflow wraps: 0x80000000 × 2 = 0x100000000 → lower 32 = 0 */
    li   a1, 0x80000000
    li   a2, 2
    mul  a3, a1, a2
    CHECK a3, 0, fail

    /* multiply by zero */
    li   a1, 0xDEADBEEF
    li   a2, 0
    mul  a3, a1, a2
    CHECK a3, 0, fail

    /* ---- MULH: upper 32 bits of signed × signed ---- */
    /* 0x80000000 × 0x80000000 = 0x4000_0000_0000_0000 → upper = 0x40000000 */
    li   a1, 0x80000000
    li   a2, 0x80000000
    mulh a3, a1, a2
    li   t0, 0x40000000
    bne  a3, t0, fail

    /* -1 × -1 = 1 → upper = 0 */
    li   a1, -1
    li   a2, -1
    mulh a3, a1, a2
    CHECK a3, 0, fail

    /* -1 × 1 = -1 → upper = -1 (sign-extended) */
    li   a1, -1
    li   a2, 1
    mulh a3, a1, a2
    CHECK a3, -1, fail

    /* ---- MULHSU: upper 32 bits of signed × unsigned ---- */
    /* -1 (0xFFFFFFFF) × 1 unsigned = 0xFFFF_FFFF_FFFF_FFFF → upper = -1 */
    li   a1, -1
    li   a2, 1
    mulhsu a3, a1, a2
    CHECK a3, -1, fail

    /* 1 × 0xFFFFFFFF unsigned = 0x00000000_FFFFFFFF → upper = 0 */
    li   a1, 1
    li   a2, -1            /* unsigned 0xFFFFFFFF */
    mulhsu a3, a1, a2
    CHECK a3, 0, fail

    /* ---- MULHU: upper 32 bits of unsigned × unsigned ---- */
    /* 0xFFFFFFFF × 0xFFFFFFFF = 0xFFFFFFFE_00000001 → upper = 0xFFFFFFFE */
    li   a1, -1            /* 0xFFFFFFFF */
    li   a2, -1            /* 0xFFFFFFFF */
    mulhu a3, a1, a2
    li   t0, 0xFFFFFFFE
    bne  a3, t0, fail

    /* 2 × 3 = 6 → upper = 0 */
    li   a1, 2
    li   a2, 3
    mulhu a3, a1, a2
    CHECK a3, 0, fail

    /* ---- DIV: signed division ---- */
    li   a1, 20
    li   a2, 4
    div  a3, a1, a2
    CHECK a3, 5, fail

    /* truncates toward zero: 7 / 2 = 3 */
    li   a1, 7
    li   a2, 2
    div  a3, a1, a2
    CHECK a3, 3, fail

    /* negative / positive: -7 / 2 = -3 (truncate toward zero) */
    li   a1, -7
    li   a2, 2
    div  a3, a1, a2
    CHECK a3, -3, fail

    /* positive / negative: 7 / -2 = -3 */
    li   a1, 7
    li   a2, -2
    div  a3, a1, a2
    CHECK a3, -3, fail

    /* negative / negative: -7 / -2 = 3 */
    li   a1, -7
    li   a2, -2
    div  a3, a1, a2
    CHECK a3, 3, fail

    /* divide by zero → -1 (spec) */
    li   a1, 42
    li   a2, 0
    div  a3, a1, a2
    CHECK a3, -1, fail

    /* INT_MIN / -1 overflow → INT_MIN (spec) */
    li   a1, 0x80000000
    li   a2, -1
    div  a3, a1, a2
    li   t0, 0x80000000
    bne  a3, t0, fail

    /* ---- DIVU: unsigned division ---- */
    li   a1, 20
    li   a2, 4
    divu a3, a1, a2
    CHECK a3, 5, fail

    /* 0xFFFFFFFF / 2 = 0x7FFFFFFF */
    li   a1, -1            /* 0xFFFFFFFF */
    li   a2, 2
    divu a3, a1, a2
    li   t0, 0x7FFFFFFF
    bne  a3, t0, fail

    /* divide by zero → 0xFFFFFFFF (spec) */
    li   a1, 42
    li   a2, 0
    divu a3, a1, a2
    CHECK a3, -1, fail

    /* ---- REM: signed remainder ---- */
    /* 7 rem 2 = 1 */
    li   a1, 7
    li   a2, 2
    rem  a3, a1, a2
    CHECK a3, 1, fail

    /* -7 rem 2 = -1 (sign follows dividend) */
    li   a1, -7
    li   a2, 2
    rem  a3, a1, a2
    CHECK a3, -1, fail

    /* 7 rem -2 = 1 */
    li   a1, 7
    li   a2, -2
    rem  a3, a1, a2
    CHECK a3, 1, fail

    /* -7 rem -2 = -1 */
    li   a1, -7
    li   a2, -2
    rem  a3, a1, a2
    CHECK a3, -1, fail

    /* rem by zero → dividend (spec) */
    li   a1, 42
    li   a2, 0
    rem  a3, a1, a2
    CHECK a3, 42, fail

    /* INT_MIN rem -1 = 0 (spec) */
    li   a1, 0x80000000
    li   a2, -1
    rem  a3, a1, a2
    CHECK a3, 0, fail

    /* ---- REMU: unsigned remainder ---- */
    /* 7 remu 2 = 1 */
    li   a1, 7
    li   a2, 2
    remu a3, a1, a2
    CHECK a3, 1, fail

    /* 0xFFFFFFFF remu 3 = 0 (0xFFFFFFFF = 3 × 0x55555555) */
    li   a1, -1            /* 0xFFFFFFFF */
    li   a2, 3
    remu a3, a1, a2
    CHECK a3, 0, fail

    /* remu by zero → dividend (spec) */
    li   a1, 42
    li   a2, 0
    remu a3, a1, a2
    CHECK a3, 42, fail

    /* ---- result in x0 is discarded ---- */
    li   a1, 7
    li   a2, 2
    div  x0, a1, a2
    CHECK x0, 0, fail

    /* ---- back-to-back: MUL result used immediately ---- */
    li   a1, 6
    li   a2, 7
    mul  a3, a1, a2        /* a3 = 42 */
    addi a4, a3, 1         /* a4 = 43 — tests forwarding from mul */
    CHECK a4, 43, fail

pass:
    li   a0, 1
    ret

fail:
    li   a0, 0
    ret
