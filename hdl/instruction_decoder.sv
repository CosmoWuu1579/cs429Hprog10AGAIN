// Combinational decode of one 32-bit Tinker instruction.
// Bit layout: [31:27]=opcode [26:22]=d [21:17]=s [16:12]=t [11:0]=L
module instruction_decoder (
    input  wire [31:0] instruction,
    output wire [4:0]  opcode,
    output wire [4:0]  d,
    output wire [4:0]  s,
    output wire [4:0]  t,
    output wire [11:0] L
);
    assign opcode = instruction[31:27];
    assign d      = instruction[26:22];
    assign s      = instruction[21:17];
    assign t      = instruction[16:12];
    assign L      = instruction[11:0];
endmodule
