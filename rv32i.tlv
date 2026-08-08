\m4_TLV_version 1d: tl-x.org
\SV
   // This code can be found in: https://github.com/stevehoover/LF-Building-a-RISC-V-CPU-Core/risc-v_shell.tlv

m4_include_lib(['https://raw.githubusercontent.com/stevehoover/LF-Building-a-RISC-V-CPU-Core/main/lib/risc-v_shell_lib.tlv'])
m4_define(['m4_asm_ECALL'],  ['32'b00000000000000000000000001110011'])
m4_define(['m4_asm_EBREAK'], ['32'b00000000000100000000000001110011'])
m4_define(['m4_asm_MRET'],   ['32'b00110000001000000000000001110011'])
m4_asm(ADDI,  x1,  x0,  1001000)             //   0  x1 = 72 (handler address)
m4_asm(CSRRW, x0,  x1,  1100000101)          //   4  mtvec = 72
m4_asm(ADDI,  x2,  x0,  11111111111)         //   8  x2 = 2047 (junk payload for CSR writes)
m4_asm(ADDI,  x11, x0,  1000101011)          //  12  x11 = 555 (canary)
m4_asm(ADDI,  x12, x0,  1000101011)          //  16  x12 = 555 (canary)
m4_asm(ADDI,  x13, x0,  0)                   //  20  x13 = 0 -- a NON-x0 register that HOLDS zero

   // ---- A: reads of the read-only ID CSRs must not trap ----
m4_asm(CSRRS, x3,  x0,  111100010001)        //  24  x3 = mvendorid (0xF11)
m4_asm(CSRRS, x4,  x0,  111100010010)        //  28  x4 = marchid   (0xF12)
m4_asm(CSRRS, x5,  x0,  111100010011)        //  32  x5 = mimpid    (0xF13)
m4_asm(CSRRS, x6,  x0,  111100010100)        //  36  x6 = mhartid   (0xF14)
m4_asm(CSRRS, x7,  x0,  1100000001)          //  40  x7 = misa      (0x301)

   // ---- B: misa is WARL read-WRITE -- write is accepted, dropped, and must NOT trap ----
m4_asm(CSRRW, x9,  x2,  1100000001)          //  44  x9 = OLD misa; writes 2047, which must be discarded
m4_asm(CSRRS, x8,  x0,  1100000001)          //  48  x8 = misa, must be unchanged

   // ---- C: write to a read-only CSR must trap ----
m4_asm(CSRRW, x11, x2,  111100010001)        //  52  TRAP (cause 2); x11 must keep its canary

   // ---- D: rs1 holds zero but is not x0, so this IS a write -- must still trap ----
m4_asm(CSRRS, x12, x13, 111100010100)        //  56  TRAP (cause 2); x12 must keep its canary

   // ---- D': rs1 IS x0, so the write is suppressed and the read-only access is legal ----
m4_asm(CSRRS, x10, x0,  111100010001)        //  60  x10 = mvendorid, NO trap

m4_asm(ADDI,  x14, x0,  101010)              //  64  x14 = 42, sentinel: main path ran to completion
m4_asm(BGE,   x0,  x0,  0)                   //  68  halt

   // ---- shared handler: accumulate cause, count traps, skip the faulting instruction ----
m4_asm(CSRRS, x22, x0,  1101000010)          //  72  handler: x22 = mcause
m4_asm(ADD,   x20, x20, x22)                 //  76  x20 += mcause
m4_asm(ADDI,  x21, x21, 1)                   //  80  x21 += 1 (trap counter)
m4_asm(CSRRS, x23, x0,  1101000001)          //  84  x23 = mepc
m4_asm(ADDI,  x23, x23, 100)                 //  88  x23 = mepc + 4
m4_asm(CSRRW, x0,  x23, 1101000001)          //  92  mepc = mepc + 4
m4_asm(MRET)                                 //  96  -> PC = mepc
m4_asm(ADDI,  x30, x0,  1111100111)          // 100  poison (999): must NEVER execute
m4_asm(BGE,   x0,  x0,  0)                   // 104  handler halt (unreachable)
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
         $btb_hit_f = /btb[$bht_index_f]>>1$valid && (/btb[$bht_index_f]>>1$tag == $pc[31:7]);
         $pred_taken_f = $btb_hit_f && /bht[$bht_index_f]>>1$ctr[1];
         $br_predicted_pc_f[31:0] = /btb[$bht_index_f]>>1$value;

         $pc[31:0] = >>1$next_pc;
         $next_pc[31:0] = $reset ? 32'b0:
                          >>2$take_trap ? >>2$trap_target_pc:
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
                    && !>>1$valid_jal
                    && !>>1$valid_jalr && !>>2$valid_jalr
                    && !>>1$valid_mret && !>>2$valid_mret
                    && !>>1$valid_trap && !>>2$valid_trap
                    && !>>1$valid_mispredicted && !>>2$valid_mispredicted
                    && !>>1$valid_misaligned_id && !>>2$valid_misaligned_id
                    && !>>1$valid_misaligned_ex && !>>2$valid_misaligned_ex;
         $valid = $on_path && !$trap;
         $valid_trap = $on_path && $trap;
         $valid_jal  = $valid && $is_jal;
         $valid_jalr = $valid && $is_jalr;
         $valid_mret = $valid && $is_mret;
         $valid_misaligned_id = $valid && $misaligned_id;
         $misaligned_id = $is_jal && ($br_target_pc[1:0] != 2'b00);
         $decode_valid = $is_lui || $is_auipc || $is_jal // instruction check catch all, compares funct7 and opcodes
                         || ($is_jalr && $funct3 == 3'b000)
                         || ($is_fence && $funct3 == 3'b000)
                         || $is_system || $is_beq || $is_bne || $is_blt || $is_bge || $is_bltu || $is_bgeu
                         || $is_lw || $is_lh || $is_lhu || $is_lb || $is_lbu
                         || $is_sw || $is_sh || $is_sb
                         || $is_addi || $is_slti || $is_sltiu || $is_xori || $is_ori || $is_andi
                         || (($is_slli || $is_srli || $is_srai) && $funct7_valid)
                         || (($is_add || $is_sub || $is_sll || $is_slt || $is_sltu || $is_xor || $is_srl || $is_sra || $is_or || $is_and) && $funct7_valid);
         $illegal_instr = ($is_csr && !$csr_addr_valid)
                          || ($csr_wr_req && $csr_addr[11:10] == 2'b11) //writing to a read only csr section
                          || ($is_system && !$is_csr && !$is_ecall && !$is_ebreak && !$is_mret) //unauthorized system instruction
                          || !$decode_valid;

         //branch history table and branch target buffer
         /bht[31:0]
            $my_update = |cpu>>1$valid && |cpu>>1$is_b_instr && (|cpu>>1$bht_index_f == #bht);
            $ctr[1:0] = |cpu$reset ? 2'b01:
                        $my_update ? (|cpu>>1$taken_br ? (>>1$ctr == 2'b11 ? 2'b11 : >>1$ctr + 2'b01):
                                                         (>>1$ctr == 2'b00 ? 2'b00 : >>1$ctr - 2'b01)):
                        $RETAIN;
         /btb[31:0]
            $my_update = |cpu>>1$valid && |cpu>>1$taken_br && (|cpu>>1$bht_index_f == #btb);
            $tag[24:0] = |cpu$reset ? 25'b0:
                         $my_update ? |cpu>>1$pc[31:7]:
                         $RETAIN;
            $valid = |cpu$reset ? 1'b0:
                     $my_update ? 1'b1:
                     $RETAIN;
            $value[31:0] = |cpu$reset ? 32'b0:
                           $my_update ? |cpu>>1$br_target_pc:
                           $RETAIN;

         //Decoding logic
         //splitting up instruction signal
         $funct7[6:0] = $instr[31:25];
         $funct3[2:0] = $instr[14:12];
         $rs1[4:0] = $instr[19:15];
         $rs2[4:0] = $instr[24:20];
         $rd[4:0] = $instr[11:7];
         $opcode[6:0] = $instr[6:0];
         // opcode only decodes
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
         $csr_addr[11:0] = $instr[31:20]; //unsigned as opposed to imm
         $csr_uimm[31:0] = {27'b0, $instr[19:15]};
           //write suppression (no valid needed, valid depends on trap depends on illegal_instr
         $csr_src_zero = $is_csr_imm ? ($instr[19:15] == 5'b0) : ($rs1 == 5'b0);
         $csr_wr_req = $is_csr && !(($is_csrrs || $is_csrrc || $is_csrrsi || $is_csrrci) && $csr_src_zero);
         $csr_addr_valid = ($csr_addr == 12'h340) || ($csr_addr == 12'h305)
                           || ($csr_addr == 12'h341) || ($csr_addr == 12'h342)
                           || ($csr_addr == 12'hB00) || ($csr_addr == 12'hB02)
                           || ($csr_addr == 12'h343) || ($csr_addr == 12'h300)
                           || ($csr_addr == 12'h310) || ($csr_addr == 12'h301)
                           || ($csr_addr == 12'hF11) || ($csr_addr == 12'hF12)
                           || ($csr_addr == 12'hF13) || ($csr_addr == 12'hF14);
         //instruction formats, used mainly for gating validity
         $is_i_instr = $is_load || $is_opimm || $is_jalr;
         $is_s_instr = $is_store;
         $is_b_instr = $is_branch;
         $is_u_instr = $is_lui || $is_auipc;
         $is_j_instr = $is_jal;
         $is_r_instr = $is_op;
         $is_csr_imm = $is_csrrwi || $is_csrrsi || $is_csrrci;
         $is_csr = $is_csrrw || $is_csrrs || $is_csrrc || $is_csr_imm;
         //immediate mux
         $imm[31:0] = $is_i_instr ? { {21{$instr[31]}}, $instr[30:20]}:
                      $is_s_instr ? { {21{$instr[31]}}, $instr[30:25], $instr[11:7]}:
                      $is_b_instr ? { {20{$instr[31]}}, $instr[7], $instr[30:25], $instr[11:8], 1'b0}:
                      $is_u_instr ? {$instr[31:12], 12'b0}:
                      $is_j_instr ? { {12{$instr[31]}}, $instr[19:12], $instr[20], $instr[30:21], 1'b0}:
                      32'b0;
         // valid fields
         $funct7_valid = ($funct7 == 7'b0) || ($funct7 == 7'b0100000);
         $funct3_valid = $is_r_instr || $is_i_instr || $is_s_instr || $is_b_instr;
         $rs1_valid = $is_r_instr || $is_i_instr || $is_s_instr || $is_b_instr || ($is_csr && !$is_csr_imm);
         $rs2_valid = $is_r_instr || $is_s_instr || $is_b_instr;
         $rd_valid = ($is_r_instr || $is_i_instr || $is_u_instr || $is_j_instr || $is_csr) && $rd != 5'b0;
         // SYSTEM sub-decode
         $is_ecall  = $instr == 32'h00000073;
         $is_ebreak = $instr == 32'h00100073;
         $is_mret   = $instr == 32'h30200073;
         //branch target address
         $br_target_pc[31:0] = $pc + $imm;

         //silencing signals
         `BOGUS_USE($rd $rd_valid $rs1 $rs1_valid $rs2 $rs2_valid $opcode $funct3 $funct3_valid $is_u_instr $is_i_instr $is_s_instr $is_b_instr $is_j_instr $is_r_instr
                    $is_beq $is_bne $is_blt $is_bge $is_bltu $is_bgeu $is_addi $is_add $dec_bits $imm $src1_value $src2_value $is_lw $is_sw $src2_or_imm
                    $illegal_instr $is_ebreak $is_ecall)

         // Register File
         // Write port control (sourced from the WB stage)
         $rf_wr_en = >>3$rd_valid && >>3$rd != 5'b0 && >>3$valid && (!>>3$valid_misaligned_id && !>>3$valid_misaligned_ex);
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
         $is_lb = {$funct3, $opcode} ==? 10'b000_0000011;
         $is_lh = {$funct3, $opcode} ==? 10'b001_0000011;
         $is_lbu = {$funct3, $opcode} ==? 10'b100_0000011;
         $is_lhu = {$funct3, $opcode} ==? 10'b101_0000011;
         $is_sw = {$funct3, $opcode} ==? 10'b010_0100011;
         $is_sb = {$funct3, $opcode} ==? 10'b000_0100011;
         $is_sh = {$funct3, $opcode} ==? 10'b001_0100011;




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
         $mem_fwd_value[31:0] = (>>1$is_lw || >>1$is_lh || >>1$is_lhu || >>1$is_lb || >>1$is_lbu) ? >>1$ld_data : >>1$result;
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
         $mtval_old[31:0] = >>1$mtval;
         $mstatus_mpie_old = >>1$mstatus_mpie;
         $mstatus_mie_old = >>1$mstatus_mie;
           //mstatus_value for an M mode only processor only has 2 variable flops
         $mstatus_value[31:0] = {19'b0, 2'b11, 3'b0, $mstatus_mpie_old, 3'b0, $mstatus_mie_old, 3'b0};
         $trap_target_pc[31:0] = $mtvec_old;
         $mret_target_pc[31:0] = $mepc_old;
           //misa register fields, editable for future extension
         $misa_mxl[1:0] = 2'b01; //rv32
         $misa_extensions[25:0] = 26'h100; //I mode
         $misa_val[31:0] = {$misa_mxl, 4'b0, $misa_extensions};
           //read-mod-write muxes
         $csr_read_data[31:0] = ($csr_addr == 12'h300) ? $mstatus_value:
                                ($csr_addr == 12'h340) ? $mscratch_old:
                                ($csr_addr == 12'h301) ? $misa_val:
                                ($csr_addr == 12'h305) ? $mtvec_old:
                                ($csr_addr == 12'h341) ? $mepc_old:
                                ($csr_addr == 12'h342) ? $mcause_old:
                                ($csr_addr == 12'h343) ? $mtval_old:
                                ($csr_addr == 12'hB00) ? $mcycle_old:
                                ($csr_addr == 12'hB02) ? $minstret_old:
                                32'b0; //more CSRs go here, also covers mstatush and all four 0xF1x regs
         $csr_src[31:0] = $is_csr_imm ? $csr_uimm : $src1_value_fwd;
         $csr_new_value[31:0] = ($is_csrrw || $is_csrrwi) ? $csr_src:
                              ($is_csrrs || $is_csrrsi) ? $csr_read_data | $csr_src:
                              ($is_csrrc || $is_csrrci) ? $csr_read_data & ~$csr_src:
                              32'b0;
         $csr_wr_en = $csr_wr_req && $valid;
           //next state flops
         $mscratch[31:0] = $reset ? 32'b0:  //plain storage: hold unless written
                           ($csr_wr_en && $csr_addr == 12'h340) ? $csr_new_value : $mscratch_old;
         $mcycle[31:0] = $reset ? 32'b0:    //background update, counts unless there is an explicit write
                         ($csr_wr_en && $csr_addr == 12'hB00) ? $csr_new_value : ($mcycle_old + 32'b1);
         $minstret[31:0] = $reset ? 32'b0:  //counts retirements not cycles, only adds one if valid and not explicit write
                           ($csr_wr_en && $csr_addr == 12'hB02) ? $csr_new_value: $minstret_old + {31'b0, $valid && !$valid_misaligned_id && !$valid_misaligned_ex};
         $mtvec[31:0] = $reset ? 32'b0:
                        ($csr_wr_en && ($csr_addr == 12'h305)) ? {$csr_new_value[31:2], 2'b00}: //mask to set MODE to direct
                        $mtvec_old;
         $mepc[31:0] = $reset ? 32'b0:
                       $take_trap ? $pc:
                       ($csr_wr_en && ($csr_addr == 12'h341)) ? {$csr_new_value[31:2], 2'b00}: //masks low bits to align, will change with C extension
                       $mepc_old;
         $mcause[31:0] = $reset ? 32'b0: //32b sig to match RISCOF test result over spec matching
                         $valid_trap ? $trap_cause:
                         ($valid_misaligned_id || $valid_misaligned_ex) ? 32'b0:
                         ($csr_wr_en && ($csr_addr == 12'h342)) ? $csr_new_value:
                         $mcause_old;
         $mtval[31:0] = $reset ? 32'b0:
                        $valid_trap ? 32'b0:
                        $valid_misaligned_id ? $br_target_pc: //mutually exclusive w valid_trap
                        $valid_misaligned_ex ? ($is_jalr ? $jalr_target_pc : $br_target_pc):
                        $csr_wr_en && ($csr_addr == 12'h343) ? $csr_new_value: //mutually exclusive w above
                        $mtval_old;
         $mstatus_mie = $reset ? 1'b0: //interrupts currently enabled
                        $take_trap ? 1'b0:
                        $valid_mret ? $mstatus_mpie_old:
                        ($csr_wr_en && ($csr_addr == 12'h300)) ? $csr_new_value[3] : $mstatus_mie_old;
         $mstatus_mpie = $reset ? 1'b0: //interrupts enabled before trap
                         $take_trap ? $mstatus_mie_old:
                         $valid_mret ? 1'b1:
                         ($csr_wr_en && ($csr_addr == 12'h300)) ? $csr_new_value[7] : $mstatus_mpie_old;


         //Branch Logic
         $src2_or_imm_fwd[31:0] = $is_r_instr ? $src2_value_fwd : $imm;
         $taken_br = $is_b_instr && $is_beq ? $src1_value_fwd == $src2_value_fwd:
                     $is_b_instr && $is_bne ? $src1_value_fwd != $src2_value_fwd:
                     $is_b_instr && $is_blt ? ($src1_value_fwd < $src2_value_fwd) ^ ($src1_value_fwd[31] != $src2_value_fwd[31]):
                     $is_b_instr && $is_bge ? ($src1_value_fwd >= $src2_value_fwd) ^ ($src1_value_fwd[31] != $src2_value_fwd[31]):
                     $is_b_instr && $is_bltu ? $src1_value_fwd < $src2_value_fwd:
                     $is_b_instr && $is_bgeu ? $src1_value_fwd >= $src2_value_fwd:
                     1'b0;
         $mispredicted = !($is_jal || $is_jalr || $is_mret) //these instructions self correct earlier in the pipeline
                         && (($taken_br != $pred_taken_f) || ($taken_br && $pred_taken_f && ($br_target_pc != $br_predicted_pc_f)));
         $valid_mispredicted = $valid && $mispredicted;
         $misaligned_ex = ($taken_br && $br_target_pc[1:0] != 2'b00) || ($is_jalr && $jalr_target_pc[1:0] != 2'b00);
         $valid_misaligned_ex = $valid && $misaligned_ex;
         $take_trap = $valid_trap || $valid_misaligned_id || $valid_misaligned_ex;

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
         $dmem_wr_en = ($is_sw || $is_sh || $is_sb) && $valid;
         $dmem_index[4:0] = $addr[6:2];
         $dmem_wr_data[31:0] = $funct3 == 3'b010 ? $src2_value_fwd:
                               $funct3 == 3'b001 ? $addr[1:0] == 2'b00 ? {/dmem[$dmem_index]>>1$value[31:16], $src2_value_fwd[15:0]}:
                                                $addr[1:0] == 2'b10 ? {$src2_value_fwd[15:0], /dmem[$dmem_index]>>1$value[15:0]}:
                                         32'hFFFFFFFF : //writes a garbage value for now, TODO at tier 1: misalign trap
                               $funct3 == 3'b000 ? ($addr[1:0] == 2'b00 ? {/dmem[$dmem_index]>>1$value[31:8], $src2_value_fwd[7:0]}:
                                                $addr[1:0] == 2'b01 ? {/dmem[$dmem_index]>>1$value[31:16], $src2_value_fwd[7:0], /dmem[$dmem_index]>>1$value[7:0]}:
                                                $addr[1:0] == 2'b10 ? {/dmem[$dmem_index]>>1$value[31:24], $src2_value_fwd[7:0], /dmem[$dmem_index]>>1$value[15:0]}:
                                                {$src2_value_fwd[7:0], /dmem[$dmem_index]>>1$value[23:0]}) :
                               32'b0; //dmem_wr_en low guarenteed so doesn't matter
         /dmem[31:0]
            $my_wr_en = |cpu$dmem_wr_en && (|cpu$dmem_index == #dmem);
            $value[31:0] = |cpu$reset ? 32'b0:
                           $my_wr_en ? |cpu$dmem_wr_data:
                           $RETAIN;
         $ld_data[31:0] = $funct3 == 3'b001 ? ($addr[1] ? { {16{/dmem[$dmem_index]$value[31]}}, /dmem[$dmem_index]$value[31:16]}:
                                                       { {16{/dmem[$dmem_index]$value[15]}}, /dmem[$dmem_index]$value[15:0]}) :
                          $funct3 == 3'b101 ? ($addr[1] ? {16'b0, /dmem[$dmem_index]$value[31:16]}:
                                                       {16'b0, /dmem[$dmem_index]$value[15:0]}) :
                          $funct3 == 3'b000 ? ($addr[1:0] == 2'b00 ? { {24{/dmem[$dmem_index]$value[7]}}, /dmem[$dmem_index]$value[7:0]}:
                                            $addr[1:0] == 2'b01 ? { {24{/dmem[$dmem_index]$value[15]}}, /dmem[$dmem_index]$value[15:8]}:
                                            $addr[1:0] == 2'b10 ? { {24{/dmem[$dmem_index]$value[23]}}, /dmem[$dmem_index]$value[23:16]}:
                                            { {24{/dmem[$dmem_index]$value[31]}}, /dmem[$dmem_index]$value[31:24]}) :
                          $funct3 == 3'b100 ? ($addr[1:0] == 2'b00 ? {24'b0, /dmem[$dmem_index]$value[7:0]}:
                                            $addr[1:0] == 2'b01 ? {24'b0, /dmem[$dmem_index]$value[15:8]}:
                                            $addr[1:0] == 2'b10 ? {24'b0, /dmem[$dmem_index]$value[23:16]}:
                                            {24'b0, /dmem[$dmem_index]$value[31:24]}) :
                          /dmem[$dmem_index]$value; //saves gates by aliasing funct3 instead of is_*, order lh, lhu, lb, lbu, lw
      @4 //WB
         $rf_wr_data[31:0] = ($is_lw || $is_lh || $is_lhu || $is_lb || $is_lbu) ? $ld_data:
                             $result;
\SV
   endmodule
