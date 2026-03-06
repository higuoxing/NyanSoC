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
| S-mode CSRs | ❌ Not started |
| Sv32 MMU | ❌ Not started |
| SDRAM direct CPU address mapping | ❌ Not started |
| PLIC | ❌ Not started |
| OpenSBI port | ❌ Not started |
| Linux kernel build | ❌ Not started |
| SD card bootloader | ❌ Not started |

---

## Phase 1 — CPU: Supervisor mode CSRs

Add S-mode privilege level to `rtl/nyanrv.v`.

- [ ] Add `sstatus`, `stvec`, `sip`, `sie`, `sscratch`, `sepc`, `scause`, `stval` CSRs
- [ ] Add `medeleg` / `mideleg` registers (M-mode delegates traps/interrupts to S-mode)
- [ ] Add `satp` CSR (Sv32 page-table base + MODE field; reads as 0 until MMU is added)
- [ ] Implement `sret` instruction (return from S-mode trap)
- [ ] Implement privilege-level tracking (`prv` register: 2'b11=M, 2'b01=S, 2'b00=U)
- [ ] Route traps through delegation logic:
  - If `medeleg[cause]` is set and current prv < M → take trap in S-mode
  - Otherwise → take trap in M-mode (existing behaviour)
- [ ] Update `mstatus` fields: `SPP`, `SPIE`, `SIE` (S-mode equivalents of MPP/MPIE/MIE)
- [ ] Update `mip` / `mie` to include supervisor timer (STIP/STIE) and external (SEIP/SEIE)
- [ ] Write `smode_test` firmware to verify S-mode trap entry/exit and CSR access

## Phase 2 — CPU: Sv32 MMU

Add a hardware page-table walker and TLB to `rtl/nyanrv.v`.

- [ ] Add `satp` MODE decode: `0` = bare (no translation), `1` = Sv32
- [ ] Implement Sv32 two-level page-table walk:
  - Level 1: PA = `satp.PPN << 12`, index = `VA[31:22]`
  - Level 0: PA = `PTE.PPN << 12`, index = `VA[21:12]`
  - Leaf PTE: PA = `PTE.PPN << 12 | VA[11:0]`
- [ ] Add a small direct-mapped TLB (e.g. 16 entries, ASID-tagged)
- [ ] Implement `SFENCE.VMA` instruction (flush TLB, optionally by ASID/VA)
- [ ] Raise page-fault exceptions:
  - Instruction page fault (cause 12)
  - Load page fault (cause 13)
  - Store/AMO page fault (cause 15)
- [ ] Handle PTE A/D (accessed/dirty) bits
- [ ] Write `mmu_test` firmware: map a page, access it, verify translation, test page fault

## Phase 3 — SoC: SDRAM direct mapping + PLIC

Changes to `boards/tangnano20k/top.v`.

- [ ] Map SDRAM directly into CPU address space (e.g. `0x8000_0000–0x81FF_FFFF`, 32 MB)
  - Replace register-mapped interface with a stall-based arbiter (hold `dmem_rready`
    low until `sdram_rd_valid` fires, same for writes)
  - This is where Linux will live (kernel + heap + stack)
- [ ] Add PLIC (Platform-Level Interrupt Controller) at `0x0C00_0000` (standard address)
  - At minimum: 1 source (UART RX), 1 context (S-mode)
  - Registers: priority, pending, enable, threshold, claim/complete
  - Wire PLIC interrupt output to `i_irq_external` on the CPU
- [ ] Update memory map comment and README

## Phase 4 — Software: OpenSBI + Linux + rootfs

- [ ] Port OpenSBI to NyanSoC:
  - Platform config: `CLK_FREQ=27000000`, UART at `0x0003_0000`, CLINT at `0x0200_0000`
  - Set `PLATFORM_RISCV_ISA = rv32ima`
  - Load address: `0x8000_0000` (start of SDRAM)
- [ ] Write Device Tree Source (`.dts`) for NyanSoC:
  - CPU: RV32IMA, 1 hart
  - Memory: `0x8000_0000`, size `0x2000000` (32 MB)
  - UART: `0x0003_0000`, compatible `ns16550a` or simple-bus
  - CLINT: `0x0200_0000`
  - PLIC: `0x0C00_0000`
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
