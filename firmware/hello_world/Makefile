CROSS   := riscv32-unknown-elf
CC      := $(CROSS)-gcc
OBJCOPY := $(CROSS)-objcopy
OBJDUMP := $(CROSS)-objdump

CFLAGS  := -march=rv32i -mabi=ilp32 -Os -ffreestanding -nostdlib \
            -nostartfiles -Wall -Wextra
LDFLAGS := -T link.ld -march=rv32i -mabi=ilp32 -nostdlib \
            -nostartfiles -Wl,--no-relax

SRCS    := start.S hello_world.c

.PHONY: all clean dis

all: imem.hex imem_init.vh imem_rom.vh imem_data_rom.vh

imem.hex: hello_world.elf
	$(OBJCOPY) -O verilog --verilog-data-width=4 \
	    --only-section=.text --only-section=.rodata \
	    $< $@

# imem_init.vh: explicit Verilog initial assignments (for simulation).
imem_init.vh: imem.hex
	awk '/^@/{addr=strtonum("0x"substr($$0,2)); next} \
	     {for(i=1;i<=NF;i++) printf "    imem[%d] = 32'\''h%s;\n", addr++, $$i}' \
	    $< > $@

# imem_rom.vh: combinatorial case-ROM include for synthesis.
imem_rom.vh: imem.hex
	@printf '    case (imem_idx)\n' > $@
	awk '/^@/{addr=strtonum("0x"substr($$0,2)); next} \
	     {for(i=1;i<=NF;i++){gsub(/\r/,"",$$i); printf "      10'\''d%d: imem_rdata = 32'\''h%s;\n", addr++, toupper($$i)}}' \
	    $< >> $@
	@printf '      default: imem_rdata = 32'\''h00000013;\n    endcase\n' >> $@

hello_world.elf: $(SRCS) link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS)

dis: hello_world.elf
	$(OBJDUMP) -d $<

# imem_data_rom.vh: same ROM but assigns dmem_imem_rdata (for data-bus .rodata reads).
imem_data_rom.vh: imem.hex
	awk '/^@/{addr=strtonum("0x"substr($$0,2)); next} \
	     {for(i=1;i<=NF;i++){gsub(/\r/,"",$$i); printf "      10'\''d%d: dmem_imem_rdata = 32'\''h%s;\n", addr++, toupper($$i)}}' \
	    $< > $@

clean:
	rm -f hello_world.elf imem.hex imem_init.vh imem_rom.vh imem_data_rom.vh
