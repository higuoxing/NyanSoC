##############################################################################
# NyanSoC formal verification - formal/Makefile
#
# Usage:
#   make setup       - init submodule and install nyanrv core files
#   make genchecks   - (re-)generate SymbiYosys check scripts from checks.cfg
#   make prove       - run all BMC checks in parallel
#   make cover       - run the cover check
#   make clean       - remove generated checks directory
#
# On a fresh clone, run `make setup` once before `make prove`.
##############################################################################

CORE      := nyanrv
COREDIR   := riscv-formal/cores/$(CORE)
CHECKSDIR := $(COREDIR)/checks
SRCDIR    := nyanrv

NPROC := $(shell nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 1)

# Files we own that live in formal/nyanrv/ and are synced into the submodule.
CORE_FILES := checks.cfg wrapper.sv .gitignore

.PHONY: setup
setup:
	git submodule update --init riscv-formal
	@# Prevent the submodule from reporting our core files as untracked.
	@EXCLUDE=../.git/modules/formal/riscv-formal/info/exclude; \
	 grep -qF "cores/nyanrv/" "$$EXCLUDE" 2>/dev/null || echo "cores/nyanrv/" >> "$$EXCLUDE"
	$(MAKE) sync

# Copy our core files into the submodule's cores/nyanrv/ directory.
.PHONY: sync
sync:
	mkdir -p $(COREDIR)
	$(foreach f,$(CORE_FILES),cp $(SRCDIR)/$(f) $(COREDIR)/$(f);)

.PHONY: genchecks
genchecks: sync
	cd $(COREDIR) && python3 ../../checks/genchecks.py

$(CHECKSDIR)/makefile: genchecks

.PHONY: prove
prove: $(CHECKSDIR)/makefile
	$(MAKE) -C $(CHECKSDIR) -j$(NPROC)

.PHONY: cover
cover: $(CHECKSDIR)/makefile
	sby -f $(CHECKSDIR)/cover.sby

.PHONY: clean
clean:
	rm -rf $(CHECKSDIR)
