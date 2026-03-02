`default_nettype none
`timescale 1 ns / 1 ps

module uart_rx #(
    parameter integer CLK_FREQ  = 50_000_000,
    parameter integer BAUD_RATE = 115200
) (
    input  wire       i_clk,
    input  wire       i_rst_n,
    input  wire       i_rx,
    output wire       o_rx_valid,
    output wire [7:0] o_rx_data
);

  localparam integer CYCLES_PER_BAUD = CLK_FREQ / BAUD_RATE;
  // Sample in the middle of each bit period.
  localparam integer CYCLES_HALF_BAUD = CYCLES_PER_BAUD / 2;

  localparam integer RX_IDLE  = 2'd0;
  localparam integer RX_START = 2'd1;
  localparam integer RX_DATA  = 2'd2;
  localparam integer RX_STOP  = 2'd3;

  // Two-FF synchroniser for the async i_rx input.
  reg rx_meta, rx_sync;
  always @(posedge i_clk) begin
    rx_meta <= i_rx;
    rx_sync <= rx_meta;
  end

  reg [1:0] rx_state;
  reg [31:0] cycle_count;
  reg [3:0] bit_count;
  reg [7:0] rx_data;
  reg rx_valid;

  assign o_rx_valid = rx_valid;
  assign o_rx_data  = rx_data;

  always @(posedge i_clk) begin
    if (!i_rst_n) begin
      rx_state    <= RX_IDLE;
      cycle_count <= 0;
      bit_count   <= 0;
      rx_data     <= 8'b0;
      rx_valid    <= 1'b0;
    end else begin
      rx_valid <= 1'b0;

      if (rx_state == RX_IDLE) begin
        cycle_count <= 0;
        bit_count   <= 0;
        // Falling edge on RX signals start bit.
        if (!rx_sync) begin
          rx_state <= RX_START;
        end
      end  // RX_IDLE

      else if (rx_state == RX_START) begin
        // Wait half a baud period then verify the line is still low
        // (not a glitch) before sampling data bits at mid-bit.
        if (cycle_count == CYCLES_HALF_BAUD - 1) begin
          cycle_count <= 0;
          if (!rx_sync) begin
            rx_state <= RX_DATA;
          end else begin
            // Glitch — line went high again, return to idle.
            rx_state <= RX_IDLE;
          end
        end else begin
          cycle_count <= cycle_count + 1;
        end
      end  // RX_START

      else if (rx_state == RX_DATA) begin
        // Sample each data bit at the middle of its baud period.
        if (cycle_count == CYCLES_PER_BAUD - 1) begin
          cycle_count             <= 0;
          rx_data[bit_count[2:0]] <= rx_sync;
          if (bit_count < 7) begin
            bit_count <= bit_count + 1;
          end else begin
            bit_count <= 0;
            rx_state  <= RX_STOP;
          end
        end else begin
          cycle_count <= cycle_count + 1;
        end
      end  // RX_DATA

      else if (rx_state == RX_STOP) begin
        // Wait one full baud period for the stop bit, then assert valid.
        if (cycle_count == CYCLES_PER_BAUD - 1) begin
          cycle_count <= 0;
          rx_state    <= RX_IDLE;
          if (rx_sync) begin
            // Valid stop bit received.
            rx_valid <= 1'b1;
          end
          // Framing error: stop bit low — data discarded, rx_valid stays 0.
        end else begin
          cycle_count <= cycle_count + 1;
        end
      end  // RX_STOP

    end
  end  // always @(posedge i_clk)

`ifdef FORMAL
  reg        f_past_valid;
  reg [31:0] f_counter;

  initial begin
    assume (f_past_valid == 1'b0);
    assume (f_counter == 32'd0);
    assume (i_rst_n == 1'b0);
  end

  always @(posedge i_clk) f_past_valid <= 1'b1;

  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n == 1'b1);
  end

  // Track total active cycles for timing assertions.
  always @(posedge i_clk) begin
    if (!i_rst_n || rx_state == RX_IDLE) f_counter <= 0;
    else f_counter <= f_counter + 1;
  end

  always @(*) begin
    if (f_past_valid) begin
      // rx_state must be one of the four defined states.
      assert (rx_state == RX_IDLE || rx_state == RX_START ||
              rx_state == RX_DATA || rx_state == RX_STOP);

      // bit_count never exceeds 7.
      assert (bit_count <= 7);

      // cycle_count stays within one baud period.
      assert (cycle_count < CYCLES_PER_BAUD);

      // o_rx_valid is a single-cycle pulse; it can only be high in IDLE
      // (the cycle we just transitioned back from STOP).
      if (o_rx_valid) assert (rx_state == RX_IDLE);
    end
  end

  // Checks that all states are reachable.
  always @(*) cover (i_rst_n && rx_state == RX_IDLE);
  always @(*) cover (i_rst_n && rx_state == RX_START);
  always @(*) cover (i_rst_n && rx_state == RX_DATA);
  always @(*) cover (i_rst_n && rx_state == RX_STOP);
  always @(*) cover (i_rst_n && o_rx_valid);

  // Timing: after the half-baud start delay, DATA runs for 8 full baud
  // periods; STOP runs for one more.
  always @(*) begin
    if (f_past_valid) begin
      case (rx_state)
        RX_START: assert (f_counter == cycle_count);
        RX_DATA:  assert (f_counter == CYCLES_HALF_BAUD + CYCLES_PER_BAUD * bit_count + cycle_count);
        RX_STOP:  assert (f_counter == CYCLES_HALF_BAUD + CYCLES_PER_BAUD * 8 + cycle_count);
      endcase
    end
  end

  // Verify state transition timing.
  always @(posedge i_clk) begin
    if (f_past_valid) begin
      unique casex ({$past(rx_state), rx_state})
        // START -> DATA: half-baud delay elapsed.
        {RX_START, RX_DATA}: begin
          assert ($past(cycle_count) == CYCLES_HALF_BAUD - 1);
          assert (cycle_count == 0);
        end
        // DATA -> STOP: all 8 bits sampled.
        {RX_DATA, RX_STOP}: begin
          assert ($past(cycle_count) == CYCLES_PER_BAUD - 1);
          assert ($past(bit_count) == 7);
          assert (cycle_count == 0);
        end
        // STOP -> IDLE: one full baud stop period elapsed.
        {RX_STOP, RX_IDLE}: begin
          assert ($past(cycle_count) == CYCLES_PER_BAUD - 1);
          assert (cycle_count == 0);
        end
      endcase
    end
  end

`endif  // FORMAL

endmodule  // uart_rx
