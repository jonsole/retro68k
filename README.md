# retro68k

A homebrew Motorola 68000 computer with Amiga-style shared memory and an FPGA handling video and audio. It starts as a 68000 core inside the FPGA and later gains a real 68SEC000 CPU board.

## Goals

- **CPU:** 68000 at 20 MHz: the fx68k core inside the FPGA first (16.7 MHz fallback), then a real MC68SEC000 (3.3 V, 20 MHz)
- **Memory:** Amiga-style Chip RAM (SDRAM shared with DMA in fixed slots), plus CPU-only Fast RAM on the later CPU board
- **ROM:** boot ROM with a monitor, held in FPGA block RAM
- **Video + audio:** one FPGA that the CPU sees as memory-mapped registers and VRAM
- **I/O:** UART, SD card, PS/2 or USB keyboard, timers, interrupts
- Easy to build: 2–4 layer PCB, parts you can still buy

## Block diagram (with the later CPU board)

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

Decisions, memory map, phases and open questions are in [`docs/design-plan.md`](docs/design-plan.md). Main choices so far: a **68000 core inside the FPGA** first, a real **MC68SEC000** later, **Xilinx Spartan-6 LX25** FPGA on a Scarab miniSpartan6+ dev board first, HDMI 640×480, PCM sample audio, aimed at both a home computer and a game machine.

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
- **FPGA:** Xilinx ISE 14.7 WebPACK (Spartan-6); simulation with Verilator and Icarus Verilog
- **PCB:** KiCad 8+
- **Emulation:** MAME or a custom emulator to test firmware before hardware

## Roadmap

The 68000 starts as a core inside the FPGA, so the whole computer runs on the miniSpartan6+ board alone. A real 68SEC000 board comes later. Details are in [`docs/design-plan.md`](docs/design-plan.md).

1. [ ] FPGA bring-up: HDMI test pattern, USB serial echo
2. [ ] Whole computer in simulation: prints "hello"
3. [ ] Computer on the board: "hello" on an HDMI monitor
4. [ ] SDRAM main memory and a boot monitor
5. [ ] Video: bitmap modes, palette, scrolling, sprites
6. [ ] Audio: PCM sample channels
7. [ ] Home computer: SD card, keyboard, BASIC
8. [ ] Upgrade: real 68SEC000 CPU board with fast SRAM
9. [ ] Final PCB

## License

MIT — see `LICENSE`.
