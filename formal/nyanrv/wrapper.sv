/*
 * NyanSoC RVFI wrapper for riscv-formal
 *
 * nyanrv is an in-order core with a split ready/valid memory interface.
 * We tie all ready signals high so memory always responds in one cycle,
 * and provide unconstrained (any-value) instruction/data bus content so
 * the solver can explore the full instruction stream.
 *
 * All `define RISCV_FORMAL_* macros are injected by the generated
 * per-check defines.sv; do not add them here.
 *
 * Reset alignment: nyanrv takes 2 cycles per instruction (fetch + execute).
 * The regfile zeroes one register per clock during reset, taking 32 cycles
 * before o_rst_done goes high and the CPU begins fetching.
 * Total latency from reset deassertion to first retirement:
 *   32 cycles (regfile reset) + 1 cycle (fetch) + 1 cycle (execute) = 34 cycles.
 * We hold i_rst_n low for 1 SMT step and delay the release through a
 * 33-cycle shift register, giving first retirements at SMT steps 36, 38, ...
 * The genchecks depths are set accordingly in checks.cfg.
 */

`include "rvfi_macros.vh"

module rvfi_wrapper (
    input clock,
    input reset,
    `RVFI_OUTPUTS
);
  (* keep *) `rvformal_rand_reg [31:0] imem_rdata;
  (* keep *) `rvformal_rand_reg [31:0] dmem_rdata;

  // Extend reset by one extra cycle (matching the original 2-cycle reset hold).
  // The regfile zeroing (32 cycles) is handled internally by the CPU gating
  // on rf_rst_done, which is transparent to the solver — it just means the
  // first rvfi_valid retirement appears 32 cycles later than in a plain core.
  reg reset_q = 1;
  always @(posedge clock) reset_q <= reset;
  wire rst_n = !(reset || reset_q);

  (* keep *)wire [31:0] o_imem_addr;
  (* keep *)wire        o_imem_valid;
  (* keep *)wire [31:0] o_dmem_raddr;
  (* keep *)wire        o_dmem_rvalid;
  (* keep *)wire [31:0] o_dmem_waddr;
  (* keep *)wire        o_dmem_wvalid;
  (* keep *)wire [ 3:0] o_dmem_wstrb;
  (* keep *)wire [31:0] o_dmem_wdata;
  (* keep *)wire        o_trap;

  nyanrv uut (
      .i_clk  (clock),
      .i_rst_n(rst_n),

      .o_imem_addr (o_imem_addr),
      .o_imem_valid(o_imem_valid),
      .i_imem_rdata(imem_rdata),
      .i_imem_ready(1'b1),

      .o_dmem_raddr (o_dmem_raddr),
      .o_dmem_rvalid(o_dmem_rvalid),
      .i_dmem_rdata (dmem_rdata),
      .i_dmem_rready(1'b1),

      .o_dmem_waddr (o_dmem_waddr),
      .o_dmem_wvalid(o_dmem_wvalid),
      .o_dmem_wstrb (o_dmem_wstrb),
      .o_dmem_wdata (o_dmem_wdata),
      .i_dmem_wready(1'b1),

      .i_irq_timer   (1'b0),
      .i_irq_external(1'b0),

      .o_trap(o_trap),

      `RVFI_CONN
  );

endmodule
