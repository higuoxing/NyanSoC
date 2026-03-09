/* plic.v — NyanSoC RISC-V PLIC (Platform-Level Interrupt Controller)
 *
 * Minimum PLIC for Linux S-mode UART RX interrupts.
 * Conforms to RISC-V PLIC specification v1.0.0.
 *
 * Configuration (fixed):
 *   1 interrupt source  (source 1 = UART RX; source 0 reserved/always 0)
 *   1 context           (context 0 = S-mode hart 0)
 *
 * Register map (byte offsets from PLIC base 0x0C00_0000):
 *   0x000004   Source 1 priority            R/W  bits[2:0]
 *   0x001000   Interrupt pending word 0      R    bit[1]=src1
 *   0x002000   Enable bits, context 0 word 0 R/W  bit[1]=src1
 *   0x200000   Threshold, context 0          R/W  bits[2:0]
 *   0x200004   Claim / complete, context 0   R/W  32-bit source ID
 *
 * Pending is edge-triggered: set on rising edge of i_src[1],
 * cleared when the CPU reads the claim register.
 */
`default_nettype none

module plic (
    input  wire        i_clk,
    input  wire        i_rst_n,

    // Interrupt sources: [0] unused (spec), [1] = UART RX
    input  wire [1:0]  i_src,

    // Memory-mapped interface (24-bit byte offset within PLIC region)
    input  wire [23:0] i_addr,
    input  wire        i_rvalid,
    output reg  [31:0] o_rdata,
    output wire        o_rready,
    input  wire        i_wvalid,
    input  wire [ 3:0] i_wstrb,
    input  wire [31:0] i_wdata,

    // IRQ output (context 0 = S-mode)
    output wire        o_irq
);

  // ── Registers ───────────────────────────────────────────────────────────────
  reg [2:0] src1_priority;   // priority of source 1
  reg       src1_pending;    // pending bit for source 1
  reg       src1_enable;     // enable in context 0
  reg [2:0] ctx0_threshold;  // priority threshold for context 0

  // ── Edge detection ──────────────────────────────────────────────────────────
  reg src1_prev;

  // ── Claim: returns src ID when active, else 0 ───────────────────────────────
  wire claim_active = src1_pending && src1_enable && (src1_priority > ctx0_threshold);
  wire [31:0] claim_val = claim_active ? 32'd1 : 32'd0;

  // ── Write strobes ───────────────────────────────────────────────────────────
  wire wr_prio1  = i_wvalid && (i_addr == 24'h000004);
  wire wr_en0    = i_wvalid && (i_addr == 24'h002000);
  wire wr_thr0   = i_wvalid && (i_addr == 24'h200000);
  // wr_complete: write to 0x200004 (complete) — no action needed for edge src

  // ── Sequential ──────────────────────────────────────────────────────────────
  always @(posedge i_clk) begin
    if (!i_rst_n) begin
      src1_prev      <= 1'b0;
      src1_pending   <= 1'b0;
      src1_priority  <= 3'd0;
      src1_enable    <= 1'b0;
      ctx0_threshold <= 3'd0;
    end else begin
      src1_prev <= i_src[1];

      // Rising edge of source → set pending
      if (i_src[1] && !src1_prev)
        src1_pending <= 1'b1;

      // Claim read: clear pending one cycle after the read so the combinatorial
      // claim_val is still valid when the CPU samples rdata this cycle.
      if (i_rvalid && (i_addr == 24'h200004) && claim_active)
        src1_pending <= 1'b0;

      // Register writes (byte-enable on byte 0 covers the low bits)
      if (wr_prio1 && i_wstrb[0]) src1_priority  <= i_wdata[2:0];
      if (wr_en0   && i_wstrb[0]) src1_enable    <= i_wdata[1];
      if (wr_thr0  && i_wstrb[0]) ctx0_threshold <= i_wdata[2:0];
    end
  end

  // ── Read mux (fully combinatorial) ──────────────────────────────────────────
  // The CPU samples i_dmem_rdata on the same cycle that i_dmem_rready=1.
  // Because o_rready = i_rvalid (combinatorial), the CPU sees data and ready
  // on the same cycle as i_rvalid.  pending is cleared on the NEXT posedge
  // (one cycle after claim is read), so claim_val is still valid this cycle.
  assign o_rready = i_rvalid;

  always @(*) begin
    case (i_addr)
      24'h000004: o_rdata = {29'd0, src1_priority};
      24'h001000: o_rdata = {30'd0, src1_pending, 1'b0};
      24'h002000: o_rdata = {30'd0, src1_enable, 1'b0};
      24'h200000: o_rdata = {29'd0, ctx0_threshold};
      24'h200004: o_rdata = claim_val;
      default:    o_rdata = 32'd0;
    endcase
  end

  // ── IRQ output ───────────────────────────────────────────────────────────────
  assign o_irq = claim_active;

endmodule
`default_nettype wire
