	.section .text
	.globl _start

_start:
	addi x1, x0, 0
	addi x2, x0, 10

loop:
	addi x1, x1, 1
	beq x1, x2, done
	jal x0, loop

done:
	jal x0, done
