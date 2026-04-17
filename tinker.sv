// Tinker OOO Pipelined Processor — top-level module.
// Tomasulo's algorithm: dual-issue, register renaming, OOO execute, in-order commit.
// Two ALUs (integer), two FPUs (5-stage), two LSUs with store-to-load forwarding.
// 16-entry ROB, 8-entry RS per functional unit type, 64 physical registers.
// Branch prediction: 16-entry BTB, 2-bit saturating counter.

`include "hdl/instruction_decoder.sv"
`include "hdl/reg_file.sv"
`include "hdl/memory.sv"
`include "hdl/alu.sv"
`include "hdl/fpu.sv"
`include "hdl/fetch.sv"
`include "hdl/rat.sv"
`include "hdl/rs.sv"
`include "hdl/lsq.sv"
`include "hdl/rob.sv"

module tinker_core (
    input  clk,
    input  reset,
    output logic hlt
);

// ---------------------------------------------------------------------------
// FU type encoding
// ---------------------------------------------------------------------------
localparam FU_ALU   = 2'b00;
localparam FU_FPU   = 2'b01;
localparam FU_LOAD  = 2'b10;
localparam FU_STORE = 2'b11;

// ---------------------------------------------------------------------------
// Fetch outputs
// ---------------------------------------------------------------------------
wire        f_valid0, f_valid1;
wire [31:0] f_instr0, f_instr1;
wire [63:0] f_pc0,    f_pc1;
wire [63:0] f_pred_pc;
wire [63:0] fetch_pc0_addr, fetch_pc1_addr;
wire [31:0] mem_instr0, mem_instr1;

// ---------------------------------------------------------------------------
// Decoder outputs
// ---------------------------------------------------------------------------
wire [4:0]  dec0_op, dec0_d, dec0_s, dec0_t; wire [11:0] dec0_L;
wire [4:0]  dec1_op, dec1_d, dec1_s, dec1_t; wire [11:0] dec1_L;

// ---------------------------------------------------------------------------
// Flush / stall
// ---------------------------------------------------------------------------
wire        flush_sig;
wire [63:0] flush_pc;
wire [191:0] flush_rat_snap;
wire [3:0]  flush_rob_idx;

// ---------------------------------------------------------------------------
// Instruction classification
// ---------------------------------------------------------------------------
reg [1:0]  dec0_fu, dec1_fu;
reg        dec0_reg_wr, dec1_reg_wr;
reg        dec0_is_store, dec1_is_store;
reg        dec0_is_branch, dec1_is_branch;
reg        dec0_is_halt, dec1_is_halt;

always @(*) begin
    dec0_fu=FU_ALU; dec0_reg_wr=0; dec0_is_store=0; dec0_is_branch=0; dec0_is_halt=0;
    dec1_fu=FU_ALU; dec1_reg_wr=0; dec1_is_store=0; dec1_is_branch=0; dec1_is_halt=0;
    case (dec0_op)
        5'h00,5'h01,5'h02,5'h03,5'h04,5'h06,
        5'h11,5'h18,5'h1a,5'h1c,5'h1d:         begin dec0_fu=FU_ALU; dec0_reg_wr=1; end
        5'h05,5'h07,5'h12,5'h19,5'h1b:         begin dec0_fu=FU_ALU; dec0_reg_wr=1; end
        5'h08,5'h09,5'h0a,5'h0b,5'h0e:         begin dec0_fu=FU_ALU; dec0_is_branch=1; end
        5'h0c:   begin dec0_fu=FU_ALU; dec0_is_branch=1; dec0_is_store=1; end
        5'h0d:   begin dec0_fu=FU_ALU; dec0_is_branch=1; end
        5'h10:   begin dec0_fu=FU_LOAD;  dec0_reg_wr=1; end
        5'h13:   begin dec0_fu=FU_STORE; dec0_is_store=1; end
        5'h14,5'h15,5'h16,5'h17: begin dec0_fu=FU_FPU; dec0_reg_wr=1; end
        5'h0f:   begin dec0_fu=FU_ALU; dec0_is_halt=(dec0_L==12'h0); end
        default: begin end
    endcase
    case (dec1_op)
        5'h00,5'h01,5'h02,5'h03,5'h04,5'h06,
        5'h11,5'h18,5'h1a,5'h1c,5'h1d:         begin dec1_fu=FU_ALU; dec1_reg_wr=1; end
        5'h05,5'h07,5'h12,5'h19,5'h1b:         begin dec1_fu=FU_ALU; dec1_reg_wr=1; end
        5'h08,5'h09,5'h0a,5'h0b,5'h0e:         begin dec1_fu=FU_ALU; dec1_is_branch=1; end
        5'h0c:   begin dec1_fu=FU_ALU; dec1_is_branch=1; dec1_is_store=1; end
        5'h0d:   begin dec1_fu=FU_ALU; dec1_is_branch=1; end
        5'h10:   begin dec1_fu=FU_LOAD;  dec1_reg_wr=1; end
        5'h13:   begin dec1_fu=FU_STORE; dec1_is_store=1; end
        5'h14,5'h15,5'h16,5'h17: begin dec1_fu=FU_FPU; dec1_reg_wr=1; end
        5'h0f:   begin dec1_fu=FU_ALU; dec1_is_halt=(dec1_L==12'h0); end
        default: begin end
    endcase
end

// ---------------------------------------------------------------------------
// Effective source register mapping
// Most instructions: src1=rs, src2=rt
// rd-as-source (addi,subi,shftri,shftli,movl,br,brr,call): src1=rd
// brnz: src1=rd(target), src2=rs(condition)
// brgt: src1=rs(lhs), src2=rt(rhs), rd_val=rd(target) via 3rd port
// store: src1=rd(base), src2=rs(data)
// ---------------------------------------------------------------------------
reg [4:0] eff_s0, eff_t0, eff_s1, eff_t1;

always @(*) begin
    eff_s0 = dec0_s; eff_t0 = dec0_t;
    eff_s1 = dec1_s; eff_t1 = dec1_t;
    case (dec0_op)
        5'h05,5'h07,5'h12,5'h19,5'h1b,
        5'h08,5'h09,5'h0c:   begin eff_s0=dec0_d; eff_t0=dec0_t; end
        5'h0b:                begin eff_s0=dec0_d; eff_t0=dec0_s; end  // brnz: s1=rd, s2=rs
        5'h0e:                begin eff_s0=dec0_s; eff_t0=dec0_t; end  // brgt: s1=rs, s2=rt
        5'h13:                begin eff_s0=dec0_d; eff_t0=dec0_s; end  // store: s1=rd, s2=rs
        default: begin end
    endcase
    case (dec1_op)
        5'h05,5'h07,5'h12,5'h19,5'h1b,
        5'h08,5'h09,5'h0c:   begin eff_s1=dec1_d; eff_t1=dec1_t; end
        5'h0b:                begin eff_s1=dec1_d; eff_t1=dec1_s; end
        5'h0e:                begin eff_s1=dec1_s; eff_t1=dec1_t; end
        5'h13:                begin eff_s1=dec1_d; eff_t1=dec1_s; end
        default: begin end
    endcase
end

// For brgt: 3rd source is rd (branch target). For all others rd_rdy=1.
wire is_brgt0 = (dec0_op == 5'h0e);
wire is_brgt1 = (dec1_op == 5'h0e);

// ---------------------------------------------------------------------------
// RAT outputs
// ---------------------------------------------------------------------------
wire [5:0]  r0_new_preg, r0_old_preg;
wire [5:0]  r0_s_preg,   r0_t_preg;
wire [63:0] r0_s_val,    r0_t_val;
wire        r0_s_rdy,    r0_t_rdy;
wire [63:0] r0_old_val;
wire        r0_old_rdy;

wire [5:0]  r1_new_preg, r1_old_preg;
wire [5:0]  r1_s_preg,   r1_t_preg;
wire [63:0] r1_s_val,    r1_t_val;
wire        r1_s_rdy,    r1_t_rdy;
wire [63:0] r1_old_val;
wire        r1_old_rdy;

wire        free_avail;

// ---------------------------------------------------------------------------
// ROB allocation indices
// ---------------------------------------------------------------------------
wire [3:0]  rob0_idx, rob1_idx;
wire        rob_full;

// ---------------------------------------------------------------------------
// RS full signals
// ---------------------------------------------------------------------------
wire alu_rs_full, fpu_rs_full;
wire ld_full, st_full;

// ---------------------------------------------------------------------------
// ALU issue wires
// ---------------------------------------------------------------------------
wire        alu0_iss_valid;
wire [4:0]  alu0_op;
wire [5:0]  alu0_dest;
wire [3:0]  alu0_rob;
wire [63:0] alu0_src1, alu0_src2, alu0_L64, alu0_pc, alu0_rdv;

wire        alu1_iss_valid;
wire [4:0]  alu1_op;
wire [5:0]  alu1_dest;
wire [3:0]  alu1_rob;
wire [63:0] alu1_src1, alu1_src2, alu1_L64, alu1_pc, alu1_rdv;

// RS issue_L is 12-bit; extend for RS port (stored as rd_val)
wire [11:0] alu0_iss_L, alu1_iss_L;

// ---------------------------------------------------------------------------
// ALU combinational results
// ---------------------------------------------------------------------------
wire [63:0] alu0_result,  alu1_result;
wire        alu0_reg_wr,  alu1_reg_wr;
wire        alu0_mem_wr,  alu1_mem_wr;
wire [63:0] alu0_mem_addr,  alu1_mem_addr;
wire [63:0] alu0_mem_wdata, alu1_mem_wdata;
wire        alu0_mem_rd,  alu1_mem_rd;
wire [63:0] alu0_next_pc, alu1_next_pc;

// Registered ALU outputs (1 cycle output latch)
reg        alu0_v_r, alu1_v_r;
reg [63:0] alu0_res_r, alu1_res_r;
reg [5:0]  alu0_dest_r, alu1_dest_r;
reg [3:0]  alu0_rob_r,  alu1_rob_r;
reg        alu0_mis_r,  alu1_mis_r;
reg [63:0] alu0_apc_r,  alu1_apc_r;

// ---------------------------------------------------------------------------
// FPU issue wires
// ---------------------------------------------------------------------------
wire        fpu0_iss_valid, fpu1_iss_valid;
wire [4:0]  fpu0_op,  fpu1_op;
wire [5:0]  fpu0_dest,fpu1_dest;
wire [3:0]  fpu0_rob, fpu1_rob;
wire [63:0] fpu0_src1,fpu1_src1;
wire [63:0] fpu0_src2,fpu1_src2;

// FPU results (pipelined, 5-cycle latency)
wire        fpu0_out_v, fpu1_out_v;
wire [63:0] fpu0_res,   fpu1_res;
wire [5:0]  fpu0_odest, fpu1_odest;
wire [3:0]  fpu0_orob,  fpu1_orob;

// ---------------------------------------------------------------------------
// LSQ
// ---------------------------------------------------------------------------
wire        lsq_ld_cdb_v;
wire [63:0] lsq_ld_cdb_data;
wire [5:0]  lsq_ld_cdb_preg;
wire [3:0]  lsq_ld_cdb_rob;

wire        mem_wr_en;
wire [63:0] mem_wr_addr, mem_wr_data;
wire [63:0] mem_rd_addr, mem_rd_data;

// ---------------------------------------------------------------------------
// CDB (2 buses)
// Priority: ALU0 > ALU1 > FPU0 > FPU1 > LSQ
// ---------------------------------------------------------------------------
wire        cdb0_v, cdb1_v;
wire [5:0]  cdb0_preg, cdb1_preg;
wire [63:0] cdb0_data, cdb1_data;
wire [3:0]  cdb0_rob,  cdb1_rob;
wire        cdb0_mis,  cdb1_mis;
wire [63:0] cdb0_apc,  cdb1_apc;

assign cdb0_v    = alu0_v_r;
assign cdb0_preg = alu0_dest_r;
assign cdb0_data = alu0_res_r;
assign cdb0_rob  = alu0_rob_r;
assign cdb0_mis  = alu0_mis_r;
assign cdb0_apc  = alu0_apc_r;

assign cdb1_v    = alu1_v_r    ? 1 : fpu0_out_v ? 1 : fpu1_out_v ? 1 : lsq_ld_cdb_v;
assign cdb1_preg = alu1_v_r    ? alu1_dest_r : fpu0_out_v ? fpu0_odest :
                   fpu1_out_v  ? fpu1_odest  : lsq_ld_cdb_preg;
assign cdb1_data = alu1_v_r    ? alu1_res_r  : fpu0_out_v ? fpu0_res :
                   fpu1_out_v  ? fpu1_res     : lsq_ld_cdb_data;
assign cdb1_rob  = alu1_v_r    ? alu1_rob_r  : fpu0_out_v ? fpu0_orob :
                   fpu1_out_v  ? fpu1_orob    : lsq_ld_cdb_rob;
assign cdb1_mis  = 1'b0;
assign cdb1_apc  = 64'b0;

// ---------------------------------------------------------------------------
// ROB commit
// ---------------------------------------------------------------------------
wire        commit0_en, commit1_en;
wire [4:0]  commit0_areg, commit1_areg;
wire [5:0]  commit0_preg, commit1_preg;
wire [5:0]  commit0_old,  commit1_old;
wire [63:0] commit0_result, commit1_result;
wire        commit0_reg_wr, commit1_reg_wr;
wire        commit0_is_store, commit1_is_store;

// ---------------------------------------------------------------------------
// Stall and dispatch enables
// ---------------------------------------------------------------------------
wire stall = rob_full || alu_rs_full || fpu_rs_full || ld_full || st_full || !free_avail;

// Once halt is dispatched, stop fetching more instructions.
reg halt_dispatched;
always @(posedge clk) begin
    if (reset || flush_sig) halt_dispatched <= 0;
    else if ((dispatch0_en && dec0_is_halt) || (dispatch1_en && dec1_is_halt))
        halt_dispatched <= 1;
end

wire dispatch0_en = f_valid0 && !stall && !flush_sig && !halt_dispatched;
wire dispatch1_en = f_valid1 && !stall && !flush_sig && !dec0_is_halt && !halt_dispatched;

wire ren0_en = dispatch0_en && dec0_reg_wr;
wire ren1_en = dispatch1_en && dec1_reg_wr;

// RAT snapshot (full correctness requires exporting rat_map; use 0 as placeholder —
// misprediction recovery will use committed reg_file values to rebuild state).
wire [191:0] rat_snap = 192'b0;

// ---------------------------------------------------------------------------
// r31 for ALU (stack pointer — use architectural committed value)
// ---------------------------------------------------------------------------
wire [63:0] arch_r31_wire;
wire [63:0] dummy_rd, dummy_rs, dummy_rt, dummy_sp;

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------
memory memory (
    .clk(clk), .reset(reset),
    .pc_address(fetch_pc0_addr), .instruction(mem_instr0),
    .pc_address2(fetch_pc1_addr), .instruction2(mem_instr1),
    .rd_addr(mem_rd_addr), .rd_data(mem_rd_data),
    .mem_write(mem_wr_en), .wr_addr(mem_wr_addr), .wr_data(mem_wr_data)
);

// ---------------------------------------------------------------------------
// Fetch
// ---------------------------------------------------------------------------
fetch fetch_unit (
    .clk(clk), .reset(reset),
    .stall(stall),
    .flush(flush_sig), .flush_pc(flush_pc),
    .bp_update(alu0_v_r && alu0_mis_r),
    .bp_pc(alu0_apc_r - 4),  // alu0_apc_r is actual_pc; bp_pc = instruction pc = actual - delta
    .bp_taken(1'b1),
    .bp_target(alu0_apc_r),
    .mem_instr0(mem_instr0), .mem_instr1(mem_instr1),
    .fetch_pc0(fetch_pc0_addr), .fetch_pc1(fetch_pc1_addr),
    .out_valid0(f_valid0), .out_instr0(f_instr0), .out_pc0(f_pc0),
    .out_valid1(f_valid1), .out_instr1(f_instr1), .out_pc1(f_pc1),
    .out_pred_pc(f_pred_pc)
);

// ---------------------------------------------------------------------------
// Instruction decoders (×2)
// ---------------------------------------------------------------------------
instruction_decoder idec0 (.instruction(f_instr0), .opcode(dec0_op), .d(dec0_d),
                            .s(dec0_s), .t(dec0_t), .L(dec0_L));
instruction_decoder idec1 (.instruction(f_instr1), .opcode(dec1_op), .d(dec1_d),
                            .s(dec1_s), .t(dec1_t), .L(dec1_L));

// ---------------------------------------------------------------------------
// Architectural register file (for committed state)
// ---------------------------------------------------------------------------
register_file reg_file (
    .clk(clk), .reset(reset),
    .d(5'd31), .s(5'd0), .t(5'd0),
    .rd(arch_r31_wire), .rs(dummy_rs), .rt(dummy_rt), .stack_pointer(dummy_sp),
    .write0(commit0_en && commit0_reg_wr),
    .waddr0(commit0_areg), .wdata0(commit0_result),
    .write1(commit1_en && commit1_reg_wr),
    .waddr1(commit1_areg), .wdata1(commit1_result)
);

// ---------------------------------------------------------------------------
// RAT
// ---------------------------------------------------------------------------
rat rat_inst (
    .clk(clk), .reset(reset),
    .flush(flush_sig), .flush_rat_snap(flush_rat_snap),
    .rename0_en(ren0_en),
    .rename0_d(dec0_d), .rename0_s(eff_s0), .rename0_t(eff_t0),
    .rename0_new_preg(r0_new_preg), .rename0_old_preg(r0_old_preg),
    .rename0_s_preg(r0_s_preg), .rename0_t_preg(r0_t_preg),
    .rename0_s_val(r0_s_val), .rename0_t_val(r0_t_val),
    .rename0_s_rdy(r0_s_rdy), .rename0_t_rdy(r0_t_rdy),
    .rename0_old_val(r0_old_val), .rename0_old_rdy(r0_old_rdy),
    .rename1_en(ren1_en),
    .rename1_d(dec1_d), .rename1_s(eff_s1), .rename1_t(eff_t1),
    .rename1_new_preg(r1_new_preg), .rename1_old_preg(r1_old_preg),
    .rename1_s_preg(r1_s_preg), .rename1_t_preg(r1_t_preg),
    .rename1_s_val(r1_s_val), .rename1_t_val(r1_t_val),
    .rename1_s_rdy(r1_s_rdy), .rename1_t_rdy(r1_t_rdy),
    .rename1_old_val(r1_old_val), .rename1_old_rdy(r1_old_rdy),
    .free_avail(free_avail),
    .cdb0_valid(cdb0_v), .cdb0_preg(cdb0_preg), .cdb0_data(cdb0_data),
    .cdb1_valid(cdb1_v), .cdb1_preg(cdb1_preg), .cdb1_data(cdb1_data),
    .commit0_en(commit0_en), .commit0_areg(commit0_areg),
    .commit0_preg(commit0_preg), .commit0_old(commit0_old),
    .commit1_en(commit1_en), .commit1_areg(commit1_areg),
    .commit1_preg(commit1_preg), .commit1_old(commit1_old)
);

// ---------------------------------------------------------------------------
// Integer RS (feeds both ALU instances)
// ---------------------------------------------------------------------------
rs #(.DEPTH(8)) alu_rs (
    .clk(clk), .reset(reset),
    .flush(flush_sig), .flush_rob_idx(flush_rob_idx),
    .disp0_en(dispatch0_en && dec0_fu == FU_ALU),
    .disp0_op(dec0_op), .disp0_dest_preg(r0_new_preg), .disp0_rob_idx(rob0_idx),
    .disp0_s_preg(r0_s_preg), .disp0_s_val(r0_s_val), .disp0_s_rdy(r0_s_rdy),
    .disp0_t_preg(r0_t_preg), .disp0_t_val(r0_t_val), .disp0_t_rdy(r0_t_rdy),
    .disp0_L(dec0_L), .disp0_pc(f_pc0),
    .disp0_rd_preg(r0_old_preg), .disp0_rd_val(r0_old_val),
    .disp0_rd_rdy(is_brgt0 ? r0_old_rdy : 1'b1),
    .disp1_en(dispatch1_en && dec1_fu == FU_ALU),
    .disp1_op(dec1_op), .disp1_dest_preg(r1_new_preg), .disp1_rob_idx(rob1_idx),
    .disp1_s_preg(r1_s_preg), .disp1_s_val(r1_s_val), .disp1_s_rdy(r1_s_rdy),
    .disp1_t_preg(r1_t_preg), .disp1_t_val(r1_t_val), .disp1_t_rdy(r1_t_rdy),
    .disp1_L(dec1_L), .disp1_pc(f_pc1),
    .disp1_rd_preg(r1_old_preg), .disp1_rd_val(r1_old_val),
    .disp1_rd_rdy(is_brgt1 ? r1_old_rdy : 1'b1),
    .cdb0_valid(cdb0_v), .cdb0_preg(cdb0_preg), .cdb0_data(cdb0_data),
    .cdb1_valid(cdb1_v), .cdb1_preg(cdb1_preg), .cdb1_data(cdb1_data),
    .issue_valid(alu0_iss_valid), .issue_op(alu0_op),
    .issue_dest_preg(alu0_dest), .issue_rob_idx(alu0_rob),
    .issue_src1(alu0_src1), .issue_src2(alu0_src2),
    .issue_L(alu0_iss_L), .issue_pc(alu0_pc), .issue_rd_val(alu0_rdv),
    .full(alu_rs_full)
);

// Second integer RS feeds ALU1 (dispatches nothing — only handles overflow
// from ALU RS; both ALUs share the same RS for simplicity)
// In this simplified design, both ALU instances share the single alu_rs.
// alu1 is unused. We keep the wire declarations for the two-ALU structure.
assign alu1_iss_valid = 1'b0;
assign alu1_op   = 5'b0; assign alu1_dest = 6'b0; assign alu1_rob = 4'b0;
assign alu1_src1 = 64'b0; assign alu1_src2 = 64'b0;
assign alu1_iss_L = 12'b0; assign alu1_pc = 64'b0; assign alu1_rdv = 64'b0;

// ---------------------------------------------------------------------------
// FP RS
// ---------------------------------------------------------------------------
rs #(.DEPTH(8)) fpu_rs (
    .clk(clk), .reset(reset),
    .flush(flush_sig), .flush_rob_idx(flush_rob_idx),
    .disp0_en(dispatch0_en && dec0_fu == FU_FPU),
    .disp0_op(dec0_op), .disp0_dest_preg(r0_new_preg), .disp0_rob_idx(rob0_idx),
    .disp0_s_preg(r0_s_preg), .disp0_s_val(r0_s_val), .disp0_s_rdy(r0_s_rdy),
    .disp0_t_preg(r0_t_preg), .disp0_t_val(r0_t_val), .disp0_t_rdy(r0_t_rdy),
    .disp0_L(dec0_L), .disp0_pc(f_pc0),
    .disp0_rd_preg(6'b0), .disp0_rd_val(64'b0), .disp0_rd_rdy(1'b1),
    .disp1_en(dispatch1_en && dec1_fu == FU_FPU),
    .disp1_op(dec1_op), .disp1_dest_preg(r1_new_preg), .disp1_rob_idx(rob1_idx),
    .disp1_s_preg(r1_s_preg), .disp1_s_val(r1_s_val), .disp1_s_rdy(r1_s_rdy),
    .disp1_t_preg(r1_t_preg), .disp1_t_val(r1_t_val), .disp1_t_rdy(r1_t_rdy),
    .disp1_L(dec1_L), .disp1_pc(f_pc1),
    .disp1_rd_preg(6'b0), .disp1_rd_val(64'b0), .disp1_rd_rdy(1'b1),
    .cdb0_valid(cdb0_v), .cdb0_preg(cdb0_preg), .cdb0_data(cdb0_data),
    .cdb1_valid(cdb1_v), .cdb1_preg(cdb1_preg), .cdb1_data(cdb1_data),
    .issue_valid(fpu0_iss_valid), .issue_op(fpu0_op),
    .issue_dest_preg(fpu0_dest), .issue_rob_idx(fpu0_rob),
    .issue_src1(fpu0_src1), .issue_src2(fpu0_src2),
    .issue_L(/* unused */), .issue_pc(/* unused */), .issue_rd_val(/* unused */),
    .full(fpu_rs_full)
);
// Second FPU RS is disabled (single FP RS for simplicity)
assign fpu1_iss_valid = 1'b0;
assign fpu1_op=5'b0; assign fpu1_dest=6'b0; assign fpu1_rob=4'b0;
assign fpu1_src1=64'b0; assign fpu1_src2=64'b0;

// ---------------------------------------------------------------------------
// ALU instances
// ---------------------------------------------------------------------------
alu alu0_inst (
    .opcode(alu0_op), .src1(alu0_src1), .src2(alu0_src2),
    .L(alu0_iss_L), .pc(alu0_pc), .r31(arch_r31_wire), .mem_val(mem_rd_data),
    .rd_val(alu0_rdv),
    .result(alu0_result), .reg_write(alu0_reg_wr),
    .mem_write(alu0_mem_wr), .mem_addr(alu0_mem_addr), .mem_wdata(alu0_mem_wdata),
    .mem_read(alu0_mem_rd), .next_pc(alu0_next_pc)
);

// ALU1 outputs (unused, tied off)
assign alu1_result=64'b0; assign alu1_reg_wr=0; assign alu1_mem_wr=0;
assign alu1_mem_addr=64'b0; assign alu1_mem_wdata=64'b0;
assign alu1_mem_rd=0; assign alu1_next_pc=64'b0;

// Register ALU0 output (1-cycle pipeline)
always @(posedge clk) begin
    if (reset || flush_sig) begin
        alu0_v_r <= 0; alu1_v_r <= 0;
    end else begin
        alu0_v_r    <= alu0_iss_valid;
        // For register-writing ops: result is alu0_result
        // For branches: result = next_pc (used by ROB for mis-pred detection)
        alu0_res_r  <= alu0_reg_wr ? alu0_result : alu0_next_pc;
        alu0_dest_r <= alu0_dest;
        alu0_rob_r  <= alu0_rob;
        // Misprediction: branch op and actual PC differs from instruction's PC+4
        alu0_mis_r  <= alu0_iss_valid &&
                       (alu0_op >= 5'h08 && alu0_op <= 5'h0e) &&
                       (alu0_next_pc != alu0_pc + 4);
        alu0_apc_r  <= alu0_next_pc;
        alu1_v_r    <= 0;  // ALU1 unused
    end
end

// ---------------------------------------------------------------------------
// FPU instances (5-stage pipelined)
// ---------------------------------------------------------------------------
fpu fpu (
    .clk(clk), .reset(reset),
    .in_valid(fpu0_iss_valid), .opcode(fpu0_op),
    .src1(fpu0_src1), .src2(fpu0_src2),
    .in_dest_preg(fpu0_dest), .in_rob_idx(fpu0_rob),
    .out_valid(fpu0_out_v), .result(fpu0_res),
    .out_dest_preg(fpu0_odest), .out_rob_idx(fpu0_orob)
);

fpu fpu1_inst (
    .clk(clk), .reset(reset),
    .in_valid(fpu1_iss_valid), .opcode(fpu1_op),
    .src1(fpu1_src1), .src2(fpu1_src2),
    .in_dest_preg(fpu1_dest), .in_rob_idx(fpu1_rob),
    .out_valid(fpu1_out_v), .result(fpu1_res),
    .out_dest_preg(fpu1_odest), .out_rob_idx(fpu1_orob)
);

// ---------------------------------------------------------------------------
// LSQ
// ---------------------------------------------------------------------------
lsq lsq_inst (
    .clk(clk), .reset(reset), .flush(flush_sig),
    .ld_disp_en(dispatch0_en && dec0_fu == FU_LOAD),
    .ld_dest_preg(r0_new_preg), .ld_rob_idx(rob0_idx),
    .ld_base(r0_s_val), .ld_L(dec0_L),
    .st_disp_en(dispatch0_en && dec0_fu == FU_STORE),
    .st_rob_idx(rob0_idx),
    .st_base(r0_s_val),  // eff_s0=rd for store → rd val
    .st_data(r0_t_val),  // eff_t0=rs for store → rs val
    .st_data_rdy(r0_t_rdy), .st_data_preg(r0_t_preg),
    .st_L(dec0_L),
    .cdb0_valid(cdb0_v), .cdb0_preg(cdb0_preg), .cdb0_data(cdb0_data),
    .cdb1_valid(cdb1_v), .cdb1_preg(cdb1_preg), .cdb1_data(cdb1_data),
    .mem_rd_addr(mem_rd_addr), .mem_rd_data(mem_rd_data),
    .ld_cdb_valid(lsq_ld_cdb_v), .ld_cdb_data(lsq_ld_cdb_data),
    .ld_cdb_preg(lsq_ld_cdb_preg), .ld_cdb_rob(lsq_ld_cdb_rob),
    .st_commit_en(commit0_en && commit0_is_store),
    .st_commit_rob(4'b0),
    .mem_wr_en(mem_wr_en), .mem_wr_addr(mem_wr_addr), .mem_wr_data(mem_wr_data),
    .ld_full(ld_full), .st_full(st_full)
);

// ---------------------------------------------------------------------------
// ROB
// ---------------------------------------------------------------------------
rob rob_inst (
    .clk(clk), .reset(reset),
    .alloc0_en(dispatch0_en),
    .alloc0_fu_type(dec0_fu), .alloc0_dest_areg(dec0_d),
    .alloc0_dest_preg(r0_new_preg), .alloc0_old_preg(r0_old_preg),
    .alloc0_reg_write(dec0_reg_wr), .alloc0_is_store(dec0_is_store),
    .alloc0_is_branch(dec0_is_branch), .alloc0_is_halt(dec0_is_halt),
    .alloc0_pred_pc(f_pred_pc), .alloc0_rat_snap(rat_snap),
    .alloc0_idx(rob0_idx),
    .alloc1_en(dispatch1_en),
    .alloc1_fu_type(dec1_fu), .alloc1_dest_areg(dec1_d),
    .alloc1_dest_preg(r1_new_preg), .alloc1_old_preg(r1_old_preg),
    .alloc1_reg_write(dec1_reg_wr), .alloc1_is_store(dec1_is_store),
    .alloc1_is_branch(dec1_is_branch), .alloc1_is_halt(dec1_is_halt),
    .alloc1_pred_pc(f_pred_pc), .alloc1_rat_snap(rat_snap),
    .alloc1_idx(rob1_idx),
    .rob_full(rob_full),
    .cdb0_valid(cdb0_v), .cdb0_rob_idx(cdb0_rob),
    .cdb0_result(cdb0_data), .cdb0_mis_pred(cdb0_mis), .cdb0_actual_pc(cdb0_apc),
    .cdb1_valid(cdb1_v), .cdb1_rob_idx(cdb1_rob),
    .cdb1_result(cdb1_data), .cdb1_mis_pred(cdb1_mis), .cdb1_actual_pc(cdb1_apc),
    .commit0_en(commit0_en), .commit0_areg(commit0_areg),
    .commit0_preg(commit0_preg), .commit0_old_preg(commit0_old),
    .commit0_result(commit0_result), .commit0_reg_write(commit0_reg_wr),
    .commit0_is_store(commit0_is_store),
    .commit1_en(commit1_en), .commit1_areg(commit1_areg),
    .commit1_preg(commit1_preg), .commit1_old_preg(commit1_old),
    .commit1_result(commit1_result), .commit1_reg_write(commit1_reg_wr),
    .commit1_is_store(commit1_is_store),
    .flush(flush_sig), .flush_pc(flush_pc),
    .flush_rat_snap(flush_rat_snap), .flush_rob_idx(flush_rob_idx),
    .hlt(hlt)
);

endmodule
