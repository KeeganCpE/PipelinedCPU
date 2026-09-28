// =============================================================================
// design.v  –  5-Stage Pipelined RISC-V Processor (Behavioral Model)
// EE3172 Project 2
//
// Pipeline stages : IF | ID | EX | MEM | WB
// Pipeline regs   : IF/ID | ID/EX | EX/MEM | MEM/WB
//
// Supported instructions
//   R-type  : add  (opcode 0110011)
//   I-type  : addi (opcode 0010011), lw (opcode 0000011)
//   S-type  : sw   (opcode 0100011)
//
// Hazard handling
//   • Data forwarding  – EX/MEM → EX  and  MEM/WB → EX  (Figure 4.55)
//   • Load-use stall   – inserts 1 NOP bubble, freezes IF/ID & PC
// =============================================================================
`timescale 1ns/1ps

module Pipelined_CPU (
    input clk,
    input reset
);

    // =========================================================================
    // Memory arrays and register file
    // =========================================================================
    reg [31:0] imem [0:255];   // 256-word instruction memory (word-addressed by [9:2])
    reg [31:0] dmem [0:255];   // 256-word data memory
    reg [31:0] rf   [0:31];    // 32 general-purpose registers

    integer idx;               // loop variable (used in reset)

    // =========================================================================
    // Program Counter
    // =========================================================================
    reg [31:0] PC;

    // =========================================================================
    // IF/ID pipeline register
    // =========================================================================
    reg [31:0] IFID_PC;
    reg [31:0] IFID_IR;

    // =========================================================================
    // ID/EX pipeline register
    // =========================================================================
    reg [31:0] IDEX_PC;
    reg [31:0] IDEX_IR;
    reg [31:0] IDEX_A;          // rf[rs1] captured in ID
    reg [31:0] IDEX_B;          // rf[rs2] captured in ID
    reg [31:0] IDEX_Imm;        // sign-extended immediate
    reg [4:0]  IDEX_RS1;        // rs1 index (for forwarding comparisons)
    reg [4:0]  IDEX_RS2;        // rs2 index (for forwarding comparisons)
    reg [4:0]  IDEX_RD;         // destination register index
    // Control bits
    reg        IDEX_RegWrite;
    reg        IDEX_MemRead;
    reg        IDEX_MemWrite;
    reg        IDEX_MemToReg;
    reg        IDEX_ALUSrc;
    reg [1:0]  IDEX_ALUOp;

    // =========================================================================
    // EX/MEM pipeline register
    // =========================================================================
    reg [31:0] EXMEM_PC;
    reg [31:0] EXMEM_IR;
    reg [31:0] EXMEM_ALUResult;
    reg [31:0] EXMEM_WriteData;  // forwarded rs2 value – used by sw
    reg [4:0]  EXMEM_RD;
    // Control bits
    reg        EXMEM_RegWrite;
    reg        EXMEM_MemRead;
    reg        EXMEM_MemWrite;
    reg        EXMEM_MemToReg;

    // =========================================================================
    // MEM/WB pipeline register
    // =========================================================================
    reg [31:0] MEMWB_IR;
    reg [31:0] MEMWB_ALUResult;
    reg [31:0] MEMWB_ReadData;
    reg [4:0]  MEMWB_RD;
    // Control bits
    reg        MEMWB_RegWrite;
    reg        MEMWB_MemToReg;

    // =========================================================================
    // ID Stage – combinational decode of IF/ID register
    // =========================================================================
    wire [6:0] if_opcode = IFID_IR[6:0];
    wire [4:0] if_rs1    = IFID_IR[19:15];
    wire [4:0] if_rs2    = IFID_IR[24:20];
    wire [4:0] if_rd     = IFID_IR[11:7];

    // Immediate generation (Figure 4.49 – ImmGen)
    wire [31:0] imm_i = {{20{IFID_IR[31]}}, IFID_IR[31:20]};                        // I-type
    wire [31:0] imm_s = {{20{IFID_IR[31]}}, IFID_IR[31:25], IFID_IR[11:7]};         // S-type

    // Control unit (combinational, matches Figure 4.49 control signals)
    reg ctrl_RegWrite, ctrl_MemRead, ctrl_MemWrite, ctrl_MemToReg, ctrl_ALUSrc;
    reg [1:0] ctrl_ALUOp;

    always @(*) begin
        // Default: all signals de-asserted (NOP / bubble)
        ctrl_RegWrite = 1'b0;
        ctrl_MemRead  = 1'b0;
        ctrl_MemWrite = 1'b0;
        ctrl_MemToReg = 1'b0;
        ctrl_ALUSrc   = 1'b0;
        ctrl_ALUOp    = 2'b00;

        case (if_opcode)
            7'b0110011: begin   // R-type: add / sub
                ctrl_RegWrite = 1'b1;
                ctrl_ALUOp    = 2'b10;
            end
            7'b0010011: begin   // I-type ALU: addi
                ctrl_RegWrite = 1'b1;
                ctrl_ALUSrc   = 1'b1;
                ctrl_ALUOp    = 2'b10;
            end
            7'b0000011: begin   // Load: lw
                ctrl_RegWrite = 1'b1;
                ctrl_MemRead  = 1'b1;
                ctrl_MemToReg = 1'b1;
                ctrl_ALUSrc   = 1'b1;
                ctrl_ALUOp    = 2'b00;  // address = base + offset
            end
            7'b0100011: begin   // Store: sw
                ctrl_MemWrite = 1'b1;
                ctrl_ALUSrc   = 1'b1;
                ctrl_ALUOp    = 2'b00;  // address = base + offset
            end
            default: ;           // unknown / NOP
        endcase
    end

    // =========================================================================
    // Hazard Detection Unit  (load-use only)
    // Stalls the pipeline for one cycle when lw is in EX and the next
    // instruction needs the load result.
    // =========================================================================
    wire stall;
    assign stall = IDEX_MemRead              &&   // instruction in EX is a load
                   (IDEX_RD != 5'b0)         &&   // it has a real destination
                   ((IDEX_RD == if_rs1) ||        // dependent on rs1
                    (IDEX_RD == if_rs2));          // dependent on rs2

    // =========================================================================
    // Forwarding Unit  (Figure 4.55 – EX/MEM→EX and MEM/WB→EX)
    // =========================================================================
    reg [1:0] forwardA;   // selects ALU input A
    reg [1:0] forwardB;   // selects ALU input B (before ALUSrc mux)

    always @(*) begin
        // ----- Forward A (rs1) -----
        if (EXMEM_RegWrite && (EXMEM_RD != 5'b0) && (EXMEM_RD == IDEX_RS1))
            forwardA = 2'b10;   // EX/MEM → EX
        else if (MEMWB_RegWrite && (MEMWB_RD != 5'b0) && (MEMWB_RD == IDEX_RS1))
            forwardA = 2'b01;   // MEM/WB → EX
        else
            forwardA = 2'b00;   // no forwarding; use IDEX_A

        // ----- Forward B (rs2) -----
        if (EXMEM_RegWrite && (EXMEM_RD != 5'b0) && (EXMEM_RD == IDEX_RS2))
            forwardB = 2'b10;   // EX/MEM → EX
        else if (MEMWB_RegWrite && (MEMWB_RD != 5'b0) && (MEMWB_RD == IDEX_RS2))
            forwardB = 2'b01;   // MEM/WB → EX
        else
            forwardB = 2'b00;   // no forwarding; use IDEX_B
    end

    // =========================================================================
    // EX Stage – ALU  (combinational)
    // =========================================================================

    // WB data mux: either ALU result or memory load data
    wire [31:0] wb_result = MEMWB_MemToReg ? MEMWB_ReadData : MEMWB_ALUResult;

    // ALU input A – forwarding mux
    reg [31:0] alu_in_A;
    always @(*) begin
        case (forwardA)
            2'b10:   alu_in_A = EXMEM_ALUResult;
            2'b01:   alu_in_A = wb_result;
            default: alu_in_A = IDEX_A;
        endcase
    end

    // ALU input B – forwarding mux (before the ALUSrc mux)
    reg [31:0] alu_in_B_fwd;
    always @(*) begin
        case (forwardB)
            2'b10:   alu_in_B_fwd = EXMEM_ALUResult;
            2'b01:   alu_in_B_fwd = wb_result;
            default: alu_in_B_fwd = IDEX_B;
        endcase
    end

    // ALUSrc mux (Figure 4.55): choose forwarded rs2 OR sign-extended immediate
    wire [31:0] alu_in_B = IDEX_ALUSrc ? IDEX_Imm : alu_in_B_fwd;

    // ALU operation decode (ALUOp + funct3 + funct7[5])
    reg [31:0] alu_result;
    always @(*) begin
        case (IDEX_ALUOp)
            2'b00: // Load / Store – always ADD (address calculation)
                alu_result = alu_in_A + alu_in_B;

            2'b10: // R-type or I-type ALU – decode funct3/funct7
                case (IDEX_IR[14:12])           // funct3
                    3'b000: begin
                        // sub only for R-type (opcode 0110011) with funct7[5]=1
                        if ((IDEX_IR[6:0] == 7'b0110011) && IDEX_IR[30])
                            alu_result = alu_in_A - alu_in_B;   // sub
                        else
                            alu_result = alu_in_A + alu_in_B;   // add / addi
                    end
                    default:
                        alu_result = alu_in_A + alu_in_B;
                endcase

            default:
                alu_result = alu_in_A + alu_in_B;
        endcase
    end

    // =========================================================================
    // Sequential pipeline logic – one always block handles all 5 stages
    // =========================================================================
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            // -----------------------------------------------------------------
            // Synchronous reset: clear all pipeline registers and PC
            // -----------------------------------------------------------------
            PC <= 32'h0;

            IFID_PC <= 32'b0;
            IFID_IR <= 32'b0;

            IDEX_PC       <= 32'b0;
            IDEX_IR       <= 32'b0;
            IDEX_A        <= 32'b0;
            IDEX_B        <= 32'b0;
            IDEX_Imm      <= 32'b0;
            IDEX_RS1      <= 5'b0;
            IDEX_RS2      <= 5'b0;
            IDEX_RD       <= 5'b0;
            IDEX_RegWrite <= 1'b0;
            IDEX_MemRead  <= 1'b0;
            IDEX_MemWrite <= 1'b0;
            IDEX_MemToReg <= 1'b0;
            IDEX_ALUSrc   <= 1'b0;
            IDEX_ALUOp    <= 2'b0;

            EXMEM_PC        <= 32'b0;
            EXMEM_IR        <= 32'b0;
            EXMEM_ALUResult <= 32'b0;
            EXMEM_WriteData <= 32'b0;
            EXMEM_RD        <= 5'b0;
            EXMEM_RegWrite  <= 1'b0;
            EXMEM_MemRead   <= 1'b0;
            EXMEM_MemWrite  <= 1'b0;
            EXMEM_MemToReg  <= 1'b0;

            MEMWB_IR        <= 32'b0;
            MEMWB_ALUResult <= 32'b0;
            MEMWB_ReadData  <= 32'b0;
            MEMWB_RD        <= 5'b0;
            MEMWB_RegWrite  <= 1'b0;
            MEMWB_MemToReg  <= 1'b0;

            // Zero out register file
            for (idx = 0; idx < 32; idx = idx + 1)
                rf[idx] = 32'b0;
        end
        else begin
            // =================================================================
            // WB  –  write result back to register file
            //        (non-blocking so ID reads old values → forwarding handles it)
            // =================================================================
            if (MEMWB_RegWrite && (MEMWB_RD != 5'b0))
                rf[MEMWB_RD] <= MEMWB_MemToReg ? MEMWB_ReadData : MEMWB_ALUResult;

            // =================================================================
            // MEM/WB register  –  latch MEM stage outputs
            // =================================================================
            MEMWB_IR        <= EXMEM_IR;
            MEMWB_ALUResult <= EXMEM_ALUResult;
            // Read data memory only when MemRead is asserted
            MEMWB_ReadData  <= EXMEM_MemRead ? dmem[EXMEM_ALUResult[9:2]] : 32'b0;
            MEMWB_RD        <= EXMEM_RD;
            MEMWB_RegWrite  <= EXMEM_RegWrite;
            MEMWB_MemToReg  <= EXMEM_MemToReg;

            // =================================================================
            // MEM  –  data memory write (sw)
            // =================================================================
            if (EXMEM_MemWrite)
                dmem[EXMEM_ALUResult[9:2]] <= EXMEM_WriteData;

            // =================================================================
            // EX/MEM register  –  latch EX stage outputs
            // =================================================================
            EXMEM_IR        <= IDEX_IR;
            EXMEM_PC        <= IDEX_PC;
            EXMEM_ALUResult <= alu_result;
            // Store forwarded rs2 (before ALUSrc mux) so sw has the correct value
            EXMEM_WriteData <= alu_in_B_fwd;
            EXMEM_RD        <= IDEX_RD;
            EXMEM_RegWrite  <= IDEX_RegWrite;
            EXMEM_MemRead   <= IDEX_MemRead;
            EXMEM_MemWrite  <= IDEX_MemWrite;
            EXMEM_MemToReg  <= IDEX_MemToReg;

            // =================================================================
            // STALL path  (load-use hazard)
            //   • Insert NOP bubble into ID/EX
            //   • Do NOT update IF/ID or PC  (freeze upstream)
            // =================================================================
            if (stall) begin
                // NOP bubble – all control signals de-asserted, RD=0
                IDEX_IR       <= 32'h00000013;  // addi x0, x0, 0  (canonical NOP)
                IDEX_PC       <= IDEX_PC;
                IDEX_A        <= 32'b0;
                IDEX_B        <= 32'b0;
                IDEX_Imm      <= 32'b0;
                IDEX_RS1      <= 5'b0;
                IDEX_RS2      <= 5'b0;
                IDEX_RD       <= 5'b0;
                IDEX_RegWrite <= 1'b0;
                IDEX_MemRead  <= 1'b0;
                IDEX_MemWrite <= 1'b0;
                IDEX_MemToReg <= 1'b0;
                IDEX_ALUSrc   <= 1'b0;
                IDEX_ALUOp    <= 2'b0;
                // IF/ID and PC retain their values (no assignment here)
            end
            else begin
                // =============================================================
                // NORMAL path
                // =============================================================

                // ID/EX  –  latch decoded instruction + register reads
                IDEX_PC       <= IFID_PC;
                IDEX_IR       <= IFID_IR;
                IDEX_A        <= rf[if_rs1];    // register file read port 1
                IDEX_B        <= rf[if_rs2];    // register file read port 2
                // Select immediate format based on opcode
                IDEX_Imm      <= (if_opcode == 7'b0100011) ? imm_s : imm_i;
                IDEX_RS1      <= if_rs1;
                IDEX_RS2      <= if_rs2;
                IDEX_RD       <= if_rd;
                IDEX_RegWrite <= ctrl_RegWrite;
                IDEX_MemRead  <= ctrl_MemRead;
                IDEX_MemWrite <= ctrl_MemWrite;
                IDEX_MemToReg <= ctrl_MemToReg;
                IDEX_ALUSrc   <= ctrl_ALUSrc;
                IDEX_ALUOp    <= ctrl_ALUOp;

                // IF/ID  –  fetch instruction from instruction memory
                IFID_IR <= imem[PC[9:2]];   // word-addressed (PC >> 2)
                IFID_PC <= PC;

                // PC  –  advance by 4 (no branch support required)
                PC <= PC + 32'd4;
            end
        end
    end

endmodule 