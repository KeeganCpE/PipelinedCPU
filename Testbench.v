// =============================================================================
// testbench.v  –  Testbench for riscv_pipeline
// EE3172 Project 2
//
// Test program (RISC-V machine code loaded into imem):
//
//   addi x1, x0, 5      ; x1 = 5
//   addi x2, x0, 10     ; x2 = 10
//   add  x3, x1, x2     ; x3 = 15   ← forwarding: MEM/WB→EX (x1), EX/MEM→EX (x2)
//   lw   x4, 0(x3)      ; x4 = dmem[3] = 20  ← one stall inserted (load-use)
//   add  x5, x4, x1     ; x5 = 25   ← forwarding: MEM/WB→EX (x4)
//
// Expected results after pipeline drains:
//   x1 =  5,  x2 = 10,  x3 = 15,  x4 = 20,  x5 = 25
//
// Machine-code encoding (verified bit-by-bit):
//   0x00500093  addi x1,  x0, 5
//   0x00A00113  addi x2,  x0, 10
//   0x002081B3  add  x3,  x1, x2
//   0x0001A203  lw   x4,  0(x3)
//   0x001202B3  add  x5,  x4, x1
// =============================================================================
`timescale 1ns/1ps

module Testbench;

    // =========================================================================
    // DUT signals
    // =========================================================================
    reg clk;
    reg reset;

    // =========================================================================
    // Instantiate design under test
    // =========================================================================
    Pipelined_CPU dut (
        .clk   (clk),
        .reset (reset)
    );

    // =========================================================================
    // Clock: 10 ns period (100 MHz)
    // =========================================================================
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // =========================================================================
    // Simulation variables
    // =========================================================================
    integer       i;
    reg    [31:0] cycle_count;

    // =========================================================================
    // Memory initialisation and stimulus
    // =========================================================================
    initial begin
        cycle_count = 0;

        // ----- Fill memories with safe defaults before reset -----
        for (i = 0; i < 256; i = i + 1) begin
            dut.imem[i] = 32'h00000013;   // NOP: addi x0, x0, 0
            dut.dmem[i] = 32'b0;
        end

        // ----- Load test program -----
        // Instruction encodings (RISC-V 32-bit):
        //
        //  addi x1, x0, 5
        //    [31:20]=000000000101  [19:15]=00000  [14:12]=000  [11:7]=00001  [6:0]=0010011
        dut.imem[0] = 32'h00500093;

        //  addi x2, x0, 10
        //    [31:20]=000000001010  [19:15]=00000  [14:12]=000  [11:7]=00010  [6:0]=0010011
        dut.imem[1] = 32'h00A00113;

        //  add x3, x1, x2
        //    [31:25]=0000000  [24:20]=00010  [19:15]=00001  [14:12]=000  [11:7]=00011  [6:0]=0110011
        dut.imem[2] = 32'h002081B3;

        //  lw x4, 0(x3)
        //    [31:20]=000000000000  [19:15]=00011  [14:12]=010  [11:7]=00100  [6:0]=0000011
        dut.imem[3] = 32'h0001A203;

        //  add x5, x4, x1
        //    [31:25]=0000000  [24:20]=00001  [19:15]=00100  [14:12]=000  [11:7]=00101  [6:0]=0110011
        dut.imem[4] = 32'h001202B3;

        // ----- Initialise data memory -----
        // lw x4, 0(x3):  effective address = x3 + 0 = 15
        //   word index = 15[9:2] = 3   →  dmem[3]
        dut.dmem[3] = 32'd20;   // x4 will become 20

        // ----- Apply and release reset -----
        reset = 1'b1;
        repeat(2) @(posedge clk);   // hold reset for 2 rising edges
        @(negedge clk);             // release on a falling edge to avoid races
        reset = 1'b0;

        // ----- Let the pipeline drain (25 cycles is more than enough) -----
        repeat(25) @(posedge clk);

        // ----- Print and check results -----
        $display("");
        $display("==========================================================");
        $display("  Simulation Results  (EE3172 Project 2)");
        $display("==========================================================");
        $display("  Register | Got | Expected | Pass?");
        $display("  ---------|-----|----------|---------");
        $display("     x1    | %3d |    5     |  %s", dut.rf[1], (dut.rf[1] ==  5) ? "PASS" : "FAIL");
        $display("     x2    | %3d |   10     |  %s", dut.rf[2], (dut.rf[2] == 10) ? "PASS" : "FAIL");
        $display("     x3    | %3d |   15     |  %s", dut.rf[3], (dut.rf[3] == 15) ? "PASS" : "FAIL");
        $display("     x4    | %3d |   20     |  %s", dut.rf[4], (dut.rf[4] == 20) ? "PASS" : "FAIL");
        $display("     x5    | %3d |   25     |  %s", dut.rf[5], (dut.rf[5] == 25) ? "PASS" : "FAIL");
        $display("==========================================================");

        if (dut.rf[1] ==  5 &&
            dut.rf[2] == 10 &&
            dut.rf[3] == 15 &&
            dut.rf[4] == 20 &&
            dut.rf[5] == 25)
            $display("  >>>  ALL TESTS PASSED  <<<");
        else
            $display("  >>>  SOME TESTS FAILED – check waveform  <<<");

        $display("==========================================================");
        $display("");
        $finish;
    end

    // =========================================================================
    // Per-cycle pipeline trace (visible in transcript / console)
    // =========================================================================
    always @(posedge clk) begin
        if (!reset) begin
            cycle_count <= cycle_count + 1;
            $display("Cyc%02d | PC=%02d | IF=%h | ID=%h | EX=%h | ME=%h | stall=%b | fwdA=%b fwdB=%b | x1=%0d x2=%0d x3=%0d x4=%0d x5=%0d",
                     cycle_count,
                     dut.PC,
                     dut.IFID_IR,
                     dut.IDEX_IR,
                     dut.EXMEM_IR,
                     dut.MEMWB_IR,
                     dut.stall,
                     dut.forwardA,
                     dut.forwardB,
                     dut.rf[1], dut.rf[2], dut.rf[3], dut.rf[4], dut.rf[5]);
        end
    end

    // =========================================================================
    // VCD waveform dump
    // (Works in EDA Playground / ModelSim / QuestaSim)
    // In Quartus's built-in simulator, use the waveform window instead.
    // =========================================================================
    initial begin
        $dumpfile("pipeline_wave.vcd");
        $dumpvars(0, Testbench);
    end

endmodule 