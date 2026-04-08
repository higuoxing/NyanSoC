# sw/Makefile — NyanSoC software build (OpenSBI)
#
# Targets:
#   make opensbi          — build OpenSBI fw_jump.bin for NyanSoC
#   make opensbi-clean    — clean OpenSBI build artefacts
#   make sbi_stub         — build the S-mode test stub kernel
#   make sbi_stub-clean   — clean stub build artefacts
#   make sd-image         — build the SD card boot image (nyansoc_sd.img)
#   make clean            — clean everything

ROOT_DIR      := $(abspath ..)
OPENSBI_DIR   := $(ROOT_DIR)/sw/opensbi
PLATFORM_DIR  := $(ROOT_DIR)/sw/opensbi-platform
STUB_DIR      := $(ROOT_DIR)/firmware/sbi_stub

# OpenSBI must be built with GNU make. If `make` is shadowed (e.g. IDE stub named "make"
# on PATH), recursive $(MAKE) breaks; prefer gmake or /usr/bin/make.
GNU_MAKE      := $(shell command -v gmake 2>/dev/null || echo /usr/bin/make)
SUBMAKE       := $(if $(findstring cursor,$(MAKE)),$(GNU_MAKE),$(MAKE))

CROSS_COMPILE ?= riscv64-elf-
FW_TEXT_START ?= 0x80000000

OPENSBI_OUT   := $(OPENSBI_DIR)/build/platform/nyansoc/firmware/fw_jump.bin

# ── OpenSBI ───────────────────────────────────────────────────────────────────

.PHONY: opensbi
opensbi: $(OPENSBI_OUT)

$(OPENSBI_OUT): $(PLATFORM_DIR) $(OPENSBI_DIR)/Makefile
	@echo "==> Applying no-PIE patch to OpenSBI..."
	@cd $(OPENSBI_DIR) && \
	    if ! grep -q "bare-metal build" Makefile; then \
	        patch -p1 < $(ROOT_DIR)/sw/opensbi-no-pie.patch; \
	    else \
	        echo "    (already patched, skipping)"; \
	    fi
	@echo "==> Syncing platform files..."
	@cp -r $(PLATFORM_DIR)/. $(OPENSBI_DIR)/platform/nyansoc/
	@echo "==> Building OpenSBI..."
	$(SUBMAKE) -C $(OPENSBI_DIR) \
	    PLATFORM=nyansoc \
	    CROSS_COMPILE=$(CROSS_COMPILE) \
	    FW_TEXT_START=$(FW_TEXT_START)
	@echo ""
	@echo "OpenSBI fw_jump.bin: $$(ls -lh $(OPENSBI_OUT) | awk '{print $$5}')"
	@echo "Entry point: $(FW_TEXT_START)"

.PHONY: opensbi-clean
opensbi-clean:
	$(SUBMAKE) -C $(OPENSBI_DIR) distclean 2>/dev/null || \
	    $(SUBMAKE) -C $(OPENSBI_DIR) clean 2>/dev/null || true

# ── S-mode stub kernel ────────────────────────────────────────────────────────

.PHONY: sbi_stub
sbi_stub:
	$(MAKE) -C $(STUB_DIR)

.PHONY: sbi_stub-clean
sbi_stub-clean:
	$(MAKE) -C $(STUB_DIR) clean

# ── SD card image ─────────────────────────────────────────────────────────────

.PHONY: sd-image
sd-image: opensbi sbi_stub
	$(ROOT_DIR)/scripts/make_sd_image.sh $(ROOT_DIR)/nyansoc_sd.img

# ── Clean all ─────────────────────────────────────────────────────────────────

.PHONY: clean
clean: opensbi-clean sbi_stub-clean
