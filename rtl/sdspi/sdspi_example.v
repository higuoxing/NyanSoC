`default_nettype none
`timescale 1 ns / 1 ps

// Example usage of sdspi on Tang Nano 20K (27 MHz, LVCMOS33).
//
// After the SD card initialises, this module reads block 0 (the MBR),
// then writes the same 512 bytes back to block 1.  Two LEDs report
// the outcome:
//   o_led_ok   – block read and write both completed without error
//   o_led_err  – an error occurred during init, read, or write
//
// SD card SPI wiring (Tang Nano 20K):
//   o_spi_clk  → TF_CLK  (pin 83)
//   o_spi_mosi → TF_CMD  (pin 82)
//   i_spi_miso → TF_D0   (pin 84)
//   o_spi_cs_n → TF_D3   (pin 81)

module sdspi_example (
    input  wire       i_clk,     // 27 MHz system clock
    input  wire       i_rst_n,   // active-low reset

    // Status LEDs (active-high)
    output reg        o_led_ok,
    output reg        o_led_err,

    // SPI interface (connect directly to TF card slot)
    output wire       o_spi_clk,
    output wire       o_spi_mosi,
    input  wire       i_spi_miso,
    output wire       o_spi_cs_n
);

  // ── sdspi instance ────────────────────────────────────────────────────────
  wire        init_done;
  wire        busy;
  wire        sd_err;

  reg         sd_rd;
  reg         sd_wr;
  reg  [31:0] sd_addr;

  wire        rd_valid;
  wire [ 7:0] rd_data;
  reg         rd_ack;

  reg  [ 7:0] wr_data;
  reg         wr_valid;
  wire        wr_ready;

  sdspi #(
      .CLK_FREQ_HZ   (27_000_000),
      .SPI_CLK_DIV   (2),         // 27 MHz / 4 = 6.75 MHz SPI clock
      .SPI_CLK_DIV_INIT(68)       // 27 MHz / 136 ≈ 199 kHz during init
  ) u_sdspi (
      .i_clk      (i_clk),
      .i_rst_n    (i_rst_n),
      .o_init_done(init_done),
      .o_busy     (busy),
      .o_err      (sd_err),
      .i_rd       (sd_rd),
      .i_addr     (sd_addr),
      .o_rd_valid (rd_valid),
      .o_rd_data  (rd_data),
      .i_rd_ack   (rd_ack),
      .i_wr       (sd_wr),
      .i_wr_data  (wr_data),
      .i_wr_valid (wr_valid),
      .o_wr_ready (wr_ready),
      .o_spi_cs_n (o_spi_cs_n),
      .o_spi_clk  (o_spi_clk),
      .o_spi_mosi (o_spi_mosi),
      .i_spi_miso (i_spi_miso)
  );

  // ── 512-byte block buffer ─────────────────────────────────────────────────
  reg [ 7:0] blk_buf [0:511];
  reg [ 9:0] buf_rd_ptr;   // read pointer into blk_buf (0..511)
  reg [ 9:0] buf_wr_ptr;   // write pointer into blk_buf (0..511)

  // ── Example FSM ───────────────────────────────────────────────────────────
  localparam [2:0]
    S_WAIT_INIT  = 3'd0,  // wait for SD card initialisation
    S_READ_START = 3'd1,  // issue block 0 read
    S_READ_DATA  = 3'd2,  // drain read FIFO into blk_buf
    S_READ_WAIT  = 3'd3,  // wait for busy to clear
    S_WRITE_FILL = 3'd4,  // push blk_buf into write FIFO
    S_WRITE_START= 3'd5,  // issue block 1 write
    S_WRITE_WAIT = 3'd6,  // wait for busy to clear
    S_DONE       = 3'd7;

  reg [2:0] state;

  always @(posedge i_clk) begin
    if (!i_rst_n) begin
      state      <= S_WAIT_INIT;
      sd_rd      <= 1'b0;
      sd_wr      <= 1'b0;
      sd_addr    <= 32'd0;
      rd_ack     <= 1'b0;
      wr_data    <= 8'd0;
      wr_valid   <= 1'b0;
      buf_rd_ptr <= 10'd0;
      buf_wr_ptr <= 10'd0;
      o_led_ok   <= 1'b0;
      o_led_err  <= 1'b0;
    end else begin
      // Default: deassert single-cycle strobes.
      sd_rd    <= 1'b0;
      sd_wr    <= 1'b0;
      rd_ack   <= 1'b0;
      wr_valid <= 1'b0;

      if (sd_err) begin
        o_led_err <= 1'b1;
        state     <= S_DONE;
      end else begin
        case (state)

          S_WAIT_INIT: begin
            if (init_done && !busy)
              state <= S_READ_START;
          end

          S_READ_START: begin
            sd_addr <= 32'd0;   // block 0 (MBR)
            sd_rd   <= 1'b1;
            buf_wr_ptr <= 10'd0;
            state   <= S_READ_DATA;
          end

          S_READ_DATA: begin
            // Drain bytes from the controller FIFO into blk_buf.
            if (rd_valid && buf_wr_ptr < 10'd512) begin
              blk_buf[buf_wr_ptr[8:0]] <= rd_data;
              buf_wr_ptr               <= buf_wr_ptr + 1'b1;
              rd_ack                   <= 1'b1;
            end
            if (buf_wr_ptr == 10'd512) begin
              state <= S_READ_WAIT;
            end
          end

          S_READ_WAIT: begin
            if (!busy) begin
              buf_rd_ptr <= 10'd0;
              state      <= S_WRITE_START;
            end
          end

          S_WRITE_START: begin
            sd_addr <= 32'd1;   // block 1
            sd_wr   <= 1'b1;
            state   <= S_WRITE_FILL;
          end

          S_WRITE_FILL: begin
            // Push bytes from blk_buf into the write FIFO.
            if (wr_ready && buf_rd_ptr < 10'd512) begin
              wr_data    <= blk_buf[buf_rd_ptr[8:0]];
              wr_valid   <= 1'b1;
              buf_rd_ptr <= buf_rd_ptr + 1'b1;
            end
            if (buf_rd_ptr == 10'd512) begin
              state <= S_WRITE_WAIT;
            end
          end

          S_WRITE_WAIT: begin
            if (!busy) begin
              o_led_ok <= 1'b1;
              state    <= S_DONE;
            end
          end

          S_DONE: begin
            // Latch LEDs forever.
          end

          default: state <= S_WAIT_INIT;
        endcase
      end
    end
  end

endmodule  // sdspi_example
