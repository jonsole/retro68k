# retro68k

A homebrew Motorola 68000 computer with fast, zero-wait-state SRAM and an FPGA handling video and audio.

## Goals

- **CPU:** MC68000 (or 68HC000 / 68SEC000) at 12–20 MHz
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

## Memory map (draft)

| Range                   | Size  | Device                          |
|-------------------------|-------|---------------------------------|
| `0x000000`–`0x0FFFFF`   | 1 MB  | Boot ROM (mirrored at reset)    |
| `0x100000`–`0x8FFFFF`   | 8 MB  | Main SRAM                       |
| `0xC00000`–`0xDFFFFF`   | 2 MB  | FPGA: VRAM window               |
| `0xE00000`–`0xEFFFFF`   | 1 MB  | FPGA: video/audio registers     |
| `0xF00000`–`0xFFFFFF`   | 1 MB  | I/O (UART, SD, keyboard, timer) |

At reset the 68000 reads its stack pointer and start address from `0x000000`, so ROM is mapped there first. The glue logic can switch SRAM in at low addresses after boot so the vector table can live in RAM.

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
