// Integer ALU for Tinker OOO pipeline.
// Combinational. Handles all non-FP opcodes.
// src1 = physical value of rs (or rd for immediate-format instructions).
// src2 = physical value of rt.
// For branch instructions: result = actual next PC; reg_write = 0.
// For call: mem_write=1, mem_addr=r31-8, mem_data=pc+4, result=target PC.
// For return: mem_read=1, mem_addr=r31-8; caller must provide mem_val.
module alu (
    input  wire [4:0]  opcode,
    input  wire [63:0] src1,      // rs value (or rd for addi/subi/shftri/shftli/movl)
    input  wire [63:0] src2,      // rt value
    input  wire [11:0] L,
    input  wire [63:0] pc,
    input  wire [63:0] r31,       // stack pointer value
    input  wire [63:0] mem_val,   // value read from memory (for return)
    input  wire [63:0] rd_val,   // rd register value (for brgt target, brgt/brnz routing)
    // Results
    output reg  [63:0] result,    // register write value or next PC for branches
    output reg         reg_write,
    output reg         mem_write,
    output reg  [63:0] mem_addr,
    output reg  [63:0] mem_wdata,
    output reg         mem_read,  // 1 = this op needs memory read (return)
    output reg  [63:0] next_pc    // next PC (pc+4 for non-branches, target for branches)
);
    wire [63:0] L_sext;
    assign L_sext = {{52{L[11]}}, L};

    always @(*) begin
        result     = 64'b0;
        reg_write  = 1'b0;
        mem_write  = 1'b0;
        mem_addr   = 64'b0;
        mem_wdata  = 64'b0;
        mem_read   = 1'b0;
        next_pc    = pc + 4;

        case (opcode)
            // --- Logic ---
            5'h00: begin result = src1 & src2;       reg_write = 1; end  // and
            5'h01: begin result = src1 | src2;       reg_write = 1; end  // or
            5'h02: begin result = src1 ^ src2;       reg_write = 1; end  // xor
            5'h03: begin result = ~src1;             reg_write = 1; end  // not (src1=rs)
            // --- Shift ---
            5'h04: begin result = src1 >> src2;      reg_write = 1; end  // shftr
            5'h05: begin result = src1 >> L;         reg_write = 1; end  // shftri (src1=rd)
            5'h06: begin result = src1 << src2;      reg_write = 1; end  // shftl
            5'h07: begin result = src1 << L;         reg_write = 1; end  // shftli (src1=rd)
            // --- Branches (result = actual next PC) ---
            5'h08: begin next_pc = src1;             reg_write = 0; end  // br rd
            5'h09: begin next_pc = pc + src1;        reg_write = 0; end  // brr rd
            5'h0a: begin next_pc = pc + L_sext;      reg_write = 0; end  // brr L
            5'h0b: begin                                                  // brnz rd, rs
                // src1 = rd (target, routed via eff_s = d), src2 = rs (condition, via eff_t = s)
                next_pc = (src2 != 0) ? src1 : pc + 4;
                reg_write = 0;
            end
            5'h0c: begin                                                  // call rd
                mem_write = 1;
                mem_addr  = r31 - 8;
                mem_wdata = pc + 4;
                next_pc   = src1;
                reg_write = 0;
            end
            5'h0d: begin                                                  // return
                mem_read = 1;
                mem_addr = r31 - 8;
                next_pc  = mem_val;
                reg_write = 0;
            end
            5'h0e: begin                                                  // brgt rd, rs, rt
                // src1=rs_val(lhs), src2=rt_val(rhs), rd_val=rd(target)
                next_pc = ($signed(src1) > $signed(src2)) ? rd_val : pc + 4;
                reg_write = 0;
            end
            // --- Data movement ---
            5'h11: begin result = src1;              reg_write = 1; end  // mov rd, rs
            5'h12: begin                                                  // movl rd, L (sets bits [63:52])
                result = {src1[63:12], L};
                reg_write = 1;
            end
            // --- Integer arithmetic ---
            5'h18: begin result = src1 + src2;       reg_write = 1; end  // add
            5'h19: begin result = src1 + {52'b0,L};  reg_write = 1; end  // addi (src1=rd)
            5'h1a: begin result = src1 - src2;       reg_write = 1; end  // sub
            5'h1b: begin result = src1 - {52'b0,L};  reg_write = 1; end  // subi (src1=rd)
            5'h1c: begin result = src1 * src2;       reg_write = 1; end  // mul
            5'h1d: begin                                                  // div
                result = (src2 != 0) ? ($signed(src1) / $signed(src2)) : 64'b0;
                reg_write = 1;
            end
            default: begin end
        endcase
    end
endmodule
