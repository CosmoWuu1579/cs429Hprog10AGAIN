# Tinker OOO Processor — prog10

**Name:** Cosmo Wu
**EID:** cosmowu

## Overview

Out-of-order dual-issue Tinker processor using Tomasulo's algorithm.
Features: register renaming (32 arch → 64 phys), 16-entry ROB, per-FU reservation stations,
5-stage pipelined FPU, BTB branch prediction, load/store queue with store-to-load forwarding.

## Dependencies

- `iverilog` (Icarus Verilog, version 11+)
- `vvp` (bundled with iverilog)

## Compile

```bash
# Compile the core (used by all testbenches via `include)
iverilog -g2012 -o vvp/tinker tinker.sv

# Compile the basic testbench
iverilog -g2012 -o vvp/tb_tinker_core test/tb_tinker_core.sv
```

## Run

```bash
# Run the basic testbench (integer ALU: addi, add, sub, mul, or, and, xor, halt)
vvp vvp/tb_tinker_core
```

Expected output:
```
Halted after N cycles
r1 = 5 (expect 5)
r2 = 7 (expect 7)
r3 = 12 (expect 12)
r4 = 2 (expect 2)
r5 = 24 (expect 24)
r6 = 7 (expect 7)
r7 = 0 (expect 0)
r8 = 2 (expect 2)
PASS: all registers correct
```

A waveform dump is written to `sim/tb_tinker_core.vcd` and can be viewed with GTKWave:
```bash
gtkwave sim/tb_tinker_core.vcd
```

## File Structure

```
tinker.sv                  # Top-level tinker_core module
hdl/
  instruction_decoder.sv   # Combinational instruction decode
  reg_file.sv              # Architectural register file (committed state)
  memory.sv                # Byte-addressable memory with dual instruction fetch
  alu.sv                   # Integer ALU (combinational)
  fpu.sv                   # 5-stage pipelined FPU (addf/subf/mulf/divf)
  fetch.sv                 # Fetch buffer + BTB branch predictor
  rat.sv                   # Register Alias Table + free list + physical reg file
  rs.sv                    # Parameterized reservation station
  lsq.sv                   # Load/store queue
  rob.sv                   # Reorder buffer
test/
  tb_tinker_core.sv        # Basic integer ALU testbench
```
