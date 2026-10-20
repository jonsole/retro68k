# retro68k design plan

Status: **draft for review**. Nothing in `fpga/`, `firmware/` or `hardware/` gets built until the decisions below are agreed and each block has a written spec.

## 1. Requirements

| # | Requirement | Source |
|---|-------------|--------|
| R1 | CPU is a real MC68SEC000 (3.3 V, 16-bit bus mode) | decided |
| R2 | Main memory is fast async SRAM with zero wait states | project goal |
| R3 | Video and audio are done by a Lattice ECP5 FPGA, open toolchain (Yosys + nextpnr) | decided |
| R4 | Video output is HDMI/DVI at 640×480 @ 60 Hz | decided |
| R5 | Audio is 4–8 PCM sample channels (Amiga-style) | decided |
| R6 | Usable as a home computer: boots to a monitor, then BASIC; keyboard; SD card | decided ("both") |
| R7 | Usable as a game/demo machine: sprites, scrolling, later a blitter | decided ("both") |
| R8 | First hardware = ECP5 dev board + a small custom CPU board; one combined PCB later | decided |

## 2. Key decisions

### D1. Dev board: ULX3S with ECP5 LFE5U-85F (proposed)

Why:
- It has HDMI (GPDI), a USB serial port wired to the FPGA, an SD card slot, an audio jack, 32 MB SDRAM and 3.3 V GPIO headers already on the board.
- The **85F** has about 468 KB of block RAM. That is enough for a full 640×480×8bpp frame buffer (300 KB) inside the FPGA, so the first video design needs no external video RAM.
- The 45F (~243 KB of block RAM) would limit us to 320×240×8bpp or 640×480×4bpp until SDRAM is in use.

To verify: the exact number of free header GPIOs on the current ULX3S revision (expected 56; see D3).

### D2. The FPGA is the glue logic

The FPGA generates the CPU clock and reset, decodes addresses, drives `/DTACK`, encodes interrupts and selects the SRAM. This means no CPLD and no 74-series glue chips, and the memory map can change without new hardware.

- The FPGA holds the CPU in reset until it has finished loading its configuration.
- **The boot ROM lives in FPGA block RAM** (e.g. 32 KB), loaded with the bitstream. This avoids a flash chip and its programming steps. A real flash ROM is optional on the final PCB.
- The 68SEC000 is 3.3 V, the same as the ECP5 I/O, so no level shifters are needed.

### D3. CPU board ↔ FPGA pin budget

| Signals | Pins |
|---------|------|
| A1–A23 | 23 |
| D0–D15 | 16 |
| /AS, /UDS, /LDS, R/W, /DTACK | 5 |
| /IPL0–2 | 3 |
| /RESET, /HALT, CLK, /BERR, /VPA | 5 |
| SRAM /CE | 1 |
| **Total** | **53** |

Savings already applied:
- **FC0–2 are not connected.** Interrupt-acknowledge cycles are recognised by their address instead (A4–A23 all 1), so `0xFFFFF0`–`0xFFFFFF` is reserved.
- **Bus arbitration is not used:** /BR is tied high and /BGACK is tied high.
- **SRAM control lines are wired directly to the CPU:** /UB ← /UDS, /LB ← /LDS, /WE ← R/W, and /OE tied low. Writes are timed by /UDS and /LDS. Spec 1 must check this against the SRAM datasheet's timing.

With 56 GPIOs on the headers, 53 leaves only 3 spare. **This is the main hardware risk.** If the count does not fit, the fallback is to move SRAM decoding onto the CPU board (one small 3.3 V logic chip) and drop A1–A18 from the FPGA side. The FPGA would then see only a narrower window, at the cost of a smaller VRAM window.

### D4. CPU clock: 12.5 MHz first, aiming for 20 MHz

The FPGA's PLL generates the clock, so it can be changed in software. Start low while the bus runs over header wires, then raise it. The 68SEC000 is rated up to 20 MHz.

The FPGA samples the bus with its own fast system clock (100 MHz). CPU strobes pass through two-flop synchronisers, which adds about 20 ns of delay. A zero-wait-state cycle at 20 MHz allows roughly 100 ns before `/DTACK` must be seen, so there is margin.

### D5. Memory map (proposed)

| Range | Size | Device | Wait states |
|-------|------|--------|-------------|
| `0x000000`–`0x007FFF` | 32 KB | Boot ROM (FPGA BRAM); overlays RAM at reset | 0 |
| `0x100000`–`0x2FFFFF` | 2 MB | Main SRAM (1M×16, e.g. IS61WV102416, 10 ns) | 0 |
| `0xC00000`–`0xC7FFFF` | 512 KB | VRAM window (FPGA BRAM) | 0–1 |
| `0xD00000`–`0xDFFFFF` | 1 MB | Sample RAM window (SDRAM, later) | variable |
| `0xE00000`–`0xE0FFFF` | 64 KB | Video and audio registers, palette, sprites | 0–1 |
| `0xF00000`–`0xF0FFFF` | 64 KB | System: UART, timers, interrupt controller, SD, keyboard | 0–1 |
| `0xFFFFF0`–`0xFFFFFF` | — | Reserved for interrupt-acknowledge cycles | — |
| everything else | | Unmapped: `/BERR` after a timeout | — |

Reset overlay: the CPU reads its first two vectors from ROM at address 0. A write to a system register turns the overlay off, so SRAM can hold a writable vector table at 0.

### D6. Video (first version)

- 640×480 @ 60 Hz with a 25 MHz pixel clock. DVI/TMDS encoding is done in the FPGA, with the ECP5 DDR outputs running at 125 MHz.
- **Mode 0:** 80×30 text with an 8×16 font in BRAM and 16 colours (the monitor and BASIC console).
- **Mode 1:** 640×480 at 4 or 8 bits per pixel, from a 256-entry palette of 24-bit colours.
- **Mode 2:** 320×240 at 8bpp with pixel doubling (games).
- Hardware scroll registers, a vertical-blank interrupt and a raster-line interrupt.
- **Later:** sprites, then a blitter, with VRAM moved to SDRAM if BRAM runs out.
- The CPU and video each get their own port on the dual-port BRAM, so the CPU never waits for the display.

### D7. Audio (first version)

- 4 channels at first, each with 8- or 16-bit samples, a start address, a length, a loop point, a pitch step and a volume. The mixer runs at 48 kHz.
- **Stage 1:** samples come from a small BRAM area, and the CPU can also feed a FIFO.
- **Stage 2:** samples come from SDRAM through the sample RAM window. This is what makes 4–8 full-size channels practical.
- Output goes through a sigma-delta DAC to the ULX3S audio jack, and later to an I2S DAC (PCM5102A) on the PCB.
- The CPU never has to give up its bus, so there is no DMA from main SRAM. This keeps the bus logic simple.

### D8. Interrupts

| Level | Source |
|-------|--------|
| 7 | NMI button |
| 6 | System timer |
| 5 | Video (vblank, raster line) |
| 4 | Audio (channel end / FIFO low) |
| 3 | UART |
| 2 | Keyboard, SD |

All interrupts are autovectored: the FPGA asserts `/VPA` during the interrupt-acknowledge cycle.

### D9. Tools and languages

- **HDL:** plain Verilog-2005, which Yosys handles best. No vendor IP.
- **Simulation:** Verilator for the full system and Icarus Verilog plus cocotb for block tests.
- **Soft CPU for simulation:** fx68k, a cycle-accurate 68000 core, so the whole system, including real boot code, can run in simulation before the CPU board exists.
- **68000 software:** `vasm` for the boot ROM, `m68k-elf-gcc` later, and EhBASIC (68000 port) as the BASIC.
- **CI:** GitHub Actions with the OSS CAD Suite runs lint, block tests and a full synthesis plus place-and-route timing check on every push.
- **PCB:** KiCad 8.

## 3. Specs to write before code

Each block gets a short spec first: its interface, registers, timing and a test plan. RTL is written against that spec.

1. `docs/spec/bus-interface.md`: CPU bus timing, DTACK/BERR rules, synchronisers, wait-state table
2. `docs/spec/memory-map.md`: the final version of D5
3. `docs/spec/registers.md`: every register, its address and bit layout
4. `docs/spec/video.md`: timing, modes, VRAM layout, palette, interrupts
5. `docs/spec/audio.md`: channel registers, mixer, sample format
6. `docs/spec/system.md`: UART, timer, interrupt controller, reset and overlay
7. `docs/spec/cpu-board.md`: schematic-level description, header pinout, power

## 4. Phases

Each phase ends with a test that shows it is done.

| Phase | Work | Done when |
|-------|------|-----------|
| **0. Plan** | This document, decisions agreed, specs 1–3 written | Decisions D1–D9 signed off |
| **1. FPGA bring-up** | Toolchain, CI, ULX3S blinky, HDMI test pattern, UART echo | Test pattern on a monitor; CI green |
| **2. Simulated computer** | fx68k + bus interface + boot ROM + text mode + UART in Verilator | Boot ROM prints "hello" on the simulated screen and UART |
| **3. Soft-CPU on hardware** (optional) | Same design with fx68k inside the ECP5 | Same result on a real monitor |
| **4. CPU board** | KiCad schematic and layout for 68SEC000 + SRAM + header, design review, order | Board assembled; power and clock check out |
| **5. Real-CPU bring-up** | FPGA runs the real CPU from the BRAM ROM; SRAM test; serial monitor | Monitor prompt over UART; full SRAM test passes at 12.5 MHz, then 20 MHz |
| **6. Video** | Bitmap modes, palette, scroll, interrupts; then sprites | Demo program runs all modes |
| **7. Audio** | PCM channels from BRAM, then SDRAM | 4-channel module-style playback |
| **8. Home computer** | SD card, keyboard, EhBASIC | Boot to BASIC, load and save a program |
| **9. Final PCB** | One board: CPU, SRAM, ECP5, HDMI, audio, SD, keyboard | Everything from phases 5–8 works on the single board |

## 5. Risks and open questions

| # | Item | Plan |
|---|------|------|
| Q1 | GPIO count on the ULX3S headers vs. 53 needed | Check the ULX3S schematic before the CPU board design starts; fallback in D3 |
| Q2 | MC68SEC000 availability, price and package (64-pin QFP, fine pitch) | Check distributors; hand-solderable with care, or use assembly service |
| Q3 | Signal integrity of the bus over header connectors at 20 MHz | Short direct mating (CPU board plugs straight onto ULX3S), ground pins, series resistors on clock |
| Q4 | Keyboard: USB host on the ULX3S vs. a PS/2 connector on the CPU board | Decide in phase 8; PS/2 is far simpler in logic |
| Q5 | 85F board cost and availability vs. 45F | If only 45F, start with 320×240 / 4bpp modes and move VRAM to SDRAM sooner |
| Q6 | Colour depth stored in the palette (24-bit vs 12-bit) | 24-bit; BRAM cost is trivial |
| Q7 | Do we want an emulator (e.g. based on Musashi) for software work? | Nice to have; fx68k simulation may be enough at first |

## 6. Next step

Review this document. Once D1–D9 are agreed or changed, write specs 1–3 (bus interface, memory map, register map). Those are needed before any RTL.
