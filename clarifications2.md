The timing-only part of the autograder uses yosys, which accepts a narrower subset of SystemVerilog than iverilog. If you want your design to be eligible for the timing bucket, please avoid the following patterns in synthesizable RTL:

// avoid enum typedefs like this
typedef enum logic [4:0] {
    OP_ADD = 5'h18,
    OP_SUB = 5'h1a,
    OP_HALT = 5'hf
} opcode_e;

// use plain constants instead
localparam [4:0] OP_ADD  = 5'h18;
localparam [4:0] OP_SUB  = 5'h1a;
localparam [4:0] OP_HALT = 5'hf;

// avoid loop-variable declarations in the for header
for (int i = 0; i < 31; i++) begin
    registers[i] <= 0;
end

// declare the loop variable outside instead
integer i;
for (i = 0; i < 31; i = i + 1) begin
    registers[i] <= 0;
end

// avoid data-dependent while loops
while (mantissa_sum[52] == 1'b0 && exp_c > 0) begin
    mantissa_sum = mantissa_sum << 1;
    exp_c = exp_c - 1;
end

// use a fixed-bound loop with an if inside
integer i;
for (i = 0; i < 53; i = i + 1) begin
    if (mantissa_sum[52] == 1'b0 && exp_c > 0) begin
        mantissa_sum = mantissa_sum << 1;
        exp_c = exp_c - 1;
    end
end

// avoid runtime-terminated for loops
for (i = 0; (i < 54) && !sum[52] && (er > 1); i = i + 1) begin
    sum = sum << 1;
    er = er - 1;
end

// use a fixed iteration bound instead
for (i = 0; i < 54; i = i + 1) begin
    if (!sum[52] && (er > 1)) begin
        sum = sum << 1;
        er = er - 1;
    end
end

// avoid disable-based loop exits
for (i = 63; i >= 0; i = i - 1) begin : clz_loop
    if (sig[i]) disable clz_loop;
    count = count + 1;
end

// use a flag instead
logic found;
count = 0;
found = 0;
for (i = 63; i >= 0; i = i - 1) begin
    if (!found) begin
        if (sig[i]) found = 1;
        else count = count + 1;
    end
end

// avoid typed localparams
localparam int ROB_SIZE = 4;
localparam bit ENABLE_BRANCH_PRED = 1'b1;

// use plain localparams instead
localparam ROB_SIZE = 4;
localparam ENABLE_BRANCH_PRED = 1'b1;

// avoid modern typed function headers
function automatic logic [63:0] predicted_next_pc(input logic [63:0] pc);
    ...
endfunction

// use old-style function declarations instead
function [63:0] predicted_next_pc;
    input [63:0] pc;
    ...
endfunction

Also avoid real, $bitstoreal, and $realtobits in synthesizable RTL (this part is not optional). If your code uses only fixed-bounds loops, bit-vector logic, and plain constants, it is much more likely to work with the timing flow.