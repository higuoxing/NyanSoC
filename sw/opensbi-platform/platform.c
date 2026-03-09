/* SPDX-License-Identifier: BSD-2-Clause
 *
 * OpenSBI platform port for NyanSoC (Tang Nano 20K)
 *
 * Hardware summary:
 *   CPU:    NyanRV  RV32IMA_Zicsr, 1 hart, Sv32 MMU
 *   Clock:  27 MHz
 *   UART:   custom, base 0x0003_0000 (TX +4, RX +0)
 *   CLINT:  standard layout, base 0x0200_0000, 32-bit MMIO
 *   PLIC:   1 source (UART RX = ID 1), 1 S-mode context (ctx 0)
 *           base 0x0C00_0000
 *   SDRAM:  32 MB at 0x8000_0000 (OpenSBI loads here)
 *
 * Boot flow:
 *   Bootloader → OpenSBI (fw_jump) at 0x8000_0000  (M-mode)
 *              → Linux kernel               at 0x8020_0000  (S-mode)
 *              → DTB                        at 0x8100_0000
 */

#include <sbi/riscv_asm.h>
#include <sbi/riscv_encoding.h>
#include <sbi/sbi_const.h>
#include <sbi/sbi_platform.h>
#include <sbi_utils/irqchip/plic.h>
#include <sbi_utils/timer/aclint_mtimer.h>
#include "uart_nyansoc.h"

/* ── Address map ─────────────────────────────────────────────────────────── */
#define NYANSOC_UART_ADDR       0x00030000UL
#define NYANSOC_CLINT_ADDR      0x02000000UL
#define NYANSOC_PLIC_ADDR       0x0C000000UL
#define NYANSOC_PLIC_SIZE       0x00210000UL  /* up to claim/complete at 0x200004 */
#define NYANSOC_PLIC_NUM_SRC    1

/* ── Clock / UART ────────────────────────────────────────────────────────── */
#define NYANSOC_CLK_FREQ        27000000UL

/* ── CLINT (ACLINT MTIMER) ───────────────────────────────────────────────── */
/*
 * Our CLINT register layout at 0x0200_0000:
 *   +0x0  mtime    lo   [R/W]
 *   +0x4  mtime    hi   [R/W]
 *   +0x8  mtimecmp lo   [R/W]
 *   +0xC  mtimecmp hi   [R/W]
 *
 * ACLINT MTIMER driver with has_64bit_mmio=false does two 32-bit
 * accesses, which matches our 32-bit MMIO perfectly.
 *
 * We set mtime_addr = base+0 and mtimecmp_addr = base+8 directly.
 * Sizes are set to 8 bytes each (one 64-bit register).
 */
#define NYANSOC_MTIME_ADDR      (NYANSOC_CLINT_ADDR + 0x0)
#define NYANSOC_MTIMECMP_ADDR   (NYANSOC_CLINT_ADDR + 0x8)

static struct aclint_mtimer_data mtimer = {
	.mtime_freq     = NYANSOC_CLK_FREQ,
	.mtime_addr     = NYANSOC_MTIME_ADDR,
	.mtime_size     = 0x8,
	.mtimecmp_addr  = NYANSOC_MTIMECMP_ADDR,
	.mtimecmp_size  = 0x8,
	.first_hartid   = 0,
	.hart_count     = 1,
	.has_64bit_mmio = false,
};

/* ── PLIC ────────────────────────────────────────────────────────────────── */
/*
 * 1 source, 1 S-mode context (context 0).
 * No M-mode context → set PLIC_M_CONTEXT slot to -1.
 * context_map[hart][PLIC_M_CONTEXT] = -1  (no M-mode context)
 * context_map[hart][PLIC_S_CONTEXT] = 0   (S-mode = context 0)
 *
 * plic_data has a flexible array member context_map[][2] at the end.
 * We allocate it as a byte array of the correct size using PLIC_DATA_SIZE.
 */
static u8 plic_buf[PLIC_DATA_SIZE(1)];  /* 1 hart */
#define plic_inst ((struct plic_data *)plic_buf)

/* ── Platform callbacks ──────────────────────────────────────────────────── */

static int nyansoc_early_init(bool cold_boot)
{
	if (!cold_boot)
		return 0;
	return uart_nyansoc_init(NYANSOC_UART_ADDR);
}

static int nyansoc_final_init(bool cold_boot)
{
	(void)cold_boot;
	return 0;
}

static int nyansoc_irqchip_init(void)
{
	plic_inst->addr    = NYANSOC_PLIC_ADDR;
	plic_inst->size    = NYANSOC_PLIC_SIZE;
	plic_inst->num_src = NYANSOC_PLIC_NUM_SRC;
	plic_inst->context_map[0][PLIC_M_CONTEXT] = -1;  /* no M-mode context */
	plic_inst->context_map[0][PLIC_S_CONTEXT] =  0;  /* S-mode = context 0 */
	return plic_cold_irqchip_init(plic_inst);
}

static int nyansoc_timer_init(void)
{
	return aclint_mtimer_cold_init(&mtimer, NULL);
}

/* ── Platform descriptor ─────────────────────────────────────────────────── */

const struct sbi_platform_operations platform_ops = {
	.early_init   = nyansoc_early_init,
	.final_init   = nyansoc_final_init,
	.irqchip_init = nyansoc_irqchip_init,
	.timer_init   = nyansoc_timer_init,
};

const struct sbi_platform platform = {
	.opensbi_version  = OPENSBI_VERSION,
	.platform_version = SBI_PLATFORM_VERSION(0x0, 0x01),
	.name             = "NyanSoC (Tang Nano 20K)",
	.features         = SBI_PLATFORM_DEFAULT_FEATURES,
	.hart_count       = 1,
	.hart_stack_size  = SBI_PLATFORM_DEFAULT_HART_STACK_SIZE,
	.heap_size        = SBI_PLATFORM_DEFAULT_HEAP_SIZE(1),
	.platform_ops_addr = (unsigned long)&platform_ops,
};
