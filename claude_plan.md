Tinker Pipelined Processor — Implementation Plan
1. Architecture Overview
This is an out-of-order, dual-issue processor implementing Tomasulo's algorithm. There are no traditional linear pipeline registers; instead, the ROB, reservation stations, and LSQ serve as the inter-stage state. The logical flow is:


IF → ID/RN → Dispatch → [RS/LSQ] → EX (OOO) → CDB Writeback → Commit
Reset: PC=0x2000, r0–r30=0, r31=524288 (MEM_SIZE).

2. Pipeline Stages
Stage 1 — IF (Instruction Fetch)
Module: fetch.sv

Maintains a 16-instruction (64-byte) fetch buffer. Refills from memory when buffer has fewer than 2 valid instructions.
Dispatches 2 instructions per cycle to ID/RN.
Contains the branch predictor: a 16-entry Branch Target Buffer (BTB), indexed by PC[5:2], each entry holding {valid, tag[63:6], target[63:0], pred_bit[1:0]} (2-bit saturating counter).
Unconditional branches (br, brr, brr L) are resolved at decode with no prediction needed.
Conditional branches (brnz, brgt) use the BTB; if no BTB entry, predict not-taken.
On a misprediction signal from the ROB: flush the fetch buffer, discard the IF/ID latch, redirect PC to the actual branch target.
Output signals to ID/RN latch:

Signal	Width	Description
ifid_valid[1:0]	2	Which slots hold valid instructions
ifid_instr[1:0][31:0]	64	Raw instruction words
ifid_pc[1:0][63:0]	128	PC of each instruction
ifid_pred_pc[63:0]	64	Predicted next fetch address
Stage 2 — ID/RN (Decode + Rename)
Modules: instruction_decoder.sv (×2 instances), rat.sv (RAT + physical reg file)

Decodes both instructions combinationally using two instances of instruction_decoder (reused from prog09 as-is).
Register renaming via RAT:
RAT maps 32 architectural registers → 64 physical registers (6-bit index).
A free list (64-bit shift-register/bitmask) tracks available physical regs.
Source architectural regs are looked up in RAT → get physical reg + current value (if ready) from physical reg file.
Destination arch reg is renamed to a freshly allocated physical reg.
Old physical reg mapping (the one being replaced) is stored in the ROB for later freeing at commit.
WAR and WAW hazards are fully eliminated by renaming.
For each instruction, one ROB entry is allocated (in-order head pointer).
A RAT snapshot (32 × 6 bits = 192 bits) is stored per ROB entry to support fast branch misprediction recovery.
If ROB is full, RS is full, or LSQ is full, or free list has < 2 entries: stall (hold IF/ID latch, do not advance).
Classifies each instruction into a functional unit type:
FU_ALU (0x0–0x9, 0xb–0xe, 0x11, 0x12, 0x18–0x1d)
FU_FPU (0x14–0x17)
FU_LOAD (0x10)
FU_STORE (0x13)
FU_HALT (0xf with L=0)
Dispatch output (written into RS/ROB/LSQ on clock edge):

Signal	Width	Description
dec_valid[1:0]	2	Valid slots
dec_opcode[1:0][4:0]	10	Decoded opcode
dec_fu_type[1:0][1:0]	4	Functional unit type
dec_dest_areg[1:0][4:0]	10	Destination architectural reg
dec_dest_preg[1:0][5:0]	12	Destination physical reg (newly allocated)
dec_old_preg[1:0][5:0]	12	Old physical reg (to be freed at commit)
dec_src1_preg[1:0][5:0]	12	Source 1 physical reg
dec_src2_preg[1:0][5:0]	12	Source 2 physical reg
dec_src1_rdy[1:0]	2	Source 1 value already available
dec_src2_rdy[1:0]	2	Source 2 value already available
dec_src1_val[1:0][63:0]	128	Source 1 value (if ready)
dec_src2_val[1:0][63:0]	128	Source 2 value (if ready)
dec_L[1:0][11:0]	24	Immediate field
dec_pc[1:0][63:0]	128	PC (for branch target calc)
dec_rob_idx[1:0][3:0]	8	Allocated ROB entry index
dec_rat_snap[1:0][191:0]	384	RAT snapshot for mispred recovery
Stage 3 — Issue (Reservation Stations)
Module: rs.sv

Integer RS: 8 entries shared across 2 ALUs.
FP RS: 8 entries shared across 2 FPUs.
Each RS entry holds: {valid, opcode, src1_preg, src1_val, src1_rdy, src2_preg, src2_val, src2_rdy, L, pc, dest_preg, rob_idx}.
CDB snooping: every cycle, all RS entries compare their src1_preg/src2_preg against the CDB broadcast tag. On match: capture value, set ready bit.
Wakeup and select: each cycle, for each functional unit, select one ready RS entry (oldest-first by rob_idx to reduce starvation). Issue to the functional unit.
Structural hazard: if RS is full at dispatch: stall (ID/RN stage does not consume new instructions from IF/ID).
Issue signals (one set per functional unit):

Signal	Width
iss_valid	1
iss_opcode[4:0]	5
iss_src1[63:0], iss_src2[63:0]	128
iss_L[11:0]	12
iss_pc[63:0]	64
iss_dest_preg[5:0]	6
iss_rob_idx[3:0]	4
Stage 4 — EX (Execute, Out-of-Order)
Modules: alu.sv (×2 instances), fpu.sv (instance fpu + one more), lsq.sv (with queues)

ALU (integer, 2 instances):

Handles opcodes: logic (0x0–0x7), branches (0x8–0xe), mov-reg (0x11), movl (0x12), add/sub/mul/div (0x18–0x1d).
Combinational, 1-cycle latency (simple pipelining: registered output to CDB).
For branches: computes actual target PC and taken/not-taken; sends misprediction flag to ROB.
Extracted from prog09 alu.sv (integer cases only).
FPU (float, 2 instances, first named fpu):

Handles opcodes: addf (0x14), subf (0x15), mulf (0x16), divf (0x17).
Extracted from prog09 alu.sv (FP cases only).
Pipelined: 2 stages for addf/subf (normalize + add/subtract + renormalize split across clock edges), 3 stages for mulf/divf. The RS does not re-issue until the unit is free; the latency is tracked by a shift-register ready signal.
Important: all loops use fixed bounds with internal if per clarifications2.md.
LSU + Load/Store Queue (2 logical units in lsq.sv):

Contains a 4-entry load queue and 4-entry store queue.
Address calculation is combinational (done immediately on issue).
Loads:
Compute address from rs + sign_extend(L).
Search store queue for matching address (store-to-load forwarding). If found and store data is ready: forward directly, no memory access.
Else: read from memory module's address_value port. Completes in 1 cycle (combinational memory read, registered output).
Result broadcast on CDB.
Stores:
Compute address, store {addr, data, rob_idx} in store queue.
Do not write to memory until committed from ROB head.
At commit: ROB signals LSQ to dequeue the head store entry; LSQ drives memory module's write port.
Structural hazard: if load/store queue full at dispatch, stall.
Stage 5 — WB (Writeback / CDB)
Integrated into functional units and rob.sv.

Each cycle, up to 4 functional unit groups can complete (ALU0, ALU1, FPU0, FPU1, LSU). When multiple complete on the same cycle, CDB arbitration (priority: ALU0 > ALU1 > FPU0 > FPU1 > LSU; non-winning units are held back one cycle and retry).
Winning unit drives the Common Data Bus: {cdb_valid, cdb_rob_idx[3:0], cdb_dest_preg[5:0], cdb_result[63:0]}.
CDB is snooped simultaneously by:
All RS entries (capture values, clear wait bits)
ROB (mark entry as complete, store result)
Physical register file (write result)
CDB signals:

Signal	Width
cdb_valid	1
cdb_rob_idx[3:0]	4
cdb_dest_preg[5:0]	6
cdb_result[63:0]	64
cdb_mis_pred	1
cdb_actual_pc[63:0]	64
Stage 6 — COM (Commit)
Module: rob.sv

ROB: 16-entry circular buffer (head and tail pointers, 4-bit index).

Each ROB entry:

Field	Width	Purpose
valid	1	Entry occupied
ready	1	Execution complete
fu_type[1:0]	2	ALU/FPU/LD/ST/HALT
dest_areg[4:0]	5	Architectural destination
dest_preg[5:0]	6	Physical destination
old_preg[5:0]	6	Physical reg being replaced (freed at commit)
result[63:0]	64	Computed result
store_addr[63:0]	64	For stores
store_data[63:0]	64	For stores
is_branch	1	Was a branch
pred_pc[63:0]	64	What fetch predicted
actual_pc[63:0]	64	Actual next PC (from EX)
mis_pred	1	Misprediction flag
rat_snap[191:0]	192	RAT snapshot at dispatch
is_halt	1	Halt instruction
Commit logic (up to 2 instructions/cycle in order from head):

If head.ready: commit.
Write result to architectural reg_file (via the 2 write ports).
Free old_preg back to free list.
For stores: signal lsq to flush head store entry to memory.
Advance head pointer.
If head.is_halt: assert hlt = 1 and freeze.
Misprediction recovery: when a branch commits with mis_pred=1:

Flush all ROB entries newer than the branch (squash).
Restore RAT from the branch's rat_snap.
Return all physical regs allocated to squashed instructions to the free list.
Clear all RS entries with rob_idx newer than this branch.
Redirect fetch PC to actual_pc.
3. Module Breakdown (11 files)
File	Module	Description
tinker.sv	tinker_core	Top-level wrapper; instantiates all modules; routes CDB, commit, and flush signals
hdl/fetch.sv	fetch	Fetch buffer (16 instr), 2-per-cycle dispatch, 2-bit sat-counter BTB branch predictor, flush/redirect handling
hdl/instruction_decoder.sv	instruction_decoder	Pure combinational decode of one 32-bit instruction → opcode, d, s, t, L (reused verbatim from prog09)
hdl/reg_file.sv	register_file	Architectural register file; 4 read ports, 2 write ports for dual-issue commit; registers[0:31] array (extend prog09 version)
hdl/memory.sv	memory	512KB byte-addressable memory; bytes[0:MEM_SIZE-1]; combinational read, clocked write only from LSQ at commit (reuse prog09, remove ALU-driven write path)
hdl/alu.sv	alu	Integer ALU: opcodes 0x0–0xe (excl. 0x10/0x13), 0x11, 0x12, 0x18–0x1d; combinational, 1-cycle output register; extracted from prog09 alu.sv
hdl/fpu.sv	fpu	FP unit: opcodes 0x14–0x17; 2-cycle (add/sub) or 3-cycle (mul/div) pipelined; extracted from prog09 alu.sv; first instance named fpu
hdl/rat.sv	rat	RAT (32→64 phys reg map) + free list (64-bit) + physical register file (64 regs × 64 bits, 4 read ports, 2 write ports); handles rename at dispatch and free at commit
hdl/rs.sv	reservation_station	Unified RS module; parameterized depth (8 entries); instantiated once for integer, once for FP; CDB snoop, wakeup, oldest-first issue select
hdl/lsq.sv	lsq	Load queue (4 entries) + store queue (4 entries); store-to-load forwarding; drives memory write port at commit; produces CDB result for loads
hdl/rob.sv	rob	16-entry ROB; circular buffer; dual-issue commit; misprediction flush and RAT restore; free list update; halt detection; drives hlt
4. Pipeline Registers / Inter-Stage State
Interface	Type	Key Signals
IF → ID	Registered latch	ifid_valid[1:0], ifid_instr[1:0][31:0], ifid_pc[1:0][63:0]
ID → RS/ROB/LSQ	Synchronous write into arrays	dec_* signals from §Stage 2 table above
RS → EX	Registered (RS entry captured when issued)	iss_opcode, iss_src1, iss_src2, iss_L, iss_pc, iss_dest_preg, iss_rob_idx
EX → CDB	Registered (output register of each FU)	cdb_valid, cdb_rob_idx, cdb_dest_preg, cdb_result, cdb_mis_pred, cdb_actual_pc
CDB → RS/ROB/phys_regfile	Combinational snoop (written each cycle)	Broadcast from CDB wires
ROB → reg_file/memory/lsq	At commit (clocked)	commit_valid[1:0], commit_dest_areg, commit_result, commit_old_preg, commit_is_store, commit_store_addr/data
5. Hazard Handling
Data Hazards
Hazard	Mechanism	Resolution
RAW (true dependence)	Source operand not yet computed	RS holds instruction; CDB broadcast captures value when produced
WAR (anti-dependence)	Read-after-write ordering	Eliminated by register renaming (RAT assigns unique physical reg to each destination)
WAW (output dependence)	Two writes same arch reg	Eliminated by register renaming
Load-to-use RAW	Load result used immediately	Load completes and broadcasts on CDB; dependent RS entries snoop and wake up
Store-to-load forwarding	Load address matches pending store	LSQ checks store queue on load issue; if address matches and store data ready, forward directly
Structural Hazards
Resource	Hazard	Resolution
ROB full (16 entries)	Cannot allocate new ROB entry	Stall dispatch (hold IF/ID latch)
RS full (8 entries/type)	Cannot allocate RS entry	Stall dispatch
LSQ full (4 load or 4 store entries)	Cannot issue memory op	Stall dispatch
FPU busy (multi-cycle)	FPU still executing	RS does not issue another FPU op until pipeline stage is free; if both FPU instances busy, stall issue
CDB conflict	Multiple FUs complete same cycle	Arbitration (fixed priority); losing FU holds result one extra cycle
Control Hazards
Branch Type	Detection	Resolution
br rd (unconditional indirect)	Decode (rd known after rename; value may not be ready)	Predict with BTB; if BTB miss, stall fetch 1 cycle until rs value available from phys regfile
brr rd (unconditional relative)	Decode	Same as br rd
brr L (unconditional immediate)	Decode	Target = PC + sign_extend(L), resolved at decode; no prediction needed
brnz rd, rs (conditional)	EX (need rs value)	2-bit saturating BTB; misprediction → flush + redirect at commit
brgt rd, rs, rt (conditional)	EX	Same as brnz
call rd, rs, rt	Decode/EX	Treat as indirect branch + store; predict target with BTB
return	EX (reads memory)	Predict with BTB (return address stack would be ideal but BTB suffices)
Misprediction flush sequence (triggered at ROB commit of mispredicted branch):

Assert flush signal.
Clear IF/ID latch.
Invalidate all RS entries with rob_idx strictly newer than the branch.
Squash all ROB entries tail → branch (exclusive): free their dest_preg back to free list.
Restore RAT from the branch ROB entry's rat_snap.
Redirect fetch PC to cdb_actual_pc of the branch.
Update BTB entry with correct direction and target.
6. Control Signal Generation
Control is distributed — there is no centralized control unit. Instead:

Decode classifies each instruction into fu_type and sets reg_write, mem_write, is_branch, is_halt flags that travel with the instruction through its RS and ROB entries.
Opcodes → Functional unit mapping (encoded as 2-bit fu_type):
FU_ALU=2'b00: 0x0–0xe, 0x11, 0x12, 0x18–0x1d
FU_FPU=2'b01: 0x14–0x17
FU_LOAD=2'b10: 0x10
FU_STORE=2'b11: 0x13
Halt (0xf, L=0): treated as FU_ALU with is_halt=1, no reg write, no mem write
ALU control: opcode passed directly to the combinational ALU; it selects its operation by opcode (same as prog09).
FPU control: opcode 0x14–0x17 passed to FPU; selects addf/subf/mulf/divf.
ROB controls commit: reg_write, mem_write, is_halt flags in the ROB entry gate what happens at commit (write to reg_file, signal lsq to flush to memory, assert hlt).
Stall control: a single dispatch_stall signal (ROB full OR RS full OR LSQ full OR free_list < 2) gates the IF/ID register (holds it frozen) and prevents the fetch buffer from advancing.
Flush control: a single flush signal (asserted for one cycle at misprediction commit) resets IF/ID, all RS, and ROB tail entries as described above.
7. Reuse Strategy for prog09 Components
prog09 Module	Reuse in prog10
instruction_decoder.sv	Verbatim reuse. Instantiate twice for dual-issue decode.
reg_file.sv	Minor extension. Add a second write port (write2, data_write2, d2). Keep registers[0:31] array name. Adjust reset loop syntax per clarifications2.md.
memory.sv	Interface change. Remove direct ALU write path; write port is driven exclusively by LSQ at commit. Keep bytes[0:MEM_SIZE-1] array.
alu.sv	Split into two files. Extract integer cases (0x0–0xe, 0x11, 0x12, 0x18–0x1d) into new alu.sv. Extract FP cases (0x14–0x17) into new fpu.sv. Remove memory_value and stack_pointer inputs from ALU (those are handled by LSQ); simplify interface to {opcode, src1, src2, L, pc} → {result, next_pc, reg_write, mis_pred}.
instruction_fetch.sv	Replaced. New fetch.sv is a superset with a fetch buffer, BTB, and dual-issue output.
control_state.sv	Not reused. The OOO engine has no cycle-counting state machine.
8. Key Implementation Notes (per clarifications2.md)
All localparam must be untyped: localparam ROB_SIZE = 16; not localparam int ROB_SIZE = 16;
All loop variables declared outside for: integer i; for (i = 0; ...).
No typedef enum; use localparam [1:0] FU_ALU = 2'b00; etc.
No data-dependent loop termination; use fixed bounds with an internal if and a found flag.
No disable inside loops.
Old-style function declarations if any functions are needed.
No real, $bitstoreal, $realtobits anywhere in synthesizable RTL.
9. Testbench Strategy
test/tb_alu.sv: unit test for integer ALU (all opcodes, edge cases)
test/tb_fpu.sv: unit test for FPU (addf/subf/mulf/divf, subnormals, NaN, inf)
test/tb_rob.sv: test commit ordering, misprediction flush, halt detection
test/tb_tinker_core.sv: integration tests — small programs covering: straight-line computation, loops with branches, function call/return, store-then-load, FP arithmetic, halt