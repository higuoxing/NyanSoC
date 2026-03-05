/* sdtest.c — NyanSoC SD card peripheral smoke test.
 *
 * Memory map (top.v):
 *   0x0003_0000  UART RX  read: {23'b0, valid, data[7:0]}  (clears valid)
 *   0x0003_0004  UART TX  write: send byte; read: {31'b0, busy}
 *   0x0004_0000  SD status  read: {18'b0, dbg_state[5:0], rd_valid, wr_ready, err, busy, init_done}
 *   0x0004_0004  SD command write: bit0=rd, bit1=wr  (single-cycle strobe)
 *   0x0004_0008  SD address read/write: 32-bit block address
 *   0x0004_000C  SD data FIFO: write=push byte, read=pop byte
 */

#define UART_RX   ((volatile unsigned int *)0x00030000)
#define UART_TX   ((volatile unsigned int *)0x00030004)
#define SD_STATUS ((volatile unsigned int *)0x00040000)
#define SD_CMD    ((volatile unsigned int *)0x00040004)
#define SD_ADDR   ((volatile unsigned int *)0x00040008)
#define SD_DATA   ((volatile unsigned int *)0x0004000C)

#define SD_INIT_DONE  (1u << 0)
#define SD_BUSY       (1u << 1)
#define SD_ERR        (1u << 2)
#define SD_WR_READY   (1u << 3)
#define SD_RD_VALID   (1u << 4)
/* bits [10: 5] = current FSM state
 * bits [18:11] = last SPI rx byte when error fired
 * bits [24:19] = FSM state before S_ERROR */
#define SD_DBG_STATE(st) (((st) >>  5) & 0x3Fu)
#define SD_DBG_RX(st)    (((st) >> 11) & 0xFFu)
#define SD_DBG_PREV(st)  (((st) >> 19) & 0x3Fu)

#define SD_CMD_RD     (1u << 0)
#define SD_CMD_WR     (1u << 1)

/* ── UART helpers ────────────────────────────────────────────────────────── */

static void uart_putc(unsigned char c)
{
    while (*UART_TX & 1)
        ;
    *UART_TX = c;
}

static void uart_puts(const char *s)
{
    while (*s) uart_putc((unsigned char)*s++);
}

static void uart_puthex8(unsigned char v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_putc(hex[v >> 4]);
    uart_putc(hex[v & 0xF]);
}

static void uart_puthex32(unsigned int v)
{
    uart_puthex8((unsigned char)(v >> 24));
    uart_puthex8((unsigned char)(v >> 16));
    uart_puthex8((unsigned char)(v >>  8));
    uart_puthex8((unsigned char)(v      ));
}

static unsigned char uart_getc(void)
{
    unsigned int v;
    do { v = *UART_RX; } while (!(v & 0x100));
    return (unsigned char)(v & 0xFF);
}

/* ── SD helpers ──────────────────────────────────────────────────────────── */

static int sd_wait_not_busy(void)
{
    unsigned int timeout = 0x1000000u;
    while ((*SD_STATUS & SD_BUSY) && !(*SD_STATUS & SD_ERR) && --timeout)
        ;
    if (*SD_STATUS & SD_ERR) return -1;
    if (!timeout)            return -2;
    return 0;
}

/* Read one 512-byte block into buf[512].
 * Returns 0 on success, -1 on SD error, -2 on timeout. */
static int sd_read_block(unsigned int blk_addr, unsigned char *buf)
{
    *SD_ADDR = blk_addr;
    *SD_CMD  = SD_CMD_RD;

    for (int i = 0; i < 512; i++) {
        unsigned int timeout = 0x1000000u;
        while (!(*SD_STATUS & SD_RD_VALID) && !(*SD_STATUS & SD_ERR) && --timeout)
            ;
        if (*SD_STATUS & SD_ERR) return -1;
        if (!timeout)            return -2;
        buf[i] = (unsigned char)*SD_DATA;
    }
    return 0;
}

/* Write one 512-byte block from buf[512].
 * Returns 0 on success, <0 on error. */
static int sd_write_block(unsigned int blk_addr, const unsigned char *buf)
{
    *SD_ADDR = blk_addr;
    *SD_CMD  = SD_CMD_WR;

    for (int i = 0; i < 512; i++) {
        unsigned int timeout = 0x1000000u;
        while (!(*SD_STATUS & SD_WR_READY) && !(*SD_STATUS & SD_ERR) && --timeout)
            ;
        if (*SD_STATUS & SD_ERR) return -1;
        if (!timeout)            return -2;
        *SD_DATA = buf[i];
    }

    return sd_wait_not_busy();
}

/* ── Test ────────────────────────────────────────────────────────────────── */

int main(void)
{
    /* Wait for keypress so picocom can connect before anything happens. */
    uart_puts("\r\n=== NyanSoC SD card test ===\r\n");
    uart_puts("Press any key to start...\r\n");
    uart_getc();

    /* 1. Poll SD status until init done or error, printing status each time it changes. */
    uart_puts("Waiting for SD init...\r\n");
    {
        unsigned int st;
        unsigned int last_st = 0xFFFFFFFFu;
        unsigned int timeout = 0x2000000u;
        do {
            st = *SD_STATUS;
            if (st != last_st) {
                uart_puts("  status=");
                uart_puthex32(st);
                uart_puts(" state=");
                uart_puthex8((unsigned char)SD_DBG_STATE(st));
                uart_puts(" prev=");
                uart_puthex8((unsigned char)SD_DBG_PREV(st));
                uart_puts(" rx=");
                uart_puthex8((unsigned char)SD_DBG_RX(st));
                uart_puts("\r\n");
                last_st = st;
            }
        } while (!(st & (SD_INIT_DONE | SD_ERR)) && --timeout);

        st = *SD_STATUS;
        if ((st & SD_ERR) || !timeout) {
            uart_puts("SD init FAILED: status=");
            uart_puthex32(st);
            uart_puts(" state=");
            uart_puthex8((unsigned char)SD_DBG_STATE(st));
            uart_puts(" prev=");
            uart_puthex8((unsigned char)SD_DBG_PREV(st));
            uart_puts(" rx=");
            uart_puthex8((unsigned char)SD_DBG_RX(st));
            uart_puts("\r\n");
            return 1;
        }
        uart_puts("SD init OK\r\n");
    }

    /* 2. Read block 0 (MBR). */
    uart_puts("Reading block 0...\r\n");
    {
        unsigned char buf[512];
        int rc = sd_read_block(0, buf);
        uart_puts("  rc=");
        uart_puthex8((unsigned char)(rc < 0 ? (unsigned char)(-rc) : 0));
        uart_puts("  status=");
        uart_puthex32(*SD_STATUS);
        uart_puts("\r\n");
        if (rc < 0) {
            uart_puts("Read block 0 FAILED\r\n");
            return 1;
        }
        uart_puts("  First 16 bytes: ");
        for (int i = 0; i < 16; i++) {
            uart_puthex8(buf[i]);
            uart_putc(' ');
        }
        uart_puts("\r\n");
        uart_puts(buf[510] == 0x55 && buf[511] == 0xAA
                  ? "  MBR signature OK (55 AA)\r\n"
                  : "  MBR signature missing\r\n");
    }

    /* 3. Write pattern to block 63. */
    uart_puts("Writing pattern to block 63...\r\n");
    {
        unsigned char wbuf[512];
        for (int i = 0; i < 512; i++)
            wbuf[i] = (unsigned char)((i ^ 0xA5) & 0xFF);
        int rc = sd_write_block(63, wbuf);
        uart_puts("  rc=");
        uart_puthex8((unsigned char)(rc < 0 ? (unsigned char)(-rc) : 0));
        uart_puts("  status=");
        uart_puthex32(*SD_STATUS);
        uart_puts("\r\n");
        if (rc < 0) {
            uart_puts("Write block 63 FAILED\r\n");
            return 1;
        }
        uart_puts("Write OK\r\n");
    }

    /* 4. Read back block 63 and verify. */
    uart_puts("Reading back block 63...\r\n");
    {
        unsigned char rbuf[512];
        int rc = sd_read_block(63, rbuf);
        uart_puts("  rc=");
        uart_puthex8((unsigned char)(rc < 0 ? (unsigned char)(-rc) : 0));
        uart_puts("  status=");
        uart_puthex32(*SD_STATUS);
        uart_puts("\r\n");
        if (rc < 0) {
            uart_puts("Read back FAILED\r\n");
            return 1;
        }
        uart_puts("Verifying...\r\n");
        for (int i = 0; i < 512; i++) {
            unsigned char expected = (unsigned char)((i ^ 0xA5) & 0xFF);
            if (rbuf[i] != expected) {
                uart_puts("  MISMATCH at byte 0x");
                uart_puthex32((unsigned int)i);
                uart_puts(": got 0x");
                uart_puthex8(rbuf[i]);
                uart_puts(" expected 0x");
                uart_puthex8(expected);
                uart_puts("\r\n");
                return 1;
            }
        }
        uart_puts("Verify OK\r\n");
    }

    uart_puts("=== PASS ===\r\n");
    return 0;
}
