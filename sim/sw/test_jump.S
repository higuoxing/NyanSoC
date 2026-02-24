/* test_jump.S
 * Tests JAL and JALR.
 *
 * Checks:
 *  - JAL saves return address (PC+4) in rd.
 *  - JAL performs correct PC-relative jump.
 *  - JALR saves return address, clears LSB of target.
 *  - JALR with negative offset.
 *  - Call/return convention using ra.
 *  - Chained calls.
 * Returns 1 in a0 on PASS, 0 on FAIL.
 */

    .text
    .global test_main
test_main:
    /* test_main calls subroutines, so save ra on entry */
    addi sp, sp, -4
    sw   ra, 0(sp)

    /* ---- JAL: verify rd = PC+4 ---- */
    /* jal_after1 is placed immediately after the jal insn.
     * jal_target1 jumps to jal_after1; t0 must equal &jal_after1. */
    la   t1, jal_after1     /* t1 = address of jal_after1 */
    jal  t0, jal_target1    /* t0 = PC+4 = &jal_after1 */
jal_after1:                  /* NOTE: NO j-fail here; jal never falls through */
    bne  t0, t1, fail

    /* ---- JAL: jump skips instructions ---- */
    li   a1, 0
    jal  x0, jal_skip       /* x0 discards return addr */
    li   a1, 1              /* should be skipped */
    li   a1, 2              /* should be skipped */
jal_skip:
    /* a1 must still be 0 */
    li   t0, 0
    bne  a1, t0, fail

    /* ---- JALR: basic ---- */
    la   t2, jalr_after     /* t2 = address of jalr_after */
    la   t0, jalr_target
    jalr t1, t0, 0          /* t1 = PC+4 = &jalr_after */
jalr_after:                  /* immediately after jalr, no j-fail between */
    bne  t1, t2, fail

    /* ---- JALR: LSB clearing ---- */
    la   t0, jalr_lsb_target
    ori  t0, t0, 1          /* set LSB - JALR must clear it */
    jalr x0, t0, 0
    j    fail
jalr_lsb_target:
    /* if we arrive here, LSB was cleared correctly */

    /* ---- JALR: negative offset ---- */
    la   t0, jalr_neg_base
    jalr x0, t0, -4         /* should jump to jalr_neg_base - 4 */
    j    fail
jalr_neg_target:
    j    jalr_neg_done
jalr_neg_base:
    j    fail               /* should be jumped over */
jalr_neg_done:

    /* ---- Call / ret: simple leaf function ---- */
    li   a0, 21
    call double_it          /* a0 = double_it(21) = 42 */
    li   t0, 42
    bne  a0, t0, fail

    /* ---- Chained calls ---- */
    li   a0, 5
    call add3               /* add3 calls add1 three times */
    li   t0, 8
    bne  a0, t0, fail

    /* ---- JAL to x0 (discard return address) ---- */
    li   s1, 0
    jal  x0, jal_x0_tgt
    li   s1, 1              /* skipped */
jal_x0_tgt:
    li   t0, 0
    bne  s1, t0, fail

pass:
    li   a0, 1
    lw   ra, 0(sp)
    addi sp, sp, 4
    ret

fail:
    li   a0, 0
    lw   ra, 0(sp)
    addi sp, sp, 4
    ret

/* --- Helper: target for first JAL test --- */
jal_target1:
    j    jal_after1

/* --- Target for JALR basic test --- */
jalr_target:
    j    jalr_after

/* --- double_it: a0 = a0 * 2 --- */
double_it:
    add  a0, a0, a0
    ret

/* --- add1: a0 += 1 --- */
add1:
    addi a0, a0, 1
    ret

/* --- add3: a0 += 3, via three calls to add1 --- */
add3:
    addi sp, sp, -4
    sw   ra, 0(sp)
    call add1
    call add1
    call add1
    lw   ra, 0(sp)
    addi sp, sp, 4
    ret
