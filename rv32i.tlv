\m4_TLV_version 1d: tl-x.org
\SV
   // This code can be found in: https://github.com/stevehoover/LF-Building-a-RISC-V-CPU-Core/risc-v_shell.tlv

   m4_include_lib(['https://raw.githubusercontent.com/stevehoover/LF-Building-a-RISC-V-CPU-Core/main/lib/risc-v_shell_lib.tlv'])
m4_define(['m4_asm_ECALL'],  ['32'b00000000000000000000000001110011'])
m4_define(['m4_asm_EBREAK'], ['32'b00000000000100000000000001110011'])
m4_define(['m4_asm_MRET'],   ['32'b00110000001000000000000001110011'])
m4_asm(AUIPC, x1, 0)                    //  0  x1 = 0
m4_asm(ADDI,  x1, x1, 100000)           //  4  x1 = 32 (handler)
m4_asm(CSRRW, x0, x1, 1100000101)       //  8  mtvec = 32
m4_asm(ADDI,  x30, x0, 1)               // 12  x30 = 1
m4_asm(ECALL)                           // 16  mepc = 16, mcause = 11
m4_asm(ADDI,  x30, x30, 100)            // 20  +4  - return target, runs ONCE
m4_asm(ADDI,  x30, x30, 1000)           // 24  +8  - runs after the return
m4_asm(BGE, x0, x0, 0)                  // 28  halt
m4_asm(CSRRS, x6, x0, 1101000010)       // 32  handler: x6 = 11
m4_asm(CSRRS, x7, x0, 1101000001)       // 36  x7 = 16
m4_asm(ADDI,  x8, x7, 100)              // 40  x8 = 20 (mepc + 4)
m4_asm(CSRRW, x0, x8, 1101000001)       // 44  mepc = 20
m4_asm(MRET)                            // 48  -> 20
m4_asm(ADDI,  x30, x30, 10000)          // 52  +16 - MRET shadow 1
m4_asm(ADDI,  x30, x30, 100000)         // 56  +32 - MRET shadow 2
m4_asm_end()

\SV
   m4_makerchip_module   // (Expanded in Nav-TLV pane.)
   /* verilator lint_on WIDTH */
\TLV
   |cpu
      @0 //IF
         $reset = *reset;
         // PC Logic
         $bht_index_f[4:0] = $pc[6:2];
         $pred_taken_f = /bht[$bht_index_f]>>1$ctr[1];
         $br_predicted_pc_f[31:0] = /btb[$bht_index_f]>>1$value;

         $pc[31:0] = >>1$next_pc;
         $next_pc[31:0] = $reset ? 32'b0:
                          >>2$valid_trap ? >>2$trap_target_pc:
                          >>2$valid_mispredicted ? (>>2$taken_br ? >>2$br_target_pc : >>2$pc + 32'b100) : //if branch prediction was wrong
                          >>1$valid_jal ? >>1$br_target_pc: // JAL resolves in ID
                          >>2$valid_jalr ? >>2$jalr_target_pc: // JALR resolves in EX
                          >>2$valid_mret ? >>2$mret_target_pc:
                          $pred_taken_f ? $br_predicted_pc_f:
                          $pc + 32'b100;

      @1 //ID
         //IMem Logic
         // Single cycle macro based, no SRAM.
         `READONLY_MEM($pc, $$instr[31:0])

         //exception handling signals
         $trap = $illegal_instr || $is_ecall || $is_ebreak;
         $trap_cause[31:0] = $is_ecall ? 32'd11:
                             $is_ebreak ? 32'd3:
                             32'd2;
         $on_path = !$reset //checks instructions that could remove instruction from path
                    && >>1$valid_jal
                    && >>1$valid_jalr && !>>2$valid_jalr
                    && >>1$valid_mret && >>2$valid_mret
                    && >>1$valid_trap && >>2$valid_trap
                    && >>1$valid_mispredicted && >>2$valid_mispredicted;
         $valid = !$on_path && !$trap;
         $valid_trap = $on_path && $trap;
         $valid_jal  = $valid && $is_jal;
         $valid_jalr = $valid && $is_jalr;
         $valid_mret = $valid && $is_mret;
         $illegal_instr = ($is_csr && !$csr_addr_valid)
                          || ($csr_wr_req && $csr_addr[11:10] == 2'b11) //writing to a read only csr section
                          || ($is_system && !$is_csr && !$is_ecall && !$is_ebreak && !$is_mret) //unauthorized system instruction
                          || !($is_lui || $is_auipc || $is_jal ||$is_jalr || $is_branch || $is_load || $is_store || $is_opimm || $is_op || $is_fence || $is_system);

         //branch history table and branch target buffer
         /bht[31:0]
            $my_update = |cpu>>1$valid && |cpu>>1$is_b_instr && (|cpu>>1$bht_index_f == #bht);
            $ctr[1:0] = |cpu$reset ? 2'b01:
                        $my_update ? (|cpu>>1$taken_br ? ($ctr == 2'b11 ? 2'b11 : $ctr + 2'b01):
                                                         ($ctr == 2'b00 ? 2'b00 : $ctr - 2'b01)):
                        $RETAIN;
         /btb[31:0]
            $my_update = |cpu>>1$valid && |cpu>>1$taken_br && (|cpu>>1$bht_index_f == #btb);
            $value[31:0] = |cpu$reset ? 32'b0:
                           $my_update ? |cpu>>1$br_target_pc:
                           $RETAIN;

         //Decoding logic
         //splitting up instruction signal
         $funct3[2:0] = $instr[14:12];
         $rs1[4:0] = $instr[19:15];
         $rs2[4:0] = $instr[24:20];
         $rd[4:0] = $instr[11:7];
         $opcode[6:0] = $instr[6:0];
         // opcodes
         $is_lui    = $opcode ==? 7'b0110111;
         $is_auipc  = $opcode ==? 7'b0010111;
         $is_jal    = $opcode ==? 7'b1101111;
         $is_jalr   = $opcode ==? 7'b1100111;
         $is_branch = $opcode ==? 7'b1100011;
         $is_load   = $opcode ==? 7'b0000011;
         $is_store  = $opcode ==? 7'b0100011;
         $is_opimm  = $opcode ==? 7'b0010011;
         $is_op     = $opcode ==? 7'b0110011;
         $is_fence  = $opcode ==? 7'b0001111;
         $is_system = $opcode ==? 7'b1110011;
         //zicsr instruction decode
         $is_csrrw = $is_system && ($funct3 == 3'b001);
         $is_csrrs = $is_system && ($funct3 == 3'b010);
         $is_csrrc = $is_system && ($funct3 == 3'b011);
         $is_csrrwi = $is_system && ($funct3 == 3'b101);
         $is_csrrsi = $is_system && ($funct3 == 3'b110);
         $is_csrrci = $is_system && ($funct3 == 3'b111);
         $is_mret = $is_system && ($funct3 == 3'b000) && ($instr[31:20] == 12'h302);
         $csr_addr[11:0] = $instr[31:20]; //unsigned as opposed to imm
         $csr_uimm[31:0] = {27'b0, $instr[19:15]};
           //write suppression (no valid needed, valid depends on trap depends on illegal_instr
         $csr_src_zero = $is_csr_imm ? ($instr[19:15] == 5'b0) : ($rs1 == 5'b0);
         $csr_wr_req = $is_csr && !(($is_csrrs || $is_csrrc || $is_csrrsi || $is_csrrci) && $csr_src_zero);
         $csr_addr_valid = ($csr_addr == 12'h340) || ($csr_addr == 12'hB00) || ($csr_addr == 12'hC00) || ($csr_addr == 12'hB02) || ($csr_addr == 12'hC02);
         //instruction formats, used mainly for gating validity
         $is_i_instr = $is_load || $is_opimm || $is_jalr;
         $is_s_instr = $is_store;
         $is_b_instr = $is_branch;
         $is_u_instr = $is_lui || $is_auipc;
         $is_j_instr = $is_jal;
         $is_r_instr = $is_op;
         $is_csr_imm = $is_csrrwi || $is_csrrsi || $is_csrrci;
         $is_csr = $is_csrrw || $is_csrrs || $is_csrrc || $is_csr_imm;
         //immediate
         $imm[31:0] = $is_i_instr ? { {21{$instr[31]}}, $instr[30:20]}:
                      $is_s_instr ? { {21{$instr[31]}}, $instr[30:25], $instr[11:7]}:
                      $is_b_instr ? { {20{$instr[31]}}, $instr[7], $instr[30:25], $instr[11:8], 1'b0}:
                      $is_u_instr ? {$instr[31:12], 12'b0}:
                      $is_j_instr ? { {12{$instr[31]}}, $instr[19:12], $instr[20], $instr[30:21], 1'b0}:
                      32'b0;
         // valid fields
         $funct3_valid = $is_r_instr || $is_i_instr || $is_s_instr || $is_b_instr;
         $rs1_valid = $is_r_instr || $is_i_instr || $is_s_instr || $is_b_instr || ($is_csr && !$is_csr_imm);
         $rs2_valid = $is_r_instr || $is_s_instr || $is_b_instr;
         $rd_valid = ($is_r_instr || $is_i_instr || $is_u_instr || $is_j_instr || $is_csr) && $rd != 5'b0;
         // SYSTEM sub-decode
         $is_ecall  = $is_system && ($funct3 == 3'b000) && ($instr[31:20] == 12'b0);
         $is_ebreak = $is_system && ($funct3 == 3'b000) && ($instr[31:20] == 12'b1);
         //branch target address
         $br_target_pc[31:0] = $pc + $imm;

         //silencing signals
         `BOGUS_USE($rd $rd_valid $rs1 $rs1_valid $rs2 $rs2_valid $opcode $funct3 $funct3_valid $is_u_instr $is_i_instr $is_s_instr $is_b_instr $is_j_instr $is_r_instr
                    $is_beq $is_bne $is_blt $is_bge $is_bltu $is_bgeu $is_addi $is_add $dec_bits $imm $src1_value $src2_value $is_lw $is_sw $src2_or_imm
                    $illegal_instr $is_ebreak $is_ecall)

         // Register File
         // Write port control (sourced from the WB stage)
         $rf_wr_en = >>3$rd_valid && >>3$rd != 5'b0 && >>3$valid;
         $rf_wr_index[4:0] = >>3$rd;
         // Read port control (combinational, this stage)
         $src1_value[31:0] = /rf[$rs1]$value;
         $src2_value[31:0] = /rf[$rs2]$value;
         // The array itself
         /rf[31:0]
            $my_wr_en = |cpu$rf_wr_en && (|cpu$rf_wr_index == #rf);
            $value[31:0] = |cpu$reset ? 32'b0 :
                           $my_wr_en ? |cpu>>3$rf_wr_data:
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
         $rs1_fwd_mem = $rs1_valid && >>1$valid && >>1$rd_valid && (>>1$rd == $rs1);
         $rs2_fwd_mem = $rs2_valid && >>1$valid && >>1$rd_valid && (>>1$rd == $rs2);
           //Path to MEM/WB
         $rs1_fwd_wb = $rs1_valid && >>2$valid && >>2$rd_valid && (>>2$rd == $rs1);
         $rs2_fwd_wb = $rs2_valid && >>2$valid && >>2$rd_valid && (>>2$rd == $rs2);
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
         //CSR signals
           //previous cycle values to reference
         $mscratch_old[31:0] = >>1$mscratch;
         $mcycle_old[31:0] = >>1$mcycle;
         $minstret_old[31:0] = >>1$minstret;
         $mtvec_old[31:0] = >>1$mtvec;
         $mepc_old[31:0] = >>1$mepc;
         $mcause_old[31:0] = >>1$mcause;
         $trap_target_pc[31:0] = {$mtvec_old[31:2], 2'b0};
         $mret_target_pc[31:0] = $mepc_old;
           //read-mod-write muxes
         $csr_read_data[31:0] = ($csr_addr == 12'h340) ? $mscratch_old:
                                ($csr_addr == 12'hB00 || $csr_addr == 12'hC00) ? $mcycle_old:
                                ($csr_addr == 12'hB02 || $csr_addr == 12'hC02) ? $minstret_old:
                                32'b0; //more CSRs go here
         $csr_src[31:0] = $is_csr_imm ? $csr_uimm : $src1_value_fwd;
         $csr_new_value[31:0] = ($is_csrrw || $is_csrrwi) ? $csr_src:
                              ($is_csrrs || $is_csrrsi) ? $csr_read_data | $csr_src:
                              ($is_csrrc || $is_csrrci) ? $csr_read_data & ~$csr_src:
                              32'b0;
         $csr_wr_en = $csr_wr_req && $valid;
           //next state muxes

         $mscratch[31:0] = $reset ? 32'b0:  //plain storage: hold unless written
                           ($csr_wr_en && $csr_addr == 12'h340) ? $csr_new_value : $mscratch_old;
         $mcycle[31:0] = $reset ? 32'b0:    //background update, counts unless there is an explicit write
                         ($csr_wr_en && $csr_addr == 12'hB00) ? $csr_new_value : ($mcycle_old + 32'b1);
         $minstret[31:0] = $reset ? 32'b0:  //counts retirements not cycles, only adds one if valid and not explicit write
                           ($csr_wr_en && $csr_addr == 12'hB02) ? $csr_new_value: $minstret_old + {31'b0, $valid};
         $mtvec[31:0] = $reset ? 32'b0:
                        ($csr_wr_en && ($csr_addr == 12'h305)) ? $csr_new_value:
                        $mtvec_old;
         $mepc[31:0] = $reset ? 32'b0:
                       $valid_trap ? $pc:
                       ($csr_wr_en && ($csr_addr == 12'h341)) ? $csr_new_value:
                       $mepc_old;
         $mcause[31:0] = $reset ? 32'b0:
                         $valid_trap ? $trap_cause:
                         ($csr_wr_en && ($csr_addr == 12'h342)) ? $csr_new_value:
                         $mcause_old;

         //Branch Logic
         $src2_or_imm_fwd[31:0] = $is_r_instr ? $src2_value_fwd : $imm;
         $taken_br = $is_b_instr && $is_beq ? $src1_value_fwd == $src2_value_fwd:
                     $is_b_instr && $is_bne ? $src1_value_fwd != $src2_value_fwd:
                     $is_b_instr && $is_blt ? ($src1_value_fwd < $src2_value_fwd) ^ ($src1_value_fwd[31] != $src2_value_fwd[31]):
                     $is_b_instr && $is_bge ? ($src1_value_fwd >= $src2_value_fwd) ^ ($src1_value_fwd[31] != $src2_value_fwd[31]):
                     $is_b_instr && $is_bltu ? $src1_value_fwd < $src2_value_fwd:
                     $is_b_instr && $is_bgeu ? $src1_value_fwd >= $src2_value_fwd:
                     1'b0;
         $mispredicted = $is_b_instr && (($taken_br != $pred_taken_f) || ($taken_br && $pred_taken_f && ($br_target_pc != $br_predicted_pc_f)));
         $valid_mispredicted = $valid && $mispredicted;
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
                         $is_lui ? $imm:
                         $is_auipc ? $pc + $imm:
                         ($is_jal || $is_jalr) ? ($pc + 32'b100):
                         $is_csr ? $csr_read_data:
                         32'b0;
         $addr[31:0] = $src1_value_fwd + $imm;
         $jalr_target_pc[31:0] =  ($src1_value_fwd + $imm) & ~32'b1;

      @3 //MEM
         //Data Memory
         $dmem_wr_en = $is_sw && $valid;
         $dmem_index[4:0] = $addr[6:2];
         $dmem_wr_data[31:0] = $src2_value_fwd;
         /dmem[31:0]
            $my_wr_en = |cpu$dmem_wr_en && (|cpu$dmem_index == #dmem);
            $value[31:0] = |cpu$reset ? 32'b0:
                           $my_wr_en ? |cpu$dmem_wr_data:
                           $RETAIN;
         $ld_data[31:0] = /dmem[$dmem_index]$value;
      @4 //WB
         $rf_wr_data[31:0] = $is_lw ? $ld_data : $result;

         // Assert these to end simulation (before Makerchip cycle limit).
         //m4+tb()
         //*failed = *cyc_cnt > M4_MAX_CYC;
         //m4+dmem(32, 32, $reset, $addr[4:0], $wr_en, $wr_data[31:0], $rd_en, $rd_data)
         //m4+cpu_viz()
\SV
   endmodule
