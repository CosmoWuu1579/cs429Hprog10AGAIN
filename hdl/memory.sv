// Byte-addressable memory, 512 KB.
// Instruction fetch is combinational (pc_address port).
// Data read is combinational (rd_addr port -> rd_data).
// Data write is clocked and gated by mem_write — driven only by LSQ at commit time.
module memory (
    input  clk,
    input  reset,
    // Instruction fetch ports (combinational, dual-issue)
    input  wire [63:0] pc_address,
    output wire [31:0] instruction,
    input  wire [63:0] pc_address2,
    output wire [31:0] instruction2,
    // Data read port (combinational)
    input  wire [63:0] rd_addr,
    output wire [63:0] rd_data,
    // Data write port (clocked, commit-only)
    input  wire        mem_write,
    input  wire [63:0] wr_addr,
    input  wire [63:0] wr_data
);
    localparam MEM_SIZE = 524288;
    reg [7:0] bytes [0:MEM_SIZE-1];

    integer i;
    initial begin
        for (i = 0; i < MEM_SIZE; i = i + 1) bytes[i] = 8'h00;
    end

    assign instruction  = {bytes[pc_address+3],  bytes[pc_address+2],
                           bytes[pc_address+1],  bytes[pc_address]};
    assign instruction2 = {bytes[pc_address2+3], bytes[pc_address2+2],
                           bytes[pc_address2+1], bytes[pc_address2]};

    assign rd_data = {bytes[rd_addr+7], bytes[rd_addr+6], bytes[rd_addr+5], bytes[rd_addr+4],
                      bytes[rd_addr+3], bytes[rd_addr+2], bytes[rd_addr+1], bytes[rd_addr]};

    always @(posedge clk) begin
        if (mem_write) begin
            bytes[wr_addr+7] <= wr_data[63:56];
            bytes[wr_addr+6] <= wr_data[55:48];
            bytes[wr_addr+5] <= wr_data[47:40];
            bytes[wr_addr+4] <= wr_data[39:32];
            bytes[wr_addr+3] <= wr_data[31:24];
            bytes[wr_addr+2] <= wr_data[23:16];
            bytes[wr_addr+1] <= wr_data[15:8];
            bytes[wr_addr]   <= wr_data[7:0];
        end
    end
endmodule
