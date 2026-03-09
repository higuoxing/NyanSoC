/* test_mmu.S — Sv32 MMU simulation test for NyanSoC nyanrv.
 *
 * Memory layout (from link.ld):
 *   Code: VA 0x0000_0000 (imem, identity mapped to PA 0x0000_0000)
 *   Data: VA 0x0010_0000 (dmem, identity mapped to PA 0x0010_0000)
 *
 * TLB indexing: VA[21:20] (2 bits → 4 entries)
 *   Code 0x0000_0000: VA[21:20]=00 → TLB entry 0
 *   Data 0x0010_0000: VA[21:20]=01 → TLB entry 1  (no collision)
 *
 * Sv32 page tables (built by testbench in ptbl[]):
 *   satp.PPN=1  → L1 table at PA=0x0000_1000
 *   L1[0]   → pointer PTE, PPN=2 → L0 at PA=0x0000_2000
 *   L0[0]   → leaf PTE for VA 0x0000_0000, PPN=0,    R+W+X+U+A+D
 *   L0[256] → leaf PTE for VA 0x0010_0000, PPN=0x100, R+W+U+A+D
 *   L0[257] → leaf PTE for VA 0x0010_1000, PPN=0x101, R+X+U+A+D (no W)
 *
 * Test checks:
 *   1. Load from VA 0x0010_0000 works with MMU enabled (data TLB fill).
 *   2. Store to VA 0x0010_0000 works.
 *   3. Load from VA 0x0010_1000 works (R+X page).
 *   4. Store to VA 0x0010_1000 causes store page fault (cause 15).
 *   5. Load from unmapped VA 0x0100_0000 causes load page fault (cause 13).
 *   6. SFENCE.VMA flushes TLB; subsequent access re-fills correctly.
 *
 * Completion: writes DONE_MAGIC (0xBEEFC0DE) to 0x0010_0000 word 0,
 *             writes 1 (PASS) or 0 (FAIL) to word 1,
 *             writes fail line number to word 2.
 */

#define DONE_ADDR   0x100000
#define RESULT_ADDR 0x100004
#define FAILLN_ADDR 0x100008
#define DONE_MAGIC  0xBEEFC0DE   /* marker written to DONE_ADDR on completion */

/* Scratch locations in dmem (words 3..31) */
#define SCRATCH0    0x10000C
#define SCRATCH1    0x100010
#define PAGE2_DATA  0x101000      /* first word of VA 0x0010_1000 */

/* CSR numbers */
#define CSR_MSTATUS   0x300
#define CSR_MTVEC     0x305
#define CSR_MEPC      0x341
#define CSR_MCAUSE    0x342
#define CSR_MTVAL     0x343
#define CSR_MEDELEG   0x302
#define CSR_STVEC     0x105
#define CSR_SEPC      0x141
#define CSR_SCAUSE    0x142
#define CSR_STVAL     0x143
#define CSR_SATP      0x180

/* Shared state in DMEM (words 8..15) */
#define TRAP_CAUSE_ADDR  0x100020
#define TRAP_PC_ADDR     0x100024
#define TRAP_TVAL_ADDR   0x100028
#define TRAP_DONE_ADDR   0x10002C

/* CHECK macro: if reg != imm32 jump to done_fail */
.macro CHECK reg, imm32, lineno
    li      t0, \imm32
    beq     \reg, t0, .Lcheck_ok_\lineno
    li      t0, FAILLN_ADDR
    li      t1, \lineno
    sw      t1, 0(t0)
    j       done_fail
.Lcheck_ok_\lineno:
.endm

/* ── _start: M-mode entry ─────────────────────────────────────────────────── */
.section .text.start
.global _start
_start:
    /* Set up M-mode trap vector for catching expected page faults */
    la      t0, m_trap_handler
    csrw    CSR_MTVEC, t0

    /* Delegate causes 12,13,15 (page faults) to S-mode via medeleg. */
    li      t0, (1 << 12) | (1 << 13) | (1 << 15)
    csrw    CSR_MEDELEG, t0

    /* Set S-mode trap vector */
    la      t0, s_trap_handler
    csrw    CSR_STVEC, t0

    /* Clear shared trap-state area */
    li      t0, TRAP_CAUSE_ADDR
    sw      zero, 0(t0)
    sw      zero, 4(t0)
    sw      zero, 8(t0)
    sw      zero, 12(t0)

    /* Drop to S-mode via mret */
    li      t0, ~(3 << 11)
    csrr    t1, CSR_MSTATUS
    and     t1, t1, t0
    li      t0, (1 << 11)   /* MPP=01 (S-mode) */
    or      t1, t1, t0
    csrw    CSR_MSTATUS, t1

    la      t0, smode_start
    csrw    CSR_MEPC, t0
    mret                            /* → smode_start in S-mode */

/* ── M-mode trap handler ──────────────────────────────────────────────────── */
.align 4
m_trap_handler:
    li      t0, FAILLN_ADDR
    li      t1, 1000
    sw      t1, 0(t0)
    j       done_fail

/* ── S-mode trap handler ──────────────────────────────────────────────────── */
.align 4
s_trap_handler:
    csrr    t0, CSR_SCAUSE
    li      t1, TRAP_CAUSE_ADDR
    sw      t0, 0(t1)
    csrr    t0, CSR_SEPC
    sw      t0, 4(t1)
    csrr    t0, CSR_STVAL
    sw      t0, 8(t1)
    li      t0, 1
    sw      t0, 12(t1)              /* trap_done = 1 */
    /* Skip the faulting instruction (4 bytes) */
    csrr    t0, CSR_SEPC
    addi    t0, t0, 4
    csrw    CSR_SEPC, t0
    sret

/* ── S-mode start ─────────────────────────────────────────────────────────── */
.align 4
.global smode_start
smode_start:

    /* ── Test 0: Sanity — load/store without MMU ─────────────────────── */
    li      a0, SCRATCH0
    li      a1, 0xDEAD1234
    sw      a1, 0(a0)
    lw      a2, 0(a0)
    CHECK   a2, 0xDEAD1234, 10

    /* ── Enable Sv32 MMU: satp = MODE=1 (bit31) | PPN=1 ─────────────── */
    li      t0, (1 << 31) | 1
    csrw    CSR_SATP, t0

    /* Barrier — SFENCE.VMA to flush any stale TLB state */
    sfence.vma

    /* ── Test 1: Load from mapped data page (VA 0x0010_0000) ─────────── */
    li      a0, SCRATCH0
    lw      a1, 0(a0)
    CHECK   a1, 0xDEAD1234, 20

    /* ── Test 2: Store to mapped data page ───────────────────────────── */
    li      a0, SCRATCH1
    li      a1, 0x12345678
    sw      a1, 0(a0)
    sfence.vma
    lw      a2, 0(a0)
    CHECK   a2, 0x12345678, 30

    /* ── Test 3: Load from R+X-only page (VA 0x0010_1000) ────────────── */
    li      a0, PAGE2_DATA
    lw      a2, 0(a0)
    /* Verify no fault triggered */
    li      t0, TRAP_DONE_ADDR
    lw      t1, 0(t0)
    CHECK   t1, 0, 40

    /* ── Test 4: Store to R+X-only page → store page fault (cause 15) ── */
    li      t0, TRAP_DONE_ADDR
    sw      zero, 0(t0)
    li      t0, TRAP_CAUSE_ADDR
    sw      zero, 0(t0)

    li      a0, PAGE2_DATA
    li      a1, 0xDEADBEEF
    sw      a1, 0(a0)               /* expect fault: no W permission */

    li      t0, TRAP_DONE_ADDR
    lw      t1, 0(t0)
    CHECK   t1, 1, 50

    li      t0, TRAP_CAUSE_ADDR
    lw      t1, 0(t0)
    CHECK   t1, 15, 51              /* store/AMO page fault */

    /* ── Test 5: Load from unmapped VA → load page fault (cause 13) ──── */
    li      t0, TRAP_DONE_ADDR
    sw      zero, 0(t0)
    li      t0, TRAP_CAUSE_ADDR
    sw      zero, 0(t0)

    /* VA 0x0100_0000: L1[4] is invalid → page fault */
    li      a0, 0x01000000
    lw      a1, 0(a0)               /* expect fault: invalid PTE at L1 */

    li      t0, TRAP_DONE_ADDR
    lw      t1, 0(t0)
    CHECK   t1, 1, 60

    li      t0, TRAP_CAUSE_ADDR
    lw      t1, 0(t0)
    CHECK   t1, 13, 61              /* load page fault */

    /* ── Test 6: SFENCE.VMA flushes TLB; re-access refills correctly ─── */
    li      a0, SCRATCH0
    li      a1, 0x99887766
    sw      a1, 0(a0)
    sfence.vma
    lw      a2, 0(a0)
    CHECK   a2, 0x99887766, 70

    /* ── All tests passed — write PASS ───────────────────────────────── */
    li      t0, RESULT_ADDR
    li      t1, 1
    sw      t1, 0(t0)
    j       done_ok

done_fail:
    li      t0, RESULT_ADDR
    sw      zero, 0(t0)
done_ok:
    li      t0, DONE_ADDR
    li      t1, 0xBEEFC0DE
    sw      t1, 0(t0)
.Lspin:
    j       .Lspin
