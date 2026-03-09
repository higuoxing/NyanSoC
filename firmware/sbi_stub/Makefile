CROSS   ?= riscv64-elf
CC      := $(CROSS)-gcc
OBJCOPY := $(CROSS)-objcopy
OBJDUMP := $(CROSS)-objdump

CFLAGS  := -march=rv32ima_zicsr -mabi=ilp32 -Os -ffreestanding -nostdlib \
            -nostartfiles -Wall -Wextra
LDFLAGS := -T link.ld -march=rv32ima_zicsr -mabi=ilp32 -nostdlib \
            -nostartfiles -Wl,--no-relax

SRCS    := start.S sbi_stub.c

.PHONY: all clean dis

all: sbi_stub.bin

sbi_stub.elf: $(SRCS) link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS)

sbi_stub.bin: sbi_stub.elf
	$(OBJCOPY) -O binary $< $@

dis: sbi_stub.elf
	$(OBJDUMP) -d $<

clean:
	rm -f sbi_stub.elf sbi_stub.bin
