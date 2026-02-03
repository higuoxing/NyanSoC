`timescale 1ns / 1ps

module nyan_core_tb;
   reg clk;
   reg rst_n;

   // Memory Interface
   wire [31:0] imem_addr, dmem_raddr, dmem_waddr, dmem_wdata;
   wire        imem_valid, dmem_rvalid, dmem_wvalid;
   wire [3:0]  dmem_wstrb;
   reg [31:0]  imem_rdata, dmem_rdata;
   reg         imem_ready, dmem_ready;

   // Trap signal
   wire        trap;

   // Instantiate your core
   nyan_core uut (
      .i_clk(clk),
      .i_rst_n(rst_n),
      .o_imem_addr(imem_addr),
      .o_imem_valid(imem_valid),
      .i_imem_rdata(imem_rdata),
      .i_imem_ready(imem_ready),
      .o_dmem_raddr(dmem_raddr),
      .o_dmem_rvalid(dmem_rvalid),
      .i_dmem_rdata(dmem_rdata),
      .i_dmem_rready(dmem_ready),
      .o_dmem_waddr(dmem_waddr),
      .o_dmem_wvalid(dmem_wvalid),
      .o_dmem_wstrb(dmem_wstrb),
      .o_dmem_wdata(dmem_wdata),
      .i_dmem_wready(dmem_ready),
      .o_trap(trap)
   );

   // Clock generation
   initial clk = 0;
   always #5 clk = ~clk;

   // Memory array (32-bit words)
   reg [31:0] mem [0:10240];

   // --- Unified Memory Logic ---
   always @(posedge clk) begin
      if (!rst_n) begin
         imem_ready <= 1'b0;
         imem_rdata <= 32'b0;
         dmem_ready <= 1'b0;
         dmem_rdata <= 32'b0;
      end else begin
         // Instruction Fetch
         if (imem_valid) begin
            imem_rdata <= mem[imem_addr >> 2];
            imem_ready <= 1'b1;
            // $display("FETCH: Addr=%h Instr=%h", imem_addr, mem[imem_addr >> 2]);
         end else begin
            imem_ready <= 1'b0;
         end

         // Data Memory (Load/Store)
         if (dmem_rvalid || dmem_wvalid) begin
            dmem_ready <= 1'b1;
            // Read path
            dmem_rdata <= mem[dmem_raddr >> 2]; 
            
            // Write path (with byte strobes)
            if (dmem_wvalid) begin
               if (dmem_wstrb[0]) mem[dmem_waddr>>2][7:0]   <= dmem_wdata[7:0];
               if (dmem_wstrb[1]) mem[dmem_waddr>>2][15:8]  <= dmem_wdata[15:8];
               if (dmem_wstrb[2]) mem[dmem_waddr>>2][23:16] <= dmem_wdata[23:16];
               if (dmem_wstrb[3]) mem[dmem_waddr>>2][31:24] <= dmem_wdata[31:24];
               $display("DMEM WRITE: Addr=%h Data=%h Strobe=%b", dmem_waddr, dmem_wdata, dmem_wstrb);
            end
         end else begin
            dmem_ready <= 1'b0;
         end
      end
   end

   // --- Console Logging ---
   always @(posedge clk) begin
      if (rst_n) begin
         if (uut.cpu_state == 2'b01) begin // Execute state
            $display("--- Step: PC=%h | Instr=%h ---", uut.pc_q, uut.insn_q);
            $display("Registers: x1=%h, x2=%h, x3=%h, x9=%h, x31=%h", 
                     uut.X[1], uut.X[2], uut.X[3], uut.X[9], uut.X[31]);
         end
      end
   end

   // --- Simulation Control ---
   initial begin
      // Optional: Dump waves for GTKWave
      // $dumpfile("nyan.vcd"); $dumpvars(0, nyan_core_tb);

      $readmemh("imem.hex", mem);
      rst_n = 0; 
      #20 rst_n = 1;

      // Fork to handle either success or timeout
      fork
         begin
            wait(trap || uut.X[31] == 32'h666);
            #20;
            if (trap && uut.X[31] != 32'h666) begin
               $display("\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
               $display("TORTURE FAILED: CPU Trapped at PC=%h", uut.pc);
               $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n");
            end else begin
               $display("\n*******************************");
               $display("TORTURE PASSED! Final Flag: %h", uut.X[31]);
               $display("*******************************\n");
            end
         end
         begin
            #200000; // Timeout after 200us
            $display("TIMEOUT: Simulation took too long!");
         end
      join_any

      $finish;
   end

endmodule // nyan_core_tb
