.PHONY: prove
prove:
	make -C rtl prove
	make -C formal prove

.PHONY: cover
cover:
	make -C rtl cover
	make -C formal cover
