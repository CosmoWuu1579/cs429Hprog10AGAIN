// Architectural register file: 32 x 64-bit registers.
// 4 read ports (rd, rs, rt, r31), 2 write ports for dual-issue commit.
// r31 initialized to MEM_SIZE; r0-r30 initialized to 0.
module register_file (
    input  clk,
    input  reset,
    // Read ports (combinational)
    output wire [63:0] reg_array_out_0,
    output wire [63:0] reg_array_out_1,
    output wire [63:0] reg_array_out_2,
    output wire [63:0] reg_array_out_3,
    output wire [63:0] reg_array_out_4,
    output wire [63:0] reg_array_out_5,
    output wire [63:0] reg_array_out_6,
    output wire [63:0] reg_array_out_7,
    output wire [63:0] reg_array_out_8,
    output wire [63:0] reg_array_out_9,
    output wire [63:0] reg_array_out_10,
    output wire [63:0] reg_array_out_11,
    output wire [63:0] reg_array_out_12,
    output wire [63:0] reg_array_out_13,
    output wire [63:0] reg_array_out_14,
    output wire [63:0] reg_array_out_15,
    output wire [63:0] reg_array_out_16,
    output wire [63:0] reg_array_out_17,
    output wire [63:0] reg_array_out_18,
    output wire [63:0] reg_array_out_19,
    output wire [63:0] reg_array_out_20,
    output wire [63:0] reg_array_out_21,
    output wire [63:0] reg_array_out_22,
    output wire [63:0] reg_array_out_23,
    output wire [63:0] reg_array_out_24,
    output wire [63:0] reg_array_out_25,
    output wire [63:0] reg_array_out_26,
    output wire [63:0] reg_array_out_27,
    output wire [63:0] reg_array_out_28,
    output wire [63:0] reg_array_out_29,
    output wire [63:0] reg_array_out_30,
    output wire [63:0] reg_array_out_31,
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

    genvar g;
    generate 
        assign reg_array_out_0 = registers[0];
        assign reg_array_out_1 = registers[1];
        assign reg_array_out_2 = registers[2];
        assign reg_array_out_3 = registers[3];
        assign reg_array_out_4 = registers[4];
        assign reg_array_out_5 = registers[5];
        assign reg_array_out_6 = registers[6];
        assign reg_array_out_7 = registers[7];
        assign reg_array_out_8 = registers[8];
        assign reg_array_out_9 = registers[9];
        assign reg_array_out_10 = registers[10];
        assign reg_array_out_11 = registers[11];
        assign reg_array_out_12 = registers[12];
        assign reg_array_out_13 = registers[13];
        assign reg_array_out_14 = registers[14];
        assign reg_array_out_15 = registers[15];
        assign reg_array_out_16 = registers[16];
        assign reg_array_out_17 = registers[17];
        assign reg_array_out_18 = registers[18];
        assign reg_array_out_19 = registers[19];
        assign reg_array_out_20 = registers[20];
        assign reg_array_out_21 = registers[21];
        assign reg_array_out_22 = registers[22];
        assign reg_array_out_23 = registers[23];
        assign reg_array_out_24 = registers[24];
        assign reg_array_out_25 = registers[25];
        assign reg_array_out_26 = registers[26];
        assign reg_array_out_27 = registers[27];
        assign reg_array_out_28 = registers[28];
        assign reg_array_out_29 = registers[29];
        assign reg_array_out_30 = registers[30];
        assign reg_array_out_31 = registers[31];
    endgenerate 
endmodule
