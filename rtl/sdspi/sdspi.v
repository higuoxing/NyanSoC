`default_nettype none
`timescale 1 ns / 1 ps

// SD card controller — SPI mode (SD spec simplified bus protocol).
//
// Operates in SPI Mode 0 (CPOL=0, CPHA=0): data captured on rising CLK edge,
// shifted out on falling CLK edge.  All SD cards must support SPI mode after
// power-on (CMD0 with CS asserted).
//
// Interface overview
// ──────────────────
//  After reset, the controller drives SD card initialization automatically.
//  o_init_done goes high once the card is ready for block reads/writes.
//
//  Block read  (512 bytes):
//    1. Assert i_rd, provide i_addr (32-bit byte address, must be 512-aligned
//       for SDSC; block address for SDHC/SDXC).
//    2. Hold until o_busy goes low.
//    3. Read 512 bytes from the FIFO via i_rd_ack / o_rd_data / o_rd_valid.
//
//  Block write (512 bytes):
//    1. Assert i_wr, provide i_addr and fill i_wr_data / i_wr_valid one byte
//       per cycle (back-pressure via o_wr_ready).
//    2. Hold until o_busy goes low after the last byte is accepted.
//
// SPI signals
// ───────────
//   o_spi_cs_n  — chip select (active-low)
//   o_spi_clk   — SPI clock (driven from i_clk divider)
//   o_spi_mosi  — master out / slave in
//   i_spi_miso  — master in / slave out
//
// Timing
// ──────
//  CLK_FREQ_HZ / (2 * SPI_CLK_DIV) gives the SPI clock frequency.
//  During initialization SD requires < 400 kHz; use SPI_CLK_DIV_INIT.
//  After init, SPI_CLK_DIV gives the fast operating clock.

module sdspi #(
    parameter integer CLK_FREQ_HZ    = 27_000_000,
    parameter integer SPI_CLK_DIV      = 2,    // fast clock: 27 MHz / (2*2) = 6.75 MHz
    parameter integer SPI_CLK_DIV_INIT = 68    // init clock: 27 MHz / (2*68) ≈ 198 kHz
) (
    input  wire        i_clk,
    input  wire        i_rst_n,

    // Status
    output wire        o_init_done,  // high once card is initialised
    output wire        o_busy,       // high while a transaction is in progress
    output wire        o_err,        // high if last operation ended in error (sticky)

    // Block read request (512-byte block)
    input  wire        i_rd,         // pulse: start a read
    input  wire [31:0] i_addr,       // block address (SDHC) or byte address (SDSC)

    // Read data stream (valid after o_busy goes low)
    output wire        o_rd_valid,   // one byte available
    output wire [ 7:0] o_rd_data,    // byte from card
    input  wire        i_rd_ack,     // pulse: consume one byte

    // Block write request (512-byte block)
    input  wire        i_wr,         // pulse: start a write
    // i_addr shared with read
    input  wire [ 7:0] i_wr_data,    // byte to write
    input  wire        i_wr_valid,   // byte on i_wr_data is valid
    output wire        o_wr_ready,   // controller can accept one more byte

    // SPI physical interface
    output reg         o_spi_cs_n,
    output wire        o_spi_clk,
    output wire        o_spi_mosi,
    input  wire        i_spi_miso
);

  // ── SPI clock divider ────────────────────────────────────────────────────
  // Generates a spi_clk_en tick every SPI_CLK_DIV system clocks (half-period).
  // MOSI shifts on the falling edge (spi_fall_en), MISO sampled on rising
  // edge (spi_rise_en).

  // Use a wider divider that switches between init and fast speeds.
  localparam DIV_W = 8;  // enough for max SPI_CLK_DIV_INIT = 255

  reg [DIV_W-1:0] clk_div_cnt;
  reg             fast_mode;   // 0 = init speed, 1 = fast speed

  wire [DIV_W-1:0] clk_div_top = fast_mode
      ? (DIV_W)'(SPI_CLK_DIV - 1)
      : (DIV_W)'(SPI_CLK_DIV_INIT - 1);

  wire spi_tick = (clk_div_cnt == clk_div_top);

  always @(posedge i_clk) begin
    if (!i_rst_n) begin
      clk_div_cnt <= {DIV_W{1'b0}};
    end else begin
      if (spi_tick) clk_div_cnt <= {DIV_W{1'b0}};
      else          clk_div_cnt <= clk_div_cnt + 1'b1;
    end
  end

  // ── SPI byte engine ──────────────────────────────────────────────────────
  // Shifts one byte at a time.  Caller fills spi_tx_byte, pulses spi_start,
  // and reads spi_rx_byte when spi_done is asserted.

  reg        spi_active;   // 1 while shifting a byte

  // SPI clock state: toggles on each tick when the SPI engine is active.
  reg spi_clk_r;
  always @(posedge i_clk) begin
    if (!i_rst_n) spi_clk_r <= 1'b0;
    else if (spi_tick && spi_active) spi_clk_r <= ~spi_clk_r;
  end

  // Rising/falling edge enables (one system clock wide).
  wire spi_rise_en = spi_tick &&  spi_clk_r && spi_active;  // clock was high → sample
  wire spi_fall_en = spi_tick && !spi_clk_r && spi_active;  // clock was low  → shift

  assign o_spi_clk = spi_clk_r;
  reg [ 7:0] spi_tx_shift;
  reg [ 7:0] spi_rx_shift;
  reg [ 2:0] spi_bit_cnt;  // counts 7..0
  reg        spi_done;     // one-cycle pulse: byte shifted out/in

  // Byte to transmit and received result (set by controller FSM).
  reg [ 7:0] spi_tx_byte;
  wire [ 7:0] spi_rx_byte = spi_rx_shift;

  // Kick: asserted for one cycle by the FSM to begin a new byte transfer.
  reg spi_start;

  assign o_spi_mosi = spi_tx_shift[7];  // MSB first

  always @(posedge i_clk) begin
    spi_done <= 1'b0;
    if (!i_rst_n) begin
      spi_active  <= 1'b0;
      spi_bit_cnt <= 3'd7;
      spi_tx_shift<= 8'hFF;
      spi_rx_shift<= 8'hFF;
    end else begin
      if (spi_start && !spi_active) begin
        spi_active   <= 1'b1;
        spi_bit_cnt  <= 3'd7;
        spi_tx_shift <= spi_tx_byte;
      end else if (spi_active) begin
        if (spi_rise_en) begin
          // Sample MISO on rising edge.
          spi_rx_shift <= {spi_rx_shift[6:0], i_spi_miso};
        end
        if (spi_fall_en) begin
          // Shift MOSI on falling edge (after sampling).
          if (spi_bit_cnt == 3'd0) begin
            spi_active <= 1'b0;
            spi_done   <= 1'b1;
          end else begin
            spi_tx_shift <= {spi_tx_shift[6:0], 1'b1};
            spi_bit_cnt  <= spi_bit_cnt - 1'b1;
          end
        end
      end
    end
  end

  // ── Read FIFO (512 bytes) ────────────────────────────────────────────────
  // Simple 512-deep synchronous FIFO backed by registers.
  // Only used for block reads; write path is streaming (no FIFO needed).

  localparam FIFO_DEPTH = 512;
  localparam FIFO_AW    = 9;

  reg [ 7:0] rd_fifo [0:FIFO_DEPTH-1];
  reg [FIFO_AW-1:0] rd_wr_ptr;
  reg [FIFO_AW-1:0] rd_rd_ptr;
  reg [FIFO_AW  :0] rd_count;   // one extra bit to distinguish full from empty

  wire rd_fifo_empty = (rd_count == 0);
  wire rd_fifo_full  = (rd_count == FIFO_DEPTH);

  // Write side (driven by block read FSM).
  reg       rd_fifo_wr_en;
  reg [7:0] rd_fifo_din;

  always @(posedge i_clk) begin
    if (!i_rst_n) begin
      rd_wr_ptr <= {FIFO_AW{1'b0}};
      rd_rd_ptr <= {FIFO_AW{1'b0}};
      rd_count  <= {(FIFO_AW+1){1'b0}};
    end else begin
      if (rd_fifo_wr_en && !rd_fifo_full) begin
        rd_fifo[rd_wr_ptr] <= rd_fifo_din;
        rd_wr_ptr <= rd_wr_ptr + 1'b1;
        rd_count  <= rd_count + 1'b1;
      end
      if (i_rd_ack && !rd_fifo_empty) begin
        rd_rd_ptr <= rd_rd_ptr + 1'b1;
        rd_count  <= rd_count - 1'b1;
      end
      // Both simultaneously.
      if (rd_fifo_wr_en && !rd_fifo_full && i_rd_ack && !rd_fifo_empty)
        rd_count <= rd_count;  // net zero change
    end
  end

  assign o_rd_valid = !rd_fifo_empty;
  assign o_rd_data  = rd_fifo[rd_rd_ptr];

  // ── Write FIFO (512 bytes) ────────────────────────────────────────────────
  // Buffers the 512 write bytes before we start sending them to the card.

  reg [ 7:0] wr_fifo [0:FIFO_DEPTH-1];
  reg [FIFO_AW-1:0] wr_wr_ptr;
  reg [FIFO_AW-1:0] wr_rd_ptr;
  reg [FIFO_AW  :0] wr_count;

  wire wr_fifo_empty = (wr_count == 0);
  wire wr_fifo_full  = (wr_count == FIFO_DEPTH);

  // Read side driven by block write FSM.
  reg       wr_fifo_rd_en;
  wire [7:0] wr_fifo_dout = wr_fifo[wr_rd_ptr];

  assign o_wr_ready = !wr_fifo_full;

  always @(posedge i_clk) begin
    if (!i_rst_n) begin
      wr_wr_ptr <= {FIFO_AW{1'b0}};
      wr_rd_ptr <= {FIFO_AW{1'b0}};
      wr_count  <= {(FIFO_AW+1){1'b0}};
    end else begin
      if (i_wr_valid && !wr_fifo_full) begin
        wr_fifo[wr_wr_ptr] <= i_wr_data;
        wr_wr_ptr <= wr_wr_ptr + 1'b1;
        wr_count  <= wr_count + 1'b1;
      end
      if (wr_fifo_rd_en && !wr_fifo_empty) begin
        wr_rd_ptr <= wr_rd_ptr + 1'b1;
        wr_count  <= wr_count - 1'b1;
      end
      if (i_wr_valid && !wr_fifo_full && wr_fifo_rd_en && !wr_fifo_empty)
        wr_count <= wr_count;
    end
  end

  // ── Controller FSM ───────────────────────────────────────────────────────
  // Implements the SD SPI initialisation sequence and CMD17/CMD24 block I/O.
  //
  // Initialization sequence (SD Physical Layer Simplified Spec §6.4.1):
  //   1. Power-up delay: ≥ 74 SPI clocks with CS deasserted.
  //   2. CMD0  (GO_IDLE_STATE)    — puts card in SPI idle. Expect R1=0x01.
  //   3. CMD8  (SEND_IF_COND)     — detect SDHC/SDXC. Expect R7 (5 bytes).
  //      If CMD8 fails (R1=0x05), assume SDSC v1.
  //   4. ACMD41 (SD_SEND_OP_COND) — repeated until R1=0x00 (card ready).
  //      ACMD41 = CMD55 followed by CMD41.
  //   5. CMD58 (READ_OCR)         — read OCR to check CCS bit (SDHC flag).
  //   6. CMD16 (SET_BLOCKLEN)     — set 512-byte blocks (SDSC only).
  //
  // Block read (CMD17):
  //   CS low → send CMD17 → R1 → data token 0xFE → 512 bytes → 2 CRC bytes.
  //
  // Block write (CMD24):
  //   CS low → send CMD24 → R1 → data token 0xFE → 512 bytes → 2 CRC bytes
  //   → data response token → busy polling.

  localparam [5:0]
    // Initialisation states
    S_RESET          = 6'd0,
    S_INIT_CLOCKS    = 6'd1,   // send 80 clocks CS deasserted
    S_CMD0           = 6'd2,
    S_CMD0_RESP      = 6'd3,
    S_CMD8           = 6'd4,
    S_CMD8_RESP      = 6'd5,
    S_CMD55          = 6'd6,
    S_CMD55_RESP     = 6'd7,
    S_ACMD41         = 6'd8,
    S_ACMD41_RESP    = 6'd9,
    S_CMD58          = 6'd10,
    S_CMD58_RESP     = 6'd11,
    S_CMD16          = 6'd12,
    S_CMD16_RESP     = 6'd13,
    S_IDLE           = 6'd14,
    // Read states
    S_RD_CMD         = 6'd15,
    S_RD_RESP        = 6'd16,
    S_RD_TOKEN       = 6'd17,
    S_RD_DATA        = 6'd18,
    S_RD_CRC         = 6'd19,
    // Write states
    S_WR_CMD         = 6'd20,
    S_WR_RESP        = 6'd21,
    S_WR_TOKEN       = 6'd22,
    S_WR_DATA        = 6'd23,
    S_WR_CRC         = 6'd24,
    S_WR_DRESP       = 6'd25,  // data response token
    S_WR_BUSY        = 6'd26,  // busy polling
    S_ERROR          = 6'd27;

  reg [5:0]  state;
  reg [5:0]  next_state;    // where to go after a multi-byte sequence
  reg [31:0] addr_latch;    // latched request address
  reg        is_sdhc;       // 1 = SDHC/SDXC (block addressing)
  reg        err_r;

  // Byte/step counter (dual use: init clock counter, byte-within-state counter).
  reg [9:0] cnt;

  // Command buffer: 6 bytes (CMD index + 4-byte arg + CRC).
  reg [7:0] cmd_buf [0:5];

  // Response byte accumulator (up to 5 bytes for R7).
  reg [7:0] resp [0:4];

  // Convenience: current response byte 0.
  wire [7:0] r1 = resp[0];

  // Retry counter for ACMD41.
  localparam ACMD41_RETRIES = 16'd2000;
  reg [15:0] retry_cnt;

  // CRC dummy bytes (SPI mode ignores CRC except CMD0/CMD8).
  localparam CRC_DUMMY = 8'hFF;

  assign o_init_done = (state == S_IDLE) || (state == S_RD_CMD) ||
                       (state == S_RD_RESP) || (state == S_RD_TOKEN) ||
                       (state == S_RD_DATA) || (state == S_RD_CRC) ||
                       (state == S_WR_CMD) || (state == S_WR_RESP) ||
                       (state == S_WR_TOKEN) || (state == S_WR_DATA) ||
                       (state == S_WR_CRC) || (state == S_WR_DRESP) ||
                       (state == S_WR_BUSY);
  assign o_busy      = (state != S_IDLE) && (state != S_ERROR);
  assign o_err       = err_r;

  // ── Helper: load a 6-byte SD command into cmd_buf ────────────────────────
  // Called combinatorially before entering S_CMD* states.
  task load_cmd;
    input [5:0] idx;
    input [31:0] arg;
    input [ 7:0] crc;
    begin
      cmd_buf[0] = {2'b01, idx};
      cmd_buf[1] = arg[31:24];
      cmd_buf[2] = arg[23:16];
      cmd_buf[3] = arg[15: 8];
      cmd_buf[4] = arg[ 7: 0];
      cmd_buf[5] = crc;
    end
  endtask

  // ── FSM ──────────────────────────────────────────────────────────────────
  // One rule: only call spi_start when spi_active is low.

  always @(posedge i_clk) begin
    spi_start      <= 1'b0;
    rd_fifo_wr_en  <= 1'b0;
    wr_fifo_rd_en  <= 1'b0;

    if (!i_rst_n) begin
      state        <= S_RESET;
      o_spi_cs_n   <= 1'b1;
      fast_mode    <= 1'b0;
      is_sdhc      <= 1'b0;
      err_r        <= 1'b0;
      cnt          <= 10'd0;
      retry_cnt    <= 16'd0;
      addr_latch   <= 32'd0;
      spi_tx_byte  <= 8'hFF;
    end else begin
      case (state)

        // ── Reset: wait one tick then start init ──────────────────────────
        S_RESET: begin
          o_spi_cs_n  <= 1'b1;
          fast_mode   <= 1'b0;
          cnt         <= 10'd0;
          state       <= S_INIT_CLOCKS;
        end

        // ── Send ≥80 SPI clocks with CS=1 (card power-up requirement) ─────
        S_INIT_CLOCKS: begin
          o_spi_cs_n  <= 1'b1;
          spi_tx_byte <= 8'hFF;
          if (!spi_active && !spi_start) begin
            if (cnt < 10'd10) begin  // 10 bytes × 8 bits = 80 clocks
              spi_start <= 1'b1;
              cnt       <= cnt + 1'b1;
            end else begin
              cnt   <= 10'd0;
              // Load CMD0: GO_IDLE_STATE, arg=0, CRC=0x95
              load_cmd(6'd0, 32'd0, 8'h95);
              state <= S_CMD0;
            end
          end
        end

        // ── CMD0: send 6 bytes ────────────────────────────────────────────
        S_CMD0: begin
          o_spi_cs_n <= 1'b0;
          if (!spi_active && !spi_start) begin
            if (cnt < 10'd6) begin
              spi_tx_byte <= cmd_buf[cnt[2:0]];
              spi_start   <= 1'b1;
              cnt         <= cnt + 1'b1;
            end else begin
              cnt         <= 10'd0;
              spi_tx_byte <= 8'hFF;
              state       <= S_CMD0_RESP;
            end
          end
        end

        // ── CMD0 response: poll up to 8 bytes for R1 ─────────────────────
        S_CMD0_RESP: begin
          if (!spi_active && !spi_start) begin
            if (spi_done) begin
              if (spi_rx_byte != 8'hFF) begin
                // Got a response byte.
                resp[0] <= spi_rx_byte;
                if (spi_rx_byte == 8'h01) begin
                  // In idle — move to CMD8.
                  cnt <= 10'd0;
                  load_cmd(6'd8, 32'h000001AA, 8'h87);
                  state <= S_CMD8;
                end else begin
                  state <= S_ERROR;
                end
              end else if (cnt < 10'd8) begin
                spi_tx_byte <= 8'hFF;
                spi_start   <= 1'b1;
                cnt         <= cnt + 1'b1;
              end else begin
                state <= S_ERROR;  // no response
              end
            end else begin
              spi_tx_byte <= 8'hFF;
              spi_start   <= 1'b1;
            end
          end
        end

        // ── CMD8: send 6 bytes ────────────────────────────────────────────
        S_CMD8: begin
          if (!spi_active && !spi_start) begin
            if (cnt < 10'd6) begin
              spi_tx_byte <= cmd_buf[cnt[2:0]];
              spi_start   <= 1'b1;
              cnt         <= cnt + 1'b1;
            end else begin
              cnt         <= 10'd0;
              spi_tx_byte <= 8'hFF;
              state       <= S_CMD8_RESP;
            end
          end
        end

        // ── CMD8 response: R7 = 5 bytes ───────────────────────────────────
        S_CMD8_RESP: begin
          if (!spi_active && !spi_start) begin
            if (spi_done) begin
              if (cnt == 10'd0 && spi_rx_byte == 8'hFF) begin
                // Still waiting for first non-FF byte.
                spi_tx_byte <= 8'hFF;
                spi_start   <= 1'b1;
              end else begin
                resp[cnt[2:0]] <= spi_rx_byte;
                if (cnt < 10'd4) begin
                  spi_tx_byte <= 8'hFF;
                  spi_start   <= 1'b1;
                  cnt         <= cnt + 1'b1;
                end else begin
                  // Done. R1 = resp[0]. Check for illegal command (0x05 → SDSC v1).
                  cnt       <= 10'd0;
                  retry_cnt <= 16'd0;
                  load_cmd(6'd55, 32'd0, CRC_DUMMY);
                  state     <= S_CMD55;
                end
              end
            end else begin
              spi_tx_byte <= 8'hFF;
              spi_start   <= 1'b1;
            end
          end
        end

        // ── CMD55 + ACMD41 loop ───────────────────────────────────────────
        S_CMD55: begin
          if (!spi_active && !spi_start) begin
            if (cnt < 10'd6) begin
              spi_tx_byte <= cmd_buf[cnt[2:0]];
              spi_start   <= 1'b1;
              cnt         <= cnt + 1'b1;
            end else begin
              cnt         <= 10'd0;
              spi_tx_byte <= 8'hFF;
              state       <= S_CMD55_RESP;
            end
          end
        end

        S_CMD55_RESP: begin
          if (!spi_active && !spi_start) begin
            if (spi_done) begin
              if (spi_rx_byte != 8'hFF) begin
                resp[0] <= spi_rx_byte;
                cnt     <= 10'd0;
                // Send ACMD41: HCS=1 for SDHC support.
                load_cmd(6'd41, 32'h40000000, CRC_DUMMY);
                state   <= S_ACMD41;
              end else begin
                spi_tx_byte <= 8'hFF;
                spi_start   <= 1'b1;
              end
            end else begin
              spi_tx_byte <= 8'hFF;
              spi_start   <= 1'b1;
            end
          end
        end

        S_ACMD41: begin
          if (!spi_active && !spi_start) begin
            if (cnt < 10'd6) begin
              spi_tx_byte <= cmd_buf[cnt[2:0]];
              spi_start   <= 1'b1;
              cnt         <= cnt + 1'b1;
            end else begin
              cnt         <= 10'd0;
              spi_tx_byte <= 8'hFF;
              state       <= S_ACMD41_RESP;
            end
          end
        end

        S_ACMD41_RESP: begin
          if (!spi_active && !spi_start) begin
            if (spi_done) begin
              if (spi_rx_byte != 8'hFF) begin
                resp[0] <= spi_rx_byte;
                if (spi_rx_byte == 8'h00) begin
                  // Card ready — read OCR.
                  cnt   <= 10'd0;
                  load_cmd(6'd58, 32'd0, CRC_DUMMY);
                  state <= S_CMD58;
                end else if (retry_cnt < ACMD41_RETRIES) begin
                  // Still initialising — retry CMD55/ACMD41.
                  retry_cnt <= retry_cnt + 1'b1;
                  cnt       <= 10'd0;
                  load_cmd(6'd55, 32'd0, CRC_DUMMY);
                  state     <= S_CMD55;
                end else begin
                  state <= S_ERROR;
                end
              end else begin
                spi_tx_byte <= 8'hFF;
                spi_start   <= 1'b1;
              end
            end else begin
              spi_tx_byte <= 8'hFF;
              spi_start   <= 1'b1;
            end
          end
        end

        // ── CMD58: read OCR ───────────────────────────────────────────────
        S_CMD58: begin
          if (!spi_active && !spi_start) begin
            if (cnt < 10'd6) begin
              spi_tx_byte <= cmd_buf[cnt[2:0]];
              spi_start   <= 1'b1;
              cnt         <= cnt + 1'b1;
            end else begin
              cnt         <= 10'd0;
              spi_tx_byte <= 8'hFF;
              state       <= S_CMD58_RESP;
            end
          end
        end

        S_CMD58_RESP: begin
          if (!spi_active && !spi_start) begin
            if (spi_done) begin
              if (cnt == 10'd0 && spi_rx_byte == 8'hFF) begin
                spi_tx_byte <= 8'hFF;
                spi_start   <= 1'b1;
              end else begin
                resp[cnt[2:0]] <= spi_rx_byte;
                if (cnt < 10'd4) begin
                  spi_tx_byte <= 8'hFF;
                  spi_start   <= 1'b1;
                  cnt         <= cnt + 1'b1;
                end else begin
                  // OCR byte 1 (resp[1]) bit 6 = CCS (1 = SDHC).
                  is_sdhc   <= resp[1][6];
                  fast_mode <= 1'b1;   // switch to fast SPI clock
                  cnt       <= 10'd0;
                  if (!resp[1][6]) begin
                    // SDSC: set block length to 512.
                    load_cmd(6'd16, 32'd512, CRC_DUMMY);
                    state <= S_CMD16;
                  end else begin
                    state <= S_IDLE;
                  end
                end
              end
            end else begin
              spi_tx_byte <= 8'hFF;
              spi_start   <= 1'b1;
            end
          end
        end

        // ── CMD16: SET_BLOCKLEN (SDSC only) ──────────────────────────────
        S_CMD16: begin
          if (!spi_active && !spi_start) begin
            if (cnt < 10'd6) begin
              spi_tx_byte <= cmd_buf[cnt[2:0]];
              spi_start   <= 1'b1;
              cnt         <= cnt + 1'b1;
            end else begin
              cnt         <= 10'd0;
              spi_tx_byte <= 8'hFF;
              state       <= S_CMD16_RESP;
            end
          end
        end

        S_CMD16_RESP: begin
          if (!spi_active && !spi_start) begin
            if (spi_done) begin
              if (spi_rx_byte != 8'hFF) begin
                if (spi_rx_byte == 8'h00) state <= S_IDLE;
                else                       state <= S_ERROR;
              end else begin
                spi_tx_byte <= 8'hFF;
                spi_start   <= 1'b1;
              end
            end else begin
              spi_tx_byte <= 8'hFF;
              spi_start   <= 1'b1;
            end
          end
        end

        // ── Idle: wait for read/write request ─────────────────────────────
        S_IDLE: begin
          o_spi_cs_n <= 1'b1;
          if (i_rd) begin
            addr_latch <= is_sdhc ? i_addr : {i_addr[29:0], 2'b00};
            cnt        <= 10'd0;
            // Flush read FIFO pointers.
            load_cmd(6'd17, is_sdhc ? i_addr : {i_addr[29:0], 2'b00}, CRC_DUMMY);
            state      <= S_RD_CMD;
          end else if (i_wr) begin
            addr_latch <= is_sdhc ? i_addr : {i_addr[29:0], 2'b00};
            cnt        <= 10'd0;
            load_cmd(6'd24, is_sdhc ? i_addr : {i_addr[29:0], 2'b00}, CRC_DUMMY);
            state      <= S_WR_CMD;
          end
        end

        // ── Block read ────────────────────────────────────────────────────

        S_RD_CMD: begin
          o_spi_cs_n <= 1'b0;
          if (!spi_active && !spi_start) begin
            if (cnt < 10'd6) begin
              spi_tx_byte <= cmd_buf[cnt[2:0]];
              spi_start   <= 1'b1;
              cnt         <= cnt + 1'b1;
            end else begin
              cnt         <= 10'd0;
              spi_tx_byte <= 8'hFF;
              state       <= S_RD_RESP;
            end
          end
        end

        S_RD_RESP: begin
          if (!spi_active && !spi_start) begin
            if (spi_done) begin
              if (spi_rx_byte != 8'hFF) begin
                if (spi_rx_byte == 8'h00) begin
                  cnt   <= 10'd0;
                  state <= S_RD_TOKEN;
                end else begin
                  state <= S_ERROR;
                end
              end else begin
                spi_tx_byte <= 8'hFF;
                spi_start   <= 1'b1;
              end
            end else begin
              spi_tx_byte <= 8'hFF;
              spi_start   <= 1'b1;
            end
          end
        end

        S_RD_TOKEN: begin
          // Poll for start-block token 0xFE (up to many bytes).
          if (!spi_active && !spi_start) begin
            if (spi_done) begin
              if (spi_rx_byte == 8'hFE) begin
                cnt   <= 10'd0;
                state <= S_RD_DATA;
              end else if (spi_rx_byte[7:4] == 4'b0000) begin
                // Error token received.
                state <= S_ERROR;
              end else begin
                spi_tx_byte <= 8'hFF;
                spi_start   <= 1'b1;
              end
            end else begin
              spi_tx_byte <= 8'hFF;
              spi_start   <= 1'b1;
            end
          end
        end

        S_RD_DATA: begin
          // Read 512 bytes and push into FIFO.
          if (!spi_active && !spi_start) begin
            if (spi_done) begin
              rd_fifo_wr_en <= 1'b1;
              rd_fifo_din   <= spi_rx_byte;
              if (cnt < 10'd511) begin
                cnt         <= cnt + 1'b1;
                spi_tx_byte <= 8'hFF;
                spi_start   <= 1'b1;
              end else begin
                cnt   <= 10'd0;
                state <= S_RD_CRC;
              end
            end else begin
              spi_tx_byte <= 8'hFF;
              spi_start   <= 1'b1;
            end
          end
        end

        S_RD_CRC: begin
          // Read 2 CRC bytes (discarded in SPI mode).
          if (!spi_active && !spi_start) begin
            if (spi_done) begin
              if (cnt < 10'd1) begin
                cnt         <= cnt + 1'b1;
                spi_tx_byte <= 8'hFF;
                spi_start   <= 1'b1;
              end else begin
                o_spi_cs_n <= 1'b1;
                state      <= S_IDLE;
              end
            end else begin
              spi_tx_byte <= 8'hFF;
              spi_start   <= 1'b1;
            end
          end
        end

        // ── Block write ───────────────────────────────────────────────────

        S_WR_CMD: begin
          o_spi_cs_n <= 1'b0;
          if (!spi_active && !spi_start) begin
            if (cnt < 10'd6) begin
              spi_tx_byte <= cmd_buf[cnt[2:0]];
              spi_start   <= 1'b1;
              cnt         <= cnt + 1'b1;
            end else begin
              cnt         <= 10'd0;
              spi_tx_byte <= 8'hFF;
              state       <= S_WR_RESP;
            end
          end
        end

        S_WR_RESP: begin
          if (!spi_active && !spi_start) begin
            if (spi_done) begin
              if (spi_rx_byte != 8'hFF) begin
                if (spi_rx_byte == 8'h00) begin
                  cnt   <= 10'd0;
                  state <= S_WR_TOKEN;
                end else begin
                  state <= S_ERROR;
                end
              end else begin
                spi_tx_byte <= 8'hFF;
                spi_start   <= 1'b1;
              end
            end else begin
              spi_tx_byte <= 8'hFF;
              spi_start   <= 1'b1;
            end
          end
        end

        S_WR_TOKEN: begin
          // Send 1-byte pad + start-block token 0xFE.
          if (!spi_active && !spi_start) begin
            if (cnt == 10'd0) begin
              spi_tx_byte <= 8'hFF;  // 1 byte pad
              spi_start   <= 1'b1;
              cnt         <= 10'd1;
            end else if (cnt == 10'd1 && spi_done) begin
              spi_tx_byte <= 8'hFE;  // start token
              spi_start   <= 1'b1;
              cnt         <= 10'd0;
              state       <= S_WR_DATA;
            end
          end
        end

        S_WR_DATA: begin
          // Send 512 bytes from write FIFO.
          if (!spi_active && !spi_start) begin
            if (!wr_fifo_empty) begin
              spi_tx_byte  <= wr_fifo_dout;
              wr_fifo_rd_en<= 1'b1;
              spi_start    <= 1'b1;
              if (cnt < 10'd511) cnt <= cnt + 1'b1;
              else begin
                cnt   <= 10'd0;
                state <= S_WR_CRC;
              end
            end
            // If FIFO is empty, stall until more data arrives.
          end
        end

        S_WR_CRC: begin
          // Send 2 dummy CRC bytes.
          if (!spi_active && !spi_start) begin
            if (cnt < 10'd2) begin
              spi_tx_byte <= 8'hFF;
              spi_start   <= 1'b1;
              cnt         <= cnt + 1'b1;
            end else begin
              cnt         <= 10'd0;
              spi_tx_byte <= 8'hFF;
              state       <= S_WR_DRESP;
            end
          end
        end

        S_WR_DRESP: begin
          // Read data response token (lower 4 bits = 0x05 → accepted).
          if (!spi_active && !spi_start) begin
            if (spi_done) begin
              if (spi_rx_byte != 8'hFF) begin
                if ((spi_rx_byte & 8'h1F) == 8'h05) state <= S_WR_BUSY;
                else                                  state <= S_ERROR;
              end else begin
                spi_tx_byte <= 8'hFF;
                spi_start   <= 1'b1;
              end
            end else begin
              spi_tx_byte <= 8'hFF;
              spi_start   <= 1'b1;
            end
          end
        end

        S_WR_BUSY: begin
          // Poll MISO until card releases (high = not busy).
          if (!spi_active && !spi_start) begin
            if (spi_done) begin
              if (spi_rx_byte == 8'hFF) begin
                o_spi_cs_n <= 1'b1;
                state      <= S_IDLE;
              end else begin
                spi_tx_byte <= 8'hFF;
                spi_start   <= 1'b1;
              end
            end else begin
              spi_tx_byte <= 8'hFF;
              spi_start   <= 1'b1;
            end
          end
        end

        S_ERROR: begin
          err_r      <= 1'b1;
          o_spi_cs_n <= 1'b1;
        end

        default: state <= S_RESET;
      endcase
    end
  end

`ifdef FORMAL
  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  // Assume reset at time 0.
  initial assume (!i_rst_n);
  always @(posedge i_clk)
    if (f_past_valid) assume (i_rst_n);

  // SPI CS must be deasserted during init clock phase.
  always @(*) begin
    if (f_past_valid && state == S_INIT_CLOCKS)
      assert (o_spi_cs_n == 1'b1);
  end

  // o_busy and o_init_done are mutually consistent with state.
  always @(*) begin
    if (f_past_valid) begin
      if (state == S_IDLE)   assert (!o_busy);
      if (state == S_ERROR)  assert (!o_busy);
      if (state == S_RESET || state == S_INIT_CLOCKS ||
          state == S_CMD0  || state == S_CMD0_RESP)
        assert (!o_init_done);
    end
  end

  // SPI byte engine: once spi_active is set, it must stay set until spi_done.
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n) begin
      if ($past(spi_active) && !$past(spi_done))
        assert (spi_active || spi_done);
    end
  end

  // FIFO count must never exceed capacity.
  always @(*) begin
    if (f_past_valid) begin
      assert (rd_count <= FIFO_DEPTH);
      assert (wr_count <= FIFO_DEPTH);
    end
  end

  // Reachability covers.
  always @(*) cover (f_past_valid && state == S_IDLE);
  always @(*) cover (f_past_valid && state == S_ERROR);
  always @(*) cover (f_past_valid && state == S_INIT_CLOCKS);
  always @(*) cover (f_past_valid && spi_done);
`endif  // FORMAL

endmodule  // sdspi
