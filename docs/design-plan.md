# retro68k design plan

Status: **draft for review**. Nothing in `fpga/`, `firmware/` or `hardware/` gets built until the decisions below are agreed and each block has a written spec.

## 1. Requirements

| # | Requirement | Source |
|---|-------------|--------|
| R1 | CPU is a real MC68SEC000 (3.3 V, 16-bit bus mode) | decided |
| R2 | Main memory is fast async SRAM with zero wait states | project goal |
| R3 | Video, audio and glue logic are done by an FPGA | project goal |
| R4 | Video output is HDMI/DVI at 640×480 @ 60 Hz | decided |
| R5 | Audio is 4–8 PCM sample channels (Amiga-style) | decided |
| R6 | Usable as a home computer: boots to a monitor, then BASIC; keyboard; SD card | decided ("both") |
| R7 | Usable as a game/demo machine: sprites, scrolling, later a blitter | decided ("both") |
| R8 | First hardware = existing FPGA dev board + a small custom CPU board; one combined PCB later | decided |

## 2. Key decisions

### D1. Dev board: Scarab miniSpartan6+ with XC6SLX25 (the board already owned)

What the board provides, checked against Scarab's Rev B schematic and pin file ([github.com/scarabhardware/miniSpartan6-plus](https://github.com/scarabhardware/miniSpartan6-plus)):

| Feature | Detail | Used for |
|---------|--------|----------|
| FPGA | XC6SLX25-FT256: ~24k logic cells, 52 × 18 Kb block RAM (~117 KB), 38 DSP slices | Everything |
| GPIO | **64 pins** (ports A, B, C, E, F × 12, port D × 4), all I/O banks at **3.3 V** | CPU bus |
| SDRAM | Winbond 16M×16 (32 MB) | Video memory, audio samples |
| HDMI | 1 out, 1 in | Display |
| USB | FT2232H: channel A = JTAG, channel B = 8-bit parallel FIFO to the FPGA | Programming; host link / serial console |
| Storage | microSD slot (4-bit) | Storage |
| Audio | Stereo jack driven by 2 FPGA pins (1-bit sigma-delta) | Sound |
| Clocks | 50 MHz and 32 MHz oscillators | PLL input |
| Other | 8 LEDs, 4 switches, 8-channel ADC, SPI config flash | Debug |

Consequences compared to the earlier ECP5 plan:
- **Block RAM is only ~117 KB**, so a full 640×480×8bpp frame buffer (300 KB) cannot live inside the FPGA. Video memory goes in the **SDRAM**. The text mode, fonts, palette and line buffers stay in block RAM.
- **Toolchain is Xilinx ISE 14.7 WebPACK** (free, supports the LX25). It is old and closed-source, and is best run in a Linux VM; AMD supplies a ready-made ISE VM. There are no open-source place-and-route tools for Spartan-6.

### D2. The FPGA is the glue logic

The FPGA generates the CPU clock and reset, decodes addresses, drives `/DTACK`, encodes interrupts and selects the SRAM. This means no CPLD and no 74-series glue chips, and the memory map can change without new hardware.

- The FPGA holds the CPU in reset until it has finished loading its configuration.
- **The boot ROM lives in FPGA block RAM** (32 KB), loaded with the bitstream. This avoids a flash chip on the CPU board.
- All FPGA banks are 3.3 V, like the 68SEC000, so no level shifters are needed.

### D3. CPU board ↔ FPGA pin budget

| Signals | Pins |
|---------|------|
| A1–A23 | 23 |
| D0–D15 | 16 |
| /AS, /UDS, /LDS, R/W, /DTACK | 5 |
| FC0–FC2 | 3 |
| /IPL0–2 | 3 |
| /RESET, /HALT, CLK, /BERR, /VPA | 5 |
| SRAM /CE | 1 |
| **Total** | **56 of 64** (8 spare) |

- **FC0–2 are connected.** The FPGA can then recognise interrupt-acknowledge cycles cleanly, and can tell supervisor accesses from user ones if memory protection is wanted later.
- **Bus arbitration is not used:** /BR and /BGACK are pulled high on the CPU board.
- **SRAM control lines are wired directly to the CPU:** /UB ← /UDS, /LB ← /LDS, /WE ← R/W, and /OE tied low. Writes are timed by /UDS and /LDS. Spec 1 must check this against the SRAM datasheet's timing.
- The spare pins are kept for a PS/2 keyboard, a reset/NMI button and debug signals.
- Fast signals (clock, strobes) go on the ports with the shortest traces and plenty of ground pins. The exact assignment goes in spec 7.

### D4. Clocks

- The 50 MHz oscillator feeds the FPGA PLLs.
- **System clock: 100 MHz.** Bus logic, SDRAM controller and most registers run on it.
- **Pixel clock: 25 MHz.** HDMI bit clock: 250 MHz, made with the Spartan-6 OSERDES2 serialisers (the standard XAPP495 method, which Scarab's HDMI example also uses).
- **CPU clock: 12.5 MHz first** (50 ÷ 4), **aiming for 20 MHz** once the bus is proven. The 68SEC000 is rated up to 20 MHz.
- The FPGA samples the CPU bus at 100 MHz through two-flop synchronisers. This adds about 20 ns, well inside the ~100 ns a zero-wait-state cycle at 20 MHz allows before `/DTACK` must be seen.

### D5. Memory map (proposed)

| Range | Size | Device | Wait states |
|-------|------|--------|-------------|
| `0x000000`–`0x007FFF` | 32 KB | Boot ROM (FPGA BRAM); overlays RAM at reset | 0 |
| `0x100000`–`0x2FFFFF` | 2 MB | Main SRAM (1M×16, e.g. IS61WV102416, 10 ns) | 0 |
| `0xC00000`–`0xDFFFFF` | 2 MB | SDRAM window (video memory and samples); a bank register selects which 2 MB of the 32 MB | variable |
| `0xE00000`–`0xE0FFFF` | 64 KB | Video and audio registers, palette, sprites | 0–1 |
| `0xE10000`–`0xE13FFF` | 16 KB | Text-mode screen and font (FPGA BRAM) | 0–1 |
| `0xF00000`–`0xF0FFFF` | 64 KB | System: USB serial, timers, interrupt controller, SD, keyboard | 0–1 |
| everything else | | Unmapped: `/BERR` after a timeout | — |

Reset overlay: the CPU reads its first two vectors from ROM at address 0. A write to a system register turns the overlay off, so SRAM can hold a writable vector table at 0.

SDRAM accesses from the CPU take a variable time because they share the SDRAM with video and audio. The FPGA simply holds `/DTACK` until the access is done. Video fetches have top priority.

### D6. Video

- 640×480 @ 60 Hz, DVI signalling over the HDMI connector.
- **Mode 0:** 80×30 text with an 8×16 font and 16 colours. Lives entirely in block RAM, so it works before the SDRAM controller exists (monitor and BASIC console).
- **Mode 1:** 640×480 at 4 or 8 bits per pixel, read from SDRAM, using a 256-entry palette of 24-bit colours.
- **Mode 2:** 320×240 at 8bpp with pixel doubling (games), read from SDRAM.
- Hardware scroll registers, a vertical-blank interrupt and a raster-line interrupt.
- **Later:** sprites (line buffers in block RAM), then a blitter working in SDRAM.
- **SDRAM bandwidth check:** a 16-bit SDRAM at 100 MHz gives about 200 MB/s peak. 640×480×8bpp at 60 Hz needs about 25 MB/s during the visible part of each line, so well over half the bandwidth is left for the CPU, audio and blitter.

### D7. Audio

- 4 channels at first, each with 8- or 16-bit samples, a start address, a length, a loop point, a pitch step and a volume. The mixer runs at 48 kHz.
- Samples are read from SDRAM. Until the SDRAM controller exists, a small block-RAM FIFO that the CPU fills is used for testing.
- Output goes through a sigma-delta DAC to the board's audio jack. An I2S DAC (PCM5102A) can be added on the final PCB.
- The CPU never gives up its bus, so there is no DMA from main SRAM. This keeps the bus logic simple.

### D8. Interrupts

| Level | Source |
|-------|--------|
| 7 | NMI button |
| 6 | System timer |
| 5 | Video (vblank, raster line) |
| 4 | Audio (channel end / FIFO low) |
| 3 | USB serial |
| 2 | Keyboard, SD |

All interrupts are autovectored: the FPGA asserts `/VPA` during the interrupt-acknowledge cycle (FC = 111).

### D9. Tools and languages

- **HDL:** plain Verilog-2005 so the design moves easily to another FPGA later.
- **Chip-specific parts go in small wrapper modules** in `fpga/rtl/platform/spartan6/`: PLL, OSERDES2 for HDMI, block RAM, clock buffers and I/O pads. Each wrapper also has a plain behavioural version for simulation. Moving to ECP5 or Artix-7 later only means writing new wrappers.
- **FPGA build:** Xilinx ISE 14.7 WebPACK, run from a script (`xtclsh`/command-line) in a VM, so builds are repeatable and nothing depends on the ISE GUI.
- **Simulation:** Verilator for the full system, Icarus Verilog plus cocotb for block tests.
- **Soft CPU:** fx68k, a cycle-accurate 68000 core, used in simulation and on the FPGA itself (see D10).
- **68000 software:** `vasm` for the boot ROM, `m68k-elf-gcc` later, and EhBASIC (68000 port) as the BASIC.
- **CI:** GitHub Actions runs lint (Verilator) and all simulations on every push. FPGA builds happen locally in the ISE VM, because ISE cannot reasonably run in CI.
- **PCB:** KiCad 8.

### D10. A 68000 core inside the LX25

The fx68k core (a cycle-accurate 68000) fits comfortably in the LX25. Trial synthesis on 2026-10-20: fx68k was converted to Verilog with sv2v and synthesised with Yosys 0.33 for Spartan-6 (`synth_xilinx -family xc6s`):

| Resource | fx68k uses | LX25 has | Share |
|----------|-----------|----------|-------|
| LUTs | ~3,350 | 15,032 | ~22% |
| Flip-flops | ~1,440 | 30,064 | ~5% |
| 18 Kb block RAMs | 3 (microcode) | 52 | ~6% |

This is a Yosys estimate; ISE's results will differ somewhat, but there is a large margin. About 11,700 LUTs are left for video, audio, the SDRAM controller and glue logic.

What this means for the plan:
- **Phase 3 is no longer optional.** The whole computer can run on the miniSpartan6+ with no extra hardware. Video, audio and software work can go ahead while the CPU board is designed and built.
- **The same bus interface serves both CPUs.** The FPGA logic talks to a 68000 bus, whether the CPU is fx68k inside the chip or the real 68SEC000 on the headers. A build option chooses which one.
- **ISE cannot read SystemVerilog**, so fx68k goes through sv2v, a free converter, during the build. The conversion worked without errors. Yosys reported one latch in `rowDecoder`, which needs checking.
- **fx68k is GPL-3.0.** It will be added as a git submodule under `fpga/third_party/fx68k`. Any FPGA bitstream that includes it is covered by the GPL. The real 68SEC000 build does not use it.
- **The memory map stays the same.** Main RAM can live in SDRAM when the soft CPU is used, because the 2 MB fast SRAM is on the CPU board.

## 3. Specs to write before code

Each block gets a short spec first: its interface, registers, timing and a test plan. RTL is written against that spec.

1. `docs/spec/bus-interface.md`: CPU bus timing, DTACK/BERR rules, synchronisers, wait-state table
2. `docs/spec/memory-map.md`: the final version of D5
3. `docs/spec/registers.md`: every register, its address and bit layout
4. `docs/spec/video.md`: timing, modes, memory layout, palette, interrupts
5. `docs/spec/sdram.md`: controller, arbitration between video, audio and CPU, bandwidth budget
6. `docs/spec/audio.md`: channel registers, mixer, sample format
7. `docs/spec/system.md`: USB serial, timer, interrupt controller, reset and overlay
8. `docs/spec/cpu-board.md`: schematic-level description, header pinout onto ports A–F, power

## 4. Phases

Each phase ends with a test that shows it is done.

| Phase | Work | Done when |
|-------|------|-----------|
| **0. Plan** | This document, decisions agreed, specs 1–3 written | Decisions D1–D10 signed off |
| **1. FPGA bring-up** | ISE VM and scripted build, CI for simulation, blinky, HDMI test pattern, USB FIFO echo | Test pattern on a monitor; characters echo over USB |
| **2. Simulated computer** | fx68k + bus interface + boot ROM + text mode + USB serial in Verilator | Boot ROM prints "hello" on the simulated screen and serial port |
| **3. Soft CPU on the board** | Same design with fx68k inside the LX25 (see D10) | Same result on a real monitor; software development can continue on this while the CPU board is built |
| **4. CPU board** | KiCad schematic and layout for 68SEC000 + SRAM + headers, design review, order | Board assembled; power and clock check out |
| **5. Real-CPU bring-up** | FPGA runs the real CPU from the BRAM ROM; SRAM test; serial monitor | Monitor prompt over USB; full SRAM test passes at 12.5 MHz, then 20 MHz |
| **6. SDRAM + video** | SDRAM controller and arbiter; bitmap modes, palette, scroll, interrupts; then sprites | Demo program runs all modes |
| **7. Audio** | PCM channels reading from SDRAM | 4-channel module-style playback |
| **8. Home computer** | SD card, keyboard, EhBASIC | Boot to BASIC, load and save a program |
| **9. Final PCB** | One board: CPU, SRAM, FPGA, HDMI, audio, SD, keyboard | Everything from phases 5–8 works on the single board |

## 5. Risks and open questions

| # | Item | Plan |
|---|------|------|
| Q1 | MC68SEC000 availability, price and package (64-pin QFP, fine pitch) | Check distributors; hand-solderable with care, or use an assembly service |
| Q2 | Signal integrity of the bus over header pins at 20 MHz | CPU board mates directly onto the miniSpartan6+ headers (no cables), ground pins next to the clock and strobes, series resistors on the clock |
| Q3 | Physical fit: the CPU board has to reach headers on several sides of the board | Measure the miniSpartan6+ header positions from the Rev B board file before starting the layout |
| Q4 | ~~Does fx68k fit in the LX25?~~ **Yes.** A trial synthesis uses about 22% of the chip (see D10) | Closed; confirm with a real ISE build in phase 3 |
| Q5 | ISE 14.7 is old and no longer updated | Keep the build scripted inside a VM image; keep RTL portable (D9) so the final PCB can use a newer FPGA |
| Q6 | FPGA for the final PCB: stay on Spartan-6, or move to ECP5 / Artix-7 | Decide in phase 9; Spartan-6 keeps everything proven, newer parts give more RAM and open tools |
| Q7 | Keyboard: PS/2 on a spare pin pair vs. USB | PS/2 is far simpler in logic; decide in phase 8 |
| Q8 | Is the FT2232H channel B already set to parallel FIFO mode on this board? | Check the EEPROM settings with FT_Prog in phase 1 |

## 6. Next step

Review this document. Once D1–D10 are agreed or changed, write specs 1–3 (bus interface, memory map, register map). Those are needed before any RTL.
