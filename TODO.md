# NyanSoC TODO

Goal: run full MMU Linux (Sv32) on the Tang Nano 20K.

## Status snapshot

| Component | Status |
|-----------|--------|
| nyanrv CPU (RV32IM + Zicsr, M-mode) | ✅ Done, formally verified |
| UART TX/RX | ✅ Done, formally verified |
| SPI SD card controller | ✅ Done, tested |
| SDRAM controller (register-mapped) | ✅ Done, tested |
| CLINT (mtime / mtimecmp) | ✅ Done, tested |
| S-mode CSRs + privilege tracking | ✅ Done, sim-tested |
| Sv32 MMU | ✅ Done, sim-tested |
| SDRAM direct CPU address mapping | ✅ Done, hardware verified |
| PLIC | ✅ Done, hardware verified |
| OpenSBI port | 🔄 In progress |
| Linux kernel build | ❌ Not started |
| SD card bootloader | ❌ Not started |

---

## Phase 1 — CPU: Supervisor mode CSRs

Add S-mode privilege level to `rtl/nyanrv.v`.

- [x] Add `sstatus`, `stvec`, `sip`, `sie`, `sscratch`, `sepc`, `scause`, `stval` CSRs
- [x] Add `medeleg` / `mideleg` registers (M-mode delegates traps/interrupts to S-mode)
- [x] Add `satp` CSR (Sv32 page-table base + MODE field; reads as 0 until MMU is added)
- [x] Implement `sret` instruction (return from S-mode trap)
- [x] Implement privilege-level tracking (`prv` register: 2'b11=M, 2'b01=S, 2'b00=U)
- [x] Route traps through delegation logic:
  - If `medeleg[cause]` is set and current prv < M → take trap in S-mode
  - Otherwise → take trap in M-mode (existing behaviour)
- [x] Update `mstatus` fields: `SPP`, `SPIE`, `SIE` (S-mode equivalents of MPP/MPIE/MIE)
- [x] Update `mip` / `mie` to include supervisor timer (STIP/STIE) and external (SEIP/SEIE)
- [x] Write `smode_test` firmware to verify S-mode trap entry/exit and CSR access

## Phase 2 — CPU: Sv32 MMU

Add a hardware page-table walker and TLB to `rtl/nyanrv.v`.

- [x] Add `satp` MODE decode: `0` = bare (no translation), `1` = Sv32
- [x] Implement Sv32 two-level page-table walk:
  - Level 1: PA = `satp.PPN << 12`, index = `VA[31:22]`
  - Level 0: PA = `PTE.PPN << 12`, index = `VA[21:12]`
  - Leaf PTE: PA = `PTE.PPN << 12 | VA[11:0]`
- [x] Add a small direct-mapped TLB (16 entries, ASID-tagged, indexed by VA[19:16])
- [x] Implement `SFENCE.VMA` instruction (flush TLB, optionally by ASID/VA)
- [x] Raise page-fault exceptions:
  - Instruction page fault (cause 12)
  - Load page fault (cause 13)
  - Store/AMO page fault (cause 15)
- [x] Handle PTE A/D (accessed/dirty) bits (fault if A=0 or D=0 on store; SW handles update)
- [x] Write `mmu_test` firmware + simulation test:
  - `rtl/sim/sw/asm/test_mmu.S` + `rtl/sim/rtl/nyanrv_mmu_tb.v` (full Sv32 sim test — PASS)
  - `firmware/mmu_test/` (on-hardware: satp R/W; full MMU exercise needs SDRAM PTW support)

## Phase 3 — SoC: SDRAM direct mapping + PLIC

Changes to `boards/tangnano20k/top.v`.

- [x] Map SDRAM directly into CPU address space (`0x8000_0000–0x81FF_FFFF`, 32 MB)
  - Stall-based FSM arbiter: `dmem_rready`=0 until `sdram_rd_valid`, `dmem_wready`=0 until write recovery
  - Uses `wrd_ack` (controller's internal ack shift register) to detect actual command acceptance,
    correctly handling auto-refresh preemption in `STATE_IDLE`
  - PTW reads to SDRAM also stall transparently (PTEs can live in SDRAM)
  - Legacy register-mapped interface at `0x0005_xxxx` retained for diagnostics
  - Hardware verified: 64×32-bit W+R, 4×byte-enable (SB), 2×halfword (SH), second 4KB page — all pass
  - This is where Linux will live (kernel + heap + stack)
- [x] Add PLIC (Platform-Level Interrupt Controller) at `0x0C00_0000` (standard address)
  - 1 source (UART RX, source ID=1), 1 context (S-mode hart 0)
  - Registers: priority (0x4), pending (0x1000), enable (0x2000), threshold (0x200000), claim/complete (0x200004)
  - Edge-triggered pending on `rx_valid_raw` rising edge; claim clears pending
  - `irq_external` wired to `i_irq_external` on the CPU (was hard-wired to 0)
  - RTL unit test: `rtl/sim/rtl/plic_tb.v` — 15/15 checks pass in simulation
  - Hardware firmware: `firmware/plic_test/` — bitstream built and flashed
- [x] Update memory map comment and README

## Phase 4 — Software: OpenSBI + Linux + rootfs

- [x] Port OpenSBI to NyanSoC:
  - `platform/nyansoc/` in `/Users/v/workspace/opensbi`
  - Custom UART driver (`uart_nyansoc.c`) — not 8250-compatible
  - ACLINT MTIMER at `0x0200_0000`, `has_64bit_mmio=false` (32-bit MMIO)
  - PLIC at `0x0C00_0000`, 1 source, S-mode context 0, no M-mode context
  - `fw_jump` firmware: loads at `0x8000_0000`, jumps to `0x8020_0000` (kernel), DTB at `0x8100_0000`
  - Build: `make PLATFORM=nyansoc CROSS_COMPILE=riscv64-elf- FW_TEXT_START=0x80000000`
  - Output: `build/platform/nyansoc/firmware/fw_jump.bin` (258 KB) — builds cleanly
- [x] Write Device Tree Source (`.dts`) for NyanSoC:
  - `boards/tangnano20k/nyansoc.dts`
  - CPU: RV32IMA, 1 hart, Sv32 MMU, 27 MHz timebase
  - Memory: `0x8000_0000`, size `0x2000000` (32 MB)
  - UART: `0x0003_0000`, compatible `nyansoc,uart`
  - CLINT: `0x0200_0000`
  - PLIC: `0x0C00_0000`, 1 interrupt (UART RX)
- [ ] Build Linux kernel (Sv32, RV32):
  - `CONFIG_ARCH_RV32I=y`, `CONFIG_SMP=n`, `CONFIG_MMU=y`
  - `CONFIG_SERIAL_EARLYCON=y`, `CONFIG_HVC_RISCV_SBI=y`
  - Load address: `0x8020_0000` (after OpenSBI)
- [ ] Build minimal rootfs with BusyBox using Buildroot
- [ ] Pack initramfs into kernel image

## Phase 5 — Boot: SD card bootloader

- [ ] Write a bare-metal bootloader firmware (fits in 4 KiB IMEM LUT-ROM):
  - Waits for SDRAM init
  - Reads OpenSBI binary from SD card into `0x8000_0000`
  - Reads DTB from SD card into `0x8100_0000` (or appended to OpenSBI)
  - Reads kernel image from SD card into `0x8020_0000`
  - Jumps to OpenSBI entry point
- [ ] Define SD card image layout (partition or raw sector offsets)

---

## Nice-to-haves (post-Linux)

- [ ] Update README with full memory map and Linux boot instructions
- [ ] Add `riscv-formal` coverage for S-mode CSRs and MMU
- [ ] PLL to run CPU faster than 27 MHz (currently limited by SDRAM timing)
- [ ] Second UART or SPI for debugging during boot
