BOARD      = tangnano20k
ROOT_DIR   = ../..
FW        ?= echo
PROG_DIR   = $(ROOT_DIR)/firmware/$(FW)
YOSYS      ?= yosys
NEXTPNR    ?= nextpnr-himbaechel
TOP_MODULE ?= top
SOURCES   := $(ROOT_DIR)/rtl/nyanrv.v
SOURCES   += $(ROOT_DIR)/rtl/uart/uart_rx.v
SOURCES   += $(ROOT_DIR)/rtl/uart/uart_tx.v
SOURCES   += $(ROOT_DIR)/rtl/sdspi/sdspi.v
SOURCES   += $(ROOT_DIR)/rtl/gowin/sdram_gw2ar.v
SOURCES   += $(TOP_MODULE).v

all: $(BOARD).fs

# ── Firmware hex (instruction memory image) ──────────────────────────────────
# Always re-run so that switching FW= picks up fresh output immediately.
.PHONY: FORCE
imem.hex imem_rom.vh imem_data_rom.vh: FORCE
	make -C $(PROG_DIR)
	cp $(PROG_DIR)/imem.hex .
	cp $(PROG_DIR)/imem_rom.vh .
	cp $(PROG_DIR)/imem_data_rom.vh .

# ── FPGA bitstream ────────────────────────────────────────────────────────────
$(BOARD).fs: $(BOARD).json
	gowin_pack -d GW2A-18C -o $@ $<

$(BOARD).json: $(BOARD)-synth.json $(BOARD).cst
	$(NEXTPNR) --top $(TOP_MODULE) --json $< --write $@ \
	    --device "GW2AR-LV18QN88C8/I7" \
	    --vopt family="GW2A-18C" --vopt cst=$(BOARD).cst

# imem_rom.vh must exist before synthesis so the `include resolves.
$(BOARD)-synth.json: $(SOURCES) imem.hex imem_rom.vh imem_data_rom.vh
	$(YOSYS) -p "read_verilog $(SOURCES); synth_gowin -json $@ -family gw2a"

.PHONY: flash flash-sram
flash: $(BOARD).fs
	openFPGALoader -b $(BOARD) --write-flash $(BOARD).fs

flash-sram: $(BOARD).fs
	openFPGALoader -b $(BOARD) $(BOARD).fs

.PHONY: clean
clean:
	rm -f *.fs *.json imem.hex imem_rom.vh imem_data_rom.vh
	make -C $(PROG_DIR) clean
