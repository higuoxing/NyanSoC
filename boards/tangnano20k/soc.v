`default_nettype none
`timescale 1 ns / 1 ps

/* NyanSoC top-level SoC for Tang Nano 20K
 *
 * Memory map (all regions 4 KiB, indexed by addr[11:2]):
 *   0x0000_0000 - 0x0000_0FFF  IMEM (1 KiB words, combinatorial LUT-ROM)
 *   0x0001_0000 - 0x0001_0FFF  DMEM (1 KiB words, BRAM, read/write)
 *   0x0002_0000                GPIO output register
 *                                 bits [5:0] = LED[5:0] (write 1 = on)
 *
 * Address decode uses bits [17:16]:
 *   2'b00 -> IMEM  (only via instruction bus)
 *   2'b01 -> DMEM
 *   2'b10 -> GPIO
 *
 * Reset: i_rst_n is the S1 button (active-low, pulled high at rest).
 * A power-on reset shift register (por_sr) guarantees reset is held for
 * 8 cycles after FPGA configuration, so the CPU starts cleanly without
 * needing to press S1.
 */

module soc (
    input  wire       i_clk,
    input  wire       i_rst_n,  // S1 button: 1 when pressed, 0 at rest (pulled low)
    output wire [5:0] o_led     // active-low LEDs (6 monochromatic)
);

  // ── Parameters ────────────────────────────────────────────────────────────
  parameter IMEM_WORDS = 1024;
  parameter DMEM_WORDS = 1024;

  // ── Power-on reset ────────────────────────────────────────────────────────
  // On FPGA power-up, initial blocks do not reliably reset flip-flops.
  // por_sr starts all-zero (Gowin GSR pulls FFs low at configuration time)
  // and shifts in 1s each cycle, keeping rst_n low for 8 cycles before
  // releasing. S1 is pulled low at rest and goes high when pressed, so
  // pressing S1 asserts reset (i_rst_n=1 → rst_n=0).
  reg [7:0] por_sr = 8'b0;
  always @(posedge i_clk) por_sr <= {por_sr[6:0], 1'b1};
  wire rst_n = por_sr[7] & ~i_rst_n;  // ~i_rst_n: pressed=0 (reset), rest=1 (run)

  // ── CPU wires ─────────────────────────────────────────────────────────────
  wire [31:0] imem_addr;
  wire        imem_valid;
  reg  [31:0] imem_rdata;
  reg         imem_ready;

  wire [31:0] dmem_raddr;
  wire        dmem_rvalid;
  reg  [31:0] dmem_rdata;
  reg         dmem_rready;

  wire [31:0] dmem_waddr;
  wire        dmem_wvalid;
  wire [ 3:0] dmem_wstrb;
  wire [31:0] dmem_wdata;
  reg         dmem_wready;

  wire        o_trap;

  // ── Instruction memory: combinatorial LUT-ROM ─────────────────────────────
  // A pure combinatorial case ROM synthesises reliably to LUTs.
  // $readmemh-based BRAM init is unreliable with the open-source Gowin flow.
  wire [9:0] imem_idx = imem_addr[11:2];

  always @(*) begin
    `include "imem_rom.vh"
    imem_ready = imem_valid;
  end

  // ── Data BRAM ─────────────────────────────────────────────────────────────
  reg [31:0] dmem[0:DMEM_WORDS-1];

  wire dmem_rsel = dmem_rvalid && (dmem_raddr[17:16] == 2'b01);
  wire dmem_wsel = dmem_wvalid && (dmem_waddr[17:16] == 2'b01);

  wire [9:0] dmem_raddr_idx = dmem_raddr[11:2];
  wire [9:0] dmem_waddr_idx = dmem_waddr[11:2];

  always @(posedge i_clk) begin
    if (dmem_wsel) begin
      if (dmem_wstrb[0]) dmem[dmem_waddr_idx][ 7: 0] <= dmem_wdata[ 7: 0];
      if (dmem_wstrb[1]) dmem[dmem_waddr_idx][15: 8] <= dmem_wdata[15: 8];
      if (dmem_wstrb[2]) dmem[dmem_waddr_idx][23:16] <= dmem_wdata[23:16];
      if (dmem_wstrb[3]) dmem[dmem_waddr_idx][31:24] <= dmem_wdata[31:24];
    end
  end

  always @(*) begin
    dmem_rdata  = dmem_rsel ? dmem[dmem_raddr_idx] : 32'b0;
    dmem_rready = dmem_rvalid;
  end

  // ── GPIO register ─────────────────────────────────────────────────────────
  wire gpio_wsel = dmem_wvalid && (dmem_waddr[17:16] == 2'b10);

  reg [5:0] gpio_out;
  always @(posedge i_clk or negedge rst_n) begin
    if (!rst_n) gpio_out <= 6'b000000;
    else if (gpio_wsel && dmem_wstrb[0]) gpio_out <= dmem_wdata[5:0];
  end

  assign o_led = ~gpio_out;  // active-low: invert for the LED pins

  always @(*) dmem_wready = dmem_wvalid;

  // ── CPU ───────────────────────────────────────────────────────────────────
  nyanrv u_cpu (
      .i_clk          (i_clk),
      .i_rst_n        (rst_n),
      .o_imem_addr    (imem_addr),
      .o_imem_valid   (imem_valid),
      .i_imem_rdata   (imem_rdata),
      .i_imem_ready   (imem_ready),
      .o_dmem_raddr   (dmem_raddr),
      .o_dmem_rvalid  (dmem_rvalid),
      .i_dmem_rdata   (dmem_rdata),
      .i_dmem_rready  (dmem_rready),
      .o_dmem_waddr   (dmem_waddr),
      .o_dmem_wvalid  (dmem_wvalid),
      .o_dmem_wstrb   (dmem_wstrb),
      .o_dmem_wdata   (dmem_wdata),
      .i_dmem_wready  (dmem_wready),
      .i_irq_timer    (1'b0),
      .i_irq_external (1'b0),
      .o_trap         (o_trap)
  );

endmodule
