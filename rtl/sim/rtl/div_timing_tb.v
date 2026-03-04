`timescale 1 ns / 1 ps

module div_timing_tb;

  parameter IMEM_WORDS = 1024;
  parameter DMEM_WORDS = 1024;
  parameter IMEM_ADDR_BITS = 10;
  parameter DMEM_ADDR_BITS = 10;

  reg         i_clk;
  reg         i_rst_n;

  wire [31:0] o_imem_addr;
  wire        o_imem_valid;
  reg  [31:0] i_imem_rdata;
  reg         i_imem_ready;

  wire [31:0] o_dmem_raddr;
  wire        o_dmem_rvalid;
  reg  [31:0] i_dmem_rdata;
  reg         i_dmem_rready;

  wire [31:0] o_dmem_waddr;
  wire        o_dmem_wvalid;
  wire [ 3:0] o_dmem_wstrb;
  wire [31:0] o_dmem_wdata;
  wire        i_dmem_wready;

  wire        o_trap;
  reg         i_irq_timer;
  reg         i_irq_external;

  reg  [31:0] imem [0:IMEM_WORDS-1];
  reg  [31:0] dmem [0:DMEM_WORDS-1];

  initial i_clk = 0;
  always #5 i_clk = ~i_clk;

  wire [IMEM_ADDR_BITS-1:0] imem_idx = o_imem_addr[IMEM_ADDR_BITS+1:2];
  always @(*) begin
    i_imem_rdata = (o_imem_valid && imem_idx < IMEM_WORDS) ? imem[imem_idx] : 32'h0000_0013;
    i_imem_ready = o_imem_valid;
  end

  wire [DMEM_ADDR_BITS-1:0] dmem_raddr_idx = o_dmem_raddr[DMEM_ADDR_BITS+1:2];
  always @(*) begin
    i_dmem_rdata  = (o_dmem_rvalid && dmem_raddr_idx < DMEM_WORDS) ? dmem[dmem_raddr_idx] : 32'b0;
    i_dmem_rready = o_dmem_rvalid;
  end

  assign i_dmem_wready = 1'b1;
  wire [DMEM_ADDR_BITS-1:0] dmem_waddr_idx = o_dmem_waddr[DMEM_ADDR_BITS+1:2];
  always @(posedge i_clk) begin
    if (o_dmem_wvalid) begin
      if (o_dmem_wstrb[0]) dmem[dmem_waddr_idx][ 7: 0] <= o_dmem_wdata[ 7: 0];
      if (o_dmem_wstrb[1]) dmem[dmem_waddr_idx][15: 8] <= o_dmem_wdata[15: 8];
      if (o_dmem_wstrb[2]) dmem[dmem_waddr_idx][23:16] <= o_dmem_wdata[23:16];
      if (o_dmem_wstrb[3]) dmem[dmem_waddr_idx][31:24] <= o_dmem_wdata[31:24];
    end
  end

  nyanrv dut (
    .i_clk            (i_clk),
    .i_rst_n          (i_rst_n),
    .o_imem_addr      (o_imem_addr),
    .o_imem_valid     (o_imem_valid),
    .i_imem_rdata     (i_imem_rdata),
    .i_imem_ready     (i_imem_ready),
    .o_dmem_raddr     (o_dmem_raddr),
    .o_dmem_rvalid    (o_dmem_rvalid),
    .i_dmem_rdata     (i_dmem_rdata),
    .i_dmem_rready    (i_dmem_rready),
    .o_dmem_waddr     (o_dmem_waddr),
    .o_dmem_wvalid    (o_dmem_wvalid),
    .o_dmem_wstrb     (o_dmem_wstrb),
    .o_dmem_wdata     (o_dmem_wdata),
    .i_dmem_wready    (i_dmem_wready),
    .o_trap           (o_trap),
    .i_irq_timer      (i_irq_timer),
    .i_irq_external   (i_irq_external)
  );

  // Cycle counter and sentinel tracking
  // dmem word index 1 = address 0x00010004
  localparam SENTINEL_IDX = 1;

  integer cycle_cnt;
  integer mark_cycle;
  reg [31:0] last_sentinel;

  initial cycle_cnt = 0;
  always @(posedge i_clk) cycle_cnt = cycle_cnt + 1;

  // Detect writes to the sentinel address and measure cycles between AA→BB pairs
  wire sentinel_write = o_dmem_wvalid && (dmem_waddr_idx == SENTINEL_IDX);

  always @(posedge i_clk) begin
    if (sentinel_write) begin
      if (o_dmem_wdata[7:0] == 8'hAA) begin
        // Start marker
        mark_cycle = cycle_cnt;
      end else if (o_dmem_wdata[7:0] == 8'hBB) begin
        // End marker — print elapsed cycles
        case (o_dmem_wdata[15:8])
          8'h11: $display("  div  1        / 1        => %0d cycles  (31 leading zeros, expect ~3)",
                          cycle_cnt - mark_cycle - 1);
          8'h22: $display("  div  0xFF     / 3        => %0d cycles  (24 leading zeros, expect ~10)",
                          cycle_cnt - mark_cycle - 1);
          8'h33: $display("  div  0xFFFF   / 7        => %0d cycles  (16 leading zeros, expect ~18)",
                          cycle_cnt - mark_cycle - 1);
          8'h44: $display("  divu 0xFFFFFF / 3        => %0d cycles  (0 leading zeros,  expect ~34)",
                          cycle_cnt - mark_cycle - 1);
          8'h55: $display("  div  0        / 1        => %0d cycles  (dividend=0,       expect ~2)",
                          cycle_cnt - mark_cycle - 1);
        endcase
      end
    end
  end

  integer i;
  initial begin
    for (i = 0; i < DMEM_WORDS; i = i + 1) dmem[i] = 32'b0;
    i_rst_n        = 0;
    i_irq_timer    = 0;
    i_irq_external = 0;
    $readmemh("imem.hex", imem);
    @(posedge i_clk); #1;
    @(posedge i_clk); #1;
    i_rst_n = 1;
    repeat (10000) @(posedge i_clk);
    $display("Timeout");
    $finish;
  end

  always @(posedge i_clk) begin
    if (o_trap) begin
      if (dmem[0] == 32'd1)
        $display("PASS");
      else
        $display("FAIL");
      $finish;
    end
  end

endmodule
