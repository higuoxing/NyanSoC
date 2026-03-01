BOARD      = tangnano20k
ROOT_DIR   = ../..
PROG_DIR   = $(ROOT_DIR)/firmwares/blinky
YOSYS     ?= yosys
NEXTPNR   ?= nextpnr-himbaechel
TOP_MODULE ?= soc
SOURCES   := $(ROOT_DIR)/rtl/nyanrv.v
SOURCES   += $(TOP_MODULE).v

all: $(BOARD).fs

# ── Blinky hex (instruction memory image) ────────────────────────────────────
imem.hex imem_rom.vh:
	make -C $(PROG_DIR)
	cp $(PROG_DIR)/imem.hex .
	cp $(PROG_DIR)/imem_rom.vh .

# ── FPGA bitstream ────────────────────────────────────────────────────────────
$(BOARD).fs: $(BOARD).json
	gowin_pack -d GW2A-18C -o $@ $<

$(BOARD).json: $(BOARD)-synth.json $(BOARD).cst
	$(NEXTPNR) --top $(TOP_MODULE) --json $< --write $@ \
	    --device "GW2AR-LV18QN88C8/I7" \
	    --vopt family="GW2A-18C" --vopt cst=$(BOARD).cst

# imem_rom.vh must exist before synthesis so the `include resolves.
$(BOARD)-synth.json: $(SOURCES) imem.hex imem_rom.vh
	$(YOSYS) -p "read_verilog $(SOURCES); synth_gowin -json $@ -family gw2a"

.PHONY: flash flash-sram
flash: $(BOARD).fs
	openFPGALoader -b $(BOARD) --write-flash $(BOARD).fs

flash-sram: $(BOARD).fs
	openFPGALoader -b $(BOARD) $(BOARD).fs

.PHONY: clean
clean:
	rm -f *.fs *.json imem.hex imem_rom.vh
	make -C $(PROG_DIR) clean
