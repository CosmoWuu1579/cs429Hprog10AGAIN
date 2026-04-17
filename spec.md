# Tinkering with the Pipeline
## Task Definition
Implement a pipelined Tinker. Assume the microarchitecture has:
- One fetch unit that reads 64 bytes at a time.
- One instruction and decode unit.
- A register file with 4 read ports, 2 write ports.
- Two ALUs.
- Two FPUs.
- Two L/S units.
## Allowable Optimizations
You need to implement the following optimizations below.
- Forwarding.
- Multi-issue instructions.
- Out of order execution.
- Pipelining the execution units (ALU and FPU).
- Adding queues to the L/S units.
- Deepening the pipelines.
- Branch predictions.
- Register renaming.
