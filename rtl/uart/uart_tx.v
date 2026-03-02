`default_nettype none
`timescale 1 ns / 1 ps

module uart_tx #(
    parameter integer CLK_FREQ  = 50_000_000,
    parameter integer BAUD_RATE = 115200
) (
    input wire i_clk,
    input wire i_rst_n,
    input wire i_tx_wr,
    output wire o_tx,
    output wire o_tx_busy,
    input wire [7:0] i_tx_data
);

  localparam integer CYCLES_PER_BAUD = CLK_FREQ / BAUD_RATE;

  localparam integer TX_IDLE = 2'd0;
  localparam integer TX_START = 2'd1;
  localparam integer TX_DATA = 2'd2;
  localparam integer TX_STOP = 2'd3;

  reg        tx;
  reg [ 3:0] bit_count;
  reg [31:0] cycle_count;
  reg [ 1:0] tx_state;
  reg [ 7:0] tx_data;

  assign o_tx = tx;
  assign o_tx_busy = tx_state != TX_IDLE;

  always @(posedge i_clk) begin
    if (!i_rst_n) begin
      tx_state <= TX_IDLE;
      cycle_count <= 0;
      bit_count <= 0;
      tx_data <= 8'b0;
    end else begin
      if (tx_state == TX_IDLE) begin
        cycle_count <= 0;
        bit_count   <= 0;
        if (i_tx_wr) begin
          tx_state <= TX_START;
          tx_data  <= i_tx_data;
        end else begin
          tx_data <= 8'b0;
        end
      end // if (tx_state == TX_IDLE)
      else if (tx_state == TX_START) begin
        bit_count <= 0;
        if (cycle_count == CYCLES_PER_BAUD - 1) begin
          cycle_count <= 0;
          tx_state <= TX_DATA;
        end else begin
          cycle_count <= cycle_count + 1;
        end
      end // if (tx_state == TX_START)
      else if (tx_state == TX_DATA) begin
        if (cycle_count == CYCLES_PER_BAUD - 1) begin
          cycle_count <= 0;
          if (bit_count < 7) begin
            bit_count <= bit_count + 1;
          end else begin
            bit_count <= 0;
            tx_data   <= 8'b0;
            tx_state  <= TX_STOP;
          end
        end else begin
          cycle_count <= cycle_count + 1;
        end
      end // if (tx_state == TX_DATA)
      else if (tx_state == TX_STOP) begin
        bit_count <= 0;
        tx_data   <= 8'b0;
        if (cycle_count == CYCLES_PER_BAUD - 2) begin
          cycle_count <= 0;
          tx_state <= TX_IDLE;
        end else begin
          cycle_count <= cycle_count + 1;
        end
      end  // if (tx_state == TX_STOP)
    end
  end  // always @ (posedge i_clk)

  always @(*) begin
    if (tx_state == TX_START) begin
      tx = 0;
    end else if (tx_state == TX_DATA) begin
      tx = tx_data[bit_count];
    end else begin
      tx = 1;
    end
  end

`ifdef FORMAL
  reg [ 7:0] f_data;
  reg [31:0] f_counter;
  reg        f_past_valid;

  initial begin
    assume (f_counter == 32'd0);
    assume (f_past_valid == 1'b0);
    assume (i_rst_n == 1'b0);
  end

  // Reset it before verification.
  always @(posedge i_clk) f_past_valid <= 1'b1;

  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n == 1'b1);
  end

  always @(*) begin
    if (f_past_valid) begin
      // tx_state must be one of TX_IDLE, TX_START, TX_DATA, TX_STOP.
      assert(tx_state == TX_IDLE || tx_state == TX_START ||
           tx_state == TX_DATA || tx_state == TX_STOP);

      // o_tx_busy is low iff tx_state == TX_IDLE.
      if (!o_tx_busy) assert (tx_state == TX_IDLE);

      // When tx_state is in the IDLE / STOP state, o_tx is high.
      if (tx_state == TX_IDLE || tx_state == TX_STOP) assert (o_tx == 1'b1);
      if (tx_state == TX_START) assert (o_tx == 1'b0);

      // bit_count should always be less than or equal to 7.
      assert (bit_count <= 7);
    end
  end  // always @ (*)

  // Checks that all states are reachable.
  always @(*) cover (i_rst_n && tx_state == TX_IDLE);
  always @(*) cover (i_rst_n && tx_state == TX_START);
  always @(*) cover (i_rst_n && tx_state == TX_DATA);
  always @(*) cover (i_rst_n && tx_state == TX_STOP);

  // Capture the data being sent.
  always @(posedge i_clk) begin
    if (i_tx_wr && !o_tx_busy && i_rst_n) f_data <= i_tx_data;
  end

  // UART TX counter.
  always @(posedge i_clk) begin
    if (!o_tx_busy || !i_rst_n) f_counter <= 0;
    else f_counter <= f_counter + 1;
  end

  // Check clock cycles.
  always @(*) begin
    if (f_past_valid) begin
      case (tx_state)
        TX_START: assert (f_counter == cycle_count);
        TX_DATA:  assert (f_counter == CYCLES_PER_BAUD * (bit_count + 1) + cycle_count);
        TX_STOP:  assert (f_counter == CYCLES_PER_BAUD * 9 + cycle_count);
      endcase  // case (tx_state)
    end
  end

  // Check the duration of each states.
  always @(posedge i_clk) begin
    if (f_past_valid) begin
      unique casex ({
        $past(tx_state), tx_state
      })
        // Verify that TX_START lives for CYCLES_PER_BAUD cycles.
        {
          TX_START, TX_DATA
        } : begin
          assert ($past(cycle_count) == CYCLES_PER_BAUD - 1);
          assert (cycle_count == 0);
        end
        // Verify that each bit lives for CYCLES_PER_BAUD cycles.
        {
          TX_DATA, TX_STOP
        } : begin
          assert ($past(cycle_count) == CYCLES_PER_BAUD - 1);
          assert (cycle_count == 0);
        end
        // Verify that stop bit lives for CYCLES_PER_BAUD cycles.
        {
          TX_STOP, TX_IDLE
        } : begin
          assert ($past(cycle_count) == CYCLES_PER_BAUD - 2);
          assert (cycle_count == 0);
        end
      endcase
    end
  end  // always @ (posedge i_clk)

  // Verify that the start bit lives for CYCLES_PER_BAUD cycles.
  always @(posedge i_clk) begin
    if (f_past_valid) begin
      if (tx_state == TX_DATA && $past(bit_count) + 1 == bit_count) begin
        assert ($past(cycle_count) == CYCLES_PER_BAUD - 1);
        assert (cycle_count == 0);
      end
    end
  end

  // Check data that we're transmitting.
  always @(*) begin
    if (i_rst_n && f_past_valid && tx_state == TX_DATA) assert (o_tx == tx_data[bit_count]);
  end

`endif  // FORMAL

endmodule  // uart_tx
