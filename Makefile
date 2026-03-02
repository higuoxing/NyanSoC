##############################################################################
# NyanSoC root Makefile
#
# Delegates to sub-Makefiles. Run `make` (or `make help`) to list targets.
##############################################################################

BOARD ?= tangnano20k

.PHONY: help
help:
	@echo "NyanSoC — available make targets"
	@echo ""
	@echo "  Simulation"
	@echo "    sim            Run all CPU simulation tests (iverilog)"
	@echo "    sim-waves      Run first sim test and dump waveform (.vcd)"
	@echo ""
	@echo "  Formal verification"
	@echo "    prove          Run all BMC formal checks (CPU + UART)"
	@echo "    cover          Run all cover checks (CPU + UART)"
	@echo ""
	@echo "  FPGA — Tang Nano 20K  (BOARD=$(BOARD))"
	@echo "    bitstream      Synthesise + P&R → $(BOARD).fs"
	@echo "    flash          Write bitstream to SPI flash (persistent)"
	@echo "    flash-sram     Write bitstream to SRAM (volatile)"
	@echo "    board-clean    Remove board build artefacts"
	@echo ""
	@echo "  Firmware"
	@echo "    firmware       Build blinky firmware (imem.hex + imem_rom.vh)"
	@echo "    firmware-clean Remove firmware build artefacts"
	@echo ""
	@echo "  Housekeeping"
	@echo "    clean          Clean everything (sim + firmware + board)"
	@echo ""

# ── Simulation ───────────────────────────────────────────────────────────────

.PHONY: sim sim-waves
sim:
	$(MAKE) -C sim/sw run

sim-waves:
	$(MAKE) -C sim/sw waves

# ── Formal verification ───────────────────────────────────────────────────────

.PHONY: prove cover
prove:
	$(MAKE) -C rtl prove
	$(MAKE) -C formal prove

cover:
	$(MAKE) -C rtl cover
	$(MAKE) -C formal cover

# ── FPGA ──────────────────────────────────────────────────────────────────────

.PHONY: bitstream flash flash-sram board-clean
bitstream:
	$(MAKE) -C boards/$(BOARD)

flash:
	$(MAKE) -C boards/$(BOARD) flash

flash-sram:
	$(MAKE) -C boards/$(BOARD) flash-sram

board-clean:
	$(MAKE) -C boards/$(BOARD) clean

# ── Firmware ──────────────────────────────────────────────────────────────────

.PHONY: firmware firmware-clean
firmware:
	$(MAKE) -C firmware/blinky

firmware-clean:
	$(MAKE) -C firmware/blinky clean

# ── Clean all ─────────────────────────────────────────────────────────────────

.PHONY: clean
clean: board-clean firmware-clean
	$(MAKE) -C sim/sw clean
