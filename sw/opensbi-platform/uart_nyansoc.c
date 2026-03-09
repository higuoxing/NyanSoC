/* SPDX-License-Identifier: BSD-2-Clause
 *
 * NyanSoC custom UART serial driver for OpenSBI.
 *
 * Register layout at base address (0x0003_0000):
 *   +0x0  RX  [R]  {23'b0, valid, data[7:0]}  — read clears valid
 *   +0x4  TX  [W]  byte to transmit
 *         TX  [R]  {31'b0, busy}
 */

#include <sbi/riscv_io.h>
#include <sbi/sbi_console.h>
#include "uart_nyansoc.h"

#define UART_RX_OFFSET  0x0
#define UART_TX_OFFSET  0x4

#define UART_RX_VALID   (1u << 8)
#define UART_TX_BUSY    (1u << 0)

static volatile char *uart_base;

static void nyansoc_uart_putc(char ch)
{
	volatile u32 *tx = (volatile u32 *)(uart_base + UART_TX_OFFSET);

	while (readl(tx) & UART_TX_BUSY)
		;
	writel((u32)(unsigned char)ch, tx);
}

static int nyansoc_uart_getc(void)
{
	volatile u32 *rx = (volatile u32 *)(uart_base + UART_RX_OFFSET);
	u32 val = readl(rx);

	if (val & UART_RX_VALID)
		return (int)(val & 0xFF);
	return -1;
}

static struct sbi_console_device nyansoc_console = {
	.name		= "nyansoc-uart",
	.console_putc	= nyansoc_uart_putc,
	.console_getc	= nyansoc_uart_getc,
};

int uart_nyansoc_init(unsigned long base)
{
	uart_base = (volatile char *)(uintptr_t)base;
	sbi_console_set_device(&nyansoc_console);
	return 0;
}
