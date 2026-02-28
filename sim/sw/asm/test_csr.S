/* test_csr.S
 * Tests CSR instructions: CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI.
 *
 * NyanSoC CSR address map:
 *   0x300 mstatus   (standard)
 *   0x301 misa      (standard)
 *   0x304 mie       (standard)
 *   0x305 mtvec     (standard)
 *   0x340 mscratch  (standard)
 *   0x341 mepc      (standard)
 *   0x342 mcause    (standard)
 *   0x343 mtval     (standard)
 *   0x344 mip       (standard)
 *   0x744 mnstatus  (Smrnmi extension)
 *   0xF14 mhartid   (standard)
 *
 * We use .word to hand-encode CSR instructions for non-standard addresses,
 * and the standard assembler CSR mnemonics where addresses match the spec.
 * Returns 1 in a0 on PASS, 0 on FAIL.
 */

/* Encode CSRRW rd, csr, rs1: opcode=1110011 funct3=001 */
.macro CSRRW_RAW rd, csr, rs1
    .word ((\csr) << 20) | ((\rs1) << 15) | (0b001 << 12) | ((\rd) << 7) | 0b1110011
.endm
/* Encode CSRRS rd, csr, rs1 (funct3=010) */
.macro CSRRS_RAW rd, csr, rs1
    .word ((\csr) << 20) | ((\rs1) << 15) | (0b010 << 12) | ((\rd) << 7) | 0b1110011
.endm
/* Encode CSRRC rd, csr, rs1 (funct3=011) */
.macro CSRRC_RAW rd, csr, rs1
    .word ((\csr) << 20) | ((\rs1) << 15) | (0b011 << 12) | ((\rd) << 7) | 0b1110011
.endm
/* Encode CSRRWI rd, csr, uimm5 (funct3=101) */
.macro CSRRWI_RAW rd, csr, uimm
    .word ((\csr) << 20) | ((\uimm) << 15) | (0b101 << 12) | ((\rd) << 7) | 0b1110011
.endm
/* Encode CSRRSI rd, csr, uimm5 (funct3=110) */
.macro CSRRSI_RAW rd, csr, uimm
    .word ((\csr) << 20) | ((\uimm) << 15) | (0b110 << 12) | ((\rd) << 7) | 0b1110011
.endm
/* Encode CSRRCI rd, csr, uimm5 (funct3=111) */
.macro CSRRCI_RAW rd, csr, uimm
    .word ((\csr) << 20) | ((\uimm) << 15) | (0b111 << 12) | ((\rd) << 7) | 0b1110011
.endm

/* Register ABI name -> number mapping for the macros above */
.equ REG_x0,  0
.equ REG_a0, 10
.equ REG_a1, 11
.equ REG_a2, 12
.equ REG_t0,  5
.equ REG_t6, 31

/* NyanSoC CSR addresses */
.equ CSR_MSTATUS,  0x300
.equ CSR_MISA,     0x301
.equ CSR_MIE,      0x304
.equ CSR_MTVEC,    0x305
.equ CSR_MSCRATCH, 0x340
.equ CSR_MEPC,     0x341
.equ CSR_MCAUSE,   0x342
.equ CSR_MTVAL,    0x343
.equ CSR_MIP,      0x344
.equ CSR_MHARTID,  0xF14

.macro CHECK reg, expected, lbl
    li   t6, \expected
    bne  \reg, t6, \lbl
.endm

    .text
    .global test_main
test_main:

    /* ---- mhartid: must read 0 ---- */
    /* csrr a1, mhartid  (0xF14 - standard address, use assembler pseudo) */
    .word (0xF14 << 20) | (REG_x0 << 15) | (0b010 << 12) | (REG_a1 << 7) | 0b1110011
    CHECK a1, 0, fail

    /* ---- misa at NyanSoC address 0x302: expect 0x40000100 (RV32I) ---- */
    CSRRS_RAW REG_a1, CSR_MISA, REG_x0
    li   t0, 0x40000100
    bne  a1, t0, fail

    /* ---- CSRRW on mscratch (0x340) ---- */
    li   t0, 0xDEAD
    CSRRW_RAW REG_x0, CSR_MSCRATCH, REG_t0   /* write 0xDEAD, discard old */
    CSRRS_RAW REG_a1, CSR_MSCRATCH, REG_x0   /* read back */
    CHECK a1, 0xDEAD, fail

    li   t0, 0xBEEF
    CSRRW_RAW REG_a2, CSR_MSCRATCH, REG_t0   /* a2 = old (0xDEAD), mscratch = 0xBEEF */
    CHECK a2, 0xDEAD, fail
    CSRRS_RAW REG_a1, CSR_MSCRATCH, REG_x0
    CHECK a1, 0xBEEF, fail

    /* ---- CSRRS: set bits ---- */
    li   t0, 0xFF00
    CSRRW_RAW REG_x0, CSR_MSCRATCH, REG_t0   /* mscratch = 0xFF00 */
    li   t0, 0x00FF
    CSRRS_RAW REG_a2, CSR_MSCRATCH, REG_t0   /* a2 = old (0xFF00), mscratch |= 0x00FF */
    CHECK a2, 0xFF00, fail
    CSRRS_RAW REG_a1, CSR_MSCRATCH, REG_x0
    CHECK a1, 0xFFFF, fail

    /* CSRRS with rs1=x0: read-only, no write */
    CSRRS_RAW REG_a1, CSR_MSCRATCH, REG_x0
    CHECK a1, 0xFFFF, fail
    CSRRS_RAW REG_a2, CSR_MSCRATCH, REG_x0
    CHECK a2, 0xFFFF, fail

    /* ---- CSRRC: clear bits ---- */
    li   t0, 0xFFFF
    CSRRW_RAW REG_x0, CSR_MSCRATCH, REG_t0
    li   t0, 0x0F0F
    CSRRC_RAW REG_a2, CSR_MSCRATCH, REG_t0   /* a2 = old (0xFFFF), mscratch &= ~0x0F0F */
    CHECK a2, 0xFFFF, fail
    CSRRS_RAW REG_a1, CSR_MSCRATCH, REG_x0
    li    t0, 0xF0F0
    bne   a1, t0, fail

    /* CSRRC with rs1=x0: no write */
    CSRRC_RAW REG_a1, CSR_MSCRATCH, REG_x0
    li    t0, 0xF0F0
    bne   a1, t0, fail

    /* ---- CSRRWI: write 5-bit immediate ---- */
    CSRRWI_RAW REG_a2, CSR_MSCRATCH, 7   /* write 7, a2 = old */
    CSRRS_RAW  REG_a1, CSR_MSCRATCH, REG_x0
    CHECK  a1, 7, fail

    CSRRWI_RAW REG_a2, CSR_MSCRATCH, 0   /* write 0 */
    CHECK  a2, 7, fail                    /* old was 7 */
    CSRRS_RAW  REG_a1, CSR_MSCRATCH, REG_x0
    CHECK  a1, 0, fail

    /* ---- CSRRSI: set bits from uimm5 ---- */
    li   t0, 0x10
    CSRRW_RAW  REG_x0, CSR_MSCRATCH, REG_t0   /* mscratch = 0x10 */
    CSRRSI_RAW REG_a2, CSR_MSCRATCH, 5         /* a2 = old (0x10), mscratch |= 5 */
    CHECK  a2, 0x10, fail
    CSRRS_RAW  REG_a1, CSR_MSCRATCH, REG_x0
    li     t0, 0x15
    bne    a1, t0, fail

    /* ---- CSRRCI: clear bits from uimm5 ---- */
    li   t0, 0x1F
    CSRRW_RAW  REG_x0, CSR_MSCRATCH, REG_t0   /* mscratch = 0x1F */
    CSRRCI_RAW REG_a2, CSR_MSCRATCH, 5         /* a2 = old (0x1F), mscratch &= ~5 -> 0x1A */
    CHECK  a2, 0x1F, fail
    CSRRS_RAW  REG_a1, CSR_MSCRATCH, REG_x0
    li     t0, 0x1A
    bne    a1, t0, fail

    /* ---- mepc / mtvec / mcause via CSRRW ---- */
    li   t0, 0x1000
    CSRRW_RAW REG_x0, CSR_MEPC, REG_t0
    CSRRS_RAW REG_a1, CSR_MEPC, REG_x0
    CHECK a1, 0x1000, fail

    li   t0, 0x2000
    CSRRW_RAW REG_x0, CSR_MTVEC, REG_t0
    CSRRS_RAW REG_a1, CSR_MTVEC, REG_x0
    CHECK a1, 0x2000, fail

    li   t0, 0xAB
    CSRRW_RAW REG_x0, CSR_MCAUSE, REG_t0
    CSRRS_RAW REG_a1, CSR_MCAUSE, REG_x0
    CHECK a1, 0xAB, fail

    li   t0, 0x1800
    CSRRW_RAW REG_x0, CSR_MSTATUS, REG_t0
    CSRRS_RAW REG_a1, CSR_MSTATUS, REG_x0
    CHECK a1, 0x1800, fail

pass:
    li   a0, 1
    ret

fail:
    li   a0, 0
    ret
