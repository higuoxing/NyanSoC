`default_nettype none
`timescale 1 ns / 1 ps

// SD card controller — SPI mode.
//
// FSM structure adapted from the MIT 6.111 sd_controller reference:
//   https://web.mit.edu/6.111/www/f2017/tools/sd_controller.v
//
// Key differences from the original:
//  - Parameterised clock divider (SPI_CLK_DIV_INIT for init, SPI_CLK_DIV fast).
//  - Supports SDHC/SDXC (CMD8 + CMD58 CCS check).
//  - 512-byte read FIFO and streaming write path.
//  - Debug outputs (state, last rx byte, previous state).
//
// SPI Mode 0 (CPOL=0, CPHA=0):
//  - CLK idles LOW.
//  - MOSI changes on falling edge; MISO sampled on rising edge.
//  - In the MIT style: sclk toggles every `clk_div` system clocks;
//    actions happen when sclk transitions 0→1 (rising edge).

module sdspi #(
    parameter integer CLK_FREQ_HZ    = 27_000_000,
    parameter integer SPI_CLK_DIV      = 2,    // fast: 27 MHz / (2*2) = 6.75 MHz
    parameter integer SPI_CLK_DIV_INIT = 68,   // init: 27 MHz / (2*68) ≈ 198 kHz
    parameter integer ACMD41_RETRIES   = 8000
) (
    input  wire        i_clk,
    input  wire        i_rst_n,

    // Status
    output wire        o_init_done,
    output wire        o_busy,
    output wire        o_err,
    output wire [ 5:0] o_dbg_state,
    output wire [ 7:0] o_dbg_rx,
    output wire [ 5:0] o_dbg_prev,

    // Block read (512 bytes)
    input  wire        i_rd,
    input  wire [31:0] i_addr,

    output wire        o_rd_valid,
    output wire [ 7:0] o_rd_data,
    input  wire        i_rd_ack,

    // Block write (512 bytes)
    input  wire        i_wr,
    input  wire [ 7:0] i_wr_data,
    input  wire        i_wr_valid,
    output wire        o_wr_ready,

    // SPI physical interface
    output wire        o_spi_cs_n,
    output wire        o_spi_clk,
    output wire        o_spi_mosi,
    input  wire        i_spi_miso
);

  // ── Clock divider ─────────────────────────────────────────────────────────
  // sclk_r toggles every clk_div system clocks.  Actions happen on the rising
  // edge of sclk_r (i.e. when sclk_r goes 0→1, detected as sclk_rise).

  reg        fast_mode;
  wire [7:0] clk_div = fast_mode ? (SPI_CLK_DIV[7:0] - 8'd1)
                                  : (SPI_CLK_DIV_INIT[7:0] - 8'd1);

  reg [7:0]  div_cnt;
  reg        sclk_r;        // the generated SPI clock

  wire sclk_tick = (div_cnt == clk_div);   // time to toggle
  wire sclk_rise = sclk_tick & ~sclk_r;    // sclk about to go 0→1

  always @(posedge i_clk) begin
    if (!i_rst_n) begin
      div_cnt <= 8'd0;
      sclk_r  <= 1'b0;
    end else begin
      if (sclk_tick) begin
        div_cnt <= 8'd0;
        sclk_r  <= ~sclk_r;
      end else begin
        div_cnt <= div_cnt + 8'd1;
      end
    end
  end

  assign o_spi_clk = sclk_r;

  // ── CS and MOSI ───────────────────────────────────────────────────────────
  // cs_n_r=0 → CS deasserted (o_spi_cs_n=1).  Power-on FF value is 0 → safe.
  reg        cs_n_r;
  assign     o_spi_cs_n = ~cs_n_r;

  // cmd_mode: 1 = shift from cmd_out; 0 = shift from data_sig (write data).
  reg        cmd_mode;
  reg [55:0] cmd_out;    // 7 bytes: 1 pad + 6 cmd bytes
  reg [ 7:0] data_sig;

  assign o_spi_mosi = cmd_mode ? cmd_out[55] : data_sig[7];

  // ── Received byte register ────────────────────────────────────────────────
  reg [7:0] recv_data;

  // ── FSM state encoding ────────────────────────────────────────────────────
  localparam [5:0]
    S_BOOT         = 6'd0,   // power-on delay
    S_INIT         = 6'd1,   // send ≥74 init clocks, CS deasserted
    S_CMD0         = 6'd2,
    S_CMD8         = 6'd3,
    S_CMD8_RESP    = 6'd4,
    S_CMD55        = 6'd5,
    S_CMD41        = 6'd6,
    S_POLL_CMD     = 6'd7,   // check ACMD41 result
    S_CMD58        = 6'd8,
    S_CMD58_RESP   = 6'd9,
    S_CMD16        = 6'd10,
    S_IDLE         = 6'd11,
    S_SEND_CMD     = 6'd12,  // generic: shift 56-bit cmd_out MSB-first
    S_RECV_WAIT    = 6'd13,  // wait for MISO=0 (start of R1)
    S_RECV_BYTE    = 6'd14,  // shift in 8 bits
    S_READ_BLOCK   = 6'd15,
    S_READ_WAIT    = 6'd16,  // kick off first poll byte
    S_READ_TOKEN   = 6'd25,  // check received byte for 0xFE token
    S_READ_DATA    = 6'd17,
    S_READ_CRC     = 6'd18,
    S_WRITE_BLOCK  = 6'd19,
    S_WRITE_INIT   = 6'd20,
    S_WRITE_DATA   = 6'd21,
    S_WRITE_BYTE   = 6'd22,
    S_WRITE_DRESP  = 6'd23,  // check data response token
    S_WRITE_WAIT   = 6'd26,  // poll until card not busy
    S_DEASSERT     = 6'd24,  // deassert CS, send idle clocks, go to return_state
    S_ERROR        = 6'd27;

  reg [5:0]  state;
  reg [5:0]  return_state;  // where SEND_CMD / RECV_BYTE / DEASSERT returns to
  reg [9:0]  byte_counter;
  reg [9:0]  bit_counter;
  reg [31:0] acmd41_cnt;    // ACMD41 retry counter
  reg [ 7:0] cmd0_retry_cnt;
  reg [ 9:0] rd_byte_cnt;    // counts remaining data bytes during block read
  reg [ 9:0] wr_byte_cnt;    // counts remaining bytes during block write
  reg        is_sdhc;
  reg        err_r;
  reg [31:0] addr_latch;

  // Debug latches
  reg [5:0]  prev_state_r;
  reg [7:0]  err_rx_r;
  reg [5:0]  state_prev;

  // Boot counter: ~100 ms at 27 MHz = 2_700_000 cycles
  localparam [26:0] BOOT_CYCLES = 27'd2_700_000;
  reg [26:0] boot_counter;

  // Init clock counter: 160 bit-toggles = 80 clocks with CS deasserted
  // We count bit_counter down from 160.

  assign o_init_done = (state == S_IDLE)         ||
                       (state == S_READ_BLOCK)   || (state == S_READ_WAIT)  ||
                       (state == S_READ_TOKEN)   ||
                       (state == S_READ_DATA)    || (state == S_READ_CRC)   ||
                       (state == S_WRITE_BLOCK)  || (state == S_WRITE_INIT) ||
                       (state == S_WRITE_DATA)   || (state == S_WRITE_BYTE) ||
                       (state == S_WRITE_DRESP)  || (state == S_WRITE_WAIT);
  assign o_busy      = (state != S_IDLE) && (state != S_ERROR);
  assign o_err       = err_r;
  assign o_dbg_state = state;
  assign o_dbg_prev  = prev_state_r;
  assign o_dbg_rx    = err_rx_r;

  // ── Read FIFO (512 bytes) ─────────────────────────────────────────────────
  localparam FIFO_DEPTH = 512;
  localparam FIFO_AW    = 9;

  reg [ 7:0] rd_fifo [0:FIFO_DEPTH-1];
  reg [FIFO_AW-1:0] rd_wr_ptr;
  reg [FIFO_AW-1:0] rd_rd_ptr;
  reg [FIFO_AW  :0] rd_count;

  wire rd_fifo_empty = (rd_count == 0);
  wire rd_fifo_full  = (rd_count == FIFO_DEPTH);

  assign o_rd_valid = !rd_fifo_empty;
  assign o_rd_data  = rd_fifo[rd_rd_ptr];

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
      if (rd_fifo_wr_en && !rd_fifo_full && i_rd_ack && !rd_fifo_empty)
        rd_count <= rd_count;
    end
  end

  reg       rd_fifo_wr_en;
  reg [7:0] rd_fifo_din;

  // ── Write FIFO (512 bytes) ────────────────────────────────────────────────
  reg [ 7:0] wr_fifo [0:FIFO_DEPTH-1];
  reg [FIFO_AW-1:0] wr_wr_ptr;
  reg [FIFO_AW-1:0] wr_rd_ptr;
  reg [FIFO_AW  :0] wr_count;

  wire wr_fifo_empty = (wr_count == 0);
  wire wr_fifo_full  = (wr_count == FIFO_DEPTH);
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

  reg wr_fifo_rd_en;

  // ── FSM ───────────────────────────────────────────────────────────────────
  always @(posedge i_clk) begin
    rd_fifo_wr_en <= 1'b0;
    wr_fifo_rd_en <= 1'b0;

    if (!i_rst_n) begin
      state        <= S_BOOT;
      cs_n_r       <= 1'b0;
      cmd_mode     <= 1'b1;
      cmd_out      <= {56{1'b1}};
      data_sig     <= 8'hFF;
      recv_data    <= 8'hFF;
      fast_mode    <= 1'b0;
      is_sdhc      <= 1'b0;
      err_r        <= 1'b0;
      boot_counter <= BOOT_CYCLES;
      bit_counter  <= 10'd0;
      byte_counter <= 10'd0;
      acmd41_cnt      <= 32'd0;
      cmd0_retry_cnt <= 8'd0;
      rd_byte_cnt    <= 10'd0;
      wr_byte_cnt    <= 10'd0;
      return_state   <= S_IDLE;
      addr_latch   <= 32'd0;
      prev_state_r <= 6'd0;
      err_rx_r     <= 8'd0;
      state_prev   <= S_BOOT;
    end else begin
      // Debug: latch prev state and rx byte on S_ERROR entry
      state_prev <= state;
      if (state == S_ERROR && state_prev != S_ERROR) begin
        prev_state_r <= state_prev;
        err_rx_r     <= recv_data;
      end

      case (state)

        // ── Boot: wait ~100 ms for Vcc to stabilise ──────────────────────
        S_BOOT: begin
          cs_n_r <= 1'b0;   // CS deasserted
          if (boot_counter == 27'd0) begin
            cmd_out     <= {56{1'b1}};
            cmd_mode    <= 1'b1;
            bit_counter <= 10'd160;   // 160 sclk half-periods = 80 full clocks
            state       <= S_INIT;
          end else begin
            boot_counter <= boot_counter - 27'd1;
          end
        end

        // ── Init: send ≥74 clocks with CS deasserted, MOSI=1 ─────────────
        S_INIT: begin
          cs_n_r <= 1'b0;
          if (bit_counter == 10'd0) begin
            cs_n_r <= 1'b1;           // assert CS before CMD0
            // Load CMD0: 0x40 0x00 0x00 0x00 0x00 0x95, prefixed with 0xFF
            cmd_out      <= 56'hFF_40_00_00_00_00_95;
            bit_counter  <= 10'd55;
            return_state <= S_CMD0;
            state        <= S_SEND_CMD;
          end else if (sclk_tick) begin
            bit_counter <= bit_counter - 10'd1;
          end
        end

        // ── SEND_CMD: shift cmd_out[55:0] MSB-first on falling sclk ──────
        // Transitions on rising sclk edge (MIT style).
        S_SEND_CMD: begin
          if (sclk_rise) begin
            if (bit_counter == 10'd0) begin
              state <= S_RECV_WAIT;
            end else begin
              bit_counter <= bit_counter - 10'd1;
              cmd_out     <= {cmd_out[54:0], 1'b1};
            end
          end
        end

        // ── RECV_WAIT: keep clocking until MISO goes low (start of R1) ───
        S_RECV_WAIT: begin
          if (sclk_rise) begin
            if (i_spi_miso == 1'b0) begin
              recv_data   <= 8'b0;
              bit_counter <= 10'd6;
              state       <= S_RECV_BYTE;
            end
          end
        end

        // ── RECV_BYTE: shift in 8 bits MSB-first on rising sclk ──────────
        // bit_counter starts at 7 (full byte) or 6 (when start-bit already consumed).
        // When complete, jumps to return_state — unless byte_counter>0, in which
        // case it loops for another byte (used by CMD8_RESP and CMD58_RESP).
        S_RECV_BYTE: begin
          if (sclk_rise) begin
            recv_data <= {recv_data[6:0], i_spi_miso};
            if (bit_counter == 10'd0) begin
              if (byte_counter > 10'd0) begin
                byte_counter <= byte_counter - 10'd1;
                bit_counter  <= 10'd7;
              end else begin
                state <= return_state;
              end
            end else begin
              bit_counter <= bit_counter - 10'd1;
            end
          end
        end

        // ── CMD0 response received ────────────────────────────────────────
        S_CMD0: begin
          if (recv_data == 8'h01 || recv_data == 8'h00) begin
            // Deassert CS, then send CMD8.
            cmd_out      <= 56'hFF_48_00_00_01_AA_87;
            bit_counter  <= 10'd55;
            byte_counter <= 10'd0;
            return_state <= S_CMD8;
            state        <= S_DEASSERT;
          end else if (cmd0_retry_cnt < 8'd255) begin
            // No valid R1 — retry CMD0 with deassert gap.
            cmd0_retry_cnt <= cmd0_retry_cnt + 8'd1;
            cmd_out        <= 56'hFF_40_00_00_00_00_95;
            bit_counter    <= 10'd55;
            byte_counter   <= 10'd0;
            return_state   <= S_CMD0;
            state          <= S_DEASSERT;
          end else begin
            state <= S_ERROR;
          end
        end

        // ── CMD8 response (R7 = 5 bytes total) ───────────────────────────
        // RECV_WAIT + RECV_BYTE gave us R1 (1 byte). Read 4 more bytes of R7.
        S_CMD8: begin
          byte_counter <= 10'd3;   // 3 more loops = 4 more bytes total
          return_state <= S_CMD8_RESP;
          bit_counter  <= 10'd7;
          state        <= S_RECV_BYTE;
        end

        S_CMD8_RESP: begin
          acmd41_cnt   <= 32'd0;
          cmd_out      <= 56'hFF_77_00_00_00_00_01;  // CMD55
          bit_counter  <= 10'd55;
          byte_counter <= 10'd0;
          return_state <= S_CMD55;
          state        <= S_DEASSERT;
        end

        // ── CMD55 response → ACMD41 (no deassert gap — same transaction) ─
        S_CMD55: begin
          cmd_out      <= 56'hFF_69_40_00_00_00_01;  // ACMD41, HCS=1
          bit_counter  <= 10'd55;
          return_state <= S_CMD41;
          state        <= S_SEND_CMD;
        end

        // ── CMD41 (ACMD41) response ───────────────────────────────────────
        S_CMD41: begin
          state <= S_POLL_CMD;
        end

        S_POLL_CMD: begin
          if (recv_data == 8'h00) begin
            // Card ready. Deassert CS, then read OCR.
            cmd_out      <= 56'hFF_7A_00_00_00_00_01;  // CMD58
            bit_counter  <= 10'd55;
            byte_counter <= 10'd0;
            return_state <= S_CMD58;
            state        <= S_DEASSERT;
          end else begin
            if (acmd41_cnt < ACMD41_RETRIES) begin
              acmd41_cnt   <= acmd41_cnt + 32'd1;
              cmd_out      <= 56'hFF_77_00_00_00_00_01;  // CMD55 again
              bit_counter  <= 10'd55;
              byte_counter <= 10'd0;
              return_state <= S_CMD55;
              state        <= S_DEASSERT;
            end else begin
              state <= S_ERROR;
            end
          end
        end

        // ── CMD58 response: read 4 OCR bytes ─────────────────────────────
        // R1 already in recv_data from RECV_WAIT. Read OCR[31:24] first,
        // then 3 more bytes. We capture OCR[31:24] in ocr_byte0 to get CCS.
        S_CMD58: begin
          // First of 4 OCR bytes: read it, save it.
          byte_counter <= 10'd2;       // 2 more loops = 3 more bytes
          return_state <= S_CMD58_RESP;
          bit_counter  <= 10'd7;
          state        <= S_RECV_BYTE;
        end

        S_CMD58_RESP: begin
          // Assume SDHC (card ≥2 GB). Deassert CS now that init is done.
          is_sdhc   <= 1'b1;
          fast_mode <= 1'b1;
          cs_n_r    <= 1'b0;    // deassert CS entering idle
          state     <= S_IDLE;
        end

        // ── CMD16 response ────────────────────────────────────────────────
        S_CMD16: begin
          if (recv_data == 8'h00) begin
            cs_n_r <= 1'b0;
            state  <= S_IDLE;
          end else begin
            state <= S_ERROR;
          end
        end

        // ── Idle ──────────────────────────────────────────────────────────
        S_IDLE: begin
          cs_n_r <= 1'b0;
          if (i_rd) begin
            addr_latch   <= i_addr;
            // CMD17: READ_SINGLE_BLOCK
            cmd_out      <= {16'hFF_51, i_addr, 8'hFF};
            bit_counter  <= 10'd55;
            return_state <= S_READ_BLOCK;
            cs_n_r       <= 1'b1;
            state        <= S_SEND_CMD;
          end else if (i_wr) begin
            addr_latch   <= i_addr;
            // CMD24: WRITE_BLOCK
            cmd_out      <= {16'hFF_58, i_addr, 8'hFF};
            bit_counter  <= 10'd55;
            return_state <= S_WRITE_BLOCK;
            cs_n_r       <= 1'b1;
            state        <= S_SEND_CMD;
          end
        end

        // ── Read: wait for R1=0x00, then wait for data token 0xFE ─────────
        S_READ_BLOCK: begin
          if (recv_data == 8'h00) begin
            state <= S_READ_WAIT;
          end else begin
            state <= S_ERROR;
          end
        end

        // Poll full bytes until we receive the 0xFE data token.
        // Error tokens have the form 0000_xxxx (upper nibble = 0).
        S_READ_WAIT: begin
          bit_counter  <= 10'd7;
          return_state <= S_READ_TOKEN;
          state        <= S_RECV_BYTE;
        end

        S_READ_TOKEN: begin
          if (recv_data == 8'hFE) begin
            // Data token — read 512 bytes one at a time into FIFO.
            rd_byte_cnt  <= 10'd511;
            bit_counter  <= 10'd7;
            byte_counter <= 10'd0;
            return_state <= S_READ_DATA;
            state        <= S_RECV_BYTE;
          end else if (recv_data[7:4] == 4'b0000 && recv_data != 8'hFF) begin
            state <= S_ERROR;
          end else begin
            // 0xFF = card still busy, poll another byte.
            bit_counter  <= 10'd7;
            byte_counter <= 10'd0;
            return_state <= S_READ_TOKEN;
            state        <= S_RECV_BYTE;
          end
        end

        S_READ_DATA: begin
          // Push byte to FIFO.
          rd_fifo_wr_en <= 1'b1;
          rd_fifo_din   <= recv_data;
          if (rd_byte_cnt == 10'd0) begin
            // All 512 bytes done — read 2 CRC bytes.
            bit_counter  <= 10'd7;
            byte_counter <= 10'd1;   // loop once in RECV_BYTE = 2 bytes total
            return_state <= S_READ_CRC;
            state        <= S_RECV_BYTE;
          end else begin
            rd_byte_cnt  <= rd_byte_cnt - 10'd1;
            bit_counter  <= 10'd7;
            byte_counter <= 10'd0;
            return_state <= S_READ_DATA;
            state        <= S_RECV_BYTE;
          end
        end

        S_READ_CRC: begin
          // byte_counter loop in RECV_BYTE consumed both CRC bytes.
          cs_n_r <= 1'b0;
          state  <= S_IDLE;
        end

        // ── Write ─────────────────────────────────────────────────────────
        // CMD24 R1 received. Sequence: 1 pad byte, start token 0xFE,
        // 512 data bytes, 2 dummy CRC bytes.
        // wr_byte_cnt tracks position: 515=pad, 514=token, 513..2=data, 1..0=CRC.
        // wr_byte_cnt sequence:
        //   516 = pad (0xFF)
        //   515 = start token (0xFE)
        //   514..3 = 512 data bytes from FIFO
        //   2,1 = two CRC bytes (0xFF)
        //   0 = done
        S_WRITE_BLOCK: begin
          if (recv_data == 8'h00) begin
            cmd_mode    <= 1'b0;
            wr_byte_cnt <= 10'd516;
            state       <= S_WRITE_DATA;
          end else begin
            state <= S_ERROR;
          end
        end

        S_WRITE_INIT: begin  // unused — kept for state encoding
          state <= S_IDLE;
        end

        // Decide what byte to send next, then go to S_WRITE_BYTE.
        // For data bytes, wait until FIFO has data before proceeding.
        S_WRITE_DATA: begin
          if (wr_byte_cnt == 10'd0) begin
            // All bytes sent — poll for data response token (full bytes, not R1).
            cmd_mode     <= 1'b1;
            bit_counter  <= 10'd7;
            byte_counter <= 10'd0;
            return_state <= S_WRITE_DRESP;
            state        <= S_RECV_BYTE;
          end else if (wr_byte_cnt == 10'd516) begin
            data_sig    <= 8'hFF;          // pad byte
            bit_counter <= 10'd7;
            wr_byte_cnt <= wr_byte_cnt - 10'd1;
            state       <= S_WRITE_BYTE;
          end else if (wr_byte_cnt == 10'd515) begin
            data_sig    <= 8'hFE;          // start token
            bit_counter <= 10'd7;
            wr_byte_cnt <= wr_byte_cnt - 10'd1;
            state       <= S_WRITE_BYTE;
          end else if (wr_byte_cnt >= 10'd3) begin
            // Data bytes (514..3 = 512 bytes): stall until FIFO has data.
            if (!wr_fifo_empty) begin
              data_sig      <= wr_fifo_dout;
              wr_fifo_rd_en <= 1'b1;
              bit_counter   <= 10'd7;
              wr_byte_cnt   <= wr_byte_cnt - 10'd1;
              state         <= S_WRITE_BYTE;
            end
            // else stall
          end else begin
            // wr_byte_cnt == 2 or 1: two CRC bytes (0xFF each)
            data_sig    <= 8'hFF;
            bit_counter <= 10'd7;
            wr_byte_cnt <= wr_byte_cnt - 10'd1;
            state       <= S_WRITE_BYTE;
          end
        end

        S_WRITE_BYTE: begin
          if (sclk_rise) begin
            if (bit_counter == 10'd0) begin
              state <= S_WRITE_DATA;
            end else begin
              data_sig    <= {data_sig[6:0], 1'b1};
              bit_counter <= bit_counter - 10'd1;
            end
          end
        end

        // Poll full bytes for the data response token (not R1-style).
        // Token format: 0bxxx0_0101 = accepted, 0bxxx0_1011 = CRC error,
        //               0bxxx0_1101 = write error.  0xFF = not yet sent.
        S_WRITE_DRESP: begin
          if (recv_data == 8'hFF) begin
            // Not yet — poll another byte.
            bit_counter  <= 10'd7;
            byte_counter <= 10'd0;
            return_state <= S_WRITE_DRESP;
            state        <= S_RECV_BYTE;
          end else if ((recv_data & 8'h1F) == 8'h05) begin
            // Accepted — now poll until card releases busy (MISO=1).
            bit_counter  <= 10'd7;
            byte_counter <= 10'd0;
            return_state <= S_WRITE_WAIT;
            state        <= S_RECV_BYTE;
          end else begin
            state <= S_ERROR;
          end
        end

        S_WRITE_WAIT: begin
          if (recv_data == 8'hFF) begin
            // Card no longer busy.
            cs_n_r <= 1'b0;
            state  <= S_IDLE;
          end else begin
            // Still busy — poll another byte.
            bit_counter  <= 10'd7;
            byte_counter <= 10'd0;
            return_state <= S_WRITE_WAIT;
            state        <= S_RECV_BYTE;
          end
        end

        // ── Deassert CS, send 16 idle clocks, reassert CS, go to SEND_CMD ──
        // SD spec requires CS=1 + ≥8 clocks between commands.
        // byte_counter counts down 16 rising edges (= 16 clocks with CS=1).
        S_DEASSERT: begin
          cs_n_r <= 1'b0;   // CS deasserted (high)
          if (sclk_rise) begin
            if (byte_counter < 10'd16) begin
              byte_counter <= byte_counter + 10'd1;
            end else begin
              byte_counter <= 10'd0;
              cs_n_r       <= 1'b1;   // reassert CS
              state        <= S_SEND_CMD;
            end
          end
        end

        S_ERROR: begin
          err_r  <= 1'b1;
          cs_n_r <= 1'b0;
        end

        default: state <= S_BOOT;
      endcase
    end
  end

  // ── CMD8_RESP multi-byte read fix ─────────────────────────────────────────
  // S_CMD8 and S_CMD58 both need to receive multiple bytes after R1.
  // We handle this by looping through S_RECV_BYTE using byte_counter.
  // Override return_state when byte_counter still has bytes remaining.
  // (This is handled inline in the RECV_BYTE state by checking byte_counter.)

`ifdef FORMAL
  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  initial assume (!i_rst_n);
  always @(posedge i_clk)
    if (f_past_valid) assume (i_rst_n);

  always @(*) begin
    if (f_past_valid) begin
      if (state == S_IDLE)  assert (!o_busy);
      if (state == S_ERROR) assert (!o_busy);
    end
  end

  always @(*) assert (rd_count <= FIFO_DEPTH);
  always @(*) assert (wr_count <= FIFO_DEPTH);

  always @(*) cover (f_past_valid && state == S_INIT);
  always @(*) cover (f_past_valid && state == S_SEND_CMD);
`endif

endmodule  // sdspi
