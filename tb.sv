`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// Testbench for the rv32i-tlv core.
//
// Two modes, selected by plusargs:
//
//  1. Legacy self-check mode (no +trace): loads imem.hex, runs to a self-loop,
//     dumps regs.out / dmem.out.  This is what run.sh uses.
//
//  2. Co-simulation trace mode (+trace=<file>): additionally emits an
//     RVFI-style retirement trace, one line per architecturally committed
//     instruction, for comparison against a reference model (Spike/Sail).
//
// Trace line format (see verif/rvtrace.py):
//     <pc> <insn> [x<rd>=<val>] [m<size>[<addr>]=<val>]
//     TRAP <pc> <cause> <tval>
// ---------------------------------------------------------------------------

module tb;
   localparam int MEM_WORDS = 524288;

   logic clk = 0;
   logic reset = 1;
   logic [31:0] cyc_cnt = 0;
   logic passed, failed;

   top dut (.clk(clk), .reset(reset), .cyc_cnt(cyc_cnt), .passed(passed), .failed(failed));

   // ---------------------------------------------------------------- config
   string imem_file  = "imem.hex";
   string trace_file = "";
   string regs_file  = "regs.out";
   string dmem_file  = "dmem.out";
   int    load_addr  = 0;        // byte address the flat image is loaded at
   int    entry_pc   = 0;        // if != 0, plant "jal x0, entry_pc" at word 0
   int    max_cyc    = 200000;
   int    stuck_lim  = 20;
   int    halt_store = 0;        // stop on a store to this address (tohost)
   bit    no_dmem    = 0;

   int    trace_fd   = 0;

   // Build "jal x0, target" as executed from pc == 0.
   // J-type: {imm[20], imm[10:1], imm[11], imm[19:12], rd, opcode}
   function automatic logic [31:0] jal_x0(input logic [31:0] target);
      logic [20:0] off;
      off = target[20:0];
      return {off[20], off[10:1], off[11], off[19:12], 5'b00000, 7'b1101111};
   endfunction

   initial begin
      void'($value$plusargs("imem=%s",   imem_file));
      void'($value$plusargs("trace=%s",  trace_file));
      void'($value$plusargs("regs=%s",   regs_file));
      void'($value$plusargs("dmem=%s",   dmem_file));
      void'($value$plusargs("load=%h",   load_addr));
      void'($value$plusargs("entry=%h",  entry_pc));
      void'($value$plusargs("maxcyc=%d", max_cyc));
      void'($value$plusargs("stuck=%d",  stuck_lim));
      void'($value$plusargs("haltstore=%h", halt_store));
      no_dmem = $test$plusargs("nodmem");

      for (int i = 0; i < MEM_WORDS; i++) begin
         dut.imem_array[i] = 32'b0;
         dut.dmem_array[i] = 32'b0;
      end

      // Unified image: the core is Harvard-split but both arrays mirror the
      // same address space, so stores land in dmem and code is read from imem.
      $readmemh(imem_file, dut.imem_array, load_addr / 4);
      $readmemh(imem_file, dut.dmem_array, load_addr / 4);

      // The core resets to pc==0.  Reference models (Spike) cannot map address
      // 0, so tests are linked higher and we plant a single jump at word 0.
      // The comparator drops this synthetic instruction.
      if (entry_pc != 0) dut.imem_array[0] = jal_x0(entry_pc);

      if (trace_file != "") begin
         trace_fd = $fopen(trace_file, "w");
         if (trace_fd == 0) begin
            $display("ERROR: cannot open trace file %s", trace_file);
            $fatal;
         end
      end
   end

   always #5 clk = ~clk;

   // ------------------------------------------------- commit-point alignment
   //
   // The core's architectural commit point is stage @4 (writeback): that is
   // where $rf_wr_data is final, because loads only resolve at @3.
   //
   // SandPiper only pipelines a signal as far as the design actually uses it,
   // so $pc stops at @2 and $instr stops at @1.  Rather than add flops to the
   // RTL just for observability, we re-pipeline them here in the testbench --
   // free, because the testbench is never synthesised.
   //
   // Alignment check, for instruction X in stage 2 during cycle n:
   //   cycle n   : CPU_pc_a2 = X.pc,  CPU_retires_a2 = X.retires
   //   cycle n+1 : pc_s3     = X.pc,  CPU_retires_a3 = X.retires
   //   cycle n+2 : pc_s4     = X.pc,  CPU_retires_a4 = X.retires   <-- sample
   // Both shift registers use nonblocking assignment on the same posedge, so
   // the emit block below reads the pre-edge (i.e. cycle n+2) values of all
   // of them.  Everything describes the same instruction X.

   logic [31:0] pc_s3,   pc_s4;
   logic [31:0] insn_s2, insn_s3, insn_s4;

   // store payload is only known at @3; shift it forward one stage
   logic        st_en_s4;
   logic [31:0] st_addr_s4, st_data_s4;
   logic [1:0]  st_size_s4;

   // trap resolves at @2; shift it forward two stages so traps and retirements
   // appear in the trace in program order
   logic        trp_s3,    trp_s4;
   logic [31:0] trpc_s3,   trpc_s4;
   logic [31:0] trcau_s3,  trcau_s4;
   logic [31:0] trtval_s3, trtval_s4;

   always @(posedge clk) begin
      pc_s3      <= dut.CPU_pc_a2;
      pc_s4      <= pc_s3;

      insn_s2    <= dut.CPU_instr_a1;
      insn_s3    <= insn_s2;
      insn_s4    <= insn_s3;

      st_en_s4   <= dut.CPU_dmem_wr_en_a3;
      // Deliberately reconstructed from the *decoded* index rather than from
      // $addr, so that any address-decode truncation in the RTL shows up in
      // the trace as a wrong store address.  Trace what the hardware did, not
      // what the instruction asked for.
      st_addr_s4 <= {16'b0, dut.CPU_dmem_index_a3, dut.CPU_addr_a3[1:0]};
      st_data_s4 <= dut.CPU_src2_value_fwd_a3;
      st_size_s4 <= dut.CPU_funct3_a3[1:0];

      trp_s3     <= dut.CPU_take_trap_a2;         trp_s4    <= trp_s3;
      trpc_s3    <= dut.CPU_pc_a2;                trpc_s4   <= trpc_s3;
      trcau_s3   <= dut.CPU_exception_cause_a2;   trcau_s4  <= trcau_s3;
      trtval_s3  <= dut.CPU_exception_tvalue_a2;  trtval_s4 <= trtval_s3;
   end

   // ------------------------------------------------------------ trace emit
   always @(posedge clk) begin
      if (trace_fd != 0 && cyc_cnt > 6) begin
         if (dut.CPU_retires_a4) begin
            $fwrite(trace_fd, "%08x %08x", pc_s4, insn_s4);
            if (dut.CPU_rd_valid_a4)
               $fwrite(trace_fd, " x%0d=%08x", dut.CPU_rd_a4, dut.CPU_rf_wr_data_a4);
            if (st_en_s4)
               $fwrite(trace_fd, " m%0d[%08x]=%08x",
                       1 << st_size_s4, st_addr_s4, st_data_s4);
            $fwrite(trace_fd, "\n");
         end
         else if (trp_s4) begin
            $fwrite(trace_fd, "TRAP %08x %08x %08x\n", trpc_s4, trcau_s4, trtval_s4);
         end
      end
   end

   // --------------------------------------------------------- halt detection
   //
   // Primary condition: the same pc retires twice in a row, i.e. the test has
   // reached its terminating "j .".  This is deliberately the identical rule
   // the trace comparator applies to the reference model, so both sides stop
   // at the same instruction.
   //
   // Note the older "pc_a0 unchanged for N cycles" heuristic does NOT fire on
   // a self-loop: fetch runs one slot ahead of the jal resolving at @1, so
   // pc_a0 alternates between the loop and loop+4 forever.  It is kept only
   // as a backstop for a pipeline that is genuinely wedged.
   logic [31:0] last_ret_pc = 32'hFFFFFFFF;
   bit  selfloop = 0;
   int  idle     = 0;

   logic [31:0] prev_pc = 32'hFFFFFFFF;
   int stuck = 0;

   always @(posedge clk) begin
      if (cyc_cnt > 6 && dut.CPU_retires_a4) begin
         if (pc_s4 == last_ret_pc) selfloop <= 1;
         // riscv-dv ends in a 3-instruction write_tohost loop rather than a
         // "j .", so the pc never repeats; the tohost store is the real signal.
         if (halt_store != 0 && st_en_s4 && st_addr_s4 == halt_store) selfloop <= 1;
         last_ret_pc <= pc_s4;
         idle <= 0;
      end
      else if (cyc_cnt > 6) begin
         idle <= idle + 1;              // catches trap loops, which never retire
      end
   end

   always @(posedge clk) begin
      cyc_cnt <= cyc_cnt + 1;
      if (cyc_cnt == 5) reset <= 1'b0;

      if (!reset && cyc_cnt > 10) begin
         if (dut.CPU_pc_a0 == prev_pc) stuck <= stuck + 1;
         else                          stuck <= 0;
         prev_pc <= dut.CPU_pc_a0;
      end

      if (selfloop || idle == 2000 || stuck == stuck_lim || cyc_cnt == max_cyc) begin
         if (cyc_cnt == max_cyc) $display("TIMEOUT");
         if (idle == 2000)       $display("STALLED: no instruction retired for 2000 cycles");
         $display("halted at pc=%08x after %0d cycles", prev_pc, cyc_cnt);
         if (trace_fd != 0) $fclose(trace_fd);
         $writememh(regs_file, dut.CPU_Rf_value_a1);
         if (!no_dmem) $writememh(dmem_file, dut.dmem_array, 0, MEM_WORDS-1);
         $finish;
      end
   end
endmodule
