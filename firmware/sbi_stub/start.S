/* start.S — entry point for sbi_stub at 0x8020_0000.
 *
 * OpenSBI fw_jump jumps here in S-mode with:
 *   a0 = hart ID
 *   a1 = DTB physical address
 *
 * Set up a small stack in SDRAM (just below our load address) and call kmain.
 */
    .section .text.start
    .global _start
_start:
    /* Stack: 4 KiB below load address (0x8020_0000 - 0x1000 = 0x801F_F000) */
    li   sp, 0x801FF000

    /* a0=hartid, a1=dtb_pa already set by OpenSBI — pass through to kmain */
    call kmain

    /* Should not return, but spin if it does */
1:  wfi
    j    1b
