\m4_TLV_version 1d: tl-x.org
\SV
   // This code can be found in: https://github.com/stevehoover/LF-Building-a-RISC-V-CPU-Core/risc-v_shell.tlv

   m4_include_lib(['https://raw.githubusercontent.com/stevehoover/LF-Building-a-RISC-V-CPU-Core/main/lib/risc-v_shell_lib.tlv'])



   //---------------------------------------------------------------------------------
   // /====================\
   // | Sum 1 to 9 Program |
   // \====================/
   //
   // Program to test RV32I
   // Add 1,2,3,...,9 (in that order).
   //
   // Regs:
   //  x12 (a2): 10
   //  x13 (a3): 1..10
   //  x14 (a4): Sum
   //
   m4_asm(ADDI, x14, x0, 0)             // Initialize sum register a4 with 0
   m4_asm(ADDI, x12, x0, 1010)          // Store count of 10 in register a2.
   m4_asm(ADDI, x13, x0, 1)             // Initialize loop count register a3 with 0
   // Loop:
   m4_asm(ADD, x14, x13, x14)           // Incremental summation
   m4_asm(ADDI, x13, x13, 1)            // Increment loop count by 1
   m4_asm(BLT, x13, x12, 1111111111000) // If a3 is less than a2, branch to label named <loop>
   // Test result value in x14, and set x31 to reflect pass/fail.
   m4_asm(ADDI, x30, x14, 111111010100) // Subtract expected value of 44 to set x30 to 1 if and only iff the result is 45 (1 + 2 + ... + 9).
   m4_asm(BGE, x0, x0, 0) // Done. Jump to itself (infinite loop). (Up to 20-bit signed immediate plus implicit 0 bit (unlike JALR) provides byte address; last immediate bit should also be 0)
   m4_asm_end()
   m4_define(['M4_MAX_CYC'], 50)
   //---------------------------------------------------------------------------------



\SV
   m4_makerchip_module   // (Expanded in Nav-TLV pane.)
   /* verilator lint_on WIDTH */
\TLV
   |cpu
      @0 //IF
         $reset = *reset;
         // PC Logic
         $pc[31:0] = >>1$next_pc;
         $next_pc[31:0] = $reset ? 32'b0:
                          >>2$taken_br ? >>2$br_target_pc:
                          $pc + 32'b100;

      @1 //ID
         //IMem Logic
         // Single cycle macro based, no SRAM.
         `READONLY_MEM($pc, $$instr[31:0])

         //Decoding logic
         // Two MSBs must be 11 for RV321 instructions so they will be assumed valid and ignored.
         $is_u_instr = $instr[6:2] ==? 5'b0x101;
         $is_i_instr = $instr[6:2] ==? 5'b0000x || $instr[6:2] == 5'b001x0 || $instr[6:2] == 5'b11001;
         $is_s_instr = $instr[6:2] ==? 5'b0100x;
         $is_b_instr = $instr[6:2] == 5'b11000;
         $is_j_instr = $instr[6:2] == 5'b11011;
         $is_r_instr = $instr[6:2] ==? 5'b011x0 || $instr[6:2] == 5'b01011 || $instr[6:2] == 5'b10100;
         //splitting up instruction signal
         $funct3[2:0] = $instr[14:12];
         $rs1[4:0] = $instr[19:15];
         $rs2[4:0] = $instr[24:20];
         $rd[4:0] = $instr[11:7];
         $opcode[6:0] = $instr[6:0];
         $imm[31:0] = $is_i_instr ? { {21{$instr[31]}}, $instr[30:20]}:
                      $is_s_instr ? { {21{$instr[31]}}, $instr[30:25], $instr[11:7]}:
                      $is_b_instr ? { {20{$instr[31]}}, $instr[7], $instr[30:25], $instr[11:8], 1'b0}:
                      $is_u_instr ? {$instr[31:12], 12'b0}:
                      $is_j_instr ? { {12{$instr[31]}}, $instr[19:12], $instr[20], $instr[30:21], 1'b0}:
                      32'b0;
         // valid fields
         $funct3_valid = $is_r_instr || $is_i_instr || $is_s_instr || $is_b_instr;
         $rs1_valid = $funct3_valid;
         $rs2_valid = $is_r_instr || $is_s_instr || $is_b_instr;
         $rd_valid = ($is_r_instr || $is_i_instr || $is_u_instr || $is_j_instr) && $rd != 5'b0;

         `BOGUS_USE($rd $rd_valid $rs1 $rs1_valid $rs2 $rs2_valid $opcode $funct3 $funct3_valid $is_u_instr $is_i_instr $is_s_instr $is_b_instr $is_j_instr $is_r_instr
                    $is_beq $is_bne $is_blt $is_bge $is_bltu $is_bgeu $is_addi $is_add $dec_bits $imm $src1_value $src2_value $is_lw $is_sw)



         // Register File
         // Write port control (sourced from the WB stage)
         $rf_wr_en = >>3$rd_valid && >>3$rd != 5'b0;
         $rf_wr_index[4:0] = >>3$rd;
         // Read port control (combinational, this stage)
         $src1_value[31:0] = /rf[$rs1]$value;
         $src2_value[31:0] = /rf[$rs2]$value;
         // The array itself
         /rf[31:0]
            $my_wr_en = |cpu$rf_wr_en && (|cpu$rf_wr_index == #rf);
            $value[31:0] = |cpu$reset ? 32'b0 :
                           $my_wr_en ? |cpu>>3$rf_wr_data :
                           $RETAIN;

         $dec_bits[10:0] = {$instr[30], $funct3, $opcode};
         $src2_or_imm[31:0] = $is_r_instr ? $src2_value : $imm; //one mux to decide between rs2 and imm
         //determining instruction type (funct7_funct3_opcode)
         $is_beq = $dec_bits ==? 11'bx_000_1100011;
         $is_bne = $dec_bits ==? 11'bx_001_1100011;
         $is_blt = $dec_bits ==? 11'bx_100_1100011;
         $is_bge = $dec_bits ==? 11'bx_101_1100011;
         $is_bltu = $dec_bits ==? 11'bx_110_1100011;
         $is_bgeu = $dec_bits ==? 11'bx_111_1100011;
         $is_addi = $dec_bits ==? 11'bx_000_0010011;
         $is_add = $dec_bits ==? 11'b0_000_0110011;
         $is_sub = $dec_bits ==? 11'b1_000_0110011;
         $is_sll = $dec_bits ==? 11'b0_001_0110011;
         $is_slt = $dec_bits ==? 11'b0_010_0110011;
         $is_sltu = $dec_bits ==? 11'b0_011_0110011;
         $is_xor = $dec_bits ==? 11'b0_100_0110011;
         $is_srl = $dec_bits ==? 11'b0_101_0110011;
         $is_sra = $dec_bits ==? 11'b1_101_0110011;
         $is_or = $dec_bits ==? 11'b0_110_0110011;
         $is_and = $dec_bits ==? 11'b0_111_0110011;
         $is_slti = $dec_bits ==? 11'bx_010_0010011;
         $is_sltiu = $dec_bits ==? 11'bx_011_0010011;
         $is_xori = $dec_bits ==? 11'bx_100_0010011;
         $is_ori = $dec_bits ==? 11'bx_110_0010011;
         $is_andi = $dec_bits ==? 11'bx_111_0010011;
         $is_slli = $dec_bits ==? 11'b0_001_0010011;
         $is_srli = $dec_bits ==? 11'b0_101_0010011;
         $is_srai = $dec_bits ==? 11'b1_101_0010011;
         $is_lw = {$funct3, $opcode} ==? 10'b010_0000011;
         $is_sw = {$funct3, $opcode} ==? 10'b010_0100011;



      @2 //ALU
         //Forwarding Control Signals
         //Path to EX/MEM
         $rs1_fwd_mem = $rs1_valid && >>1$rd_valid && (>>1$rd == $rs1);
         $rs2_fwd_mem = $rs2_valid && >>1$rd_valid && (>>1$rd == $rs2);
         //Path to MEM/WB
         $rs1_fwd_wb = $rs1_valid && >>2$rd_valid && (>>2$rd == $rs1);
         $rs2_fwd_wb = $rs2_valid && >>2$rd_valid && (>>2$rd == $rs2);
         //Forwarding Data Logic
         //EX/MEM, only load cases
         $mem_fwd_value[31:0] = >>1$is_lw ? >>1$ld_data : >>1$result;
         //MEM/WB rf_wr_data already gated by load condition
         $wb_fwd_value[31:0] = >>2$rf_wr_data;
         //Control Logic
         $src1_value_fwd[31:0] = $rs1_fwd_mem ? $mem_fwd_value:
                           $rs1_fwd_wb ? $wb_fwd_value:
                           $src1_value;
         $src2_value_fwd[31:0] = $rs2_fwd_mem ? $mem_fwd_value:
                           $rs2_fwd_wb ? $wb_fwd_value:
                           $src2_value;

         //Branch Logic
         $src2_or_imm_fwd[31:0] = $is_r_instr ? $src2_value_fwd : $imm;
         $taken_br = $is_b_instr && $is_beq ? $src1_value_fwd == $src2_value_fwd:
                     $is_b_instr && $is_bne ? $src1_value_fwd != $src2_value_fwd:
                     $is_b_instr && $is_blt ? ($src1_value_fwd < $src2_value_fwd) ^ ($src1_value_fwd[31] != $src2_value_fwd[31]):
                     $is_b_instr && $is_bge ? ($src1_value_fwd >= $src2_value_fwd) ^ ($src1_value_fwd[31] != $src2_value_fwd[31]):
                     $is_b_instr && $is_bltu ? $src1_value_fwd < $src2_value_fwd:
                     $is_b_instr && $is_bgeu ? $src1_value_fwd >= $src2_value_fwd:
                     1'b0;
         $br_target_pc[31:0] = $pc + $imm;

         //ALU Logic
         $result[31:0] = ($is_add || $is_addi) ? $src1_value_fwd + $src2_or_imm_fwd:
                         ($is_slti || $is_slt) ? {31'b0, ($src1_value_fwd < $src2_or_imm_fwd) ^ ($src1_value_fwd[31] != $src2_or_imm_fwd[31])}:
                         ($is_sltiu || $is_sltu) ? {31'b0, ($src1_value_fwd < $src2_or_imm_fwd)}:
                         ($is_xori || $is_xor) ? $src1_value_fwd ^ $src2_or_imm_fwd:
                         ($is_ori || $is_or) ? $src1_value_fwd | $src2_or_imm_fwd:
                         ($is_andi || $is_and) ? $src1_value_fwd & $src2_or_imm_fwd:
                         ($is_slli || $is_sll) ? $src1_value_fwd << $src2_or_imm_fwd[4:0]:
                         ($is_srli || $is_srl) ? $src1_value_fwd >> $src2_or_imm_fwd[4:0]:
                         //bit flip hack to sign extend without $signed from SV
                         ($is_srai || $is_sra) ? ($src1_value_fwd[31] ? ~(~$src1_value_fwd >> $src2_or_imm_fwd[4:0]) : $src1_value_fwd >> $src2_or_imm_fwd[4:0]):
                         $is_sub ? $src1_value_fwd - $src2_value_fwd:
                         32'b0;
         $addr[31:0] = $src1_value_fwd + $imm;


      @3 //MEM
         //Data Memory
         $dmem_wr_en = >>2$is_sw;
         $dmem_index[4:0] = >>1$addr[6:2];
         $dmem_wr_data[31:0] = >>1$src2_or_imm_fwd;
         /dmem[31:0]
            $my_wr_en = |cpu$dmem_wr_en && (|cpu$dmem_index == #dmem);
            $value[31:0] = |cpu$reset ? 32'b0:
                           $my_wr_en ? |cpu$dmem_wr_data:
                           $RETAIN;
         $ld_data[31:0] = /dmem[$dmem_index]$value;
      @4 //WB
         $rf_wr_data[31:0] = <<3$is_lw ? <<1$ld_data : <<2$result;

         // Assert these to end simulation (before Makerchip cycle limit).
         //m4+tb()
         *failed = *cyc_cnt > M4_MAX_CYC;
         //m4+dmem(32, 32, $reset, $addr[4:0], $wr_en, $wr_data[31:0], $rd_en, $rd_data)
         //m4+cpu_viz()
\SV
   endmodule
