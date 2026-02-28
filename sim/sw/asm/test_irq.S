/* test_irq.S
 * Tests machine external interrupt (MEI) and machine timer interrupt (MTI).
 *
 * Layout:
 *   imem[0x000]: _start (crt0 calls test_main)
 *   imem[irq_handler]: interrupt handler
 *   dmem[0x10000]: PASS/FAIL (written by crt0 with test_main return value)
 *   dmem[0x10004]: irq_count — number of interrupts handled so far
 *
 * Test sequence:
 *   1. Install handler at mtvec.
 *   2. Enable MEIE (mie[11]) and MTIE (mie[7]) in mie.
 *   3. Enable MIE (mstatus[3]).
 *   4. Spin until irq_count reaches 2 (one MEI + one MTI).
 *      The testbench asserts i_irq_external for the first interrupt and
 *      i_irq_timer for the second, each held until the handler runs.
 *   5. Verify that mcause was correct for each interrupt (stored by handler).
 *   6. Return 1 on PASS, 0 on FAIL.
 *
 * The handler:
 *   - Increments irq_count at dmem[0x10004].
 *   - Stores mcause at dmem[0x10008] (first irq) and dmem[0x1000c] (second).
 *   - MRETs.
 *
 * Register usage in test_main: a0=return, t0-t5=scratch, s0=irq_count ptr.
 */

.equ CSR_MSTATUS,  0x300
.equ CSR_MIE,      0x304
.equ CSR_MTVEC,    0x305
.equ CSR_MSCRATCH, 0x340
.equ CSR_MEPC,     0x341
.equ CSR_MCAUSE,   0x342
.equ CSR_MHARTID,  0xF14

.equ RESULT_ADDR,  0x00010000   /* dmem[0]: PASS=1 / FAIL=0         */
.equ IRQ_COUNT,    0x00010004   /* dmem[1]: number of IRQs handled   */
.equ CAUSE_0,      0x00010008   /* dmem[2]: mcause of 1st interrupt  */
.equ CAUSE_1,      0x0001000c   /* dmem[3]: mcause of 2nd interrupt  */

.equ MCAUSE_MEI,   0x8000000b   /* Machine external interrupt        */
.equ MCAUSE_MTI,   0x80000007   /* Machine timer interrupt           */

    .text
    .global test_main
test_main:
    /* ── Step 1: Install interrupt handler ───────────────────────── */
    la   t0, irq_handler
    csrw mtvec, t0

    /* ── Step 2: Enable MEI and MTI in mie ───────────────────────── */
    /* mie[11]=MEIE, mie[7]=MTIE */
    li   t0, (1 << 11) | (1 << 7)
    csrw mie, t0

    /* ── Step 3: Enable global interrupts (mstatus.MIE = bit 3) ──── */
    csrsi mstatus, 8

    /* ── Step 4: Spin until two interrupts have been handled ──────── */
    li   s0, IRQ_COUNT

    /* Wait for first interrupt (MEI) */
spin1:
    lw   t0, 0(s0)
    beqz t0, spin1

    /* Re-enable MTIE for the second interrupt */
    li   t0, (1 << 7)
    csrs mie, t0

spin2:
    lw   t0, 0(s0)          /* load irq_count                        */
    li   t1, 2
    blt  t0, t1, spin2      /* loop until count reaches 2            */

    /* ── Step 5: Verify causes stored by handler ─────────────────── */
    /* First interrupt must have been MEI (external) */
    lw   t0, (CAUSE_0 - IRQ_COUNT)(s0)
    li   t1, MCAUSE_MEI
    bne  t0, t1, fail

    /* Second interrupt must have been MTI (timer) */
    lw   t0, (CAUSE_1 - IRQ_COUNT)(s0)
    li   t1, MCAUSE_MTI
    bne  t0, t1, fail

pass:
    li   a0, 1
    ret

fail:
    li   a0, 0
    ret

/* ── Interrupt handler ──────────────────────────────────────────────
 * Saves/restores no registers — the test_main spin loop only reads
 * memory after interrupts are done, so no caller-saved regs are live.
 * In real code you would save/restore the full context.
 *
 * The handler clears the enable bit for whichever source fired so
 * the interrupt does not immediately re-enter after MRET (the line
 * stays asserted until the testbench deasserts it).  test_main
 * re-enables the next source's bit before releasing the spin.
 */
    .balign 4
irq_handler:
    csrr t0, mcause
    /* Only handle interrupts (mcause bit 31 set); re-raise anything else. */
    bltz t0, .Lirq_ok
    /* This is an exception (ebreak/ecall/trap) — not expected.  Spin. */
.Lunexpected:
    j    .Lunexpected

.Lirq_ok:
    /* Disable the source that fired so we don't re-enter immediately */
    li   t1, (1 << 11)          /* MEIE mask                         */
    li   t3, (1 << 7)           /* MTIE mask                         */
    li   t4, MCAUSE_MEI
    beq  t0, t4, .Ldisable_mei
    csrc mie, t3                /* disable MTIE                      */
    j    .Lrecord
.Ldisable_mei:
    csrc mie, t1                /* disable MEIE                      */

.Lrecord:
    /* Store mcause and increment irq_count */
    li   t1, IRQ_COUNT
    lw   t2, 0(t1)              /* current count                     */
    li   t3, 0
    beq  t2, t3, .Lstore_cause0
    /* second interrupt → CAUSE_1 */
    sw   t0, (CAUSE_1 - IRQ_COUNT)(t1)
    j    .Linc
.Lstore_cause0:
    sw   t0, (CAUSE_0 - IRQ_COUNT)(t1)
.Linc:
    addi t2, t2, 1
    sw   t2, 0(t1)              /* irq_count++                       */
    mret
