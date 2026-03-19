/* sdram_test.c - NyanSoC SDRAM direct-map test firmware.
 *
 * Exercises SDRAM through the CPU direct-map window (0x8000_0000–0x81FF_FFFF).
 * All sequencing (issue, wait for ack, wait for ready) is handled by the
 * hardware FSM in top.v — the firmware just does ordinary loads and stores.
 *
 * The test data region starts at 0x8010_0000 (1 MiB above the load address)
 * to avoid aliasing with the executing code and its instruction-fetch stream.
 *
 * Memory map:
 *   0x8000_0000  code/stack (loaded here by uart_loader)
 *   0x8010_0000  test data region (well above the ~1 KiB binary)
 *   0x0003_0004  UART TX  write: send byte; read: {31'b0, busy}
 */

#define SDRAM_TEST ((volatile unsigned int *)0x80100000)
#define UART_TX    ((volatile unsigned int *)0x00030004)

#define TEST_WORDS 256

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

int main(void)
{
    uart_puts("\r\nSDRAM direct-map test starting...\r\n");
    uart_puts("Writing ");
    uart_puthex(TEST_WORDS);
    uart_puts(" words...\r\n");

    /* Write phase: store a pattern to each SDRAM word address. */
    for (unsigned int i = 0; i < TEST_WORDS; i++) {
        unsigned int pattern = 0xA5000000u | (i << 8) | i;
        SDRAM_TEST[i] = pattern;
    }

    uart_puts("Verifying...\r\n");

    /* Read-back phase: compare each word against the expected pattern. */
    unsigned int pass = 0, fail = 0;
    for (unsigned int i = 0; i < TEST_WORDS; i++) {
        unsigned int expected = 0xA5000000u | (i << 8) | i;
        unsigned int got      = SDRAM_TEST[i];
        if (got == expected) {
            pass++;
        } else {
            uart_puts("  FAIL addr=");
            uart_puthex(i);
            uart_puts(" expected=");
            uart_puthex(expected);
            uart_puts(" got=");
            uart_puthex(got);
            uart_puts("\r\n");
            fail++;
        }
    }

    uart_puts("\r\nResult: ");
    uart_puthex(pass);
    uart_puts(" passed, ");
    uart_puthex(fail);
    uart_puts(" failed\r\n");

    if (fail == 0)
        uart_puts("*** ALL PASS ***\r\n");
    else
        uart_puts("*** FAILURES DETECTED ***\r\n");

    return 0;
}
