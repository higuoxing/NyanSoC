/* sdram_test.c - NyanSoC SDRAM controller test firmware.
 *
 * Memory map (top.v):
 *   0x0005_0000  SDRAM ctrl/status  read:  {30'b0, init_done, busy_n}
 *                                   write: bit0=wr_n, bit1=rd_n (active-low strobes)
 *   0x0005_0004  SDRAM word address (21-bit)
 *   0x0005_0008  SDRAM data         write=data to write, read=last read data
 *
 *   0x0003_0004  UART TX            write: send byte; read: {31'b0, busy}
 *
 * Test sequence:
 *   1. Wait for SDRAM init_done.
 *   2. Write a walking-ones pattern across N addresses.
 *   3. Read back and compare — print PASS or FAIL for each word.
 *   4. Report total pass/fail count.
 */

#define SDRAM_CTRL ((volatile unsigned int *)0x00050000)
#define SDRAM_ADDR ((volatile unsigned int *)0x00050004)
#define SDRAM_DATA ((volatile unsigned int *)0x00050008)

#define UART_TX    ((volatile unsigned int *)0x00030004)

#define SDRAM_BUSY_N    (1u << 0)
#define SDRAM_INIT_DONE (1u << 1)
#define SDRAM_RD_VALID  (1u << 2)

#define SDRAM_WR_CMD    (0u)  /* bit0=wr_n=0, bit1=rd_n=1 → write */
#define SDRAM_RD_CMD    (1u)  /* bit0=wr_n=1, bit1=rd_n=0 → read  */

#define TEST_WORDS 64

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

static void sdram_wait_ready(void)
{
    unsigned int t = 0;
    while (!(*SDRAM_CTRL & SDRAM_BUSY_N)) {
        if (++t == 0) {
            uart_puts("  [stuck busy] ctrl=");
            uart_puthex(*SDRAM_CTRL);
            uart_puts("\r\n");
        }
    }
}

static void sdram_write(unsigned int addr, unsigned int data)
{
    sdram_wait_ready();
    *SDRAM_ADDR = addr;
    *SDRAM_DATA = data;
    *SDRAM_CTRL = SDRAM_WR_CMD;  /* wr_n=0, rd_n=1 */
    sdram_wait_ready();          /* wait for write to complete */
}

static unsigned int sdram_read(unsigned int addr)
{
    sdram_wait_ready();
    *SDRAM_ADDR = addr;
    *SDRAM_CTRL = SDRAM_RD_CMD;  /* wr_n=1, rd_n=0 */
    /* Wait for rd_valid — data is live on the bus while rd_valid is asserted */
    unsigned int t = 0;
    while (!(*SDRAM_CTRL & SDRAM_RD_VALID)) {
        if (++t == 0) {
            uart_puts("  [stuck rd_valid] ctrl=");
            uart_puthex(*SDRAM_CTRL);
            uart_puts("\r\n");
        }
    }
    return *SDRAM_DATA;  /* read while rd_valid still high (combinatorial path) */
}

int main(void)
{
    uart_puts("\r\nSDRAM test starting...\r\n");

    /* Wait for SDRAM initialisation — print ctrl value every ~1M polls */
    uart_puts("Waiting for init...\r\n");
    while (!(*SDRAM_CTRL & SDRAM_INIT_DONE))
        ;
    uart_puts("init done, ctrl=");
    uart_puthex(*SDRAM_CTRL);
    uart_puts("\r\n");

    /* Write-then-read each address immediately (avoids sequential-read timing) */
    uart_puts("Write+verify ");
    uart_puthex(TEST_WORDS);
    uart_puts(" words...\r\n");

    unsigned int pass = 0, fail = 0;
    for (unsigned int i = 0; i < TEST_WORDS; i++) {
        unsigned int pattern = 0xA5000000u | (i << 8) | i;
        sdram_write(i, pattern);
        unsigned int got = sdram_read(i);
        if (got == pattern) {
            pass++;
        } else {
            uart_puts("  FAIL addr=");
            uart_puthex(i);
            uart_puts(" expected=");
            uart_puthex(pattern);
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
