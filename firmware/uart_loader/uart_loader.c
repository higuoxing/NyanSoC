/* uart_loader.c — NyanSoC UART program loader.
 *
 * Sits in the 4 KiB IMEM LUT-ROM.  Lets you upload and run programs over
 * UART without reflashing the FPGA.
 *
 * Protocol (all multi-byte values big-endian):
 *
 *   Load:
 *     Host sends:  'L' <addr:4> <len:4> <data:len> <csum:1>
 *     csum = XOR of all <data> bytes.
 *     Board replies: 'K' on success, 'E' on checksum mismatch.
 *
 *   Go (jump):
 *     Host sends:  'G' <addr:4>
 *     Board jumps to addr immediately (no reply).
 *
 *   Dump (read back memory):
 *     Host sends:  'D' <addr:4> <len:4>
 *     Board replies: <data:len> (raw bytes, no framing).
 *
 *   Ping:
 *     Host sends:  'P'
 *     Board replies: 'O' (for "OK").
 *
 * The host-side script is in scripts/uart_load.py.
 */

#define UART_RX  ((volatile unsigned int *)0x00030000)
#define UART_TX  ((volatile unsigned int *)0x00030004)

/* ── UART primitives ─────────────────────────────────────────────────────── */

static void uart_putc(unsigned char c)
{
    while (*UART_TX & 1);
    *UART_TX = c;
}

static unsigned char uart_getc(void)
{
    unsigned int v;
    do { v = *UART_RX; } while (!(v & 0x100));
    return (unsigned char)(v & 0xFF);
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

/* ── Protocol helpers ────────────────────────────────────────────────────── */

static unsigned int recv_u32(void)
{
    unsigned int v = 0;
    v |= (unsigned int)uart_getc() << 24;
    v |= (unsigned int)uart_getc() << 16;
    v |= (unsigned int)uart_getc() <<  8;
    v |= (unsigned int)uart_getc();
    return v;
}

/* ── Commands ────────────────────────────────────────────────────────────── */

static void cmd_load(void)
{
    unsigned int addr = recv_u32();
    unsigned int len  = recv_u32();

    uart_puts("\r\nLoad ");
    uart_puthex(len);
    uart_puts(" bytes -> ");
    uart_puthex(addr);
    uart_puts("\r\n");

    unsigned char *dst  = (unsigned char *)addr;
    unsigned char  csum = 0;

    for (unsigned int i = 0; i < len; i++) {
        unsigned char b = uart_getc();
        dst[i] = b;
        csum ^= b;
    }

    unsigned char expected = uart_getc();
    if (csum == expected) {
        uart_putc('K');
        uart_puts(" OK\r\n");
    } else {
        uart_putc('E');
        uart_puts(" checksum error (got ");
        uart_puthex(expected);
        uart_puts(" want ");
        uart_puthex(csum);
        uart_puts(")\r\n");
    }
}

static void cmd_dump(void)
{
    unsigned int addr = recv_u32();
    unsigned int len  = recv_u32();
    const unsigned char *src = (const unsigned char *)addr;
    for (unsigned int i = 0; i < len; i++)
        uart_putc(src[i]);
}

static void __attribute__((noreturn)) cmd_go(void)
{
    unsigned int addr = recv_u32();
    uart_puts("\r\nJumping to ");
    uart_puthex(addr);
    uart_puts("...\r\n");
    typedef void (*entry_t)(void) __attribute__((noreturn));
    ((entry_t)addr)();
}

/* ── Main loop ───────────────────────────────────────────────────────────── */

int main(void)
{
    uart_puts("\r\n=== NyanSoC UART Loader ===\r\n");
    uart_puts("Commands: L(oad) G(o) D(ump) P(ing)\r\n");
    uart_puts("Ready.\r\n");

    while (1) {
        unsigned char cmd = uart_getc();
        switch (cmd) {
        case 'L': cmd_load(); break;
        case 'G': cmd_go();   break;  /* noreturn */
        case 'D': cmd_dump(); break;
        case 'P': uart_putc('O'); break;
        default:
            uart_puts("\r\n? unknown command '");
            uart_putc(cmd);
            uart_puts("'\r\n");
            break;
        }
    }
}
