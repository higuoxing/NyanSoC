# SPDX-License-Identifier: BSD-2-Clause
#
# OpenSBI platform Makefile for NyanSoC (Tang Nano 20K)

# RV32IMA, ILP32 ABI, medany code model
PLATFORM_RISCV_XLEN       = 32
PLATFORM_RISCV_ABI        = ilp32
PLATFORM_RISCV_ISA        = rv32ima_zicsr_zifencei
PLATFORM_RISCV_CODE_MODEL = medany

platform-objs-y += platform.o uart_nyansoc.o

# fw_jump: OpenSBI jumps to a fixed kernel address.
# The bootloader places the kernel at 0x8020_0000 and the DTB at 0x8100_0000.
FW_JUMP       = y
FW_JUMP_ADDR  = 0x80200000
FW_JUMP_FDT_ADDR = 0x81000000
