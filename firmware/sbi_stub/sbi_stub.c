/* sbi_stub.c — Minimal S-mode stub "kernel" for OpenSBI testing.
 *
 * OpenSBI fw_jump jumps here (0x8020_0000) in S-mode with:
 *   a0 = hart ID (0)
 *   a1 = DTB physical address
 *
 * We use SBI ecalls to print via OpenSBI's console, then halt.
 * This proves OpenSBI booted, delegated to S-mode, and SBI calls work.
 */

/* SBI ecall: console putchar (legacy extension 0x01) */
static void sbi_putc(char c)
{
    register long a0 __asm__("a0") = (long)(unsigned char)c;
    register long a7 __asm__("a7") = 0x01;  /* SBI_EXT_0_1_CONSOLE_PUTCHAR */
    __asm__ volatile ("ecall" : "+r"(a0) : "r"(a7) : "memory");
}

static void sbi_puts(const char *s)
{
    while (*s) sbi_putc(*s++);
}

static void sbi_puthex(unsigned long v)
{
    const char *h = "0123456789abcdef";
    sbi_puts("0x");
    for (int i = 28; i >= 0; i -= 4)
        sbi_putc(h[(v >> i) & 0xF]);
}

/* SBI shutdown (SRST extension 0x53525354, type=0=shutdown) */
static void __attribute__((noreturn)) sbi_shutdown(void)
{
    register long a0 __asm__("a0") = 0;  /* reset_type = shutdown */
    register long a1 __asm__("a1") = 0;  /* reason = no reason */
    register long a6 __asm__("a6") = 0;  /* fid = 0 */
    register long a7 __asm__("a7") = 0x53525354;  /* SBI_EXT_SRST */
    __asm__ volatile ("ecall" : : "r"(a0), "r"(a1), "r"(a6), "r"(a7));
    /* If shutdown ecall fails (not implemented), spin */
    while (1) __asm__ volatile ("wfi");
    __builtin_unreachable();
}

void kmain(unsigned long hartid, unsigned long dtb_pa)
{
    sbi_puts("\r\n");
    sbi_puts("========================================\r\n");
    sbi_puts("  NyanSoC S-mode stub kernel\r\n");
    sbi_puts("========================================\r\n");
    sbi_puts("  OpenSBI booted successfully!\r\n");
    sbi_puts("  Now running in S-mode.\r\n");
    sbi_puts("\r\n");
    sbi_puts("  hart id : "); sbi_puthex(hartid); sbi_puts("\r\n");
    sbi_puts("  dtb pa  : "); sbi_puthex(dtb_pa); sbi_puts("\r\n");
    sbi_puts("\r\n");
    sbi_puts("  SBI console ecall works.\r\n");
    sbi_puts("  Halting.\r\n");
    sbi_puts("========================================\r\n");

    sbi_shutdown();
}
