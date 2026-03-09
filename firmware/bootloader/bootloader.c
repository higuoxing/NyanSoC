/* bootloader.c — NyanSoC SD card bootloader.
 *
 * Runs in M-mode from the 4 KiB IMEM LUT-ROM.
 * Loads OpenSBI + stub kernel + DTB from SD card into SDRAM, then jumps.
 *
 * SD card raw layout (512-byte sectors, no partition table):
 *   Sector     0        : reserved
 *   Sectors    1 –  516 : fw_jump.bin  (OpenSBI, 258 KB = 516 sectors)
 *   Sectors  517 –  524 : sbi_stub.bin (stub kernel, up to 4 KB = 8 sectors)
 *   Sectors  525 –  532 : nyansoc.dtb  (device tree, up to 4 KB = 8 sectors)
 *
 * Load addresses:
 *   OpenSBI   → 0x8000_0000  (fw_jump entry point)
 *   Stub      → 0x8020_0000  (fw_jump jumps here in S-mode)
 *   DTB       → 0x8100_0000  (passed in a1 to OpenSBI)
 *
 * SDRAM init is done by the hardware controller before reset is released,
 * but we poll the init_done bit to be safe.
 */

/* ── Memory-mapped peripherals ───────────────────────────────────────────── */
#define UART_TX     ((volatile unsigned int *)0x00030004)
#define SD_STATUS   ((volatile unsigned int *)0x00040000)
#define SD_CMD      ((volatile unsigned int *)0x00040004)
#define SD_ADDR     ((volatile unsigned int *)0x00040008)
#define SD_DATA     ((volatile unsigned int *)0x0004000C)
#define SDRAM_CTRL  ((volatile unsigned int *)0x00050000)

#define SD_INIT_DONE  (1u << 0)
#define SD_BUSY       (1u << 1)
#define SD_ERR        (1u << 2)
#define SD_WR_READY   (1u << 3)
#define SD_RD_VALID   (1u << 4)
#define SD_CMD_RD     (1u << 0)

#define SDRAM_INIT_DONE (1u << 1)  /* bit 1 of SDRAM ctrl/status */

/* ── SD card layout ──────────────────────────────────────────────────────── */
#define OPENSBI_SECTOR_START   1u
#define OPENSBI_SECTOR_COUNT   516u   /* 258 KB */
#define STUB_SECTOR_START      517u
#define STUB_SECTOR_COUNT      8u     /* 4 KB */
#define DTB_SECTOR_START       525u
#define DTB_SECTOR_COUNT       8u     /* 4 KB */

/* ── Load addresses ──────────────────────────────────────────────────────── */
#define OPENSBI_LOAD_ADDR  0x80000000u
#define STUB_LOAD_ADDR     0x80200000u
#define DTB_LOAD_ADDR      0x81000000u

/* ── UART ────────────────────────────────────────────────────────────────── */
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

/* ── SD helpers ──────────────────────────────────────────────────────────── */
static int sd_read_sectors(unsigned int start, unsigned int count,
                           unsigned char *dst)
{
    for (unsigned int s = 0; s < count; s++) {
        *SD_ADDR = start + s;
        *SD_CMD  = SD_CMD_RD;

        for (int i = 0; i < 512; i++) {
            unsigned int timeout = 0x800000u;
            while (!(*SD_STATUS & SD_RD_VALID) &&
                   !(*SD_STATUS & SD_ERR) && --timeout);
            if (*SD_STATUS & SD_ERR) return -1;
            if (!timeout)            return -2;
            *dst++ = (unsigned char)*SD_DATA;
        }
    }
    return 0;
}

/* ── Main ────────────────────────────────────────────────────────────────── */
int main(void)
{
    uart_puts("\r\n=== NyanSoC Bootloader ===\r\n");

    /* 1. Wait for SDRAM controller init */
    uart_puts("Waiting for SDRAM...\r\n");
    {
        unsigned int timeout = 0x4000000u;
        while (!(*SDRAM_CTRL & SDRAM_INIT_DONE) && --timeout);
        if (!(*SDRAM_CTRL & SDRAM_INIT_DONE)) {
            uart_puts("SDRAM init TIMEOUT\r\n");
            return -1;
        }
    }
    uart_puts("SDRAM ready.\r\n");

    /* 2. Wait for SD card init */
    uart_puts("Waiting for SD card...\r\n");
    {
        unsigned int timeout = 0x4000000u;
        while (!(*SD_STATUS & SD_INIT_DONE) &&
               !(*SD_STATUS & SD_ERR) && --timeout);
        if (*SD_STATUS & SD_ERR) {
            uart_puts("SD init ERROR\r\n");
            return -1;
        }
        if (!timeout) {
            uart_puts("SD init TIMEOUT\r\n");
            return -1;
        }
    }
    uart_puts("SD card ready.\r\n");

    /* 3. Load OpenSBI fw_jump.bin → 0x8000_0000 */
    uart_puts("Loading OpenSBI (");
    uart_puthex(OPENSBI_SECTOR_COUNT * 512);
    uart_puts(" bytes)...\r\n");
    if (sd_read_sectors(OPENSBI_SECTOR_START, OPENSBI_SECTOR_COUNT,
                        (unsigned char *)OPENSBI_LOAD_ADDR)) {
        uart_puts("OpenSBI load FAILED\r\n");
        return -1;
    }
    uart_puts("OpenSBI loaded at ");
    uart_puthex(OPENSBI_LOAD_ADDR);
    uart_puts("\r\n");

    /* 4. Load stub kernel → 0x8020_0000 */
    uart_puts("Loading stub kernel...\r\n");
    if (sd_read_sectors(STUB_SECTOR_START, STUB_SECTOR_COUNT,
                        (unsigned char *)STUB_LOAD_ADDR)) {
        uart_puts("Stub load FAILED\r\n");
        return -1;
    }
    uart_puts("Stub loaded at ");
    uart_puthex(STUB_LOAD_ADDR);
    uart_puts("\r\n");

    /* 5. Load DTB → 0x8100_0000 */
    uart_puts("Loading DTB...\r\n");
    if (sd_read_sectors(DTB_SECTOR_START, DTB_SECTOR_COUNT,
                        (unsigned char *)DTB_LOAD_ADDR)) {
        uart_puts("DTB load FAILED\r\n");
        return -1;
    }
    uart_puts("DTB loaded at ");
    uart_puthex(DTB_LOAD_ADDR);
    uart_puts("\r\n");

    /* 6. Jump to OpenSBI entry point in M-mode.
     *    OpenSBI expects: a0=hartid=0, a1=DTB address. */
    uart_puts("Jumping to OpenSBI at ");
    uart_puthex(OPENSBI_LOAD_ADDR);
    uart_puts("...\r\n");

    typedef void (*entry_t)(unsigned long hartid, unsigned long dtb_pa)
        __attribute__((noreturn));
    entry_t entry = (entry_t)OPENSBI_LOAD_ADDR;
    entry(0, DTB_LOAD_ADDR);
}
