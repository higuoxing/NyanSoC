`timescale 1 ns / 1 ps
/*
 * nyanrv_smode_tb.v — S-mode privilege testbench for nyanrv.
 *
 * Unlike nyanrv_tb.v, this testbench does NOT stop on o_trap.  The test
 * firmware uses ecall/ebreak internally to transition between privilege
 * levels; the testbench instead polls dmem[DONE_ADDR] for a magic "done"
 * value written by the test when it finishes.
 *
 * Memory map (matches test_smode.S):
 *   0x10000  DONE_ADDR   — written 0xDEAD_D0D0 when test completes
 *   0x10004  RESULT_ADDR — 1 = PASS, 0 = FAIL
 *   0x10008  FAIL_LINE   — line number of first failure (for debug)
 */

module nyanrv_smode_tb;

  parameter IMEM_WORDS     = 1024;
  parameter DMEM_WORDS     = 1024;
  parameter IMEM_ADDR_BITS = 10;
  parameter DMEM_ADDR_BITS = 10;
  parameter MAX_CYCLES     = 200_000;

  // dmem word indices (byte addr >> 2, mod DMEM_WORDS)
  // 0x10000 >> 2 = 0x4000, mod 1024 = 0
  localparam DONE_IDX   = 0;   // 0x10000
  localparam RESULT_IDX = 1;   // 0x10004
  localparam FAILLN_IDX = 2;   // 0x10008

  localparam DONE_MAGIC = 32'hDEAD_D0D0;

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

  wire [31:0] o_ptw_addr;
  wire        o_ptw_valid;
  reg  [31:0] i_ptw_rdata;
  reg         i_ptw_ready;

  reg         i_irq_timer;
  reg         i_irq_external;
  wire        o_trap;

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

  // PTW port backed by dmem (S-mode test has no page tables; just return 0).
  always @(*) begin
    i_ptw_rdata = 32'b0;
    i_ptw_ready = o_ptw_valid;
  end

  wire [DMEM_ADDR_BITS-1:0] dmem_waddr_idx = o_dmem_waddr[DMEM_ADDR_BITS+1:2];
  always @(posedge i_clk) begin
    if (o_dmem_wvalid && dmem_waddr_idx < DMEM_WORDS) begin
      if (o_dmem_wstrb[0]) dmem[dmem_waddr_idx][ 7: 0] <= o_dmem_wdata[ 7: 0];
      if (o_dmem_wstrb[1]) dmem[dmem_waddr_idx][15: 8] <= o_dmem_wdata[15: 8];
      if (o_dmem_wstrb[2]) dmem[dmem_waddr_idx][23:16] <= o_dmem_wdata[23:16];
      if (o_dmem_wstrb[3]) dmem[dmem_waddr_idx][31:24] <= o_dmem_wdata[31:24];
    end
  end
  assign i_dmem_wready = o_dmem_wvalid;

  nyanrv u_dut (
      .i_clk         (i_clk),
      .i_rst_n       (i_rst_n),
      .o_ptw_addr    (o_ptw_addr),
      .o_ptw_valid   (o_ptw_valid),
      .i_ptw_rdata   (i_ptw_rdata),
      .i_ptw_ready   (i_ptw_ready),
      .o_imem_addr   (o_imem_addr),
      .o_imem_valid  (o_imem_valid),
      .i_imem_rdata  (i_imem_rdata),
      .i_imem_ready  (i_imem_ready),
      .o_dmem_raddr  (o_dmem_raddr),
      .o_dmem_rvalid (o_dmem_rvalid),
      .i_dmem_rdata  (i_dmem_rdata),
      .i_dmem_rready (i_dmem_rready),
      .o_dmem_waddr  (o_dmem_waddr),
      .o_dmem_wvalid (o_dmem_wvalid),
      .o_dmem_wstrb  (o_dmem_wstrb),
      .o_dmem_wdata  (o_dmem_wdata),
      .i_dmem_wready (i_dmem_wready),
      .i_irq_timer   (i_irq_timer),
      .i_irq_external(i_irq_external),
      .o_trap        (o_trap)
  );

  integer cycle_count;
  integer i;

  initial begin
    if ($test$plusargs("dump")) begin
      $dumpfile("nyanrv_smode_tb.vcd");
      $dumpvars(0, nyanrv_smode_tb);
    end

    i_irq_timer    = 0;
    i_irq_external = 0;
    cycle_count    = 0;
    for (i = 0; i < IMEM_WORDS; i = i + 1) imem[i] = 32'h0000_0013;
    for (i = 0; i < DMEM_WORDS; i = i + 1) dmem[i] = 32'b0;
    $readmemh("imem.hex", imem);

    i_rst_n = 0;
    repeat (4) #20;
    i_rst_n = 1;
    #20;

    // Poll for done magic value; don't stop on o_trap
    while (dmem[DONE_IDX] !== DONE_MAGIC && cycle_count < MAX_CYCLES) begin
      #20;
      cycle_count = cycle_count + 1;
    end

    if (dmem[DONE_IDX] !== DONE_MAGIC) begin
      $display("TIMEOUT: test did not complete after %0d cycles", MAX_CYCLES);
      $display("FAIL: done=0x%08x result=%0d fail_line=%0d",
               dmem[DONE_IDX], dmem[RESULT_IDX], dmem[FAILLN_IDX]);
    end else if (dmem[RESULT_IDX] == 32'd1) begin
      $display("PASS");
    end else begin
      $display("FAIL: result=%0d fail_line=%0d", dmem[RESULT_IDX], dmem[FAILLN_IDX]);
    end

    $finish;
  end

endmodule
