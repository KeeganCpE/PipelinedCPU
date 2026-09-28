#PipelinedCPU

Simplified ARM-based CPU created in Verilog based on the following diagram:

<img width="943" height="722" alt="PipelinedCPU" src="https://github.com/user-attachments/assets/28cbe2cf-1c78-4acf-9d89-3e24590ad9f6" />

Pipeline stages : IF | ID | EX | MEM | WB
Pipeline regs   : IF/ID | ID/EX | EX/MEM | MEM/WB

Supported instructions
  R-type  : add  (opcode 0110011)
  I-type  : addi (opcode 0010011), lw (opcode 0000011)
  S-type  : sw   (opcode 0100011)

Hazard handling
  • Data forwarding  – EX/MEM → EX  and  MEM/WB → EX  (Figure 4.55)
  • Load-use stall   – inserts 1 NOP bubble, freezes IF/ID & PC

#Testbench Explanation (RISC-V machine code loaded into imem):

  addi x1, x0, 5      ; x1 = 5
  addi x2, x0, 10     ; x2 = 10
  add  x3, x1, x2     ; x3 = 15   ← forwarding: MEM/WB→EX (x1), EX/MEM→EX (x2)
  lw   x4, 0(x3)      ; x4 = dmem[3] = 20  ← one stall inserted (load-use)
  add  x5, x4, x1     ; x5 = 25   ← forwarding: MEM/WB→EX (x4)

Expected results after pipeline drains:
  x1 =  5,  x2 = 10,  x3 = 15,  x4 = 20,  x5 = 25

Machine-code encoding (verified bit-by-bit):
  0x00500093  addi x1,  x0, 5
  0x00A00113  addi x2,  x0, 10
  0x002081B3  add  x3,  x1, x2
  0x0001A203  lw   x4,  0(x3)
  0x001202B3  add  x5,  x4, x1
  
