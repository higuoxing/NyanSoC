imem.elf: imem.s
	riscv64-elf-gcc -O0 -nostdlib \
		-march=rv32i -mabi=ilp32 -mno-relax \
		-Ttext=0 imem.s -o imem.elf

imem.bin: imem.elf
	riscv64-elf-objcopy -O binary imem.elf imem.bin

imem.hex: imem.bin
	hexdump -v -e '1/4 "%08x\n"' imem.bin > imem.hex

sim: imem.hex
	iverilog -g2012 nyanrv.v nyanrv_tb.v
	vvp a.out

.PHONY: prove
prove:
	make -C gowin prove
	make -C uart prove

.PHONY: cover
cover:
	make -C gowin cover
	make -C uart cover
