/* test_div_timing.S
 * Measures cycle counts for DIV with different dividend magnitudes.
 * Writes results to DMEM starting at 0x00010004 as pairs:
 *   [offset +0] = cycle count for that DIV
 *   [offset +4] = quotient (to verify correctness)
 *
 * Layout (word offsets from 0x00010000):
 *   [0]  = pass/fail (written last by crt0)
 *   [1]  = cycles for DIV  1 / 1        (dividend has 31 leading zeros)
 *   [2]  = quotient
 *   [3]  = cycles for DIV  0xFF / 3     (24 leading zeros)
 *   [4]  = quotient
 *   [5]  = cycles for DIV  0xFFFF / 7   (16 leading zeros)
 *   [6]  = quotient
 *   [7]  = cycles for DIV  0xFFFFFFFF / 3 (0 leading zeros)
 *   [8]  = quotient
 *   [9]  = cycles for DIV  0 / 1        (dividend = 0, 0 steps)
 *   [10] = quotient
 *
 * Returns 1 in a0 (always pass — this is a timing measurement).
 */

/* We use DMEM sentinel writes to bracket each DIV.
 * The testbench counts clock edges between consecutive stores to
 * dmem[1] (sentinel=0xAA) and dmem[1] (sentinel=0xBB).
 * The quotient is stored to dmem[2..6] for verification. */

.macro CHECK reg, expected, lbl
    li   t6, \expected
    bne  \reg, t6, \lbl
.endm

/* Write sentinel value VAL to dmem[1] (address 0x00010004) */
.macro MARK val
    li   t5, 0x00010004
    li   t4, \val
    sw   t4, 0(t5)
.endm

    .text
    .global test_main
test_main:

    /* ── Case 1: 1 / 1  (31 leading zeros → 1 step) ── */
    MARK 0x11AA
    li   a1, 1
    li   a2, 1
    div  a3, a1, a2
    MARK 0x11BB
    CHECK a3, 1, fail
    li   t5, 0x00010008
    sw   a3, 0(t5)

    /* ── Case 2: 0xFF / 3  (24 leading zeros → 8 steps) ── */
    MARK 0x22AA
    li   a1, 0xFF
    li   a2, 3
    div  a3, a1, a2
    MARK 0x22BB
    CHECK a3, 85, fail
    li   t5, 0x0001000C
    sw   a3, 0(t5)

    /* ── Case 3: 0xFFFF / 7  (16 leading zeros → 16 steps) ── */
    MARK 0x33AA
    li   a1, 0xFFFF
    li   a2, 7
    div  a3, a1, a2
    MARK 0x33BB
    CHECK a3, 9362, fail
    li   t5, 0x00010010
    sw   a3, 0(t5)

    /* ── Case 4: 0xFFFFFFFF / 3  (0 leading zeros → 32 steps) ── */
    MARK 0x44AA
    li   a1, -1
    li   a2, 3
    divu a3, a1, a2
    MARK 0x44BB
    li   t6, 0x55555555
    bne  a3, t6, fail
    li   t5, 0x00010014
    sw   a3, 0(t5)

    /* ── Case 5: 0 / 1  (dividend = 0 → 0 steps) ── */
    MARK 0x55AA
    li   a1, 0
    li   a2, 1
    div  a3, a1, a2
    MARK 0x55BB
    CHECK a3, 0, fail
    li   t5, 0x00010018
    sw   a3, 0(t5)

pass:
    li   a0, 1
    ret

fail:
    li   a0, 0
    ret
