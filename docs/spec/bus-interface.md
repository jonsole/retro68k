# Spec 1: CPU bus interface

Status: **draft for review**

This spec connects the 68000 to everything else. It covers how the fx68k core is clocked, how its bus signals cross into the 100 MHz memory side, address decoding, /DTACK and wait states, bus errors, interrupt acknowledge, reset, and what changes for the real 68SEC000 later.

## 1. Summary

| Item | Value |
|------|-------|
| CPU | fx68k (cycle-exact 68000) inside the FPGA; a real MC68SEC000 on the CPU board later |
| CPU speed | 20 MHz: fx68k clocked at 40 MHz with alternating phase enables. Fallback 16.7 MHz (33.3 MHz clock) |
| Clock crossing | 40 MHz and 100 MHz come from the same PLL and line up every 50 ns. Signals cross at fixed points with at least 15 ns to settle, so no synchronisers and no uncertainty |
| Bus | 68000 asynchronous bus: /AS, /UDS, /LDS, R/W, /DTACK, /BERR, FC0–2, IPL0–2. /VPA, E, bus arbitration and /HALT input are not used |
| Wait states | None for ROM, block RAM and registers. Chip RAM: none on the CPU's slots, 2 clocks when an access meets a busy DMA slot (spec 5) |
| Bus errors | Unmapped addresses, writes to ROM, and (optionally) user-mode accesses to hardware |
| Interrupts | Vectored; the interrupt controller answers the acknowledge cycle with no wait states |
| Reset | fx68k reset from the system reset (spec 7); its RESET instruction resets the devices; a halted CPU (double bus fault) is detected |

## 2. Clocking fx68k

### 2.1 Phase enables

fx68k needs a clock at least twice the CPU speed, plus two one-cycle pulses, **enPhi1** and **enPhi2**, which act as clock enables for the two halves of the 68000's clock. "The original clock frequency can be any multiple and it doesn't even need to be regular" (fx68k notes).

- fx68k is clocked at **40 MHz** (the 200 MHz master ÷ 5).
- enPhi1 and enPhi2 alternate on every 40 MHz cycle, so one 68000 clock is two 40 MHz cycles: **20 MHz**.
- Each 68000 bus state (S0–S7) is one 40 MHz cycle, 25 ns. A bus cycle is 8 states, 200 ns. That is 2 memory slots (spec 5, section 5).
- fx68k's outputs change one 40 MHz cycle after the enable that caused them, exactly as the real chip's change on its clock edges.

### 2.2 Meeting timing at 40 MHz

40 MHz is near fx68k's top speed (design plan Q1). The fx68k notes say its microcode lookup is one of the slowest paths but its result isn't needed in the next cycle. The build will give ISE matching **multicycle constraints** (2 cycles) from the instruction register to the micro- and nanocode addresses, as the notes show for Vivado. If 40 MHz still can't be met, the fallback is 33.3 MHz (master ÷ 6) for a 16.7 MHz 68000, with 120 ns slots (spec 5, section 4.1).

### 2.3 Pausing the CPU

Because the enables are just clock enables, stopping them freezes fx68k exactly, in the middle of anything, and starting them again carries on as if nothing happened. Version 1 uses this only for reset. It could later support a hardware debugger (open point B3).

## 3. Crossing between 40 MHz and 100 MHz

The bus interface and the slot controller run at 100 MHz, while fx68k runs at 40 MHz. Both come from the 200 MHz master, and their rising edges line up every **50 ns** (one 68000 clock). Within each 50 ns, the edges are:

```
 time (ns):    0    10    20    25    30    40    50
 40 MHz:       ↑                 ↑                ↑
 100 MHz:      ↑     ↑     ↑           ↑     ↑     ↑
```

**From fx68k to 100 MHz** (address, /AS, /UDS, /LDS, R/W, FC, write data): these change only on 40 MHz edges, at 0 or 25 ns. The 100 MHz side captures them only on its edges at **20 and 40 ns**, 20 and 15 ns after any change.

**From 100 MHz to fx68k** (/DTACK, /BERR, IPL, read data): the 100 MHz side changes these only on its edges at **10 and 30 ns**. fx68k samples them on its edges at 25 and 50 ns, 15 and 20 ns later.

Every crossing therefore has **at least 15 ns** to settle. The build tells ISE so with timing groups and 15 ns path constraints, instead of the default worst case (5 ns, from 25 to 30). There are no synchronisers and no random delays, so the CPU's timing against the memory slots is the same every time.

At the 16.7 MHz fallback (33.3 MHz clock), edges line up every 30 ns, and the same idea applies with captures 20 ns after each change.

## 4. A bus cycle

### 4.1 Timing

For a bus cycle starting at time 0 (state S0), with the slot grid from spec 5:

| Time (ns) | State | What happens |
|-----------|-------|--------------|
| 0 | S0 | Cycle begins; slot k starts |
| 25 | S1 | Address and FC valid |
| 50 | S2 | /AS asserted; R/W valid |
| 70 | | 100 MHz side captures /AS: the access is known |
| 75 | S3 | Write data valid |
| 90 | | 100 MHz side captures write data |
| 100 | S4 | Slot k+1 starts: the SDRAM access begins (ACT) |
| 110 | | /DTACK asserted (or held back for a wait) |
| 125 | S5 | fx68k sees /DTACK: no wait state |
| 140 | | SDRAM read data arrives |
| 160 | | Read data driven to fx68k |
| 175 | S7 | fx68k latches the read data (end of S6) |
| 200 | | Next cycle can start |

For block RAM, registers and ROM, the data is ready well before 160 ns, so the same timing gives zero wait states.

### 4.2 Wait states

| Target | Wait |
|--------|------|
| Chip RAM, access in a slot the CPU can have | 0 |
| Chip RAM, access meets a busy odd slot, or a sprite or urgent copper fetch takes the slot | 2 clocks per slot of delay (/DTACK held to the next slot) |
| Boot ROM, block RAM areas, custom registers, system registers | 0 |
| Interrupt acknowledge | 0 |
| Fast RAM (CPU board) | 0 |

Waits are always whole slots, 2 CPU clocks each, so the CPU never drifts off the 2-clock grid (spec 5, section 5).

## 5. Address decoding

| Address | Target | Notes |
|---------|--------|-------|
| `0x000000`–`0x007FFF` | Boot ROM for reads while the overlay is on; Chip RAM otherwise | Writes always go to Chip RAM (spec 7, section 3.2) |
| `0x000000`–`0x7FFFFF` | Chip RAM (8 MB) | Through the slot controller |
| `0x800000`–`0x9FFFFF` | Reserved | Bus error |
| `0xA00000`–`0xBFFFFF` | Fast RAM (CPU board only) | Bus error on the main path |
| `0xC00000`–`0xDFFFFF` | Reserved | Bus error |
| `0xE00000`–`0xE0FFFF` | Custom registers, palette, sprite table, descriptor RAM | Internal register bus |
| `0xE10000`–`0xE13FFF` | Text screen and font | Internal register bus |
| `0xF00000`–`0xF0FFFF` | System registers | Internal register bus |
| `0xF80000`–`0xF87FFF` | Boot ROM | Writes are a bus error unless SYSCON.ROMWE (spec 7, section 3.3) |
| Everything else | Unmapped | Bus error |

Unused addresses inside a block (e.g. a gap in the custom registers) read as 0 and ignore writes. Only whole unmapped regions give bus errors, so the decoder stays small.

**Byte and word access:** /UDS and /LDS give the bytes. Chip RAM uses them as SDRAM byte masks. A byte write to a register behaves like a 16-bit write that keeps the other byte; the 16-bit-halves rules then apply (spec 10, section 4.1; spec 15, section 6).

## 6. Bus errors

/BERR is asserted at S4 instead of /DTACK, and the 68000 takes its bus error exception (vector 2). Causes:

- an unmapped or reserved address,
- a write to the boot ROM while ROMWE is off,
- **optional protection:** with SYSCON.PROTECT set, any user-mode access (FC = 001 or 010) to `0xE00000`–`0xFFFFFF`. An operating system can keep programs away from the hardware with one bit,
- a CPU-space cycle other than interrupt acknowledge (the 68000 has no others in normal use).

The address and the cause of the last bus error are kept in BUSERRADDR and BUSERRWHY for debugging.

## 7. Interrupt acknowledge

The 68000 signals an interrupt acknowledge with FC = 111 and A19–A16 = 1111, with the level on A3–A1. The bus interface passes it to the interrupt controller (spec 13), which puts the vector number on D7–D0. /DTACK follows at the normal time: no wait states, no /VPA, no E-clock cycle.

IPL0–2 come from the interrupt controller through the 100 MHz to 40 MHz crossing (section 3).

## 8. Reset and halt

- **Reset in:** the system reset (spec 7) drives fx68k's extReset, and at power-on also pwrUp (fx68k's "cold reset" input, which it needs once at start). The enables keep running during reset, so the core resets cleanly.
- **First bus cycle:** fx68k leaves reset at a fixed point in the slot grid, so its first bus cycle starts on an even slot and the CPU begins aligned (spec 5, section 5).
- **RESET instruction:** fx68k drives its reset output for 124 clocks. The bus interface turns this into the device reset in spec 7, section 2.4.
- **Halt:** a double bus fault halts the 68000 (fx68k's oHALTEDn). This sets SYSSTAT.HALTED and shows an error code on the LEDs. With SYSCON.HALTRESET set, the computer also resets itself, with RESETWHY.HALTED. Otherwise the watchdog, a reset button or a USB RESET command recovers it.
- **Not used:** /HALT as an input (fx68k does not implement bus retry), /VPA and E (no 6800 devices), and bus arbitration (/BR, /BG, /BGACK: no other bus master; DMA uses memory slots instead).

## 9. New system registers

Added to the system control registers (spec 7, section 7):

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x810` | SYSCON | adds PROTECT (3), HALTRESET (4) | User-mode accesses to hardware give bus errors; reset automatically when the CPU halts |
| `0x80C` | RESETWHY | adds HALTED (7) | Reset because the CPU halted |
| `0x820` | SYSSTAT | HALTED (0) | Read: the CPU is halted |
| `0x824` | BUSERRADDR | 23–0 | Read: address of the last bus error |
| `0x828` | BUSERRWHY | UNMAPPED (0), ROMWRITE (1), PROTECT (2), CPUSPACE (3) | Read: cause of the last bus error |

## 10. The real 68SEC000 later (phase 8)

The same bus interface serves an external 68SEC000 on the CPU board, with these differences (to be specified with the CPU board):

- The FPGA drives the CPU's 20 MHz clock (master ÷ 10), so the external CPU is phase-locked to the slot grid too.
- The CPU's signals arrive through the FPGA's I/O pins, registered in the pin flip-flops. Pin and board delays (a few ns each way) eat into the 15 ns margins in section 3, so the capture points may move, and Chip RAM accesses may need 2 extra clocks.
- Fast RAM (2 MB SRAM) on the CPU board is selected by the FPGA and runs with zero wait states.
- FC0–2 are wired (design plan D3), so interrupt acknowledge and PROTECT work the same way.

## 11. FPGA resources

| Item | Resource |
|------|----------|
| fx68k | ~3,350 LUTs, ~1,440 flip-flops, 3 block RAMs (design plan D10) |
| Bus interface: crossing registers, decoder, /DTACK and /BERR logic, register-bus master | Estimate 200–400 LUTs |

## 12. Open points

| # | Item |
|---|------|
| B1 | Get fx68k through ISE at 40 MHz with the multicycle constraints, as early as possible (design plan Q1) |
| B2 | Confirm in simulation that fx68k's outputs and sampling points match section 4.1 exactly (spec 5, open point M1) |
| B3 | A hardware debugger: pause the CPU by stopping its enables, single-step, breakpoints on addresses, all controlled from the PC over USB |
| B4 | Whether a user-mode access to Chip RAM should ever be blocked (memory protection beyond PROTECT): not in version 1 |

## 13. Tests

- **Clock crossing:** in simulation and in an ISE timing report, every 40 ↔ 100 MHz path meets 15 ns, and captures happen only on the edges in section 3.
- **Bus cycles:** reads and writes of bytes and words to every target, with the timing of section 4.1; zero wait states except where section 4.2 says.
- **Wait states:** with busy DMA, every wait is a whole number of slots and the CPU stays aligned.
- **Bus errors:** each cause raises vector 2 and records BUSERRADDR and BUSERRWHY; PROTECT blocks user mode only.
- **Interrupt acknowledge:** each level returns the right vector with no wait.
- **Reset and halt:** reset at every source; the RESET instruction resets the devices only; a double bus fault sets HALTED and, with HALTRESET, resets with RESETWHY.HALTED.
- **Software:** run a 68000 instruction test suite (for example one of the published exhaustive 68000 test sets) on fx68k through this bus interface, from ROM and from Chip RAM.
