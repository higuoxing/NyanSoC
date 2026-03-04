```
  _   _                    _____        _____
 | \ | |                  / ____|      / ____|
 |  \| |_   _  __ _ _ __ | (___   ___ | |
 | . ` | | | |/ _` | '_ \ \___ \ / _ \| |
 | |\  | |_| | (_| | | | |____) | (_) | |____
 |_| \_|\__, |\__,_|_| |_|_____/ \___/ \_____|
         __/ |
        |___/
```

A small, formally verified RISC-V SoC.

## Features

- **nyanrv** — RV32IM + Zicsr soft CPU with M-mode interrupt support (MTI + MEI)
- **UART TX/RX** — parameterised baud-rate UART with formal verification
- **SDRAM controller** — for GW2AR-18 embedded SDRAM (Tang Nano 20K)
- **SPI SD card controller** — SPI-mode SD card with full init sequence and block read/write
- Formally verified with [riscv-formal](https://github.com/YosysHQ/riscv-formal) and [SymbiYosys](https://github.com/YosysHQ/sby)

## Directory structure

```
NyanSoC/
├── rtl/
│   ├── nyanrv.v          # RV32I + Zicsr CPU core
│   ├── uart/
│   │   ├── uart_tx.v     # UART transmitter
│   │   └── uart_rx.v     # UART receiver
│   ├── gowin/
│   │   └── sdram_gw2ar.v  # SDRAM controller for GW2AR embedded SDRAM
│   └── sim/
│       ├── rtl/          # Simulation testbenches
│       └── sw/           # RV32I assembly test suite (iverilog)
├── boards/
│   └── tangnano20k/      # Tang Nano 20K top-level + P&R scripts (only supported board)
├── firmware/
│   ├── blinky/           # LED blink (C)
│   └── hello_world/      # "Hello, World!" over UART (C)
└── formal/
    ├── nyanrv/           # riscv-formal config and wrapper for nyanrv
    └── Makefile          # Formal verification flow
```

## Memory map (Tang Nano 20K SoC)

| Address range             | Region              |
|---------------------------|---------------------|
| `0x0000_0000–0x0000_0FFF` | IMEM (1 KiB, LUT-ROM) |
| `0x0001_0000–0x0001_0FFF` | DMEM (1 KiB, BRAM)  |
| `0x0002_0000`             | GPIO — bits [5:0] drive LED[5:0] |
| `0x0003_0004`             | UART TX — write: send byte; read: `{31'b0, busy}` |

> **Supported boards:** Tang Nano 20K only.

## Prerequisites

| Tool | Purpose |
|------|---------|
| [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) | Simulation, synthesis, formal verification |
| [openFPGALoader](https://github.com/trabucayre/openFPGALoader) | Flashing the FPGA |
| [riscv-gnu-toolchain](https://github.com/riscv-collab/riscv-gnu-toolchain) | Cross-compiler for firmware and sim tests |

Source the OSS CAD Suite environment before running any make targets:

```sh
source /path/to/oss-cad-suite/environment
```

## Quick start

```sh
# Run all CPU simulation tests
make sim

# Run all formal proofs and cover checks
make prove
make cover

# Build firmware and synthesise bitstream for Tang Nano 20K
make bitstream

# Flash to SRAM (volatile, lost on power cycle)
make flash-sram

# Flash to SPI flash (persistent)
make flash
```

## Simulation tests

The `rtl/sim/sw/` test suite assembles RV32I programs with `riscv64-elf-gcc` and
runs them under [Icarus Verilog](http://iverilog.icarus.com/):

```sh
make sim          # run all tests
make sim-waves    # run first test and dump a VCD waveform
```

Individual tests: `test_alu`, `test_branch`, `test_mem`, `test_jump`,
`test_csr`, `test_irq`, `test_mext`.

## Formal verification

```sh
make prove    # BMC checks: nyanrv (riscv-formal) + UART TX/RX
make cover    # Cover checks: reachability for all modules
```

The riscv-formal core files live in `formal/nyanrv/` and are synced into the
`riscv-formal` submodule at build time via `make -C formal setup`.

## UART modules

Both `uart_tx` and `uart_rx` are parameterised by `CLK_FREQ` and `BAUD_RATE`:

```verilog
uart_rx #(.CLK_FREQ(27_000_000), .BAUD_RATE(115200)) u_rx ( ... );
uart_tx #(.CLK_FREQ(27_000_000), .BAUD_RATE(115200)) u_tx ( ... );
```

See `rtl/uart/uart_rx_example.v` for a loopback echo example, and
`rtl/uart/uart_tx_example.v` for a continuous transmit example.
