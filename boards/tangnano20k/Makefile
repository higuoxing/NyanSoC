BOARD = tangnano20k
ROOT_DIR = ../..
YOSYS ?= yosys
NEXTPNR ?= nextpnr-himbaechel
TOP_MODULE ?= wrapper
SOURCES := $(shell find $(ROOT_DIR)/rtl -name '*.v')
SOURCES += $(TOP_MODULE).v

all: $(BOARD).fs

$(BOARD).fs: $(BOARD).json
	gowin_pack -d GW2A-18C -o $@ $<

$(BOARD).json: $(BOARD)-synth.json $(BOARD).cst
	$(NEXTPNR) --top $(TOP_MODULE)  --json $< --write $@ --device "GW2AR-LV18QN88C8/I7" --vopt family="GW2A-18C" --vopt cst=$(BOARD).cst

$(BOARD)-synth.json: $(SOURCES)
	$(YOSYS) -D LEDS_NR=6 -D OSC_TYPE_OSC -D INV_BTN=1 -D CPU_FREQ=27 -D BAUD_RATE=115200 -D NUM_HCLK=5 -p "read_verilog $^; hierarchy -top $(TOP_MODULE); synth_gowin -json $@ -family gw2a"

.PHONY: flash
flash: $(BOARD).fs
	openFPGALoader -b $(BOARD) $(BOARD).fs

.PHONY: clean
clean:
	rm -f *.fs *.json
