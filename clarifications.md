Submission Instructions:
The following are the main deliverables:

A file named exactly tinker.sv in the top directory of your submission

This is the module that represents your tinker CPU core

Your testing code

You will likely have multiple modules for each component (register file, ALU/FPU, etc.), so it is good to have multiple testbenches for each (including one for the overall tinker core)

These testbenches should test inputs to the module and validate the output and/or state of the CPU (i.e., by producing a waveform file, printing to console, etc.)

A README with your name and EID, as well as instructions on how to compile and run your testing code

Submit to Gradescope:

You can submit as a zip or through Github

Review tests that you missed. There may be hidden tests

These will primarily be correctness tests

Code Style: please write comments and clean code for this assignment (should be easier with AI; see below) for ease of grading the optimizations

The purpose of this assignment is not to stress y'all out with implementing all optimizations but to make sure you understand pipelined processors


Clarifications:
As stated by Mootaz during lecture, you may use AI for this project

For this assignment, your implementation should be a pipelined processor. In addition, all optimizations specified in the spec are required

Tinker CPU Core (tinker.sv):

In tinker.sv, there must be a module named tinker_core with the following signature:

module tinker_core (
    input clk,
    input reset,
    output logic hlt
);
Your should set the hlt signal to 1 when it is committed from the reorder buffer (oldest instruction)
halt (priv with L = 0x0) is the only privileged instruction you need to implement
Register File:

Same signature as previous assignment, though note that those 32 registers represents the architectural registers for Tinker. You will need a separate set of >32 physical registers to implement register renaming 

ALU/FPU:

The floating-point unit must be a separate module from the integer ALU and must be instantiated with the instance name fpu. Once you implement dual issue, the name of the second one does not matter

Memory:

Same signature as previous assignment; remember that store instructions are only written to memory when they are committed from the reorder buffer (oldest instruction)

Forwarding:

For an OOO processor, traditional forwarding doesn't apply in the same sense. A common data bus should broadcast results from computation units (ALU, FPU, etc.), and other reservation stations will be listening

You should have store-to-load forwarding through the load/store queues

Multi-Issue:

Your processor should be dual-issue at minimum

Out-of-Order:

The architecture should be similar to Tomasulo's algorithm (as shown in discussion/lecture)

Modules you should probably have:

Fetch

Decode

Register Alias Table (for renaming)

Physical register file

Architectural register file (reg_file)

Reservation stations

Functional units (ALU/FPU)

Load/store queues

Physical memory (memory)

Reorder buffer


Recommendations:
Organize your files; as shown in discussion, we recommend 4 subdirectories:

hdl/: contains all your module definitions (.v files)

sim/: contains any waveform files produced by simulation (.vcd files)

test/: contains all testbench code

vvp/: contains the compiled output of your code (.vvp files)

Review the discussion slides from last week for the OOO processor architecture (especially watch the video attached toward the end of the slides)

Use online resources for implementation details of OOO, branch prediction, etc.

Look at visualizations of existing architectures

Additional Notes:
On reset, you should set PC to 0x2000, r0-r30 to 0, and r31 to MEM_SIZE (512 KB)

Inside tinker_core, you must instantiate separate modules for the fetch module, instruction decoder, register file, memory, and ALU/FPU

The register file must be instantiated with the instance name reg_file 

The memory must be instantiated with the instance name memory 

For both modules above, the module name does not matter; all other modules can be any name and instantiated with any name

Register File:

The contents of the register file must be stored in a packed array named registers declared exactly as follows:

reg [63:0] registers [0:31];
If you are unsure how packed arrays work, refer to HDLBits: Unpacked vs. Packed Arrays

Memory:

The contents of the memory must be stored in packed array named bytes declared exactly as follows:

reg [7:0] bytes [0:MEM_SIZE-1];
The autograder testbench will write instructions into this array at 0x2000 before resetting and starting the program execution

ALU/FPU:

For floating point instructions, implement the arithmetic logic manually using standard bit vectors as a physical processor would

As you do the assignment, you may come across a real data type as well as functions $realtobits and $bitstoreal. This is only used in simulation, and cannot be synthesized into hardware; you should not use these to implement your floating point instructions

Output:

There is no other output needed from your design besides updating the register file and memory

The autograder testbench will go inside the modules and inspect the registers and bytes arrays directly to verify your design’s functionality