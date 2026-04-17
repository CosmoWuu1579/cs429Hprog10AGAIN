// Instruction fetch unit with 16-entry fetch buffer and BTB branch predictor.
// Fetches 2 instructions per cycle from memory and dispatches 2 to decode.
// Fill and dispatch are computed together to avoid fb_count conflicts.
module fetch (
    input  clk,
    input  reset,
    input  wire        stall,
    input  wire        flush,
    input  wire [63:0] flush_pc,
    // BTB update
    input  wire        bp_update,
    input  wire [63:0] bp_pc,
    input  wire        bp_taken,
    input  wire [63:0] bp_target,
    // Memory instruction fetch ports
    input  wire [31:0] mem_instr0,
    input  wire [31:0] mem_instr1,
    output reg  [63:0] fetch_pc0,
    output reg  [63:0] fetch_pc1,
    // Output to decode (up to 2 per cycle)
    output reg         out_valid0,
    output reg  [31:0] out_instr0,
    output reg  [63:0] out_pc0,
    output reg         out_valid1,
    output reg  [31:0] out_instr1,
    output reg  [63:0] out_pc1,
    output reg  [63:0] out_pred_pc
);
    localparam DEPTH = 16;

    reg [31:0] buf_instr [0:DEPTH-1];
    reg [63:0] buf_pc    [0:DEPTH-1];
    reg [3:0]  head;    // next entry to dispatch
    reg [3:0]  tail;    // next slot to fill
    reg [4:0]  count;   // number of valid entries

    reg [63:0] next_fetch_pc; // PC of next instruction to fetch

    // BTB
    reg        btb_v   [0:15];
    reg [63:0] btb_tag [0:15];
    reg [63:0] btb_tgt [0:15];
    reg [1:0]  btb_cnt [0:15];

    integer j;

    // Branch prediction: given a PC and instruction, return predicted next PC
    function [63:0] predict;
        input [63:0] pc;
        input [31:0] instr;
        reg [3:0]  idx;
        reg [4:0]  op;
        reg [11:0] L;
        begin
            op  = instr[31:27];
            L   = instr[11:0];
            idx = pc[5:2];
            if ((op == 5'h08 || op == 5'h09) &&
                btb_v[idx] && btb_tag[idx] == pc)
                predict = btb_tgt[idx];
            else if (op == 5'h0a)
                predict = pc + {{52{L[11]}}, L};
            else if ((op == 5'h0b || op == 5'h0e) &&
                     btb_v[idx] && btb_tag[idx] == pc && btb_cnt[idx][1])
                predict = btb_tgt[idx];
            else
                predict = pc + 4;
        end
    endfunction

    always @(posedge clk) begin
        // Combinational computation of how many we fill and dispatch this cycle
        reg [1:0] fill_cnt, disp_cnt;
        reg [4:0] new_count;

        if (reset) begin
            head <= 0; tail <= 0; count <= 0;
            next_fetch_pc <= 64'h2000;
            out_valid0 <= 0; out_valid1 <= 0;
            for (j = 0; j < 16; j = j + 1) btb_v[j] <= 0;
        end else begin
            // BTB update
            if (bp_update) begin
                btb_v   [bp_pc[5:2]] <= 1;
                btb_tag [bp_pc[5:2]] <= bp_pc;
                btb_tgt [bp_pc[5:2]] <= bp_target;
                if (bp_taken) begin
                    if (btb_cnt[bp_pc[5:2]] != 2'b11)
                        btb_cnt[bp_pc[5:2]] <= btb_cnt[bp_pc[5:2]] + 1;
                end else begin
                    if (btb_cnt[bp_pc[5:2]] != 2'b00)
                        btb_cnt[bp_pc[5:2]] <= btb_cnt[bp_pc[5:2]] - 1;
                end
            end

            if (flush) begin
                head <= 0; tail <= 0; count <= 0;
                next_fetch_pc <= flush_pc;
                out_valid0 <= 0; out_valid1 <= 0;
            end else begin
                // How many new instructions can we fill?
                fill_cnt = 0;
                if (!stall) begin
                    if (count <= DEPTH - 2) fill_cnt = 2;
                    else if (count <= DEPTH - 1) fill_cnt = 1;
                end

                // How many can we dispatch?
                disp_cnt = 0;
                if (!stall) begin
                    if (count >= 2) disp_cnt = 2;
                    else if (count == 1) disp_cnt = 1;
                end

                // Dispatch outputs
                out_valid0 <= 0; out_valid1 <= 0;
                if (disp_cnt >= 1) begin
                    out_valid0  <= 1;
                    out_instr0  <= buf_instr[head];
                    out_pc0     <= buf_pc[head];
                end
                if (disp_cnt == 2) begin
                    out_valid1  <= 1;
                    out_instr1  <= buf_instr[(head+1) & 4'hF];
                    out_pc1     <= buf_pc[(head+1) & 4'hF];
                    out_pred_pc <= predict(buf_pc[(head+1) & 4'hF],
                                          buf_instr[(head+1) & 4'hF]);
                end else if (disp_cnt == 1) begin
                    out_pred_pc <= predict(buf_pc[head], buf_instr[head]);
                end

                // Fill buffer at tail
                if (fill_cnt >= 1) begin
                    buf_instr[tail]             <= mem_instr0;
                    buf_pc   [tail]             <= next_fetch_pc;
                end
                if (fill_cnt == 2) begin
                    buf_instr[(tail+1) & 4'hF]  <= mem_instr1;
                    buf_pc   [(tail+1) & 4'hF]  <= next_fetch_pc + 4;
                end

                // Update pointers: combine fill and dispatch in one assignment
                head          <= (head + {3'b0, disp_cnt}) & 4'hF;
                tail          <= (tail + {3'b0, fill_cnt})  & 4'hF;
                count         <= count + {3'b0, fill_cnt} - {3'b0, disp_cnt};
                next_fetch_pc <= next_fetch_pc + {61'b0, fill_cnt, 2'b0}; // +4 or +8
            end
        end
    end

    // Drive memory fetch addresses combinationally
    always @(*) begin
        fetch_pc0 = next_fetch_pc;
        fetch_pc1 = next_fetch_pc + 4;
    end
endmodule
