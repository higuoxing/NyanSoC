`default_nettype none
`timescale 1 ns / 1 ps

// Example usage of sdram_gw2ar.
//
// After initialization completes the module writes the 32-bit word 0xDEADBEEF
// to SDRAM address 0, then reads it back.  Two LEDs report the outcome:
//   o_led_ok   – pulses high when the readback value matches the written word
//   o_led_err  – pulses high when the readback value does not match
//
// Wiring for Tang Nano 20K (27 MHz oscillator, GW2AR-18 embedded SDRAM):
//   i_clk      <- 27 MHz system clock (same clock fed to SDRAM)
//   i_rst_n    <- active-low reset (e.g. button_n)
//   o_sdram_*  <- connect directly to the GW2AR embedded SDRAM pins
//   io_sdram_dq<- bidirectional data bus

module sdram_gw2ar_example (
    input  wire        i_clk,
    input  wire        i_rst_n,

    // Status LEDs (active-high)
    output reg         o_led_ok,
    output reg         o_led_err,

    // SDRAM physical interface (pass through from sdram_gw2ar)
    output wire        o_sdram_clk,
    output wire        o_sdram_cke,
    output wire        o_sdram_cs_n,
    output wire        o_sdram_cas_n,
    output wire        o_sdram_ras_n,
    output wire        o_sdram_wen_n,
    output wire [ 3:0] o_sdram_dqm,
    output wire [10:0] o_sdram_addr,
    output wire [ 1:0] o_sdram_ba,
    inout  wire [31:0] io_sdram_dq
);

  // ── Controller user-side wires ─────────────────────────────────────────────
  reg         sdrc_wr_n;
  reg         sdrc_rd_n;
  reg  [20:0] sdrc_addr;
  reg  [31:0] sdrc_data_in;
  wire [31:0] sdrc_data_out;
  wire        sdrc_init_done;
  wire        sdrc_busy_n;
  wire        sdrc_rd_valid;
  wire        sdrc_wrd_ack;

  // ── sdram_gw2ar instance ───────────────────────────────────────────────────
  // Tang Nano 20K: 27 MHz, GW2AR-18 embedded SDRAM (64 Mbit, 32-bit wide).
  // Timing parameters follow the JEDEC SDR SDRAM spec for -6 speed grade.
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
      .i_sdrc_rst_n       (i_rst_n),
      .i_sdrc_clk         (i_clk),
      .i_sdram_clk        (i_clk),
      .i_sdrc_self_refresh(1'b0),
      .i_sdrc_power_down  (1'b0),
      .i_sdrc_wr_n        (sdrc_wr_n),
      .i_sdrc_rd_n        (sdrc_rd_n),
      .i_sdrc_addr        (sdrc_addr),
      .i_sdrc_dqm         (4'b0000),
      .i_sdrc_data_len    (8'd0),
      .i_sdrc_data        (sdrc_data_in),
      .o_sdrc_data        (sdrc_data_out),
      .o_sdrc_init_done   (sdrc_init_done),
      .o_sdrc_busy_n      (sdrc_busy_n),
      .o_sdrc_rd_valid    (sdrc_rd_valid),
      .o_sdrc_wrd_ack     (sdrc_wrd_ack),

      .o_sdram_clk  (o_sdram_clk),
      .o_sdram_cke  (o_sdram_cke),
      .o_sdram_cs_n (o_sdram_cs_n),
      .o_sdram_cas_n(o_sdram_cas_n),
      .o_sdram_ras_n(o_sdram_ras_n),
      .o_sdram_wen_n(o_sdram_wen_n),
      .o_sdram_dqm  (o_sdram_dqm),
      .o_sdram_addr (o_sdram_addr),
      .o_sdram_ba   (o_sdram_ba),
      .io_sdram_dq  (io_sdram_dq)
  );

  // ── Simple write-then-read-back FSM ───────────────────────────────────────
  localparam [2:0]
    S_WAIT_INIT = 3'd0,   // wait for controller initialisation to finish
    S_WRITE     = 3'd1,   // issue a single-word write
    S_WAIT_ACK  = 3'd2,   // wait for write acknowledgement
    S_READ      = 3'd3,   // issue a single-word read
    S_WAIT_DATA = 3'd4,   // wait for read data to be valid
    S_DONE      = 3'd5;   // latch result, stay here

  localparam [31:0] TEST_WORD    = 32'hDEAD_BEEF;
  localparam [20:0] TEST_ADDRESS = 21'd0;

  reg [2:0] state;

  always @(posedge i_clk) begin
    if (!i_rst_n) begin
      state        <= S_WAIT_INIT;
      sdrc_wr_n    <= 1'b1;
      sdrc_rd_n    <= 1'b1;
      sdrc_addr    <= 21'd0;
      sdrc_data_in <= 32'd0;
      o_led_ok     <= 1'b0;
      o_led_err    <= 1'b0;
    end else begin
      // Default: deassert strobes every cycle so they are single-cycle pulses.
      sdrc_wr_n <= 1'b1;
      sdrc_rd_n <= 1'b1;

      case (state)

        S_WAIT_INIT: begin
          if (sdrc_init_done && sdrc_busy_n)
            state <= S_WRITE;
        end

        S_WRITE: begin
          sdrc_wr_n    <= 1'b0;
          sdrc_addr    <= TEST_ADDRESS;
          sdrc_data_in <= TEST_WORD;
          state        <= S_WAIT_ACK;
        end

        S_WAIT_ACK: begin
          if (sdrc_wrd_ack)
            state <= S_READ;
        end

        S_READ: begin
          if (sdrc_busy_n) begin
            sdrc_rd_n <= 1'b0;
            sdrc_addr <= TEST_ADDRESS;
            state     <= S_WAIT_DATA;
          end
        end

        S_WAIT_DATA: begin
          if (sdrc_rd_valid) begin
            o_led_ok  <= (sdrc_data_out == TEST_WORD);
            o_led_err <= (sdrc_data_out != TEST_WORD);
            state     <= S_DONE;
          end
        end

        S_DONE: begin
          // Result latched in LEDs; stay idle.
        end

        default: state <= S_WAIT_INIT;
      endcase
    end
  end

endmodule  // sdram_gw2ar_example
