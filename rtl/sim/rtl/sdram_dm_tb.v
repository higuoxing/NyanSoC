`timescale 1 ns / 1 ps
/* sdram_dm_tb.v — unit-test the SDRAM direct-map FSMs in top.v
 *
 * Instantiates a behavioural SDRAM model alongside the same FSM logic
 * used in top.v so we can observe every handshake cycle-by-cycle.
 *
 * The behavioural model honours:
 *   busy_n  = 1 only when idle (no ongoing transaction, no refresh)
 *   rd_valid fires after CAS-latency cycles
 *   wrd_ack fires 2 cycles after command acceptance (matching sdram_gw2ar)
 *   Auto-refresh fires periodically to exercise the race condition
 */

module sdram_dm_tb;

  // ── Clock / reset ─────────────────────────────────────────────────────────
  reg clk, rst_n;
  initial clk = 0;
  always #5 clk = ~clk;   // 100 MHz (just for simulation speed)

  // ── CPU-side signals (driven by this testbench) ───────────────────────────
  reg  [31:0] cpu_raddr;
  reg         cpu_rvalid;
  wire [31:0] cpu_rdata;
  wire        cpu_rready;

  reg  [31:0] cpu_waddr;
  reg  [31:0] cpu_wdata;
  reg  [ 3:0] cpu_wstrb;
  reg         cpu_wvalid;
  wire        cpu_wready;

  // ── Behavioural SDRAM model ────────────────────────────────────────────────
  // Timing constants (short for simulation)
  localparam CAS_LAT    = 3;
  localparam ACT_LAT    = 2;   // tRCD
  localparam WR_REC     = 2;   // tWR
  localparam REFRESH_IV = 40;  // refresh every 40 cycles (aggressive for testing)

  reg         sdram_busy_n;
  reg         sdram_rd_valid;
  reg  [31:0] sdram_data_out;
  reg         sdram_wrd_ack;

  reg  [31:0] sdram_mem [0:4095];  // small model memory

  // Signals driven by the FSM under test
  wire        sdram_rd_n_in;
  wire        sdram_wr_n_in;
  wire [20:0] sdram_addr_in;
  wire [31:0] sdram_data_in;
  wire [ 3:0] sdram_dqm_in;

  // SDRAM model FSM
  localparam [2:0]
    SM_IDLE    = 3'd0,
    SM_ACTIVE  = 3'd1,
    SM_RW      = 3'd2,
    SM_CAS     = 3'd3,
    SM_WRREC   = 3'd4,
    SM_REFRESH = 3'd5;

  reg [2:0] sm_state;
  reg [3:0] sm_cnt;
  reg       sm_is_write;
  reg [20:0] sm_addr;
  reg [31:0] sm_wdata;
  reg [3:0]  sm_dqm;
  reg [5:0]  refresh_ctr;
  reg        refresh_req;
  reg [1:0]  ack_sr;  // 2-cycle shift for wrd_ack (matches sdram_gw2ar)

  integer i;
  initial begin
    for (i = 0; i < 4096; i = i + 1) sdram_mem[i] = 32'hDEAD0000 | i;
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      sm_state     <= SM_IDLE;
      sm_cnt       <= 0;
      sdram_busy_n <= 1'b1;
      sdram_rd_valid <= 1'b0;
      sdram_wrd_ack  <= 1'b0;
      refresh_ctr  <= 0;
      refresh_req  <= 0;
      ack_sr       <= 2'b00;
    end else begin
      sdram_rd_valid <= 1'b0;
      // wrd_ack: 2-cycle shift of (command seen while IDLE)
      ack_sr <= {ack_sr[0], (!sdram_rd_n_in || !sdram_wr_n_in) && (sm_state == SM_IDLE) && !refresh_req};
      sdram_wrd_ack <= ack_sr[1];

      // Refresh counter
      if (refresh_ctr == REFRESH_IV - 1) begin
        refresh_ctr <= 0;
        refresh_req <= 1'b1;
      end else begin
        refresh_ctr <= refresh_ctr + 1;
      end

      case (sm_state)
        SM_IDLE: begin
          sdram_busy_n <= 1'b1;
          if (refresh_req) begin
            refresh_req  <= 1'b0;
            sdram_busy_n <= 1'b0;
            sm_cnt       <= REFRESH_IV[3:0] / 2;
            sm_state     <= SM_REFRESH;
          end else if (!sdram_rd_n_in || !sdram_wr_n_in) begin
            // Accept command — busy_n goes low next cycle.
            sm_is_write  <= !sdram_wr_n_in;
            sm_addr      <= sdram_addr_in;
            sm_wdata     <= sdram_data_in;
            sm_dqm       <= sdram_dqm_in;
            sdram_busy_n <= 1'b0;
            // wrd_ack: 2-cycle shift register (matches sdram_gw2ar ack_sr[1]).
            // Cycle 0: command accepted (this cycle), ack_sr[0]=1
            // Cycle 1: busy_n=0, FSM moves ISSUE→WAIT, ack_sr[1]=1 → wrd_ack fires
            // We model this as a 1-cycle delayed pulse after this state.
            sm_cnt       <= ACT_LAT - 1;
            sm_state     <= SM_ACTIVE;
          end
        end
        SM_REFRESH: begin
          if (sm_cnt == 0) begin
            sdram_busy_n <= 1'b1;
            sm_state     <= SM_IDLE;
          end else sm_cnt <= sm_cnt - 1;
        end
        SM_ACTIVE: begin
          if (sm_cnt == 0) begin
            sm_state <= SM_RW;
            sm_cnt   <= 0;
          end else sm_cnt <= sm_cnt - 1;
        end
        SM_RW: begin
          if (sm_is_write) begin
            // Apply byte enables
            if (!sm_dqm[0]) sdram_mem[sm_addr[11:0]][ 7: 0] <= sm_wdata[ 7: 0];
            if (!sm_dqm[1]) sdram_mem[sm_addr[11:0]][15: 8] <= sm_wdata[15: 8];
            if (!sm_dqm[2]) sdram_mem[sm_addr[11:0]][23:16] <= sm_wdata[23:16];
            if (!sm_dqm[3]) sdram_mem[sm_addr[11:0]][31:24] <= sm_wdata[31:24];
            sm_cnt   <= WR_REC - 1;
            sm_state <= SM_WRREC;
          end else begin
            sm_cnt   <= CAS_LAT - 1;
            sm_state <= SM_CAS;
          end
        end
        SM_CAS: begin
          if (sm_cnt == 0) begin
            sdram_data_out <= sdram_mem[sm_addr[11:0]];
            sdram_rd_valid <= 1'b1;
            sdram_busy_n   <= 1'b1;
            sm_state       <= SM_IDLE;
          end else sm_cnt <= sm_cnt - 1;
        end
        SM_WRREC: begin
          if (sm_cnt == 0) begin
            sdram_busy_n <= 1'b1;
            sm_state     <= SM_IDLE;
          end else sm_cnt <= sm_cnt - 1;
        end
        default: sm_state <= SM_IDLE;
      endcase
    end
  end

  // ── FSM under test (copied verbatim from top.v) ───────────────────────────
  // Direct-map region decode (addr[31]=1)
  wire sdram_dm_r = cpu_rvalid && cpu_raddr[31];
  wire sdram_dm_w = cpu_wvalid && cpu_waddr[31];
  wire bus_rvalid_dm = cpu_rvalid;

  wire [20:0] sdram_dm_raddr_w = cpu_raddr[22:2];
  wire [20:0] sdram_dm_waddr   = cpu_waddr[22:2];

  localparam [1:0] SDRDM_IDLE  = 2'd0,
                   SDRDM_ISSUE = 2'd1,
                   SDRDM_WAIT  = 2'd2,
                   SDRDM_DONE  = 2'd3;

  localparam [1:0] SDWDM_IDLE  = 2'd0,
                   SDWDM_ISSUE = 2'd1,
                   SDWDM_WAIT  = 2'd2,
                   SDWDM_DONE  = 2'd3;

  reg [1:0]  sdrdm_r_state;
  reg [31:0] sdrdm_rdata_latch;
  reg [20:0] sdrdm_raddr_lat;
  reg [1:0]  sdrdm_w_state;

  reg [20:0] sdrdm_waddr_lat;
  reg [31:0] sdrdm_wdata_lat;
  reg [ 3:0] sdrdm_dqm_lat;

  // Latch addresses when entering ISSUE
  always @(posedge clk) begin
    if (sdrdm_r_state == SDRDM_IDLE && sdram_dm_r && bus_rvalid_dm)
      sdrdm_raddr_lat <= cpu_raddr[22:2];
    if (sdrdm_w_state == SDWDM_IDLE && sdram_dm_w) begin
      sdrdm_waddr_lat <= sdram_dm_waddr;
      sdrdm_wdata_lat <= cpu_wdata;
      sdrdm_dqm_lat   <= ~cpu_wstrb;
    end
  end

  // Read FSM
  always @(posedge clk) begin
    if (!rst_n) begin
      sdrdm_r_state    <= SDRDM_IDLE;
      sdrdm_rdata_latch<= 32'd0;
      sdrdm_raddr_lat  <= 21'd0;
    end else begin
      case (sdrdm_r_state)
        SDRDM_IDLE:  if (sdram_dm_r && bus_rvalid_dm) begin
                       sdrdm_raddr_lat <= cpu_raddr[22:2];
                       sdrdm_r_state   <= SDRDM_ISSUE;
                     end
        SDRDM_ISSUE: if (sdram_wrd_ack) sdrdm_r_state <= SDRDM_WAIT;
        SDRDM_WAIT:  if (sdram_rd_valid) begin
                       sdrdm_rdata_latch <= sdram_data_out;
                       sdrdm_r_state     <= SDRDM_DONE;
                     end
        SDRDM_DONE:  sdrdm_r_state <= SDRDM_IDLE;
        default:     sdrdm_r_state <= SDRDM_IDLE;
      endcase
    end
  end

  // Write FSM
  always @(posedge clk) begin
    if (!rst_n) begin
      sdrdm_w_state <= SDWDM_IDLE;
    end else begin
      case (sdrdm_w_state)
        SDWDM_IDLE:  if (sdram_dm_w)    sdrdm_w_state <= SDWDM_ISSUE;
        SDWDM_ISSUE: if (sdram_wrd_ack) sdrdm_w_state <= SDWDM_WAIT;
        SDWDM_WAIT:  if (sdram_busy_n)  sdrdm_w_state <= SDWDM_DONE;
        SDWDM_DONE:  sdrdm_w_state <= SDWDM_IDLE;
        default:     sdrdm_w_state <= SDWDM_IDLE;
      endcase
    end
  end

  // Controller input mux
  reg  [20:0] sdram_addr_in_r;
  reg  [31:0] sdram_data_in_r;
  reg  [ 3:0] sdram_dqm_in_r;
  reg         sdram_wr_n_in_r;
  reg         sdram_rd_n_in_r;

  always @(*) begin
    if (sdrdm_r_state == SDRDM_ISSUE) begin
      sdram_addr_in_r = sdrdm_raddr_lat;  // hold rd_n=0 until wrd_ack
      sdram_data_in_r = 32'd0;
      sdram_dqm_in_r  = 4'b0000;
      sdram_wr_n_in_r = 1'b1;
      sdram_rd_n_in_r = 1'b0;
    end else if (sdrdm_w_state == SDWDM_ISSUE) begin
      sdram_addr_in_r = sdrdm_waddr_lat;
      sdram_data_in_r = sdrdm_wdata_lat;
      sdram_dqm_in_r  = sdrdm_dqm_lat;
      sdram_wr_n_in_r = 1'b0;
      sdram_rd_n_in_r = 1'b1;
    end else begin
      sdram_addr_in_r = 21'd0;
      sdram_data_in_r = 32'd0;
      sdram_dqm_in_r  = 4'b1111;
      sdram_wr_n_in_r = 1'b1;
      sdram_rd_n_in_r = 1'b1;
    end
  end

  assign sdram_addr_in = sdram_addr_in_r;
  assign sdram_data_in = sdram_data_in_r;
  assign sdram_dqm_in  = sdram_dqm_in_r;
  assign sdram_wr_n_in = sdram_wr_n_in_r;
  assign sdram_rd_n_in = sdram_rd_n_in_r;

  // CPU-facing outputs
  assign cpu_rready = (sdrdm_r_state == SDRDM_DONE);
  assign cpu_rdata  = sdrdm_rdata_latch;
  assign cpu_wready = (sdrdm_w_state == SDWDM_DONE);

  // ── Test stimulus ──────────────────────────────────────────────────────────
  integer errors;
  integer cycle;

  task do_write;
    input [31:0] addr;
    input [31:0] data;
    begin
      @(posedge clk); #1;
      cpu_waddr  = addr;
      cpu_wdata  = data;
      cpu_wstrb  = 4'hF;
      cpu_wvalid = 1;
      // Wait for wready. Deassert wvalid immediately after (before next posedge)
      // to mimic registered CPU behavior — prevents FSM re-triggering.
      @(posedge clk);
      while (!cpu_wready) @(posedge clk);
      #1;
      cpu_wvalid = 0;
    end
  endtask

  task do_read;
    input  [31:0] addr;
    output [31:0] data;
    begin
      @(posedge clk); #1;
      cpu_raddr  = addr;
      cpu_rvalid = 1;
      // Poll until rready=1 (seen at posedge). After posedge where rready=1
      // fires, the FSM moves DONE→IDLE on the next posedge. We must deassert
      // cpu_rvalid before that next posedge to avoid re-triggering.
      @(posedge clk);
      while (!cpu_rready) @(posedge clk);
      // We are now at the posedge where rready=1 (FSM=DONE).
      // Deassert immediately after (before next posedge) to mimic registered CPU.
      #1;
      cpu_rvalid = 0;
      data = cpu_rdata;
    end
  endtask

  integer t;
  reg [31:0] got;
  reg [31:0] expected;

  initial begin
    $dumpfile("sdram_dm_tb.vcd");
    $dumpvars(0, sdram_dm_tb);

    errors     = 0;
    cpu_raddr  = 0; cpu_rvalid = 0;
    cpu_waddr  = 0; cpu_wdata = 0; cpu_wstrb = 0; cpu_wvalid = 0;

    rst_n = 0;
    repeat(4) @(posedge clk);
    rst_n = 1;
    // Let SDRAM model warm up
    repeat(10) @(posedge clk);

    $display("=== SDRAM Direct-Map FSM Sim ===");

    // ── Test 1: Write then read back 8 words ──────────────────────────────
    $display("Test 1: write 8 words to 0x80000000...");
    for (t = 0; t < 8; t = t + 1) begin
      expected = 32'hA500_0000 | (t << 8) | t;
      do_write(32'h8000_0000 + t*4, expected);
    end

    $display("Test 1: read back...");
    for (t = 0; t < 8; t = t + 1) begin
      expected = 32'hA500_0000 | (t << 8) | t;
      do_read(32'h8000_0000 + t*4, got);
      if (got !== expected) begin
        $display("  FAIL [%0d] got=0x%08X expected=0x%08X", t, got, expected);
        errors = errors + 1;
      end else begin
        $display("  PASS [%0d] 0x%08X", t, got);
      end
    end

    // ── Test 2: Byte-enable write ─────────────────────────────────────────
    $display("Test 2: byte-enable write...");
    do_write(32'h8000_1000, 32'h0000_0000);  // clear
    // Write only byte 0
    @(posedge clk); #1;
    cpu_waddr  = 32'h8000_1000;
    cpu_wdata  = 32'hDEAD_BEEF;
    cpu_wstrb  = 4'b0001;          // byte 0 only
    cpu_wvalid = 1;
    @(posedge clk);
    while (!cpu_wready) @(posedge clk);
    #1; cpu_wvalid = 0;

    do_read(32'h8000_1000, got);
    if (got !== 32'h0000_00EF) begin
      $display("  FAIL byte0: got=0x%08X expected=0x000000EF", got);
      errors = errors + 1;
    end else $display("  PASS byte0: 0x%08X", got);

    // ── Summary ───────────────────────────────────────────────────────────
    if (errors == 0)
      $display("PASS — all checks passed");
    else
      $display("FAIL — %0d errors", errors);

    $finish;
  end

  // Timeout
  initial begin
    #500000;
    $display("TIMEOUT");
    $finish;
  end

  // Cycle counter + trace
  always @(posedge clk) begin
    if (rst_n)
      $display("t=%0t r_st=%0d w_st=%0d busy_n=%b rd_valid=%b wr_n=%b rd_n=%b cpu_raddr=%0d mux_addr=%0d rready=%b wready=%b smaddr=%0d",
        $time, sdrdm_r_state, sdrdm_w_state,
        sdram_busy_n, sdram_rd_valid,
        sdram_wr_n_in, sdram_rd_n_in,
        cpu_raddr[22:2], sdram_addr_in_r,
        cpu_rready, cpu_wready, sm_addr);
  end

endmodule
