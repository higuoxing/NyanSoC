CROSS   ?= riscv64-elf
CC      := $(CROSS)-gcc
OBJCOPY := $(CROSS)-objcopy
OBJDUMP := $(CROSS)-objdump

CFLAGS  := -march=rv32i -mabi=ilp32 -Os -ffreestanding -nostdlib \
            -nostartfiles -Wall -Wextra
LDFLAGS := -T link.ld -march=rv32i -mabi=ilp32 -nostdlib \
            -nostartfiles -Wl,--no-relax

SRCS    := start.S sdram_test.c

# Load address for uart_loader flat binary.
BIN_ADDR ?= 0x80000000

.PHONY: all clean dis bin

all: imem.hex imem_init.vh imem_rom.vh imem_data_rom.vh

imem.hex: sdram_test.elf
	$(OBJCOPY) -O verilog --verilog-data-width=4 \
	    --only-section=.text --only-section=.rodata \
	    $< $@

AWK_HEXTODEC := function hextodec(h,  i,v,c){v=0;h=toupper(h);for(i=1;i<=length(h);i++){c=index("0123456789ABCDEF",substr(h,i,1))-1;v=v*16+c};return v} {gsub(/\r/,"",$$0)}

imem_init.vh: imem.hex
	awk '$(AWK_HEXTODEC) \
	     /^@/{addr=hextodec(substr($$0,2)); next} \
	     {for(i=1;i<=NF;i++) printf "    imem[%d] = 32'\''h%s;\n", addr++, $$i}' \
	    $< > $@

imem_rom.vh: imem.hex
	@printf '    case (imem_idx)\n' > $@
	awk '$(AWK_HEXTODEC) \
	     /^@/{addr=hextodec(substr($$0,2)); next} \
	     {for(i=1;i<=NF;i++){gsub(/\r/,"",$$i); printf "      10'\''d%d: imem_rdata = 32'\''h%s;\n", addr++, toupper($$i)}}' \
	    $< >> $@
	@printf '      default: imem_rdata = 32'\''h00000013;\n    endcase\n' >> $@

imem_data_rom.vh: imem.hex
	awk '$(AWK_HEXTODEC) \
	     /^@/{addr=hextodec(substr($$0,2)); next} \
	     {for(i=1;i<=NF;i++){gsub(/\r/,"",$$i); printf "      10'\''d%d: dmem_imem_rdata = 32'\''h%s;\n", addr++, toupper($$i)}}' \
	    $< > $@

sdram_test.elf: $(SRCS) link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS)

# Flat binary linked at BIN_ADDR for uart_loader.
# Uses start_ram.S (stack in SDRAM) instead of start.S (stack in DMEM).
bin: sdram_test.bin
sdram_test.bin: sdram_test.c ../start_ram.S ../link_ram.ld
	$(CC) $(CFLAGS) -T ../link_ram.ld -Wl,--defsym,RAM_BASE=$(BIN_ADDR) \
	    -march=rv32im_zicsr -mabi=ilp32 -nostdlib -nostartfiles -Wl,--no-relax \
	    -o sdram_test_ram.elf ../start_ram.S sdram_test.c
	$(OBJCOPY) -O binary sdram_test_ram.elf $@
	@ls -la $@

dis: sdram_test.elf
	$(OBJDUMP) -d $<

clean:
	rm -f sdram_test.elf sdram_test_ram.elf sdram_test.bin \
	      imem.hex imem_init.vh imem_rom.vh imem_data_rom.vh
