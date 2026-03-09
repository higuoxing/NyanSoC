`timescale 1 ns / 1 ps
/* plic_tb.v — unit test for rtl/plic.v
 *
 * Checks:
 *  1. IRQ not asserted before any configuration.
 *  2. Source fires while enable=0 → pending set but IRQ not asserted.
 *  3. Write priority=1, enable bit=1, threshold=0 → IRQ asserted.
 *  4. Claim register returns source ID 1, clears pending, deasserts IRQ.
 *  5. Complete write is a no-op (pending stays clear).
 *  6. Second source pulse → pending re-set, IRQ re-asserted.
 *  7. threshold >= priority → IRQ masked.
 *  8. Register reads return correct values.
 */
module plic_tb;

  reg        clk, rst_n;
  initial clk = 0;
  always #5 clk = ~clk;

  // DUT signals
  reg  [1:0]  src;
  reg  [23:0] addr;
  reg         rvalid;
  wire [31:0] rdata;
  wire        rready;
  reg         wvalid;
  reg  [ 3:0] wstrb;
  reg  [31:0] wdata;
  wire        irq;

  plic dut (
      .i_clk    (clk),
      .i_rst_n  (rst_n),
      .i_src    (src),
      .i_addr   (addr),
      .i_rvalid (rvalid),
      .o_rdata  (rdata),
      .o_rready (rready),
      .i_wvalid (wvalid),
      .i_wstrb  (wstrb),
      .i_wdata  (wdata),
      .o_irq    (irq)
  );

  // Write: assert for one full cycle.
  task plic_write;
    input [23:0] a;
    input [31:0] d;
    begin
      @(posedge clk); #1;
      addr = a; wdata = d; wstrb = 4'hF; wvalid = 1; rvalid = 0;
      @(posedge clk); #1;  // posedge samples the write
      wvalid = 0;
    end
  endtask

  // Read: assert rvalid for one cycle; sample rdata the same cycle as assertion
  // (combinatorial). rdata is stable because the PLIC mux is purely combinatorial.
  // Any state changes (like pending clear) take effect one cycle later.
  task plic_read;
    input  [23:0] a;
    output [31:0] d;
    begin
      @(posedge clk); #1;
      addr = a; rvalid = 1; wvalid = 0;
      #1;  // allow combinatorial paths to settle
      d = rdata;
      @(posedge clk); #1;  // posedge processes state updates
      rvalid = 0;
    end
  endtask

  task pulse_src;
    begin
      @(posedge clk); #1;
      src[1] = 1;
      @(posedge clk); #1;
      src[1] = 0;
    end
  endtask

  integer errors;
  reg [31:0] got;

  task check32;
    input [31:0] a, b;
    input [63:0] label;
    begin
      if (a !== b) begin
        $display("FAIL %s: got=0x%08X expected=0x%08X", label, a, b);
        errors = errors + 1;
      end else
        $display("PASS %s: 0x%08X", label, a);
    end
  endtask

  initial begin
    errors = 0;
    src    = 2'b00;
    addr   = 0; rvalid = 0; wvalid = 0; wstrb = 0; wdata = 0;
    rst_n  = 0;
    repeat(4) @(posedge clk);
    rst_n = 1;
    repeat(2) @(posedge clk);

    $display("=== PLIC unit test ===");

    // 1. IRQ not asserted after reset
    @(posedge clk); #1;
    check32(irq, 0, "1.irq_after_reset");

    // 2. Source fires but enable=0 → pending set, IRQ not asserted
    pulse_src;
    @(posedge clk); #1;
    check32(irq, 0, "2.irq_masked_enable0");
    plic_read(24'h001000, got);
    check32(got[1], 1, "2.pending_set");

    // 3. Set priority=1, enable bit 1, threshold=0 → IRQ asserted
    plic_write(24'h000004, 32'd1);  // priority[1] = 1
    plic_write(24'h002000, 32'h2); // enable[0][1] = 1
    plic_write(24'h200000, 32'd0); // threshold[0] = 0
    @(posedge clk); #1;
    check32(irq, 1, "3.irq_asserted");

    // 4. Claim → returns source 1, clears pending, deasserts IRQ
    plic_read(24'h200004, got);
    check32(got, 1, "4.claim_id");
    @(posedge clk); #1;
    check32(irq, 0, "4.irq_cleared");
    plic_read(24'h001000, got);
    check32(got[1], 0, "4.pending_cleared");

    // 5. Complete write is no-op (pending stays clear)
    plic_write(24'h200004, 32'd1);
    @(posedge clk); #1;
    check32(irq, 0, "5.complete_noop");

    // 6. Second source pulse → pending re-set, IRQ re-asserted
    pulse_src;
    @(posedge clk); #1;
    check32(irq, 1, "6.irq_re_asserted");

    // 7. threshold >= priority → IRQ masked
    plic_write(24'h200000, 32'd1); // threshold = 1, priority = 1 → not >
    @(posedge clk); #1;
    check32(irq, 0, "7.irq_masked_threshold");
    plic_read(24'h001000, got);
    check32(got[1], 1, "7.pending_still_set");

    // Lower threshold back → IRQ re-asserted
    plic_write(24'h200000, 32'd0);
    @(posedge clk); #1;
    check32(irq, 1, "7b.irq_unmasked");

    // 8. Register reads
    plic_read(24'h000004, got); check32(got, 1, "8.priority_reg");
    plic_read(24'h002000, got); check32(got, 2, "8.enable_reg");
    plic_read(24'h200000, got); check32(got, 0, "8.threshold_reg");

    // Summary
    if (errors == 0)
      $display("PASS");
    else
      $display("FAIL — %0d errors", errors);

    $finish;
  end

  initial begin
    #50000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
