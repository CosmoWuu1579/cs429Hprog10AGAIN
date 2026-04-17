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
    assign rename0_s_val    = phys_regs[rat_map[rename0_s]];
    assign rename0_t_val    = phys_regs[rat_map[rename0_t]];
    assign rename0_s_rdy    = phys_rdy[rat_map[rename0_s]];
    assign rename0_t_rdy    = phys_rdy[rat_map[rename0_t]];
    // Extra: current value of dest arch reg (before rename) — for brgt rd_val
    assign rename0_old_val  = phys_regs[rat_map[rename0_d]];
    assign rename0_old_rdy  = phys_rdy [rat_map[rename0_d]];

    assign rename1_new_preg = free1_idx;
    assign rename1_old_preg = (rename0_en && rename1_d == rename0_d) ? free0_idx : rat_map[rename1_d];
    assign rename1_s_preg   = rat1_s;
    assign rename1_t_preg   = rat1_t;
    assign rename1_s_val    = phys_regs[rat1_s];
    assign rename1_t_val    = phys_regs[rat1_t];
    assign rename1_s_rdy    = phys_rdy[rat1_s];
    assign rename1_t_rdy    = phys_rdy[rat1_t];
    assign rename1_old_val  = phys_regs[rat_map[rename1_d]];
    assign rename1_old_rdy  = phys_rdy [rat_map[rename1_d]];

    always @(posedge clk) begin
        if (reset) begin
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
            end
            if (cdb1_valid) begin
                phys_regs[cdb1_preg] <= cdb1_data;
                phys_rdy[cdb1_preg]  <= 1;
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
