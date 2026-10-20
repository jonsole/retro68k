# retro68k

A homebrew Motorola 68000 computer with fast, zero-wait-state SRAM and an FPGA handling video and audio.

## Goals

- **CPU:** MC68SEC000 (3.3 V) at 12.5–20 MHz
- **Memory:** fast asynchronous SRAM, no wait states, no DRAM refresh logic
- **ROM:** flash boot ROM with a monitor
- **Video + audio:** one FPGA that the CPU sees as memory-mapped registers and VRAM
- **I/O:** UART, SD card, PS/2 or USB keyboard, timers, interrupts
- Easy to build: 2–4 layer PCB, parts you can still buy

## Block diagram

```
            +-----------+       address / data / control bus        +------------------+
 Clock ---> |  MC68000  |<==========================================>|  FPGA (video +   |---> VGA / HDMI
 Reset ---> |  (16-bit) |        |              |          |        |  audio + glue)   |---> I2S / PWM audio
            +-----------+        |              |          |        +------------------+
                  ^              v              v          v                 |
                  |        +----------+   +----------+  +-------+     +-------------+
                  +--------| Boot ROM |   |  SRAM    |  |  I/O  |     | Video SRAM  |
              IPL / DTACK  | (flash)  |   | (fast)   |  | UART, |     | (FPGA side) |
                           +----------+   +----------+  | SD... |     +-------------+
                                                       +-------+
```

## Design plan

Decisions, memory map, phases and open questions are in [`docs/design-plan.md`](docs/design-plan.md). Main choices so far: **MC68SEC000** CPU, **Lattice ECP5** FPGA (ULX3S dev board first), HDMI 640×480, PCM sample audio, aimed at both a home computer and a game machine.

## Repository layout

| Folder              | Contents                                       |
|---------------------|------------------------------------------------|
| `docs/`             | Design notes, memory map, timing, parts list   |
| `hardware/kicad/`   | Schematic and PCB                              |
| `fpga/rtl/`         | Verilog for video, audio and bus interface     |
| `firmware/boot/`    | 68000 assembly boot ROM / monitor              |
| `tools/`            | Build scripts, ROM flashing, serial loader     |

## Toolchain

- **68000 code:** `vasm` (Motorola syntax) or `m68k-elf-gcc`
- **FPGA:** Yosys + nextpnr (open source) for iCE40 / ECP5, or the vendor tools
- **PCB:** KiCad 8+
- **Emulation:** MAME or a custom emulator to test firmware before hardware

## Roadmap

1. [ ] Minimal board: 68000, ROM, SRAM, UART — blink an LED and print "hello"
2. [ ] Boot monitor: memory dump, load over serial, jump
3. [ ] FPGA bus interface: CPU can read/write FPGA registers
4. [ ] Text-mode video, then bitmap modes and sprites
5. [ ] Audio: PCM channels and/or a synthesizer
6. [ ] SD card, file system, keyboard
7. [ ] Final PCB

## License

MIT — see `LICENSE`.
