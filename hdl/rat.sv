// Register Alias Table + Free List + Physical Register File
// 32 architectural registers mapped to 64 physical registers (6-bit index).
// Physical regs 0-31 are "identity" mapped at reset (arch[i] → phys[i]).
// Free list is a 64-bit bitmask (1 = free).  At reset phys 32-63 are free.
//
// Dual-issue: up to 2 renames per cycle (rename0 before rename1 in program order).
// Dual-commit: up to 2 arch writes per cycle, freeing the old physical regs.
//
// Read ports: 4 (for rs/rt of two instructions) → returns phys reg index + value + ready.
// Write ports: 2 (for dual-issue rename) and 2 (for dual-commit free).

module rat (
    input  clk,
    input  reset,
    input wire [63:0] reg_array_out_0,
    input wire [63:0] reg_array_out_1,
    input wire [63:0] reg_array_out_2,
    input wire [63:0] reg_array_out_3,
    input wire [63:0] reg_array_out_4,
    input wire [63:0] reg_array_out_5,
    input wire [63:0] reg_array_out_6,
    input wire [63:0] reg_array_out_7,
    input wire [63:0] reg_array_out_8,
    input wire [63:0] reg_array_out_9,
    input wire [63:0] reg_array_out_10,
    input wire [63:0] reg_array_out_11,
    input wire [63:0] reg_array_out_12,
    input wire [63:0] reg_array_out_13,
    input wire [63:0] reg_array_out_14,
    input wire [63:0] reg_array_out_15,
    input wire [63:0] reg_array_out_16,
    input wire [63:0] reg_array_out_17,
    input wire [63:0] reg_array_out_18,
    input wire [63:0] reg_array_out_19,
    input wire [63:0] reg_array_out_20,
    input wire [63:0] reg_array_out_21,
    input wire [63:0] reg_array_out_22,
    input wire [63:0] reg_array_out_23,
    input wire [63:0] reg_array_out_24,
    input wire [63:0] reg_array_out_25,
    input wire [63:0] reg_array_out_26,
    input wire [63:0] reg_array_out_27,
    input wire [63:0] reg_array_out_28,
    input wire [63:0] reg_array_out_29,
    input wire [63:0] reg_array_out_30,
    input wire [63:0] reg_array_out_31,

    // Flush (branch misprediction): restore RAT from snapshot
    input  wire        flush,
    input  wire [191:0] flush_rat_snap, // 32 × 6-bit snapshot

    // Rename port 0 (first instruction in program order)
    input  wire        rename0_en,
    input  wire [4:0]  rename0_d,          // destination arch reg
    input  wire [4:0]  rename0_s,          // source arch reg 1
    input  wire [4:0]  rename0_t,          // source arch reg 2
    output wire [5:0]  rename0_new_preg,   // allocated physical reg for dest
    output wire [5:0]  rename0_old_preg,   // old physical reg (to free at commit)
    output wire [5:0]  rename0_s_preg,
    output wire [5:0]  rename0_t_preg,
    output wire [63:0] rename0_s_val,
    output wire [63:0] rename0_t_val,
    output wire        rename0_s_rdy,
    output wire        rename0_t_rdy,
    // Value of dest arch reg BEFORE rename (for brgt rd_val)
    output wire [63:0] rename0_old_val,
    output wire        rename0_old_rdy,

    // Rename port 1 (second instruction, sees rename0's write)
    input  wire        rename1_en,
    input  wire [4:0]  rename1_d,
    input  wire [4:0]  rename1_s,
    input  wire [4:0]  rename1_t,
    output wire [5:0]  rename1_new_preg,
    output wire [5:0]  rename1_old_preg,
    output wire [5:0]  rename1_s_preg,
    output wire [5:0]  rename1_t_preg,
    output wire [63:0] rename1_s_val,
    output wire [63:0] rename1_t_val,
    output wire        rename1_s_rdy,
    output wire        rename1_t_rdy,
    output wire [63:0] rename1_old_val,
    output wire        rename1_old_rdy,

    // Free list status (stall if < 2 free regs)
    output wire        free_avail,    // 1 if at least 2 physical regs are free

    // CDB write (update physical reg file, mark ready)
    input  wire        cdb0_valid,
    input  wire [5:0]  cdb0_preg,
    input  wire [63:0] cdb0_data,
    input  wire        cdb1_valid,
    input  wire [5:0]  cdb1_preg,
    input  wire [63:0] cdb1_data,

    // Commit port: free old physical regs, update arch→phys map
    input  wire        commit0_en,
    input  wire [4:0]  commit0_areg,
    input  wire [5:0]  commit0_preg,   // new physical reg becoming "committed"
    input  wire [5:0]  commit0_old,    // old physical reg to free
    input  wire        commit1_en,
    input  wire [4:0]  commit1_areg,
    input  wire [5:0]  commit1_preg,
    input  wire [5:0]  commit1_old,
    output wire [191:0] rat_map_out
);
    localparam NPHYS = 64;

    reg [63:0] recovered_free_list;
    // RAT: arch → phys mapping (current speculative state)
    reg [5:0]  rat_map [0:31];
    // Physical register file
    reg [63:0] phys_regs [0:NPHYS-1];
    reg        phys_rdy  [0:NPHYS-1]; // 1 = result available
    // Free list bitmask
    reg [63:0] free_list;

    integer i;

    // Find lowest free bit in free_list (combinational)
    reg [5:0]  free0_idx;  // first free phys reg
    reg [5:0]  free1_idx;  // second free phys reg
    reg        found0, found1;



    always @(*) begin
        free0_idx = 6'd63; free1_idx = 6'd63;
        found0 = 0; found1 = 0;
        for (i = 0; i < NPHYS; i = i + 1) begin
            if (!found0) begin
                if (free_list[i]) begin free0_idx = i[5:0]; found0 = 1; end
            end else if (!found1) begin
                if (free_list[i]) begin free1_idx = i[5:0]; found1 = 1; end
            end
        end
    end

    assign free_avail = found0 && found1;

    // Forwarding: rename1 sees rename0's write if same arch reg
    wire [5:0] rat_s0  = rat_map[rename0_s];
    wire [5:0] rat_t0  = rat_map[rename0_t];
    wire [5:0] rat_d0  = (rename0_en && (rename0_s == rename0_d)) ? free0_idx : rat_map[rename0_s];
    // For rename1: if rename0 wrote the same arch reg, use free0_idx
    wire [5:0] rat1_s  = (rename0_en && rename1_s == rename0_d) ? free0_idx : rat_map[rename1_s];
    wire [5:0] rat1_t  = (rename0_en && rename1_t == rename0_d) ? free0_idx : rat_map[rename1_t];

    assign rename0_new_preg = free0_idx;
    assign rename0_old_preg = rat_map[rename0_d];
    assign rename0_s_preg   = rat_map[rename0_s];
    assign rename0_t_preg   = rat_map[rename0_t];
    // assign rename0_s_val    = phys_regs[rat_map[rename0_s]];
    // assign rename0_t_val    = phys_regs[rat_map[rename0_t]];
    assign rename0_s_rdy    = phys_rdy[rat_map[rename0_s]];
    assign rename0_t_rdy    = phys_rdy[rat_map[rename0_t]];
    // Extra: current value of dest arch reg (before rename) — for brgt rd_val
    // assign rename0_old_val  = phys_regs[rat_map[rename0_d]];
    assign rename0_old_rdy  = phys_rdy [rat_map[rename0_d]];

    assign rename1_new_preg = free1_idx;
    assign rename1_old_preg = (rename0_en && rename1_d == rename0_d) ? free0_idx : rat_map[rename1_d];
    assign rename1_s_preg   = rat1_s;
    assign rename1_t_preg   = rat1_t;
    // assign rename1_s_val    = phys_regs[rat1_s];
    // assign rename1_t_val    = phys_regs[rat1_t];
    assign rename1_s_rdy    = phys_rdy[rat1_s];
    assign rename1_t_rdy    = phys_rdy[rat1_t];
    // assign rename1_old_val  = phys_regs[rat_map[rename1_d]];
    assign rename1_old_rdy  = phys_rdy [rat_map[rename1_d]];

    
    // Add this declaration above your always block
    reg [31:0] is_initial;
    // Replace your current value assignments with these:
    wire [5:0] s0_idx = rat_map[rename0_s];
    wire [5:0] t0_idx = rat_map[rename0_t];
    wire [5:0] d0_idx = rat_map[rename0_d];

    // Bundle the individual ports back into an indexable internal array
    wire [63:0] arch_regs_in [0:31];
    assign arch_regs_in[0] = reg_array_out_0;
    assign arch_regs_in[1] = reg_array_out_1;
    assign arch_regs_in[2] = reg_array_out_2;
    assign arch_regs_in[3] = reg_array_out_3;
    assign arch_regs_in[4] = reg_array_out_4;
    assign arch_regs_in[5] = reg_array_out_5;
    assign arch_regs_in[6] = reg_array_out_6;
    assign arch_regs_in[7] = reg_array_out_7;
    assign arch_regs_in[8] = reg_array_out_8;
    assign arch_regs_in[9] = reg_array_out_9;
    assign arch_regs_in[10] = reg_array_out_10;
    assign arch_regs_in[11] = reg_array_out_11;
    assign arch_regs_in[12] = reg_array_out_12;
    assign arch_regs_in[13] = reg_array_out_13;
    assign arch_regs_in[14] = reg_array_out_14;
    assign arch_regs_in[15] = reg_array_out_15;
    assign arch_regs_in[16] = reg_array_out_16;
    assign arch_regs_in[17] = reg_array_out_17;
    assign arch_regs_in[18] = reg_array_out_18;
    assign arch_regs_in[19] = reg_array_out_19;
    assign arch_regs_in[20] = reg_array_out_20;
    assign arch_regs_in[21] = reg_array_out_21;
    assign arch_regs_in[22] = reg_array_out_22;
    assign arch_regs_in[23] = reg_array_out_23;
    assign arch_regs_in[24] = reg_array_out_24;
    assign arch_regs_in[25] = reg_array_out_25;
    assign arch_regs_in[26] = reg_array_out_26;
    assign arch_regs_in[27] = reg_array_out_27;
    assign arch_regs_in[28] = reg_array_out_28;
    assign arch_regs_in[29] = reg_array_out_29;
    assign arch_regs_in[30] = reg_array_out_30;
    assign arch_regs_in[31] = reg_array_out_31;
    
    assign rename0_s_val   = (s0_idx < 32 && is_initial[s0_idx[4:0]]) ? arch_regs_in[s0_idx[4:0]] : phys_regs[s0_idx];
    assign rename0_t_val   = (t0_idx < 32 && is_initial[t0_idx[4:0]]) ? arch_regs_in[t0_idx[4:0]] : phys_regs[t0_idx];
    assign rename0_old_val = (d0_idx < 32 && is_initial[d0_idx[4:0]]) ? arch_regs_in[d0_idx[4:0]] : phys_regs[d0_idx];

    wire [5:0] s1_idx = rat1_s;
    wire [5:0] t1_idx = rat1_t;
    wire [5:0] d1_idx = rat_map[rename1_d];

    assign rename1_s_val   = (s1_idx < 32 && is_initial[s1_idx[4:0]]) ? arch_regs_in[s1_idx[4:0]] : phys_regs[s1_idx];
    assign rename1_t_val   = (t1_idx < 32 && is_initial[t1_idx[4:0]]) ? arch_regs_in[t1_idx[4:0]] : phys_regs[t1_idx];
    assign rename1_old_val = (d1_idx < 32 && is_initial[d1_idx[4:0]]) ? arch_regs_in[d1_idx[4:0]] : phys_regs[d1_idx];
    always @(posedge clk) begin
        if (reset) begin
            is_initial <= 32'hFFFF_FFFF; // <--- ADD THIS (all start as initial)

            // Identity mapping: arch[i] → phys[i], regs 0-31 ready with 0 / MEM_SIZE
            for (i = 0; i < 32; i = i + 1) begin
                rat_map[i]   <= i[5:0];
                phys_regs[i] <= (i == 31) ? 64'd524288 : 64'b0;
                phys_rdy[i]  <= 1;
            end
            for (i = 32; i < NPHYS; i = i + 1) begin
                phys_regs[i] <= 64'b0;
                phys_rdy[i]  <= 0;
            end
            // phys 0-31 occupied, 32-63 free
            free_list <= 64'hFFFF_FFFF_0000_0000;
        end else if (flush) begin
            // // Restore RAT from snapshot; free list and phys file are updated
            // // by the ROB flushing allocated physical regs back to free list.
            // for (i = 0; i < 32; i = i + 1)
            //     rat_map[i] <= flush_rat_snap[i*6 +: 6];
            recovered_free_list = 64'hFFFF_FFFF_FFFF_FFFF;
            for (i = 0; i < 32; i = i + 1) begin
                rat_map[i] <= flush_rat_snap[i*6 +: 6];
                recovered_free_list[flush_rat_snap[i*6 +: 6]] = 1'b0;
            end
            free_list <= recovered_free_list;
        end else begin
            // CDB writes (update phys file, mark ready)
            if (cdb0_valid) begin
                phys_regs[cdb0_preg] <= cdb0_data;
                phys_rdy[cdb0_preg]  <= 1;
                if (cdb0_preg < 32) is_initial[cdb0_preg[4:0]] <= 0; // <--- ADD THIS
            end
            if (cdb1_valid) begin
                phys_regs[cdb1_preg] <= cdb1_data;
                phys_rdy[cdb1_preg]  <= 1;
                if (cdb1_preg < 32) is_initial[cdb1_preg[4:0]] <= 0; // <--- ADD THIS
            end

            // Commit: make old phys reg free, no RAT change needed
            // (RAT already has committed mapping; it was set at rename time)
            if (commit0_en) begin
                free_list[commit0_old] <= 1;
            end
            if (commit1_en) begin
                free_list[commit1_old] <= 1;
            end

            // Rename (allocate new phys regs, update RAT)
            if (rename0_en) begin
                rat_map[rename0_d]     <= free0_idx;
                free_list[free0_idx]   <= 0;
                phys_rdy[free0_idx]    <= 0;
            end
            if (rename1_en) begin
                rat_map[rename1_d]     <= free1_idx;
                free_list[free1_idx]   <= 0;
                phys_rdy[free1_idx]    <= 0;
            end
        end
    end


    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : gen_rat_snap
            assign rat_map_out[g*6 +: 6] = rat_map[g];
        end
    endgenerate
endmodule
