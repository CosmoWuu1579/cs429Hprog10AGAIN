// Testbench for tinker_core — loads a small program into memory and checks results.
`timescale 1ns/1ps
`include "tinker.sv"

module tb_tinker_core;
    reg  clk, reset;
    wire hlt;

    tinker_core dut (.clk(clk), .reset(reset), .hlt(hlt));

    // Clock: 10ns period
    always #5 clk = ~clk;

    // Helper task: write a 32-bit instruction at a byte address
    task write_instr;
        input [63:0] addr;
        input [31:0] instr;
        begin
            dut.memory.bytes[addr]   = instr[7:0];
            dut.memory.bytes[addr+1] = instr[15:8];
            dut.memory.bytes[addr+2] = instr[23:16];
            dut.memory.bytes[addr+3] = instr[31:24];
        end
    endtask

    // Encode instruction fields: {op[4:0], d[4:0], s[4:0], t[4:0], L[11:0]}
    function [31:0] enc3;
        input [4:0] op, d, s, t;
        begin enc3 = {op, d, s, t, 12'b0}; end
    endfunction
    function [31:0] encL;
        input [4:0] op, d;
        input [11:0] L;
        begin encL = {op, d, 10'b0, L}; end
    endfunction
    function [31:0] enc2;
        input [4:0] op, d, s;
        begin enc2 = {op, d, s, 17'b0}; end
    endfunction
    function [31:0] enc_halt;
        begin enc_halt = {5'hf, 27'b0}; end // priv L=0 = halt
    endfunction

    integer i;
    integer timeout;

    initial begin
        clk = 0; reset = 1;
        // Zero out memory (autograder does this; we do it for cleanliness)
        // Program starts at 0x2000
        // -------------------------------------------------------------------
        // Test 1: add r1, r2, r3  (r1 = r2 + r3 = 0+0=0, then addi r1,5 → r1=5)
        // addi r1, 5    (0x19: r1 = r1 + 5)
        write_instr(64'h2000, encL(5'h19, 5'd1, 5'd5));      // addi r1, 5  → r1=5
        // addi r2, 7
        // write_instr(64'h2004, encL(5'h19, 5'd2, 5'd7));      // addi r2, 7  → r2=7
        // // add r3, r1, r2
        // write_instr(64'h2008, enc3(5'h18, 5'd3, 5'd1, 5'd2)); // add r3=r1+r2=12
        // // sub r4, r2, r1
        // write_instr(64'h200c, enc3(5'h1a, 5'd4, 5'd2, 5'd1)); // sub r4=r2-r1=2
        // // mul r5, r3, r4
        // write_instr(64'h2010, enc3(5'h1c, 5'd5, 5'd3, 5'd4)); // mul r5=12*2=24
        // // or r6, r1, r2
        // write_instr(64'h2014, enc3(5'h01, 5'd6, 5'd1, 5'd2)); // or r6=5|7=7
        // // and r7, r5, r6
        // write_instr(64'h2018, enc3(5'h00, 5'd7, 5'd5, 5'd6)); // and r7=24&7=0
        // // xor r8, r1, r2
        // write_instr(64'h201c, enc3(5'h02, 5'd8, 5'd1, 5'd2)); // xor r8=5^7=2
        // halt
        write_instr(64'h2020, enc_halt());

        @(posedge clk); @(posedge clk);
        reset = 0;

        // Run until hlt or timeout
        timeout = 0;
        while (!hlt && timeout < 500) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (!hlt) begin
            $display("FAIL: timeout after %0d cycles", timeout);
        end else begin
            $display("Halted after %0d cycles", timeout);
            // Check register results via architectural reg file
            $display("r1 = %0d (expect 5)",  dut.reg_file.registers[1]);
            $display("r2 = %0d (expect 7)",  dut.reg_file.registers[2]);
            $display("r3 = %0d (expect 12)", dut.reg_file.registers[3]);
            $display("r4 = %0d (expect 2)",  dut.reg_file.registers[4]);
            $display("r5 = %0d (expect 24)", dut.reg_file.registers[5]);
            $display("r6 = %0d (expect 7)",  dut.reg_file.registers[6]);
            $display("r7 = %0d (expect 0)",  dut.reg_file.registers[7]);
            $display("r8 = %0d (expect 2)",  dut.reg_file.registers[8]);

            if (dut.reg_file.registers[1] == 64'd5  &&
                dut.reg_file.registers[2] == 64'd7  &&
                dut.reg_file.registers[3] == 64'd12 &&
                dut.reg_file.registers[4] == 64'd2  &&
                dut.reg_file.registers[5] == 64'd24 &&
                dut.reg_file.registers[6] == 64'd7  &&
                dut.reg_file.registers[7] == 64'd0  &&
                dut.reg_file.registers[8] == 64'd2)
                $display("PASS: all registers correct");
            else
                $display("FAIL: register mismatch");
        end
        $finish;
    end

    initial begin
        $dumpfile("sim/tb_tinker_core.vcd");
        $dumpvars(0, tb_tinker_core);
    end
endmodule
