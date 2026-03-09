`timescale 1 ns / 1 ps
/*
 * nyanrv_mmu_tb.v — Sv32 MMU testbench for nyanrv.
 *
 * Memory layout:
 *   imem[0..1023]    : instruction words at VA/PA 0x0000_0000..0x0000_0FFF
 *   dmem[0..1023]    : data words at VA 0x0010_0000 / PA 0x0010_0000
 *   ptbl[0..4095]    : page-table words backed by a flat 16 KB array
 *                      Indexed by ptw_addr[13:2] (i.e., ptw_addr >> 2, low 16KB).
 *
 * TLB uses VA[21:20] (2 bits, 4 entries):
 *   Code 0x0000_0000: VA[21:20]=00 → entry 0
 *   Data 0x0010_0000: VA[21:20]=01 → entry 1  (no collision)
 *
 * Sv32 page table setup:
 *   satp.PPN = 1  → L1 table at PA = 0x0000_1000
 *     L1[0]   = pointer PTE → PPN=2 (L0 table at PA=0x0000_2000)
 *     L1[4]   = invalid (for unmapped-VA fault test)
 *   L0 table at PA = 0x0000_2000:
 *     L0[0]   = leaf PTE for VA 0x0000_0000 (VPN[0]=0):   PPN=0,     R+W+X+V+A+D+U
 *     L0[256] = leaf PTE for VA 0x0010_0000 (VPN[0]=256):  PPN=0x100, R+W+V+A+D+U
 *     L0[257] = leaf PTE for VA 0x0010_1000 (VPN[0]=257):  PPN=0x101, R+X+V+A+D+U (no W)
 */

module nyanrv_mmu_tb;

  parameter IMEM_WORDS     = 1024;
  parameter DMEM_WORDS     = 1024;   // 4 KB at PA 0x0010_0000
  parameter PTBL_WORDS     = 4096;   // 16 KB of page-table space
  parameter IMEM_ADDR_BITS = 10;
  parameter MAX_CYCLES     = 500_000;

  // Data memory base physical address (matches test_mmu.S).
  localparam DMEM_BASE = 32'h0010_0000;

  localparam DONE_IDX   = 0;
  localparam RESULT_IDX = 1;
  localparam FAILLN_IDX = 2;
  localparam DONE_MAGIC = 32'hBEEFC0DE;

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
  // Page-table backing store: indexed by ptw_addr[13:2] (low 16 KB).
  reg  [31:0] ptbl [0:PTBL_WORDS-1];

  initial i_clk = 0;
  always #5 i_clk = ~i_clk;

  // ── Instruction memory ──────────────────────────────────────────────────
  wire [IMEM_ADDR_BITS-1:0] imem_idx = o_imem_addr[IMEM_ADDR_BITS+1:2];
  always @(*) begin
    i_imem_rdata = (o_imem_valid && imem_idx < IMEM_WORDS) ? imem[imem_idx] : 32'h0000_0013;
    i_imem_ready = o_imem_valid;
  end

  // ── Data memory — PA 0x0010_0000..0x0010_0FFF (1 KB words)
  // Index by stripping the base address and using bits [11:2].
  wire [9:0] dmem_raddr_idx = (o_dmem_raddr - DMEM_BASE) >> 2;
  wire       dmem_r_inrange = (o_dmem_raddr >= DMEM_BASE) &&
                              (o_dmem_raddr < DMEM_BASE + (DMEM_WORDS * 4));
  always @(*) begin
    i_dmem_rdata  = (o_dmem_rvalid && dmem_r_inrange) ? dmem[dmem_raddr_idx] : 32'b0;
    i_dmem_rready = o_dmem_rvalid;
  end

  wire [9:0] dmem_waddr_idx = (o_dmem_waddr - DMEM_BASE) >> 2;
  wire       dmem_w_inrange = (o_dmem_waddr >= DMEM_BASE) &&
                              (o_dmem_waddr < DMEM_BASE + (DMEM_WORDS * 4));
  always @(posedge i_clk) begin
    if (o_dmem_wvalid && dmem_w_inrange) begin
      if (o_dmem_wstrb[0]) dmem[dmem_waddr_idx][ 7: 0] <= o_dmem_wdata[ 7: 0];
      if (o_dmem_wstrb[1]) dmem[dmem_waddr_idx][15: 8] <= o_dmem_wdata[15: 8];
      if (o_dmem_wstrb[2]) dmem[dmem_waddr_idx][23:16] <= o_dmem_wdata[23:16];
      if (o_dmem_wstrb[3]) dmem[dmem_waddr_idx][31:24] <= o_dmem_wdata[31:24];
    end
  end
  assign i_dmem_wready = o_dmem_wvalid;

  // ── PTW port: backed by ptbl[], indexed by ptw_addr[13:2] ───────────────
  wire [11:0] ptw_addr_idx = o_ptw_addr[13:2];
  always @(*) begin
    i_ptw_rdata = (o_ptw_valid && ptw_addr_idx < PTBL_WORDS) ? ptbl[ptw_addr_idx] : 32'b0;
    i_ptw_ready = o_ptw_valid;
  end

  // ── DUT ─────────────────────────────────────────────────────────────────
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

  /*
   * Sv32 PTE bit layout (bit 0 = V):
   *   [0]  V  = valid
   *   [1]  R  = readable
   *   [2]  W  = writable
   *   [3]  X  = executable
   *   [4]  U  = user (accessible in U-mode)
   *   [5]  G  = global
   *   [6]  A  = accessed (must be 1, or hardware/sw sets it)
   *   [7]  D  = dirty (must be 1 for stores, or SW sets it)
   *   [31:10] PPN
   *
   * Non-leaf (pointer) PTE: R=W=X=0, V=1.
   * Leaf PTE: at least one of R, W, X is set.
   */
  localparam PTE_V  = 32'h1;
  localparam PTE_R  = 32'h2;
  localparam PTE_W  = 32'h4;
  localparam PTE_X  = 32'h8;
  localparam PTE_U  = 32'h10;
  localparam PTE_A  = 32'h40;
  localparam PTE_D  = 32'h80;

  // Helper: build a leaf PTE: PPN << 10 | flags
  function [31:0] leaf_pte;
    input [21:0] ppn;
    input [7:0]  flags;
    begin
      leaf_pte = ({ppn, 10'b0} | {24'b0, flags});
    end
  endfunction

  // Helper: build a pointer PTE (R=W=X=0)
  function [31:0] ptr_pte;
    input [21:0] ppn;
    begin
      ptr_pte = ({ppn, 10'b0} | PTE_V);
    end
  endfunction

  initial begin
    if ($test$plusargs("dump")) begin
      $dumpfile("nyanrv_mmu_tb.vcd");
      $dumpvars(0, nyanrv_mmu_tb);
    end

    i_irq_timer    = 0;
    i_irq_external = 0;
    cycle_count    = 0;

    for (i = 0; i < IMEM_WORDS; i = i + 1) imem[i] = 32'h0000_0013;
    for (i = 0; i < DMEM_WORDS; i = i + 1) dmem[i] = 32'b0;
    for (i = 0; i < PTBL_WORDS; i = i + 1) ptbl[i] = 32'b0;

    $display("Loading instruction memory from imem.hex");
    $readmemh("imem.hex", imem);

    // ── Build Sv32 page tables ─────────────────────────────────────────────
    // satp = MODE=1 (bit31) | ASID=0 | PPN=1 → L1 table at PA=0x0000_1000
    // ptbl is indexed by ptw_addr[13:2] (low 16 KB).
    //
    // TLB index = VA[21:20] (2 bits, 4 entries):
    //   Code 0x0000_0000: VA[21:20]=00 → entry 0
    //   Data 0x0010_0000: VA[21:20]=01 → entry 1  (no collision)
    //
    // Sv32 VPN decomposition:
    //   VPN[1] = VA[31:22]   → L1 index (10 bits)
    //   VPN[0] = VA[21:12]   → L0 index (10 bits)
    //
    //   VA=0x0000_0000: VPN[1]=0, VPN[0]=0   → code page
    //   VA=0x0010_0000: VPN[1]=0, VPN[0]=256 → data page 1 (0x100000>>12=256)
    //   VA=0x0010_1000: VPN[1]=0, VPN[0]=257 → data page 2 (no W)
    //   VA=0x0100_0000: VPN[1]=4, VPN[0]=0   → unmapped (L1[4]=invalid)

    // L1 table at PA 0x1000 (ptbl[1024]):
    //   L1[0] = VPN[1]=0 → pointer PTE to L0 at PPN=2 (PA=0x0000_2000)
    ptbl[1024 + 0] = ptr_pte(22'd2);  // L1[0] → L0 at PPN=2

    // L0 table at PA 0x2000 (ptbl[2048..]):
    //   L0[0]   = VPN[0]=0   → code at PA=0x0000_0000 (PPN=0), R+W+X+U+A+D
    //   L0[256] = VPN[0]=256 → data at PA=0x0010_0000 (PPN=0x100), R+W+U+A+D
    //   L0[257] = VPN[0]=257 → data at PA=0x0010_1000 (PPN=0x101), R+X+U+A+D (no W)
    ptbl[2048 + 0]   = leaf_pte(22'd0,     PTE_V|PTE_R|PTE_W|PTE_X|PTE_U|PTE_A|PTE_D);
    ptbl[2048 + 256] = leaf_pte(22'h100,   PTE_V|PTE_R|PTE_W|PTE_U|PTE_A|PTE_D);
    ptbl[2048 + 257] = leaf_pte(22'h101,   PTE_V|PTE_R|PTE_X|PTE_U|PTE_A|PTE_D);

    // L1[4] left as 0 (invalid) → VA 0x0100_0000..0x013F_FFFF faults.

    // ── Reset & run ────────────────────────────────────────────────────────
    i_rst_n = 0;
    repeat (4) #20;
    i_rst_n = 1;
    #20;

    $display("Running MMU test (max %0d cycles)...", MAX_CYCLES);
    while (dmem[DONE_IDX] !== DONE_MAGIC && cycle_count < MAX_CYCLES) begin
      #20;
      cycle_count = cycle_count + 1;
    end

    if (cycle_count >= MAX_CYCLES) begin
      $display("TIMEOUT: test did not complete after %0d cycles", MAX_CYCLES);
      $display("FAIL: done=0x%08x result=%0d fail_line=%0d",
               dmem[DONE_IDX], dmem[RESULT_IDX], dmem[FAILLN_IDX]);
    end else if (dmem[RESULT_IDX] == 32'd1) begin
      $display("PASS  test_mmu (completed in %0d cycles)", cycle_count);
    end else begin
      $display("FAIL: result=%0d fail_line=%0d", dmem[RESULT_IDX], dmem[FAILLN_IDX]);
    end

    #40;
    $finish;
  end

endmodule
