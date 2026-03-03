/* echo.c - NyanSoC UART byte-echo firmware.
 *
 * Polls UART RX; every received byte is immediately echoed back via TX.
 *
 * Memory map (top.v):
 *   0x0003_0000  UART RX  read: {23'b0, valid, data[7:0]}  (clears valid flag)
 *   0x0003_0004  UART TX  write: send byte; read: {31'b0, busy}
 */

#define UART_RX  ((volatile unsigned int *)0x00030000)
#define UART_TX  ((volatile unsigned int *)0x00030004)

static unsigned char uart_getc(void)
{
    unsigned int v;
    do { v = *UART_RX; } while (!(v & 0x100));  /* bit 8 = valid */
    return (unsigned char)(v & 0xFF);
}

static void uart_putc(unsigned char c)
{
    while (*UART_TX & 1)  /* bit 0 = busy */
        ;
    *UART_TX = c;
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc((unsigned char)*s++);
}

/* Stack-allocated buffer — avoids any DMEM static variable issues. */
int main(void)
{
    char buffer[64];
    int  len = 0;

    while (1) {
        char c = uart_getc();
        if (c == '\r' || c == '\n') {
            buffer[len] = '\0';
            uart_puts("\r\nReceived: ");
            uart_puts(buffer);
            uart_puts("\r\n");
            len = 0;
        } else {
            uart_putc(c);
            if (len < 63)
                buffer[len++] = c;
        }
    }
}
