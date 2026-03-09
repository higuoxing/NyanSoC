/* sdram_direct_test.c - NyanSoC SDRAM direct-map access test.
 *
 * Verifies that the CPU can read and write SDRAM via its direct-mapped
 * address window at 0x8000_0000–0x81FF_FFFF without using the legacy
 * register-mapped interface.
 *
 * Test sequence:
 *   1. Wait for SDRAM init_done (polled via legacy ctrl register).
 *   2. Write a walking-ones pattern to 64 words starting at 0x8000_0000.
 *   3. Read back via the same direct-mapped window and compare.
 *   4. Write byte-enable patterns (SW, SH, SB) and verify.
 *   5. Write to a second 4KB page (0x8000_1000) and verify.
 *   6. Report total PASS/FAIL.
 */

#define SDRAM_CTRL ((volatile unsigned int *)0x00050000)
#define UART_TX    ((volatile unsigned int *)0x00030004)

#define SDRAM_INIT_DONE (1u << 1)

/* Direct-mapped SDRAM window */
#define SDRAM_BASE ((volatile unsigned int *)0x80000000)

#define TEST_WORDS  64u
#define PAGE_WORDS  (0x1000 / 4)   /* 1 KiB in 32-bit words */

static void uart_putc(unsigned char c)
{
    while (*UART_TX & 1)
        ;
    *UART_TX = c;
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc((unsigned char)*s++);
}

static void uart_puthex(unsigned int v)
{
    const char *hex = "0123456789ABCDEF";
    uart_putc('0'); uart_putc('x');
    for (int i = 28; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xf]);
}

static unsigned int pass_total, fail_total;

static void check(unsigned int addr_idx, unsigned int got, unsigned int expected)
{
    if (got == expected) {
        pass_total++;
    } else {
        uart_puts("  FAIL [");
        uart_puthex(addr_idx);
        uart_puts("] expected=");
        uart_puthex(expected);
        uart_puts(" got=");
        uart_puthex(got);
        uart_puts("\r\n");
        fail_total++;
    }
}

int main(void)
{
    uart_puts("\r\n=== NyanSoC SDRAM Direct-Map Test ===\r\n");

    uart_puts("Waiting for SDRAM init...\r\n");
    while (!(*SDRAM_CTRL & SDRAM_INIT_DONE))
        ;
    uart_puts("SDRAM init done.\r\n");

    pass_total = 0;
    fail_total = 0;

    /* ── Test 1: 32-bit word write + read ─────────────────────────────────── */
    uart_puts("Test 1: 32-bit W+R (");
    uart_puthex(TEST_WORDS);
    uart_puts(" words at 0x80000000)...\r\n");

    volatile unsigned int *sdram = SDRAM_BASE;

    uart_puts("  Writing...\r\n");
    for (unsigned int i = 0; i < TEST_WORDS; i++) {
        unsigned int pattern = 0xA5000000u | (i << 8) | i;
        uart_puts("  W["); uart_puthex(i); uart_puts("]="); uart_puthex(pattern); uart_puts("\r\n");
        sdram[i] = pattern;
        uart_puts("  W["); uart_puthex(i); uart_puts("] done\r\n");
    }
    uart_puts("  Reading...\r\n");
    for (unsigned int i = 0; i < TEST_WORDS; i++) {
        unsigned int pattern = 0xA5000000u | (i << 8) | i;
        uart_puts("  R["); uart_puthex(i); uart_puts("]...\r\n");
        unsigned int got = sdram[i];
        uart_puts("  R["); uart_puthex(i); uart_puts("]="); uart_puthex(got); uart_puts("\r\n");
        check(i, got, pattern);
    }

    /* ── Test 2: Byte (SB/LBU) write ──────────────────────────────────────── */
    uart_puts("Test 2: byte-enable writes...\r\n");

    volatile unsigned char *sdram_b = (volatile unsigned char *)0x80001000u;

    uart_puts("  T2a: SW zero\r\n");
    ((volatile unsigned int *)sdram_b)[0] = 0x00000000u;
    uart_puts("  T2b: SB[0]=0xDE\r\n");
    sdram_b[0] = 0xDE;
    uart_puts("  T2c: LW\r\n");
    unsigned int word = ((volatile unsigned int *)sdram_b)[0];
    uart_puts("  T2c got="); uart_puthex(word); uart_puts("\r\n");
    check(0x1000, word, 0x000000DEu);

    uart_puts("  T2d: SB[1]=0xAD\r\n");
    sdram_b[1] = 0xAD;
    uart_puts("  T2e: LW\r\n");
    word = ((volatile unsigned int *)sdram_b)[0];
    uart_puts("  T2e got="); uart_puthex(word); uart_puts("\r\n");
    check(0x1001, word, 0x0000ADDEu);

    uart_puts("  T2f: SB[2]=0xBE\r\n");
    sdram_b[2] = 0xBE;
    uart_puts("  T2g: LW\r\n");
    word = ((volatile unsigned int *)sdram_b)[0];
    uart_puts("  T2g got="); uart_puthex(word); uart_puts("\r\n");
    check(0x1002, word, 0x00BEADDEu);

    uart_puts("  T2h: SB[3]=0xEF\r\n");
    sdram_b[3] = 0xEF;
    uart_puts("  T2i: LW\r\n");
    word = ((volatile unsigned int *)sdram_b)[0];
    uart_puts("  T2i got="); uart_puthex(word); uart_puts("\r\n");
    check(0x1003, word, 0xEFBEADDEu);

    /* ── Test 3: Halfword (SH/LHU) write ─────────────────────────────────── */
    uart_puts("Test 3: halfword writes...\r\n");

    volatile unsigned short *sdram_h = (volatile unsigned short *)(0x80001100u);
    uart_puts("  T3a: SW zero\r\n");
    ((volatile unsigned int *)sdram_h)[0] = 0x00000000u;

    uart_puts("  T3b: SH[0]=0x1234\r\n");
    sdram_h[0] = 0x1234u;
    uart_puts("  T3c: LW\r\n");
    word = ((volatile unsigned int *)sdram_h)[0];
    uart_puts("  T3c got="); uart_puthex(word); uart_puts("\r\n");
    check(0x1100, word, 0x00001234u);

    uart_puts("  T3d: SH[1]=0x5678\r\n");
    sdram_h[1] = 0x5678u;
    uart_puts("  T3e: LW\r\n");
    word = ((volatile unsigned int *)sdram_h)[0];
    uart_puts("  T3e got="); uart_puthex(word); uart_puts("\r\n");
    check(0x1101, word, 0x56781234u);

    /* ── Test 4: second 4 KB page ─────────────────────────────────────────── */
    uart_puts("Test 4: second 4KB page (0x80001000)...\r\n");

    volatile unsigned int *page1 = (volatile unsigned int *)0x80001000u;
    for (unsigned int i = 0; i < 8u; i++) {
        uart_puts("  T4W["); uart_puthex(i); uart_puts("]\r\n");
        page1[i] = 0xDEAD0000u | i;
    }
    for (unsigned int i = 0; i < 8u; i++) {
        uart_puts("  T4R["); uart_puthex(i); uart_puts("]\r\n");
        check(0x1000 + i, page1[i], 0xDEAD0000u | i);
    }

    /* ── Summary ───────────────────────────────────────────────────────────── */
    uart_puts("\r\n=== Results ===\r\n");
    uart_puthex(pass_total);
    uart_puts(" passed, ");
    uart_puthex(fail_total);
    uart_puts(" failed\r\n");

    if (fail_total == 0)
        uart_puts("*** ALL PASS ***\r\n");
    else
        uart_puts("*** FAILURES DETECTED ***\r\n");

    uart_puts("=== DONE ===\r\n");
    return 0;
}
