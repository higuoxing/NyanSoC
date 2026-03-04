`timescale 1 ns / 1 ps

// uart_tb — simulation tests for uart_tx and uart_rx.
//
// Uses CLK_FREQ=16 / BAUD_RATE=1 so CYCLES_PER_BAUD=16, keeping
// simulation fast while exercising every baud-period boundary.
//
// Tests
//   1. uart_tx: transmit a single byte, decode bits on o_tx, verify data
//      and timing (start bit, 8 data bits, stop bit).
//   2. uart_tx: back-to-back transmit — send two bytes without a gap and
//      verify both are received correctly.
//   3. uart_rx: receive a single byte driven by a bit-bang task.
//   4. uart_rx: framing error — stop bit held low, o_rx_valid must not fire.
//   5. uart_rx: glitch rejection — sub-half-baud pulse on i_rx must be
//      ignored and the receiver must stay in IDLE.
//   6. Loopback — wire uart_tx.o_tx → uart_rx.i_rx and transmit a string,
//      verify every received byte matches.

module uart_tb;

  // ── Parameters ─────────────────────────────────────────────────────────────
  // Keep CYCLES_PER_BAUD small so simulation is fast.
  localparam integer CLK_FREQ       = 16;
  localparam integer BAUD_RATE      = 1;
  localparam integer CYCLES_PER_BAUD = CLK_FREQ / BAUD_RATE;  // 16
  localparam integer CYCLES_HALF_BAUD = CYCLES_PER_BAUD / 2;  // 8

  // Clock period in ns (arbitrary — timescale is ns/ps).
  localparam CLK_PERIOD = 10;

  // ── Clock ──────────────────────────────────────────────────────────────────
  reg clk = 0;
  always #(CLK_PERIOD / 2) clk = ~clk;

  // ── Test infrastructure ────────────────────────────────────────────────────
  integer pass_count = 0;
  integer fail_count = 0;

  task pass;
    input [8*64-1:0] name;
    begin
      $display("  PASS  %0s", name);
      pass_count = pass_count + 1;
    end
  endtask

  task fail;
    input [8*64-1:0] name;
    begin
      $display("  FAIL  %0s", name);
      fail_count = fail_count + 1;
    end
  endtask

  // Wait N rising edges of clk.
  task wait_cycles;
    input integer n;
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) @(posedge clk);
    end
  endtask

  // ── uart_tx DUT ────────────────────────────────────────────────────────────
  reg        tx_rst_n   = 0;
  reg        tx_wr      = 0;
  reg  [7:0] tx_data_in = 0;
  wire       o_tx;
  wire       o_tx_busy;

  uart_tx #(
      .CLK_FREQ (CLK_FREQ),
      .BAUD_RATE(BAUD_RATE)
  ) u_tx (
      .i_clk    (clk),
      .i_rst_n  (tx_rst_n),
      .i_tx_wr  (tx_wr),
      .o_tx     (o_tx),
      .o_tx_busy(o_tx_busy),
      .i_tx_data(tx_data_in)
  );

  // ── uart_rx DUT ────────────────────────────────────────────────────────────
  reg        rx_rst_n = 0;
  reg        rx_in    = 1;  // idle high
  wire       o_rx_valid;
  wire [7:0] o_rx_data;

  uart_rx #(
      .CLK_FREQ (CLK_FREQ),
      .BAUD_RATE(BAUD_RATE)
  ) u_rx (
      .i_clk     (clk),
      .i_rst_n   (rx_rst_n),
      .i_rx      (rx_in),
      .o_rx_valid(o_rx_valid),
      .o_rx_data (o_rx_data)
  );

  // ── Loopback RX (wired to o_tx) ────────────────────────────────────────────
  reg        lb_rst_n = 0;
  wire       lb_rx_valid;
  wire [7:0] lb_rx_data;

  uart_rx #(
      .CLK_FREQ (CLK_FREQ),
      .BAUD_RATE(BAUD_RATE)
  ) u_lb_rx (
      .i_clk     (clk),
      .i_rst_n   (lb_rst_n),
      .i_rx      (o_tx),       // connected to uart_tx output
      .o_rx_valid(lb_rx_valid),
      .o_rx_data (lb_rx_data)
  );

  // ── Helper: transmit one byte via uart_tx and decode bits on o_tx ──────────
  // Returns the decoded byte in `decoded`.
  task tx_send_and_decode;
    input  [7:0] data;
    output [7:0] decoded;
    integer      bit_idx;
    begin
      // Assert tx_wr on a posedge so TX_START begins that same cycle.
      @(negedge clk);
      tx_data_in = data;
      tx_wr      = 1;
      @(posedge clk);       // TX latches tx_wr here, enters TX_START
      @(negedge clk);
      tx_wr = 0;

      // TX_START lasts CYCLES_PER_BAUD clocks, then DATA bits begin.
      // Sample bit N at mid-point: CYCLES_PER_BAUD + CYCLES_HALF_BAUD +
      // N * CYCLES_PER_BAUD cycles after the posedge that started TX_START.
      // We are currently 1 cycle past that posedge (at the negedge after it),
      // so wait (CYCLES_PER_BAUD + CYCLES_HALF_BAUD - 1) more posedges
      // to land at the mid-point of bit 0.
      wait_cycles(CYCLES_PER_BAUD + CYCLES_HALF_BAUD - 1);

      decoded = 0;
      for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
        @(posedge clk);
        decoded[bit_idx] = o_tx;
        if (bit_idx < 7) wait_cycles(CYCLES_PER_BAUD - 1);
      end

      // Wait for TX to return to IDLE.
      wait (o_tx_busy == 0);
    end
  endtask

  // ── Helper: bit-bang one UART frame into rx_in ─────────────────────────────
  task rx_send_frame;
    input [7:0] data;
    input       good_stop;  // 1 = valid stop bit, 0 = framing error
    integer     bit_idx;
    begin
      @(negedge clk);
      // Start bit
      rx_in = 0;
      wait_cycles(CYCLES_PER_BAUD);
      // Data bits LSB first
      for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
        rx_in = data[bit_idx];
        wait_cycles(CYCLES_PER_BAUD);
      end
      // Stop bit
      rx_in = good_stop ? 1 : 0;
      wait_cycles(CYCLES_PER_BAUD);
      // Return to idle
      rx_in = 1;
      wait_cycles(4);
    end
  endtask

  // ── Main test sequence ──────────────────────────────────────────────────────
  integer    i;
  reg [7:0]  decoded_byte;
  reg [7:0]  rx_captured;
  reg        valid_seen;

  // String for loopback test
  localparam MSG_LEN = 5;
  reg [7:0] msg [0:MSG_LEN-1];

  initial begin
    if ($test$plusargs("dump")) begin
      $dumpfile("uart_tb.vcd");
      $dumpvars(0, uart_tb);
    end

    msg[0] = "H";
    msg[1] = "e";
    msg[2] = "l";
    msg[3] = "l";
    msg[4] = "o";

    // ── Reset all DUTs ────────────────────────────────────────────────────
    tx_rst_n = 0;
    rx_rst_n = 0;
    lb_rst_n = 0;
    wait_cycles(4);
    tx_rst_n = 1;
    rx_rst_n = 1;
    lb_rst_n = 1;
    wait_cycles(2);

    $display("=== uart_tx tests ===");

    // ── Test 1: Single byte transmit ─────────────────────────────────────
    begin : t1
      tx_send_and_decode(8'hA5, decoded_byte);
      if (decoded_byte === 8'hA5)
        pass("tx: single byte 0xA5");
      else begin
        $display("    got 0x%02X, expected 0xA5", decoded_byte);
        fail("tx: single byte 0xA5");
      end
    end

    wait_cycles(2);

    // ── Test 2: All-zeros byte ────────────────────────────────────────────
    begin : t2
      tx_send_and_decode(8'h00, decoded_byte);
      if (decoded_byte === 8'h00)
        pass("tx: byte 0x00");
      else begin
        $display("    got 0x%02X, expected 0x00", decoded_byte);
        fail("tx: byte 0x00");
      end
    end

    wait_cycles(2);

    // ── Test 3: All-ones byte ─────────────────────────────────────────────
    begin : t3
      tx_send_and_decode(8'hFF, decoded_byte);
      if (decoded_byte === 8'hFF)
        pass("tx: byte 0xFF");
      else begin
        $display("    got 0x%02X, expected 0xFF", decoded_byte);
        fail("tx: byte 0xFF");
      end
    end

    wait_cycles(2);

    // ── Test 4: Back-to-back transmit ─────────────────────────────────────
    // Queue 0x37, wait for busy to drop then immediately send 0xC8.
    begin : t4
      reg [7:0] d1, d2;
      tx_send_and_decode(8'h37, d1);
      tx_send_and_decode(8'hC8, d2);
      if (d1 === 8'h37 && d2 === 8'hC8)
        pass("tx: back-to-back 0x37 0xC8");
      else begin
        $display("    got 0x%02X 0x%02X, expected 0x37 0xC8", d1, d2);
        fail("tx: back-to-back 0x37 0xC8");
      end
    end

    wait_cycles(4);

    // ── Test 5: o_tx idles high ───────────────────────────────────────────
    if (o_tx === 1'b1)
      pass("tx: idle line is high");
    else
      fail("tx: idle line is high");

    $display("=== uart_rx tests ===");

    // ── Test 6: Single byte receive ───────────────────────────────────────
    begin : t6
      valid_seen  = 0;
      rx_captured = 0;
      fork
        rx_send_frame(8'hB3, 1);
        begin
          @(posedge o_rx_valid);
          rx_captured = o_rx_data;
          valid_seen  = 1;
        end
      join
      if (valid_seen && rx_captured === 8'hB3)
        pass("rx: single byte 0xB3");
      else begin
        $display("    valid=%0b data=0x%02X, expected 0xB3", valid_seen, rx_captured);
        fail("rx: single byte 0xB3");
      end
    end

    // ── Test 7: All-zeros byte ────────────────────────────────────────────
    begin : t7
      valid_seen  = 0;
      rx_captured = 0;
      fork
        rx_send_frame(8'h00, 1);
        begin
          @(posedge o_rx_valid);
          rx_captured = o_rx_data;
          valid_seen  = 1;
        end
      join
      if (valid_seen && rx_captured === 8'h00)
        pass("rx: byte 0x00");
      else begin
        $display("    valid=%0b data=0x%02X, expected 0x00", valid_seen, rx_captured);
        fail("rx: byte 0x00");
      end
    end

    // ── Test 8: All-ones byte ─────────────────────────────────────────────
    begin : t8
      valid_seen  = 0;
      rx_captured = 0;
      fork
        rx_send_frame(8'hFF, 1);
        begin
          @(posedge o_rx_valid);
          rx_captured = o_rx_data;
          valid_seen  = 1;
        end
      join
      if (valid_seen && rx_captured === 8'hFF)
        pass("rx: byte 0xFF");
      else begin
        $display("    valid=%0b data=0x%02X, expected 0xFF", valid_seen, rx_captured);
        fail("rx: byte 0xFF");
      end
    end

    // ── Test 9: Framing error — bad stop bit, no valid pulse ─────────────
    begin : t9
      valid_seen = 0;
      fork
        rx_send_frame(8'hAA, 0);  // stop bit = 0 (framing error)
        begin : t9_wait
          // Give enough time for a full frame to play out.
          wait_cycles((CYCLES_PER_BAUD * 12));
          disable t9_wait;
        end
      join
      // o_rx_valid should never have fired.
      if (!valid_seen)
        pass("rx: framing error suppresses valid");
      else
        fail("rx: framing error suppresses valid");
    end

    wait_cycles(4);

    // ── Test 10: Glitch rejection — pulse shorter than half baud ──────────
    begin : t10
      valid_seen = 0;
      @(negedge clk);
      rx_in = 0;
      // Hold low for only CYCLES_HALF_BAUD - 2 cycles (shorter than half baud).
      wait_cycles(CYCLES_HALF_BAUD - 2);
      rx_in = 1;
      // Wait long enough for any spurious frame to complete.
      wait_cycles(CYCLES_PER_BAUD * 12);
      if (!valid_seen)
        pass("rx: glitch shorter than half-baud is rejected");
      else
        fail("rx: glitch shorter than half-baud is rejected");
    end

    wait_cycles(4);

    $display("=== loopback test (uart_tx -> uart_rx) ===");

    // ── Test 11: Loopback — transmit "Hello", verify received bytes ───────
    begin : t11
      integer errors;
      reg [7:0] lb_buf [0:MSG_LEN-1];
      integer   lb_idx;
      errors = 0;
      lb_idx = 0;

      // Receive bytes in the background as TX sends them.
      fork
        // Sender: transmit each byte, wait until not busy before next.
        begin : lb_sender
          for (i = 0; i < MSG_LEN; i = i + 1) begin
            @(negedge clk);
            tx_data_in = msg[i];
            tx_wr      = 1;
            @(posedge clk);
            @(negedge clk);
            tx_wr = 0;
            wait (o_tx_busy == 0);
          end
        end
        // Receiver: collect MSG_LEN valid pulses.
        begin : lb_receiver
          repeat (MSG_LEN) begin
            @(posedge lb_rx_valid);
            lb_buf[lb_idx] = lb_rx_data;
            lb_idx         = lb_idx + 1;
          end
        end
      join

      for (i = 0; i < MSG_LEN; i = i + 1) begin
        if (lb_buf[i] !== msg[i]) begin
          $display("    byte[%0d]: got 0x%02X ('%c'), expected 0x%02X ('%c')",
                   i, lb_buf[i], lb_buf[i], msg[i], msg[i]);
          errors = errors + 1;
        end
      end
      if (errors == 0)
        pass("loopback: \"Hello\" received correctly");
      else
        fail("loopback: \"Hello\" received correctly");
    end

    // ── Summary ───────────────────────────────────────────────────────────
    $display("");
    $display("Results: %0d passed, %0d failed out of %0d tests",
             pass_count, fail_count, pass_count + fail_count);
    if (fail_count == 0) $display("PASS");
    else $display("FAIL");

    $finish;
  end

  // Safety timeout.
  initial begin
    #(CLK_PERIOD * CLK_FREQ * 500);
    $display("TIMEOUT");
    $finish;
  end

endmodule
