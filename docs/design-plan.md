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
| R2 | Fast main memory: Chip RAM (SDRAM) with Amiga-style even/odd slots, where the CPU rarely waits; plus zero-wait Fast RAM (SRAM) on the CPU board | project goal |
| R3 | Video, audio and glue logic are done by an FPGA | project goal |
| R4 | Video output is HDMI/DVI; pixel clock is a whole-number division of one master clock, timing programmable: 640×480 up to 1280×720, 50 or 60 Hz; DMA locked to the beam | decided |
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
| SDRAM | Winbond 16M×16 (32 MB) | 8 MB of Chip RAM: main RAM, video memory, audio samples |
| HDMI | 1 out, 1 in | Display |
| USB | FT2232H: channel A = JTAG, channel B = 8-bit parallel FIFO to the FPGA | Programming; host link / serial console |
| Storage | microSD slot (4-bit) | Storage |
| Audio | Stereo jack driven by 2 FPGA pins (1-bit sigma-delta) | Sound |
| Clocks | 50 MHz and 32 MHz oscillators | PLL input |
| Other | 8 LEDs, 4 switches, 8-channel ADC, SPI config flash | Debug |

Consequences compared to the earlier ECP5 plan:
- **Block RAM is only ~117 KB**, so a full 640×480×8bpp frame buffer (300 KB) cannot live inside the FPGA. Video memory goes in the **SDRAM**. The text mode, fonts and palette stay in block RAM. Video data is fetched by DMA just in time as the beam scans, with no line buffers.
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

- **One master clock, as on the Amiga.** A PLL, set once at power-on, makes a 200 MHz master from the 50 MHz oscillator. Everything else is the master divided by a whole number:
  - **System / SDRAM: 100 MHz** (÷ 2)
  - **68000: 20 MHz** (fx68k clocked at 40 MHz, ÷ 5, with alternating phase enables)
  - **Memory slot: 100 ns = 2 CPU clocks** (÷ 20), the Amiga's ratio
  - **Pixel clock: ÷ N, N = 3–8 (66.7–25 MHz)**, programmable
- Every scan line is a whole, even number of slots, so DMA is locked to the beam in every video mode (spec 4, section 3.2).
- A second PLL works only as a ×10 multiplier for the HDMI serialisers (OSERDES2, XAPP495 method), following the divided pixel clock.
- **Fallback:** 40 MHz is near fx68k's top speed (Q1). If the LX25 can't reach it, fx68k runs at 33.3 MHz (÷ 6) for a 16.7 MHz 68000, with 120 ns slots. Spec 1 confirms the exact fx68k clocking.
- *(CPU board)* The external CPU gets a 20 MHz clock (master ÷ 10), its rated speed. The FPGA samples its bus at 100 MHz through two-flop synchronisers. This adds about 20 ns, well inside the ~100 ns a zero-wait-state cycle at 20 MHz allows before `/DTACK` must be seen.

### D5. Memory architecture and memory map

Defined in [spec 5: memory architecture](spec/memory-architecture.md). In short:

- **Amiga-style slots.** SDRAM time is cut into 100 ns slots (two 68000 clocks). Even slots belong to the CPU, odd slots to DMA; the CPU may also use odd slots DMA leaves free. Each DMA engine (refresh, audio, sprites, video, storage) owns fixed odd slots in every scan line. Unused slots go to the copper and blitter.
- **The 20 MHz CPU rarely waits.** It loses 2 clocks only when an access lands on a busy DMA slot, or when a sprite about to be late borrows its slot, as on the Amiga.
- **Chip RAM** = 8 MB of the SDRAM, shared with DMA. **Fast RAM** = 2 MB SRAM on the later CPU board, CPU-only.

| Range | Size | Device |
|-------|------|--------|
| `0x000000`–`0x7FFFFF` | 8 MB | Chip RAM (boot ROM overlays address 0 at reset) |
| `0x800000`–`0x9FFFFF` | 2 MB | Reserved |
| `0xA00000`–`0xBFFFFF` | 2 MB | Fast RAM (CPU board only) |
| `0xE00000`–`0xE0FFFF` | 64 KB | Custom registers: video, audio, DMA, blitter, copper |
| `0xE10000`–`0xE13FFF` | 16 KB | Text screen and font (block RAM) |
| `0xF00000`–`0xF0FFFF` | 64 KB | System: USB serial, timers, interrupts, SD, keyboard |
| `0xF80000`–`0xF87FFF` | 32 KB | Boot ROM (block RAM) |

Before the SDRAM controller exists (phase 3), the first 16 KB of Chip RAM is temporarily block RAM (see D11).

### D6. Video

Defined in [spec 4: video](spec/video.md). In short:

- DVI over HDMI; **pixel clock = 200 MHz ÷ N** with programmable timing: presets from 640×480 to 1280×720 at 50 or 60 Hz. DMA is locked to the beam in every mode
- **4 layers + 64 sprites (16 per line) + background colour**, in any priority order. Each layer has its own display window, source address, stride, scroll, scale and palette block
- Layer types: chunky bitmaps at 1/2/4/8 bits per pixel from Chip RAM, or a text layer from block RAM
- Free scaling in 1/256-pixel steps (2×, 4×, odd sizes)
- Video memory is fetched on demand by DMA as the beam scans, Amiga-style, with no line buffers. Fetch timing is worked out from the windows; the budget is a rate in bytes per pixel (1 normally at 640×480, 2 with wide fetch). Layers only use DMA slots, so they never slow the CPU. Sprites are also fetched just before their X position, and borrow a CPU slot only when needed
- 1024-entry palette of 24-bit colours; beam position registers; vertical-blank and line interrupts

### D7. Audio

Defined in [spec 6: audio](spec/audio.md). In short:

- **16 hardware channels** in one shared engine: 16- or 8-bit samples, any pitch, stereo volume, loops, queued next sample; no CPU work while they play
- **16-tap windowed-sinc resampling** (about −105 dB aliasing), optional pre-filtered octave copies for clean pitch-ups, and a per-channel Amiga-style "nearest" mode
- **A 16-bit stereo stream** from a ring buffer in Chip RAM, filled by software. The DMA engine's MIX operation is on hold and may not be needed
- Output rate = 200 MHz ÷ D (48 kHz by default), 16-bit mixer, sigma-delta DAC to the board's audio jack; an I2S DAC can be added on the final PCB

### D8. Interrupts

| Level | Source |
|-------|--------|
| 7 | NMI button |
| 6 | System timer |
| 5 | Video (vblank, raster line), copper |
| 4 | Audio (channel end / FIFO low), DMA engine (job done, error) |
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
| Video: palette, text buffer and font | 8 | Spec 4, section 7. No line buffers; layer buffers and sprite registers are built from logic |
| Sprite table | 1 | Spec 9 |
| DMA descriptor RAM | 1 | Spec 11 |
| Audio: filter coefficients (2), sample caches and stream FIFO (1) | 3 | Spec 6, section 7 |
| SDRAM and USB FIFOs | 2 | Estimate |
| **Subtotal** | **34** | |
| Temporary 16 KB RAM (phase 3 only) | 8 | Removed once Chip RAM is in SDRAM |
| **Total in phase 3** | **42 of 52** | |

If the budget gets tight, the boot ROM can shrink to 16 KB and load the rest (e.g. BASIC) from the SD card.

## 3. Specs to write before code

Each block gets a short spec first: its interface, registers, timing and a test plan. RTL is written against that spec.

1. `docs/spec/bus-interface.md`: fx68k clocking and phase enables, internal bus timing, DTACK/BERR rules, wait-state table; later the external-CPU timing
2. `docs/spec/memory-map.md`: the final version of D5
3. `docs/spec/registers.md`: every register, its address and bit layout
4. [`docs/spec/video.md`](spec/video.md): **drafted.** Timing, layers, windows, fetch, palette, interrupts
5. [`docs/spec/memory-architecture.md`](spec/memory-architecture.md): **drafted.** Slots, SDRAM timing, CPU access at 20 MHz, DMA slot table, DMACON
6. [`docs/spec/audio.md`](spec/audio.md): **drafted.** 16 hardware channels with 16-tap sinc resampling, stereo stream, mixer, sigma-delta output
7. `docs/spec/system.md`: USB serial, timer, interrupt controller, reset and overlay
8. *(CPU board)* `docs/spec/cpu-board.md`: schematic-level description, header pinout onto ports A–F, power. Written at the start of phase 8.
9. [`docs/spec/sprites.md`](spec/sprites.md): **drafted.** Sprite table, formats, scaling, depth, just-in-time fetch, collision
10. [`docs/spec/copper.md`](spec/copper.md): **drafted.** Beam-following coprocessor: MOVE, MOVEN, ADD, WAIT, WAITH, SKIP, JUMP, CALL/RET, loops, IRQ, WAITDMX
11. [`docs/spec/dma-engine.md`](spec/dma-engine.md): **drafted.** DMA engine and blitter: 4 channels, descriptor chains, copy/fill/colour-key/logic/add in 1D and 2D, MIX for audio voices (on hold), peripheral ports

## 4. Phases

Each phase ends with a test that shows it is done.

| Phase | Work | Done when |
|-------|------|-----------|
| **0. Plan** | This document, decisions agreed, specs 1–3 written | Decisions D1–D11 signed off |
| **1. FPGA bring-up** | ISE VM and scripted build, CI for simulation, blinky, HDMI test pattern, USB FIFO echo | Test pattern on a monitor; characters echo over USB |
| **2. Simulated computer** | fx68k + bus interface + boot ROM + 16 KB block-RAM main RAM + text layer + USB serial, in Verilator | Boot ROM prints "hello" on the simulated screen and serial port |
| **3. Computer on the board** | The same design built for the LX25 | "hello" on a real HDMI monitor and over USB |
| **4. SDRAM + monitor** | SDRAM controller with the even/odd slot scheduler; Chip RAM moves to SDRAM; boot monitor (memory dump/edit, load over USB, run) | Full RAM test passes at 20 MHz; programs load and run over USB |
| **5. Video** | Bitmap modes, palette, scroll, interrupts; then sprites | Demo program runs all modes |
| **6. Audio** | PCM channels reading from SDRAM | 4-channel module-style playback |
| **7. Home computer** | SD card, PS/2 keyboard, EhBASIC | Boot to BASIC, load and save a program |
| **8. Real CPU board** *(upgrade)* | KiCad design for 68SEC000 + 2 MB fast SRAM + headers; review, order, bring-up | All software from phases 4–7 runs unchanged on the real CPU at 20 MHz |
| **9. Final PCB** | One board: CPU (or FPGA-only), RAM, FPGA, HDMI, audio, SD, keyboard | Everything from phases 3–8 works on the single board |

## 5. Risks and open questions

| # | Item | Plan |
|---|------|------|
| Q1 | Can fx68k run at 40 MHz (a 20 MHz 68000) on the LX25? Its author reports about 40 MHz on Intel/Altera chips, so this is near its limit | Check with an ISE timing report as early as possible (phase 2/3); fallback is 33.3 MHz (16.7 MHz 68000) with 120 ns slots |
| Q2 | How often does the 20 MHz CPU wait for busy DMA slots? | Slot timing checked against the W9825G6 datasheet in spec 5; measure in simulation with fx68k's real bus timing (spec 5, M1 and M9) |
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
