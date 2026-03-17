/* hello_world.c - NyanSoC UART "Hello, world!" firmware.
 *
 * Repeatedly prints "Hello, world!\r\n" over UART TX.
 * A short busy-wait separates each line so the output is readable.
 *
 * Memory map (soc.v):
 *   0x0003_0004  UART TX  write: send byte; read: {31'b0, busy}
 */

#define UART_TX  ((volatile unsigned int *)0x00030004)

/* ~27 MHz / 2 instr per iter / 2 Hz ≈ 6 750 000 iters → ~0.5 s between lines */
#define DELAY_ITERS 675000

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

static void delay(void)
{
    int n = DELAY_ITERS;
    __asm__ volatile (
        "1: addi %0, %0, -1\n"
        "   bne  %0, zero, 1b\n"
        : "+r"(n)
    );
}

int main(void)
{
    while (1) {
        uart_puts("Hello, world!\r\n");
        delay();
    }
}
