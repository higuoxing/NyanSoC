`timescale 1 ns / 1 ps
/*
 * nyanrv_irq_tb.v — interrupt stimulus testbench for nyanrv.
 *
 * The testbench drives the two IRQ lines from a single initial block,
 * interleaved with the main run loop, so there are no race conditions
 * between concurrent initial blocks.
 *
 * Sequence:
 *   1. Reset for 4 cycles.
 *   2. Wait IRQ_DELAY_CYCLES for the CPU to execute its CSR setup.
 *   3. Assert i_irq_external; wait until irq_count rises to 1 (handler ran).
 *   4. Release i_irq_external; wait IRQ_GAP_CYCLES.
 *   5. Assert i_irq_timer; wait until irq_count rises to 2.
 *   6. Release i_irq_timer; run until ebreak (o_trap).
 *   7. Check dmem[0] == 1 for PASS.
 *
 * Memory map (matches test_irq.S and link.ld):
 *   dmem[0] = 0x10000 >> 2 mod 1024 = 0  → PASS/FAIL
 *   dmem[1] = 0x10004 >> 2 mod 1024 = 1  → irq_count
 *   dmem[2] = 0x10008 >> 2 mod 1024 = 2  → cause of 1st interrupt
 *   dmem[3] = 0x1000c >> 2 mod 1024 = 3  → cause of 2nd interrupt
 */

module nyanrv_irq_tb;

  parameter IMEM_WORDS = 1024;
  parameter DMEM_WORDS = 1024;
  parameter IMEM_ADDR_BITS = 10;
  parameter DMEM_ADDR_BITS = 10;

  // Cycles after reset-release before asserting the first IRQ.
  // The CPU must execute: la mtvec, csrw mie, csrsi mstatus (~6 insns × 2 cycles).
  parameter IRQ_DELAY_CYCLES = 40;
  // Maximum cycles to wait for each IRQ to be acknowledged.
  parameter IRQ_ACK_TIMEOUT = 500;
  // Gap (cycles) between the two IRQs.
  parameter IRQ_GAP_CYCLES = 20;
  // Overall simulation timeout.
  parameter MAX_CYCLES = 50_000;

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

  reg         i_irq_timer;
  reg         i_irq_external;
  wire        o_trap;

  reg  [31:0] imem           [0:IMEM_WORDS-1];
  reg  [31:0] dmem           [0:DMEM_WORDS-1];

  // 10 ns clock
  initial i_clk = 0;
  always #5 i_clk = ~i_clk;

  // Instruction memory — combinational, always ready
  wire [IMEM_ADDR_BITS-1:0] imem_idx = o_imem_addr[IMEM_ADDR_BITS+1:2];
  always @(*) begin
    i_imem_rdata = (o_imem_valid && imem_idx < IMEM_WORDS) ? imem[imem_idx] : 32'h0000_0013;
    i_imem_ready = o_imem_valid;
  end

  // Data memory — combinational read, synchronous write
  wire [DMEM_ADDR_BITS-1:0] dmem_raddr_idx = o_dmem_raddr[DMEM_ADDR_BITS+1:2];
  always @(*) begin
    i_dmem_rdata  = (o_dmem_rvalid && dmem_raddr_idx < DMEM_WORDS) ? dmem[dmem_raddr_idx] : 32'b0;
    i_dmem_rready = o_dmem_rvalid;
  end

  wire [DMEM_ADDR_BITS-1:0] dmem_waddr_idx = o_dmem_waddr[DMEM_ADDR_BITS+1:2];
  always @(posedge i_clk) begin
    if (o_dmem_wvalid && dmem_waddr_idx < DMEM_WORDS) begin
      if (o_dmem_wstrb[0]) dmem[dmem_waddr_idx][7:0] <= o_dmem_wdata[7:0];
      if (o_dmem_wstrb[1]) dmem[dmem_waddr_idx][15:8] <= o_dmem_wdata[15:8];
      if (o_dmem_wstrb[2]) dmem[dmem_waddr_idx][23:16] <= o_dmem_wdata[23:16];
      if (o_dmem_wstrb[3]) dmem[dmem_waddr_idx][31:24] <= o_dmem_wdata[31:24];
    end
  end
  assign i_dmem_wready = o_dmem_wvalid;

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
  integer timeout;
  integer i;

  task wait_cycles;
    input integer n;
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) @(posedge i_clk);
    end
  endtask

  // Run clock cycles until condition or timeout; returns 1 on condition.
  // (Implemented inline in the initial block below for Verilog-2005 compat.)

  initial begin
    if ($test$plusargs("dump")) begin
      $dumpfile("nyanrv_irq_tb.vcd");
      $dumpvars(0, nyanrv_irq_tb);
    end

    // Initialise
    i_irq_timer    = 0;
    i_irq_external = 0;
    cycle_count    = 0;
    for (i = 0; i < IMEM_WORDS; i = i + 1) imem[i] = 32'h0000_0013;
    for (i = 0; i < DMEM_WORDS; i = i + 1) dmem[i] = 32'b0;
    $readmemh("imem.hex", imem);

    // ── Reset ────────────────────────────────────────────────────────────
    i_rst_n = 0;
    wait_cycles(4);
    i_rst_n = 1;

    // ── Wait for CSR setup ───────────────────────────────────────────────
    wait_cycles(IRQ_DELAY_CYCLES);

    // ── First interrupt: machine external (MEI) ──────────────────────────
    i_irq_external = 1;
    timeout = IRQ_ACK_TIMEOUT;
    while (dmem[1] < 1 && timeout > 0) begin
      @(posedge i_clk);
      timeout = timeout - 1;
      cycle_count = cycle_count + 1;
    end
    i_irq_external = 0;
    if (timeout == 0) begin
      $display("TIMEOUT waiting for MEI acknowledgement");
      $display("FAIL: dmem[0]=%0d irq_count=%0d cause0=0x%08x cause1=0x%08x", dmem[0], dmem[1],
               dmem[2], dmem[3]);
      $finish;
    end

    // ── Gap between interrupts ───────────────────────────────────────────
    wait_cycles(IRQ_GAP_CYCLES);

    // ── Second interrupt: machine timer (MTI) ────────────────────────────
    i_irq_timer = 1;
    timeout = IRQ_ACK_TIMEOUT;
    while (dmem[1] < 2 && timeout > 0) begin
      @(posedge i_clk);
      timeout = timeout - 1;
      cycle_count = cycle_count + 1;
    end
    i_irq_timer = 0;
    if (timeout == 0) begin
      $display("TIMEOUT waiting for MTI acknowledgement");
      $display("FAIL: dmem[0]=%0d irq_count=%0d cause0=0x%08x cause1=0x%08x", dmem[0], dmem[1],
               dmem[2], dmem[3]);
      $finish;
    end

    // ── Give the CPU time to run the verify code and reach ebreak ────────
    // After IRQ acks, the spin exits and ~6 more instructions run before
    // crt0's ebreak.  Wait generously before declaring timeout.
    wait_cycles(500);

    // ── Run until ebreak ─────────────────────────────────────────────────
    timeout = MAX_CYCLES;
    while (!o_trap && timeout > 0) begin
      @(posedge i_clk);
      timeout = timeout - 1;
      cycle_count = cycle_count + 1;
    end

    if (!o_trap) $display("WARNING: No trap after %0d cycles total.", cycle_count);

    if (dmem[0] == 32'd1) $display("PASS");
    else
      $display(
          "FAIL: dmem[0]=%0d irq_count=%0d cause0=0x%08x cause1=0x%08x",
          dmem[0],
          dmem[1],
          dmem[2],
          dmem[3]
      );
    $finish;
  end

endmodule
