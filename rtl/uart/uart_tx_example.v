// This module serves as an example for using UART TX module. After
// initialization, this module will continuously send "Hello" to the host
// machine.  We can use tio to verify it.
// $ tio -b 115200 /dev/ttyUSB1

module uart_tx_example (
    input  wire i_clk,
    input  wire i_rst_n,
    output wire o_uart_tx
);

  wire tx_busy;
  reg [7:0] tx_data;
  reg [31:0] counter;
  wire [7:0] hello[7];

  assign hello[0] = "H";
  assign hello[1] = "e";
  assign hello[2] = "l";
  assign hello[3] = "l";
  assign hello[4] = "o";
  assign hello[5] = "\r";
  assign hello[6] = "\n";

  uart_tx #(
      .CLK_FREQ (27_000_000),
      .BAUD_RATE(115200)
  ) tx (
      .i_clk(i_clk),
      .i_rst_n(i_rst_n),
      .i_tx_wr(1'b1),
      .o_tx(o_uart_tx),
      .o_tx_busy(tx_busy),
      .i_tx_data(tx_data)
  );

  always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      counter <= 0;
    end else begin
      if (!tx_busy) counter <= counter + 1;
    end
  end

  always @(*) begin
    tx_data = hello[counter%7];
  end
endmodule  // uart_tx_example
