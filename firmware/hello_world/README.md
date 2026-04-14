# hello_world

Repeatedly prints `Hello, world!` over UART TX every ~0.5 s.

## Bring-up summary (what landed in-tree)

This firmware is the **smallest SDRAM sanity check** on NyanSoC. Related work that made it and the larger boot path usable:

- **Host UART on Linux**: `scripts/uart_load.py` was hardened (raw `termios`, flow control, timing) for `/dev/ttyUSB*`; docs cover `picocom --noreset`, echo/loopback pitfalls, and `dialout`.
- **UART loader** (`firmware/uart_loader/`): short delay at reset so the host port is ready before the loader speaks; IMEM ROM path unchanged in spirit.
- **SD card bootloader** (`firmware/bootloader/`): loads OpenSBI, a stub “kernel”, and DTB from **raw sectors** into SDRAM, then jumps to OpenSBI at `0x80000000` with `a0=0`, `a1=0x80100000`. Uses a **DMEM sector buffer** then bulk copy to SDRAM to avoid SD/SDRAM bus contention; `boards/tangnano20k/top.v` decodes peripheral writes only when `!addr[31]` so SDRAM writes do not alias DMEM/MMIO.
- **SDSPI RTL**: SDHC vs SDSC addressing for CMD17/CMD24 from OCR CCS; status decode aligned with `top.v`.
- **CPU (`rtl/nyanrv.v`) for OpenSBI**: `mstatush`, `mcounteren`/`scounteren`, read-only ID CSRs, corrected `misa` (A/U); **AMO** (`amoswap`, `amoadd`, `lr`/`sc`, etc.) for the `A` extension; **`wfi`** as NOP on this single-hart core; **PMP** CSRs (`0x3a0`–`0x3bf`) and **counter stubs** (`mcycle`/`minstret`/`…h`) so OpenSBI’s `sbi_hart_init` does not spin on illegal CSR traps.
- **Stub kernel** (`firmware/sbi_stub/`): minimal S-mode image at `0x80200000`; can include a **direct UART** line for diagnostics (independent of SBI console ecalls).
- **SD image**: `scripts/make_sd_image.sh` builds `nyansoc_sd.img` (or write straight to a block device). Typical **contents written to the SD card** (first 533 × 512-byte sectors):

  | Sectors   | File / role |
  |-----------|----------------|
  | 1–516     | OpenSBI `fw_jump.bin` → SDRAM `0x80000000` |
  | 517–524   | `sbi_stub.bin` (stub kernel) → `0x80200000` |
  | 525–532   | `nyansoc.dtb` → `0x80100000` |

  The FPGA bitstream usually has **`FW=bootloader`** so the SoC runs that loader from IMEM LUT-ROM; the SD card supplies OpenSBI + stub + DTB (not `hello_world` unless you load it another way).

**Next milestones** (see repo `TODO.md`): build a real RV32 Linux `Image`, swap it into the SD layout for sector 517+, then rootfs / initramfs as planned.

## Prerequisites

- `riscv64-elf-gcc` toolchain
- OSS CAD Suite (`yosys`, `nextpnr-himbaechel`, `gowin_pack`, `openFPGALoader`)
- `pyserial` (`pip3 install pyserial`)
- Tang Nano 20K connected over USB

## Method 1 — Bake into FPGA bitstream (IMEM LUT-ROM)

This is the traditional path. The firmware is compiled into the FPGA bitstream
itself and runs immediately on power-up.

```bash
# Build and flash (synthesises the full SoC with hello_world in the ROM)
make -C boards/tangnano20k FW=hello_world flash-sram

# Connect to see output
picocom -b 115200 /dev/tty.usbserial-XXXXXXXX
```

## Method 2 — Upload via UART loader (no reflash needed)

The UART loader firmware sits in the IMEM LUT-ROM and accepts programs over
UART. Programs are linked to run from SDRAM (`0x8000_0000`) where the CPU can
both write and fetch instructions.

### Step 1 — Flash the UART loader (one time only)

```bash
make -C boards/tangnano20k FW=uart_loader flash-sram
```

### Step 2 — Build the SDRAM binary

```bash
make -C firmware/hello_world bin BIN_ADDR=0x80000000
# produces firmware/hello_world/hello_world.bin (140 bytes)
```

### Step 3 — Upload and run

```bash
python3 scripts/uart_load.py -p /dev/tty.usbserial-XXXXXXXX run \
    firmware/hello_world/hello_world.bin 0x80000000
```

The script uploads the binary, jumps to it, and streams the program's output
directly to your terminal. Press `Ctrl+C` to disconnect.

Expected output:

```
Connected to /dev/tty.usbserial-XXXXXXXX at 115200 baud
Loading 140 bytes to 0x80000000 (csum=0x9A)...
  OK
Jumping to 0x80000000...
--- program output (Ctrl+C to exit) ---
Hello, world!
Hello, world!
Hello, world!
...
```

## Notes

- The `BIN_ADDR` default is `0x00010000` (DMEM), but DMEM cannot be used for
  instruction fetch — always use `BIN_ADDR=0x80000000` (SDRAM) with the UART
  loader.
- The stack is placed at `0x801F_FFFC` (top of the first 2 MiB of SDRAM) by
  `firmware/start_ram.S`, safely above the 140-byte program image.
- To disassemble: `make -C firmware/hello_world dis`
