`default_nettype none
`timescale 1 ns / 1 ps

/* NyanSoC top-level SoC for Tang Nano 20K
 *
 * Memory map (all regions, indexed by addr[11:2]):
 *   0x0000_0000 - 0x0000_0FFF  IMEM (1 KiB words, combinatorial LUT-ROM)
 *   0x0001_0000 - 0x0001_0FFF  DMEM (1 KiB words, BRAM, read/write)
 *   0x0002_0000                GPIO output register
 *                                 bits [5:0] = LED[5:0] (write 1 = on)
 *   0x0003_0000                UART RX  read: {23'b0, valid, data[7:0]}  (clears valid)
 *   0x0003_0004                UART TX  write: send byte; read: {31'b0, busy}
 *   0x0004_0000                SD status  read: {18'b0, dbg_state[5:0], rd_valid, wr_ready, err, busy, init_done}
 *   0x0004_0004                SD command write: bit0=rd, bit1=wr (single-cycle strobe)
 *   0x0004_0008                SD address read/write: 32-bit block address
 *   0x0004_000C                SD data FIFO: write=push byte, read=pop byte
 *
 * Address decode uses bits [19:16]:
 *   4'b0000 -> IMEM  (only via instruction bus)
 *   4'b0001 -> DMEM
 *   4'b0010 -> GPIO
 *   4'b0011 -> UART (RX at offset 0, TX at offset 4)
 *   4'b0100 -> SD card controller
 *
 * Reset: i_rst_n is the S1 button (active-low, pulled high at rest).
 * A power-on reset shift register (por_sr) guarantees reset is held for
 * 8 cycles after FPGA configuration, so the CPU starts cleanly without
 * needing to press S1.
 */

module top #(
    parameter integer CLK_FREQ  = 27_000_000,
    parameter integer BAUD_RATE = 115_200
) (
    input  wire       i_clk,
    input  wire       i_rst_n,  // S1 button: 1 when pressed, 0 at rest (pulled low)
    output wire [5:0] o_led,    // active-low LEDs (6 monochromatic)
    input  wire       i_rx,     // UART RX
    output wire       o_tx,     // UART TX

    // TF (microSD) card — SPI mode
    output wire       o_spi_clk,
    output wire       o_spi_mosi,
    input  wire       i_spi_miso,
    output wire       o_spi_cs_n
);

  // ── Parameters ────────────────────────────────────────────────────────────
  parameter IMEM_WORDS = 1024;
  parameter DMEM_WORDS = 1024;

  // ── Power-on reset ────────────────────────────────────────────────────────
  // On FPGA power-up, initial blocks do not reliably reset flip-flops.
  // por_sr starts all-zero (Gowin GSR pulls FFs low at configuration time)
  // and shifts in 1s each cycle, keeping rst_n low for 8 cycles before
  // releasing. S1 is pulled low at rest and goes high when pressed, so
  // pressing S1 asserts reset (i_rst_n=1 → rst_n=0).
  reg [7:0] por_sr = 8'b0;
  always @(posedge i_clk) por_sr <= {por_sr[6:0], 1'b1};
  wire rst_n = por_sr[7] & ~i_rst_n;  // ~i_rst_n: pressed=0 (reset), rest=1 (run)

  // ── CPU wires ─────────────────────────────────────────────────────────────
  wire [31:0] imem_addr;
  wire        imem_valid;
  reg  [31:0] imem_rdata;
  reg         imem_ready;

  wire [31:0] dmem_raddr;
  wire        dmem_rvalid;
  reg  [31:0] dmem_rdata;
  reg         dmem_rready;

  wire [31:0] dmem_waddr;
  wire        dmem_wvalid;
  wire [ 3:0] dmem_wstrb;
  wire [31:0] dmem_wdata;
  reg         dmem_wready;

  wire        o_trap;

  // ── Instruction memory: combinatorial LUT-ROM ─────────────────────────────
  // A pure combinatorial case ROM synthesises reliably to LUTs.
  // $readmemh-based BRAM init is unreliable with the open-source Gowin flow.
  wire [9:0] imem_idx = imem_addr[11:2];

  always @(*) begin
    `include "imem_rom.vh"
    imem_ready = imem_valid;
  end

  // ── Data BRAM ─────────────────────────────────────────────────────────────
  // Four separate byte-wide BRAMs so each can be written independently.
  // Gowin BRAM does not support sub-word byte-enable writes on a single
  // 32-bit-wide instance, so we split into four 8-bit BRAMs instead.
  reg [7:0] dmem0[0:DMEM_WORDS-1];  // bits  [7: 0]
  reg [7:0] dmem1[0:DMEM_WORDS-1];  // bits [15: 8]
  reg [7:0] dmem2[0:DMEM_WORDS-1];  // bits [23:16]
  reg [7:0] dmem3[0:DMEM_WORDS-1];  // bits [31:24]

  wire dmem_wsel = dmem_wvalid && (dmem_waddr[19:16] == 4'b0001);

  wire [9:0] dmem_raddr_idx = dmem_raddr[11:2];
  wire [9:0] dmem_waddr_idx = dmem_waddr[11:2];

  always @(posedge i_clk) begin
    if (dmem_wsel) begin
      if (dmem_wstrb[0]) dmem0[dmem_waddr_idx] <= dmem_wdata[ 7: 0];
      if (dmem_wstrb[1]) dmem1[dmem_waddr_idx] <= dmem_wdata[15: 8];
      if (dmem_wstrb[2]) dmem2[dmem_waddr_idx] <= dmem_wdata[23:16];
      if (dmem_wstrb[3]) dmem3[dmem_waddr_idx] <= dmem_wdata[31:24];
    end
  end

  // ── UART TX ───────────────────────────────────────────────────────────────
  wire uart_tx_wr = dmem_wvalid && (dmem_waddr[19:16] == 4'b0011)
                    && dmem_waddr[2] && dmem_wstrb[0];
  wire tx_busy;

  uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) u_uart_tx (
      .i_clk    (i_clk),
      .i_rst_n  (rst_n),
      .i_tx_wr  (uart_tx_wr),
      .o_tx     (o_tx),
      .o_tx_busy(tx_busy),
      .i_tx_data(dmem_wdata[7:0])
  );

  // ── UART RX ───────────────────────────────────────────────────────────────
  wire       rx_valid_raw;
  wire [7:0] rx_data_raw;

  uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) u_uart_rx (
      .i_clk     (i_clk),
      .i_rst_n   (rst_n),
      .i_rx      (i_rx),
      .o_rx_valid(rx_valid_raw),
      .o_rx_data (rx_data_raw)
  );

  // 1-byte latch: holds the last received byte until the CPU reads it.
  // Reading 0x0003_0000 returns {23'b0, valid, data[7:0]} and clears valid.
  wire uart_rx_rd = dmem_rvalid && (dmem_raddr[19:16] == 4'b0011)
                    && (dmem_raddr[2] == 1'b0);

  reg       rx_valid_latch;
  reg [7:0] rx_data_latch;

  always @(posedge i_clk) begin
    if (!rst_n) begin
      rx_valid_latch <= 1'b0;
      rx_data_latch  <= 8'b0;
    end else begin
      if (rx_valid_raw) begin
        // New byte — latch it (takes priority over a simultaneous CPU read).
        rx_valid_latch <= 1'b1;
        rx_data_latch  <= rx_data_raw;
      end else if (uart_rx_rd) begin
        // CPU read clears the valid flag.
        rx_valid_latch <= 1'b0;
      end
    end
  end

  // ── SD card controller (sdspi) ────────────────────────────────────────────
  // Register map at 0x0004_xxxx (bits [3:2] select register):
  //   +0x0  status  [R]   {29'b0, o_err, o_busy, o_init_done}
  //   +0x4  command [W]   bit0=i_rd, bit1=i_wr  (single-cycle strobe)
  //   +0x8  address [R/W] 32-bit block address
  //   +0xC  data    [R/W] write=push byte to TX FIFO, read=pop byte from RX FIFO

  wire sd_region_r = dmem_rvalid && (dmem_raddr[19:16] == 4'b0100);
  wire sd_region_w = dmem_wvalid && (dmem_waddr[19:16] == 4'b0100);

  wire        sd_init_done;
  wire        sd_busy;
  wire        sd_err;
  wire [ 5:0] sd_dbg_state;
  wire [ 7:0] sd_dbg_rx;
  wire [ 5:0] sd_dbg_prev;

  reg         sd_rd;
  reg         sd_wr;
  reg  [31:0] sd_addr_reg;

  wire        sd_rd_valid;
  wire [ 7:0] sd_rd_data;
  reg         sd_rd_ack;

  wire        sd_wr_ready;

  // Command register write (offset +0x4): pulse i_rd / i_wr for one cycle.
  wire sd_cmd_w = sd_region_w && (dmem_waddr[3:2] == 2'b01) && dmem_wstrb[0];

  always @(posedge i_clk) begin
    if (!rst_n) begin
      sd_rd      <= 1'b0;
      sd_wr      <= 1'b0;
      sd_addr_reg<= 32'd0;
    end else begin
      sd_rd <= 1'b0;
      sd_wr <= 1'b0;
      if (sd_cmd_w) begin
        sd_rd <= dmem_wdata[0];
        sd_wr <= dmem_wdata[1];
      end
      // Address register write (offset +0x8).
      if (sd_region_w && (dmem_waddr[3:2] == 2'b10))
        sd_addr_reg <= dmem_wdata;
    end
  end

  // Data FIFO read: pop one byte when CPU reads offset +0xC.
  always @(*) sd_rd_ack = sd_region_r && (dmem_raddr[3:2] == 2'b11);

  sdspi #(
      .CLK_FREQ_HZ   (CLK_FREQ),
      .SPI_CLK_DIV   (2),         // 27 MHz / 4 = 6.75 MHz
      .SPI_CLK_DIV_INIT(68)       // 27 MHz / 136 ≈ 199 kHz during init
  ) u_sdspi (
      .i_clk      (i_clk),
      .i_rst_n    (rst_n),
      .o_init_done(sd_init_done),
      .o_busy     (sd_busy),
      .o_err      (sd_err),
      .i_rd       (sd_rd),
      .i_addr     (sd_addr_reg),
      .o_rd_valid (sd_rd_valid),
      .o_rd_data  (sd_rd_data),
      .i_rd_ack   (sd_rd_ack),
      .i_wr       (sd_wr),
      .i_wr_data  (dmem_wdata[7:0]),
      .i_wr_valid (sd_region_w && (dmem_waddr[3:2] == 2'b11) && dmem_wstrb[0]),
      .o_wr_ready (sd_wr_ready),
      .o_spi_cs_n (o_spi_cs_n),
      .o_spi_clk  (o_spi_clk),
      .o_spi_mosi (o_spi_mosi),
      .i_spi_miso   (i_spi_miso),
      .o_dbg_state  (sd_dbg_state),
      .o_dbg_rx     (sd_dbg_rx),
      .o_dbg_prev   (sd_dbg_prev)
  );

  // ── IMEM data-path read (for .rodata accessed via data bus) ──────────────
  // The same LUT-ROM is read combinatorially with dmem_raddr for data reads.
  wire [9:0] dmem_imem_idx = dmem_raddr[11:2];
  reg [31:0] dmem_imem_rdata;
  always @(*) begin
    case (dmem_imem_idx)
      `include "imem_data_rom.vh"
      default: dmem_imem_rdata = 32'h00000013;
    endcase
  end

  // ── Data-bus read mux ─────────────────────────────────────────────────────
  // Status word bit layout:
  //  [31:26] unused
  //  [25:20] dbg_prev  — state before entering S_ERROR
  //  [19:12] dbg_rx    — last SPI rx byte when error occurred
  //  [11: 6] dbg_state — current FSM state
  //  [    5] rd_valid
  //  [    4] (unused, was rd_valid bit 4 — shift to keep low 5 as before)
  // Redefine compact layout to keep firmware bit defs unchanged (bits [4:0]):
  //  [4] rd_valid, [3] wr_ready, [2] err, [1] busy, [0] init_done
  wire [31:0] sd_status_word = {7'b0, sd_dbg_prev, sd_dbg_rx, sd_dbg_state,
                                sd_rd_valid, sd_wr_ready, sd_err, sd_busy, sd_init_done};
  wire [31:0] sd_rd_mux = (dmem_raddr[3:2] == 2'b00) ? sd_status_word :
                           (dmem_raddr[3:2] == 2'b10) ? sd_addr_reg    :
                           (dmem_raddr[3:2] == 2'b11) ? {24'b0, sd_rd_data} : 32'b0;

  always @(*) begin
    case (dmem_raddr[19:16])
      4'b0000: dmem_rdata = dmem_imem_rdata;
      4'b0001: dmem_rdata = {dmem3[dmem_raddr_idx],
                              dmem2[dmem_raddr_idx],
                              dmem1[dmem_raddr_idx],
                              dmem0[dmem_raddr_idx]};
      4'b0011: dmem_rdata = dmem_raddr[2]
                             ? {31'b0, tx_busy}
                             : {23'b0, rx_valid_latch, rx_data_latch};
      4'b0100: dmem_rdata = sd_rd_mux;
      default: dmem_rdata = 32'b0;
    endcase
    dmem_rready = dmem_rvalid;
  end

  // ── GPIO register ─────────────────────────────────────────────────────────
  wire gpio_wsel = dmem_wvalid && (dmem_waddr[19:16] == 4'b0010);

  reg [5:0] gpio_out;
  always @(posedge i_clk) begin
    if (!rst_n) gpio_out <= 6'b000000;
    else if (gpio_wsel && dmem_wstrb[0]) gpio_out <= dmem_wdata[5:0];
  end

  assign o_led = ~gpio_out;  // active-low: invert for the LED pins

  always @(*) dmem_wready = dmem_wvalid;

  // ── CPU ───────────────────────────────────────────────────────────────────
  nyanrv u_cpu (
      .i_clk          (i_clk),
      .i_rst_n        (rst_n),
      .o_imem_addr    (imem_addr),
      .o_imem_valid   (imem_valid),
      .i_imem_rdata   (imem_rdata),
      .i_imem_ready   (imem_ready),
      .o_dmem_raddr   (dmem_raddr),
      .o_dmem_rvalid  (dmem_rvalid),
      .i_dmem_rdata   (dmem_rdata),
      .i_dmem_rready  (dmem_rready),
      .o_dmem_waddr   (dmem_waddr),
      .o_dmem_wvalid  (dmem_wvalid),
      .o_dmem_wstrb   (dmem_wstrb),
      .o_dmem_wdata   (dmem_wdata),
      .i_dmem_wready  (dmem_wready),
      .i_irq_timer    (1'b0),
      .i_irq_external (1'b0),
      .o_trap         (o_trap)
  );

endmodule  // top
