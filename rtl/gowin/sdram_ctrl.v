// Open source alternative for Gowin SDRAM Controller IP (https://cdn.gowinsemi.com.cn/IPUG279E.pdf).
// Based on https://github.com/nand2mario/sdram-tang-nano-20k/blob/main/src/sdram.v

`default_nettype none `timescale 1 ns / 1 ps

module sdram_ctrl #(
    parameter integer DATA_WIDTH = 32,  // Value range: {8, 16, 32, 64}
    parameter integer BANK_WIDTH = 2,  // Value range: {1, 2}
    parameter integer ROW_WIDTH = 11,  // Value range: {11, 12, 13, 14}
    parameter integer COLUMN_WIDTH = 8,  // Value range: {8, 9, 10, 11, 12}
    parameter integer REFRESH_PERIOD_NS = 64_000_000,  // Value range: [1, +∞)
    parameter integer REFRESH_TIMES = 4096,  // Value range: [1, +∞)
    parameter integer CLOCK_FREQ_MHZ = 100,  // Value range: [4, 100],
    // Working clock frequency of SDRAM controller.
    parameter integer INITIALIZATION_WAIT_PERIOD_NS = 200_000,  // Value range: [100, +∞)
    parameter integer T_CL_PERIOD = 3'd3,  // CAS latency, Value range: {1, 2, 3}
    parameter integer T_RP_PERIOD = 3,  // tRP, PRECHARGE command period. Value range: [1, +∞)
    parameter integer T_MRD_PERIOD = 3,  // tMRD, LOAD MODE REGISTER command to ACTIVE or REFRESH
    // command period. Value range: [1, +∞)
    parameter integer T_WR_PERIOD = 3,  // tWR, WRITE recovery time. Value range: [1, +∞)
    parameter integer T_RFC_PERIOD = 9,  // tRFC, AUTO REFRESH period. Value range: [1, +∞)
    parameter integer T_RCD_PERIOD = 3  // tRCD, ACTIVE-to-READ or WRITE delay.
    // Value range: [1, +∞)
) (
    // User signals
    input wire i_sdrc_rst_n,  // Reset signal, active low.
    input wire i_sdrc_clk,  // SDRAM controller working clock.
    input wire i_sdram_clk,  // SDRAM working clock.
    input wire i_sdrc_self_refresh,  // Self-refresh control (1: Enable self-refresh).
    input wire i_sdrc_power_down,  // Low power consumption control (1: Enable low-power
    // consumption).
    input wire i_sdrc_wr_n,  // Write enable, active low, one clock cycle of pulse width.
    input wire i_sdrc_rd_n,  // Read enable, active low, one clock cycle of pulse width.
    input wire [20:0] i_sdrc_addr,  // Address.
    input wire [3:0] i_sdrc_dqm,  // Data mask control.
    input wire [7:0] i_sdrc_data_len,  // Read/write data length.
    input wire [DATA_WIDTH-1:0] i_sdrc_data,  // Write data.
    output wire [DATA_WIDTH-1:0] o_sdrc_data,  // Read data.
    output wire o_sdrc_init_done,  // Power-on initialization indication (1: Done).
    output wire o_sdrc_busy_n,  // Idle/busy controller indication. User logic can issue
    // read/write operation when the controller is idle (1: Idle).
    output wire o_sdrc_rd_valid,  // Active data reading indication, active high and aligns
    // with valid data.
    output wire o_sdrc_wrd_ack,  // Read/write request response, high active. After receiving
    // the read/write request, the SDRAM controller sends the signal after 2 clock delays, 1 clock cycle width.

    // SDRAM signals
    output wire                  o_sdram_clk,    // SDRAM clock.
    output wire                  o_sdram_cke,    // SDRAM clock enable.
    output wire                  o_sdram_cs_n,   // SDRAM chip select.
    output wire                  o_sdram_cas_n,  // Column address strobe.
    output wire                  o_sdram_ras_n,  // Row address strobe.
    output wire                  o_sdram_wen_n,  // Write enable.
    output wire [           3:0] o_sdram_dqm,    // Data mask control.
    output wire [          10:0] o_sdram_addr,   // Address.
    output wire [BANK_WIDTH-1:0] o_sdram_ba,     // Bank address.
    inout  wire [DATA_WIDTH-1:0] io_sdram_dq     // Data.
);

  reg [ 0:0] sdram_cke;
  reg [ 0:0] sdram_cs_n;
  reg [ 0:0] sdram_cas_n;
  reg [ 0:0] sdram_ras_n;
  reg [ 0:0] sdram_we_n;
  reg [10:0] sdram_addr;

  // When the initialization delay, init_delay_done will be high.
  reg [ 0:0] init_delay_done;

  assign o_sdram_clk = i_sdram_clk;

  // Initialization delay (INITIALIZATION_WAIT_PERIOD_NS) after power up.
  `define INITIALIZATION_WAIT_PERIOD_CYCLES ((INITIALIZATION_WAIT_PERIOD_NS * CLOCK_FREQ_MHZ) / 1000)
  reg [31:0] init_delay_cycles;
  always @(posedge i_sdrc_clk) begin
    if (!i_sdrc_rst_n) begin
      // Rest
      init_delay_cycles <= 32'd0;
      init_delay_done   <= 1'b0;
    end else if (!init_delay_done && init_delay_cycles < `INITIALIZATION_WAIT_PERIOD_CYCLES - 2) begin
      init_delay_cycles <= init_delay_cycles + 32'd1;
    end else begin
      init_delay_done <= 1'b1;
    end
  end

  // States
  `define STATE_INIT 4'd0
  `define STATE_IDLE 4'd1
  `define STATE_CONFIG_PRECHARGE 4'd2
  `define STATE_CONFIG_AUTOREFRESH_1 4'd3
  `define STATE_CONFIG_AUTOREFRESH_2 4'd4
  `define STATE_CONFIG_SET_MODEREG 4'd5
  `define STATE_IDLE 4'd6
  `define STATE_AUTOREFRESH 4'd7

  // Commands
  `define CMD_NOP 3'b111
  `define CMD_PRECHARGE 3'b010
  `define CMD_AUTOREFRESH 3'b001
  `define CMD_SET_MODEREG 3'b000

  `define SDRAM_CMD {sdram_ras_n, sdram_cas_n, sdram_we_n}

  reg [ 3:0] sdrc_state;
  reg [31:0] cycle;
  reg [0:0] sdrc_auto_refresh;

  always @(posedge i_sdrc_clk) begin
    if (!i_sdrc_rst_n) begin
      sdrc_state <= `STATE_INIT;
      cycle <= 32'd0;
      `SDRAM_CMD <= `CMD_NOP;
    end else if (init_delay_done) begin
      // SDRAM initialization completes.
      `SDRAM_CMD <= `CMD_NOP;
      unique case (sdrc_state)
        `STATE_INIT: begin
          cycle <= 32'd0;
          sdrc_state <= `STATE_CONFIG_PRECHARGE;
          `SDRAM_CMD <= `CMD_PRECHARGE;
        end
        `STATE_CONFIG_PRECHARGE: begin
          if (cycle < T_RP_PERIOD - 1) begin
            cycle <= cycle + 1;
          end else begin
            sdrc_state <= `STATE_CONFIG_AUTOREFRESH_1;
            `SDRAM_CMD <= `CMD_AUTOREFRESH;
            cycle <= 0;
          end
        end
        `STATE_CONFIG_AUTOREFRESH_1: begin
          if (cycle < T_RFC_PERIOD - 1) begin
            cycle <= cycle + 1;
          end else begin
            sdrc_state <= `STATE_CONFIG_AUTOREFRESH_2;
            `SDRAM_CMD <= `CMD_AUTOREFRESH;
            cycle <= 0;
          end
        end
        `STATE_CONFIG_AUTOREFRESH_2: begin
          if (cycle < T_RFC_PERIOD - 1) begin
            cycle <= cycle + 1;
          end else begin
            sdrc_state <= `STATE_CONFIG_SET_MODEREG;
            `SDRAM_CMD <= `CMD_SET_MODEREG;
            sdram_addr[10:0] <= {
              4'b0, T_CL_PERIOD[2:0],  /*burst_mode=sequential*/ 1'b0,  /*burst_len=*/ 3'b0
            };
            cycle <= 0;
          end
        end
        `STATE_CONFIG_SET_MODEREG: begin
          if (cycle < T_MRD_PERIOD - 1) begin
            cycle <= cycle + 1;
          end else begin
            sdrc_state <= `STATE_IDLE;
            `SDRAM_CMD <= `CMD_NOP;
            cycle <= 0;
          end
        end

        // Initialization & configuration is done.
        `STATE_IDLE: begin
          if (sdrc_auto_refresh) begin
             `SDRAM_CMD <= `CMD_AUTOREFRESH;
             sdrc_state <= `STATE_AUTOREFRESH;
             cycle <= 32'd0;
          end
        end

        `STATE_AUTOREFRESH: begin
           if (cycle < T_RFC_PERIOD - 1) begin
             cycle <= cycle + 1;
           end else begin
             sdrc_state <= `STATE_IDLE;
             `SDRAM_CMD <= `CMD_NOP;
             cycle <= 0;
           end
        end
      endcase
    end else begin
      sdrc_state <= `STATE_INIT;
      cycle <= 32'd0;
    end
  end  // always @ (posedge i_sdrc_clk)

  // Generate auto-refresh signal.
  always @(posedge i_sdrc_clk) begin
    if (!i_sdrc_rst_n) begin
      sdrc_auto_refresh <= 1'b0;
    end else begin
      // Generate auto-refresh signal after initialization.
      if (init_delay_done) begin
      end
    end
  end

`ifdef FORMAL

  reg [31:0] f_cycle_count;
  reg [ 0:0] f_past_valid;

  initial begin
    assume (f_cycle_count == 32'd0);
    assume (f_past_valid == 1'b0);
    assume (i_sdrc_rst_n == 1'b0);
  end

  always @(posedge i_sdrc_clk) f_past_valid <= 1'b1;
  always @(posedge i_sdrc_clk) if (f_past_valid) assume (i_sdrc_rst_n == 1'b1);

  // Used to check clock periods of every state.
  always @(posedge i_sdrc_clk) begin
    if (!i_sdrc_rst_n) f_cycle_count <= 32'd0;
    else f_cycle_count <= f_cycle_count + 1;
  end

  // Checks that all states are reachable.
  always @(*) cover (!i_sdrc_rst_n && sdrc_state == `STATE_INIT);
  always @(*) cover (!i_sdrc_rst_n && sdrc_state == `STATE_CONFIG_PRECHARGE);
  always @(*) cover (!i_sdrc_rst_n && sdrc_state == `STATE_CONFIG_AUTOREFRESH_1);
  always @(*) cover (!i_sdrc_rst_n && sdrc_state == `STATE_CONFIG_AUTOREFRESH_2);
  always @(*) cover (!i_sdrc_rst_n && sdrc_state == `STATE_CONFIG_SET_MODEREG);
  always @(*) cover (!i_sdrc_rst_n && sdrc_state == `STATE_IDLE);

  always @(posedge i_sdrc_clk) begin
    if (f_past_valid) begin
      // Checks that the initialization wait time.
      if (!init_delay_done) begin
        assert (init_delay_cycles <= `INITIALIZATION_WAIT_PERIOD_CYCLES - 2);
        assert (init_delay_cycles == f_cycle_count);
      end
      if ($rose(init_delay_done)) begin
        assert (init_delay_cycles == `INITIALIZATION_WAIT_PERIOD_CYCLES - 2);
        assert (f_cycle_count == `INITIALIZATION_WAIT_PERIOD_CYCLES - 1);
      end
      if (init_delay_done) assert (init_delay_cycles == `INITIALIZATION_WAIT_PERIOD_CYCLES - 2);

       // Check the duration of each state.
       casex ({ $past(sdrc_state), sdrc_state })
         { `STATE_INIT, `STATE_CONFIG_PRECHARGE }:
           assert(f_cycle_count == `INITIALIZATION_WAIT_PERIOD_CYCLES);
         { `STATE_CONFIG_PRECHARGE, `STATE_CONFIG_AUTOREFRESH_1 }:
           assert(f_cycle_count == `INITIALIZATION_WAIT_PERIOD_CYCLES + T_RP_PERIOD);
         { `STATE_CONFIG_AUTOREFRESH_1, `STATE_CONFIG_AUTOREFRESH_2 }:
           assert(f_cycle_count == `INITIALIZATION_WAIT_PERIOD_CYCLES + T_RP_PERIOD + T_RFC_PERIOD);
         { `STATE_CONFIG_AUTOREFRESH_2, `STATE_CONFIG_SET_MODEREG }:
           assert(f_cycle_count == `INITIALIZATION_WAIT_PERIOD_CYCLES + T_RP_PERIOD + T_RFC_PERIOD + T_RFC_PERIOD);
         { `STATE_CONFIG_SET_MODEREG, `STATE_IDLE }:
           assert(f_cycle_count == `INITIALIZATION_WAIT_PERIOD_CYCLES + T_RP_PERIOD + T_RFC_PERIOD + T_RFC_PERIOD + T_MRD_PERIOD);
       endcase
    end
  end // always @ (posedge i_sdrc_clk)


  // Test that each command lasts for 1 cycle.
   always @(posedge i_sdrc_clk) begin
     if (f_past_valid) begin
       if (cycle == 0) begin
         case (sdrc_state)
           `STATE_INIT:
             assert(`SDRAM_CMD == `CMD_NOP);
           `STATE_CONFIG_PRECHARGE:
             assert(`SDRAM_CMD == `CMD_PRECHARGE);
           `STATE_CONFIG_AUTOREFRESH_1:
             assert(`SDRAM_CMD == `CMD_AUTOREFRESH);
           `STATE_CONFIG_AUTOREFRESH_2:
             assert(`SDRAM_CMD == `CMD_AUTOREFRESH);
           `STATE_CONFIG_SET_MODEREG: begin
             assert(`SDRAM_CMD == `CMD_SET_MODEREG);
             assert(sdram_addr[10:0] == { 4'b0, T_CL_PERIOD[2:0],  /*burst_mode=sequential*/ 1'b0,  /*burst_len=*/ 3'b0 });
            end
         endcase // case (sdrc_state)
       end else begin // if (cycle == 0)
         assert(`SDRAM_CMD == `CMD_NOP);
       end
     end
   end

`endif  //  `ifdef FORMAL

endmodule  // sdram_ctrl
