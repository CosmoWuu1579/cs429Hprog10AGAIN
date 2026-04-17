// Architectural register file: 32 x 64-bit registers.
// 4 read ports (rd, rs, rt, r31), 2 write ports for dual-issue commit.
// r31 initialized to MEM_SIZE; r0-r30 initialized to 0.
module register_file (
    input  clk,
    input  reset,
    // Read ports (combinational)
    input  wire [4:0]  d,
    input  wire [4:0]  s,
    input  wire [4:0]  t,
    output reg  [63:0] rd,
    output reg  [63:0] rs,
    output reg  [63:0] rt,
    output reg  [63:0] stack_pointer,
    // Write port 0
    input  wire        write0,
    input  wire [4:0]  waddr0,
    input  wire [63:0] wdata0,
    // Write port 1
    input  wire        write1,
    input  wire [4:0]  waddr1,
    input  wire [63:0] wdata1
);
    localparam MEM_SIZE = 524288;
    reg [63:0] registers [0:31];

    integer i;
    initial begin
        for (i = 0; i < 31; i = i + 1) registers[i] = 64'b0;
        registers[31] = MEM_SIZE;
    end

    // Combinational reads
    always @(*) begin
        rd            = registers[d];
        rs            = registers[s];
        rt            = registers[t];
        stack_pointer = registers[31];
    end

    // Clocked writes and reset
    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < 31; i = i + 1) registers[i] <= 64'b0;
            registers[31] <= MEM_SIZE;
        end else begin
            if (write0) registers[waddr0] <= wdata0;
            if (write1) registers[waddr1] <= wdata1;
        end
    end
endmodule
