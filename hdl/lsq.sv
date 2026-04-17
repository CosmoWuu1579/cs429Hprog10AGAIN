// Load/Store Queue
// Load queue:  4 entries — computes address, checks store queue for forwarding,
//              else reads from memory. Result broadcast on CDB.
// Store queue: 4 entries — holds {addr, data} until ROB commits, then writes memory.
//
// Store-to-load forwarding: when a load's address matches the youngest committed
// store in the store queue whose data is ready, forward instead of going to memory.

module lsq (
    input  clk,
    input  reset,
    input  wire flush,

    // Dispatch: load (op=0x10)
    input  wire        ld_disp_en,
    input  wire [5:0]  ld_dest_preg,
    input  wire [3:0]  ld_rob_idx,
    input  wire [63:0] ld_base,       // rs value
    input  wire [11:0] ld_L,          // offset

    // Dispatch: store (op=0x13)
    input  wire        st_disp_en,
    input  wire [3:0]  st_rob_idx,
    input  wire [63:0] st_base,       // rd value (base address)
    input  wire [63:0] st_data,       // rs value (data to store)
    input  wire        st_data_rdy,   // rs physical reg already ready?
    input  wire [5:0]  st_data_preg,  // rs physical reg (for CDB snoop)
    input  wire [11:0] st_L,

    // CDB snoop: update store data if not yet ready
    input  wire        cdb0_valid,
    input  wire [5:0]  cdb0_preg,
    input  wire [63:0] cdb0_data,
    input  wire        cdb1_valid,
    input  wire [5:0]  cdb1_preg,
    input  wire [63:0] cdb1_data,

    // Memory read interface
    output reg  [63:0] mem_rd_addr,
    input  wire [63:0] mem_rd_data,

    // Load result → CDB
    output reg         ld_cdb_valid,
    output reg  [63:0] ld_cdb_data,
    output reg  [5:0]  ld_cdb_preg,
    output reg  [3:0]  ld_cdb_rob,

    // ROB commit: push oldest store to memory
    input  wire        st_commit_en,   // ROB says: commit head store
    input  wire [3:0]  st_commit_rob,  // must match store queue head
    output reg         mem_wr_en,
    output reg  [63:0] mem_wr_addr,
    output reg  [63:0] mem_wr_data,

    // Full signals
    output wire        ld_full,
    output wire        st_full
);
    localparam LQ_DEPTH = 4;
    localparam SQ_DEPTH = 4;

    // Load queue
    reg        lq_v    [0:LQ_DEPTH-1];
    reg [5:0]  lq_preg [0:LQ_DEPTH-1];
    reg [3:0]  lq_rob  [0:LQ_DEPTH-1];
    reg [63:0] lq_addr [0:LQ_DEPTH-1];
    reg        lq_sent [0:LQ_DEPTH-1]; // address computed, issued to mem or forwarded

    // Store queue (circular)
    reg        sq_v     [0:SQ_DEPTH-1];
    reg [3:0]  sq_rob   [0:SQ_DEPTH-1];
    reg [63:0] sq_addr  [0:SQ_DEPTH-1];
    reg [63:0] sq_data  [0:SQ_DEPTH-1];
    reg        sq_drdy  [0:SQ_DEPTH-1]; // data ready
    reg [5:0]  sq_dpreg [0:SQ_DEPTH-1]; // preg to snoop for data
    reg [1:0]  sq_head, sq_tail;
    reg [2:0]  sq_count;

    reg [1:0]  lq_head, lq_tail;
    reg [2:0]  lq_count;

    assign ld_full = (lq_count >= LQ_DEPTH - 1);
    assign st_full = (sq_count >= SQ_DEPTH - 1);

    integer i;

    always @(posedge clk) begin
        if (reset || flush) begin
            for (i = 0; i < LQ_DEPTH; i = i + 1) lq_v[i] <= 0;
            for (i = 0; i < SQ_DEPTH; i = i + 1) sq_v[i] <= 0;
            lq_head <= 0; lq_tail <= 0; lq_count <= 0;
            sq_head <= 0; sq_tail <= 0; sq_count <= 0;
            ld_cdb_valid <= 0;
            mem_wr_en    <= 0;
        end else begin
            // ------- CDB snoop for store data -------
            for (i = 0; i < SQ_DEPTH; i = i + 1) begin
                if (sq_v[i] && !sq_drdy[i]) begin
                    if (cdb0_valid && sq_dpreg[i] == cdb0_preg) begin
                        sq_data[i] <= cdb0_data; sq_drdy[i] <= 1;
                    end else if (cdb1_valid && sq_dpreg[i] == cdb1_preg) begin
                        sq_data[i] <= cdb1_data; sq_drdy[i] <= 1;
                    end
                end
            end

            // ------- Dispatch new load -------
            if (ld_disp_en && lq_count < LQ_DEPTH) begin
                lq_v   [lq_tail] <= 1;
                lq_preg[lq_tail] <= ld_dest_preg;
                lq_rob [lq_tail] <= ld_rob_idx;
                lq_addr[lq_tail] <= ld_base + {{52{ld_L[11]}}, ld_L};
                lq_sent[lq_tail] <= 0;
                lq_tail  <= lq_tail + 1;
                lq_count <= lq_count + 1;
            end

            // ------- Dispatch new store -------
            if (st_disp_en && sq_count < SQ_DEPTH) begin
                sq_v    [sq_tail] <= 1;
                sq_rob  [sq_tail] <= st_rob_idx;
                sq_addr [sq_tail] <= st_base + {{52{st_L[11]}}, st_L};
                sq_data [sq_tail] <= st_data;
                sq_drdy [sq_tail] <= st_data_rdy;
                sq_dpreg[sq_tail] <= st_data_preg;
                sq_tail  <= sq_tail + 1;
                sq_count <= sq_count + 1;
            end

            // ------- Execute oldest unsent load -------
            ld_cdb_valid <= 0;
            if (lq_v[lq_head] && !lq_sent[lq_head]) begin
                begin
                    reg [63:0] fwd_data;
                    reg        fwd_found;
                    integer    j;
                    fwd_data = 64'b0; fwd_found = 0;
                    // Search store queue for matching address (newest store wins)
                    for (j = 0; j < SQ_DEPTH; j = j + 1) begin
                        if (sq_v[j] && sq_drdy[j] && sq_addr[j] == lq_addr[lq_head]) begin
                            fwd_data = sq_data[j]; fwd_found = 1;
                        end
                    end
                    if (fwd_found) begin
                        ld_cdb_valid <= 1;
                        ld_cdb_data  <= fwd_data;
                        ld_cdb_preg  <= lq_preg[lq_head];
                        ld_cdb_rob   <= lq_rob[lq_head];
                        lq_v[lq_head] <= 0;
                        lq_head  <= lq_head + 1;
                        lq_count <= lq_count - 1;
                    end else begin
                        // Issue memory read
                        mem_rd_addr       <= lq_addr[lq_head];
                        lq_sent[lq_head]  <= 1;
                    end
                end
            end else if (lq_v[lq_head] && lq_sent[lq_head]) begin
                // Memory read result ready next cycle (combinational memory)
                ld_cdb_valid <= 1;
                ld_cdb_data  <= mem_rd_data;
                ld_cdb_preg  <= lq_preg[lq_head];
                ld_cdb_rob   <= lq_rob[lq_head];
                lq_v[lq_head] <= 0;
                lq_head  <= lq_head + 1;
                lq_count <= lq_count - 1;
            end

            // ------- Commit head store to memory -------
            mem_wr_en <= 0;
            if (st_commit_en && sq_v[sq_head] && sq_drdy[sq_head]) begin
                mem_wr_en   <= 1;
                mem_wr_addr <= sq_addr[sq_head];
                mem_wr_data <= sq_data[sq_head];
                sq_v[sq_head] <= 0;
                sq_head  <= sq_head + 1;
                sq_count <= sq_count - 1;
            end
        end
    end
endmodule
