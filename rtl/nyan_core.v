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
   assign o_imm_S = {{21{i_insn[31]}}, i_insn[30:25], i_insn[11:8], i_insn[7]};
   // B-type.
   assign o_imm_B = {{20{i_insn[31]}}, i_insn[7], i_insn[30:25], i_insn[11:8], 1'b0};
   // U-type.
   assign o_imm_U = {i_insn[31], i_insn[30:20], i_insn[19:12], 12'b0};
   // J-type.
   assign o_imm_J = {{12{i_insn[31]}}, i_insn[19:12], i_insn[20], i_insn[30:25], i_insn[24:21], 1'b0};
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
		  input wire	     i_dmem_wready
		  // }}
);

   // Program counter and registers.
   wire reset;
   wire	clk;

   assign clk = i_clk;
   assign reset = !i_rst_n;

   reg [31:0] pc;
   reg [31:0] X[32];

   reg [31:0]  imem_addr;
   reg	       imem_valid;

   assign o_imem_addr = imem_addr;
   assign o_imem_valid = imem_valid;

   reg [31:0]  dmem_raddr;
   reg [31:0]  dmem_rdata;
   reg	       dmem_rvalid;

   assign o_dmem_raddr = dmem_raddr;
   assign o_dmem_rvalid = dmem_rvalid;

   reg [31:0]  dmem_waddr;
   reg [31:0]  dmem_wdata;
   reg [3:0]   dmem_wstrb;
   reg	       dmem_wvalid;

   assign o_dmem_waddr = dmem_waddr;
   assign o_dmem_wdata = dmem_wdata;
   assign o_dmem_wstrb = dmem_wstrb;
   assign o_dmem_wvalid = dmem_wvalid;

   reg [1:0]   cpu_state;
   localparam  cpu_state_fetch = 2'b00;
   localparam  cpu_state_execute = 2'b01;
   localparam  cpu_state_store = 2'b10;
   localparam  cpu_state_load = 2'b11;

   // Valid in fetch state.
   wire [31:0] insn;
   wire [4:0]  rs1, rs2, rd;
   wire [6:0]  opcode;
   wire [2:0]  funct3;
   wire [6:0]  funct7;
   wire [31:0] imm_I, imm_S, imm_B, imm_U, imm_J;
   wire	       insn_load;
   wire	       insn_store;

   assign insn_load = opcode == 7'b0000011 &&
		      (funct3 == 3'b000 || funct3 == 3'b001 ||
		       funct3 == 3'b010 || funct3 == 3'b100 || funct3 == 3'b101);
   assign insn_store = opcode == 7'b0100011 &&
		       (funct3 == 3'b000 || funct3 == 3'b001 || funct3 == 3'b010);

   localparam SB = 2'b01;
   localparam SH = 2'b10;
   localparam SW = 2'b11;
   wire [1:0]  store_type;

   assign store_type = (opcode == 7'b0100011 && funct3 == 3'b000) ? SB
		       : (opcode == 7'b0100011 && funct3 == 3'b001) ? SH
		       : opcode == 7'b0100011 && funct3 == 3'b010 ? SW
		       : 2'b00;

   // Valid in execute state.
   reg [31:0]  insn_q;
   reg [4:0]   rs1_q, rs2_q, rd_q;
   reg [6:0]   opcode_q;
   reg [2:0]   funct3_q;
   reg [6:0]   funct7_q;
   reg [31:0]  imm_I_q, imm_S_q, imm_B_q, imm_U_q, imm_J_q;
   reg	       insn_load_q;
   reg	       insn_store_q;

   assign insn = i_imem_rdata;
   decode_insn
     u_decode_insn(
		   .i_insn(insn),
		   .o_rs1(rs1),
		   .o_rs2(rs2),
		   .o_rd(rd),
		   .o_opcode(opcode),
		   .o_funct3(funct3),
		   .o_funct7(funct7),
		   .o_imm_I(imm_I),
		   .o_imm_S(imm_S),
		   .o_imm_B(imm_B),
		   .o_imm_U(imm_U),
		   .o_imm_J(imm_J));

   wire insn_lui = { opcode_q } == { 7'b0110111 },
	insn_addi = { opcode_q, funct3_q } == { 7'b0010011, 3'b000 },
	insn_add = { opcode_q, funct3_q, funct7_q } == { 7'b0110011, 3'b000, 7'b0000000 },
	insn_sub = { opcode_q, funct3_q, funct7_q } == { 7'b0110011, 3'b000, 7'b0100000 },
	insn_beq = { opcode_q, funct3_q } == { 7'b1100011, 3'b000 },
	insn_lb = { opcode_q, funct3_q } == { 7'b0000011, 3'b000 },
	insn_lh = { opcode_q, funct3_q } == { 7'b0000011, 3'b001 },
	insn_lw = { opcode_q, funct3_q } == { 7'b0000011, 3'b010 },
	insn_lbu = { opcode_q, funct3_q } == { 7'b0000011, 3'b100 },
	insn_lhu = { opcode_q, funct3_q } == { 7'b0000011, 3'b101 },
	insn_jal = { opcode_q } == { 7'b1101111 },
	insn_sb = { opcode_q, funct3_q } == { 7'b0100011, 3'b000 };

   integer reg_idx;
   always @(posedge clk) begin
      if (reset) begin
	 pc <= 32'b0;
	 imem_valid <= 1'b0;
	 imem_addr <= 32'b0;

	 dmem_raddr <= 32'b0;
	 dmem_rvalid <= 1'b0;

	 dmem_waddr <= 32'b0;
	 dmem_wdata <= 32'b0;
	 dmem_wstrb <= 4'b0;
	 dmem_wvalid <= 1'b0;

	 insn_q <= 32'b0;
	 rs1_q <= 5'b0;
	 rs2_q <= 5'b0;
	 rd_q <= 5'b0;
	 opcode_q <= 7'b0;
	 funct3_q <= 3'b0;
	 funct7_q <= 7'b0;
	 imm_I_q <= 32'b0;
	 imm_S_q <= 32'b0;
	 imm_B_q <= 32'b0;
	 imm_U_q <= 32'b0;
	 imm_J_q <= 32'b0;

	 // Reset regfile.
	 for (reg_idx = 0; reg_idx < 32; reg_idx = reg_idx + 1) begin
	    X[reg_idx] <= 32'b0;
	 end

	 cpu_state <= cpu_state_fetch;
      end else begin
	 case (cpu_state)
	   cpu_state_fetch: begin
	      imem_valid <= 1'b1;
	      imem_addr <= pc;
	      if (imem_valid && i_imem_ready) begin
		 cpu_state <= cpu_state_execute;
		 imem_valid <= 1'b0;

		 insn_q <= insn;
		 rs1_q <= rs1;
		 rs2_q <= rs2;
		 rd_q <= rd;
		 opcode_q <= opcode;
		 funct3_q <= funct3;
		 funct7_q <= funct7;
		 imm_I_q <= imm_I;
		 imm_S_q <= imm_S;
		 imm_B_q <= imm_B;
		 imm_U_q <= imm_U;
		 imm_J_q <= imm_J;

		 if (insn_load) begin
		    cpu_state <= cpu_state_load;

		    dmem_raddr <= imm_I + X[rs1];
		    dmem_rvalid <= 1'b1;
		 end else if (insn_store) begin
		    cpu_state <= cpu_state_store;

		    dmem_wvalid <= 1'b1;
		    dmem_waddr <= imm_S + X[rs1];
		    case (store_type)
		      SB: begin
			 dmem_wstrb <= 4'b0001 << (dmem_waddr[1:0]);
			 dmem_wdata <= {4{X[rs2][7:0]}} << (dmem_waddr[1:0] << 3);
		      end

		      SH: begin
			 dmem_wstrb <= dmem_waddr[1] ? 4'b1100 : 4'b0011;
			 dmem_wdata <= {2{X[rs2][15:0]}} << (dmem_waddr[1] << 4);
		      end

		      SW: begin
			 dmem_wstrb <= 4'b1111;
			 dmem_wdata <= X[rs2];
		      end
		    endcase // case (store_type)
		 end
	      end
	   end // case: cpu_state_fetch

	   cpu_state_execute: begin
	      if (write_rd && rd_q != 0) begin
		 X[rd_q] <= rd_val;
	      end

	      pc <= pc_next;
	      imem_addr <= pc_next;
	      cpu_state <= cpu_state_fetch;
	      imem_valid <= 1'b1;
	   end

	   cpu_state_store: begin
	      if (dmem_wvalid && i_dmem_wready) begin
		 dmem_wvalid <= 1'b0;

		 pc <= pc_next;
		 imem_addr <= pc_next;
		 cpu_state <= cpu_state_fetch;
		 imem_valid <= 1'b1;
	      end
	   end

	   cpu_state_load: begin
	      if (dmem_rvalid && i_dmem_rready) begin
		 if (insn_lb) begin
		    X[rd_q][7:0] <= $signed(i_dmem_rdata[7:0]);
		 end else if (insn_lbu) begin
		    X[rd_q][7:0] <= $unsigned(i_dmem_rdata[7:0]);
		 end else if (insn_lh) begin
		    X[rd_q][15:0] <= $signed(i_dmem_rdata[15:0]);
		 end else if (insn_lhu) begin
		    X[rd_q][15:0] <= $unsigned(i_dmem_rdata[15:0]);
		 end else if (insn_lw) begin
		    X[rd_q] <= i_dmem_rdata;
		 end

		 dmem_rvalid <= 1'b0;

		 pc <= pc_next;
		 imem_addr <= pc_next;
		 cpu_state <= cpu_state_fetch;
		 imem_valid <= 1'b1;
	      end
	   end
	 endcase // case (cpu_state)
      end
   end // always @ (posedge clk)


   reg	take_branch;
   reg	write_rd;
   reg [31:0] pc_next;
   reg [31:0] rs1_val, rs2_val, rd_val;

   always @(*) begin
      take_branch = 1'b0;
      write_rd = 1'b0;
      pc_next = pc + 4;
      rs1_val = X[rs1_q];
      rs2_val = X[rs2_q];
      rd_val = 32'b0;
      insn_load_q = 1'b0;
      insn_store_q = 1'b0;

      if (insn_lui) begin
	 write_rd = 1'b1;
	 rd_val = imm_U_q;
      end else if (insn_jal) begin
	 write_rd = 1'b1;
	 rd_val = pc + 4;
	 pc_next = pc + imm_J_q;
      end else if (insn_addi) begin
	 write_rd = 1'b1;
	 rd_val = rs1_val + imm_I_q;
      end else if (insn_add) begin
	 write_rd = 1'b1;
	 rd_val = rs1_val + rs2_val;
      end else if (insn_sub) begin
	 write_rd = 1'b1;
	 rd_val = rs1_val - rs2_val;
      end else if (insn_beq) begin
	 if (rs1_val == rs2_val) begin
	    take_branch = 1'b1;
	    pc_next = pc + imm_B_q;
	 end
      end else if (insn_lb || insn_lh || insn_lw) begin
      end
   end // always @ (*)

endmodule // nyan_core
