module nyan_core_tb;
   reg clk = 0;
   reg rst_n = 0;

   wire	[31:0] imem_addr;
   wire	       imem_valid;
   reg [31:0]  imem_rdata;
   reg	       imem_ready;
   reg [7:0]   imem[0:1023];
   wire [31:0] dmem_raddr;
   wire	       dmem_rvalid;
   reg [31:0]  dmem_rdata;
   reg	       dmem_rready;
   wire [31:0] dmem_waddr;
   wire [31:0] dmem_wdata;
   wire [3:0]  dmem_wstrb;
   wire	       dmem_wvalid;
   reg	       dmem_wready;

   nyan_core nyan_core_dut0(.i_clk(clk),
			    .i_rst_n(rst_n),
			    .o_imem_addr(imem_addr),
			    .o_imem_valid(imem_valid),
			    .i_imem_rdata(imem_rdata),
			    .i_imem_ready(imem_ready),
			    .o_dmem_raddr(dmem_raddr),
			    .o_dmem_rvalid(dmem_rvalid),
			    .i_dmem_rdata(dmem_rdata),
			    .i_dmem_rready(dmem_rready),
			    .o_dmem_waddr(dmem_waddr),
			    .o_dmem_wdata(dmem_wdata),
			    .o_dmem_wstrb(dmem_wstrb),
			    .o_dmem_wvalid(dmem_wvalid),
			    .i_dmem_wready(dmem_wready));

   always #5 clk = ~clk;

   initial begin
      $readmemh("imem.hex", imem);
      #20 rst_n = 1;
      #2000 $finish;
   end

   always @(posedge clk) begin
      if (!rst_n) begin
	 imem_ready <= 1'b0;
	 imem_rdata <= 32'b0;
      end else begin
	 if (imem_valid) begin
      	    imem_rdata <= {imem[imem_addr + 3],
      			   imem[imem_addr + 2],
      			   imem[imem_addr + 1],
      			   imem[imem_addr]};
      	    imem_ready <= 1'b1;
	 end else begin
	    imem_ready <= 1'b0;
	 end
      end
   end // always @ (posedge clk)

   // dmem read logic.
   always @(posedge clk) begin
      if (!rst_n) begin
	 dmem_rready <= 1'b0;
	 dmem_rdata <= 32'b0;
      end else begin
	 if (dmem_rvalid) begin
	    dmem_rdata <= {imem[dmem_raddr + 3],
      			   imem[dmem_raddr + 2],
      			   imem[dmem_raddr + 1],
      			   imem[dmem_raddr]};
	    dmem_rready <= 1'b1;
	 end else begin
	    dmem_rready <= 1'b0;
	 end
      end
   end // always @ (posedge clk)

   // dmem write logic.
   always @(posedge clk) begin
      if (!rst_n) begin
	 dmem_wready <= 1'b0;
      end else begin
	 if (dmem_wvalid) begin
	    if (dmem_wstrb[0])
	      imem[dmem_waddr] <= dmem_wdata[7:0];
	    if (dmem_wstrb[1])
	      imem[dmem_waddr + 1] <= dmem_wdata[15:8];
	    if (dmem_wstrb[2])
	      imem[dmem_waddr + 2] <= dmem_wdata[23:16];
	    if (dmem_wstrb[3])
	      imem[dmem_waddr + 3] <= dmem_wdata[31:24];
	    dmem_wready <= 1'b1;
	 end else begin
	    dmem_wready <= 1'b0;
	 end
      end
   end

   always @(posedge clk) begin
      if (rst_n) begin
	 $display("pc=%h addr=%h valid=%d ready=%d insn=%h X[0]=%h X[1]=%h X[2]=%h X[3]=%h X[4]=%h", nyan_core_dut0.pc, nyan_core_dut0.o_imem_addr, nyan_core_dut0.o_imem_valid, imem_ready, nyan_core_dut0.insn_q, nyan_core_dut0.X[0], nyan_core_dut0.X[1], nyan_core_dut0.X[2], nyan_core_dut0.X[3], nyan_core_dut0.X[4]);
      end
   end
endmodule // nyan_core_tb
