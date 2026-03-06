CROSS   ?= riscv32-unknown-elf
CC      := $(CROSS)-gcc
OBJCOPY := $(CROSS)-objcopy
OBJDUMP := $(CROSS)-objdump

CFLAGS  := -march=rv32im_zicsr -mabi=ilp32 -Os -ffreestanding -nostdlib \
            -nostartfiles -Wall -Wextra
LDFLAGS := -T link.ld -march=rv32im_zicsr -mabi=ilp32 -nostdlib \
            -nostartfiles -Wl,--no-relax

SRCS    := start.S clint_test.c

AWK_HEXTODEC := function hextodec(h,  i,v,c){v=0;h=toupper(h);for(i=1;i<=length(h);i++){c=index("0123456789ABCDEF",substr(h,i,1))-1;v=v*16+c};return v} {gsub(/\r/,"",$$0)}

.PHONY: all clean dis

all: imem.hex imem_init.vh imem_rom.vh imem_data_rom.vh

imem.hex: clint_test.elf
	$(OBJCOPY) -O verilog --verilog-data-width=4 \
	    --only-section=.text --only-section=.rodata \
	    $< $@

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

clint_test.elf: $(SRCS) link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS)

dis: clint_test.elf
	$(OBJDUMP) -d $<

clean:
	rm -f clint_test.elf imem.hex imem_init.vh imem_rom.vh imem_data_rom.vh
