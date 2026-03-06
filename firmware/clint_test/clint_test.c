/* clint_test.c — NyanSoC CLINT smoke test.
 *
 * Tests:
 *   1. mtime is counting  (read it twice, confirm it increased)
 *   2. Timer interrupt fires  (set mtimecmp = mtime + DELAY, enable interrupts,
 *      spin until irq_count > 0, then disable)
 *   3. Interrupt clears when mtimecmp is pushed forward
 *   4. Multiple back-to-back interrupts
 *
 * CLINT memory map (standard RISC-V, 0x0200_0000):
 *   +0x0  mtime    lo
 *   +0x4  mtime    hi
 *   +0x8  mtimecmp lo
 *   +0xC  mtimecmp hi
 */

#define UART_TX      ((volatile unsigned int *)0x00030004)

#define MTIME_LO     ((volatile unsigned int *)0x02000000)
#define MTIME_HI     ((volatile unsigned int *)0x02000004)
#define MTIMECMP_LO  ((volatile unsigned int *)0x02000008)
#define MTIMECMP_HI  ((volatile unsigned int *)0x0200000C)

/* CSR helpers */
#define csrr(csr)        ({ unsigned int _v; asm volatile("csrr %0," #csr : "=r"(_v)); _v; })
#define csrw(csr, val)   asm volatile("csrw " #csr ", %0" :: "r"((unsigned int)(val)))
#define csrs(csr, bits)  asm volatile("csrs " #csr ", %0" :: "r"((unsigned int)(bits)))
#define csrc(csr, bits)  asm volatile("csrc " #csr ", %0" :: "r"((unsigned int)(bits)))

/* mstatus.MIE = bit 3 */
#define MSTATUS_MIE  (1u << 3)
/* mie.MTIE = bit 7 */
#define MIE_MTIE     (1u << 7)
/* mcause interrupt bit */
#define MCAUSE_IRQ   (1u << 31)
/* machine timer interrupt cause = 7 */
#define CAUSE_MTI    7u

/* ── Globals updated by the trap handler ─────────────────────────────── */
volatile unsigned int irq_count  = 0;
volatile unsigned int irq_mcause = 0;

/* Called from trap_handler in start.S */
void c_trap_handler(void)
{
    unsigned int cause = csrr(mcause);
    irq_mcause = cause;

    if ((cause & MCAUSE_IRQ) && ((cause & 0x1F) == CAUSE_MTI)) {
        irq_count++;
        /* Push mtimecmp far into the future to clear the interrupt.
         * Write hi first (set to max), then lo — this avoids a spurious
         * re-trigger between the two 32-bit writes. */
        *MTIMECMP_HI = 0xFFFFFFFFu;
        *MTIMECMP_LO = 0xFFFFFFFFu;
    }
}

/* ── UART helpers ────────────────────────────────────────────────────── */
static void uart_putc(char c)
{
    while (*UART_TX & 1u) ;
    *UART_TX = (unsigned int)(unsigned char)c;
}

static void uart_puts(const char *s)
{
    while (*s) uart_putc(*s++);
}

static void uart_puthex(unsigned int v)
{
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4) {
        unsigned int n = (v >> i) & 0xFu;
        uart_putc(n < 10 ? '0' + n : 'A' + n - 10);
    }
}

static void uart_putuint(unsigned int v)
{
    char buf[11]; int i = 0;
    if (!v) { uart_putc('0'); return; }
    while (v) { buf[i++] = '0' + v % 10; v /= 10; }
    while (i--) uart_putc(buf[i]);
}

/* ── mtime read (64-bit, safe against carry between lo/hi reads) ─────── */
static unsigned long long mtime_read(void)
{
    unsigned int hi0, lo, hi1;
    do {
        hi0 = *MTIME_HI;
        lo  = *MTIME_LO;
        hi1 = *MTIME_HI;
    } while (hi0 != hi1);
    return ((unsigned long long)hi1 << 32) | lo;
}

/* ── mtimecmp write (64-bit, avoids spurious IRQ during update) ──────── */
static void mtimecmp_write(unsigned long long val)
{
    /* Write hi=MAX first so the comparator never fires between the two writes */
    *MTIMECMP_HI = 0xFFFFFFFFu;
    *MTIMECMP_LO = (unsigned int)(val & 0xFFFFFFFFu);
    *MTIMECMP_HI = (unsigned int)(val >> 32);
}

/* ── Timeout loop (returns 0 on timeout) ────────────────────────────── */
#define TIMEOUT 50000000u  /* ~1.8 s at 27 MHz */

/* ── Main ────────────────────────────────────────────────────────────── */
int main(void)
{
    uart_puts("\r\n=== NyanSoC CLINT test ===\r\n");

    /* ── Test 1: mtime is counting ─────────────────────────────────── */
    uart_puts("\r\nTest 1: mtime counting...\r\n");
    unsigned long long t0 = mtime_read();
    /* Burn some cycles */
    for (volatile unsigned int i = 0; i < 1000; i++) ;
    unsigned long long t1 = mtime_read();

    uart_puts("  mtime[0] = ");
    uart_puthex((unsigned int)(t0 >> 32));
    uart_putc(':');
    uart_puthex((unsigned int)t0);
    uart_puts("\r\n  mtime[1] = ");
    uart_puthex((unsigned int)(t1 >> 32));
    uart_putc(':');
    uart_puthex((unsigned int)t1);
    uart_puts("\r\n");

    if (t1 > t0) {
        uart_puts("  PASS (mtime is counting)\r\n");
    } else {
        uart_puts("  FAIL (mtime did not advance)\r\n");
        goto done;
    }

    /* ── Test 2: timer interrupt fires ────────────────────────────── */
    uart_puts("\r\nTest 2: timer interrupt...\r\n");

    irq_count = 0;

    /* Schedule interrupt 10000 cycles from now */
    unsigned long long now = mtime_read();
    mtimecmp_write(now + 10000ULL);

    /* Enable machine timer interrupt and global MIE */
    csrs(mie, MIE_MTIE);
    csrs(mstatus, MSTATUS_MIE);

    /* Spin until interrupt fires (or timeout) */
    unsigned int timeout = TIMEOUT;
    while (irq_count == 0 && --timeout) ;

    /* Disable interrupts */
    csrc(mstatus, MSTATUS_MIE);
    csrc(mie, MIE_MTIE);

    if (irq_count > 0) {
        uart_puts("  PASS (irq fired, mcause=");
        uart_puthex(irq_mcause);
        uart_puts(")\r\n");
    } else {
        uart_puts("  FAIL (timeout waiting for timer IRQ)\r\n");
        uart_puts("  mtime    = ");
        uart_puthex((unsigned int)(mtime_read() >> 32));
        uart_putc(':');
        uart_puthex((unsigned int)mtime_read());
        uart_puts("\r\n  mtimecmp = ");
        uart_puthex(*MTIMECMP_HI);
        uart_putc(':');
        uart_puthex(*MTIMECMP_LO);
        uart_puts("\r\n");
        goto done;
    }

    /* ── Test 3: interrupt clears after mtimecmp pushed forward ───── */
    uart_puts("\r\nTest 3: interrupt clears...\r\n");

    /* Set mtimecmp to now + small delta, enable, let it fire */
    irq_count = 0;
    now = mtime_read();
    mtimecmp_write(now + 5000ULL);
    csrs(mie, MIE_MTIE);
    csrs(mstatus, MSTATUS_MIE);
    timeout = TIMEOUT;
    while (irq_count == 0 && --timeout) ;
    csrc(mstatus, MSTATUS_MIE);
    csrc(mie, MIE_MTIE);

    if (irq_count == 1) {
        uart_puts("  PASS (exactly 1 interrupt, then cleared)\r\n");
    } else if (irq_count == 0) {
        uart_puts("  FAIL (no interrupt)\r\n");
        goto done;
    } else {
        uart_puts("  FAIL (spurious extra interrupts, count=");
        uart_putuint(irq_count);
        uart_puts(")\r\n");
        goto done;
    }

    /* ── Test 4: multiple back-to-back interrupts ──────────────────── */
    uart_puts("\r\nTest 4: 5 back-to-back interrupts...\r\n");

    /* Modify handler behaviour: instead of pushing mtimecmp to MAX,
     * schedule the next interrupt 2000 cycles out, up to 5 times. */
    irq_count = 0;

    /* We'll do this by re-enabling after each IRQ from here in main,
     * using a simple loop. */
    for (unsigned int i = 0; i < 5; i++) {
        now = mtime_read();
        mtimecmp_write(now + 2000ULL);
        csrs(mie, MIE_MTIE);
        csrs(mstatus, MSTATUS_MIE);
        unsigned int prev = irq_count;
        timeout = TIMEOUT;
        while (irq_count == prev && --timeout) ;
        csrc(mstatus, MSTATUS_MIE);
        csrc(mie, MIE_MTIE);
        if (!timeout) {
            uart_puts("  FAIL (timeout on interrupt ");
            uart_putuint(i + 1);
            uart_puts(")\r\n");
            goto done;
        }
    }
    uart_puts("  PASS (5 interrupts fired)\r\n");

done:
    uart_puts("\r\n=== CLINT test done ===\r\n");
    return 0;
}
