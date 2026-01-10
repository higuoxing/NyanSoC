module nyan_core_tb;
   reg clk = 0;
   reg rst_n = 0;

   wire	[31:0] imem_addr;
   wire	       imem_valid;
   reg [31:0]  imem_rdata;
   reg	       imem_ready;
   reg [7:0]   mem[0:1023];

   nyan_core dut(.i_clk(clk),
		 .i_rst_n(rst_n),
		 .o_imem_addr(imem_addr),
		 .o_imem_valid(imem_valid),
		 .i_imem_rdata(imem_rdata),
		 .i_imem_ready(imem_ready));

   always #5 clk = ~clk;

   initial begin
      $readmemh("imem.hex", mem);
      #20 rst_n = 1;
      #1000 $finish;
   end

   always @(posedge clk) begin
      if (!rst_n) begin
	 imem_ready <= 1'b0;
	 imem_rdata <= 32'b0;
      end else begin
	 if (imem_valid) begin
      	    imem_rdata <= {mem[imem_addr + 3],
      			   mem[imem_addr + 2],
      			   mem[imem_addr + 1],
      			   mem[imem_addr]};
      	    imem_ready <= 1'b1;
	 end else begin
	    imem_ready <= 1'b0;
	 end
      end
   end

   always @(posedge clk) begin
      if (rst_n) begin
	 $display("pc=%h addr=%h valid=%d ready=%d cpu_state=%s instr=%h X[1]=%d X[2]=%d", dut.pc, dut.imem_addr, dut.imem_valid, imem_ready, dut.cpu_state == 0 ? "fetch" : "exec", dut.instr, dut.X[1], dut.X[2]);
      end
   end
endmodule // nyan_core_tb
