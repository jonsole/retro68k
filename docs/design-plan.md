# retro68k design plan

Status: **draft for review**. Nothing in `fpga/`, `firmware/` or `hardware/` gets built until the decisions below are agreed and each block has a written spec.

## Main path

The computer is built in two stages:

1. **Main path: everything on the miniSpartan6+.** The 68000 is the fx68k core running inside the FPGA, and main RAM is in the board's SDRAM. No extra hardware is needed, so video, sound and software can all be developed and used on the board you already have.
2. **Later upgrade: a real MC68SEC000 board.** A small plug-on board with the real CPU and fast SRAM. The FPGA design and the software stay the same; a build option swaps the internal core for the external CPU.

Sections marked *(CPU board)* only apply to stage 2.

## 1. Requirements

| # | Requirement | Source |
|---|-------------|--------|
| R1 | CPU is a 68000: the fx68k core inside the FPGA first, a real MC68SEC000 (3.3 V, 16-bit bus) as a later upgrade | decided |
| R2 | Main memory runs with zero wait states: Chip RAM (SDRAM) with Amiga-style even/odd slots on the main path, plus fast SRAM (Fast RAM) on the CPU board | project goal |
| R3 | Video, audio and glue logic are done by an FPGA | project goal |
| R4 | Video output is HDMI/DVI with a programmable pixel clock and timing: 640×480 up to 1280×720, 50 or 60 Hz | decided |
| R5 | Audio is 4–8 PCM sample channels (Amiga-style) | decided |
| R6 | Usable as a home computer: boots to a monitor, then BASIC; keyboard; SD card | decided ("both") |
| R7 | Usable as a game/demo machine: sprites, scrolling, later a blitter | decided ("both") |
| R8 | First hardware = the miniSpartan6+ on its own; a plug-on CPU board later; one combined PCB at the end | decided |

## 2. Key decisions

### D1. Dev board: Scarab miniSpartan6+ with XC6SLX25 (the board already owned)

What the board provides, checked against Scarab's Rev B schematic and pin file ([github.com/scarabhardware/miniSpartan6-plus](https://github.com/scarabhardware/miniSpartan6-plus)):

| Feature | Detail | Used for |
|---------|--------|----------|
| FPGA | XC6SLX25-FT256: ~24k logic cells, 52 × 18 Kb block RAM (~117 KB), 38 DSP slices | Everything |
| GPIO | **64 pins** (ports A, B, C, E, F × 12, port D × 4), all I/O banks at **3.3 V** | Keyboard, joypads, debug; CPU bus later |
| SDRAM | Winbond 16M×16 (32 MB) | Main RAM, video memory, audio samples |
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

The FPGA decodes addresses, drives `/DTACK`, encodes interrupts and generates the CPU clock and reset. It does this the same way for the internal core and the external CPU, so the memory map can change without new hardware and no glue chips are needed.

- **The boot ROM lives in FPGA block RAM** (32 KB), loaded with the bitstream.
- With the internal core, the CPU bus is just signals inside the FPGA, so everything is synchronous and simple to simulate.
- *(CPU board)* The FPGA holds the external CPU in reset until it has finished loading its configuration. All FPGA banks are 3.3 V, like the 68SEC000, so no level shifters are needed.

### D3. *(CPU board)* CPU board ↔ FPGA pin budget

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
- On the main path all 64 pins are free, for a PS/2 keyboard, joypads, buttons and a logic-analyser debug port.
- Fast signals (clock, strobes) go on the ports with the shortest traces and plenty of ground pins. The exact assignment goes in the CPU board spec.

### D4. Clocks

- The 50 MHz oscillator feeds the FPGA PLLs.
- **System clock: 100 MHz.** Bus logic, SDRAM controller and most registers run on it.
- **Pixel clock: programmable, about 25–74.25 MHz** (spec 4, section 3), made by a DCM_CLKGEN that can be reprogrammed at run time plus a PLL. The HDMI bit clock is 10× the pixel clock, made with the Spartan-6 OSERDES2 serialisers (the XAPP495 method, which Scarab's HDMI example also uses). Video runs in its own clock domain, separate from the memory slot grid.
- **CPU speed: 12.5 MHz first**, the speed of a fast 1980s 68000. fx68k is driven by a master clock plus two "phase enable" inputs, so its speed is set by those enables. Spec 1 confirms the exact clocking and how fast fx68k meets timing on the LX25; 16–20 MHz may be possible later.
- *(CPU board)* The external CPU gets a 12.5 MHz clock from the PLL, rising to 20 MHz (the 68SEC000's rating) once the bus is proven. The FPGA samples its bus at 100 MHz through two-flop synchronisers. This adds about 20 ns, well inside the ~100 ns a zero-wait-state cycle at 20 MHz allows before `/DTACK` must be seen.

### D5. Memory architecture and memory map

Defined in [spec 5: memory architecture](spec/memory-architecture.md). In short:

- **Amiga-style slots.** SDRAM time is cut into 80 ns slots (one 68000 clock). Even slots belong to the CPU, odd slots to DMA. Each DMA engine (refresh, audio, sprites, video, storage) owns fixed odd slots in every scan line. Unused slots go to the copper and blitter.
- **The CPU never waits** for video or audio, and runs at full speed from Chip RAM.
- **Chip RAM** = the 32 MB SDRAM, shared with DMA. **Fast RAM** = 2 MB SRAM on the later CPU board, CPU-only.

| Range | Size | Device |
|-------|------|--------|
| `0x000000`–`0x7FFFFF` | 8 MB | Chip RAM (boot ROM overlays address 0 at reset) |
| `0x800000`–`0x9FFFFF` | 2 MB | Chip RAM bank window into the rest of the 32 MB |
| `0xA00000`–`0xBFFFFF` | 2 MB | Fast RAM (CPU board only) |
| `0xE00000`–`0xE0FFFF` | 64 KB | Custom registers: video, audio, DMA, blitter, copper |
| `0xE10000`–`0xE13FFF` | 16 KB | Text screen and font (block RAM) |
| `0xF00000`–`0xF0FFFF` | 64 KB | System: USB serial, timers, interrupts, SD, keyboard |
| `0xF80000`–`0xF87FFF` | 32 KB | Boot ROM (block RAM) |

Before the SDRAM controller exists (phase 3), the first 16 KB of Chip RAM is temporarily block RAM (see D11).

### D6. Video

Defined in [spec 4: video](spec/video.md). In short:

- DVI over HDMI with a **programmable pixel clock and timing**: presets from 640×480 to 1280×720 at 50 or 60 Hz, including standard 576p and 720p
- **4 layers + sprites + background colour**, in any priority order. Each layer has its own display window, source address, stride, scroll, scale and palette block
- Layer types: chunky bitmaps at 1/2/4/8 bits per pixel from Chip RAM, or a text layer from block RAM
- Free scaling in 1/256-pixel steps (2×, 4×, odd sizes)
- Fetch is worked out automatically from the windows: 640 bytes per line normally, 1280 with wide fetch, using only DMA slots, so the CPU is never slowed
- 1024-entry palette of 24-bit colours; beam position registers; vertical-blank and line interrupts

### D7. Audio

- 4 channels at first, each with 8- or 16-bit samples, a start address, a length, a loop point, a pitch step and a volume. The mixer runs at 48 kHz.
- Samples are read from SDRAM. Until the SDRAM controller exists, a small block-RAM FIFO that the CPU fills is used for testing.
- Output goes through a sigma-delta DAC to the board's audio jack. An I2S DAC (PCM5102A) can be added on the final PCB.
- Audio and video read the SDRAM directly; the CPU never gives up its bus. This keeps the bus logic simple.

### D8. Interrupts

| Level | Source |
|-------|--------|
| 7 | NMI button |
| 6 | System timer |
| 5 | Video (vblank, raster line) |
| 4 | Audio (channel end / FIFO low) |
| 3 | USB serial |
| 2 | Keyboard, SD |

Interrupts are **vectored**: during the interrupt-acknowledge cycle the FPGA puts a vector number on the data bus and asserts `/DTACK`. Autovectoring through `/VPA` is not used, because its slow E-clock cycle would knock the CPU off the even-slot grid (spec 5, section 5).

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
- **This is the main path.** The whole computer runs on the miniSpartan6+ with no extra hardware.
- **The same bus interface serves both CPUs.** The FPGA logic talks to a 68000 bus, whether the CPU is fx68k inside the chip or the real 68SEC000 on the headers. A build option chooses which one.
- **ISE cannot read SystemVerilog**, so fx68k goes through sv2v, a free converter, during the build. The conversion worked without errors. Yosys reported one latch in `rowDecoder`, which needs checking.
- **fx68k is GPL-3.0.** It will be added as a git submodule under `fpga/third_party/fx68k`. Any FPGA bitstream that includes it is covered by the GPL. The real 68SEC000 build does not use it.
- **The memory map is the same for both CPUs.** Only what sits behind the main RAM range changes (SDRAM or fast SRAM).

### D11. Block RAM budget

The LX25 has 52 blocks of 18 Kb (2 KB each).

| Item | Blocks | Notes |
|------|--------|-------|
| fx68k microcode | 3 | From the trial synthesis (D10) |
| Boot ROM, 32 KB | 16 | |
| Video: line buffers, palette, text buffer and font | 12 | Spec 4, section 7 |
| Sprite line buffers | 2 | Estimate; sprite spec to confirm |
| Audio FIFOs | 1 | Estimate |
| SDRAM and USB FIFOs | 2 | Estimate |
| **Subtotal** | **36** | |
| Temporary 16 KB RAM (phase 3 only) | 8 | Removed once Chip RAM is in SDRAM |
| **Total in phase 3** | **44 of 52** | |

If the budget gets tight, the boot ROM can shrink to 16 KB and load the rest (e.g. BASIC) from the SD card.

## 3. Specs to write before code

Each block gets a short spec first: its interface, registers, timing and a test plan. RTL is written against that spec.

1. `docs/spec/bus-interface.md`: fx68k clocking and phase enables, internal bus timing, DTACK/BERR rules, wait-state table; later the external-CPU timing
2. `docs/spec/memory-map.md`: the final version of D5
3. `docs/spec/registers.md`: every register, its address and bit layout
4. [`docs/spec/video.md`](spec/video.md): **drafted.** Timing, layers, windows, fetch, palette, interrupts
5. [`docs/spec/memory-architecture.md`](spec/memory-architecture.md): **drafted.** Slots, SDRAM timing, CPU zero-wait scheme, DMA slot table, DMACON
6. `docs/spec/audio.md`: channel registers, mixer, sample format
7. `docs/spec/system.md`: USB serial, timer, interrupt controller, reset and overlay
8. *(CPU board)* `docs/spec/cpu-board.md`: schematic-level description, header pinout onto ports A–F, power. Written at the start of phase 8.

## 4. Phases

Each phase ends with a test that shows it is done.

| Phase | Work | Done when |
|-------|------|-----------|
| **0. Plan** | This document, decisions agreed, specs 1–3 written | Decisions D1–D11 signed off |
| **1. FPGA bring-up** | ISE VM and scripted build, CI for simulation, blinky, HDMI test pattern, USB FIFO echo | Test pattern on a monitor; characters echo over USB |
| **2. Simulated computer** | fx68k + bus interface + boot ROM + 16 KB block-RAM main RAM + text layer + USB serial, in Verilator | Boot ROM prints "hello" on the simulated screen and serial port |
| **3. Computer on the board** | The same design built for the LX25 | "hello" on a real HDMI monitor and over USB |
| **4. SDRAM + monitor** | SDRAM controller with the even/odd slot scheduler; Chip RAM moves to SDRAM; boot monitor (memory dump/edit, load over USB, run) | Full RAM test passes with zero wait states; programs load and run over USB |
| **5. Video** | Bitmap modes, palette, scroll, interrupts; then sprites | Demo program runs all modes |
| **6. Audio** | PCM channels reading from SDRAM | 4-channel module-style playback |
| **7. Home computer** | SD card, PS/2 keyboard, EhBASIC | Boot to BASIC, load and save a program |
| **8. Real CPU board** *(upgrade)* | KiCad design for 68SEC000 + 2 MB fast SRAM + headers; review, order, bring-up | All software from phases 4–7 runs unchanged on the real CPU at 12.5 MHz, then 20 MHz |
| **9. Final PCB** | One board: CPU (or FPGA-only), RAM, FPGA, HDMI, audio, SD, keyboard | Everything from phases 3–8 works on the single board |

## 5. Risks and open questions

| # | Item | Plan |
|---|------|------|
| Q1 | How fast fx68k runs on the LX25 (it reaches about 40 MHz master clock on Intel/Altera chips) | Check in phase 3 with an ISE timing report; 12.5 MHz is the safe target |
| Q2 | Can the SDRAM controller really give the CPU zero wait states alongside video? | Slot timing checked against the W9825G6 datasheet in spec 5; still to prove in simulation with fx68k's real bus timing (spec 5, M1) |
| Q3 | fx68k is SystemVerilog and ISE only reads Verilog; Yosys flagged one latch in `rowDecoder` | sv2v conversion is part of the build; check the latch and run fx68k's own tests in phase 2 |
| Q4 | ISE 14.7 is old and no longer updated | Keep the build scripted inside a VM image; keep RTL portable (D9) so the final PCB can use a newer FPGA |
| Q5 | PS/2 keyboards are 5 V devices; the FPGA pins are 3.3 V | Small level-shifter or resistor network on a pin adapter; many keyboards also work at 3.3 V. Decide in phase 7 |
| Q6 | Is the FT2232H channel B already set to parallel FIFO mode on this board? | Check the EEPROM settings with FT_Prog in phase 1 |
| Q7 | FPGA for the final PCB: stay on Spartan-6, or move to ECP5 / Artix-7 | Decide in phase 9; newer parts give more RAM and open tools |
| Q8 | *(CPU board)* MC68SEC000 availability, price and package (64-pin QFP, fine pitch) | Check before phase 8; hand-solderable with care, or use an assembly service |
| Q9 | *(CPU board)* Signal integrity of the bus over header pins at 20 MHz | Board mates directly onto the headers, ground pins next to clock and strobes, series resistors on the clock |
| Q10 | *(CPU board)* Physical fit: the board has to reach headers on several sides of the miniSpartan6+ | Measure header positions from the Rev B board file before the layout |

## 6. Next step

Review this document. Once D1–D11 are agreed or changed, write specs 1–3 (bus interface, memory map, register map). Those are needed before any RTL.
