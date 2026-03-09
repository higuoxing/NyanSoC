/* SPDX-License-Identifier: BSD-2-Clause
 *
 * NyanSoC custom UART driver for OpenSBI.
 *
 * Register map (base = 0x0003_0000):
 *   +0x0  RX  read:  {23'b0, valid, data[7:0]}  (reading clears valid)
 *   +0x4  TX  write: byte to send
 *         TX  read:  {31'b0, busy}
 */

#ifndef __UART_NYANSOC_H__
#define __UART_NYANSOC_H__

#include <sbi/sbi_types.h>

int uart_nyansoc_init(unsigned long base);

#endif
