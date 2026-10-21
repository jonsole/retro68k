# retro68k design plan

Status: **draft for review**. Nothing in `fpga/`, `firmware/` or `hardware/` gets built until the decisions below are agreed and each block has a written spec.

## Main path

The whole computer runs on a **ZX Spectrum Next KS3** board (issue 5). The 68000 is the fx68k core inside the board's Artix-7 FPGA, and main RAM is the board's fast SRAM. The only extra hardware is a small FT232H USB module for the serial console and uploads.

The design is installed as an extra core on the Next, next to the normal Next core, so the board keeps working as a Spectrum Next.

## 1. Requirements

| # | Requirement | Source |
|---|-------------|--------|
| R1 | CPU is a 68000: the fx68k core inside the FPGA, at 20 MHz | decided |
| R2 | Fast main memory: Chip RAM in fast SRAM, shared Amiga-style with DMA, where the CPU never waits for display, sound or normal DMA | project goal |
| R3 | Video, audio and glue logic are done by an FPGA | project goal |
| R4 | Video output is HDMI/DVI and VGA; pixel clock is a whole-number division of one master clock, timing programmable: 640×480 up to 1280×720, 50 or 60 Hz; DMA locked to the beam | decided |
| R5 | Audio: 16 PCM sample channels and a stereo stream | decided |
| R6 | Usable as a home computer: boots to a monitor, then BASIC; keyboard; SD card | decided ("both") |
| R7 | Usable as a game/demo machine: sprites, scrolling, a blitter, a copper | decided ("both") |
| R8 | Hardware = the ZX Spectrum Next KS3, already owned | decided |

## 2. Key decisions

### D1. Board: ZX Spectrum Next KS3 (issue 5)

Checked against the official Next FPGA sources (`zxnext_top_issue5.vhd` and `zxnext_pins_issue5.xdc` in [gitlab.com/SpectrumNext/ZX_Spectrum_Next_FPGA](https://gitlab.com/SpectrumNext/ZX_Spectrum_Next_FPGA)):

| Feature | Detail | Used for |
|---------|--------|----------|
| FPGA | Xilinx Artix-7 XC7A35T-2CSG324: 20,800 LUTs, 41,600 flip-flops, 100 × 18 Kb block RAM (225 KB), 90 DSP slices, 5 MMCMs | Everything |
| RAM | IS61WV204816BLL-10: 2M × 16 (4 MB) asynchronous SRAM, 10 ns | Chip RAM: main RAM, video memory, audio samples |
| Video | HDMI straight from the FPGA; VGA through an ADV7125 24-bit video DAC | Display, both at once |
| Audio | 2 pins to the audio jack through a filter, 1 to the internal speaker | Sound (sigma-delta) |
| SD card | One slot, wired for SPI mode only; no card detect | Storage |
| Keyboards | PS/2 keyboard and mouse sockets; the Spectrum membrane keyboard (8 × 7 matrix) | Keyboard; mouse later |
| Joysticks | 2 ports (Atari / Mega Drive style), multiplexed | Later |
| Buttons | Reset, Multiface, DivMMC | Reset, NMI, monitor |
| I2C | Battery-backed real-time clock; HDMI DDC | Clock, monitor detection |
| Accelerator port | 28 GPIO pins (Raspberry Pi Zero header), 3.3 V | FT232H USB module |
| Other | ESP8266 WiFi on a UART; Spectrum edge connector | Not used for now |
| Clock | 50 MHz oscillator | MMCM input |
| Config flash | Core slots: slot 0 anti-brick, slot 1 the Next core, more for other cores | Installing the design |

What this means:
- **The SRAM is fast enough to give the CPU its own memory cycle in every 100 ns slot**, so the CPU never waits for the display, audio, copper or normal DMA (D5). There is no Fast RAM: all RAM is Chip RAM.
- **Block RAM is 225 KB**, still too small for a 640×480×8bpp frame buffer plus everything else, so video memory stays in Chip RAM and is fetched just in time by DMA, as planned. Text mode, fonts and palette stay in block RAM.
- **No LEDs or switches.** The boot ROM shows start-up progress and errors as the screen's background colour (as the Amiga did) and on the serial console. Start-up options come from keys held during reset and the DivMMC button (spec 7).
- **Toolchain is Vivado** (the free edition covers the XC7A35T), scripted with Tcl in batch mode, on Linux or Windows.

### D2. The FPGA is the glue logic

The FPGA decodes addresses, drives `/DTACK`, encodes interrupts and generates the CPU clock and reset. Since the CPU is inside the FPGA, its bus is just signals in the chip: everything is synchronous and simple to simulate, and no glue chips are needed.

- **The boot ROM lives in FPGA block RAM** (32 KB), loaded with the bitstream, and can be made writable for development (spec 7).

### D3. Board connections

| Board part | Pins | Spec |
|------------|------|------|
| SRAM | 21 address, 16 data, /CS, /OE, /WE, /UB, /LB | 5 |
| HDMI | 4 differential pairs | 4 |
| VGA (ADV7125) | 4 pins per colour at double data rate, clock, sync | 4 |
| Audio | `audioext_l`, `audioext_r`, `audioint` | 6 |
| SD card | `sd_sclk`, `sd_mosi`, `sd_miso`, `sd_cs0` (`sd_cs1` unused) | 15 |
| PS/2 | Keyboard clock and data (mouse later) | 16 |
| Spectrum keyboard | 8 rows out, 7 columns in | 16 |
| Buttons | Reset, Multiface (NMI), DivMMC (monitor) | 7, 13 |
| I2C | SCL, SDA (RTC, HDMI DDC) | 7 |
| Accelerator port | 13 pins for the FT232H module in 245 FIFO mode | 14 |

The full list is in spec 7, section 8.

### D4. Clocks

- **One master clock, as on the Amiga.** An MMCM, set once at power-on, makes a 200 MHz master from the 50 MHz oscillator. Everything else is the master divided by a whole number:
  - **System / SRAM controller: 100 MHz** (÷ 2)
  - **68000: 20 MHz** (fx68k clocked at 40 MHz, ÷ 5, with alternating phase enables)
  - **Memory cycle: 20 ns** (÷ 4); **slot: 100 ns = 5 memory cycles = 2 CPU clocks** (÷ 20), the Amiga's ratio
  - **Pixel clock: ÷ N, N = 3–8 (66.7–25 MHz)**, programmable
- Every scan line is a whole number of slots (HTOTAL × N a multiple of 20), so DMA is locked to the beam in every video mode (spec 4, section 3.2).
- A second MMCM works only as a multiplier for the HDMI serialisers (OSERDESE2), following the divided pixel clock. The VGA DAC is clocked from the pixel clock.

### D5. Memory architecture and memory map

Defined in [spec 5: memory architecture](spec/memory-architecture.md). In short:

- **Amiga-style slots.** SRAM time is cut into 100 ns slots of 5 memory cycles (20 ns, 2 bytes each). **Cycle 0 of every slot belongs to the CPU**; cycles 1–4 belong to DMA: display fetch, fixed audio and peripheral cycles, and a free pool for sprites, audio top-ups, the copper and the DMA engine. Unused CPU cycles go to the free pool too.
- **The 20 MHz CPU never waits** for display, audio, the copper or normal DMA. It loses 2 clocks only when software runs a HIGH DMA job (always leaving the CPU its share) or when an urgent sprite or copper fetch borrows its cycle.
- **Chip RAM** = the 4 MB SRAM, shared with DMA. 100 MB/s in total.

| Range | Size | Device |
|-------|------|--------|
| `0x000000`–`0x3FFFFF` | 4 MB | Chip RAM (boot ROM overlays address 0 at reset) |
| `0x400000`–`0xDFFFFF` | | Reserved (bus error) |
| `0xE00000`–`0xE0FFFF` | 64 KB | Custom registers: video, audio, DMA engine, copper |
| `0xE10000`–`0xE13FFF` | 16 KB | Text screen and font (block RAM) |
| `0xF00000`–`0xF0FFFF` | 64 KB | System: USB serial, timers, interrupts, SD, keyboard, I2C |
| `0xF80000`–`0xF87FFF` | 32 KB | Boot ROM (block RAM) |

Some boards may have 2 MB of SRAM; SYSCFG.CHIPMB reports which (spec 7).

### D6. Video

Defined in [spec 4: video](spec/video.md). In short:

- DVI over HDMI and VGA at the same time; **pixel clock = 200 MHz ÷ N** with programmable timing: presets from 640×480 to 1280×720 at 50 or 60 Hz. DMA is locked to the beam in every mode
- **4 layers + 64 sprites (16 per line) + background colour**, in any priority order. Each layer has its own display window, source address, stride, scroll, scale and palette block
- Layer types: chunky bitmaps at 1/2/4/8 bits per pixel from Chip RAM, or a text layer from block RAM
- Free scaling in 1/256-pixel steps (2×, 4×, odd sizes)
- Video memory is fetched on demand by DMA as the beam scans, Amiga-style, with no line buffers. The budget is a rate in bytes per pixel: 0.2 × N normally, 0.3 × N with wide fetch (1.6 and 2.4 at 640×480). Layers never use the CPU's cycle. Sprites are fetched just before their X position (spec 9)
- 1024-entry palette of 24-bit colours; beam position registers; vertical-blank and line interrupts; a copper (spec 10)

### D7. Audio

Defined in [spec 6: audio](spec/audio.md). In short:

- **16 hardware channels** in one shared engine: 16- or 8-bit samples, any pitch, stereo volume, loops, queued next sample; no CPU work while they play
- **16-tap windowed-sinc resampling** (about −105 dB aliasing), optional pre-filtered octave copies for clean pitch-ups, and a per-channel Amiga-style "nearest" mode
- **A 16-bit stereo stream** from a ring buffer in Chip RAM, filled by software. The DMA engine's MIX operation is on hold and may not be needed
- Output rate = 200 MHz ÷ D (48 kHz by default), 16-bit mixer, sigma-delta DAC to the KS3's audio jack and internal speaker; HDMI audio later

### D8. Interrupts

Defined in [spec 13: interrupt controller](spec/interrupts.md). Every source has its own vector and a programmable level. Default levels:

| Level | Sources |
|-------|---------|
| 7 | NMI: Multiface button, USB "break" |
| 6 | Timers 0–3 |
| 5 | Video: vertical blank, line compare, copper, video errors |
| 4 | DMA engine channels 0–3; audio stream, channels, errors |
| 3 | USB serial |
| 2 | SD card, keyboard |
| 1 | Software interrupt |

Interrupts are **vectored**: during the interrupt-acknowledge cycle the FPGA puts a vector number on the data bus and asserts `/DTACK`. Autovectoring through `/VPA` is not used: its slow E-clock cycle would only waste time.

### D9. Tools and languages

- **HDL:** plain Verilog-2005 so the design moves easily to another FPGA later.
- **Chip-specific parts go in small wrapper modules** in `fpga/rtl/platform/artix7/`: MMCMs, OSERDESE2 for HDMI, ODDR for the VGA DAC, block RAM, clock buffers and I/O pads. Each wrapper also has a plain behavioural version for simulation.
- **FPGA build:** Vivado (free edition), run from a Tcl script in batch mode, so builds are repeatable and nothing depends on the GUI.
- **Loading:** during development, straight into the FPGA over the KS3's JTAG header (Vivado or openFPGALoader), which leaves the flash alone. Finished builds are installed as a Next core.
- **Simulation:** Verilator for the full system, Icarus Verilog plus cocotb for block tests.
- **Soft CPU:** fx68k, a cycle-accurate 68000 core (see D10).
- **68000 software:** `vasm` for the boot ROM, `m68k-elf-gcc` later, and EhBASIC (68000 port) as the BASIC.
- **Register map:** `fpga/regmap.def` → `tools/regmap.py` → assembler, C and Verilog headers (spec 3, section 6).
- **CI:** GitHub Actions runs the register map check now, and lint (Verilator) and all simulations once there is RTL. FPGA builds happen locally in Vivado.

### D10. A 68000 core inside the XC7A35T

The fx68k core (a cycle-accurate 68000) fits easily. Trial synthesis on 2026-10-20: fx68k converted to Verilog with sv2v and synthesised with Yosys 0.33 (`synth_xilinx -family xc7`):

| Resource | fx68k uses | XC7A35T has | Share |
|----------|-----------|-------------|-------|
| LUTs | ~3,340 | 20,800 | ~16% |
| Flip-flops | ~1,440 | 41,600 | ~3% |
| 18 Kb block RAMs | 3 (microcode) | 100 | 3% |

This is a Yosys estimate; Vivado's results will differ somewhat. On ECP5 (nextpnr) fx68k reached 62 MHz on the slowest speed grade and 81 MHz on the fastest; the Artix-7 -2 is faster still, so 40 MHz has a large margin.

- **Vivado reads SystemVerilog**, so fx68k may not even need sv2v; the converted version is kept for Verilator, Icarus and Yosys. Yosys reported one latch in `rowDecoder`, which needs checking.
- **fx68k is GPL-3.0.** It will be added as a git submodule under `fpga/third_party/fx68k`. Any bitstream that includes it is covered by the GPL.

**Logic budget estimate:** fx68k ~3.3k LUTs, video and sprites 4–5k, audio 1–1.3k, DMA engine 1.5–2k, copper 0.5k, SRAM controller and bus interface 0.5k, system blocks (timers, interrupts, serial, SD, keyboard, I2C) 1–1.5k: about **12–16.5k LUTs (58–79%)**.

### D11. Block RAM budget

The XC7A35T has 100 blocks of 18 Kb (2 KB each).

| Item | Blocks | Notes |
|------|--------|-------|
| fx68k microcode | 3 | From the trial synthesis (D10) |
| Boot ROM, 32 KB | 16 | |
| Video: palette, text buffer and font | 8 | Spec 4, section 7. No line buffers; layer buffers and sprite registers are built from logic |
| Sprite table | 1 | Spec 9 |
| DMA descriptor RAM | 1 | Spec 11 |
| Audio: filter coefficients (2), sample caches and stream FIFO (1) | 3 | Spec 6, section 7 |
| USB serial FIFOs | 2 | Spec 14 |
| SD card FIFO | 1 | Spec 15 |
| **Total** | **35 of 100** | |

The SRAM works from the first build, so no temporary block-RAM main memory is needed. The spare blocks leave room for a bigger boot ROM, larger audio caches or a second filter table (spec 6, A2).

## 3. Specs to write before code

Each block gets a short spec first: its interface, registers, timing and a test plan. RTL is written against that spec.

1. [`docs/spec/bus-interface.md`](spec/bus-interface.md): **drafted.** fx68k at 40 MHz with phase enables, fixed-point 40/100 MHz crossing, bus cycle timing, decoding, wait states, bus errors, interrupt acknowledge, reset and halt
2. Memory map: folded into spec 3
3. [`docs/spec/registers.md`](spec/registers.md): **drafted.** Memory map, rules for all registers (32-bit, written and read as 16-bit halves), every register address in the custom and system blocks
4. [`docs/spec/video.md`](spec/video.md): **drafted.** Timing, layers, windows, fetch, palette, interrupts, HDMI and VGA
5. [`docs/spec/memory-architecture.md`](spec/memory-architecture.md): **drafted.** Slots and memory cycles, SRAM timing, CPU access at 20 MHz, fixed cycles per line, DMACON
6. [`docs/spec/audio.md`](spec/audio.md): **drafted.** 16 hardware channels with 16-tap sinc resampling, stereo stream, mixer, sigma-delta output
7. [`docs/spec/system.md`](spec/system.md): **drafted.** Reset sources and behaviour, boot ROM and overlay, start-up keys and colours, buttons, ID registers, I2C master, installing as a Next core, board connections (timers are spec 12, interrupts 13, USB serial 14, SD card 15, keyboard 16)
8. ~~CPU board~~: dropped with the move to the KS3
9. [`docs/spec/sprites.md`](spec/sprites.md): **drafted.** Sprite table, formats, scaling, depth, just-in-time fetch, collision
10. [`docs/spec/copper.md`](spec/copper.md): **drafted.** Beam-following coprocessor with 4-byte instructions: MOVE, MOVEN, ADD, WAIT, WAITH, SKIP, JUMP, CALL/RET, loops, IRQ, WAITDMX
11. [`docs/spec/dma-engine.md`](spec/dma-engine.md): **drafted.** DMA engine and blitter: 4 channels, descriptor chains, copy/fill/colour-key/logic/add in 1D and 2D, MIX for audio voices (on hold), peripheral ports
12. [`docs/spec/timers.md`](spec/timers.md): **drafted.** 64-bit time counter, 4 chainable 32-bit timers (clock, lines, frames), interrupts or DMA starts, watchdog
13. [`docs/spec/interrupts.md`](spec/interrupts.md): **drafted.** 24 sources with their own vectors and programmable levels, NMI from the Multiface button and USB break, software interrupt
14. [`docs/spec/serial.md`](spec/serial.md): **drafted.** FT232H module on the accelerator port in 245 FIFO mode: console and uploads at several MB/s, hardware flow control, DMA port, BREAK/RESET/UPLOAD commands from the PC
15. [`docs/spec/sd-card.md`](spec/sd-card.md): **drafted.** SPI-mode SD host: commands with CRC, 512-byte blocks, multi-block with auto-stop, about 3 MB/s, DMA port
16. [`docs/spec/keyboard.md`](spec/keyboard.md): **drafted.** PS/2 keyboard and the Spectrum membrane keyboard as one: decoded key events, 512-bit key map, commands with acknowledge, Ctrl + Alt + Delete reset

## 4. Phases

Each phase ends with a test that shows it is done.

| Phase | Work | Done when |
|-------|------|-----------|
| **0. Plan** | This document, decisions agreed, specs written | Decisions D1–D11 signed off |
| **1. FPGA bring-up** | Vivado scripted build, CI for simulation, JTAG loading, HDMI and VGA test pattern, USB FIFO echo through the FT232H | Test pattern on a monitor; characters echo over USB |
| **2. Simulated computer** | fx68k + bus interface + SRAM controller (with an SRAM model) + boot ROM + text layer + USB serial, in Verilator | Boot ROM prints "hello" on the simulated screen and serial port |
| **3. Computer on the board** | The same design built for the KS3; boot monitor (memory dump/edit, load over USB, run) | "hello" on a real monitor and over USB; full 4 MB RAM test passes at 20 MHz with display on |
| **4. Video** | Bitmap layers, palette, scroll, interrupts; then sprites and the copper | Demo program runs all modes |
| **5. Audio** | 16 channels and the stream | Module-style playback |
| **6. DMA engine** | Copies, fills, blits, peripheral ports | Speed figures of spec 11 measured on the board |
| **7. Home computer** | SD card, PS/2 and Spectrum keyboards, real-time clock, EhBASIC | Boot to BASIC, load and save a program |
| **8. Next core** | Package the design as a Next core and install it in a flash slot | The KS3 boots the 68000 computer from its core menu, and still boots the Next |

## 5. Risks and open questions

| # | Item | Plan |
|---|------|------|
| Q1 | Does fx68k meet 40 MHz in Vivado with the multicycle constraints? | Very likely (62–81 MHz on ECP5); check with a Vivado trial build in phase 0/1 (spec 1, B1) |
| Q2 | Are 20 ns SRAM read and write cycles safe on the KS3's wiring? | Check against the datasheet (spec 5, M2); test on the board in phase 3. Fallback: slower cycles and fewer per slot |
| Q3 | Does the KS3 have 4 MB or 2 MB of SRAM? | Check the board (spec 5, M3); the design handles both |
| Q4 | Core format and slot size for an XC7A35T bitstream (about 2.2 MB) in the Next's flash | Check the Next's core-installation docs before phase 8 (spec 7, SY5); JTAG loading is used until then |
| Q5 | A JTAG cable for the KS3's header | Use a Xilinx-compatible cable (e.g. Digilent HS2, or an FT232H-based one with openFPGALoader) |
| Q6 | SPI-mode SD is slower than the native 4-bit bus (about 3 MB/s) | Enough for loading programs; try "high speed" SPI later (spec 15, SD2) |
| Q7 | Accelerator port pins for the FT232H: which 13 pins, and is the port's wiring good enough for 245 FIFO timing? | Check the Next's pin file and test the echo in phase 1 (spec 14, U1) |
| Q8 | fx68k: one latch in `rowDecoder` reported by Yosys | Check and run fx68k's own tests in phase 2 |

## 6. Next step

All the planning specs are drafted (section 3). To finish phase 0:

1. Review the decisions (D1–D11) and specs, and change anything that doesn't feel right.
2. Do the early checks that could change the design:
   - **fx68k at 40 MHz in Vivado** (Q1, spec 1 open point B1): a trial build for the XC7A35T-2 with the multicycle constraints, reading the timing report.
   - **SRAM size and timing** (Q2, Q3): read the chip marking on the KS3; check the datasheet timings.
   - **FT232H module and JTAG cable** (Q5, Q7): get them, and pick the accelerator port pins.
   - **Next core format** (Q4): read how third-party cores are installed on the KS3.
3. ~~Write the register-map generator.~~ Done: `fpga/regmap.def` and `tools/regmap.py` (spec 3, section 6).

**Phase 2 has started** (it needs no board): fx68k, the bus interface, the SRAM controller, boot ROM, system registers and USB serial run in Icarus Verilog (`sim/`). The boot ROM prints its checks over the simulated serial link with zero CPU wait states, also while a DMA port uses every other memory cycle. The interrupt controller and video version 1 (timing, palette, text layer, VBLANK interrupt) are in too, so the boot ROM's output also appears on the simulated screen: **phase 2 is done in simulation** (`docs/images/phase2-boot.png`). Next: bitmap layers with the display fetch, then timers, and the Vivado build for the KS3 (phase 3).

Then phase 1 (FPGA bring-up) starts: scripted Vivado build, JTAG loading, HDMI/VGA test pattern and USB echo.
