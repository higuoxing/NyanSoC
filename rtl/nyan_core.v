`default_nettype none `timescale 1 ns / 1 ps

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
		  output wire [31:0] o_dmem_addr,
		  output wire [31:0] o_dmem_wdata,
		  output wire [3:0]  o_dmem_wstrb,
		  output wire	     o_dmem_valid,
		  input wire [31:0]  i_dmem_rdata,
		  input wire	     i_dmem_ready
		  // }}
);

   // Program counter and registers.
   wire reset;
   wire	clk;

   reg [31:0] pc;
   reg [31:0] X[32];

   reg [31:0] instr;
   wire [4:0]  rs1;
   wire [4:0]  rs2;
   wire [4:0]  rd;
   wire [6:0]  opcode;
   wire [2:0]  funct3;
   wire [6:0]  funct7;

   wire [31:0] imm_i;
   wire [31:0] imm_s;
   wire [31:0] imm_b;
   wire [31:0] imm_u;
   wire [31:0] imm_j;
   wire [31:0] rs1_val;
   wire [31:0] rs2_val;

   reg	       take_branch;
   reg	       write_rd;
   reg [31:0]  rd_val;
   reg [31:0]  pc_next;
   reg [1:0]   cpu_state;
   reg	       store_instr;
   reg [31:0]  store_addr;
   reg [31:0]  store_data;
   localparam  MEM_STORE_NONE = 2'd0;
   localparam  MEM_STORE_BYTE = 2'd1;
   localparam  MEM_STORE_HALF = 2'd2;
   localparam  MEM_STORE_WORD = 2'd3;
   reg [1:0]   store_data_type;

   localparam  CPU_STATE_FETCH = 2'd0;
   localparam  CPU_STATE_EXECUTE = 2'd1;
   localparam  CPU_STATE_MEM_REQ = 2'd3;

   reg [31:0]  imem_addr;
   reg	       imem_valid;

   reg [31:0]  dmem_addr;
   reg [31:0]  dmem_wdata;
   reg [3:0]   dmem_wstrb;
   reg	       dmem_valid;

   assign clk = i_clk;
   assign reset = !i_rst_n;

   assign o_imem_addr = imem_addr;
   assign o_imem_valid = imem_valid;

   assign o_dmem_addr = dmem_addr;
   assign o_dmem_valid = dmem_valid;
   assign o_dmem_wdata = dmem_wdata;
   assign o_dmem_wstrb = dmem_wstrb;

   assign rs1 = instr[19:15];
   assign rs2 = instr[24:20];
   assign rd = instr[11:7];
   assign opcode = instr[6:0];
   assign funct3 = instr[14:12];
   assign funct7 = instr[31:25];
   // Immediates (Ch2. RV32I Base Integer Instruction Set).
   // {{
   // I-type.
   assign imm_i = {{21{instr[31]}}, instr[30:20]};
   // S-type.
   assign imm_s = {{21{instr[31]}}, instr[30:25], instr[11:8], instr[7]};
   // B-type.
   assign imm_b = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
   // U-type.
   assign imm_u = {instr[31], instr[30:20], instr[19:12], 12'b0};
   // J-type.
   assign imm_j = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:25], instr[24:21], 1'b0};
   // }}
   assign rs1_val = (rs1 == 0) ? 32'b0 : X[rs1];
   assign rs2_val = (rs2 == 0) ? 32'b0 : X[rs2];

   // CPU state machine.
   always @(posedge clk) begin
      if (reset) begin
	 pc <= 32'b0;
	 instr <= 32'b0;
	 imem_addr <= 32'b0;
	 imem_valid <= 32'b0;
	 cpu_state <= CPU_STATE_FETCH;

	 dmem_addr <= 32'b0;
	 dmem_valid <= 1'b0;
	 dmem_wdata <= 32'b0;
	 dmem_wstrb <= 4'b0;
      end else begin // if (reset)
	 dmem_addr <= 32'b0;
	 dmem_valid <= 1'b0;
	 dmem_wdata <= 32'b0;
	 dmem_wstrb <= 4'b0;

	 case (cpu_state)
	   CPU_STATE_FETCH: begin
	      if (imem_valid && i_imem_ready) begin
		 instr <= i_imem_rdata;
		 imem_valid <= 1'b0;
		 cpu_state <= CPU_STATE_EXECUTE;
	      end else begin
		 // Stall, waiting for instruction memory.
		 imem_addr <= pc;
		 imem_valid <= 1'b1;
	      end
	   end
	   CPU_STATE_EXECUTE: begin
	      if (store_instr) begin
		 dmem_addr <= store_addr;
		 dmem_valid <= 1'b1;
		 dmem_wdata <= store_data;
		 case (store_data_type)
		   MEM_STORE_BYTE: begin
		      dmem_wstrb <= 4'b0001;
		   end
		   MEM_STORE_HALF: begin
		   end
		   MEM_STORE_WORD: begin
		   end
		   MEM_STORE_NONE: begin
		      // Invalid instruction.
		   end
		 endcase // case (store_data_type)
	      end else begin
		 // For non-load/store instructions.
		 pc <= pc_next;
		 imem_addr <= pc_next;
		 imem_valid <= 1'b1;
		 cpu_state <= CPU_STATE_FETCH;
	      end
	   end
	 endcase // case (cpu_state)
      end
   end // always @ (posedge clk)

   integer i;
   always @(posedge clk) begin
      if (reset) begin
	 for (i = 0; i < 32; i = i + 1) begin
	    X[i] <= 32'b0;
	 end
      end else if (cpu_state == CPU_STATE_EXECUTE) begin
	 if (write_rd && rd != 0) begin
	    X[rd] <= rd_val;
	 end
      end
   end // always @ (posedge clk)

   always @(*) begin
      take_branch = 1'b0;
      write_rd = 1'b0;
      pc_next = pc + 4;
      rd_val = 32'b0;
      store_instr = 1'b0;
      store_addr = 32'b0;
      store_data_type = MEM_STORE_NONE;

      case (opcode)
	7'b0000011: begin
	   case (funct3)
	     3'b000: begin // lb
		// TODO.
	     end
	   endcase // case (funct3)
	end
	7'b0010011: begin
	   case (funct3)
	     3'b000: begin // addi
		rd_val = rs1_val + imm_i;
		write_rd = 1'b1;
	     end
	     // slti
	     // sltiu
	     // xori
	     // ori
	     // andi
	     // slli
	     // srli
	     // srai
	     default: begin
		// NOP.
	     end
	   endcase
	end // case: 7'b0010011

	7'b0010111: begin // auipc
	   rd_val = pc + imm_u;
	   write_rd = 1'b1;
	end

	7'b0100011: begin
	   case (funct3)
	     3'b000: begin // sb
		store_instr = 1'b1;
		store_addr = rs1_val + imm_i;
		store_data_type = MEM_STORE_BYTE;
		store_data = rs2_val[7:0];
	     end
	   endcase // case (funct3)
	end

	7'b0110011: begin
	   case (funct3)
	     3'b000: begin // add/sub
		if (funct7 == 7'b0000000) begin // add
		   rd_val = rs1_val + rs2_val;
		   write_rd = 1'b1;
		end
		else if (funct7 == 7'b0100000) begin // sub
		   rd_val = rs1_val - rs2_val;
		   write_rd = 1'b1;
		end
	     end
	     // sll
	     // slt
	     // sltu
	     // xor
	     // srl
	     // sra
	     // or
	     // and
	   endcase
	end // case: 7'b0110011

	7'b0110111: begin // lui
	   rd_val = imm_u;
	   write_rd = 1'b1;
	end

	// UJ-type
	7'b1101111: begin
	   write_rd = 1'b1;
	   rd_val = pc + 4;
	   pc_next = pc + imm_j;
	end
	// SB-type
	7'b1100011: begin
	   case (funct3)
	     3'b000: begin // beq
		if (rs1_val == rs2_val) begin
		   take_branch = 1'b1;
		   pc_next = pc + imm_b;
		end
	     end
	     3'b001: begin // bne
		if (rs1_val != rs2_val) begin
		   take_branch = 1'b1;
		   pc_next = pc + imm_b;
		end
	     end
	     default: begin
		// NOP.
	     end
	   endcase // case (funct3)
	end // case: 7'b1100011
	default: begin
	   // NOP.
	end
      endcase // case (opcode)
   end // always @ (*)

endmodule // nyan_core
