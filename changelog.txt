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

Added Control/Status registers and corresponding instructions. Added decoding signals including separate address signal as imm needs to be sign extended but not this address. Updated illegal_instr to assert when the CSR is being used in the wrong way. Added multiplexers to choose whether to update the CSR regs based on different conditions.
Tested with 4.

Refined trap signal to actually do something using CSRs. This required a complete rebuilding of the valid signal into two different classifications, on path vs off path. A trap instruction is on the right path but cannot retire requiring this distinction. Purely additive, no need to switch existing valid dependencies.

Added the rest of the CSR suite, added $on_path signal that gates to valid allowing for traps that are in the shadow of invalid instructions

Precise exceptions have been reached. Instruction N traps its $valid signal to 0 which gates pretty much everything: register/memory/csr reads and writes. Instructions N+1 and N+2 are squashed by $on_path and everything before S is already committed due to not having speculation.
