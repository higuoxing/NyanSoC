/* test_alu.S
 * Tests all RV32I ALU instructions (register-register and immediate).
 * Returns 1 in a0 on PASS, 0 on FAIL.
 *
 * Macro CHECK: if reg != expected_imm, jump to fail label.
 */

.macro CHECK reg, expected, lbl
    li   t6, \expected
    bne  \reg, t6, \lbl
.endm

    .text
    .global test_main
test_main:

    /* ---- ADDI ---- */
    li   a1, 0
    addi a1, a1, 42
    CHECK a1, 42, fail

    li   a1, 100
    addi a1, a1, -7
    CHECK a1, 93, fail

    /* sign-extend: addi with negative immediate */
    li   a1, 0
    addi a1, a1, -1
    CHECK a1, -1, fail

    /* ---- SLTI ---- */
    li   a1, 5
    slti a2, a1, 10        /* 5 < 10 signed -> 1 */
    CHECK a2, 1, fail

    li   a1, -1
    slti a2, a1, 0         /* -1 < 0 signed -> 1 */
    CHECK a2, 1, fail

    li   a1, 10
    slti a2, a1, 5         /* 10 < 5 -> 0 */
    CHECK a2, 0, fail

    /* ---- SLTIU ---- */
    li   a1, 1
    sltiu a2, a1, 5        /* 1 < 5 unsigned -> 1 */
    CHECK a2, 1, fail

    li   a1, -1             /* 0xFFFFFFFF unsigned */
    sltiu a2, a1, 1        /* 0xFFFF... < 1 -> 0 */
    CHECK a2, 0, fail

    /* ---- XORI ---- */
    li   a1, 0xF0F0F0F0
    xori a2, a1, 0x0F0     /* only low 12 bits of imm matter */
    li   t0, 0xF0F0F00F    /* 0xF0F0F0F0 ^ 0x0FF = 0xF0F0F00F */
    /* Actually imm = 0x0F0, so XOR with 0x000000F0 */
    li   t0, 0xF0F0F080    /* 0xF0F0F0F0 ^ 0x70 = ? let's be precise */
    /* 0xF0 ^ 0xF0 = 0x00, so result = 0xF0F0F000 ^ 0x00 — recalculate */
    /* xori a2, a1, 0x0F0: imm12 = 0x0F0 = 240 = 0xF0, sign-extended = 0x000000F0 */
    /* 0xF0F0F0F0 ^ 0x000000F0 = 0xF0F0F000 */
    li   t0, 0xF0F0F000
    bne  a2, t0, fail

    li   a1, 0xAAAAAAAA
    xori a2, a1, -1        /* flip all bits */
    li   t0, 0x55555555
    bne  a2, t0, fail

    /* ---- ORI ---- */
    li   a1, 0xF0000000
    ori  a2, a1, 0x0F      /* OR with 0x0000000F */
    li   t0, 0xF000000F
    bne  a2, t0, fail

    /* ---- ANDI ---- */
    li   a1, 0xFFFFFFFF
    andi a2, a1, 0x0FF     /* 0xFF sign-extended = 0xFFFFFFFF... wait, 0x0FF = 255, no sign bit */
    /* imm12 = 0x0FF = 255, sign-extended = 0x000000FF */
    li   t0, 0x000000FF
    bne  a2, t0, fail

    /* ---- SLLI ---- */
    li   a1, 1
    slli a2, a1, 4
    CHECK a2, 16, fail

    li   a1, 0x00000001
    slli a2, a1, 31
    li   t0, 0x80000000
    bne  a2, t0, fail

    /* ---- SRLI ---- */
    li   a1, 0x80000000
    srli a2, a1, 1
    li   t0, 0x40000000
    bne  a2, t0, fail

    li   a1, 0x80000000
    srli a2, a1, 31
    CHECK a2, 1, fail

    /* ---- SRAI ---- */
    li   a1, 0x80000000
    srai a2, a1, 1
    li   t0, 0xC0000000
    bne  a2, t0, fail

    li   a1, 0x80000000
    srai a2, a1, 31
    CHECK a2, -1, fail

    li   a1, 0x7FFFFFFF
    srai a2, a1, 1
    li   t0, 0x3FFFFFFF
    bne  a2, t0, fail

    /* ---- ADD ---- */
    li   a1, 100
    li   a2, 200
    add  a3, a1, a2
    CHECK a3, 300, fail

    li   a1, -1
    li   a2, 1
    add  a3, a1, a2
    CHECK a3, 0, fail

    /* overflow wraps */
    li   a1, 0x7FFFFFFF
    li   a2, 1
    add  a3, a1, a2
    li   t0, 0x80000000
    bne  a3, t0, fail

    /* ---- SUB ---- */
    li   a1, 300
    li   a2, 200
    sub  a3, a1, a2
    CHECK a3, 100, fail

    li   a1, 0
    li   a2, 1
    sub  a3, a1, a2
    CHECK a3, -1, fail

    /* ---- SLL ---- */
    li   a1, 1
    li   a2, 8
    sll  a3, a1, a2
    CHECK a3, 256, fail

    /* only low 5 bits of rs2 used */
    li   a1, 1
    li   a2, 33           /* 33 & 0x1F = 1 */
    sll  a3, a1, a2
    CHECK a3, 2, fail

    /* ---- SLT ---- */
    li   a1, -1
    li   a2, 0
    slt  a3, a1, a2       /* -1 < 0 signed -> 1 */
    CHECK a3, 1, fail

    li   a1, 0
    li   a2, 0
    slt  a3, a1, a2       /* 0 < 0 -> 0 */
    CHECK a3, 0, fail

    li   a1, 1
    li   a2, 0
    slt  a3, a1, a2       /* 1 < 0 -> 0 */
    CHECK a3, 0, fail

    /* ---- SLTU ---- */
    li   a1, 0
    li   a2, 1
    sltu a3, a1, a2       /* 0 < 1 unsigned -> 1 */
    CHECK a3, 1, fail

    li   a1, -1            /* 0xFFFFFFFF */
    li   a2, 0
    sltu a3, a1, a2       /* 0xFFFFFFFF < 0 -> 0 */
    CHECK a3, 0, fail

    /* ---- XOR ---- */
    li   a1, 0xAAAAAAAA
    li   a2, 0x55555555
    xor  a3, a1, a2
    CHECK a3, -1, fail    /* 0xFFFFFFFF */

    /* ---- SRL ---- */
    li   a1, 0x80000000
    li   a2, 4
    srl  a3, a1, a2
    li   t0, 0x08000000
    bne  a3, t0, fail

    /* only low 5 bits of rs2 */
    li   a1, 0x80000000
    li   a2, 36           /* 36 & 0x1F = 4 */
    srl  a3, a1, a2
    li   t0, 0x08000000
    bne  a3, t0, fail

    /* ---- SRA ---- */
    li   a1, 0x80000000
    li   a2, 4
    sra  a3, a1, a2
    li   t0, 0xF8000000
    bne  a3, t0, fail

    li   a1, 0x7FFFFFFF
    li   a2, 4
    sra  a3, a1, a2
    li   t0, 0x07FFFFFF
    bne  a3, t0, fail

    /* ---- OR ---- */
    li   a1, 0xF0F0F0F0
    li   a2, 0x0F0F0F0F
    or   a3, a1, a2
    CHECK a3, -1, fail

    /* ---- AND ---- */
    li   a1, 0xFFFF0000
    li   a2, 0xF0F0F0F0
    and  a3, a1, a2
    li   t0, 0xF0F00000
    bne  a3, t0, fail

    /* ---- LUI ---- */
    lui  a1, 0xABCDE
    li   t0, 0xABCDE000
    bne  a1, t0, fail

    lui  a1, 0x80000
    li   t0, 0x80000000
    bne  a1, t0, fail

    /* ---- AUIPC ---- */
    /* auipc writes PC + (imm << 12); we can't know exact PC, but we
     * can verify it's at least 4-aligned and has the upper bits set. */
    auipc a1, 1           /* a1 = PC + 0x1000 */
    auipc a2, 0           /* a2 = PC_next */
    /* a1 should equal (a2 - 4) + 0x1000 */
    addi  a2, a2, -4
    addi  a2, a2, 0       /* a2 = PC of auipc a1 */
    li    t0, 0x1000
    add   t0, a2, t0
    bne   a1, t0, fail

    /* ---- x0 is always zero ---- */
    addi x0, x0, 1
    CHECK x0, 0, fail

    /* ---- forwarding: back-to-back dependent instructions ---- */
    li   a1, 7
    addi a2, a1, 1        /* a2 = 8 (depends on previous write to a1) */
    addi a3, a2, 1        /* a3 = 9 */
    add  a4, a2, a3       /* a4 = 17 */
    CHECK a4, 17, fail

pass:
    li   a0, 1
    ret

fail:
    li   a0, 0
    ret
