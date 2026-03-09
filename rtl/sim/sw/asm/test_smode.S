/* test_smode.S
 * Tests Phase 1 S-mode CSR implementation in nyanrv.
 *
 * Uses a dedicated testbench (nyanrv_smode_tb.v) that does NOT stop on
 * o_trap, so ecall/ebreak can be used internally for privilege transitions.
 *
 * Completion protocol:
 *   dmem[0x10000] = 0xDEADD0D0  (done magic)
 *   dmem[0x10004] = 1 (PASS) or 0 (FAIL)
 *   dmem[0x10008] = fail line number (for debug)
 *
 * Shared state in dmem:
 *   0x10010  m_trap_cause   last mcause seen by M-mode handler
 *   0x10014  m_trap_epc     last mepc   seen by M-mode handler
 *   0x10018  s_trap_cause   last scause seen by S-mode handler
 *   0x1001c  s_trap_epc     last sepc   seen by S-mode handler
 *   0x10020  s_trap_count   number of S-mode traps taken
 *   0x10024  run_flag       which after_smode_run* to use
 *
 * Test sequence:
 *   1.  misa[18] (S-bit) is set
 *   2.  medeleg / mideleg write-read
 *   3.  stvec / sscratch / sepc / scause / stval / satp write-read from M-mode
 *   4.  Drop to S-mode (mret), S-mode ecall (cause=9) reaches M-mode
 *   5.  sscratch written in S-mode is visible from M-mode
 *   6.  Delegated ecall (cause=9) goes to S-mode handler
 *   7.  sret returns to correct PC
 *   8.  sstatus SIE/SPIE/SPP fields reflect mstatus
 */

/* ── CSR addresses ─────────────────────────────────────────────────────── */
.equ CSR_MSTATUS,  0x300
.equ CSR_MISA,     0x301
.equ CSR_MEDELEG,  0x302
.equ CSR_MIDELEG,  0x303
.equ CSR_MIE,      0x304
.equ CSR_MTVEC,    0x305
.equ CSR_MSCRATCH, 0x340
.equ CSR_MEPC,     0x341
.equ CSR_MCAUSE,   0x342
.equ CSR_MTVAL,    0x343

.equ CSR_SSTATUS,  0x100
.equ CSR_SIE,      0x104
.equ CSR_STVEC,    0x105
.equ CSR_SSCRATCH, 0x140
.equ CSR_SEPC,     0x141
.equ CSR_SCAUSE,   0x142
.equ CSR_STVAL,    0x143
.equ CSR_SIP,      0x144
.equ CSR_SATP,     0x180

/* ── Raw CSR instruction helpers ──────────────────────────────────────── */
.macro CSRRW_RAW rd, csr, rs1
    .word ((\csr) << 20) | ((\rs1) << 15) | (0b001 << 12) | ((\rd) << 7) | 0b1110011
.endm
.macro CSRRS_RAW rd, csr, rs1
    .word ((\csr) << 20) | ((\rs1) << 15) | (0b010 << 12) | ((\rd) << 7) | 0b1110011
.endm
.macro CSRRC_RAW rd, csr, rs1
    .word ((\csr) << 20) | ((\rs1) << 15) | (0b011 << 12) | ((\rd) << 7) | 0b1110011
.endm
.macro CSRRWI_RAW rd, csr, uimm
    .word ((\csr) << 20) | ((\uimm) << 15) | (0b101 << 12) | ((\rd) << 7) | 0b1110011
.endm
.macro CSRRSI_RAW rd, csr, uimm
    .word ((\csr) << 20) | ((\uimm) << 15) | (0b110 << 12) | ((\rd) << 7) | 0b1110011
.endm

/* sret = 0x10200073 */
.macro SRET
    .word 0x10200073
.endm

/* ── Register numbers ─────────────────────────────────────────────────── */
.equ REG_x0,  0
.equ REG_ra,  1
.equ REG_t0,  5
.equ REG_t1,  6
.equ REG_t2,  7
.equ REG_s0,  8
.equ REG_a0, 10
.equ REG_a1, 11
.equ REG_a2, 12
.equ REG_t6, 31

/* ── Shared memory ────────────────────────────────────────────────────── */
.equ DONE_ADDR,    0x00010000
.equ RESULT_ADDR,  0x00010004
.equ FAILLN_ADDR,  0x00010008
.equ M_TRAP_CAUSE, 0x00010010
.equ M_TRAP_EPC,   0x00010014
.equ S_TRAP_CAUSE, 0x00010018
.equ S_TRAP_EPC,   0x0001001c
.equ S_TRAP_COUNT, 0x00010020
.equ RUN_FLAG,     0x00010024

.equ DONE_MAGIC,   0xDEADD0D0

/* ── CHECK macro: takes explicit test-id for fail reporting ───────────── */
.macro CHECK reg, expected, testid
    li   t6, \expected
    bne  \reg, t6, .Lcheck_fail_\@
    j    .Lcheck_ok_\@
.Lcheck_fail_\@:
    li   t0, FAILLN_ADDR
    li   t1, \testid
    sw   t1, 0(t0)
    j    done_fail
.Lcheck_ok_\@:
.endm

/* ══════════════════════════════════════════════════════════════════════ */
    .text
    .global _start
_start:
    li   sp, 0x00010FFC

    /* Zero dmem scratch area */
    li   a0, DONE_ADDR
    li   a1, 0x00010030
1:  bge  a0, a1, 2f
    sw   zero, 0(a0)
    addi a0, a0, 4
    j    1b
2:
    /* Install M-mode trap vector */
    la   t0, m_trap_handler
    CSRRW_RAW REG_x0, CSR_MTVEC, REG_t0

    /* ── Test 1: misa S-bit (bit 18) ─────────────────────────────────── */
    CSRRS_RAW REG_a1, CSR_MISA, REG_x0
    li   t0, 0x40041100
    bne  a1, t0, .Lt1_fail
    j    .Lt1_ok
.Lt1_fail:
    li   t0, FAILLN_ADDR; li t1, 1; sw t1, 0(t0); j done_fail
.Lt1_ok:

    /* ── Test 2: medeleg / mideleg write-read ────────────────────────── */
    li   t0, (1 << 8) | (1 << 2)
    CSRRW_RAW REG_x0, CSR_MEDELEG, REG_t0
    CSRRS_RAW REG_a1, CSR_MEDELEG, REG_x0
    CHECK a1, ((1 << 8) | (1 << 2)), 20

    li   t0, (1 << 5) | (1 << 1)
    CSRRW_RAW REG_x0, CSR_MIDELEG, REG_t0
    CSRRS_RAW REG_a1, CSR_MIDELEG, REG_x0
    CHECK a1, ((1 << 5) | (1 << 1)), 21

    /* ── Test 3: S-mode CSR write-read from M-mode ───────────────────── */
    /* stvec */
    la   t0, s_trap_handler
    CSRRW_RAW REG_x0, CSR_STVEC, REG_t0
    CSRRS_RAW REG_a1, CSR_STVEC, REG_x0
    bne  a1, t0, .Lt3a_fail
    j    .Lt3a_ok
.Lt3a_fail:
    li   t0, FAILLN_ADDR; li t1, 30; sw t1, 0(t0); j done_fail
.Lt3a_ok:

    /* sscratch */
    li   t0, 0xABCD1234
    CSRRW_RAW REG_x0, CSR_SSCRATCH, REG_t0
    CSRRS_RAW REG_a1, CSR_SSCRATCH, REG_x0
    CHECK a1, 0xABCD1234, 31

    /* sepc */
    li   t0, 0x00000100
    CSRRW_RAW REG_x0, CSR_SEPC, REG_t0
    CSRRS_RAW REG_a1, CSR_SEPC, REG_x0
    CHECK a1, 0x00000100, 32

    /* scause */
    li   t0, 0x0000000F
    CSRRW_RAW REG_x0, CSR_SCAUSE, REG_t0
    CSRRS_RAW REG_a1, CSR_SCAUSE, REG_x0
    CHECK a1, 0x0000000F, 33

    /* stval */
    li   t0, 0xDEADBEEF
    CSRRW_RAW REG_x0, CSR_STVAL, REG_t0
    CSRRS_RAW REG_a1, CSR_STVAL, REG_x0
    CHECK a1, 0xDEADBEEF, 34

    /* satp bare mode */
    CSRRWI_RAW REG_x0, CSR_SATP, 0
    CSRRS_RAW REG_a1, CSR_SATP, REG_x0
    CHECK a1, 0, 35

    /* satp Sv32: MODE=1 (bit31), PPN=3 */
    li   t0, (1 << 31) | 3
    CSRRW_RAW REG_x0, CSR_SATP, REG_t0
    CSRRS_RAW REG_a1, CSR_SATP, REG_x0
    li   t0, (1 << 31) | 3
    bne  a1, t0, .Lt3b_fail
    j    .Lt3b_ok
.Lt3b_fail:
    li   t0, FAILLN_ADDR; li t1, 36; sw t1, 0(t0); j done_fail
.Lt3b_ok:

    /* ── Tests 4-5: Drop to S-mode, S-mode ecall (not delegated) ─────── */
    /* medeleg = 0: cause 9 (S-mode ecall) goes to M-mode */
    CSRRWI_RAW REG_x0, CSR_MEDELEG, 0

    /* Clear satp (bare mode) so MMU is off when we enter S-mode */
    CSRRWI_RAW REG_x0, CSR_SATP, 0

    /* Clear shared state */
    li   t0, M_TRAP_CAUSE; sw zero, 0(t0)
    li   t0, S_TRAP_COUNT; sw zero, 0(t0)
    li   t0, RUN_FLAG;     sw zero, 0(t0)

    /* mstatus: MPP=01 (S-mode, bits 12:11), MPIE=1 (bit 7) */
    CSRRS_RAW REG_a1, CSR_MSTATUS, REG_x0
    li   t0, ~(3 << 11)
    and  a1, a1, t0
    li   t0, (1 << 11) | (1 << 7)
    or   a1, a1, t0
    CSRRW_RAW REG_x0, CSR_MSTATUS, REG_a1

    la   t0, smode_payload1
    CSRRW_RAW REG_x0, CSR_MEPC, REG_t0
    mret                        /* → smode_payload1 in S-mode */

.global after_smode1
after_smode1:
    /* Test 4: M-mode caught cause=9 (S-mode ecall) */
    li   t0, M_TRAP_CAUSE
    lw   a1, 0(t0)
    CHECK a1, 9, 40

    /* Test 5: sscratch written in S-mode is visible from M-mode */
    CSRRS_RAW REG_a1, CSR_SSCRATCH, REG_x0
    CHECK a1, 0xCAFEBABE, 50

    /* ── Test 6-7: Delegated ecall (cause=9) goes to S-mode handler ──── */
    /* medeleg = (1<<9): cause 9 delegated to S-mode */
    li   t0, (1 << 9)
    CSRRW_RAW REG_x0, CSR_MEDELEG, REG_t0

    li   t0, S_TRAP_COUNT; sw zero, 0(t0)
    li   t0, S_TRAP_CAUSE; sw zero, 0(t0)
    li   t0, M_TRAP_CAUSE; sw zero, 0(t0)
    li   t0, RUN_FLAG;     li t1, 1; sw t1, 0(t0)  /* mark run 2 */

    CSRRS_RAW REG_a1, CSR_MSTATUS, REG_x0
    li   t0, ~(3 << 11)
    and  a1, a1, t0
    li   t0, (1 << 11) | (1 << 7)
    or   a1, a1, t0
    CSRRW_RAW REG_x0, CSR_MSTATUS, REG_a1

    la   t0, smode_payload2
    CSRRW_RAW REG_x0, CSR_MEPC, REG_t0
    mret                        /* → smode_payload2 in S-mode */

.global after_smode2
after_smode2:
    /* Test 6: S-mode handler was called once */
    li   t0, S_TRAP_COUNT
    lw   a1, 0(t0)
    CHECK a1, 1, 60

    /* Test 6b: scause in S-mode handler was 9 */
    li   t0, S_TRAP_CAUSE
    lw   a1, 0(t0)
    CHECK a1, 9, 61

    /* Test 7: M-mode caught ebreak (cause=3) to return from S-mode */
    li   t0, M_TRAP_CAUSE
    lw   a1, 0(t0)
    CHECK a1, 3, 70

    /* ── Test 8: sstatus SIE/SPIE/SPP reflect mstatus ────────────────── */
    CSRRWI_RAW REG_x0, CSR_MEDELEG, 0

    /* Set mstatus SIE=1(bit1), SPIE=1(bit5), SPP=1(bit8) */
    li   t0, (1 << 1) | (1 << 5) | (1 << 8)
    CSRRS_RAW REG_x0, CSR_MSTATUS, REG_t0

    CSRRS_RAW REG_a1, CSR_SSTATUS, REG_x0
    li   t0, (1 << 1) | (1 << 5) | (1 << 8)
    and  a1, a1, t0
    CHECK a1, ((1 << 1) | (1 << 5) | (1 << 8)), 80

    /* Clear those bits via sstatus write */
    li   t0, (1 << 1) | (1 << 5) | (1 << 8)
    CSRRC_RAW REG_x0, CSR_SSTATUS, REG_t0   /* clear SIE/SPIE/SPP */

    /* Verify mstatus no longer has those bits */
    CSRRS_RAW REG_a1, CSR_MSTATUS, REG_x0
    li   t0, (1 << 1) | (1 << 5) | (1 << 8)
    and  a1, a1, t0
    CHECK a1, 0, 81

done_pass:
    li   t0, RESULT_ADDR
    li   t1, 1
    sw   t1, 0(t0)
    j    done_signal

done_fail:
    li   t0, RESULT_ADDR
    sw   zero, 0(t0)

done_signal:
    li   t0, DONE_ADDR
    li   t1, DONE_MAGIC
    sw   t1, 0(t0)
1:  j    1b              /* halt */


/* ══════════════════════════════════════════════════════════════════════ */
/* M-mode trap handler                                                    */
/* ══════════════════════════════════════════════════════════════════════ */
    .balign 4
m_trap_handler:
    csrr t0, mcause
    li   t1, M_TRAP_CAUSE
    sw   t0, 0(t1)
    csrr t1, mepc
    li   t2, M_TRAP_EPC
    sw   t1, 0(t2)

    /* cause=9: S-mode ecall — redirect to after_smode1 or after_smode2 */
    li   t2, 9
    bne  t0, t2, .Lm_not9

    li   t2, RUN_FLAG
    lw   t2, 0(t2)
    bnez t2, .Lm_run2
    /* run 1: redirect to after_smode1 */
    la   t1, after_smode1
    csrw mepc, t1
    mret
.Lm_run2:
    /* run 2: cause=9 is delegated, so M-mode should NOT see it.
     * If we get here, delegation failed — signal fail. */
    li   t0, FAILLN_ADDR
    li   t1, 200
    sw   t1, 0(t0)
    j    done_fail

.Lm_not9:
    /* cause=3: ebreak from smode_payload2 — redirect to after_smode2 */
    li   t2, 3
    bne  t0, t2, .Lm_unknown
    la   t1, after_smode2
    csrw mepc, t1
    mret

.Lm_unknown:
    /* Unexpected trap — advance mepc and continue */
    addi t1, t1, 4
    csrw mepc, t1
    mret


/* ══════════════════════════════════════════════════════════════════════ */
/* S-mode trap handler                                                    */
/* ══════════════════════════════════════════════════════════════════════ */
    .balign 4
s_trap_handler:
    /* Read scause and sepc using raw encodings (assembler may not know S-mode) */
    CSRRS_RAW REG_t0, CSR_SCAUSE, REG_x0
    li   t1, S_TRAP_CAUSE
    sw   t0, 0(t1)

    CSRRS_RAW REG_t1, CSR_SEPC, REG_x0
    li   t2, S_TRAP_EPC
    sw   t1, 0(t2)

    /* s_trap_count++ */
    li   t2, S_TRAP_COUNT
    lw   t3, 0(t2)
    addi t3, t3, 1
    sw   t3, 0(t2)

    /* Advance sepc past ecall */
    addi t1, t1, 4
    CSRRW_RAW REG_x0, CSR_SEPC, REG_t1

    SRET


/* ══════════════════════════════════════════════════════════════════════ */
/* S-mode payload 1 (tests 4-5)                                           */
/* Writes sscratch, then ecall (cause=9, not delegated → M-mode).        */
/* ══════════════════════════════════════════════════════════════════════ */
    .balign 4
smode_payload1:
    li   t0, 0xCAFEBABE
    CSRRW_RAW REG_x0, CSR_SSCRATCH, REG_t0
    ecall           /* cause=9, not delegated → M-mode handler */
1:  j    1b         /* not reached */


/* ══════════════════════════════════════════════════════════════════════ */
/* S-mode payload 2 (tests 6-7)                                           */
/* ecall (cause=9, delegated → S-mode handler), then ebreak → M-mode.   */
/* ══════════════════════════════════════════════════════════════════════ */
    .balign 4
smode_payload2:
    ecall           /* cause=9, delegated → S-mode handler, sret returns here */
    ebreak          /* cause=3, not delegated → M-mode → after_smode2 */
1:  j    1b
