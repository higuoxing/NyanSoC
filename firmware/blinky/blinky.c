/* blinky.c - Walking LED on Tang Nano 20K via NyanSoC GPIO.
 *
 * The Tang Nano 20K has 6 monochromatic LEDs wired to the SoC GPIO
 * register at 0x0002_0000, bits[5:0]. Writing 1 to a bit turns the
 * corresponding LED on (the hardware wrapper inverts for active-low).
 *
 * Pattern: one LED sweeps left (0→5) then right (4→1), repeating.
 *
 * Clock: 27 MHz. Inline-asm delay: addi+bne = 2 cycles/iter (register-only,
 * no DMEM round-trip). DELAY_ITERS = 27_000_000 / 2 / 4 = 3_375_000 → ~0.5s/step.
 * Tune DELAY_ITERS to adjust speed.
 */

#define GPIO_BASE   ((volatile unsigned int *)0x00020000)
#define NUM_LEDS    6
#define DELAY_ITERS 1375000

/* Bare-metal delay: the compiler is free to eliminate a pure C countdown
 * loop with no observable side effects. A two-instruction asm loop is the
 * standard idiom for a reliable, cycle-accurate busy-wait on RISC-V. */
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
    volatile unsigned int *gpio = GPIO_BASE;

    while (1) {
        /* Sweep left: LED0 → LED5 */
        for (int i = 0; i < NUM_LEDS; i++) {
            *gpio = 1u << i;
            delay();
        }

        /* Sweep right: LED4 → LED1 (ends already shown) */
        for (int i = NUM_LEDS - 2; i > 0; i--) {
            *gpio = 1u << i;
            delay();
        }
    }
}
