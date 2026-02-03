`default_nettype none `timescale 1 ns / 1 ps

module decode_insn(
		   input wire [31:0]  i_insn,
		   output wire [4:0]  o_rs1,
		   output wire [4:0]  o_rs2,
		   output wire [4:0]  o_rd,
		   output wire [6:0]  o_opcode,
		   output wire [2:0]  o_funct3,
		   output wire [6:0]  o_funct7,
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

endmodule // decode_insn

module nyan_core (
		  input wire	     i_clk,
		  input wire	     i_rst_n,

		  // Instruction Memory
		  // {{
		  output wire [31:0] o_imem_addr,
		  output wire	     o_imem_valid,
		  input wire [31:0]  i_imem_rdata,
		  input wire	     i_imem_ready,
		  // }}

		  // Data Memory
		  // {{
		  //    Read ports
		  output wire [31:0] o_dmem_raddr,
		  output wire	     o_dmem_rvalid,
		  input wire [31:0]  i_dmem_rdata,
		  input wire	     i_dmem_rready,

		  //    Write ports
		  output wire [31:0] o_dmem_waddr,
		  output wire	     o_dmem_wvalid,
		  output wire [3:0]  o_dmem_wstrb,
		  output wire [31:0] o_dmem_wdata,
		  input wire	     i_dmem_wready,
		  // }}

		  output reg	     o_trap
);
   reg trap;

   reg [31:0] pc;
   reg [31:0] X[32];

   reg [1:0]   cpu_state;
   localparam  cpu_state_fetch = 2'b00;
   localparam  cpu_state_execute = 2'b01;
   localparam  cpu_state_store = 2'b10;
   localparam  cpu_state_load = 2'b11;

   // Valid in fetch state.
   wire [31:0] insn;
   wire [4:0]  rs1, rs2, rd;
   wire [6:0]  opcode;
   wire [2:0]  f3;
   wire [6:0]  f7;
   wire [31:0] imm_I, imm_S, imm_B, imm_U, imm_J;
   wire	       insn_lb, insn_lh, insn_lbu, insn_lhu, insn_lw,
	       insn_sb, insn_sh, insn_sw;

   assign insn = i_imem_rdata;
   decode_insn
     u_decode(
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
	      .o_imm_J(imm_J));


   assign insn_sb = { opcode, f3 } == { 7'b0100011, 3'b000 };
   assign insn_sh = { opcode, f3 } == { 7'b0100011, 3'b001 };
   assign insn_sw = { opcode, f3 } == { 7'b0100011, 3'b010 };

   // Valid in execute state.
   reg [31:0] pc_q;
   reg [31:0] insn_q;
   reg [4:0]  rs1_q, rs2_q, rd_q;
   reg [6:0]  opcode_q;
   reg [2:0]  f3_q;
   reg [6:0]  f7_q;
   reg [31:0] imm_I_q, imm_S_q, imm_B_q, imm_U_q, imm_J_q;

   reg [31:0]  load_eff_addr_q;
   reg [31:0]  store_eff_addr_q;

   // IMEM {{
   assign o_imem_addr = pc;
   assign o_imem_valid = cpu_state == cpu_state_fetch;
   // }}

   // DMEM (read) {{
   reg [31:0]  dmem_raddr;
   reg [31:0]  dmem_rdata;
   assign o_dmem_raddr = dmem_raddr;
   assign o_dmem_rvalid = cpu_state == cpu_state_load;
   // }}

   // DMEM (write) {{
   reg [31:0]  dmem_waddr;
   reg [31:0]  dmem_wdata;
   reg [3:0]   dmem_wstrb;
   reg	       dmem_wvalid;

   assign o_dmem_waddr = dmem_waddr;
   assign o_dmem_wdata = dmem_wdata;
   assign o_dmem_wstrb = dmem_wstrb;
   assign o_dmem_wvalid = cpu_state == cpu_state_store;
   // }}

   wire [31:0] load_addr_full = X[rs1] + imm_I;
   wire [31:0] store_addr_full = X[rs1] + imm_S;

   integer reg_idx;
   always @(posedge i_clk) begin
      if (!i_rst_n) begin
	 o_trap <= 1'b0;
	 pc <= 32'b0;
	 cpu_state <= cpu_state_fetch;

	 for (reg_idx = 0; reg_idx < 32; reg_idx = reg_idx + 1) X[reg_idx] <= 32'b0;
      end else begin
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
		 imm_I_q <= imm_I; imm_S_q <= imm_S; imm_B_q <= imm_B;
		 imm_U_q <= imm_U; imm_J_q <= imm_J;

		 if (opcode == 7'b0000011) begin // Load
		    cpu_state <= cpu_state_load;
		    load_eff_addr_q <= load_addr_full;
		    dmem_raddr <= load_addr_full & 32'hffff_fffc;
		 end else if (opcode == 7'b0100011) begin // Store
		    cpu_state <= cpu_state_store;
		    store_eff_addr_q <= store_addr_full;
		    dmem_waddr <= store_addr_full & 32'hffff_fffc;

		    case (f3)
		      3'b000: begin // sb
			 dmem_wstrb <= 4'b0001 << store_addr_full[1:0];
			 dmem_wdata <= {4{X[rs2][7:0]}};
		      end
		      3'b001: begin // sh
			 dmem_wstrb <= store_addr_full[1] == 1'b1 ? 4'b1100 : 4'b0011;
			 dmem_wdata <= {2{X[rs2][15:0]}};
		      end
		      3'b010: begin // sw
			 dmem_wstrb <= 4'b1111;
			 dmem_wdata <= X[rs2];
		      end
		    endcase // case (f3)
		 end else begin
		    cpu_state <= cpu_state_execute;
		 end
	      end
	   end // case: cpu_state_fetch

	   cpu_state_execute: begin
	      if (trap)
		o_trap <= 1'b1;
	      if (write_rd && rd_q != 5'b0) X[rd_q] <= rd_val;
	      pc <= pc_next;
	      cpu_state <= cpu_state_fetch;
	   end

	   cpu_state_load: begin
	      // Prevent writing to X[0].
	      if (i_dmem_rready && rd_q != 5'b0) begin
		 case (f3_q)
		   3'b000: begin // lb
		      case (load_eff_addr_q[1:0])
			2'b00: X[rd_q] <= {{24{i_dmem_rdata[7]}}, i_dmem_rdata[7:0]};
			2'b01: X[rd_q] <= {{24{i_dmem_rdata[15]}}, i_dmem_rdata[15:8]};
			2'b10: X[rd_q] <= {{24{i_dmem_rdata[23]}}, i_dmem_rdata[23:16]};
			2'b11: X[rd_q] <= {{24{i_dmem_rdata[31]}}, i_dmem_rdata[31:24]};
		      endcase // case (load_eff_addr_q[1:0])
		   end

		   3'b001: begin // lh
		      if (load_eff_addr_q[1] == 1'b1)
			X[rd_q] <= {{16{i_dmem_rdata[31]}}, i_dmem_rdata[31:16]};
		      else
			X[rd_q] <= {{16{i_dmem_rdata[15]}}, i_dmem_rdata[15:0]};
		   end

		   3'b010: begin // lw
		      X[rd_q] <= i_dmem_rdata;
		   end

		   3'b100: begin // lbu
		      case (load_eff_addr_q[1:0])
			2'b00: X[rd_q] <= {24'b0, i_dmem_rdata[7:0]};
			2'b01: X[rd_q] <= {24'b0, i_dmem_rdata[15:8]};
			2'b10: X[rd_q] <= {24'b0, i_dmem_rdata[23:16]};
			2'b11: X[rd_q] <= {24'b0, i_dmem_rdata[31:24]};
		      endcase // case (load_eff_addr_q[1:0])
		   end

		   3'b101: begin // lhu
		      if (load_eff_addr_q[1] == 1'b1)
			X[rd_q] <= {16'b0, i_dmem_rdata[31:16]};
		      else
			X[rd_q] <= {16'b0, i_dmem_rdata[15:0]};
		   end
		 endcase // case (f3_q)

		 pc <= pc_next;
		 cpu_state <= cpu_state_fetch;
	      end
	   end // case: cpu_state_load

	   cpu_state_store: begin
	      if (i_dmem_wready) begin
		 dmem_wvalid <= 1'b0;
		 pc <= pc_next;
		 cpu_state <= cpu_state_fetch;
	      end
	   end
	 endcase // case (cpu_state)
      end
   end // always @ (posedge i_clk)

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
	insn_ebreak_q = { opcode_q, f3_q, insn_q[31:20] } == { 7'b1110011, 3'b000, 12'b000000000001 };

   reg	take_branch;
   reg	write_rd;
   reg [31:0] pc_next;
   reg [31:0] rs1_val, rs2_val, rd_val;
   reg [31:0] jalr_target;
   reg [4:0]  shamt;

   always @(*) begin
      trap = 1'b0;
      take_branch = 1'b0;
      write_rd = 1'b0;
      pc_next = pc_q + 4;
      rs1_val = X[rs1_q];
      rs2_val = X[rs2_q];
      rd_val = 32'b0;
      jalr_target = 32'b0;
      shamt = 5'b0;

      if (insn_lui_q) begin
	 write_rd = 1'b1;
	 rd_val = imm_U_q;
      end else if (insn_auipc_q) begin
	 write_rd = 1'b1;
	 rd_val = pc_q + imm_U_q;
      end else if (insn_jal_q) begin
	 write_rd = 1'b1;
	 rd_val = pc_q + 4;
	 pc_next = pc_q + imm_J_q;
      end else if (insn_jalr_q) begin
	 write_rd = 1'b1;
	 jalr_target = (rs1_val + imm_I_q) & 32'hffff_fffe;
	 rd_val = pc_q + 4; // Save the return address.
	 pc_next = jalr_target;
      end else if (insn_beq_q) begin
	 if (rs1_val == rs2_val) begin
	    take_branch = 1'b1;
	    pc_next = pc_q + imm_B_q;
	 end
      end else if (insn_bne_q) begin
	 if (rs1_val != rs2_val) begin
	    take_branch = 1'b1;
	    pc_next = pc_q + imm_B_q;
	 end
      end else if (insn_blt_q) begin
	 if ($signed(rs1_val) < $signed(rs2_val)) begin
	    take_branch = 1'b1;
	    pc_next = pc_q + imm_B_q;
	 end
      end else if (insn_bge_q) begin
	 if ($signed(rs1_val) >= $signed(rs2_val)) begin
	    take_branch = 1'b1;
	    pc_next = pc_q + imm_B_q;
	 end
      end else if (insn_bltu_q) begin
	 if ($unsigned(rs1_val) < $unsigned(rs2_val)) begin
	    take_branch = 1'b1;
	    pc_next = pc_q + imm_B_q;
	 end
      end else if (insn_bgeu_q) begin
	 if ($unsigned(rs1_val) >= $unsigned(rs2_val)) begin
	    take_branch = 1'b1;
	    pc_next = pc_q + imm_B_q;
	 end
      end else if (insn_lb_q || insn_lh_q || insn_lw_q || insn_lbu_q || insn_lhu_q) begin
	 // Do nothing here.
      end else if (insn_sb_q || insn_sh_q || insn_sw_q) begin
	 // Do nothing here.
      end else if (insn_addi_q) begin
	 write_rd = 1'b1;
	 rd_val = rs1_val + imm_I_q;
      end else if (insn_slti_q) begin
	 write_rd = 1'b1;
	 rd_val = $signed(rs1_val) < $signed(imm_I_q) ? 32'b1 : 32'b0;
      end else if (insn_sltiu_q) begin
	 write_rd = 1'b1;
	 rd_val = $unsigned(rs1_val) < $unsigned(imm_I_q) ? 32'b1 : 32'b0;
      end else if (insn_xori_q) begin
	 write_rd = 1'b1;
	 rd_val = rs1_val ^ imm_I_q;
      end else if (insn_ori_q) begin
	 write_rd = 1'b1;
	 rd_val = rs1_val | imm_I_q;
      end else if (insn_andi_q) begin
	 write_rd = 1'b1;
	 rd_val = rs1_val & imm_I_q;
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
	 rd_val = rs1_val + rs2_val;
      end else if (insn_sub_q) begin
	 write_rd = 1'b1;
	 rd_val = rs1_val - rs2_val;
      end else if (insn_sll_q) begin
	 shamt = rs2_val[4:0] & 5'h1f;
	 write_rd = 1'b1;
	 rd_val = rs1_val << shamt;
      end else if (insn_slt_q) begin
	 write_rd = 1'b1;
	 rd_val = $signed(rs1_val) < $signed(rs2_val) ? 32'b1 : 32'b0;
      end else if (insn_sltu_q) begin
	 write_rd = 1'b1;
	 rd_val = rs1_val < rs2_val ? 32'b1 : 32'b0;
      end else if (insn_xor_q) begin
	 write_rd = 1'b1;
	 rd_val = rs1_val ^ rs2_val;
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
	 rd_val = rs1_val | rs2_val;
      end else if (insn_and_q) begin
	 write_rd = 1'b1;
	 rd_val = rs1_val & rs2_val;
      end else begin
	 trap = 1'b1;
      end
   end // always @ (*)

endmodule // nyan_core
