.PHONY: prove cover prove_tx cover_tx prove_rx cover_rx

prove: prove_tx prove_rx

cover: cover_tx cover_rx

prove_tx:
	sby -f uart_tx.sby prove

cover_tx:
	sby -f uart_tx.sby cover

prove_rx:
	sby -f uart_rx.sby prove

cover_rx:
	sby -f uart_rx.sby cover
