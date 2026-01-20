	.section .text
	.globl _start

_start:
	addi x1, x0, 0   # counter = 0
	addi x2, x0, 10  # limit = 10
	addi x3, x0, 0
	addi x4, x0, 0
loop:
	addi x1, x1, 1   # counter++
	beq x1, x2, done
	jal x0, loop
done:
	addi x5, x0, 0x123
	sb x5, 0x128(x3)
	lb x4, 0x128(x3)
	addi x5, x0, 0x123
	sh x5, 0x128(x3)
	lh x4, 0x128(x3)
	add x4, x0, 0
	jal x0, done
