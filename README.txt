PIPELINING:
  Code Relocation: There were a variety of snippets to be moved once the pipeline stages were established. The code had been written sequentially through the steps outlined in "How to Build a RISCV CPU Core" taught by Steve Hoover of Redwood EDA. Referencing signals in another stage is easy for TL-Verilog but the provided register file macro was unable to consume signals staged in another part of the pipeline, and even after arranging the existing code into the stages of the pipeline it became clear I would need to implement the parts of the processor that are missing into the file itself instead of using macros. I decided to start with the register file as I have the macro to compare against.

  Register File:
  Split into three logical chunks: write port control, read port control, reg file array.
    Write port control is just taking parent signals from the WB stage and storing them in a flop to be used within the scope of the register file. There is also a mux included at the write enable signal that gates it against writing to zero or an invalid.
    Read port control is a simple array lookup inside the register file array scope.
    The array is an array of pipelines, essentially 32 copies of the same array differentiated by its own 'scopename' signal, in this case the index rs1/rs2. The entire register file structure itself is only five lines of TL-Verilog.
  Worrying about hazards will be done once at least the data memory is complete so I can worry about stalling and forwarding at the same time. There are currently no plans to dynamically reorder operations so really only RAW hazards are the focus.

  Full Instruction Decode: Only a few operations were covered by the course so The ISA needed expansion which required a few design decisions:
    1. There are only going to be word operations.
    2. The arithmetic shift operation required a bit hack to replace the $signed operator that TL-Verilog reads as a variable rather than a function. If there is a way to register names as signal calls I do not know it.


Forwarding and other hazard detection:
  No OOE, only RAW hazards
  No stalls, values are valid on rising edge so clock drift would mess this up
  No latency from memory right now so no stall logic either
  Two forwarding paths: at the ALU stage the source register signals split into two that are multiplexed with the source and destination valid signals as well as a comparator between the source and destination register. Below is one of four lines for control signals. The data signals follow a similar format.
    $rs1_fwd_mem = $rs1_valid && >>1$rd_valid && (>>1$rd == $rs1);
  The alignment operator (>>) allows for an easy reference to another pipeline's value that fits in the same line of logic and automatically places a fowarding path between the stages.

  At this point I wrote a series of test instructions that targeted these RAW hazards and debugged until the instructions all executed correctly. The next step is adding branch validity logic.

Annulled register file and data mem writes in the shadow of taken branches. Added a valid signal at ID that asserts if the instruction in stage 2 or 3 has a taken branch, muxed that valid signal to write enable signals.

Added trap signal for future implementation of precise exception handling.

Fully refined ISA, added new pc redirect logic for JAL and JALR.

Tested using programs 2 and 3.

Found a bug in the forwarding logic. The compare and poison instructions in 3 jumped forward 2 instructions to an instruction that had the same rd, making the forwarding comparators mistake the forwarded value as valid and forwarding the value before doing the instruction again. The change was to compare valid in the comparators as well.


Test Program 1: For initial hazards
// ---- Setup: operands used by both R-type and I-type tests ----
m4_asm(ADDI, x1, x0, 101)              // x1 = 5
m4_asm(ADDI, x2, x0, 11)               // x2 = 3
m4_asm(ADDI, x3, x0, 1)                // x3 = 1  (shift amount)
m4_asm(ADDI, x4, x0, 111111111111)     // x4 = -1 = 0xFFFFFFFF (12-bit imm, all ones, sign-extended)

// ---- R-type ALU ops (x1=5, x2=3, x3=1, x4=0xFFFFFFFF) ----
m4_asm(ADD,  x5,  x1, x2)              // x5  = 8            (5+3)
m4_asm(SUB,  x6,  x1, x2)              // x6  = 2            (5-3)
m4_asm(AND,  x7,  x1, x2)              // x7  = 1            (5&3)
m4_asm(OR,   x8,  x1, x2)              // x8  = 7            (5|3)
m4_asm(XOR,  x9,  x1, x2)              // x9  = 6            (5^3)
m4_asm(SLT,  x10, x2, x1)              // x10 = 1            (3 < 5, signed)
m4_asm(SLTU, x11, x2, x1)              // x11 = 1            (3 < 5, unsigned)
m4_asm(SLL,  x12, x1, x3)              // x12 = 10           (5 << 1)
m4_asm(SRL,  x13, x1, x3)              // x13 = 2            (5 >> 1)
m4_asm(SRA,  x14, x4, x3)              // x14 = 0xFFFFFFFF   (-1 >>> 1, arithmetic, stays all-ones)

// ---- I-type ALU ops (x1=5, x4=0xFFFFFFFF as base) ----
m4_asm(ADDI,  x15, x1, 11)             // x15 = 8            (5+3)
m4_asm(SLTI,  x16, x1, 1010)           // x16 = 1            (5 < 10, signed)
m4_asm(SLTIU, x17, x1, 1010)           // x17 = 1            (5 < 10, unsigned)
m4_asm(XORI,  x18, x1, 11)             // x18 = 6            (5^3)
m4_asm(ORI,   x19, x1, 11)             // x19 = 7            (5|3)
m4_asm(ANDI,  x20, x1, 11)             // x20 = 1            (5&3)
m4_asm(SLLI,  x21, x1, 1)              // x21 = 10           (5 << 1)
m4_asm(SRLI,  x22, x1, 1)              // x22 = 2            (5 >> 1)
m4_asm(SRAI,  x23, x4, 1)              // x23 = 0xFFFFFFFF   (-1 >>> 1)

// ---- Load/Store ----
m4_asm(SW, x0, x1, 0)                  // mem[word 0] = x1 (5)
m4_asm(LW, x24, x0, 0)                 // x24 = 5   (loads back what was just stored)

// ---- Branches: each sets a poison bit in x25 IF the shadow-squash after a taken

m4_asm(ADDI, x25, x0, 0)               // corruption mask = 0

m4_asm(BEQ,  x2, x2, 1000)             // taken (3==3)   -> should skip next instr
m4_asm(ORI,  x25, x25, 1)              // bit0: BEQ squash failed if this executes

m4_asm(BNE,  x1, x2, 1000)             // taken (5!=3)
m4_asm(ORI,  x25, x25, 10)             // bit1: BNE

m4_asm(BLT,  x2, x1, 1000)             // taken (3<5, signed)
m4_asm(ORI,  x25, x25, 100)            // bit2: BLT

m4_asm(BGE,  x1, x2, 1000)             // taken (5>=3, signed)
m4_asm(ORI,  x25, x25, 1000)           // bit3: BGE

m4_asm(BLTU, x2, x1, 1000)             // taken (3<5, unsigned)
m4_asm(ORI,  x25, x25, 10000)          // bit4: BLTU

m4_asm(BGEU, x1, x2, 1000)             // taken (5>=3, unsigned)
m4_asm(ORI,  x25, x25, 100000)         // bit5: BGEU

// ---- JAL: same shadow-squash idea, plus checks the link value (pc+4) ----
m4_asm(JAL, x26, 100)                 // jump +8, x26 = link = this instr's addr + 4
m4_asm(ORI, x25, x25, 1000000)         // bit6: JAL squash failed if this executes

// ---- JALR: rs1=x0 makes the imm an absolute target (0+imm), which sidesteps
// needing AUIPC/another register just to build a base address for this test.
// Two-cycle shadow (needs the forwarding network, unlike JAL) — this is the
// direct regression test for the >>1$valid chain fix.
m4_asm(JALR, x27, x0, 10101000)        // absolute target = 168, x27 = link = this instr's addr + 4
m4_asm(ORI,  x25, x25, 10000000)       // bit7: JALR squash failed if this executes

// ---- LUI / AUIPC (this is also the JALR landing point) ----
m4_asm(LUI,   x28, 1)                  // x28 = 4096  (1 << 12)
m4_asm(AUIPC, x29, 1)                  // x29 = (this instr's own address) + 4096

// ---- Not-taken confirmation: proves a branch that SHOULD fall through actually does
m4_asm(ADDI, x30, x0, 0)               // 0 = "not yet confirmed"
m4_asm(BEQ,  x1, x2, 1000)             // NOT taken (5 != 3) -> should fall through
m4_asm(ADDI, x30, x0, 1)               // should execute -> x30 = 1 confirms correct fallthrough

m4_asm(BGE, x0, x0, 0)                 // done — infinite loop
m4_asm_end()

Program 2: Control Hazards
m4_asm(ADDI,  x1,  x0, 101)              //   0  x1 = 5
m4_asm(ADDI,  x2,  x0, 11)               //   4  x2 = 3
m4_asm(ADDI,  x25, x0, 0)                //   8  poison mask = 0
m4_asm(ADDI,  x30, x0, 0)                //  12  progress = 0
m4_asm(ADDI,  x31, x0, 0)                //  16  scratch

// ---- Taken branch, BOTH shadow slots distinct ----
m4_asm(BEQ,   x2, x2, 1100)              //  20  taken, +12 -> 32
m4_asm(ORI,   x25, x25, 1)               //  24  bit0: shadow slot 1
m4_asm(ORI,   x25, x25, 10)              //  28  bit1: shadow slot 2
m4_asm(ADDI,  x30, x30, 1)               //  32  progress = 1

// ---- Wrong-path JAL must not redirect; real JAL link + shadow ----
m4_asm(BEQ,   x2, x2, 1100)              //  36  taken, +12 -> 48
m4_asm(JAL,   x0, 110)                   //  40  WRONG-PATH: +12 -> 52. Must NOT redirect
m4_asm(ORI,   x25, x25, 100)             //  44  bit2: shadow slot 2
m4_asm(JAL,   x26, 100)                  //  48  real JAL: +8 -> 56; x26 = 52
m4_asm(ORI,   x25, x25, 1000)            //  52  bit3: JAL shadow / wrong-path JAL landed here
m4_asm(ADDI,  x30, x30, 1)               //  56  progress = 2

// ---- JALR: forwarded base, both shadow slots, wrong-path suppression ----
m4_asm(AUIPC, x31, 0)                    //  60  x31 = 60
m4_asm(BEQ,   x2, x2, 1100)              //  64  taken, +12 -> 76
m4_asm(JALR,  x0, x31, 11100)            //  68  WRONG-PATH: 60+28 = 88. Must NOT redirect
m4_asm(ORI,   x25, x25, 10000)           //  72  bit4: shadow slot 2
m4_asm(JALR,  x27, x31, 100000)          //  76  real JALR: 60+32 = 92; x27 = 80
m4_asm(ORI,   x25, x25, 100000)          //  80  bit5: JALR shadow slot 1
m4_asm(ORI,   x25, x25, 1000000)         //  84  bit6: JALR shadow slot 2
m4_asm(ORI,   x25, x25, 10000000)        //  88  bit7: wrong-path JALR landed here
m4_asm(ADDI,  x30, x30, 1)               //  92  progress = 3 (JALR landing)

// ---- Backward loop: predictor training + predicted-taken/not-taken recovery ----
m4_asm(ADDI,  x31, x0, 101)              //  96  x31 = 5
m4_asm(ADDI,  x31, x31, 111111111111)    // 100  x31 -= 1        <- loop top
m4_asm(BNE,   x31, x0, 1111111111100)    // 104  -4 -> 100
m4_asm(ADDI,  x30, x30, 1)               // 108  progress = 4 (loop exited)

m4_asm(BEQ,   x1, x2, 1100)              // 112  NOT taken (5 != 3)
m4_asm(ADDI,  x30, x30, 1)               // 116  progress = 5 (fallthrough confirmed)
m4_asm(BGE,   x0, x0, 0)                 // 120  halt
m4_asm_end()

Program 3: Forwarding and Memory
*do not insert more instructions past n=156 as that would cause the BHT to incorrectly train and cause a stuck loop
m4_asm(ADDI, x1,  x0, 101)               //   0  x1 = 5
m4_asm(ADDI, x25, x0, 0)                 //   4  poison mask = 0
m4_asm(ADDI, x30, x0, 0)                 //   8  progress = 0

// ---- ALU forwarding, distance 1 (three chained dependents) ----
m4_asm(ADDI, x31, x0, 1)                 //  12  1
m4_asm(ADDI, x31, x31, 1)                //  16  2
m4_asm(ADDI, x31, x31, 1)                //  20  3
m4_asm(XORI, x31, x31, 11)               //  24  3^3 = 0 if correct
m4_asm(BEQ,  x31, x0, 1000)              //  28  skip poison if 0
m4_asm(ORI,  x25, x25, 1)                //  32  bit0: ALU forward dist-1
m4_asm(ADDI, x30, x30, 1)                //  36  progress = 1

// ---- ALU forwarding, distance 2 ----
m4_asm(ADDI, x31, x0, 101)               //  40  5
m4_asm(ADDI, x29, x0, 0)                 //  44  filler
m4_asm(XORI, x31, x31, 101)              //  48  5^5 = 0
m4_asm(BEQ,  x31, x0, 1000)              //  52
m4_asm(ORI,  x25, x25, 10)               //  56  bit1: ALU forward dist-2
m4_asm(ADDI, x30, x30, 1)                //  60  progress = 2

// ---- Load-use forwarding, distance 1 ----
m4_asm(SW,   x0, x1, 0)                  //  64  mem[word0] = 5
m4_asm(LW,   x31, x0, 0)                 //  68  x31 = 5
m4_asm(XORI, x31, x31, 101)              //  72  consumes $ld_data via fwd
m4_asm(BEQ,  x31, x0, 1000)              //  76
m4_asm(ORI,  x25, x25, 100)              //  80  bit2: load-use dist-1
m4_asm(ADDI, x30, x30, 1)                //  84  progress = 3

// ---- Load-use forwarding, distance 2 ----
m4_asm(LW,   x31, x0, 0)                 //  88  x31 = 5
m4_asm(ADDI, x29, x0, 0)                 //  92  filler
m4_asm(XORI, x31, x31, 101)              //  96
m4_asm(BEQ,  x31, x0, 1000)              // 100
m4_asm(ORI,  x25, x25, 1000)             // 104  bit3: load-use dist-2
m4_asm(ADDI, x30, x30, 1)                // 108  progress = 4

// ---- Store data forwarding + nonzero dmem address ----
m4_asm(ADDI, x31, x0, 1010)              // 112  x31 = 10
m4_asm(SW,   x0, x31, 100)               // 116  addr 4 -> word 1; rs2 forwarded dist-1
m4_asm(LW,   x31, x0, 100)               // 120  x31 = 10
m4_asm(XORI, x31, x31, 1010)             // 124
m4_asm(BEQ,  x31, x0, 1000)              // 128
m4_asm(ORI,  x25, x25, 10000)            // 132  bit4: store data fwd / dmem addressing
m4_asm(ADDI, x30, x30, 1)                // 136  progress = 5

// ---- x0 stays zero ----
m4_asm(ADDI, x0, x0, 1)                  // 140  attempt to write x0
m4_asm(BEQ,  x0, x31, 1000)              // 144  x31 = 0 here; skip poison if x0 == 0
m4_asm(ORI,  x25, x25, 100000)           // 148  bit5: x0 was writable
m4_asm(BGE,  x0, x0, 0)                  // 152  halt
m4_asm_end()
