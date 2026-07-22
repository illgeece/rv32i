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
