# TG68K as a 68020 CPU: feasibility check

October 2026. A check of whether the TG68K.C soft core (https://github.com/TobiFlex/TG68K.C) could replace fx68k, to give the machine 68020 instructions and more speed without new hardware. Nothing here is in the design yet.

## Summary

Feasible. TG68K runs 68020 code correctly, fits our 16-bit memory and scheduler without changes, and works in our simulation flow. It costs about 2,100 LUTs more than fx68k and will not run at 100 MHz, so it needs room made first (section 6) and a Vivado build to confirm its speed.

## 1. Why not a real 68020 or 68030

A real 68020/030 needs about 90 signals (32 address, 32 data, about 25 control: DSACK0/1, SIZ0/1, STERM, burst, FC, IPL, bus arbitration) and they are 5 V parts. The KS3's accelerator port has 28 pins, 13 of them used by the FT232H, and the Artix-7 is 3.3 V only. A real 030 would need either a separate accelerator card with its own logic and fast RAM, linked to the KS3 over a narrow multiplexed bus, or a different FPGA board with about 100 free pins and level shifters. That belongs with a future board.

## 2. The core

- 68000, 68010 or 68020 instruction set, chosen by generics, or switchable at reset by an input (CPU = 00, 01, 11). 68020 features: 32-bit MUL and DIV, bitfields, extended addressing modes (scaled index, memory indirect), EXTB.L, VBR and the 68010/68020 stack frames.
- No MMU, no FPU, no instruction cache. Not cycle-exact (it does not try to be).
- Bus: 16-bit data, 32-bit address, a clock enable. One access per enabled clock; a 32-bit access is two. `busstate` says whether a clock is a fetch, a read, a write or no access.
- Licence: LGPL-3.0 (copyright Tobias Gubener). Fine for this project if kept as separate files with the notice.

## 3. Size (Yosys, synth_xilinx for the XC7A35T)

| | LUTs | Flip-flops | DSP | Block RAM |
|---|---|---|---|---|
| fx68k (today) | 3,518 | 1,416 | 0 | 2.5 |
| TG68K, 68000 mode | about 5,020 | 861 | 4 | 0 |
| TG68K, 68020 mode | about 5,660 | 960 | 10 | 0 |
| 68020 mode against fx68k | **+2,140** | −456 | +10 | −2.5 |

(LUTs include distributed RAM at 4 LUTs per RAM32M, as the CI check counts them.) The whole design would go from 16,455 LUTs (79%) to about 18,600 (89%).

## 4. Speed

- **Clock.** The longest path between registers is about 48 LUT levels in a generic 6-input LUT mapping, against 13 for fx68k and 26 for bpldma (which meets 100 MHz). The count is inflated by adders (which the real build puts in fast carry chains), but the core will not run at 100 MHz. About 50 MHz is a reasonable guess: the clock enable every other 100 MHz clock, with a two-clock (multicycle) timing constraint on the core. Only a Vivado build can confirm it.
- **Throughput.** In a test with zero-wait memory, 20 instructions took 105 clocks with 61 memory accesses. In our system the CPU is limited by memory: fx68k makes one access per 200 ns; TG68K could make one per 100 ns slot (cycle 0), and more if it were also given free memory cycles. A rough expectation is 2–3 times fx68k on ordinary code, and much more on multiplies and divides (a 68000's MULS takes about 70 clocks).

## 5. Checks done

- **68020 instructions.** A test program (assembled with `vasmm68k_mot -m68020`) ran on the core with a simple memory model and gave the right results for MULS.L, DIVU.L, BFEXTU, EXTB.L and a scaled index (`(a0,d6.l*4)`).
- **Simulation flow.** `ghdl --synth --out=verilog` turns the VHDL into a 35,000-line Verilog netlist that Icarus compiles and runs, so the core fits our existing testbench (the testbench itself stays Verilog).
- **Synthesis flow.** Yosys reads the VHDL directly with the GHDL plugin (`yosys -m ghdl`; on Ubuntu, packages `ghdl` and `yosys-plugin-ghdl`; the plugin needs `--PREFIX=/usr/lib/ghdl/mcode/vhdl`). Vivado reads VHDL itself.

## 6. Caveats

- **Room.** At 89% the design is above the 85% wanted for routing at 100 MHz. It fits comfortably only after the planned trims: bpldma's end-of-line adders (about −1,000 LUTs) and the timers (about −350).
- **Bus errors.** The core takes the bus error exception, but with a simplified stack frame, so a faulted instruction cannot be resumed. Our uses (unmapped addresses, ROM writes, PROTECT, and the boot ROM's test, which resets the stack and jumps back) work with that.
- **Software.** 68000 code runs unchanged in 68020 mode, but exception handlers that read the stack frame must allow for the 68020 frame formats.
- **Two clock rates.** The CPU at 50 MHz and the rest at 100 MHz, with the bus adapter between them: simple with a clock enable, as both come from the 100 MHz clock.

## 7. Plan, if it goes ahead

1. Make room: the bpldma and timer trims.
2. Add TG68K under `fpga/third_party/` (with its licence), behind a build option; fx68k stays the default.
3. A bus adapter from TG68K's `busstate` and clock enable to bus_if's memory, ROM and register paths (simpler than fx68k's phase timing).
4. Run the boot, video, copper and audio tests on both CPUs (the GHDL-converted netlist in Icarus).
5. A Vivado build for the KS3, to confirm the 50 MHz timing.
6. Optionally, a SYSCON bit to choose 68000 or 68020 mode at reset (switchable generics; about the 68020 size).
