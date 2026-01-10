imem.elf: imem.s
	riscv64-elf-gcc -O0 -nostdlib \
		-march=rv32i -mabi=ilp32 -mno-relax \
		-Ttext=0 imem.s -o imem.elf

imem.hex: imem.elf
	riscv64-elf-objcopy -O verilog imem.elf imem.hex

sim: imem.hex
	iverilog -g2012 nyan_core.v nyan_core_tb.v
	vvp a.out

.PHONY: prove
prove:
	make -C gowin prove
	make -C uart prove

.PHONY: cover
cover:
	make -C gowin cover
	make -C uart cover
