# torture.s
.section .text
.globl _start

_start:
    # --- Test 1: Immediate Sign Extension ---
    addi x1, x0, -1         # x1 = 0xFFFFFFFF
    addi x2, x0, 1          # x2 = 0x00000001
    add  x3, x1, x2         # x3 should be 0 (Testing overflow/adder)
    
    # --- Test 2: Shift Logic (SRAI vs SRLI) ---
    addi x4, x0, -2         # x4 = 0xFFFFFFFE
    srli x5, x4, 1          # x5 = 0x7FFFFFFF (Logical)
    srai x6, x4, 1          # x6 = 0xFFFFFFFF (Arithmetic - keeps sign)

    # --- Test 3: Load/Store Byte Alignment ---
    addi x7, x0, 0x123      # Load small value
    sw   x7, 100(x0)        # Store Word at 100
    addi x8, x0, 0x45       # 
    sb   x8, 101(x0)        # Store Byte at 101 (Overwrites part of the word)
    lw   x9, 100(x0)        # x9 should be 0x00004523 (if Little Endian)

    # --- Test 4: Branching Edge Cases ---
    addi x10, x0, 1
    addi x11, x0, -1
    bltu x10, x11, .L1      # Unsigned: 1 < 0xFFFFFFFF is TRUE
    ebreak                  # Fail if reached
.L1:
    blt  x11, x10, .L2      # Signed: -1 < 1 is TRUE
    ebreak                  # Fail if reached
.L2:
    # --- Test 5: JALR Alignment ---
    la   x12, .Ltarget      # Get address
    addi x12, x12, 1        # Make it misaligned (odd)
    jalr x0, 0(x12)         # JALR should mask the low bit to 0 and work
    ebreak
.Ltarget:
    addi x31, x0, 0x666     # The "Success" flag
    slli x0, x0, 0          # Trap/Finish
