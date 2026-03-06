/*
 * smode_test.c — Phase 1 S-mode CSR test for NyanSoC.
 *
 * Tests:
 *   1. misa S-bit: verify bit 18 is set
 *   2. medeleg/mideleg read-write
 *   3. S-mode CSR access (stvec, sscratch, sepc, scause) from M-mode
 *   4. Drop to S-mode via mret, trigger ecall, return to M-mode
 *   5. satp write/read
 */

#include <stdint.h>

/* ── UART ──────────────────────────────────────────────────────────────── */
#define UART_BASE  0x00020000u
#define UART_TX    (*(volatile uint32_t *)(UART_BASE + 0x00))
#define UART_STAT  (*(volatile uint32_t *)(UART_BASE + 0x04))
#define UART_TX_FULL  (1u << 0)

static void uart_putc(char c) {
    while (UART_STAT & UART_TX_FULL) {}
    UART_TX = (uint8_t)c;
}

static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

static void uart_puthex(uint32_t v) {
    static const char hex[] = "0123456789ABCDEF";
    uart_putc(hex[(v >> 28) & 0xf]);
    uart_putc(hex[(v >> 24) & 0xf]);
    uart_putc(hex[(v >> 20) & 0xf]);
    uart_putc(hex[(v >> 16) & 0xf]);
    uart_putc(hex[(v >> 12) & 0xf]);
    uart_putc(hex[(v >>  8) & 0xf]);
    uart_putc(hex[(v >>  4) & 0xf]);
    uart_putc(hex[(v >>  0) & 0xf]);
}

static void print_result(const char *name, int pass) {
    uart_puts(pass ? "  PASS: " : "  FAIL: ");
    uart_puts(name);
    uart_puts("\r\n");
}

/* ── CSR helpers ───────────────────────────────────────────────────────── */
#define csrr(csr)        ({ uint32_t _v; asm volatile("csrr %0," #csr : "=r"(_v)); _v; })
#define csrw(csr, val)   asm volatile("csrw " #csr ", %0" :: "r"((uint32_t)(val)))
#define csrs(csr, mask)  asm volatile("csrs " #csr ", %0" :: "r"((uint32_t)(mask)))
#define csrc(csr, mask)  asm volatile("csrc " #csr ", %0" :: "r"((uint32_t)(mask)))

/* ── Shared state for trap handlers ───────────────────────────────────── */
volatile uint32_t m_trap_cause;
volatile uint32_t m_trap_epc;
volatile uint32_t s_trap_cause;
volatile uint32_t s_trap_epc;
volatile int      s_trap_count;

/* Return address M-mode uses when redirecting after S-mode ecall */
extern void after_smode_run(void);

/* ── M-mode trap handler ────────────────────────────────────────────────
 * Called from mtrap_handler in start.S.
 * For S-mode ecall (cause=9): redirect mepc to after_smode_run so
 * execution returns to M-mode main() after the mret.
 */
void m_trap_handler(void) {
    m_trap_cause = csrr(mcause);
    m_trap_epc   = csrr(mepc);
    if (m_trap_cause == 9) {
        /* S-mode ecall: jump back to M-mode continuation */
        csrw(mepc, (uint32_t)after_smode_run);
    } else {
        /* Advance past faulting instruction for other traps */
        csrw(mepc, m_trap_epc + 4);
    }
}

/* ── S-mode trap handler ────────────────────────────────────────────────
 * Called from strap_handler in start.S.
 * Records cause and advances sepc past the trapping instruction.
 */
void s_trap_handler(void) {
    s_trap_cause = csrr(scause);
    s_trap_epc   = csrr(sepc);
    s_trap_count++;
    csrw(sepc, s_trap_epc + 4);
}

/* ── S-mode payload ─────────────────────────────────────────────────────
 * Runs in S-mode.  Writes sscratch, then does an ecall (cause=9) which
 * is NOT delegated to S-mode, so M-mode catches it and redirects to
 * after_smode_run.
 */
__attribute__((noinline))
static void smode_payload(void) {
    csrw(sscratch, 0xCAFEBABEu);
    asm volatile("ecall");  /* cause=9: S-mode ecall → M-mode handler */
    /* Not reached — M-mode redirects mepc to after_smode_run */
    while (1) {}
}

/* ── Main ──────────────────────────────────────────────────────────────── */
int main(void) {
    uart_puts("\r\n=== NyanSoC S-mode test ===\r\n");

    int pass_count = 0;
    int fail_count = 0;
#define CHECK(name, cond) do { \
    int _p = (cond); \
    print_result(name, _p); \
    if (_p) pass_count++; else fail_count++; \
} while(0)

    /* ── Test 1: misa S-bit ─────────────────────────────────────────── */
    uart_puts("\nTest 1: misa S-extension bit\r\n");
    uint32_t misa_val = csrr(misa);
    uart_puts("  misa = 0x"); uart_puthex(misa_val); uart_puts("\r\n");
    CHECK("misa[18] S-bit set", (misa_val >> 18) & 1);

    /* ── Test 2: medeleg/mideleg read-write ─────────────────────────── */
    uart_puts("\nTest 2: medeleg/mideleg\r\n");
    csrw(medeleg, (1u << 8) | (1u << 2));
    uint32_t edel = csrr(medeleg);
    uart_puts("  medeleg = 0x"); uart_puthex(edel); uart_puts("\r\n");
    CHECK("medeleg write/read", edel == ((1u << 8) | (1u << 2)));

    csrw(mideleg, (1u << 5) | (1u << 1));
    uint32_t idel = csrr(mideleg);
    uart_puts("  mideleg = 0x"); uart_puthex(idel); uart_puts("\r\n");
    CHECK("mideleg write/read", idel == ((1u << 5) | (1u << 1)));

    /* ── Test 3: S-mode CSR access from M-mode ───────────────────────── */
    uart_puts("\nTest 3: S-mode CSR access from M-mode\r\n");

    extern void strap_handler(void);
    csrw(stvec, (uint32_t)strap_handler);
    uint32_t sv = csrr(stvec);
    uart_puts("  stvec = 0x"); uart_puthex(sv); uart_puts("\r\n");
    CHECK("stvec write/read", sv == (uint32_t)strap_handler);

    csrw(sscratch, 0x12345678u);
    uint32_t sc = csrr(sscratch);
    CHECK("sscratch write/read from M-mode", sc == 0x12345678u);

    /* ── Test 4: Drop to S-mode, ecall back to M-mode ────────────────── */
    uart_puts("\nTest 4: S-mode ecall reaches M-mode\r\n");

    /* Only delegate U-mode ecall (cause 8), NOT S-mode ecall (cause 9) */
    csrw(medeleg, (1u << 8));

    m_trap_cause = 0;
    s_trap_count = 0;

    /* Set MPP=01 (S-mode), MPIE=1, mepc=smode_payload, then mret */
    uint32_t ms = csrr(mstatus);
    ms &= ~(3u << 11);   /* clear MPP */
    ms |=  (1u << 11);   /* MPP = 01 (S-mode) */
    ms |=  (1u << 7);    /* MPIE = 1 */
    csrw(mstatus, ms);
    csrw(mepc, (uint32_t)smode_payload);
    asm volatile(
        "mret\n"
        /* M-mode trap handler redirects mepc here on S-mode ecall */
        ".global after_smode_run\n"
        "after_smode_run:\n"
        ::: "memory"
    );

    uart_puts("  m_trap_cause = 0x"); uart_puthex(m_trap_cause); uart_puts("\r\n");
    CHECK("S-mode ecall reaches M-mode (cause=9)", m_trap_cause == 9);

    /* Verify sscratch was written by S-mode payload */
    uint32_t sc2 = csrr(sscratch);
    uart_puts("  sscratch after S-mode = 0x"); uart_puthex(sc2); uart_puts("\r\n");
    CHECK("sscratch written in S-mode", sc2 == 0xCAFEBABEu);

    /* ── Test 5: satp write/read ─────────────────────────────────────── */
    uart_puts("\nTest 5: satp write/read\r\n");
    csrw(satp, 0x00000000u);
    uint32_t satp_val = csrr(satp);
    uart_puts("  satp(bare) = 0x"); uart_puthex(satp_val); uart_puts("\r\n");
    CHECK("satp bare mode (0)", satp_val == 0u);

    csrw(satp, (1u << 31) | 0x00001u);
    satp_val = csrr(satp);
    uart_puts("  satp(Sv32) = 0x"); uart_puthex(satp_val); uart_puts("\r\n");
    CHECK("satp Sv32 mode bit set", (satp_val >> 31) == 1u);
    CHECK("satp PPN preserved", (satp_val & 0x3FFFFFu) == 0x1u);

    /* ── Summary ─────────────────────────────────────────────────────── */
    uart_puts("\r\n=== Results: ");
    uart_puthex((uint32_t)pass_count);
    uart_puts(" passed, ");
    uart_puthex((uint32_t)fail_count);
    uart_puts(" failed ===\r\n");
    if (fail_count == 0)
        uart_puts("=== ALL PASS ===\r\n");
    else
        uart_puts("=== SOME FAILURES ===\r\n");

    return 0;
}
