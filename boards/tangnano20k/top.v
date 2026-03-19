`default_nettype none
`timescale 1 ns / 1 ps

/* NyanSoC top-level SoC for Tang Nano 20K
 *
 * Memory map:
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
 *   0x0005_0000                SDRAM ctrl/status  read: {30'b0, init_done, busy_n}
 *                                                 write: bit0=rd_n, bit1=wr_n (active-low strobe)
 *   0x0005_0004                SDRAM word address (21-bit, write before issuing command)
 *   0x0005_0008                SDRAM data: write=data to write, read=last read data
 *   0x0200_0000                CLINT mtime    lo (bits [31: 0])  R/W
 *   0x0200_0004                CLINT mtime    hi (bits [63:32])  R/W
 *   0x0200_0008                CLINT mtimecmp lo (bits [31: 0])  R/W
 *   0x0200_000C                CLINT mtimecmp hi (bits [63:32])  R/W
 *   0x0C00_0004                PLIC source 1 priority            R/W  (3-bit)
 *   0x0C00_1000                PLIC pending  word 0              R    (bit[1]=UART RX)
 *   0x0C00_2000                PLIC enable   context 0 word 0   R/W  (bit[1]=UART RX)
 *   0x0C20_0000                PLIC threshold context 0          R/W  (3-bit)
 *   0x0C20_0004                PLIC claim/complete context 0     R/W
 *   0x8000_0000 - 0x81FF_FFFF  SDRAM direct mapping (32 MB, 21-bit word addr)
 *                                 Reads/writes stall CPU until SDRAM ready.
 *                                 This is where Linux lives (kernel + heap + stack).
 *
 * Address decode (priority order):
 *   addr[31]    == 1           -> SDRAM direct (0x8000_0000–0x81FF_FFFF)
 *   bits [29:28] == 2'b10     -> CLINT  (0x0200_0000)
 *   bits [27:26] == 2'b11     -> PLIC   (0x0C00_0000)
 *   bits [19:16] == 4'b0000   -> IMEM   (only via instruction bus)
 *   bits [19:16] == 4'b0001   -> DMEM
 *   bits [19:16] == 4'b0010   -> GPIO
 *   bits [19:16] == 4'b0011   -> UART
 *   bits [19:16] == 4'b0100   -> SD card controller
 *   bits [19:16] == 4'b0101   -> SDRAM register-mapped (legacy)
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
    output wire       o_spi_cs_n,

    // GW2AR-18 embedded SDRAM dedicated pins (no IO_LOC constraints needed)
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_wen_n,
    output wire [ 3:0] O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [ 1:0] O_sdram_ba,
    inout  wire [31:0] IO_sdram_dq
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

  // PTW port — page-table walker read-only bus.
  // When the CPU is walking a page table it is stalled (no dmem_rvalid),
  // so we share the read bus: mux ptw_addr onto dmem_raddr when ptw_valid.
  wire [31:0] ptw_addr;
  wire        ptw_valid;
  wire [31:0] ptw_rdata;
  wire        ptw_ready;

  wire        o_trap;

  // ── Instruction memory ────────────────────────────────────────────────────
  // Addresses with bit 31 = 0 are served by the combinatorial LUT-ROM.
  // Addresses with bit 31 = 1 are fetched from SDRAM via the shared data-bus
  // arbiter — this enables uart_loader to upload and execute code in SDRAM
  // (0x8000_0000 – 0x81FF_FFFF) without reflashing the FPGA.
  wire [9:0] imem_idx = imem_addr[11:2];
  wire       imem_from_sdram = imem_addr[31] & imem_valid;

  // LUT-ROM: combinatorial case ROM (renamed to imem_lut_rdata by the Makefile
  // sed pass so the SDRAM mux below can override without a multiple-driver error).
  reg [31:0] imem_lut_rdata;
  always @(*) begin
    `include "imem_rom.vh"
  end

  // Final IMEM output mux.  bus_rdata / bus_rready are defined further below
  // (after the SDRAM arbiter section); Verilog combinatorial always blocks may
  // reference signals declared later in the file.
  always @(*) begin
    if (imem_from_sdram) begin
      imem_rdata = bus_rdata;
      imem_ready = bus_rready;
    end else begin
      imem_rdata = imem_lut_rdata;
      imem_ready = imem_valid;
    end
  end

  // ── Data BRAM ─────────────────────────────────────────────────────────────
  // Single 32-bit wide array with registered (synchronous) read port so
  // yosys can infer Gowin BSRAM. Byte-enables are applied at write time.
  reg [31:0] dmem [0:DMEM_WORDS-1];
  reg [31:0] dmem_q;  // registered read output

  wire dmem_wsel = dmem_wvalid && (dmem_waddr[19:16] == 4'b0001);

  // Unified read address mux — priority: PTW > IMEM-from-SDRAM > DMEM.
  // PTW: CPU is stalled (dmem_rvalid=0, imem_valid still set but we ignore it).
  // IMEM-from-SDRAM: CPU is stalled at fetch; dmem_rvalid=0 during fetch stall.
  // DMEM: normal data read.
  wire [31:0] bus_raddr  = ptw_valid        ? ptw_addr   :
                           imem_from_sdram   ? imem_addr  :
                                              dmem_raddr;
  wire        bus_rvalid = ptw_valid        ? 1'b1        :
                           imem_from_sdram   ? 1'b1        :
                                              dmem_rvalid;

  wire [9:0] dmem_raddr_idx = bus_raddr[11:2];
  wire [9:0] dmem_waddr_idx = dmem_waddr[11:2];

  always @(posedge i_clk) begin
    // Synchronous read — output registered one cycle after address presented.
    dmem_q <= dmem[dmem_raddr_idx];
    // Byte-enable write.
    if (dmem_wsel) begin
      if (dmem_wstrb[0]) dmem[dmem_waddr_idx][ 7: 0] <= dmem_wdata[ 7: 0];
      if (dmem_wstrb[1]) dmem[dmem_waddr_idx][15: 8] <= dmem_wdata[15: 8];
      if (dmem_wstrb[2]) dmem[dmem_waddr_idx][23:16] <= dmem_wdata[23:16];
      if (dmem_wstrb[3]) dmem[dmem_waddr_idx][31:24] <= dmem_wdata[31:24];
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

  // ── SDRAM controller ──────────────────────────────────────────────────────
  // Two access modes share the same physical sdram_gw2ar instance:
  //
  //  A) Register-mapped (legacy, 0x0005_xxxx):
  //       Lets firmware manually drive addr/data/cmd for diagnostics.
  //       Register map at 0x0005_xxxx (bits [3:2] select register):
  //         +0x0  ctrl/status [R/W]  read: {29'b0, rd_valid, init_done, busy_n}
  //                                  write: bit0=wr_n, bit1=rd_n (active-low, single-cycle)
  //         +0x4  address     [R/W]  21-bit word address
  //         +0x8  data        [R]    last received data (valid when rd_valid=1)
  //
  //  B) Direct-mapped (0x8000_0000–0x81FF_FFFF):
  //       CPU reads/writes are transparently translated to SDRAM commands.
  //       The word address is addr[22:2] (byte address → 32-bit word index).
  //       The CPU bus is stalled (rready=0 / wready=0) until the SDRAM
  //       controller acknowledges the transaction.
  //       Byte enables (dmem_wstrb) are forwarded as DQM (inverted).

  wire sdram_region_r = dmem_rvalid && (dmem_raddr[19:16] == 4'b0101);
  wire sdram_region_w = dmem_wvalid && (dmem_waddr[19:16] == 4'b0101);

  wire        sdram_init_done;
  wire        sdram_busy_n;
  wire        sdram_rd_valid;
  wire        sdram_wrd_ack;
  wire [31:0] sdram_data_out;

  // ── SDRAM direct-map signals ───────────────────────────────────────────────
  // addr[31] == 1 selects the direct-map region (0x8000_0000–0x81FF_FFFF).
  // We must share the controller with the legacy register-mapped path, so
  // direct-map accesses take priority over register-mapped ones (firmware
  // should not use register-mapped access while a CPU load/store to SDRAM
  // is in flight).

  // Direct-map region decode: any address with bit[31]=1 maps to SDRAM.
  // Covers 0x8000_0000–0xFFFF_FFFF; the 21-bit word address is taken from
  // bits[22:2] so only the bottom 32 MiB (0x8000_0000–0x81FF_FFFF) is
  // actually reachable, but the decode is intentionally wide so that the
  // full stack range (e.g. 0x801F_FFFC) and any future expansion are covered.
  wire sdram_dm_r = (bus_raddr[31] == 1'b1);
  wire sdram_dm_w = dmem_wvalid && (dmem_waddr[31] == 1'b1);

  // bus_rvalid_dm: the FSM trigger. For PTW and DMEM reads this is the natural
  // one-cycle bus_rvalid pulse. For IMEM-SDRAM fetches bus_rvalid stays high
  // the entire time the CPU is stalled, so we use it directly — the FSM
  // re-trigger guard is handled by the SDRDM_DONE_HOLD state below.
  wire bus_rvalid_dm = bus_rvalid;

  // Word address: bits [22:2] of the byte address give a 21-bit word index.
  wire [20:0] sdram_dm_waddr   = dmem_waddr[22:2];
  wire [20:0] sdram_dm_raddr_w = bus_raddr[22:2];

  // ── SDRAM direct-map FSMs ─────────────────────────────────────────────────
  //
  //  IDLE  → latch addr/data → ISSUE
  //  ISSUE → hold rd_n/wr_n=0; wait for wrd_ack=1 (command actually accepted,
  //           not displaced by auto-refresh) → WAIT
  //  WAIT  → read: wait for rd_valid. write: wait for busy_n=1
  //  DONE  → hold rready/wready=1 for 1 cycle → IDLE
  //
  //  wrd_ack = ack_sr[1] in sdram_gw2ar: fires exactly 2 cycles after the
  //  command is latched in STATE_IDLE. This is the authoritative signal that
  //  the controller accepted our command (not an auto-refresh).
  //
  localparam [2:0] SDRDM_IDLE      = 3'd0,
                   SDRDM_ISSUE     = 3'd1,
                   SDRDM_WAIT      = 3'd2,
                   SDRDM_DONE      = 3'd3,
                   SDRDM_DONE_HOLD = 3'd4;  // extra idle cycle so CPU deasserts valid
  // Disable FSM extraction for the same reason as sdrdm_w_state: state
  // comparisons appear in separate always blocks that Yosys would not update
  // if it re-encoded the FSM with auto encoding.
  (* fsm_encoding = "none" *)
  reg [2:0]  sdrdm_r_state;
  reg [31:0] sdrdm_rdata_latch;
  reg [20:0] sdrdm_raddr_lat;

  localparam [1:0] SDWDM_IDLE  = 2'd0,
                   SDWDM_ISSUE = 2'd1,
                   SDWDM_WAIT  = 2'd2,
                   SDWDM_DONE  = 2'd3;
  // Disable FSM extraction: the write latch block (below) uses sdrdm_w_state
  // in a separate always block that Yosys cannot see as part of the FSM ctrl
  // outputs.  If Yosys re-encodes the FSM the localparam values no longer
  // match the synthesised state bits, breaking the latch enable condition.
  (* fsm_encoding = "none" *)
  reg [1:0]  sdrdm_w_state;

  // Muxed SDRAM controller inputs (direct-map takes priority over legacy).
  reg  [20:0] sdram_addr_in;
  reg  [31:0] sdram_data_in;
  reg  [ 3:0] sdram_dqm_in;
  reg         sdram_wr_n_in;
  reg         sdram_rd_n_in;

  // ── Legacy register-mapped state ──────────────────────────────────────────
  reg  [20:0] sdram_addr_reg;
  reg  [31:0] sdram_data_reg;
  reg  [31:0] sdram_data_latch;
  reg         sdram_rd_valid_latch;

  wire sdram_data_rd = sdram_region_r && (dmem_raddr[3:2] == 2'b10);
  wire sdram_ctrl_w  = sdram_region_w && (dmem_waddr[3:2] == 2'b00) && dmem_wstrb[0];
  wire sdram_leg_wr_n = sdram_ctrl_w ? dmem_wdata[0] : 1'b1;
  wire sdram_leg_rd_n = sdram_ctrl_w ? dmem_wdata[1] : 1'b1;

  always @(posedge i_clk) begin
    if (!rst_n) begin
      sdram_addr_reg       <= 21'd0;
      sdram_data_reg       <= 32'd0;
      sdram_data_latch     <= 32'd0;
      sdram_rd_valid_latch <= 1'b0;
    end else begin
      if (sdram_region_w && (dmem_waddr[3:2] == 2'b01))
        sdram_addr_reg <= dmem_wdata[20:0];
      if (sdram_region_w && (dmem_waddr[3:2] == 2'b10))
        sdram_data_reg <= dmem_wdata;
      // Latch read data from legacy path (only when direct-map is idle).
      if (sdram_rd_valid && (sdrdm_r_state == SDRDM_IDLE)) begin
        sdram_rd_valid_latch <= 1'b1;
        sdram_data_latch     <= sdram_data_out;
      end else if (sdram_data_rd) begin
        sdram_rd_valid_latch <= 1'b0;
      end
    end
  end

  // ── Direct-map read FSM ────────────────────────────────────────────────────
  // IDLE: wait for a read request targeting SDRAM.
  always @(posedge i_clk) begin
    if (!rst_n) begin
      sdrdm_r_state    <= SDRDM_IDLE;
      sdrdm_rdata_latch<= 32'd0;
      sdrdm_raddr_lat  <= 21'd0;
    end else begin
      case (sdrdm_r_state)
        SDRDM_IDLE: begin
          // Block read until any in-flight write completes. Without this, a
          // continuous stream of instruction fetches keeps busy_n=0 and the
          // write FSM (SDWDM_WAIT) never sees a clear busy_n=1 window.
          if (sdram_dm_r && bus_rvalid_dm && (sdrdm_w_state == SDWDM_IDLE)) begin
            sdrdm_raddr_lat <= sdram_dm_raddr_w;
            sdrdm_r_state   <= SDRDM_ISSUE;
          end
        end
        SDRDM_ISSUE: begin
          // Hold rd_n=0 (via mux). Wait for wrd_ack=1 which fires 2 cycles
          // after the controller accepted our command in STATE_IDLE.
          // If auto-refresh fires instead, wrd_ack stays 0 and we keep waiting.
          if (sdram_wrd_ack)
            sdrdm_r_state <= SDRDM_WAIT;
        end
        SDRDM_WAIT: begin
          if (sdram_rd_valid) begin
            sdrdm_rdata_latch <= sdram_data_out;
            sdrdm_r_state     <= SDRDM_DONE;
          end
        end
        SDRDM_DONE: begin
          // Assert rready for one cycle so the CPU latches rdata, then hold
          // one extra cycle (DONE_HOLD) before returning to IDLE.  This gives
          // the CPU time to deassert imem_valid (advance the PC) so the FSM
          // does not immediately re-trigger on the same stale imem_valid.
          sdrdm_r_state <= SDRDM_DONE_HOLD;
        end
        SDRDM_DONE_HOLD: begin
          sdrdm_r_state <= SDRDM_IDLE;
        end
        default: sdrdm_r_state <= SDRDM_IDLE;
      endcase
    end
  end

  always @(posedge i_clk) begin
    if (!rst_n) begin
      sdrdm_w_state <= SDWDM_IDLE;
    end else begin
      case (sdrdm_w_state)
        SDWDM_IDLE: begin
          // Also wait for any in-flight read to finish before issuing a write,
          // otherwise both FSMs could be in ISSUE simultaneously.  The mux
          // gives the read FSM priority, so the write wrd_ack would never fire.
          if (sdram_dm_w && (sdrdm_r_state == SDRDM_IDLE))
            sdrdm_w_state <= SDWDM_ISSUE;
        end
        SDWDM_ISSUE: begin
          // Hold wr_n=0 (via mux). wrd_ack=1 confirms command acceptance.
          if (sdram_wrd_ack)
            sdrdm_w_state <= SDWDM_WAIT;
        end
        SDWDM_WAIT: begin
          // Wait for controller back in IDLE (write complete including recovery).
          if (sdram_busy_n)
            sdrdm_w_state <= SDWDM_DONE;
        end
        SDWDM_DONE: begin
          sdrdm_w_state <= SDWDM_IDLE;
        end
        default: sdrdm_w_state <= SDWDM_IDLE;
      endcase
    end
  end

  // ── SDRAM controller input mux ─────────────────────────────────────────────
  // Latch address/data when the FSM enters ISSUE:
  //   - Read addr: latched into sdrdm_raddr_lat at IDLE→ISSUE.
  //   - Write addr/data/strobe: latched into sdrdm_w*_lat at IDLE→ISSUE.
  //     (CPU deasserts wvalid after seeing wready, so we must capture it first.)
  reg [20:0] sdrdm_waddr_lat;
  reg [31:0] sdrdm_wdata_lat;
  reg [ 3:0] sdrdm_dqm_lat;

  always @(posedge i_clk) begin
    if (sdrdm_w_state == SDWDM_IDLE && sdram_dm_w && (sdrdm_r_state == SDRDM_IDLE)) begin
      sdrdm_waddr_lat <= sdram_dm_waddr;
      sdrdm_wdata_lat <= dmem_wdata;
      sdrdm_dqm_lat   <= ~dmem_wstrb;
    end
  end

  always @(*) begin
    if (sdrdm_r_state == SDRDM_ISSUE) begin
      // Hold rd_n=0 continuously while waiting for wrd_ack (command acceptance).
      // Auto-refresh will take priority in the controller; we keep rd_n=0 so
      // the controller picks up the command as soon as it returns to IDLE.
      sdram_addr_in = sdrdm_raddr_lat;
      sdram_data_in = 32'd0;
      sdram_dqm_in  = 4'b0000;
      sdram_wr_n_in = 1'b1;
      sdram_rd_n_in = 1'b0;
    end else if (sdrdm_w_state == SDWDM_ISSUE) begin
      sdram_addr_in = sdrdm_waddr_lat;
      sdram_data_in = sdrdm_wdata_lat;
      sdram_dqm_in  = sdrdm_dqm_lat;
      sdram_wr_n_in = 1'b0;
      sdram_rd_n_in = 1'b1;
    end else begin
      // Legacy register-mapped access.
      sdram_addr_in = sdram_addr_reg;
      sdram_data_in = sdram_data_reg;
      sdram_dqm_in  = 4'b0000;
      sdram_wr_n_in = sdram_leg_wr_n;
      sdram_rd_n_in = sdram_leg_rd_n;
    end
  end

  sdram_gw2ar #(
      .DATA_WIDTH              (32),
      .BANK_WIDTH              (2),
      .ROW_WIDTH               (11),
      .COLUMN_WIDTH            (8),
      .CLOCK_FREQ_MHZ          (27),
      .REFRESH_PERIOD_NS       (64_000_000),
      .REFRESH_TIMES           (4096),
      .INITIALIZATION_WAIT_PERIOD_NS(200_000),
      .T_CL_PERIOD             (3),
      .T_RP_PERIOD             (3),
      .T_MRD_PERIOD            (3),
      .T_WR_PERIOD             (3),
      .T_RFC_PERIOD            (9),
      .T_RCD_PERIOD            (3)
  ) u_sdram (
      .i_sdrc_rst_n       (rst_n),
      .i_sdrc_clk         (i_clk),
      .i_sdram_clk        (i_clk),
      .i_sdrc_self_refresh(1'b0),
      .i_sdrc_power_down  (1'b0),
      .i_sdrc_wr_n        (sdram_wr_n_in),
      .i_sdrc_rd_n        (sdram_rd_n_in),
      .i_sdrc_addr        (sdram_addr_in),
      .i_sdrc_dqm         (sdram_dqm_in),
      .i_sdrc_data_len    (8'd0),
      .i_sdrc_data        (sdram_data_in),
      .o_sdrc_data        (sdram_data_out),
      .o_sdrc_init_done   (sdram_init_done),
      .o_sdrc_busy_n      (sdram_busy_n),
      .o_sdrc_rd_valid    (sdram_rd_valid),
      .o_sdrc_wrd_ack     (sdram_wrd_ack),
      .o_sdram_clk        (O_sdram_clk),
      .o_sdram_cke        (O_sdram_cke),
      .o_sdram_cs_n       (O_sdram_cs_n),
      .o_sdram_cas_n      (O_sdram_cas_n),
      .o_sdram_ras_n      (O_sdram_ras_n),
      .o_sdram_wen_n      (O_sdram_wen_n),
      .o_sdram_dqm        (O_sdram_dqm),
      .o_sdram_addr       (O_sdram_addr),
      .o_sdram_ba         (O_sdram_ba),
      .io_sdram_dq        (IO_sdram_dq)
  );

  // ── CLINT (Core Local Interruptor) ───────────────────────────────────────
  // Standard RISC-V CLINT at 0x0200_0000.
  // mtime    increments every clock cycle (27 MHz).
  // mtimecmp is compared against mtime; when mtime >= mtimecmp the machine
  // timer interrupt (MTIP) is asserted via i_irq_timer on the CPU.
  //
  // Register map (bits [3:2] select word):
  //   +0x0  mtime    lo  [R/W]
  //   +0x4  mtime    hi  [R/W]
  //   +0x8  mtimecmp lo  [R/W]
  //   +0xC  mtimecmp hi  [R/W]
  //
  // Address decode: bits [29:28] == 2'b10 selects the CLINT region.
  // (0x0200_0000 → addr[29:28] = 2'b10, addr[27:0] = 0)

  wire clint_region_r = dmem_rvalid && (dmem_raddr[29:28] == 2'b10);
  wire clint_region_w = dmem_wvalid && (dmem_waddr[29:28] == 2'b10);

  reg [63:0] mtime;
  reg [63:0] mtimecmp;

  // mtime increments every cycle; CPU writes to mtime or mtimecmp take priority.
  always @(posedge i_clk) begin
    if (!rst_n) begin
      mtime    <= 64'd0;
      mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
    end else begin
      mtime <= mtime + 64'd1;
      if (clint_region_w) begin
        case (dmem_waddr[3:2])
          2'b00: begin  // mtime lo (write overrides increment this cycle)
            if (dmem_wstrb[0]) mtime[ 7: 0] <= dmem_wdata[ 7: 0];
            if (dmem_wstrb[1]) mtime[15: 8] <= dmem_wdata[15: 8];
            if (dmem_wstrb[2]) mtime[23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) mtime[31:24] <= dmem_wdata[31:24];
          end
          2'b01: begin  // mtime hi
            if (dmem_wstrb[0]) mtime[39:32] <= dmem_wdata[ 7: 0];
            if (dmem_wstrb[1]) mtime[47:40] <= dmem_wdata[15: 8];
            if (dmem_wstrb[2]) mtime[55:48] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) mtime[63:56] <= dmem_wdata[31:24];
          end
          2'b10: begin  // mtimecmp lo
            if (dmem_wstrb[0]) mtimecmp[ 7: 0] <= dmem_wdata[ 7: 0];
            if (dmem_wstrb[1]) mtimecmp[15: 8] <= dmem_wdata[15: 8];
            if (dmem_wstrb[2]) mtimecmp[23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) mtimecmp[31:24] <= dmem_wdata[31:24];
          end
          2'b11: begin  // mtimecmp hi
            if (dmem_wstrb[0]) mtimecmp[39:32] <= dmem_wdata[ 7: 0];
            if (dmem_wstrb[1]) mtimecmp[47:40] <= dmem_wdata[15: 8];
            if (dmem_wstrb[2]) mtimecmp[55:48] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) mtimecmp[63:56] <= dmem_wdata[31:24];
          end
          default: ;
        endcase
      end
    end
  end

  // Timer interrupt: asserted when mtime >= mtimecmp (unsigned comparison).
  wire irq_timer = (mtime >= mtimecmp);

  // ── PLIC ──────────────────────────────────────────────────────────────────
  // Base address 0x0C00_0000.  Decode: addr[27:26] == 2'b11 selects PLIC.
  // The PLIC address offset passed in is addr[23:0] (24 bits, up to 16 MB).
  wire plic_region_r = dmem_rvalid  && !dmem_raddr[31] && (dmem_raddr[27:26] == 2'b11);
  wire plic_region_w = dmem_wvalid  && !dmem_waddr[31] && (dmem_waddr[27:26] == 2'b11);

  wire [31:0] plic_rdata;
  wire        plic_rready;
  wire        irq_external;

  // UART RX fires a 1-cycle pulse (rx_valid_raw) — use as the PLIC source.
  plic u_plic (
      .i_clk    (i_clk),
      .i_rst_n  (rst_n),
      .i_src    ({rx_valid_raw, 1'b0}),   // [1]=UART RX, [0]=reserved
      .i_addr   (dmem_rvalid ? dmem_raddr[23:0] : dmem_waddr[23:0]),
      .i_rvalid (plic_region_r),
      .o_rdata  (plic_rdata),
      .o_rready (plic_rready),
      .i_wvalid (plic_region_w),
      .i_wstrb  (dmem_wstrb),
      .i_wdata  (dmem_wdata),
      .o_irq    (irq_external)
  );

  // ── IMEM data-path read (for .rodata accessed via data bus) ──────────────
  // The same LUT-ROM is read combinatorially with bus_raddr for data reads.
  wire [9:0] dmem_imem_idx = bus_raddr[11:2];
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
  wire [31:0] sd_rd_mux = (bus_raddr[3:2] == 2'b00) ? sd_status_word :
                           (bus_raddr[3:2] == 2'b10) ? sd_addr_reg    :
                           (bus_raddr[3:2] == 2'b11) ? {24'b0, sd_rd_data} : 32'b0;

  // Unified data read mux for both CPU DMEM reads and PTW reads.
  reg [31:0] bus_rdata;
  reg        bus_rready;

  // Region decode for the unified bus address — matches sdram_dm_r above.
  wire sdram_dm_region_bus = (bus_raddr[31] == 1'b1);
  wire clint_region_bus    = (!sdram_dm_region_bus) && (bus_raddr[29:28] == 2'b10);
  wire plic_region_bus     = (!sdram_dm_region_bus) && (!clint_region_bus) &&
                             (!bus_raddr[31]) && (bus_raddr[27:26] == 2'b11);

  // DMEM uses synchronous read — register the valid signal to add 1-cycle latency.
  wire dmem_region_bus = (!sdram_dm_region_bus) && (!clint_region_bus) &&
                         (!plic_region_bus) && (bus_raddr[19:16] == 4'b0001);
  reg  bus_rvalid_d;
  always @(posedge i_clk) bus_rvalid_d <= bus_rvalid && dmem_region_bus;

  // SDRAM direct-map read: stall until the FSM signals rd_done.
  // PTW reads to SDRAM are also handled here (sdram_dm_r covers ptw_addr).

  always @(*) begin
    if (sdram_dm_region_bus) begin
      // Deassert rready until the FSM reaches DONE (data in sdrdm_rdata_latch).
      // DONE is a 1-cycle state: CPU samples rready=1 and latches rdata, then
      // the FSM moves back to IDLE while the CPU advances to cpu_state_fetch.
      bus_rready = (sdrdm_r_state == SDRDM_DONE);
      // DONE_HOLD: rready=0, FSM is idle-but-blocked; CPU sees rready=0 and
      // deasserts imem_valid before FSM returns to IDLE on the next cycle.
      bus_rdata  = sdrdm_rdata_latch;
    end else if (clint_region_bus) begin
      bus_rready = bus_rvalid;
      case (bus_raddr[3:2])
        2'b00:   bus_rdata = mtime[31:0];
        2'b01:   bus_rdata = mtime[63:32];
        2'b10:   bus_rdata = mtimecmp[31:0];
        2'b11:   bus_rdata = mtimecmp[63:32];
        default: bus_rdata = 32'b0;
      endcase
    end else if (plic_region_bus) begin
      bus_rready = plic_rready;
      bus_rdata  = plic_rdata;
    end else begin
      bus_rready = dmem_region_bus ? bus_rvalid_d : bus_rvalid;
      case (bus_raddr[19:16])
        4'b0000: bus_rdata = dmem_imem_rdata;
        4'b0001: bus_rdata = dmem_q;
        4'b0011: bus_rdata = bus_raddr[2]
                              ? {31'b0, tx_busy}
                              : {23'b0, rx_valid_latch, rx_data_latch};
        4'b0100: bus_rdata = sd_rd_mux;
        4'b0101: bus_rdata = (bus_raddr[3:2] == 2'b00) ? {29'b0, sdram_rd_valid_latch, sdram_init_done, sdram_busy_n} :
                             (bus_raddr[3:2] == 2'b01) ? {11'b0, sdram_addr_reg} :
                                                          sdram_data_latch;
        default: bus_rdata = 32'b0;
      endcase
    end
  end

  // CPU DMEM read port: forward from shared bus when not ptw or imem-sdram.
  always @(*) begin
    dmem_rdata  = bus_rdata;
    dmem_rready = (ptw_valid || imem_from_sdram) ? 1'b0 : bus_rready;
  end


  // PTW read port: combinatorial pass-through from shared bus.
  assign ptw_rdata = bus_rdata;
  assign ptw_ready = ptw_valid ? bus_rready : 1'b0;

  // ── GPIO register ─────────────────────────────────────────────────────────
  wire gpio_wsel = dmem_wvalid && (dmem_waddr[19:16] == 4'b0010);

  reg [5:0] gpio_out;
  always @(posedge i_clk) begin
    if (!rst_n) gpio_out <= 6'b000000;
    else if (gpio_wsel && dmem_wstrb[0]) gpio_out <= dmem_wdata[5:0];
  end

  assign o_led = ~gpio_out;  // active-low: invert for the LED pins

  // Write-ready: stall CPU for SDRAM direct-map writes.
  // Signal ready only when the write FSM is in DONE state (wrd_ack received).
  // For non-SDRAM destinations, ack immediately.
  always @(*) begin
    if (sdram_dm_w)
      dmem_wready = (sdrdm_w_state == SDWDM_DONE);
    else
      dmem_wready = dmem_wvalid;
  end

  // ── CPU ───────────────────────────────────────────────────────────────────
  nyanrv u_cpu (
      .i_clk          (i_clk),
      .i_rst_n        (rst_n),
      .o_ptw_addr     (ptw_addr),
      .o_ptw_valid    (ptw_valid),
      .i_ptw_rdata    (ptw_rdata),
      .i_ptw_ready    (ptw_ready),
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
      .i_irq_timer    (irq_timer),
      .i_irq_external (irq_external),
      .o_trap         (o_trap)
  );

endmodule  // top
