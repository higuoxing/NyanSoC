`default_nettype none
`timescale 1 ns / 1 ps

module decoder (
    input  wire [31:0] i_insn,
    output wire [ 4:0] o_rs1,
    output wire [ 4:0] o_rs2,
    output wire [ 4:0] o_rd,
    output wire [ 6:0] o_opcode,
    output wire [ 2:0] o_funct3,
    output wire [ 6:0] o_funct7,
    output wire [31:0] o_imm_I,
    output wire [31:0] o_imm_S,
    output wire [31:0] o_imm_B,
    output wire [31:0] o_imm_U,
    output wire [31:0] o_imm_J
);

  assign o_rs1 = i_insn[19:15];
  assign o_rs2 = i_insn[24:20];
  assign o_rd = i_insn[11:7];
  assign o_opcode = i_insn[6:0];
  assign o_funct3 = i_insn[14:12];
  assign o_funct7 = i_insn[31:25];

  // Immediates (Ch2. RV32I Base Integer Instruction Set).
  // {{
  // I-type.
  assign o_imm_I = {{21{i_insn[31]}}, i_insn[30:20]};
  // S-type.
  assign o_imm_S = {{21{i_insn[31]}}, i_insn[30:25], i_insn[11:7]};
  // B-type.
  assign o_imm_B = {{20{i_insn[31]}}, i_insn[7], i_insn[30:25], i_insn[11:8], 1'b0};
  // U-type.
  assign o_imm_U = {i_insn[31:12], 12'b0};
  // J-type.
  assign o_imm_J = {{12{i_insn[31]}}, i_insn[19:12], i_insn[20], i_insn[30:21], 1'b0};
  // }}

endmodule  // decoder

module nyanrv (
    input wire i_clk,
    input wire i_rst_n,

    // Instruction Memory
    // {{
    output wire [31:0] o_imem_addr,
    output wire        o_imem_valid,
    input  wire [31:0] i_imem_rdata,
    input  wire        i_imem_ready,
    // }}

    // Data Memory
    // {{
    //    Read ports
    output wire [31:0] o_dmem_raddr,
    output wire        o_dmem_rvalid,
    input  wire [31:0] i_dmem_rdata,
    input  wire        i_dmem_rready,

    //    Write ports
    output wire [31:0] o_dmem_waddr,
    output wire        o_dmem_wvalid,
    output wire [ 3:0] o_dmem_wstrb,
    output wire [31:0] o_dmem_wdata,
    input  wire        i_dmem_wready,
    // }}

    output reg o_trap

`ifdef RISCV_FORMAL
    // RVFI outputs
    // {{
    ,output reg        rvfi_valid
    ,output reg [63:0] rvfi_order
    ,output reg [31:0] rvfi_insn
    ,output reg        rvfi_trap
    ,output reg        rvfi_halt
    ,output reg        rvfi_intr
    ,output reg [ 1:0] rvfi_mode
    ,output reg [ 1:0] rvfi_ixl

    ,output reg [ 4:0] rvfi_rs1_addr
    ,output reg [ 4:0] rvfi_rs2_addr
    ,output reg [31:0] rvfi_rs1_rdata
    ,output reg [31:0] rvfi_rs2_rdata
    ,output reg [ 4:0] rvfi_rd_addr
    ,output reg [31:0] rvfi_rd_wdata

    ,output reg [31:0] rvfi_pc_rdata
    ,output reg [31:0] rvfi_pc_wdata

    ,output reg [31:0] rvfi_mem_addr
    ,output reg [ 3:0] rvfi_mem_rmask
    ,output reg [ 3:0] rvfi_mem_wmask
    ,output reg [31:0] rvfi_mem_rdata
    ,output reg [31:0] rvfi_mem_wdata

    // CSR ports
    ,output reg [31:0] rvfi_csr_mstatus_rmask
    ,output reg [31:0] rvfi_csr_mstatus_wmask
    ,output reg [31:0] rvfi_csr_mstatus_rdata
    ,output reg [31:0] rvfi_csr_mstatus_wdata

    ,output reg [31:0] rvfi_csr_mtvec_rmask
    ,output reg [31:0] rvfi_csr_mtvec_wmask
    ,output reg [31:0] rvfi_csr_mtvec_rdata
    ,output reg [31:0] rvfi_csr_mtvec_wdata

    ,output reg [31:0] rvfi_csr_mscratch_rmask
    ,output reg [31:0] rvfi_csr_mscratch_wmask
    ,output reg [31:0] rvfi_csr_mscratch_rdata
    ,output reg [31:0] rvfi_csr_mscratch_wdata

    ,output reg [31:0] rvfi_csr_mepc_rmask
    ,output reg [31:0] rvfi_csr_mepc_wmask
    ,output reg [31:0] rvfi_csr_mepc_rdata
    ,output reg [31:0] rvfi_csr_mepc_wdata

    ,output reg [31:0] rvfi_csr_mcause_rmask
    ,output reg [31:0] rvfi_csr_mcause_wmask
    ,output reg [31:0] rvfi_csr_mcause_rdata
    ,output reg [31:0] rvfi_csr_mcause_wdata

    ,output reg [31:0] rvfi_csr_mtval_rmask
    ,output reg [31:0] rvfi_csr_mtval_wmask
    ,output reg [31:0] rvfi_csr_mtval_rdata
    ,output reg [31:0] rvfi_csr_mtval_wdata
    // }}
`endif
);
  reg trap;
  reg [31:0] trap_cause;  // mcause value for execute-state traps

  // Registers {{
  reg [31:0] pc;
  reg [31:0] X[0:31];

  reg [31:0] CSR[0:10];
  localparam mstatus = 0;
  localparam mnstatus = 1;
  localparam mtvec = 2;
  localparam mepc = 3;
  localparam mcause = 4;
  localparam mhartid = 5;
  localparam misa = 6;
  localparam mie = 7;
  localparam mscratch = 8;
  localparam mtval = 9;
  localparam mip = 10;
  localparam mcsr_max = 11;
  // }}

  reg [1:0] cpu_state;
  localparam cpu_state_fetch = 2'b00;
  localparam cpu_state_execute = 2'b01;
  localparam cpu_state_store = 2'b10;
  localparam cpu_state_load = 2'b11;

  // Valid in fetch state.
  wire [31:0] insn;
  wire [4:0] rs1, rs2, rd;
  wire [6:0] opcode;
  wire [2:0] f3;
  wire [6:0] f7;
  wire [31:0] imm_I, imm_S, imm_B, imm_U, imm_J;

  assign insn = i_imem_rdata;
  decoder u_decoder (
      .i_insn(insn),
      .o_rs1(rs1),
      .o_rs2(rs2),
      .o_rd(rd),
      .o_opcode(opcode),
      .o_funct3(f3),
      .o_funct7(f7),
      .o_imm_I(imm_I),
      .o_imm_S(imm_S),
      .o_imm_B(imm_B),
      .o_imm_U(imm_U),
      .o_imm_J(imm_J)
  );

  // Valid in execute state.
  reg [31:0] pc_q;
  reg [31:0] insn_q;
  reg [4:0] rs1_q, rs2_q, rd_q;
  reg [6:0] opcode_q;
  reg [2:0] f3_q;
  reg [6:0] f7_q;
  reg [31:0] imm_I_q, imm_S_q, imm_B_q, imm_U_q, imm_J_q;

  reg [31:0] load_eff_addr_q;
  reg [31:0] store_eff_addr_q;
  reg        mem_align_trap;    // set in fetch when load/store address is misaligned

  // IMEM {{
  assign o_imem_addr  = pc;
  assign o_imem_valid = cpu_state == cpu_state_fetch;
  // }}

  // DMEM (read) {{
  reg [31:0] dmem_raddr;
  reg [31:0] dmem_rdata;
  assign o_dmem_raddr  = dmem_raddr;
  assign o_dmem_rvalid = cpu_state == cpu_state_load;
  // }}

  // DMEM (write) {{
  reg [31:0] dmem_waddr;
  reg [31:0] dmem_wdata;
  reg [ 3:0] dmem_wstrb;

  assign o_dmem_waddr  = dmem_waddr;
  assign o_dmem_wdata  = dmem_wdata;
  assign o_dmem_wstrb  = dmem_wstrb;
  assign o_dmem_wvalid = cpu_state == cpu_state_store;
  // }}

  wire [31:0] load_addr_full = X[rs1] + imm_I;
  wire [31:0] store_addr_full = X[rs1] + imm_S;

  wire insn_lui_q = { opcode_q } == { 7'b0110111 },
  insn_auipc_q = { opcode_q } == { 7'b0010111 },
  insn_jal_q = { opcode_q } == { 7'b1101111 },
  insn_jalr_q = { opcode_q, f3_q } == { 7'b1100111, 3'b000 },

  insn_beq_q = { opcode_q, f3_q } == { 7'b1100011, 3'b000 },
  insn_bne_q = { opcode_q, f3_q } == { 7'b1100011, 3'b001 },
  insn_blt_q = { opcode_q, f3_q } == { 7'b1100011, 3'b100 },
  insn_bge_q = { opcode_q, f3_q } == { 7'b1100011, 3'b101 },
  insn_bltu_q = { opcode_q, f3_q } == { 7'b1100011, 3'b110 },
  insn_bgeu_q = { opcode_q, f3_q } == { 7'b1100011, 3'b111 },

  insn_lb_q = { opcode_q, f3_q } == { 7'b0000011, 3'b000 },
  insn_lh_q = { opcode_q, f3_q } == { 7'b0000011, 3'b001 },
  insn_lw_q = { opcode_q, f3_q } == { 7'b0000011, 3'b010 },
  insn_lbu_q = { opcode_q, f3_q } == { 7'b0000011, 3'b100 },
  insn_lhu_q = { opcode_q, f3_q } == { 7'b0000011, 3'b101 },

  insn_sb_q = { opcode_q, f3_q } == { 7'b0100011, 3'b000 },
  insn_sh_q = { opcode_q, f3_q } == { 7'b0100011, 3'b001 },
  insn_sw_q = { opcode_q, f3_q } == { 7'b0100011, 3'b010 },

  insn_addi_q = { opcode_q, f3_q } == { 7'b0010011, 3'b000 },
  insn_slti_q = { opcode_q, f3_q } == { 7'b0010011, 3'b010 },
  insn_sltiu_q = { opcode_q, f3_q } == { 7'b0010011, 3'b011 },
  insn_xori_q   = { opcode_q, f3_q } == { 7'b0010011, 3'b100 },
  insn_ori_q    = { opcode_q, f3_q } == { 7'b0010011, 3'b110 },
  insn_andi_q   = { opcode_q, f3_q } == { 7'b0010011, 3'b111 },

  insn_slli_q   = { opcode_q, f3_q, f7_q } == { 7'b0010011, 3'b001, 7'b0000000 },
  insn_srli_q   = { opcode_q, f3_q, f7_q } == { 7'b0010011, 3'b101, 7'b0000000 },
  insn_srai_q   = { opcode_q, f3_q, f7_q } == { 7'b0010011, 3'b101, 7'b0100000 },

  insn_add_q    = { opcode_q, f3_q, f7_q } == { 7'b0110011, 3'b000, 7'b0000000 },
  insn_sub_q    = { opcode_q, f3_q, f7_q } == { 7'b0110011, 3'b000, 7'b0100000 },
  insn_sll_q    = { opcode_q, f3_q, f7_q } == { 7'b0110011, 3'b001, 7'b0000000 },
  insn_slt_q    = { opcode_q, f3_q, f7_q } == { 7'b0110011, 3'b010, 7'b0000000 },
  insn_sltu_q   = { opcode_q, f3_q, f7_q } == { 7'b0110011, 3'b011, 7'b0000000 },
  insn_xor_q    = { opcode_q, f3_q, f7_q } == { 7'b0110011, 3'b100, 7'b0000000 },
  insn_srl_q    = { opcode_q, f3_q, f7_q } == { 7'b0110011, 3'b101, 7'b0000000 },
  insn_sra_q    = { opcode_q, f3_q, f7_q } == { 7'b0110011, 3'b101, 7'b0100000 },
  insn_or_q     = { opcode_q, f3_q, f7_q } == { 7'b0110011, 3'b110, 7'b0000000 },
  insn_and_q    = { opcode_q, f3_q, f7_q } == { 7'b0110011, 3'b111, 7'b0000000 },

  insn_fence_q  = { opcode_q } == { 7'b0001111 },
  insn_ecall_q  = { opcode_q, f3_q, insn_q[31:20] } == { 7'b1110011, 3'b000, 12'b000000000000 },
  insn_ebreak_q = { opcode_q, f3_q, insn_q[31:20] } == { 7'b1110011, 3'b000, 12'b000000000001 },
  insn_mret_q = { opcode_q, f3_q, insn_q[31:20] }   == { 7'b1110011, 3'b000, 12'b001100000010 },

  // System
  insn_csrrw_q = { opcode_q, f3_q } == { 7'b1110011, 3'b001 },
  insn_csrrs_q = { opcode_q, f3_q } == { 7'b1110011, 3'b010 },
  insn_csrrc_q = { opcode_q, f3_q } == { 7'b1110011, 3'b011 },
  insn_csrrwi_q = { opcode_q, f3_q } == { 7'b1110011, 3'b101 },
  insn_csrrsi_q = { opcode_q, f3_q } == { 7'b1110011, 3'b110 },
  insn_csrrci_q = { opcode_q, f3_q } == { 7'b1110011, 3'b111 };

  reg write_rd;
  reg [31:0] pc_next;
  reg [31:0] rs1_val, rs2_val, rd_val;
  reg  [31:0] jalr_target;
  reg  [ 4:0] shamt;

  wire [11:0] csr_addr = insn_q[31:20];
  reg [3:0] csr_rs, csr_rd;
  reg [31:0] csr_rd_val;
  reg        write_csr_rd;

  // Forwarding: latch last write from execute so next instruction can bypass
  reg [ 4:0] rd_prev_q;
  reg [31:0] rd_val_prev;
  reg        write_rd_prev;

`ifdef RISCV_FORMAL
  // RVFI internal state
  reg [63:0] rvfi_order_cnt;
  // Latch pre-execution register values and memory data for RVFI reporting
  reg [31:0] rvfi_rs1_rdata_q;
  reg [31:0] rvfi_rs2_rdata_q;
  reg [31:0] rvfi_mem_rdata_q;
  reg [31:0] rvfi_mem_wdata_q;
  reg [31:0] rvfi_mem_addr_q;
  reg [ 3:0] rvfi_mem_rmask_q;
  reg [ 3:0] rvfi_mem_wmask_q;
  // Latch pre-execution CSR values
  reg [31:0] rvfi_csr_mstatus_pre;
  reg [31:0] rvfi_csr_mtvec_pre;
  reg [31:0] rvfi_csr_mscratch_pre;
  reg [31:0] rvfi_csr_mepc_pre;
  reg [31:0] rvfi_csr_mcause_pre;
  reg [31:0] rvfi_csr_mtval_pre;
  // Track intr (first insn of trap handler)
  reg        rvfi_intr_q;
`endif

  integer reg_idx;
  always @(posedge i_clk) begin
    if (!i_rst_n) begin
      o_trap <= 1'b0;
      cpu_state <= cpu_state_fetch;
      pc <= 32'b0;
      write_rd_prev <= 1'b0;
      mem_align_trap <= 1'b0;
      for (reg_idx = 0; reg_idx < 32; reg_idx = reg_idx + 1) X[reg_idx] <= 32'b0;
      for (reg_idx = 0; reg_idx < mcsr_max; reg_idx = reg_idx + 1)
      CSR[reg_idx] <= (reg_idx == misa) ? 32'h4000_0100 : 32'b0;  // RV32I in misa
`ifdef RISCV_FORMAL
      rvfi_valid       <= 1'b0;
      rvfi_order       <= 64'b0;
      rvfi_order_cnt   <= 64'b0;
      rvfi_intr_q      <= 1'b0;
      rvfi_mem_rmask_q <= 4'b0;
      rvfi_mem_wmask_q <= 4'b0;
      rvfi_mem_addr_q  <= 32'b0;
      rvfi_mem_rdata_q <= 32'b0;
      rvfi_mem_wdata_q <= 32'b0;
`endif
    end else begin
`ifdef RISCV_FORMAL
      rvfi_valid <= 1'b0;  // default; overridden by execute/load/store on retirement
`endif
      case (cpu_state)
        cpu_state_fetch: begin
          if (i_imem_ready) begin
            pc_q <= pc;
            insn_q <= insn;
            rd_q <= rd;
            rs1_q <= rs1;
            rs2_q <= rs2;
            opcode_q <= opcode;
            f3_q <= f3;
            f7_q <= f7;
            imm_I_q <= imm_I;
            imm_S_q <= imm_S;
            imm_B_q <= imm_B;
            imm_U_q <= imm_U;
            imm_J_q <= imm_J;

`ifdef RISCV_FORMAL
            // Capture pre-execution register values for RVFI.
            // The register file already reflects any write from the
            // previous instruction (non-blocking assignment took effect),
            // so a direct read is correct — no forwarding needed here.
            rvfi_rs1_rdata_q <= X[rs1];
            rvfi_rs2_rdata_q <= X[rs2];
            // CSR pre-values
            rvfi_csr_mstatus_pre  <= CSR[mstatus];
            rvfi_csr_mtvec_pre    <= CSR[mtvec];
            rvfi_csr_mscratch_pre <= CSR[mscratch];
            rvfi_csr_mepc_pre     <= CSR[mepc];
            rvfi_csr_mcause_pre   <= CSR[mcause];
            rvfi_csr_mtval_pre    <= CSR[mtval];
            // Reset mem masks for non-memory instructions
            rvfi_mem_rmask_q <= 4'b0;
            rvfi_mem_wmask_q <= 4'b0;
            rvfi_mem_addr_q  <= 32'b0;
            rvfi_mem_rdata_q <= 32'b0;
            rvfi_mem_wdata_q <= 32'b0;
`endif

            if (opcode == 7'b0000011 &&
                (f3 == 3'b000 || f3 == 3'b001 || f3 == 3'b010 ||
                 f3 == 3'b100 || f3 == 3'b101)) begin  // Load (valid funct3)
              load_eff_addr_q <= load_addr_full;
              // Check alignment: LH/LHU need 2-byte, LW needs 4-byte alignment
              if ((f3 == 3'b001 || f3 == 3'b101) && load_addr_full[0]) begin
                // LH/LHU misaligned
                mem_align_trap <= 1'b1;
                cpu_state <= cpu_state_load;
              end else if (f3 == 3'b010 && load_addr_full[1:0] != 2'b00) begin
                // LW misaligned
                mem_align_trap <= 1'b1;
                cpu_state <= cpu_state_load;
              end else begin
                mem_align_trap <= 1'b0;
                cpu_state <= cpu_state_load;
              end
              dmem_raddr <= load_addr_full & 32'hffff_fffc;
`ifdef RISCV_FORMAL
              rvfi_mem_addr_q  <= load_addr_full & 32'hffff_fffc;
              rvfi_mem_wmask_q <= 4'b0;
              case (f3)
                3'b000: rvfi_mem_rmask_q <= 4'b0001 << load_addr_full[1:0];  // lb
                3'b001: rvfi_mem_rmask_q <= load_addr_full[1] ? 4'b1100 : 4'b0011;  // lh
                3'b010: rvfi_mem_rmask_q <= 4'b1111;  // lw
                3'b100: rvfi_mem_rmask_q <= 4'b0001 << load_addr_full[1:0];  // lbu
                3'b101: rvfi_mem_rmask_q <= load_addr_full[1] ? 4'b1100 : 4'b0011;  // lhu
                default: rvfi_mem_rmask_q <= 4'b0;
              endcase
`endif
            end else if (opcode == 7'b0100011 &&
                         (f3 == 3'b000 || f3 == 3'b001 || f3 == 3'b010)) begin  // Store (valid funct3)
              cpu_state <= cpu_state_store;
              store_eff_addr_q <= store_addr_full;
              dmem_waddr <= store_addr_full & 32'hffff_fffc;
              // Check alignment: SH needs 2-byte, SW needs 4-byte alignment
              if ((f3 == 3'b001) && store_addr_full[0]) begin
                mem_align_trap <= 1'b1;  // SH misaligned
              end else if (f3 == 3'b010 && store_addr_full[1:0] != 2'b00) begin
                mem_align_trap <= 1'b1;  // SW misaligned
              end else begin
                mem_align_trap <= 1'b0;
              end

              case (f3)
                3'b000: begin  // sb
                  dmem_wstrb <= 4'b0001 << store_addr_full[1:0];
                  dmem_wdata <= {4{X[rs2][7:0]}};
`ifdef RISCV_FORMAL
                  rvfi_mem_addr_q  <= store_addr_full & 32'hffff_fffc;
                  rvfi_mem_rmask_q <= 4'b0;
                  rvfi_mem_wmask_q <= 4'b0001 << store_addr_full[1:0];
                  rvfi_mem_wdata_q <= {4{X[rs2][7:0]}};
`endif
                end
                3'b001: begin  // sh
                  dmem_wstrb <= store_addr_full[1] == 1'b1 ? 4'b1100 : 4'b0011;
                  dmem_wdata <= {2{X[rs2][15:0]}};
`ifdef RISCV_FORMAL
                  rvfi_mem_addr_q  <= store_addr_full & 32'hffff_fffc;
                  rvfi_mem_rmask_q <= 4'b0;
                  rvfi_mem_wmask_q <= store_addr_full[1] ? 4'b1100 : 4'b0011;
                  rvfi_mem_wdata_q <= {2{X[rs2][15:0]}};
`endif
                end
                3'b010: begin  // sw
                  dmem_wstrb <= 4'b1111;
                  dmem_wdata <= X[rs2];
`ifdef RISCV_FORMAL
                  rvfi_mem_addr_q  <= store_addr_full & 32'hffff_fffc;
                  rvfi_mem_rmask_q <= 4'b0;
                  rvfi_mem_wmask_q <= 4'b1111;
                  rvfi_mem_wdata_q <= X[rs2];
`endif
                end
                default: begin
                  dmem_wstrb <= 4'b0000;
                  dmem_wdata <= 32'b0;
                end
              endcase  // case (f3)
            end else begin
              // All other opcodes (including load/store with invalid funct3)
              // are handled in cpu_state_execute where the combinational `trap`
              // signal will assert for unrecognized encodings.
              cpu_state <= cpu_state_execute;
            end
          end
        end  // case: cpu_state_fetch

        cpu_state_execute: begin
          if (insn_ecall_q || insn_ebreak_q || trap) begin
            // Save current pc to mepc (the address of the ecall/trap instruction).
            CSR[mepc] <= pc_q;

            // Set the cause.
            if (insn_ecall_q) CSR[mcause] <= 32'd11;  // Machine-mode environment call
            else if (insn_ebreak_q) CSR[mcause] <= 32'd3;  // Breakpoint
            else CSR[mcause] <= trap_cause;  // 0 = insn misaligned, 2 = illegal

            // mtval: zero for ecall/ebreak/illegal traps.
            CSR[mtval] <= 32'b0;

            // Jump to handler and reset state.
            pc <= CSR[mtvec];
            cpu_state <= cpu_state_fetch;
            o_trap <= 1'b1;

`ifdef RISCV_FORMAL
            rvfi_valid      <= 1'b1;
            rvfi_order      <= rvfi_order_cnt;
            rvfi_order_cnt  <= rvfi_order_cnt + 1;
            rvfi_insn       <= insn_q;
            rvfi_trap       <= 1'b1;
            rvfi_halt       <= 1'b0;
            rvfi_intr       <= rvfi_intr_q;
            rvfi_intr_q     <= 1'b0;
            rvfi_mode       <= 2'b11;  // M-mode
            rvfi_ixl        <= 2'b01;  // XLEN=32
            rvfi_rs1_addr   <= rs1_q;
            rvfi_rs2_addr   <= rs2_q;
            rvfi_rs1_rdata  <= (rs1_q == 5'b0) ? 32'b0 : rvfi_rs1_rdata_q;
            rvfi_rs2_rdata  <= (rs2_q == 5'b0) ? 32'b0 : rvfi_rs2_rdata_q;
            rvfi_rd_addr    <= 5'b0;
            rvfi_rd_wdata   <= 32'b0;
            rvfi_pc_rdata   <= pc_q;
            rvfi_pc_wdata   <= CSR[mtvec];
            rvfi_mem_addr   <= 32'b0;
            rvfi_mem_rmask  <= 4'b0;
            rvfi_mem_wmask  <= 4'b0;
            rvfi_mem_rdata  <= 32'b0;
            rvfi_mem_wdata  <= 32'b0;
            // Trap writes mepc, mcause, mtval; mstatus could change too
            // Report pre/post for written CSRs; others report pre=post (no change)
            rvfi_csr_mstatus_rmask  <= 32'b0;
            rvfi_csr_mstatus_wmask  <= 32'b0;
            rvfi_csr_mstatus_rdata  <= rvfi_csr_mstatus_pre;
            rvfi_csr_mstatus_wdata  <= rvfi_csr_mstatus_pre;
            rvfi_csr_mtvec_rmask    <= 32'hffff_ffff;
            rvfi_csr_mtvec_wmask    <= 32'b0;
            rvfi_csr_mtvec_rdata    <= rvfi_csr_mtvec_pre;
            rvfi_csr_mtvec_wdata    <= rvfi_csr_mtvec_pre;
            rvfi_csr_mscratch_rmask <= 32'b0;
            rvfi_csr_mscratch_wmask <= 32'b0;
            rvfi_csr_mscratch_rdata <= rvfi_csr_mscratch_pre;
            rvfi_csr_mscratch_wdata <= rvfi_csr_mscratch_pre;
            rvfi_csr_mepc_rmask     <= 32'b0;
            rvfi_csr_mepc_wmask     <= 32'hffff_ffff;
            rvfi_csr_mepc_rdata     <= rvfi_csr_mepc_pre;
            rvfi_csr_mepc_wdata     <= pc_q;
            rvfi_csr_mcause_rmask   <= 32'b0;
            rvfi_csr_mcause_wmask   <= 32'hffff_ffff;
            rvfi_csr_mcause_rdata   <= rvfi_csr_mcause_pre;
            rvfi_csr_mcause_wdata   <= insn_ecall_q  ? 32'd11 :
                                       insn_ebreak_q ? 32'd3  : trap_cause;
            rvfi_csr_mtval_rmask    <= 32'b0;
            rvfi_csr_mtval_wmask    <= 32'hffff_ffff;
            rvfi_csr_mtval_rdata    <= rvfi_csr_mtval_pre;
            rvfi_csr_mtval_wdata    <= 32'b0;
`endif
          end else begin
            if (write_rd && rd_q != 5'b0) begin
              X[rd_q] <= rd_val;
              write_rd_prev <= 1'b1;
              rd_prev_q <= rd_q;
              rd_val_prev <= rd_val;
            end
            if (write_csr_rd) CSR[csr_rd] <= csr_rd_val;
            pc <= pc_next;
            cpu_state <= cpu_state_fetch;

`ifdef RISCV_FORMAL
            rvfi_valid      <= 1'b1;
            rvfi_order      <= rvfi_order_cnt;
            rvfi_order_cnt  <= rvfi_order_cnt + 1;
            rvfi_insn       <= insn_q;
            rvfi_trap       <= 1'b0;
            rvfi_halt       <= 1'b0;
            rvfi_intr       <= rvfi_intr_q;
            rvfi_intr_q     <= 1'b0;
            rvfi_mode       <= 2'b11;  // M-mode
            rvfi_ixl        <= 2'b01;  // XLEN=32
            rvfi_rs1_addr   <= rs1_q;
            rvfi_rs2_addr   <= rs2_q;
            rvfi_rs1_rdata  <= (rs1_q == 5'b0) ? 32'b0 : rvfi_rs1_rdata_q;
            rvfi_rs2_rdata  <= (rs2_q == 5'b0) ? 32'b0 : rvfi_rs2_rdata_q;
            rvfi_rd_addr    <= (write_rd && rd_q != 5'b0) ? rd_q  : 5'b0;
            rvfi_rd_wdata   <= (write_rd && rd_q != 5'b0) ? rd_val : 32'b0;
            rvfi_pc_rdata   <= pc_q;
            rvfi_pc_wdata   <= pc_next;
            rvfi_mem_addr   <= 32'b0;
            rvfi_mem_rmask  <= 4'b0;
            rvfi_mem_wmask  <= 4'b0;
            rvfi_mem_rdata  <= 32'b0;
            rvfi_mem_wdata  <= 32'b0;
            // CSR ports: report reads/writes for CSR instructions
            begin : rvfi_csr_exec
              reg csr_active;
              csr_active = insn_csrrw_q | insn_csrrs_q | insn_csrrc_q |
                           insn_csrrwi_q | insn_csrrsi_q | insn_csrrci_q;
              // mstatus
              rvfi_csr_mstatus_rmask  <= (csr_active && csr_rs == mstatus) ? 32'hffff_ffff : 32'b0;
              rvfi_csr_mstatus_wmask  <= (write_csr_rd && csr_rd == mstatus) ? 32'hffff_ffff : 32'b0;
              rvfi_csr_mstatus_rdata  <= rvfi_csr_mstatus_pre;
              rvfi_csr_mstatus_wdata  <= (write_csr_rd && csr_rd == mstatus) ? csr_rd_val : rvfi_csr_mstatus_pre;
              // mtvec
              rvfi_csr_mtvec_rmask    <= (csr_active && csr_rs == mtvec) ? 32'hffff_ffff : 32'b0;
              rvfi_csr_mtvec_wmask    <= (write_csr_rd && csr_rd == mtvec) ? 32'hffff_ffff : 32'b0;
              rvfi_csr_mtvec_rdata    <= rvfi_csr_mtvec_pre;
              rvfi_csr_mtvec_wdata    <= (write_csr_rd && csr_rd == mtvec) ? csr_rd_val : rvfi_csr_mtvec_pre;
              // mscratch
              rvfi_csr_mscratch_rmask <= (csr_active && csr_rs == mscratch) ? 32'hffff_ffff : 32'b0;
              rvfi_csr_mscratch_wmask <= (write_csr_rd && csr_rd == mscratch) ? 32'hffff_ffff : 32'b0;
              rvfi_csr_mscratch_rdata <= rvfi_csr_mscratch_pre;
              rvfi_csr_mscratch_wdata <= (write_csr_rd && csr_rd == mscratch) ? csr_rd_val : rvfi_csr_mscratch_pre;
              // mepc
              rvfi_csr_mepc_rmask     <= (csr_active && csr_rs == mepc) ? 32'hffff_ffff : 32'b0;
              rvfi_csr_mepc_wmask     <= (write_csr_rd && csr_rd == mepc) ? 32'hffff_ffff : 32'b0;
              rvfi_csr_mepc_rdata     <= rvfi_csr_mepc_pre;
              rvfi_csr_mepc_wdata     <= (write_csr_rd && csr_rd == mepc) ? csr_rd_val : rvfi_csr_mepc_pre;
              // mcause
              rvfi_csr_mcause_rmask   <= (csr_active && csr_rs == mcause) ? 32'hffff_ffff : 32'b0;
              rvfi_csr_mcause_wmask   <= (write_csr_rd && csr_rd == mcause) ? 32'hffff_ffff : 32'b0;
              rvfi_csr_mcause_rdata   <= rvfi_csr_mcause_pre;
              rvfi_csr_mcause_wdata   <= (write_csr_rd && csr_rd == mcause) ? csr_rd_val : rvfi_csr_mcause_pre;
              // mtval
              rvfi_csr_mtval_rmask    <= (csr_active && csr_rs == mtval) ? 32'hffff_ffff : 32'b0;
              rvfi_csr_mtval_wmask    <= (write_csr_rd && csr_rd == mtval) ? 32'hffff_ffff : 32'b0;
              rvfi_csr_mtval_rdata    <= rvfi_csr_mtval_pre;
              rvfi_csr_mtval_wdata    <= (write_csr_rd && csr_rd == mtval) ? csr_rd_val : rvfi_csr_mtval_pre;
            end
`endif
          end
        end

        cpu_state_load: begin
          if (mem_align_trap) begin
            // Misaligned load — raise load-address-misaligned exception.
            CSR[mepc]   <= pc_q;
            CSR[mcause] <= 32'd4;  // Load address misaligned
            CSR[mtval]  <= load_eff_addr_q;
            pc          <= CSR[mtvec];
            cpu_state   <= cpu_state_fetch;
            o_trap      <= 1'b1;
            mem_align_trap <= 1'b0;
            write_rd_prev  <= 1'b0;
`ifdef RISCV_FORMAL
            rvfi_valid     <= 1'b1;
            rvfi_order     <= rvfi_order_cnt;
            rvfi_order_cnt <= rvfi_order_cnt + 1;
            rvfi_insn      <= insn_q;
            rvfi_trap      <= 1'b1;
            rvfi_halt      <= 1'b0;
            rvfi_intr      <= rvfi_intr_q;
            rvfi_intr_q    <= 1'b0;
            rvfi_mode      <= 2'b11;
            rvfi_ixl       <= 2'b01;
            rvfi_rs1_addr  <= rs1_q;
            rvfi_rs2_addr  <= 5'b0;
            rvfi_rs1_rdata <= (rs1_q == 5'b0) ? 32'b0 : rvfi_rs1_rdata_q;
            rvfi_rs2_rdata <= 32'b0;
            rvfi_rd_addr   <= 5'b0;
            rvfi_rd_wdata  <= 32'b0;
            rvfi_pc_rdata  <= pc_q;
            rvfi_pc_wdata  <= CSR[mtvec];
            rvfi_mem_addr  <= rvfi_mem_addr_q;
            rvfi_mem_rmask <= rvfi_mem_rmask_q;
            rvfi_mem_wmask <= 4'b0;
            rvfi_mem_rdata <= 32'b0;
            rvfi_mem_wdata <= 32'b0;
            rvfi_csr_mstatus_rmask  <= 32'b0;
            rvfi_csr_mstatus_wmask  <= 32'b0;
            rvfi_csr_mstatus_rdata  <= rvfi_csr_mstatus_pre;
            rvfi_csr_mstatus_wdata  <= rvfi_csr_mstatus_pre;
            rvfi_csr_mtvec_rmask    <= 32'b0;
            rvfi_csr_mtvec_wmask    <= 32'b0;
            rvfi_csr_mtvec_rdata    <= rvfi_csr_mtvec_pre;
            rvfi_csr_mtvec_wdata    <= rvfi_csr_mtvec_pre;
            rvfi_csr_mscratch_rmask <= 32'b0;
            rvfi_csr_mscratch_wmask <= 32'b0;
            rvfi_csr_mscratch_rdata <= rvfi_csr_mscratch_pre;
            rvfi_csr_mscratch_wdata <= rvfi_csr_mscratch_pre;
            rvfi_csr_mepc_rmask     <= 32'b0;
            rvfi_csr_mepc_wmask     <= 32'hffff_ffff;
            rvfi_csr_mepc_rdata     <= rvfi_csr_mepc_pre;
            rvfi_csr_mepc_wdata     <= pc_q;
            rvfi_csr_mcause_rmask   <= 32'b0;
            rvfi_csr_mcause_wmask   <= 32'hffff_ffff;
            rvfi_csr_mcause_rdata   <= rvfi_csr_mcause_pre;
            rvfi_csr_mcause_wdata   <= 32'd4;
            rvfi_csr_mtval_rmask    <= 32'b0;
            rvfi_csr_mtval_wmask    <= 32'hffff_ffff;
            rvfi_csr_mtval_rdata    <= rvfi_csr_mtval_pre;
            rvfi_csr_mtval_wdata    <= load_eff_addr_q;
`endif
          end else
          if (i_dmem_rready) begin
`ifdef RISCV_FORMAL
            rvfi_mem_rdata_q <= i_dmem_rdata;
`endif
            if (rd_q != 5'b0) begin
              case (f3_q)
                3'b000: begin  // lb
                  case (load_eff_addr_q[1:0])
                    2'b00: X[rd_q] <= {{24{i_dmem_rdata[7]}}, i_dmem_rdata[7:0]};
                    2'b01: X[rd_q] <= {{24{i_dmem_rdata[15]}}, i_dmem_rdata[15:8]};
                    2'b10: X[rd_q] <= {{24{i_dmem_rdata[23]}}, i_dmem_rdata[23:16]};
                    2'b11: X[rd_q] <= {{24{i_dmem_rdata[31]}}, i_dmem_rdata[31:24]};
                  endcase  // case (load_eff_addr_q[1:0])
                end

                3'b001: begin  // lh
                  if (load_eff_addr_q[1] == 1'b1)
                    X[rd_q] <= {{16{i_dmem_rdata[31]}}, i_dmem_rdata[31:16]};
                  else X[rd_q] <= {{16{i_dmem_rdata[15]}}, i_dmem_rdata[15:0]};
                end

                3'b010: begin  // lw
                  X[rd_q] <= i_dmem_rdata;
                end

                3'b100: begin  // lbu
                  case (load_eff_addr_q[1:0])
                    2'b00: X[rd_q] <= {24'b0, i_dmem_rdata[7:0]};
                    2'b01: X[rd_q] <= {24'b0, i_dmem_rdata[15:8]};
                    2'b10: X[rd_q] <= {24'b0, i_dmem_rdata[23:16]};
                    2'b11: X[rd_q] <= {24'b0, i_dmem_rdata[31:24]};
                  endcase  // case (load_eff_addr_q[1:0])
                end

                3'b101: begin  // lhu
                  if (load_eff_addr_q[1] == 1'b1) X[rd_q] <= {16'b0, i_dmem_rdata[31:16]};
                  else X[rd_q] <= {16'b0, i_dmem_rdata[15:0]};
                end
              endcase  // case (f3_q)
            end  // rd_q != 0

            // Clear forwarding state: load result is now in X[]; next fetch
            // must read from X[] directly, not from a stale rd_val_prev.
            write_rd_prev <= 1'b0;

            pc <= pc_next;
            cpu_state <= cpu_state_fetch;

`ifdef RISCV_FORMAL
            rvfi_valid      <= 1'b1;
            rvfi_order      <= rvfi_order_cnt;
            rvfi_order_cnt  <= rvfi_order_cnt + 1;
            rvfi_insn       <= insn_q;
            rvfi_trap       <= 1'b0;
            rvfi_halt       <= 1'b0;
            rvfi_intr       <= rvfi_intr_q;
            rvfi_intr_q     <= 1'b0;
            rvfi_mode       <= 2'b11;
            rvfi_ixl        <= 2'b01;
            rvfi_rs1_addr   <= rs1_q;
            rvfi_rs2_addr   <= 5'b0;
            rvfi_rs1_rdata  <= (rs1_q == 5'b0) ? 32'b0 : rvfi_rs1_rdata_q;
            rvfi_rs2_rdata  <= 32'b0;
            rvfi_rd_addr    <= rd_q;
            // rd_wdata is what was written — 0 when rd=x0 (no write)
            if (rd_q == 5'b0) begin
              rvfi_rd_wdata <= 32'b0;
            end else begin
              case (f3_q)
                3'b000: begin  // lb
                  case (load_eff_addr_q[1:0])
                    2'b00: rvfi_rd_wdata <= {{24{i_dmem_rdata[7]}},  i_dmem_rdata[7:0]};
                    2'b01: rvfi_rd_wdata <= {{24{i_dmem_rdata[15]}}, i_dmem_rdata[15:8]};
                    2'b10: rvfi_rd_wdata <= {{24{i_dmem_rdata[23]}}, i_dmem_rdata[23:16]};
                    2'b11: rvfi_rd_wdata <= {{24{i_dmem_rdata[31]}}, i_dmem_rdata[31:24]};
                  endcase
                end
                3'b001: begin  // lh
                  rvfi_rd_wdata <= load_eff_addr_q[1] ?
                    {{16{i_dmem_rdata[31]}}, i_dmem_rdata[31:16]} :
                    {{16{i_dmem_rdata[15]}}, i_dmem_rdata[15:0]};
                end
                3'b010:  rvfi_rd_wdata <= i_dmem_rdata;  // lw
                3'b100: begin  // lbu
                  case (load_eff_addr_q[1:0])
                    2'b00: rvfi_rd_wdata <= {24'b0, i_dmem_rdata[7:0]};
                    2'b01: rvfi_rd_wdata <= {24'b0, i_dmem_rdata[15:8]};
                    2'b10: rvfi_rd_wdata <= {24'b0, i_dmem_rdata[23:16]};
                    2'b11: rvfi_rd_wdata <= {24'b0, i_dmem_rdata[31:24]};
                  endcase
                end
                3'b101: begin  // lhu
                  rvfi_rd_wdata <= load_eff_addr_q[1] ?
                    {16'b0, i_dmem_rdata[31:16]} : {16'b0, i_dmem_rdata[15:0]};
                end
                default: rvfi_rd_wdata <= 32'b0;
              endcase
            end
            rvfi_pc_rdata   <= pc_q;
            rvfi_pc_wdata   <= pc_next;
            rvfi_mem_addr   <= rvfi_mem_addr_q;
            rvfi_mem_rmask  <= rvfi_mem_rmask_q;
            rvfi_mem_wmask  <= 4'b0;
            rvfi_mem_rdata  <= i_dmem_rdata;
            rvfi_mem_wdata  <= 32'b0;
            rvfi_csr_mstatus_rmask  <= 32'b0; rvfi_csr_mstatus_wmask  <= 32'b0;
            rvfi_csr_mstatus_rdata  <= rvfi_csr_mstatus_pre; rvfi_csr_mstatus_wdata  <= rvfi_csr_mstatus_pre;
            rvfi_csr_mtvec_rmask    <= 32'b0; rvfi_csr_mtvec_wmask    <= 32'b0;
            rvfi_csr_mtvec_rdata    <= rvfi_csr_mtvec_pre; rvfi_csr_mtvec_wdata    <= rvfi_csr_mtvec_pre;
            rvfi_csr_mscratch_rmask <= 32'b0; rvfi_csr_mscratch_wmask <= 32'b0;
            rvfi_csr_mscratch_rdata <= rvfi_csr_mscratch_pre; rvfi_csr_mscratch_wdata <= rvfi_csr_mscratch_pre;
            rvfi_csr_mepc_rmask     <= 32'b0; rvfi_csr_mepc_wmask     <= 32'b0;
            rvfi_csr_mepc_rdata     <= rvfi_csr_mepc_pre; rvfi_csr_mepc_wdata     <= rvfi_csr_mepc_pre;
            rvfi_csr_mcause_rmask   <= 32'b0; rvfi_csr_mcause_wmask   <= 32'b0;
            rvfi_csr_mcause_rdata   <= rvfi_csr_mcause_pre; rvfi_csr_mcause_wdata   <= rvfi_csr_mcause_pre;
            rvfi_csr_mtval_rmask    <= 32'b0; rvfi_csr_mtval_wmask    <= 32'b0;
            rvfi_csr_mtval_rdata    <= rvfi_csr_mtval_pre; rvfi_csr_mtval_wdata    <= rvfi_csr_mtval_pre;
`endif
          end
        end  // case: cpu_state_load

        cpu_state_store: begin
          if (mem_align_trap) begin
            // Misaligned store — raise store-address-misaligned exception.
            CSR[mepc]   <= pc_q;
            CSR[mcause] <= 32'd6;  // Store/AMO address misaligned
            CSR[mtval]  <= store_eff_addr_q;
            pc          <= CSR[mtvec];
            cpu_state   <= cpu_state_fetch;
            o_trap      <= 1'b1;
            mem_align_trap <= 1'b0;
            write_rd_prev  <= 1'b0;
`ifdef RISCV_FORMAL
            rvfi_valid     <= 1'b1;
            rvfi_order     <= rvfi_order_cnt;
            rvfi_order_cnt <= rvfi_order_cnt + 1;
            rvfi_insn      <= insn_q;
            rvfi_trap      <= 1'b1;
            rvfi_halt      <= 1'b0;
            rvfi_intr      <= rvfi_intr_q;
            rvfi_intr_q    <= 1'b0;
            rvfi_mode      <= 2'b11;
            rvfi_ixl       <= 2'b01;
            rvfi_rs1_addr  <= rs1_q;
            rvfi_rs2_addr  <= rs2_q;
            rvfi_rs1_rdata <= (rs1_q == 5'b0) ? 32'b0 : rvfi_rs1_rdata_q;
            rvfi_rs2_rdata <= (rs2_q == 5'b0) ? 32'b0 : rvfi_rs2_rdata_q;
            rvfi_rd_addr   <= 5'b0;
            rvfi_rd_wdata  <= 32'b0;
            rvfi_pc_rdata  <= pc_q;
            rvfi_pc_wdata  <= CSR[mtvec];
            rvfi_mem_addr  <= rvfi_mem_addr_q;
            rvfi_mem_rmask <= 4'b0;
            rvfi_mem_wmask <= rvfi_mem_wmask_q;
            rvfi_mem_rdata <= 32'b0;
            rvfi_mem_wdata <= rvfi_mem_wdata_q;
            rvfi_csr_mstatus_rmask  <= 32'b0;
            rvfi_csr_mstatus_wmask  <= 32'b0;
            rvfi_csr_mstatus_rdata  <= rvfi_csr_mstatus_pre;
            rvfi_csr_mstatus_wdata  <= rvfi_csr_mstatus_pre;
            rvfi_csr_mtvec_rmask    <= 32'b0;
            rvfi_csr_mtvec_wmask    <= 32'b0;
            rvfi_csr_mtvec_rdata    <= rvfi_csr_mtvec_pre;
            rvfi_csr_mtvec_wdata    <= rvfi_csr_mtvec_pre;
            rvfi_csr_mscratch_rmask <= 32'b0;
            rvfi_csr_mscratch_wmask <= 32'b0;
            rvfi_csr_mscratch_rdata <= rvfi_csr_mscratch_pre;
            rvfi_csr_mscratch_wdata <= rvfi_csr_mscratch_pre;
            rvfi_csr_mepc_rmask     <= 32'b0;
            rvfi_csr_mepc_wmask     <= 32'hffff_ffff;
            rvfi_csr_mepc_rdata     <= rvfi_csr_mepc_pre;
            rvfi_csr_mepc_wdata     <= pc_q;
            rvfi_csr_mcause_rmask   <= 32'b0;
            rvfi_csr_mcause_wmask   <= 32'hffff_ffff;
            rvfi_csr_mcause_rdata   <= rvfi_csr_mcause_pre;
            rvfi_csr_mcause_wdata   <= 32'd6;
            rvfi_csr_mtval_rmask    <= 32'b0;
            rvfi_csr_mtval_wmask    <= 32'hffff_ffff;
            rvfi_csr_mtval_rdata    <= rvfi_csr_mtval_pre;
            rvfi_csr_mtval_wdata    <= store_eff_addr_q;
`endif
          end else
          if (i_dmem_wready) begin
            pc <= pc_next;
            cpu_state <= cpu_state_fetch;

`ifdef RISCV_FORMAL
            rvfi_valid      <= 1'b1;
            rvfi_order      <= rvfi_order_cnt;
            rvfi_order_cnt  <= rvfi_order_cnt + 1;
            rvfi_insn       <= insn_q;
            rvfi_trap       <= 1'b0;
            rvfi_halt       <= 1'b0;
            rvfi_intr       <= rvfi_intr_q;
            rvfi_intr_q     <= 1'b0;
            rvfi_mode       <= 2'b11;
            rvfi_ixl        <= 2'b01;
            rvfi_rs1_addr   <= rs1_q;
            rvfi_rs2_addr   <= rs2_q;
            rvfi_rs1_rdata  <= (rs1_q == 5'b0) ? 32'b0 : rvfi_rs1_rdata_q;
            rvfi_rs2_rdata  <= (rs2_q == 5'b0) ? 32'b0 : rvfi_rs2_rdata_q;
            rvfi_rd_addr    <= 5'b0;
            rvfi_rd_wdata   <= 32'b0;
            rvfi_pc_rdata   <= pc_q;
            rvfi_pc_wdata   <= pc_next;
            rvfi_mem_addr   <= rvfi_mem_addr_q;
            rvfi_mem_rmask  <= 4'b0;
            rvfi_mem_wmask  <= rvfi_mem_wmask_q;
            rvfi_mem_rdata  <= 32'b0;
            rvfi_mem_wdata  <= rvfi_mem_wdata_q;
            rvfi_csr_mstatus_rmask  <= 32'b0; rvfi_csr_mstatus_wmask  <= 32'b0;
            rvfi_csr_mstatus_rdata  <= rvfi_csr_mstatus_pre; rvfi_csr_mstatus_wdata  <= rvfi_csr_mstatus_pre;
            rvfi_csr_mtvec_rmask    <= 32'b0; rvfi_csr_mtvec_wmask    <= 32'b0;
            rvfi_csr_mtvec_rdata    <= rvfi_csr_mtvec_pre; rvfi_csr_mtvec_wdata    <= rvfi_csr_mtvec_pre;
            rvfi_csr_mscratch_rmask <= 32'b0; rvfi_csr_mscratch_wmask <= 32'b0;
            rvfi_csr_mscratch_rdata <= rvfi_csr_mscratch_pre; rvfi_csr_mscratch_wdata <= rvfi_csr_mscratch_pre;
            rvfi_csr_mepc_rmask     <= 32'b0; rvfi_csr_mepc_wmask     <= 32'b0;
            rvfi_csr_mepc_rdata     <= rvfi_csr_mepc_pre; rvfi_csr_mepc_wdata     <= rvfi_csr_mepc_pre;
            rvfi_csr_mcause_rmask   <= 32'b0; rvfi_csr_mcause_wmask   <= 32'b0;
            rvfi_csr_mcause_rdata   <= rvfi_csr_mcause_pre; rvfi_csr_mcause_wdata   <= rvfi_csr_mcause_pre;
            rvfi_csr_mtval_rmask    <= 32'b0; rvfi_csr_mtval_wmask    <= 32'b0;
            rvfi_csr_mtval_rdata    <= rvfi_csr_mtval_pre; rvfi_csr_mtval_wdata    <= rvfi_csr_mtval_pre;
`endif
          end
        end
      endcase  // case (cpu_state)
    end
  end  // always @ (posedge i_clk)

  always @(*) begin
    trap = 1'b0;
    trap_cause = 32'd2;  // default: illegal instruction
    write_rd = 1'b0;
    pc_next = pc_q + 4;
    rs1_val = (write_rd_prev && rs1_q == rd_prev_q && rd_prev_q != 5'b0) ? rd_val_prev : X[rs1_q];
    rs2_val = (write_rd_prev && rs2_q == rd_prev_q && rd_prev_q != 5'b0) ? rd_val_prev : X[rs2_q];
    rd_val = 32'b0;
    jalr_target = 32'b0;
    shamt = 5'b0;

    csr_rs = 4'b0;
    csr_rd = 4'b0;
    csr_rd_val = 32'b0;
    write_csr_rd = 1'b0;

    trap_cause = 32'd2;  // default: illegal instruction
    if (insn_lui_q) begin
      write_rd = 1'b1;
      rd_val   = imm_U_q;
    end else if (insn_auipc_q) begin
      write_rd = 1'b1;
      rd_val   = pc_q + imm_U_q;
    end else if (insn_jal_q) begin
      write_rd = 1'b1;
      rd_val   = pc_q + 4;
      pc_next  = pc_q + imm_J_q;
      if (pc_next[1:0] != 2'b00) begin trap = 1'b1; trap_cause = 32'd0; end
    end else if (insn_jalr_q) begin
      jalr_target = (rs1_val + imm_I_q) & 32'hffff_fffe;
      if (jalr_target[1:0] != 2'b00) begin
        trap = 1'b1; trap_cause = 32'd0;
      end else begin
        write_rd = 1'b1;
        rd_val = pc_q + 4;
        pc_next = jalr_target;
      end
    end else if (insn_beq_q) begin
      if (rs1_val == rs2_val) pc_next = pc_q + imm_B_q;
      if (pc_next[1:0] != 2'b00) begin trap = 1'b1; trap_cause = 32'd0; end
    end else if (insn_bne_q) begin
      if (rs1_val != rs2_val) pc_next = pc_q + imm_B_q;
      if (pc_next[1:0] != 2'b00) begin trap = 1'b1; trap_cause = 32'd0; end
    end else if (insn_blt_q) begin
      if ($signed(rs1_val) < $signed(rs2_val)) pc_next = pc_q + imm_B_q;
      if (pc_next[1:0] != 2'b00) begin trap = 1'b1; trap_cause = 32'd0; end
    end else if (insn_bge_q) begin
      if ($signed(rs1_val) >= $signed(rs2_val)) pc_next = pc_q + imm_B_q;
      if (pc_next[1:0] != 2'b00) begin trap = 1'b1; trap_cause = 32'd0; end
    end else if (insn_bltu_q) begin
      if ($unsigned(rs1_val) < $unsigned(rs2_val)) pc_next = pc_q + imm_B_q;
      if (pc_next[1:0] != 2'b00) begin trap = 1'b1; trap_cause = 32'd0; end
    end else if (insn_bgeu_q) begin
      if ($unsigned(rs1_val) >= $unsigned(rs2_val)) pc_next = pc_q + imm_B_q;
      if (pc_next[1:0] != 2'b00) begin trap = 1'b1; trap_cause = 32'd0; end
    end else if (insn_lb_q || insn_lh_q || insn_lw_q || insn_lbu_q || insn_lhu_q) begin
      // Do nothing here.
    end else if (insn_sb_q || insn_sh_q || insn_sw_q) begin
      // Do nothing here.
    end else if (insn_addi_q) begin
      write_rd = 1'b1;
      rd_val   = rs1_val + imm_I_q;
    end else if (insn_slti_q) begin
      write_rd = 1'b1;
      rd_val   = $signed(rs1_val) < $signed(imm_I_q) ? 32'd1 : 32'd0;
    end else if (insn_sltiu_q) begin
      write_rd = 1'b1;
      rd_val   = $unsigned(rs1_val) < $unsigned(imm_I_q) ? 32'd1 : 32'd0;
    end else if (insn_xori_q) begin
      write_rd = 1'b1;
      rd_val   = rs1_val ^ imm_I_q;
    end else if (insn_ori_q) begin
      write_rd = 1'b1;
      rd_val   = rs1_val | imm_I_q;
    end else if (insn_andi_q) begin
      write_rd = 1'b1;
      rd_val   = rs1_val & imm_I_q;
    end else if (insn_slli_q) begin
      shamt = insn_q[24:20] & 5'h1f;
      write_rd = 1'b1;
      rd_val = rs1_val << shamt;
    end else if (insn_srli_q) begin
      shamt = insn_q[24:20] & 5'h1f;
      write_rd = 1'b1;
      rd_val = rs1_val >> shamt;
    end else if (insn_srai_q) begin
      shamt = insn_q[24:20] & 5'h1f;
      write_rd = 1'b1;
      rd_val = $signed(rs1_val) >>> shamt;
    end else if (insn_add_q) begin
      write_rd = 1'b1;
      rd_val   = rs1_val + rs2_val;
    end else if (insn_sub_q) begin
      write_rd = 1'b1;
      rd_val   = rs1_val - rs2_val;
    end else if (insn_sll_q) begin
      shamt = rs2_val[4:0] & 5'h1f;
      write_rd = 1'b1;
      rd_val = rs1_val << shamt;
    end else if (insn_slt_q) begin
      write_rd = 1'b1;
      rd_val   = $signed(rs1_val) < $signed(rs2_val) ? 32'd1 : 32'd0;
    end else if (insn_sltu_q) begin
      write_rd = 1'b1;
      rd_val   = rs1_val < rs2_val ? 32'd1 : 32'd0;
    end else if (insn_xor_q) begin
      write_rd = 1'b1;
      rd_val   = rs1_val ^ rs2_val;
    end else if (insn_srl_q) begin
      shamt = rs2_val[4:0] & 5'h1f;
      write_rd = 1'b1;
      rd_val = rs1_val >> shamt;
    end else if (insn_sra_q) begin
      shamt = rs2_val[4:0] & 5'h1f;
      write_rd = 1'b1;
      rd_val = $signed(rs1_val) >>> shamt;
    end else if (insn_or_q) begin
      write_rd = 1'b1;
      rd_val   = rs1_val | rs2_val;
    end else if (insn_and_q) begin
      write_rd = 1'b1;
      rd_val   = rs1_val & rs2_val;
    end else
    if (insn_ecall_q) begin
    end else
    if (insn_ebreak_q) begin
    end else
    if (insn_fence_q) begin
    end else if (insn_mret_q) begin
      pc_next = CSR[mepc];
    end else if (insn_csrrw_q || insn_csrrs_q || insn_csrrc_q ||
       insn_csrrwi_q || insn_csrrsi_q || insn_csrrci_q) begin
      case (csr_addr)
        12'h300: begin
          csr_rs = mstatus;
          csr_rd = mstatus;
        end
        12'h301: begin
          csr_rs = misa;
          csr_rd = misa;
        end
        12'h304: begin
          csr_rs = mie;
          csr_rd = mie;
        end
        12'h744: begin
          csr_rs = mnstatus;
          csr_rd = mnstatus;
        end
        12'h305: begin
          csr_rs = mtvec;
          csr_rd = mtvec;
        end
        12'h340: begin
          csr_rs = mscratch;
          csr_rd = mscratch;
        end
        12'h341: begin
          csr_rs = mepc;
          csr_rd = mepc;
        end
        12'h342: begin
          csr_rs = mcause;
          csr_rd = mcause;
        end
        12'h343: begin
          csr_rs = mtval;
          csr_rd = mtval;
        end
        12'h344: begin
          csr_rs = mip;
          csr_rd = mip;
        end
        12'hf14: begin
          csr_rs = mhartid;
          csr_rd = mhartid;
        end
        default: trap = 1'b1;
      endcase  // case (csr_addr)

      write_rd = 1'b1;
      rd_val   = CSR[csr_rs];

      if (insn_csrrw_q) begin
        write_csr_rd = 1'b1;
        csr_rd_val   = rs1_val;
      end else if (insn_csrrs_q) begin
        write_csr_rd = (rs1_q != 5'b0);
        csr_rd_val   = CSR[csr_rs] | rs1_val;
      end else if (insn_csrrc_q) begin
        write_csr_rd = (rs1_q != 5'b0);
        csr_rd_val   = CSR[csr_rs] & ~rs1_val;
      end else if (insn_csrrwi_q) begin
        write_csr_rd = 1'b1;
        csr_rd_val   = {27'b0, rs1_q};
      end else if (insn_csrrsi_q) begin
        write_csr_rd = (rs1_q != 5'b0);
        csr_rd_val   = CSR[csr_rs] | {27'b0, rs1_q};
      end else begin  // csrrci
        write_csr_rd = (rs1_q != 5'b0);
        csr_rd_val   = CSR[csr_rs] & ~{27'b0, rs1_q};
      end
    end else begin
      trap = 1'b1;
    end
  end  // always @ (*)

endmodule  // nyanrv
