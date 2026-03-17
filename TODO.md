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
| OpenSBI port | ✅ Done, hardware verified |
| UART loader + SDRAM instruction fetch | ✅ Done, hardware verified |
| Linux kernel build | 🔄 WIP — configs ready, needs Linux build host |
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
  - `platform/nyansoc/` in `sw/opensbi-platform/` (synced into `sw/opensbi` at build time)
  - Custom UART driver (`uart_nyansoc.c`) — not 8250-compatible
  - ACLINT MTIMER at `0x0200_0000`, `has_64bit_mmio=false` (32-bit MMIO)
  - PLIC at `0x0C00_0000`, 1 source, S-mode context 0, no M-mode context
  - `fw_jump` firmware: loads at `0x8000_0000`, jumps to `0x8020_0000` (kernel), DTB at `0x8100_0000`
  - Build: `make -C sw opensbi` (applies no-PIE patch, syncs platform files, builds)
  - Output: `sw/opensbi/build/platform/nyansoc/firmware/fw_jump.bin` (258 KB) — builds cleanly
- [x] Write Device Tree Source (`.dts`) for NyanSoC:
  - `boards/tangnano20k/nyansoc.dts`
  - CPU: RV32IMA, 1 hart, Sv32 MMU, 27 MHz timebase
  - Memory: `0x8000_0000`, size `0x2000000` (32 MB)
  - UART: `0x0003_0000`, compatible `nyansoc,uart`
  - CLINT: `0x0200_0000`
  - PLIC: `0x0C00_0000`, 1 interrupt (UART RX)
  - Compiled to `boards/tangnano20k/nyansoc.dtb` with `dtc`
- [x] Add UART loader firmware + SDRAM instruction fetch:
  - `firmware/uart_loader/` — bare-metal firmware in IMEM LUT-ROM
  - Protocol: `L`(oad) / `G`(o) / `D`(ump) / `P`(ing) over UART at 115200 baud
  - `scripts/uart_load.py` — host-side Python script (load, go, run, dump, ping)
  - `firmware/start_ram.S` + `firmware/link_ram.ld` — shared CRT0/linker for RAM-loaded programs
    - Sets `mtvec`, disables interrupts, pushes `mtimecmp` to `0xFFFFFFFF_FFFFFFFF` before `main`
  - RTL change (`boards/tangnano20k/top.v`): when `imem_addr[31]=1`, instruction fetch is routed
    through the SDRAM arbiter instead of the LUT-ROM, enabling execution from SDRAM
  - SDRAM FSM extended with `SDRDM_DONE_HOLD` state to prevent re-triggering on the same
    fetch beat (CPU holds `imem_valid` high for one extra cycle after `imem_ready` fires)
  - Hardware verified: `hello_world` runs stably from SDRAM over UART loader
- [ ] Build Linux kernel (Sv32, RV32): **WIP — configs ready, needs Linux build host**
  - Config: `sw/linux-nyansoc.config` (RV32IMA, Sv32, SBI console `hvc0`, initramfs, no 8250)
  - Load address: `0x8020_0000` (after OpenSBI); kernel cmdline: `console=hvc0 earlycon=sbi`
  - Blocked on macOS: Linux kernel build requires `elf.h` and other Linux-only host headers
  - **To build on a Linux machine:**
    ```bash
    make -C linux ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- \
        KCONFIG_CONFIG=/path/to/NyanSoC/sw/linux-nyansoc.config \
        -j$(nproc) Image
    ```
- [ ] Build minimal rootfs with BusyBox using Buildroot: **WIP — config ready**
  - Config: `sw/buildroot-nyansoc.config` (RV32IMA, musl toolchain, BusyBox, Linux 6.6, initramfs)
  - **To build on a Linux machine:**
    ```bash
    make -C buildroot BR2_DEFCONFIG=/path/to/NyanSoC/sw/buildroot-nyansoc.config defconfig
    make -C buildroot -j$(nproc)
    ```
- [ ] Load Linux over UART (once kernel is built):
  - Transfer times at 115200 baud: OpenSBI ~23s, kernel ~3–8 min, DTB ~0s
  - Load sequence:
    ```bash
    python3 scripts/uart_load.py -p /dev/ttyUSB0 load sw/opensbi/.../fw_jump.bin 0x80000000
    python3 scripts/uart_load.py -p /dev/ttyUSB0 load linux/arch/riscv/boot/Image  0x80200000
    python3 scripts/uart_load.py -p /dev/ttyUSB0 load boards/tangnano20k/nyansoc.dtb 0x81000000
    python3 scripts/uart_load.py -p /dev/ttyUSB0 go 0x80000000 --stay
    ```

## Phase 5 — Boot: SD card bootloader

- [x] Write bare-metal SD card bootloader (`firmware/bootloader/`):
  - Fits in 4 KiB IMEM LUT-ROM; default firmware when `FW=bootloader`
  - Waits for SDRAM and SD card init, then loads from raw sectors:
    - Sectors 1–516: `fw_jump.bin` (OpenSBI, 258 KB) → `0x8000_0000`
    - Sectors 517–524: stub kernel (8 sectors) → `0x8020_0000`
    - Sectors 525–532: `nyansoc.dtb` (8 sectors) → `0x8100_0000`
  - Jumps to OpenSBI entry with `a0=0` (hartid), `a1=0x8100_0000` (DTB PA)
- [x] Define SD card image layout (`scripts/make_sd_image.sh`):
  - Raw sector layout, no partition table
  - Script assembles `nyansoc_sd.img` from `fw_jump.bin`, kernel, and DTB
- [ ] Replace stub kernel with real Linux `Image` in SD card layout once kernel is built
- [ ] Update `make_sd_image.sh` sector counts for actual kernel size

---

## Nice-to-haves (post-Linux)

- [ ] Update README with full memory map and Linux boot instructions
- [ ] Add `riscv-formal` coverage for S-mode CSRs and MMU
- [ ] PLL to run CPU faster than 27 MHz (currently limited by SDRAM timing)
- [ ] Second UART or SPI for debugging during boot
