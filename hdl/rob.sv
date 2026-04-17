// Reorder Buffer — 16 entry circular queue.
// Entries are allocated in-order at dispatch; retired in-order at commit.
// Dual-issue: up to 2 entries allocated per cycle, up to 2 committed per cycle.
// Branch misprediction: detected at commit; triggers flush + RAT restore.
// Halt: asserted when halt instruction reaches ROB head and is committed.

// fu_type encoding:
//   2'b00 = ALU (integer, branch, call, return, mov)
//   2'b01 = FPU
//   2'b10 = LOAD
//   2'b11 = STORE

module rob (
    input  clk,
    input  reset,

    // Allocation (dispatch) — in-order, up to 2/cycle
    input  wire        alloc0_en,
    input  wire [1:0]  alloc0_fu_type,
    input  wire [4:0]  alloc0_dest_areg,
    input  wire [5:0]  alloc0_dest_preg,
    input  wire [5:0]  alloc0_old_preg,
    input  wire        alloc0_reg_write,
    input  wire        alloc0_is_store,
    input  wire        alloc0_is_branch,
    input  wire        alloc0_is_halt,
    input  wire [63:0] alloc0_pred_pc,
    input  wire [191:0] alloc0_rat_snap,
    output wire [3:0]  alloc0_idx,

    input  wire        alloc1_en,
    input  wire [1:0]  alloc1_fu_type,
    input  wire [4:0]  alloc1_dest_areg,
    input  wire [5:0]  alloc1_dest_preg,
    input  wire [5:0]  alloc1_old_preg,
    input  wire        alloc1_reg_write,
    input  wire        alloc1_is_store,
    input  wire        alloc1_is_branch,
    input  wire        alloc1_is_halt,
    input  wire [63:0] alloc1_pred_pc,
    input  wire [191:0] alloc1_rat_snap,
    output wire [3:0]  alloc1_idx,

    // ROB full → stall dispatch
    output wire        rob_full,

    // CDB write-back: mark entries complete
    input  wire        cdb0_valid,
    input  wire [3:0]  cdb0_rob_idx,
    input  wire [63:0] cdb0_result,
    input  wire        cdb0_mis_pred,
    input  wire [63:0] cdb0_actual_pc,

    input  wire        cdb1_valid,
    input  wire [3:0]  cdb1_rob_idx,
    input  wire [63:0] cdb1_result,
    input  wire        cdb1_mis_pred,
    input  wire [63:0] cdb1_actual_pc,

    // Commit outputs (up to 2/cycle, in order)
    output reg         commit0_en,
    output reg  [4:0]  commit0_areg,
    output reg  [5:0]  commit0_preg,
    output reg  [5:0]  commit0_old_preg,
    output reg  [63:0] commit0_result,
    output reg         commit0_reg_write,
    output reg         commit0_is_store,

    output reg         commit1_en,
    output reg  [4:0]  commit1_areg,
    output reg  [5:0]  commit1_preg,
    output reg  [5:0]  commit1_old_preg,
    output reg  [63:0] commit1_result,
    output reg         commit1_reg_write,
    output reg         commit1_is_store,

    // Misprediction flush output
    output reg         flush,
    output reg  [63:0] flush_pc,
    output reg  [191:0] flush_rat_snap,
    output reg  [3:0]  flush_rob_idx,

    // Halt output
    output reg         hlt
);
    localparam ROB_SIZE = 16;

    // ROB entry fields
    reg        r_valid    [0:ROB_SIZE-1];
    reg        r_ready    [0:ROB_SIZE-1];
    reg [1:0]  r_fu_type  [0:ROB_SIZE-1];
    reg [4:0]  r_dareg    [0:ROB_SIZE-1];
    reg [5:0]  r_dpreg    [0:ROB_SIZE-1];
    reg [5:0]  r_old_preg [0:ROB_SIZE-1];
    reg        r_reg_write[0:ROB_SIZE-1];
    reg        r_is_store [0:ROB_SIZE-1];
    reg        r_is_branch[0:ROB_SIZE-1];
    reg        r_is_halt  [0:ROB_SIZE-1];
    reg [63:0] r_result   [0:ROB_SIZE-1];
    reg [63:0] r_pred_pc  [0:ROB_SIZE-1];
    reg        r_mis_pred [0:ROB_SIZE-1];
    reg [63:0] r_actual_pc[0:ROB_SIZE-1];
    reg [191:0] r_rat_snap[0:ROB_SIZE-1];

    reg [3:0]  head, tail;
    reg [4:0]  count; // 0..16

    assign alloc0_idx = tail;
    assign alloc1_idx = tail + 1;

    // Full when fewer than 2 free slots
    assign rob_full = (count >= ROB_SIZE - 1);

    integer i;

    always @(posedge clk) begin
        // Intermediate variables to track commit/alloc deltas (computed, not latched).
        reg [1:0] commit_cnt;
        reg [1:0] alloc_cnt;
        reg       do_flush;

        if (reset) begin
            for (i = 0; i < ROB_SIZE; i = i + 1) begin
                r_valid[i] <= 0; r_ready[i] <= 0;
            end
            head <= 0; tail <= 0; count <= 0;
            commit0_en <= 0; commit1_en <= 0;
            flush <= 0; hlt <= 0;
        end else begin
            flush      <= 0;
            commit0_en <= 0;
            commit1_en <= 0;
            commit_cnt  = 0;
            alloc_cnt   = 0;
            do_flush    = 0;

            // ------- CDB write-back: mark entries complete -------
            if (cdb0_valid) begin
                r_ready    [cdb0_rob_idx] <= 1;
                r_result   [cdb0_rob_idx] <= cdb0_result;
                r_mis_pred [cdb0_rob_idx] <= cdb0_mis_pred;
                r_actual_pc[cdb0_rob_idx] <= cdb0_actual_pc;
            end
            if (cdb1_valid) begin
                r_ready    [cdb1_rob_idx] <= 1;
                r_result   [cdb1_rob_idx] <= cdb1_result;
                r_mis_pred [cdb1_rob_idx] <= cdb1_mis_pred;
                r_actual_pc[cdb1_rob_idx] <= cdb1_actual_pc;
            end

            // ------- Commit up to 2 instructions from head -------
            if (r_valid[head] && r_ready[head]) begin
                // Commit entry 0
                commit0_en       <= 1;
                commit0_areg     <= r_dareg    [head];
                commit0_preg     <= r_dpreg    [head];
                commit0_old_preg <= r_old_preg [head];
                commit0_result   <= r_result   [head];
                commit0_reg_write <= r_reg_write[head];
                commit0_is_store <= r_is_store [head];
                r_valid[head]    <= 0;
                commit_cnt        = 1;

                if (r_is_halt[head]) begin
                    hlt       <= 1;
                    do_flush   = 0;
                end else if (r_is_branch[head] && r_mis_pred[head]) begin
                    flush          <= 1;
                    flush_pc       <= r_actual_pc[head];
                    flush_rat_snap <= r_rat_snap [head];
                    flush_rob_idx  <= head;
                    do_flush        = 1;
                    for (i = 0; i < ROB_SIZE; i = i + 1)
                        r_valid[i] <= 0;
                end else begin
                    // Try to commit second instruction
                    if (r_valid[head+1] && r_ready[head+1] && !r_is_halt[head+1]) begin
                        commit1_en       <= 1;
                        commit1_areg     <= r_dareg    [head+1];
                        commit1_preg     <= r_dpreg    [head+1];
                        commit1_old_preg <= r_old_preg [head+1];
                        commit1_result   <= r_result   [head+1];
                        commit1_reg_write <= r_reg_write[head+1];
                        commit1_is_store <= r_is_store [head+1];
                        r_valid[head+1]  <= 0;
                        commit_cnt        = 2;

                        if (r_is_branch[head+1] && r_mis_pred[head+1]) begin
                            flush          <= 1;
                            flush_pc       <= r_actual_pc[head+1];
                            flush_rat_snap <= r_rat_snap [head+1];
                            flush_rob_idx  <= head + 1;
                            do_flush        = 1;
                            for (i = 0; i < ROB_SIZE; i = i + 1)
                                r_valid[i] <= 0;
                        end
                    end
                end
            end

            // ------- Allocate new entries -------
            if (!do_flush) begin
                if (alloc0_en) begin
                    r_valid    [tail]   <= 1;
                    r_ready    [tail]   <= 0;
                    r_fu_type  [tail]   <= alloc0_fu_type;
                    r_dareg    [tail]   <= alloc0_dest_areg;
                    r_dpreg    [tail]   <= alloc0_dest_preg;
                    r_old_preg [tail]   <= alloc0_old_preg;
                    r_reg_write[tail]   <= alloc0_reg_write;
                    r_is_store [tail]   <= alloc0_is_store;
                    r_is_branch[tail]   <= alloc0_is_branch;
                    r_is_halt  [tail]   <= alloc0_is_halt;
                    r_pred_pc  [tail]   <= alloc0_pred_pc;
                    r_mis_pred [tail]   <= 0;
                    r_rat_snap [tail]   <= alloc0_rat_snap;
                    alloc_cnt           = alloc_cnt + 1;
                end
                if (alloc1_en) begin
                    r_valid    [tail+1] <= 1;
                    r_ready    [tail+1] <= 0;
                    r_fu_type  [tail+1] <= alloc1_fu_type;
                    r_dareg    [tail+1] <= alloc1_dest_areg;
                    r_dpreg    [tail+1] <= alloc1_dest_preg;
                    r_old_preg [tail+1] <= alloc1_old_preg;
                    r_reg_write[tail+1] <= alloc1_reg_write;
                    r_is_store [tail+1] <= alloc1_is_store;
                    r_is_branch[tail+1] <= alloc1_is_branch;
                    r_is_halt  [tail+1] <= alloc1_is_halt;
                    r_pred_pc  [tail+1] <= alloc1_pred_pc;
                    r_mis_pred [tail+1] <= 0;
                    r_rat_snap [tail+1] <= alloc1_rat_snap;
                    alloc_cnt           = alloc_cnt + 1;
                end
                tail  <= tail + {2'b0, alloc_cnt};
            end else begin
                // Flush: reset to empty
                head <= 0; tail <= 0;
            end

            // Single combined count update (avoids double-write bug)
            if (do_flush) begin
                count <= 0;
            end else begin
                count <= count - {3'b0, commit_cnt} + {3'b0, alloc_cnt};
            end

            // Advance head by commit_cnt (single assignment)
            if (!do_flush) begin
                head <= head + {2'b0, commit_cnt};
            end
        end
    end
endmodule
