`default_nettype none
`timescale 1 ns / 1 ps

// Open source alternative for Gowin SDRAM Controller IP
// (https://cdn.gowinsemi.com.cn/IPUG279E.pdf).
// Based on https://github.com/nand2mario/sdram-tang-nano-20k/blob/main/src/sdram.v
//
// Address layout for i_sdrc_addr (BANK_WIDTH + ROW_WIDTH + COLUMN_WIDTH bits):
//   [BANK_WIDTH+ROW_WIDTH+COLUMN_WIDTH-1 : ROW_WIDTH+COLUMN_WIDTH]  = bank
//   [ROW_WIDTH+COLUMN_WIDTH-1            : COLUMN_WIDTH]             = row
//   [COLUMN_WIDTH-1                      : 0]                        = column

module sdram_ctrl #(
    parameter integer DATA_WIDTH              = 32,      // {8,16,32,64}
    parameter integer BANK_WIDTH              = 2,       // {1,2}
    parameter integer ROW_WIDTH               = 11,      // {11,12,13,14}
    parameter integer COLUMN_WIDTH            = 8,       // {8,9,10,11,12}
    parameter integer REFRESH_PERIOD_NS       = 64_000_000,
    parameter integer REFRESH_TIMES           = 4096,
    parameter integer CLOCK_FREQ_MHZ          = 100,
    parameter integer INITIALIZATION_WAIT_PERIOD_NS = 200_000,
    parameter integer T_CL_PERIOD            = 3,       // CAS latency {1,2,3}
    parameter integer T_RP_PERIOD            = 3,       // tRP: PRECHARGE period
    parameter integer T_MRD_PERIOD           = 3,       // tMRD: mode-register to ACTIVE/REFRESH
    parameter integer T_WR_PERIOD            = 3,       // tWR: write recovery
    parameter integer T_RFC_PERIOD           = 9,       // tRFC: AUTO REFRESH period
    parameter integer T_RCD_PERIOD           = 3        // tRCD: ACTIVE-to-READ/WRITE delay
) (
    // User signals
    input  wire                   i_sdrc_rst_n,
    input  wire                   i_sdrc_clk,
    input  wire                   i_sdram_clk,
    input  wire                   i_sdrc_self_refresh,
    input  wire                   i_sdrc_power_down,
    input  wire                   i_sdrc_wr_n,
    input  wire                   i_sdrc_rd_n,
    input  wire [20:0]            i_sdrc_addr,
    input  wire [ 3:0]            i_sdrc_dqm,
    input  wire [ 7:0]            i_sdrc_data_len,
    input  wire [DATA_WIDTH-1:0]  i_sdrc_data,
    output wire [DATA_WIDTH-1:0]  o_sdrc_data,
    output wire                   o_sdrc_init_done,
    output wire                   o_sdrc_busy_n,
    output wire                   o_sdrc_rd_valid,
    output wire                   o_sdrc_wrd_ack,

    // SDRAM signals
    output wire                   o_sdram_clk,
    output wire                   o_sdram_cke,
    output wire                   o_sdram_cs_n,
    output wire                   o_sdram_cas_n,
    output wire                   o_sdram_ras_n,
    output wire                   o_sdram_wen_n,
    output wire [ 3:0]            o_sdram_dqm,
    output wire [10:0]            o_sdram_addr,
    output wire [BANK_WIDTH-1:0]  o_sdram_ba,
    inout  wire [DATA_WIDTH-1:0]  io_sdram_dq
);

  // ── Derived timing constants ───────────────────────────────────────────────
  localparam INIT_CYCLES     = (INITIALIZATION_WAIT_PERIOD_NS * CLOCK_FREQ_MHZ) / 1000;
  localparam REFRESH_INTERVAL = (REFRESH_PERIOD_NS / REFRESH_TIMES * CLOCK_FREQ_MHZ) / 1000;

  // ── State encoding ─────────────────────────────────────────────────────────
  localparam [3:0]
    STATE_INIT              = 4'd0,
    STATE_CONFIG_PRECHARGE  = 4'd1,
    STATE_CONFIG_AR1        = 4'd2,
    STATE_CONFIG_AR2        = 4'd3,
    STATE_CONFIG_SET_MODEREG= 4'd4,
    STATE_IDLE              = 4'd5,
    STATE_AUTOREFRESH       = 4'd6,
    STATE_ACTIVE            = 4'd7,
    STATE_READ              = 4'd8,
    STATE_CAS_LATENCY       = 4'd9,
    STATE_WRITE             = 4'd10,
    STATE_WRITE_RECOVERY    = 4'd11;

  // ── SDRAM commands: {RAS_n, CAS_n, WE_n} ──────────────────────────────────
  localparam [2:0]
    CMD_NOP        = 3'b111,
    CMD_PRECHARGE  = 3'b010,
    CMD_AUTOREFRESH= 3'b001,
    CMD_SET_MODEREG= 3'b000,
    CMD_ACTIVE     = 3'b011,
    CMD_READ       = 3'b101,
    CMD_WRITE      = 3'b100;

  // ── Address field extraction ───────────────────────────────────────────────
  localparam ADDR_WIDTH = BANK_WIDTH + ROW_WIDTH + COLUMN_WIDTH;

  wire [BANK_WIDTH-1:0]   addr_bank = i_sdrc_addr[ADDR_WIDTH-1 : ROW_WIDTH+COLUMN_WIDTH];
  wire [ROW_WIDTH-1:0]    addr_row  = i_sdrc_addr[ROW_WIDTH+COLUMN_WIDTH-1 : COLUMN_WIDTH];
  wire [COLUMN_WIDTH-1:0] addr_col  = i_sdrc_addr[COLUMN_WIDTH-1 : 0];

  // ── Internal registers ─────────────────────────────────────────────────────
  reg [3:0]          sdrc_state;
  reg [31:0]         cycle;

  reg                sdram_cke;
  reg                sdram_cs_n;
  reg                sdram_ras_n;
  reg                sdram_cas_n;
  reg                sdram_we_n;
  reg [10:0]         sdram_addr;
  reg [BANK_WIDTH-1:0] sdram_ba;
  reg [3:0]          sdram_dqm;

  // Data bus tri-state
  reg [DATA_WIDTH-1:0] dq_out;
  reg                  dq_oe;     // 1 = drive, 0 = high-Z
  reg [DATA_WIDTH-1:0] rd_data;
  reg                  rd_valid;

  // Latched request
  reg [BANK_WIDTH-1:0]   lat_bank;
  reg [ROW_WIDTH-1:0]    lat_row;
  reg [COLUMN_WIDTH-1:0] lat_col;
  reg [3:0]              lat_dqm;
  reg [DATA_WIDTH-1:0]   lat_data;
  reg                    lat_is_write;

  // ── Initialization delay ───────────────────────────────────────────────────
  reg [31:0] init_delay_cycles;
  reg        init_delay_done;

  always @(posedge i_sdrc_clk) begin
    if (!i_sdrc_rst_n) begin
      init_delay_cycles <= 32'd0;
      init_delay_done   <= 1'b0;
    end else if (!init_delay_done) begin
      if (init_delay_cycles < INIT_CYCLES - 2)
        init_delay_cycles <= init_delay_cycles + 1;
      else
        init_delay_done <= 1'b1;
    end
  end

  // ── Auto-refresh counter ───────────────────────────────────────────────────
  reg [31:0] refresh_counter;
  reg        auto_refresh_req;

  always @(posedge i_sdrc_clk) begin
    if (!i_sdrc_rst_n || !init_delay_done) begin
      refresh_counter  <= 32'd0;
      auto_refresh_req <= 1'b0;
    end else begin
      if (sdrc_state == STATE_AUTOREFRESH && cycle == 0) begin
        // Refresh is being serviced — clear the request and restart counter.
        auto_refresh_req <= 1'b0;
        refresh_counter  <= 32'd0;
      end else if (refresh_counter >= REFRESH_INTERVAL - 1) begin
        auto_refresh_req <= 1'b1;
        refresh_counter  <= 32'd0;
      end else begin
        refresh_counter <= refresh_counter + 1;
      end
    end
  end

  // ── Main FSM ───────────────────────────────────────────────────────────────
  always @(posedge i_sdrc_clk) begin
    if (!i_sdrc_rst_n) begin
      sdrc_state  <= STATE_INIT;
      cycle       <= 32'd0;
      sdram_cke   <= 1'b1;
      sdram_cs_n  <= 1'b0;
      {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_NOP;
      sdram_addr  <= 11'd0;
      sdram_ba    <= {BANK_WIDTH{1'b0}};
      sdram_dqm   <= 4'hF;
      dq_oe       <= 1'b0;
      dq_out      <= {DATA_WIDTH{1'b0}};
      rd_valid    <= 1'b0;
      lat_is_write<= 1'b0;
    end else begin
      // Default each cycle: NOP, no read-valid pulse.
      {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_NOP;
      rd_valid <= 1'b0;

      if (!init_delay_done) begin
        sdrc_state <= STATE_INIT;
        cycle      <= 32'd0;
      end else begin
        case (sdrc_state)

          // ── Wait for init delay, then kick off PRECHARGE ─────────────────
          STATE_INIT: begin
            cycle      <= 32'd0;
            sdrc_state <= STATE_CONFIG_PRECHARGE;
            {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_PRECHARGE;
            sdram_addr[10] <= 1'b1;  // A10 = 1: precharge all banks
          end

          // ── PRECHARGE: wait tRP ───────────────────────────────────────────
          STATE_CONFIG_PRECHARGE: begin
            if (cycle < T_RP_PERIOD - 1) begin
              cycle <= cycle + 1;
            end else begin
              cycle      <= 32'd0;
              sdrc_state <= STATE_CONFIG_AR1;
              {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_AUTOREFRESH;
            end
          end

          // ── First AUTO REFRESH: wait tRFC ────────────────────────────────
          STATE_CONFIG_AR1: begin
            if (cycle < T_RFC_PERIOD - 1) begin
              cycle <= cycle + 1;
            end else begin
              cycle      <= 32'd0;
              sdrc_state <= STATE_CONFIG_AR2;
              {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_AUTOREFRESH;
            end
          end

          // ── Second AUTO REFRESH: wait tRFC ───────────────────────────────
          STATE_CONFIG_AR2: begin
            if (cycle < T_RFC_PERIOD - 1) begin
              cycle <= cycle + 1;
            end else begin
              cycle      <= 32'd0;
              sdrc_state <= STATE_CONFIG_SET_MODEREG;
              {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_SET_MODEREG;
              sdram_ba   <= {BANK_WIDTH{1'b0}};
              // Mode register: CAS latency, sequential burst, burst length = 1
              sdram_addr <= {4'b0000, T_CL_PERIOD[2:0], 1'b0, 3'b000};
            end
          end

          // ── LOAD MODE REGISTER: wait tMRD ────────────────────────────────
          STATE_CONFIG_SET_MODEREG: begin
            if (cycle < T_MRD_PERIOD - 1) begin
              cycle <= cycle + 1;
            end else begin
              cycle      <= 32'd0;
              sdrc_state <= STATE_IDLE;
            end
          end

          // ── IDLE: accept refresh, read, or write requests ─────────────────
          STATE_IDLE: begin
            cycle <= 32'd0;
            if (auto_refresh_req) begin
              sdrc_state <= STATE_AUTOREFRESH;
              {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_AUTOREFRESH;
            end else if (!i_sdrc_rd_n || !i_sdrc_wr_n) begin
              // Latch request
              lat_bank     <= addr_bank;
              lat_row      <= addr_row;
              lat_col      <= addr_col;
              lat_dqm      <= i_sdrc_dqm;
              lat_data     <= i_sdrc_data;
              lat_is_write <= !i_sdrc_wr_n;
              // Issue ACTIVE
              sdrc_state   <= STATE_ACTIVE;
              {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_ACTIVE;
              sdram_ba     <= addr_bank;
              sdram_addr   <= {{(11-ROW_WIDTH){1'b0}}, addr_row};
            end
          end

          // ── AUTO REFRESH: wait tRFC ───────────────────────────────────────
          STATE_AUTOREFRESH: begin
            if (cycle < T_RFC_PERIOD - 1) begin
              cycle <= cycle + 1;
            end else begin
              cycle      <= 32'd0;
              sdrc_state <= STATE_IDLE;
            end
          end

          // ── ACTIVE: wait tRCD, then issue READ or WRITE ───────────────────
          STATE_ACTIVE: begin
            if (cycle < T_RCD_PERIOD - 1) begin
              cycle <= cycle + 1;
            end else begin
              cycle    <= 32'd0;
              sdram_ba <= lat_bank;
              // A10 = 1: auto-precharge after burst
              sdram_addr <= {1'b1, {(10-COLUMN_WIDTH){1'b0}}, lat_col};
              sdram_dqm  <= lat_dqm;
              if (lat_is_write) begin
                sdrc_state <= STATE_WRITE;
                {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_WRITE;
                dq_out <= lat_data;
                dq_oe  <= 1'b1;
              end else begin
                sdrc_state <= STATE_READ;
                {sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_READ;
              end
            end
          end

          // ── READ: CAS issued, now wait CAS latency ────────────────────────
          STATE_READ: begin
            sdram_dqm  <= 4'h0;  // unmask during read
            sdrc_state <= STATE_CAS_LATENCY;
            cycle      <= 32'd0;
          end

          // ── CAS LATENCY: capture data when it appears ─────────────────────
          STATE_CAS_LATENCY: begin
            if (cycle < T_CL_PERIOD - 1) begin
              cycle <= cycle + 1;
            end else begin
              // Data is valid on io_sdram_dq this cycle.
              rd_valid   <= 1'b1;
              cycle      <= 32'd0;
              sdrc_state <= STATE_IDLE;
              sdram_dqm  <= 4'hF;
            end
          end

          // ── WRITE: data driven, auto-precharge will close the row ─────────
          STATE_WRITE: begin
            dq_oe      <= 1'b0;   // deassert after first write cycle
            sdrc_state <= STATE_WRITE_RECOVERY;
            cycle      <= 32'd0;
          end

          // ── WRITE RECOVERY: wait tWR before accepting new requests ────────
          STATE_WRITE_RECOVERY: begin
            if (cycle < T_WR_PERIOD - 1) begin
              cycle <= cycle + 1;
            end else begin
              cycle      <= 32'd0;
              sdrc_state <= STATE_IDLE;
            end
          end

          default: sdrc_state <= STATE_IDLE;
        endcase
      end
    end
  end

  // ── Capture read data from io_sdram_dq ────────────────────────────────────
  // rd_valid is asserted the same cycle data appears; register it one extra
  // cycle so o_sdrc_data is stable when o_sdrc_rd_valid is high.
  always @(posedge i_sdrc_clk) begin
    if (rd_valid) rd_data <= io_sdram_dq;
  end

  // ── wrd_ack: 2-cycle shift register from request detection ────────────────
  reg [1:0] ack_sr;
  always @(posedge i_sdrc_clk) begin
    if (!i_sdrc_rst_n)
      ack_sr <= 2'b00;
    else
      ack_sr <= {ack_sr[0], (!i_sdrc_rd_n || !i_sdrc_wr_n) && (sdrc_state == STATE_IDLE)};
  end

  // ── Output assignments ────────────────────────────────────────────────────
  assign o_sdram_clk   = i_sdram_clk;
  assign o_sdram_cke   = sdram_cke;
  assign o_sdram_cs_n  = sdram_cs_n;
  assign o_sdram_ras_n = sdram_ras_n;
  assign o_sdram_cas_n = sdram_cas_n;
  assign o_sdram_wen_n = sdram_we_n;
  assign o_sdram_dqm   = sdram_dqm;
  assign o_sdram_addr  = sdram_addr;
  assign o_sdram_ba    = sdram_ba;

  assign io_sdram_dq   = dq_oe ? dq_out : {DATA_WIDTH{1'bz}};

  assign o_sdrc_data      = rd_data;
  assign o_sdrc_rd_valid  = rd_valid;
  assign o_sdrc_wrd_ack   = ack_sr[1];
  assign o_sdrc_busy_n    = (sdrc_state == STATE_IDLE);
  assign o_sdrc_init_done = (sdrc_state != STATE_INIT         &&
                             sdrc_state != STATE_CONFIG_PRECHARGE &&
                             sdrc_state != STATE_CONFIG_AR1    &&
                             sdrc_state != STATE_CONFIG_AR2    &&
                             sdrc_state != STATE_CONFIG_SET_MODEREG);

`ifdef FORMAL
  reg [31:0] f_cycle_count;
  reg        f_past_valid;

  initial begin
    assume (f_cycle_count == 32'd0);
    assume (f_past_valid  == 1'b0);
    assume (i_sdrc_rst_n  == 1'b0);
  end

  always @(posedge i_sdrc_clk) f_past_valid <= 1'b1;
  always @(posedge i_sdrc_clk) if (f_past_valid) assume (i_sdrc_rst_n == 1'b1);

  always @(posedge i_sdrc_clk) begin
    if (!i_sdrc_rst_n) f_cycle_count <= 32'd0;
    else               f_cycle_count <= f_cycle_count + 1;
  end

  // ── Initialisation timing ──────────────────────────────────────────────────
  always @(posedge i_sdrc_clk) begin
    if (f_past_valid) begin
      if (!init_delay_done) begin
        assert (init_delay_cycles <= INIT_CYCLES - 2);
        assert (init_delay_cycles == f_cycle_count);
      end
      if ($rose(init_delay_done)) begin
        assert (init_delay_cycles == INIT_CYCLES - 2);
        assert (f_cycle_count     == INIT_CYCLES - 1);
      end
      if (init_delay_done)
        assert (init_delay_cycles == INIT_CYCLES - 2);
    end
  end

  // ── State-transition timing ────────────────────────────────────────────────
  always @(posedge i_sdrc_clk) begin
    if (f_past_valid) begin
      casex ({$past(sdrc_state), sdrc_state})
        {STATE_INIT,             STATE_CONFIG_PRECHARGE}:
          assert (f_cycle_count == INIT_CYCLES);
        {STATE_CONFIG_PRECHARGE, STATE_CONFIG_AR1}:
          assert (f_cycle_count == INIT_CYCLES + T_RP_PERIOD);
        {STATE_CONFIG_AR1,       STATE_CONFIG_AR2}:
          assert (f_cycle_count == INIT_CYCLES + T_RP_PERIOD + T_RFC_PERIOD);
        {STATE_CONFIG_AR2,       STATE_CONFIG_SET_MODEREG}:
          assert (f_cycle_count == INIT_CYCLES + T_RP_PERIOD + T_RFC_PERIOD * 2);
        {STATE_CONFIG_SET_MODEREG, STATE_IDLE}:
          assert (f_cycle_count == INIT_CYCLES + T_RP_PERIOD + T_RFC_PERIOD * 2 + T_MRD_PERIOD);
      endcase
    end
  end

  // ── Command integrity ──────────────────────────────────────────────────────
  always @(posedge i_sdrc_clk) begin
    if (f_past_valid) begin
      if (cycle == 0) begin
        case (sdrc_state)
          STATE_CONFIG_PRECHARGE:   assert ({sdram_ras_n,sdram_cas_n,sdram_we_n} == CMD_PRECHARGE);
          STATE_CONFIG_AR1:         assert ({sdram_ras_n,sdram_cas_n,sdram_we_n} == CMD_AUTOREFRESH);
          STATE_CONFIG_AR2:         assert ({sdram_ras_n,sdram_cas_n,sdram_we_n} == CMD_AUTOREFRESH);
          STATE_CONFIG_SET_MODEREG: begin
            assert ({sdram_ras_n,sdram_cas_n,sdram_we_n} == CMD_SET_MODEREG);
            assert (sdram_addr == {4'b0000, T_CL_PERIOD[2:0], 1'b0, 3'b000});
          end
        endcase
      end
    end
  end

  // ── Invariants ─────────────────────────────────────────────────────────────
  always @(*) begin
    if (f_past_valid) begin
      // rd_valid only fires when leaving CAS_LATENCY
      if (rd_valid) assert (sdrc_state == STATE_IDLE);
      // dq_oe only asserted during WRITE states
      if (dq_oe)    assert (sdrc_state == STATE_WRITE || sdrc_state == STATE_ACTIVE);
      // busy_n only when IDLE
      if (o_sdrc_busy_n) assert (sdrc_state == STATE_IDLE);
    end
  end

  // ── Cover: all states reachable ───────────────────────────────────────────
  always @(*) cover (i_sdrc_rst_n && sdrc_state == STATE_INIT);
  always @(*) cover (i_sdrc_rst_n && sdrc_state == STATE_CONFIG_PRECHARGE);
  always @(*) cover (i_sdrc_rst_n && sdrc_state == STATE_CONFIG_AR1);
  always @(*) cover (i_sdrc_rst_n && sdrc_state == STATE_CONFIG_AR2);
  always @(*) cover (i_sdrc_rst_n && sdrc_state == STATE_CONFIG_SET_MODEREG);
  always @(*) cover (i_sdrc_rst_n && sdrc_state == STATE_IDLE);
  always @(*) cover (i_sdrc_rst_n && sdrc_state == STATE_AUTOREFRESH);
  always @(*) cover (i_sdrc_rst_n && sdrc_state == STATE_ACTIVE);
  always @(*) cover (i_sdrc_rst_n && sdrc_state == STATE_READ);
  always @(*) cover (i_sdrc_rst_n && sdrc_state == STATE_CAS_LATENCY);
  always @(*) cover (i_sdrc_rst_n && sdrc_state == STATE_WRITE);
  always @(*) cover (i_sdrc_rst_n && sdrc_state == STATE_WRITE_RECOVERY);
  always @(*) cover (i_sdrc_rst_n && o_sdrc_rd_valid);
  always @(*) cover (i_sdrc_rst_n && o_sdrc_wrd_ack);

`endif  // FORMAL

endmodule  // sdram_ctrl
