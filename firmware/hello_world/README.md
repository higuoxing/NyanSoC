# hello_world

Repeatedly prints `Hello, world!` over UART TX every ~0.5 s.

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
