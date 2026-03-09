/* plic_test.c — NyanSoC PLIC hardware verification
 *
 * Tests:
 *  1. Reset state: all PLIC registers read as 0.
 *  2. Priority / enable / threshold registers are R/W.
 *  3. Send a UART TX byte, loop it back via RX → PLIC pending bit set.
 *  4. After configuration (priority=1, enable=1, threshold=0), IRQ fires.
 *  5. Claim register returns source ID 1 and clears pending.
 *  6. After claim, IRQ deasserted (no pending source above threshold).
 *
 * The test runs in M-mode.  External interrupts are polled via meip
 * (mip.MEIP bit 11) since we haven't set up a trap handler here — we
 * just want to verify the PLIC logic drives the irq_external line.
 *
 * NOTE: UART RX loopback requires the board's RX pin to be wired back to
 * TX (or use a terminal that echoes).  On Tang Nano 20K the UART goes to
 * the onboard USB-serial bridge which does NOT auto-echo, so we instead
 * test the PLIC register interface directly without requiring actual UART
 * traffic.  The pending bit is verified by reading PLIC registers after
 * the UART RX fires (observed from a terminal sending a character).
 *
 * For a self-contained test (no terminal echo), we verify:
 *   - Register R/W works correctly.
 *   - IRQ output is masked by enable/threshold correctly.
 *   - The claim/complete protocol clears pending.
 *
 * Run with picocom: type any character to trigger the PLIC source.
 */

#define UART_RX    ((volatile unsigned int *)0x00030000)
#define UART_TX    ((volatile unsigned int *)0x00030004)

/* PLIC base = 0x0C00_0000 */
#define PLIC_PRIO1     ((volatile unsigned int *)0x0C000004)
#define PLIC_PENDING0  ((volatile unsigned int *)0x0C001000)
#define PLIC_ENABLE0   ((volatile unsigned int *)0x0C002000)
#define PLIC_THRESHOLD ((volatile unsigned int *)0x0C200000)
#define PLIC_CLAIM     ((volatile unsigned int *)0x0C200004)

/* CSR helpers */
#define read_csr(reg)       ({ unsigned int __v; \
    __asm__ volatile ("csrr %0, " #reg : "=r"(__v)); __v; })
#define set_csr(reg, bit)   __asm__ volatile ("csrs " #reg ", %0" :: "rK"(bit))
#define clear_csr(reg, bit) __asm__ volatile ("csrc " #reg ", %0" :: "rK"(bit))

#define MIP_MEIP   (1u << 11)   /* machine external interrupt pending */
#define MIE_MEIE   (1u << 11)   /* machine external interrupt enable  */

static void uart_putc(unsigned char c)
{
    while (*UART_TX & 1);
    *UART_TX = c;
}

static void uart_puts(const char *s)
{
    while (*s) uart_putc((unsigned char)*s++);
}

static void uart_puthex(unsigned int v)
{
    const char *h = "0123456789ABCDEF";
    uart_putc('0'); uart_putc('x');
    for (int i = 28; i >= 0; i -= 4)
        uart_putc(h[(v >> i) & 0xF]);
}

static unsigned int pass, fail;

static void check(const char *name, unsigned int got, unsigned int expected)
{
    if (got == expected) {
        uart_puts("  PASS "); uart_puts(name); uart_puts("\r\n");
        pass++;
    } else {
        uart_puts("  FAIL "); uart_puts(name);
        uart_puts(" got="); uart_puthex(got);
        uart_puts(" exp="); uart_puthex(expected);
        uart_puts("\r\n");
        fail++;
    }
}

int main(void)
{
    uart_puts("\r\n=== NyanSoC PLIC Test ===\r\n");

    pass = 0; fail = 0;

    /* ── 1. Reset state ─────────────────────────────────────────────────── */
    uart_puts("1. Reset state\r\n");
    check("prio1=0",     *PLIC_PRIO1,     0);
    check("pending0=0",  *PLIC_PENDING0,  0);
    check("enable0=0",   *PLIC_ENABLE0,   0);
    check("threshold=0", *PLIC_THRESHOLD, 0);
    check("claim=0",     *PLIC_CLAIM,     0);

    /* ── 2. R/W registers ──────────────────────────────────────────────── */
    uart_puts("2. Register R/W\r\n");

    *PLIC_PRIO1     = 7;
    check("prio1=7",     *PLIC_PRIO1, 7);
    *PLIC_PRIO1     = 0;

    *PLIC_ENABLE0   = 2;   /* bit[1] = src1 */
    check("enable=2",    *PLIC_ENABLE0, 2);
    *PLIC_ENABLE0   = 0;

    *PLIC_THRESHOLD = 3;
    check("thr=3",       *PLIC_THRESHOLD, 3);
    *PLIC_THRESHOLD = 0;

    /* ── 3. Pending from UART RX (requires terminal to send a byte) ────── */
    uart_puts("3. Waiting for UART RX byte (send any char from terminal)...\r\n");

    /* Enable UART RX interrupt in PLIC (priority=1, enable=1, threshold=0) */
    *PLIC_PRIO1     = 1;
    *PLIC_ENABLE0   = 2;   /* bit[1] */
    *PLIC_THRESHOLD = 0;

    /* Enable machine external interrupts in mstatus/mie */
    set_csr(mie, MIE_MEIE);

    /* Poll mip.MEIP — set by CPU when irq_external is asserted */
    unsigned int waited = 0;
    while (!(read_csr(mip) & MIP_MEIP)) {
        waited++;
        if (waited == 0x4000000u) {
            uart_puts("  TIMEOUT waiting for IRQ\r\n");
            fail++;
            goto summary;
        }
    }
    uart_puts("  IRQ asserted (mip.MEIP=1)\r\n");
    check("pending_set", (*PLIC_PENDING0 >> 1) & 1, 1);

    /* ── 4. Claim ───────────────────────────────────────────────────────── */
    uart_puts("4. Claim\r\n");
    unsigned int claimed = *PLIC_CLAIM;
    check("claim_id=1",  claimed, 1);

    /* ── 5. Post-claim: pending cleared, IRQ deasserted ───────────────── */
    uart_puts("5. Post-claim state\r\n");
    check("pending_clr", (*PLIC_PENDING0 >> 1) & 1, 0);
    /* Write complete */
    *PLIC_CLAIM = claimed;
    /* IRQ should now be deasserted */
    check("mip_cleared", (read_csr(mip) >> 11) & 1, 0);

summary:
    uart_puts("\r\n=== Results: ");
    uart_puthex(pass); uart_puts(" passed, ");
    uart_puthex(fail); uart_puts(" failed ===\r\n");
    if (fail == 0)
        uart_puts("*** ALL PASS ***\r\n");
    else
        uart_puts("*** FAILURES ***\r\n");

    uart_puts("=== DONE ===\r\n");
    return 0;
}
