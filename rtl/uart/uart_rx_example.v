// This module serves as an example for using the UART RX module. It acts
// as a loopback: every byte received over UART is immediately echoed back
// to the sender. You can test it with tio:
// $ tio -b 115200 /dev/ttyUSB1
// (anything you type will be echoed back to the terminal)

module uart_rx_example (
    input  wire i_clk,
    input  wire i_rst_n,
    input  wire i_uart_rx,
    output wire o_uart_tx
);

  wire       rx_valid;
  wire [7:0] rx_data;

  wire       tx_busy;
  reg        tx_wr;
  reg  [7:0] tx_data;

  uart_rx #(
      .CLK_FREQ (27_000_000),
      .BAUD_RATE(115200)
  ) rx (
      .i_clk     (i_clk),
      .i_rst_n   (i_rst_n),
      .i_rx      (i_uart_rx),
      .o_rx_valid(rx_valid),
      .o_rx_data (rx_data)
  );

  uart_tx #(
      .CLK_FREQ (27_000_000),
      .BAUD_RATE(115200)
  ) tx (
      .i_clk    (i_clk),
      .i_rst_n  (i_rst_n),
      .i_tx_wr  (tx_wr),
      .o_tx     (o_uart_tx),
      .o_tx_busy(tx_busy),
      .i_tx_data(tx_data)
  );

  // Latch the received byte and request a TX write when the TX is free.
  always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      tx_wr   <= 1'b0;
      tx_data <= 8'b0;
    end else begin
      if (rx_valid && !tx_busy) begin
        tx_data <= rx_data;
        tx_wr   <= 1'b1;
      end else begin
        tx_wr <= 1'b0;
      end
    end
  end

endmodule  // uart_rx_example
