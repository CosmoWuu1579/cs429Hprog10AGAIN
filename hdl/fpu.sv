// Floating-point unit — 5-stage pipeline, fully pipelined (1 new op per cycle).
// Stage 1: Unpack + special-case detect
// Stage 2: Subnormal normalize + alignment (add/sub) / exponent calc (mul/div)
// Stage 3: Mantissa operation (add, sub, mul, div)
// Stage 4: Post-op normalization (leading-1 hunt, shift, exponent adjust)
// Stage 5: Rounding + pack → IEEE 754 result
// All four opcodes (addf=0x14 subf=0x15 mulf=0x16 divf=0x17) complete in exactly 5 cycles.
// No busy signal: RS tracks the fixed latency.

module fpu (
    input  clk,
    input  reset,
    // Input handshake (accepted every cycle; no stall)
    input  wire        in_valid,
    input  wire [4:0]  opcode,
    input  wire [63:0] src1,
    input  wire [63:0] src2,
    input  wire [5:0]  in_dest_preg,
    input  wire [3:0]  in_rob_idx,
    // Output (valid 5 cycles after in_valid)
    output reg         out_valid,
    output reg  [63:0] result,
    output reg  [5:0]  out_dest_preg,
    output reg  [3:0]  out_rob_idx
);

// ---------------------------------------------------------------------------
// Stage 1 registers  (Unpack + special-case detect)
// ---------------------------------------------------------------------------
reg        s1_valid;
reg [4:0]  s1_op;
reg [5:0]  s1_dest;
reg [3:0]  s1_rob;
// Special-case bypass
reg        s1_special;
reg [63:0] s1_spec_res;
// Unpacked fields (signed extended exponent, normalised mantissa, shift applied)
reg        s1_sign1, s1_sign2;
reg [12:0] s1_exp1,  s1_exp2;   // biased, 13-bit; subnormals use 1
reg [52:0] s1_mant1, s1_mant2;  // always has leading 1 at bit 52 after shift
reg [5:0]  s1_sh1,   s1_sh2;    // left-shifts applied to normalize subnormals

// ---------------------------------------------------------------------------
// Stage 2 registers  (Alignment / Exponent calc)
// ---------------------------------------------------------------------------
reg        s2_valid;
reg [4:0]  s2_op;
reg [5:0]  s2_dest;
reg [3:0]  s2_rob;
reg        s2_special;
reg [63:0] s2_spec_res;
reg        s2_out_sign;
reg [12:0] s2_out_exp;
// For add/sub: aligned mantissas and whether to subtract
reg [52:0] s2_mant_a;     // larger-magnitude operand
reg [52:0] s2_mant_b;     // smaller, right-aligned to match a
reg [2:0]  s2_align_grs;  // guard/round/sticky lost during alignment shift
reg        s2_do_sub;     // 1 → subtract mantissas; 0 → add
// For mul/div: pass through normalised mantissas
reg [52:0] s2_mul_m1, s2_mul_m2;

// ---------------------------------------------------------------------------
// Stage 3 registers  (Mantissa operation)
// ---------------------------------------------------------------------------
reg        s3_valid;
reg [4:0]  s3_op;
reg [5:0]  s3_dest;
reg [3:0]  s3_rob;
reg        s3_special;
reg [63:0] s3_spec_res;
reg        s3_out_sign;
reg [12:0] s3_out_exp;
// Raw operation results (only relevant field used in stage 4 based on op)
reg [53:0] s3_add_raw;    // add/sub: 54-bit sum (bit 53 = overflow carry)
reg [105:0] s3_mul_raw;   // mul:    53*53 = up to 106-bit product
reg [108:0] s3_div_raw;   // div:    (53b << 56) / 53b → up to 109 bits

// ---------------------------------------------------------------------------
// Stage 4 registers  (Normalize)
// ---------------------------------------------------------------------------
reg        s4_valid;
reg [4:0]  s4_op;
reg [5:0]  s4_dest;
reg [3:0]  s4_rob;
reg        s4_special;
reg [63:0] s4_spec_res;
reg        s4_out_sign;
reg [12:0] s4_out_exp;
reg [51:0] s4_mant_frac;  // fractional bits [51:0] (leading 1 implicit)
reg [2:0]  s4_grs;        // guard, round, sticky
reg        s4_zero;       // exact zero result

// ---------------------------------------------------------------------------
// Combinational helpers (used in clocked always block)
// ---------------------------------------------------------------------------
// Variables used across multiple always blocks must be declared at module level
integer    i;
reg [5:0]  lz;            // leading-zero count for normalisation
reg        found_lz;

// ===========================================================================
// STAGE 1 → latch: Unpack + special case detect
// ===========================================================================
always @(posedge clk) begin
    integer j;
    reg [51:0] m1_frac, m2_frac;
    reg [10:0] e1_raw,  e2_raw;
    reg        nan1, nan2, inf1, inf2, z1, z2;
    reg [63:0] spec;
    reg [52:0] nm1, nm2;
    reg [5:0]  sh1, sh2;
    reg [12:0] ep1, ep2;
    reg        found1, found2;

    if (reset) begin
        s1_valid <= 0;
    end else begin
        s1_valid <= in_valid;
        s1_op    <= opcode;
        s1_dest  <= in_dest_preg;
        s1_rob   <= in_rob_idx;

        if (in_valid) begin
            e1_raw  = src1[62:52];
            m1_frac = src1[51:0];
            e2_raw  = src2[62:52];
            m2_frac = src2[51:0];

            nan1 = (e1_raw == 11'h7FF) && (m1_frac != 0);
            nan2 = (e2_raw == 11'h7FF) && (m2_frac != 0);
            inf1 = (e1_raw == 11'h7FF) && (m1_frac == 0);
            inf2 = (e2_raw == 11'h7FF) && (m2_frac == 0);
            z1   = (e1_raw == 0)       && (m1_frac == 0);
            z2   = (e2_raw == 0)       && (m2_frac == 0);

            // Default: not special
            spec          = 64'b0;
            s1_special   <= 0;
            s1_spec_res  <= 64'b0;

            // ---- Special case resolution (addf / subf) ----
            if (opcode == 5'h14 || opcode == 5'h15) begin
                // Effective sign of src2 for subtraction
                // addf: s2 sign unchanged; subf: s2 sign flipped
                if (nan1) begin
                    s1_special <= 1; s1_spec_res <= src1;
                end else if (nan2) begin
                    s1_special <= 1; s1_spec_res <= src2;
                end else if (inf1 && inf2) begin
                    // inf ± inf: same-sign → inf; diff sign → NaN
                    begin
                        reg same;
                        if (opcode == 5'h15) same = (src1[63] != src2[63]);
                        else                 same = (src1[63] == src2[63]);
                        if (same) begin
                            s1_special <= 1;
                            s1_spec_res <= {src1[63], 11'h7FF, 52'b0};
                        end else begin
                            s1_special <= 1;
                            s1_spec_res <= {1'b0, 11'h7FF, 51'b0, 1'b1}; // NaN
                        end
                    end
                end else if (inf1) begin
                    s1_special <= 1; s1_spec_res <= {src1[63], 11'h7FF, 52'b0};
                end else if (inf2) begin
                    // subf negates src2
                    begin
                        reg s2_eff_sign;
                        s2_eff_sign = (opcode == 5'h15) ? ~src2[63] : src2[63];
                        s1_special <= 1;
                        s1_spec_res <= {s2_eff_sign, 11'h7FF, 52'b0};
                    end
                end else if (z1) begin
                    s1_special <= 1;
                    if (opcode == 5'h15) s1_spec_res <= {~src2[63], src2[62:0]};
                    else                 s1_spec_res <= src2;
                end else if (z2) begin
                    s1_special <= 1; s1_spec_res <= src1;
                end
            end

            // ---- Special case resolution (mulf) ----
            if (opcode == 5'h16) begin
                if (nan1) begin
                    s1_special <= 1; s1_spec_res <= src1;
                end else if (nan2) begin
                    s1_special <= 1; s1_spec_res <= src2;
                end else if ((inf1 || inf2) && (z1 || z2)) begin
                    s1_special <= 1; s1_spec_res <= {1'b0,11'h7FF,51'b0,1'b1}; // NaN
                end else if (inf1 || inf2) begin
                    s1_special <= 1;
                    s1_spec_res <= {src1[63]^src2[63], 11'h7FF, 52'b0};
                end else if (z1 || z2) begin
                    s1_special <= 1;
                    s1_spec_res <= {src1[63]^src2[63], 63'b0};
                end
            end

            // ---- Special case resolution (divf) ----
            if (opcode == 5'h17) begin
                if (nan1) begin
                    s1_special <= 1; s1_spec_res <= src1;
                end else if (nan2) begin
                    s1_special <= 1; s1_spec_res <= src2;
                end else if (inf1 && inf2) begin
                    s1_special <= 1; s1_spec_res <= {1'b0,11'h7FF,51'b0,1'b1}; // NaN
                end else if (z1 && z2) begin
                    s1_special <= 1; s1_spec_res <= {1'b0,11'h7FF,51'b0,1'b1}; // NaN
                end else if (inf1) begin
                    s1_special <= 1;
                    s1_spec_res <= {src1[63]^src2[63], 11'h7FF, 52'b0};
                end else if (z1) begin
                    s1_special <= 1;
                    s1_spec_res <= {src1[63]^src2[63], 63'b0};
                end else if (inf2) begin
                    s1_special <= 1;
                    s1_spec_res <= {src1[63]^src2[63], 63'b0};
                end else if (z2) begin
                    s1_special <= 1;
                    s1_spec_res <= {src1[63]^src2[63], 11'h7FF, 52'b0}; // x/0 = Inf
                end
            end

            // ---- Unpack and normalize subnormals ----
            s1_sign1 <= src1[63];
            s1_sign2 <= (opcode == 5'h15) ? ~src2[63] : src2[63];

            // src1
            if (e1_raw != 0) begin
                ep1 = {2'b0, e1_raw};
                nm1 = {1'b1, m1_frac};
                sh1 = 0;
            end else begin
                // Subnormal: shift left until leading 1 appears at bit 52
                ep1 = 13'd1; // virtual biased exponent
                nm1 = {1'b0, m1_frac};
                sh1 = 0;
                found1 = 0;
                for (j = 52; j >= 0; j = j - 1) begin
                    if (!found1) begin
                        if (nm1[52]) found1 = 1;
                        else begin nm1 = nm1 << 1; sh1 = sh1 + 1; end
                    end
                end
            end

            // src2
            if (e2_raw != 0) begin
                ep2 = {2'b0, e2_raw};
                nm2 = {1'b1, m2_frac};
                sh2 = 0;
            end else begin
                ep2 = 13'd1;
                nm2 = {1'b0, m2_frac};
                sh2 = 0;
                found2 = 0;
                for (j = 52; j >= 0; j = j - 1) begin
                    if (!found2) begin
                        if (nm2[52]) found2 = 1;
                        else begin nm2 = nm2 << 1; sh2 = sh2 + 1; end
                    end
                end
            end

            s1_exp1  <= ep1; s1_mant1 <= nm1; s1_sh1 <= sh1;
            s1_exp2  <= ep2; s1_mant2 <= nm2; s1_sh2 <= sh2;
        end
    end
end

// ===========================================================================
// STAGE 2 → latch: Alignment (add/sub) or exponent calc (mul/div)
// ===========================================================================
always @(posedge clk) begin
    // effective biased exponents (accounting for subnormal shifts)
    reg [12:0] eff1, eff2, diff;
    reg [52:0] ma, mb;
    reg [2:0]  agrs;
    reg        do_sub;
    reg        sign_a;
    integer    k;

    if (reset) begin
        s2_valid <= 0;
    end else begin
        // Pass-through
        s2_valid    <= s1_valid;
        s2_op       <= s1_op;
        s2_dest     <= s1_dest;
        s2_rob      <= s1_rob;
        s2_special  <= s1_special;
        s2_spec_res <= s1_spec_res;

        if (s1_valid) begin
            // Effective biased exponents (subtract the normalisation shift from subnormals)
            // For normals sh=0, so eff = exp. For subnormals eff = 1 - sh (could underflow
            // but we guard with special=1 for zero inputs).
            eff1 = s1_exp1 - {7'b0, s1_sh1};
            eff2 = s1_exp2 - {7'b0, s1_sh2};

            if (s1_op == 5'h14 || s1_op == 5'h15) begin
                // --- Add / Sub: align mantissas ---
                // Ensure eff1 >= eff2 (swap if needed); result sign tracks larger
                if (eff1 >= eff2) begin
                    ma     = s1_mant1;
                    mb     = s1_mant2;
                    diff   = eff1 - eff2;
                    sign_a = s1_sign1;
                    do_sub = (s1_sign1 != s1_sign2);
                    s2_out_exp <= eff1;
                end else begin
                    ma     = s1_mant2;
                    mb     = s1_mant1;
                    diff   = eff2 - eff1;
                    sign_a = s1_sign2;
                    do_sub = (s1_sign1 != s1_sign2);
                    s2_out_exp <= eff2;
                end
                // Shift mb right by diff, collecting GRS bits
                agrs = 3'b0;
                for (k = 0; k < 64; k = k + 1) begin
                    if (k < diff) begin
                        agrs[0] = agrs[0] | mb[0]; // sticky
                        if (k == 0) agrs[1] = mb[0]; // round
                        if (k == 0) agrs[2] = (diff > 1) ? mb[1] : 1'b0; // guard... simplified
                        mb = {1'b0, mb[52:1]};
                    end
                end
                s2_mant_a   <= ma;
                s2_mant_b   <= mb;
                s2_align_grs <= agrs;
                s2_do_sub    <= do_sub;
                s2_out_sign  <= sign_a;
                s2_mul_m1   <= s1_mant1;
                s2_mul_m2   <= s1_mant2;
            end else begin
                // --- Mul / Div: compute result exponent ---
                // Both mantissas already normalised (leading 1 at bit 52)
                s2_mant_a   <= s1_mant1;
                s2_mant_b   <= s1_mant2;
                s2_mul_m1   <= s1_mant1;
                s2_mul_m2   <= s1_mant2;
                s2_do_sub    <= 0;
                s2_align_grs <= 0;
                s2_out_sign  <= s1_sign1 ^ s1_sign2;
                if (s1_op == 5'h16) begin
                    // mulf: exp_out = eff1 + eff2 - 1023
                    s2_out_exp <= eff1 + eff2 - 13'd1023;
                end else begin
                    // divf: exp_out = eff1 - eff2 + 1023
                    s2_out_exp <= eff1 - eff2 + 13'd1023;
                end
            end
        end
    end
end

// ===========================================================================
// STAGE 3 → latch: Mantissa operation
// ===========================================================================
always @(posedge clk) begin
    reg [53:0] sum;
    reg [105:0] prod;
    reg [108:0] quot;

    if (reset) begin
        s3_valid <= 0;
    end else begin
        s3_valid    <= s2_valid;
        s3_op       <= s2_op;
        s3_dest     <= s2_dest;
        s3_rob      <= s2_rob;
        s3_special  <= s2_special;
        s3_spec_res <= s2_spec_res;
        s3_out_sign <= s2_out_sign;
        s3_out_exp  <= s2_out_exp;

        if (s2_valid) begin
            case (s2_op)
            5'h14: begin
                // addf: add aligned mantissas
                sum = {1'b0, s2_mant_a} + {1'b0, s2_mant_b};
                s3_add_raw <= sum;
                s3_mul_raw <= 0;
                s3_div_raw <= 0;
            end
            5'h15: begin
                // subf: subtract (mant_a >= mant_b after alignment swap)
                if (s2_mant_a >= s2_mant_b)
                    sum = {1'b0, s2_mant_a} - {1'b0, s2_mant_b};
                else
                    sum = {1'b0, s2_mant_b} - {1'b0, s2_mant_a};
                s3_add_raw <= sum;
                s3_mul_raw <= 0;
                s3_div_raw <= 0;
            end
            5'h16: begin
                // mulf: 53b × 53b product
                prod = s2_mul_m1 * s2_mul_m2;
                s3_mul_raw <= prod;
                s3_add_raw <= 0;
                s3_div_raw <= 0;
            end
            5'h17: begin
                // divf: shift dividend left 56 bits before integer division
                quot = {s2_mul_m1, 56'b0} / {56'b0, s2_mul_m2};
                s3_div_raw <= quot;
                s3_add_raw <= 0;
                s3_mul_raw <= 0;
            end
            default: begin
                s3_add_raw <= 0; s3_mul_raw <= 0; s3_div_raw <= 0;
            end
            endcase
        end
    end
end

// ===========================================================================
// STAGE 4 → latch: Normalize (find leading 1, shift, adjust exponent)
// ===========================================================================
always @(posedge clk) begin
    reg [53:0] val54;
    reg [105:0] val106;
    reg [108:0] val109;
    reg [12:0] exp_adj;
    reg [51:0] frac_out;
    reg [2:0]  grs_out;
    reg        is_zero;
    integer    n;
    reg        fn;

    if (reset) begin
        s4_valid <= 0;
    end else begin
        s4_valid    <= s3_valid;
        s4_op       <= s3_op;
        s4_dest     <= s3_dest;
        s4_rob      <= s3_rob;
        s4_special  <= s3_special;
        s4_spec_res <= s3_spec_res;
        s4_out_sign <= s3_out_sign;

        if (s3_valid) begin
            exp_adj  = s3_out_exp;
            frac_out = 52'b0;
            grs_out  = 3'b0;
            is_zero  = 0;

            case (s3_op)
            5'h14, 5'h15: begin
                // add/sub result in s3_add_raw[53:0]
                val54 = s3_add_raw;
                if (val54 == 0) begin
                    is_zero = 1;
                end else if (val54[53]) begin
                    // Overflow: right-shift by 1, bump exponent
                    grs_out  = {val54[1], val54[0], 1'b0};
                    frac_out = val54[52:1];
                    exp_adj  = s3_out_exp + 1;
                end else begin
                    // Find leading 1 in bits [52:0]
                    fn = 0; lz = 0;
                    for (n = 52; n >= 0; n = n - 1) begin
                        if (!fn) begin
                            if (val54[n]) fn = 1;
                            else lz = lz + 1;
                        end
                    end
                    // Shift left by lz to bring leading 1 to bit 52
                    val54    = val54 << lz;
                    frac_out = val54[51:0];
                    grs_out  = 3'b0;
                    exp_adj  = s3_out_exp - {7'b0, lz};
                end
            end

            5'h16: begin
                // mulf: product is in s3_mul_raw[105:0]
                // Two normalised 53-bit values (1.x * 1.x) give result in [1,4)
                // bit 105 set → result ≥ 2, right-shift 1, exp++
                // bit 104 set → result in [1,2), already normalised
                val106 = s3_mul_raw;
                if (val106[105]) begin
                    grs_out  = {val106[52], val106[51], |val106[50:0]};
                    frac_out = val106[104:53];
                    exp_adj  = s3_out_exp + 1;
                end else begin
                    grs_out  = {val106[51], val106[50], |val106[49:0]};
                    frac_out = val106[103:52];
                    exp_adj  = s3_out_exp;
                end
                if (val106 == 0) is_zero = 1;
            end

            5'h17: begin
                // divf: quotient in s3_div_raw[108:0]
                // Dividend was mant1 << 56, divisor was mant2 (both 53-bit with leading 1)
                // Quotient leading 1 sits at bit 56 or 55
                val109 = s3_div_raw;
                if (val109 == 0) begin
                    is_zero = 1;
                end else if (val109[56]) begin
                    // Leading 1 at bit 56: result in [1,2)
                    grs_out  = {val109[3], val109[2], |val109[1:0]};
                    frac_out = val109[55:4];
                    exp_adj  = s3_out_exp;
                end else begin
                    // Leading 1 at bit 55: result in [0.5,1), right-shift by -1
                    grs_out  = {val109[2], val109[1], val109[0]};
                    frac_out = val109[54:3];
                    exp_adj  = s3_out_exp - 1;
                end
            end

            default: begin is_zero = 1; end
            endcase

            s4_out_exp  <= exp_adj;
            s4_mant_frac <= frac_out;
            s4_grs       <= grs_out;
            s4_zero      <= is_zero;
        end
    end
end

// ===========================================================================
// STAGE 5 (output): Rounding + Pack → IEEE 754
// ===========================================================================
always @(posedge clk) begin
    reg [51:0] frac;
    reg [12:0] exp;
    reg        round_up;
    reg [52:0] rounded; // frac + round carry

    if (reset) begin
        out_valid <= 0; result <= 0;
        out_dest_preg <= 0; out_rob_idx <= 0;
    end else begin
        out_valid     <= s4_valid;
        out_dest_preg <= s4_dest;
        out_rob_idx   <= s4_rob;

        if (s4_valid) begin
            if (s4_special) begin
                result <= s4_spec_res;
            end else if (s4_zero) begin
                result <= {s4_out_sign, 63'b0};
            end else begin
                // Round-to-nearest-even: round up if GRS > 100, or GRS = 100 and LSB = 1
                round_up = (s4_grs > 3'b100) ||
                           (s4_grs == 3'b100 && s4_mant_frac[0]);
                rounded  = {1'b0, s4_mant_frac} + (round_up ? 53'b1 : 53'b0);
                frac     = rounded[51:0];
                exp      = s4_out_exp;
                // Rounding overflow: mantissa became 2.0
                if (rounded[52]) exp = exp + 1;

                // Overflow → Inf
                if (exp >= 13'd2047) begin
                    result <= {s4_out_sign, 11'h7FF, 52'b0};
                // Subnormal or underflow
                end else if (exp <= 0) begin
                    // Shift frac right to produce subnormal (exp field = 0)
                    // Subnormal: result = 0.frac * 2^(-1022)
                    // We need to right-shift frac by (1 - exp) places
                    begin
                        reg [6:0]  sub_shift;
                        reg [51:0] sub_frac;
                        sub_shift = (exp == 0) ? 7'd1 : (7'd1 - exp[6:0]);
                        sub_frac  = frac >> sub_shift;
                        result <= {s4_out_sign, 11'b0, sub_frac};
                    end
                end else begin
                    result <= {s4_out_sign, exp[10:0], frac};
                end
            end
        end else begin
            out_valid <= 0;
        end
    end
end

endmodule
