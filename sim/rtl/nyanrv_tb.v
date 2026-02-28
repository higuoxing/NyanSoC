`timescale 1 ns / 1 ps

module nyanrv_tb;

  parameter IMEM_WORDS = 1024;
  parameter DMEM_WORDS = 1024;
  parameter IMEM_ADDR_BITS = 10;  // log2(IMEM_WORDS) for byte addr 12 bits -> word index 10
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

  // Instruction and data memories (word-addressed for indexing)
  reg  [31:0] imem           [0:IMEM_WORDS-1];
  reg  [31:0] dmem           [0:DMEM_WORDS-1];

  // Clock
  initial i_clk = 0;
  always #5 i_clk = ~i_clk;

  // Instruction memory
  wire [IMEM_ADDR_BITS-1:0] imem_idx = o_imem_addr[IMEM_ADDR_BITS+1:2];
  always @(*) begin
    i_imem_rdata = (o_imem_valid && imem_idx < IMEM_WORDS) ? imem[imem_idx] : 32'h0000_0013; // nop if OOB
    i_imem_ready = o_imem_valid;
  end

  // Data memory
  wire [DMEM_ADDR_BITS-1:0] dmem_raddr_idx = o_dmem_raddr[DMEM_ADDR_BITS+1:2];
  always @(*) begin
    i_dmem_rdata  = (o_dmem_rvalid && dmem_raddr_idx < DMEM_WORDS) ? dmem[dmem_raddr_idx] : 32'b0;
    i_dmem_rready = o_dmem_rvalid;
  end

  // Data memory: synchronous write
  wire [DMEM_ADDR_BITS-1:0] dmem_waddr_idx = o_dmem_waddr[DMEM_ADDR_BITS+1:2];
  always @(posedge i_clk) begin
    if (o_dmem_wvalid && dmem_waddr_idx < DMEM_WORDS) begin
      if (o_dmem_wstrb[0]) dmem[dmem_waddr_idx][7:0] <= o_dmem_wdata[7:0];
      if (o_dmem_wstrb[1]) dmem[dmem_waddr_idx][15:8] <= o_dmem_wdata[15:8];
      if (o_dmem_wstrb[2]) dmem[dmem_waddr_idx][23:16] <= o_dmem_wdata[23:16];
      if (o_dmem_wstrb[3]) dmem[dmem_waddr_idx][31:24] <= o_dmem_wdata[31:24];
    end
  end
  assign i_dmem_wready = o_dmem_wvalid;  // accept store same cycle

  nyanrv u_dut (
      .i_clk         (i_clk),
      .i_rst_n       (i_rst_n),
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
  integer max_cycles;
  integer i;

  initial begin
    if ($test$plusargs("dump")) begin
      $dumpfile("nyanrv_tb.vcd");
      $dumpvars(0, nyanrv_tb);
    end
  end

  initial begin
    max_cycles  = 100_000;
    cycle_count = 0;
    for (i = 0; i < IMEM_WORDS; i = i + 1) imem[i] = 32'h0000_0013;  // nop
    for (i = 0; i < DMEM_WORDS; i = i + 1) dmem[i] = 32'b0;

    $display("Loading instruction memory from imem.hex");
    $readmemh("imem.hex", imem);

    i_irq_timer    = 0;
    i_irq_external = 0;
    i_rst_n = 0;
    repeat (4) #20;
    i_rst_n = 1;
    #20;

    $display("Running CPU (max %0d cycles)...", max_cycles);
    while (!o_trap && cycle_count < max_cycles) begin
      #20;
      cycle_count = cycle_count + 1;
    end

    if (o_trap) begin
      $display("Trap asserted after %0d cycles.", cycle_count);
    end else begin
      $display("WARNING: No trap after %0d cycles; stopping.", max_cycles);
    end

    // Self-check: all tests write 1 at RESULT_ADDR (dmem[0]) on pass, 0 on fail
    if (dmem[0] == 32'd1) $display("PASS");
    else $display("FAIL: dmem[0] == %0d (expected 1)", dmem[0]);

    $display("Test done.");
    $finish;
  end

endmodule
