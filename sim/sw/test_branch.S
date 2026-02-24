/* test_branch.S
 * Tests all six branch instructions: BEQ BNE BLT BGE BLTU BGEU.
 * Each test checks both the "taken" and "not-taken" paths.
 * Returns 1 in a0 on PASS, 0 on FAIL.
 */

    .text
    .global test_main
test_main:

    /* ---- BEQ ---- */
    /* taken */
    li   a1, 42
    li   a2, 42
    beq  a1, a2, beq_taken
    j    fail
beq_taken:
    /* not taken */
    li   a1, 1
    li   a2, 2
    beq  a1, a2, fail

    /* ---- BNE ---- */
    /* taken */
    li   a1, 1
    li   a2, 2
    bne  a1, a2, bne_taken
    j    fail
bne_taken:
    /* not taken */
    li   a1, 5
    li   a2, 5
    bne  a1, a2, fail

    /* ---- BLT (signed) ---- */
    /* taken: -1 < 0 */
    li   a1, -1
    li   a2, 0
    blt  a1, a2, blt_taken1
    j    fail
blt_taken1:
    /* taken: INT_MIN < INT_MAX */
    li   a1, 0x80000000
    li   a2, 0x7FFFFFFF
    blt  a1, a2, blt_taken2
    j    fail
blt_taken2:
    /* not taken: equal */
    li   a1, 7
    li   a2, 7
    blt  a1, a2, fail
    /* not taken: a1 > a2 signed */
    li   a1, 1
    li   a2, -1
    blt  a1, a2, fail

    /* ---- BGE (signed) ---- */
    /* taken: equal */
    li   a1, 100
    li   a2, 100
    bge  a1, a2, bge_taken1
    j    fail
bge_taken1:
    /* taken: 0 >= -1 */
    li   a1, 0
    li   a2, -1
    bge  a1, a2, bge_taken2
    j    fail
bge_taken2:
    /* taken: INT_MAX >= INT_MIN */
    li   a1, 0x7FFFFFFF
    li   a2, 0x80000000
    bge  a1, a2, bge_taken3
    j    fail
bge_taken3:
    /* not taken: -1 < 0 */
    li   a1, -1
    li   a2, 0
    bge  a1, a2, fail

    /* ---- BLTU (unsigned) ---- */
    /* taken: 0 < 1 */
    li   a1, 0
    li   a2, 1
    bltu a1, a2, bltu_taken1
    j    fail
bltu_taken1:
    /* taken: 0 < 0xFFFFFFFF */
    li   a1, 0
    li   a2, -1             /* 0xFFFFFFFF unsigned */
    bltu a1, a2, bltu_taken2
    j    fail
bltu_taken2:
    /* not taken: 0xFFFFFFFF >= 1 */
    li   a1, -1
    li   a2, 1
    bltu a1, a2, fail
    /* not taken: equal */
    li   a1, 5
    li   a2, 5
    bltu a1, a2, fail

    /* ---- BGEU (unsigned) ---- */
    /* taken: equal */
    li   a1, 0
    li   a2, 0
    bgeu a1, a2, bgeu_taken1
    j    fail
bgeu_taken1:
    /* taken: 0xFFFFFFFF >= 0 */
    li   a1, -1
    li   a2, 0
    bgeu a1, a2, bgeu_taken2
    j    fail
bgeu_taken2:
    /* not taken: 0 < 1 */
    li   a1, 0
    li   a2, 1
    bgeu a1, a2, fail

    /* ---- Backward branch ---- */
    li   a1, 3
    li   a2, 0
back_loop:
    addi a2, a2, 1
    bne  a2, a1, back_loop  /* loop 3 times */
    /* a2 should equal 3 */
    li   t0, 3
    bne  a2, t0, fail

    /* ---- Branch with x0 ---- */
    beq  x0, x0, zero_eq_ok
    j    fail
zero_eq_ok:
    li   a1, 1
    bne  x0, a1, zero_ne_ok
    j    fail
zero_ne_ok:

pass:
    li   a0, 1
    ret

fail:
    li   a0, 0
    ret
