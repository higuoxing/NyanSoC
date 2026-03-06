##############################################################################
# NyanSoC test suite - rtl/sim/sw/Makefile
#
# Usage:
#   make              - build all tests and run them with iverilog
#   make build        - build only (generate .hex files)
#   make run          - run all tests (build if needed)
#   make test_alu     - build+run only the ALU test
#   make test_branch  - build+run only the branch test
#   make test_mem     - build+run only the memory test
#   make test_jump    - build+run only the jump test
#   make test_csr     - build+run only the CSR test
#   make test_mext    - build+run only the M-extension test
#   make clean        - remove all build artifacts
##############################################################################

CROSS   := riscv64-elf
CC      := $(CROSS)-gcc
AS      := $(CROSS)-gcc
LD      := $(CROSS)-gcc
OBJCOPY := $(CROSS)-objcopy
OBJDUMP := $(CROSS)-objdump

# Compiler/assembler flags
# rv32im_zicsr: M extension required for MUL/DIV instructions
ASFLAGS  := -march=rv32im_zicsr -mabi=ilp32 -nostartfiles -nostdlib
LDFLAGS  := -T link.ld -march=rv32im_zicsr -mabi=ilp32 -nostartfiles -nostdlib \
             -Wl,--no-relax

# Simulation sources (relative to repository root)
PROJ_ROOT := ../../..
TB        := $(PROJ_ROOT)/rtl/sim/rtl/nyanrv_tb.v
RTL       := $(PROJ_ROOT)/rtl/nyanrv.v
ASM_DIR   := asm

TESTS     := test_alu test_branch test_mem test_jump test_csr test_mext
IRQ_TB    := $(PROJ_ROOT)/rtl/sim/rtl/nyanrv_irq_tb.v

# Keep intermediate ELF files on build errors for easier debugging
.PRECIOUS: %.elf

# Default: build & run all
.PHONY: all
all: run

# ── Build rules ───────────────────────────────────────────────────────────────

.PHONY: build
build: $(addsuffix .hex, $(TESTS))

# Each test links crt0.S + the test .S -> ELF -> stripped binary -> hex
%.elf: $(ASM_DIR)/crt0.S $(ASM_DIR)/%.S link.ld
	$(AS) $(ASFLAGS) $(LDFLAGS) -o $@ $(ASM_DIR)/crt0.S $(ASM_DIR)/$*.S

%.hex: %.elf
	$(OBJCOPY) -O verilog --verilog-data-width=4 \
	    --only-section=.text --only-section=.data --only-section=.rodata \
	    $< $@

# Optional: disassembly for debugging
%.dis: %.elf
	$(OBJDUMP) -d $< > $@

# ── Simulation rules ──────────────────────────────────────────────────────────

# Compile the testbench once; each test run copies its .hex to imem.hex
nyanrv_tb.vvp: $(TB) $(RTL)
	iverilog -g2012 -o $@ $(RTL) $(TB)

.PHONY: run
run: build nyanrv_tb.vvp
	@pass=0; fail=0; \
	for t in $(TESTS); do \
	    cp $$t.hex imem.hex; \
	    result=$$(vvp nyanrv_tb.vvp 2>&1); \
	    if echo "$$result" | grep -q "^PASS"; then \
	        echo "PASS  $$t"; \
	        pass=$$((pass+1)); \
	    else \
	        echo "FAIL  $$t"; \
	        echo "$$result" | sed 's/^/      /'; \
	        fail=$$((fail+1)); \
	    fi; \
	done; \
	echo ""; \
	echo "Results: $$pass passed, $$fail failed out of $$((pass+fail)) tests"; \
	test $$fail -eq 0

# Per-test convenience targets
.PHONY: $(TESTS)
$(TESTS): %: %.hex nyanrv_tb.vvp
	@cp $*.hex imem.hex
	@result=$$(vvp nyanrv_tb.vvp 2>&1); \
	if echo "$$result" | grep -q "^PASS"; then \
	    echo "PASS  $*"; \
	else \
	    echo "FAIL  $*"; \
	    echo "$$result" | sed 's/^/      /'; \
	    exit 1; \
	fi

# ── IRQ test (uses its own testbench with interrupt stimulus) ─────────────────

nyanrv_irq_tb.vvp: $(IRQ_TB) $(RTL)
	iverilog -g2012 -o $@ $(RTL) $(IRQ_TB)

.PHONY: test_irq
test_irq: test_irq.hex nyanrv_irq_tb.vvp
	@cp test_irq.hex imem.hex
	@result=$$(vvp nyanrv_irq_tb.vvp 2>&1); \
	if echo "$$result" | grep -q "^PASS"; then \
	    echo "PASS  test_irq"; \
	else \
	    echo "FAIL  test_irq"; \
	    echo "$$result" | sed 's/^/      /'; \
	    exit 1; \
	fi

# ── S-mode test (uses dedicated testbench that doesn't stop on traps) ────────

SMODE_TB  := $(PROJ_ROOT)/rtl/sim/rtl/nyanrv_smode_tb.v

nyanrv_smode_tb.vvp: $(SMODE_TB) $(RTL)
	iverilog -g2012 -o $@ $(RTL) $(SMODE_TB)

# test_smode has its own _start — build without crt0.S
test_smode.elf: asm/test_smode.S link.ld
	$(AS) $(ASFLAGS) $(LDFLAGS) -o $@ asm/test_smode.S

.PHONY: test_smode
test_smode: test_smode.hex nyanrv_smode_tb.vvp
	@cp test_smode.hex imem.hex
	@result=$$(vvp nyanrv_smode_tb.vvp 2>&1); \
	if echo "$$result" | grep -q "^PASS"; then \
	    echo "PASS  test_smode"; \
	else \
	    echo "FAIL  test_smode"; \
	    echo "$$result" | sed 's/^/      /'; \
	    exit 1; \
	fi

# Optional: run with waveform dump (+dump plusarg)
.PHONY: waves
waves: $(firstword $(TESTS)).hex nyanrv_tb.vvp
	cp $(firstword $(TESTS)).hex imem.hex
	vvp nyanrv_tb.vvp +dump
	@echo "Waveform written to nyanrv_tb.vcd"

.PHONY: clean
clean:
	rm -f *.elf *.hex *.vvp *.vcd *.dis imem.hex
