PROJ_ROOT := ..
RTL       := $(PROJ_ROOT)/rtl
SIM_RTL   := $(PROJ_ROOT)/sim/rtl

.PHONY: all run_cpu run_uart clean

all: run_cpu run_uart

run_cpu:
	$(MAKE) -C sw run

uart_tb.vvp: $(SIM_RTL)/uart_tb.v $(RTL)/uart/uart_tx.v $(RTL)/uart/uart_rx.v
	iverilog -g2012 -o $@ $^

run_uart: uart_tb.vvp
	@result=$$(vvp uart_tb.vvp 2>&1); \
	echo "$$result" | grep -v "^Results:" | grep -v "^$$"; \
	if echo "$$result" | grep -q "^PASS"; then \
	    echo "PASS  uart"; \
	else \
	    echo "FAIL  uart"; \
	    exit 1; \
	fi

clean:
	rm -f uart_tb.vvp uart_tb.vcd
	$(MAKE) -C sw clean
