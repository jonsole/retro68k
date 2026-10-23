# Handoff

State of the project on 23 October 2026, after the per-layer palettes and the first Vivado build, for picking the work up in a new session (VS Code, or a fresh Claude session). Read this first, then `docs/design-plan.md` for the whole plan.

## What retro68k is

An Amiga-style 68000 computer on the ZX Spectrum Next KS3 board (Xilinx XC7A35T, 4 MB SRAM): fx68k at 20 MHz, 576p video over HDMI and VGA, a copper, sprites, 4-channel audio, serial over an FT232H. The specs are in `docs/spec/`, the programming guide (Amiga Hardware Reference Manual style) in `docs/guide/`.

## Working rules

- Commit and push straight to `main` of `jonsole/retro68k`. No pull requests unless asked.
- Author: `Jon Sole <jon.sole@gmail.com>` (`git -c user.name="Jon Sole" -c user.email="jon.sole@gmail.com" commit ...`).
- Claude's commits end with a `Co-Authored-By:` trailer (and the session link, if the session gives one). No model names anywhere else in the repo.
- Check CI (GitHub Actions, `.github/workflows/checks.yml`) after each push. A full run takes about 35 minutes.
- Every hardware change: spec first (`docs/spec/`), then RTL, then the test, then the guide.
- Run the tests before pushing RTL; CI does not run the video tests (see below).
- Keep the design under about 85% of the LUTs by Vivado's count, so it routes at 100 MHz. Yosys (the CI check) counts about 35% more than Vivado; it only fails CI past 100%.
- Run the Vivado build after RTL changes: timing at 100 MHz is met with little margin (+0.26 ns).

## Tools

| Tool | Notes |
|------|-------|
| Icarus Verilog 12 or 13 | `iverilog`, `vvp`. CI uses 12; 13 is stricter (no use before declaration) |
| sv2v | Converts fx68k from SystemVerilog. Release v0.0.13 from github.com/zachjs/sv2v |
| vasm | Build from the vendored copy: `tar xzf tools/vasm/vasm.tar.gz && make -C vasm CPU=m68k SYNTAX=mot`, then put `vasm/` on `PATH` (`vasmm68k_mot`) |
| Python 3 | Pillow for the PNG output (optional) |
| Yosys | For the size check (`fpga/ks3/yosys_check.sh`). Its LUT count runs high: Vivado's is about 25% lower |
| Vivado | 2026.1. `VIVADO=/c/AMDDesignTools/2026.1/Vivado/bin/vivado.bat bash fpga/ks3/build.sh`. Builds a bitstream (`fpga/ks3/build/retro68k_ks3.bit`), about 13 minutes; timing met. Not tried on the board yet |

### Windows

The tools are installed on Jon's Windows machine: MSYS2 (`C:/msys64`, UCRT64 packages: gcc, make, iverilog, yosys, python, python-pillow), sv2v in `C:/tools/sv2v/sv2v-Windows`, vasm built into `C:/tools/vasmsrc/vasm`. All are on the user PATH. Run the Makefiles from an MSYS2 shell (`C:/msys64/usr/bin/bash.exe -l`, with `/ucrt64/bin` first on the PATH), not with Chocolatey's `make`. The repo is checked out with `core.autocrlf=false`: the Python tools need LF files.

## Building and testing

All from `sim/` unless noted. See `sim/README.md` for more options.

| Command | What it checks | Time | In CI |
|---------|---------------|------|-------|
| `python3 tools/regmap.py --verify` (repo root) | `fpga/regmap.def` against `docs/spec/registers.md` and the generated `hw.inc`, `hw.h`, `regmap.vh` | seconds | yes |
| `make run ARGS=+serial` | Boot ROM self-test, serial echo, BREAK and RESET | 5–20 min | yes |
| `make run ARGS=+dma` | Boot ROM with the DMA port busy | 5–20 min | yes |
| `make ctest` | Copper: self-checking ROM, then 14 colour changes checked in the frame (`ctest/ccheck.py`) | 10–40 min | yes |
| `make atest` | Audio: every output sample against a Python model | 10 min | yes |
| `make vtest` | Video: four screens (`pal`, `direct`, `spr`, `share`) checked pixel by pixel against `vtest/vmodel.py`; `make vtest VTESTS=spr` runs one. Each palette gets different colours; `share` is `spr` with VIDCON.SHAREPAL | 10–45 min each | **no** |
| `bash fpga/ks3/yosys_check.sh` (repo root) | Synthesis for the XC7A35T and the LUT count | 3 min | yes |

`make BUILD=other_dir ...` builds into another directory, so a second set of runs can go alongside the first. Run long simulations in the background, one per directory: two runs in the same `build/vtest_x` directory overwrite each other's results. Edit `regmap.def`, then run `python3 tools/regmap.py` to regenerate the headers; never edit `hw.inc`, `hw.h` or `regmap.vh` by hand.

Debug switches in `sim/tb.v`, added while bringing up sprites:
- `+sprdbg`: sprite fetcher state at each frame start, and counts of acks, words and opaque pixels at the end.
- `+xstop`: stops at the first unknown (`x`) value on the sprite channel to the scheduler, and dumps the state.
- `+timeout=N`: the run's time limit in ps.

## Where things stand

Done and tested:

| Part | Files | Tests |
|------|-------|-------|
| CPU, bus, SRAM, scheduler (`dmac.v`), boot ROM | `fpga/rtl/`, `firmware/boot/boot.s` | boot |
| Video: 3 layers, planar/chunky, scaling, scroll, BPLSTRIDE, priority, direct colour, a palette per layer and one for the sprites (SHAREPAL for one) | `video.v`, `bpldma.v`, `layer_pix.v` | vtest pal, direct, share |
| Copper v1: MOVE/WAIT/SKIP/JUMP, MOVR, ALU, SKIPC, CALL/RET, RESUME | `copper.v`, `firmware/include/copper.inc` | ctest |
| Audio v1: 4 channels, 8/16-bit, pan, interpolation, start/stop strobes | `audio.v` | atest |
| Sprites v1: 8 sprites, any size, 2/4/8 bpp, ×1/2/4 magnify, depth, collisions, FIFO per sprite | `sprites.v`, `sprite_pix.v`, `video.v` | vtest spr |
| Beam coordinates for every position | all of the above | all of the above |
| Serial, interrupts, timers | `serial.v`, `intc.v`, `timers.v` | boot |

Size: 12,771 LUTs (61%) by Vivado, 12.5 of 50 block RAMs; about 17,400 (84%) by Yosys. Timing met at 100 MHz, worst slack +0.26 ns (sprite deadlines, audio).

### Recent decisions to know about

- **Beam coordinates** (spec 4, section 3.3). (0, 0) is the start of the horizontal and vertical blanks, so the picture is beam pixels 144–863 and lines 49–624. `hw.inc` has `VID_X0` = 144, `VID_Y0` = 49, `VID_W`, `VID_H`, `BEAM_W`, `BEAM_H`. The frame starts at (0, 0), where the copper restarts, VBLANK fires and sprites restart. Copper positions only go up through a frame. `CWAIT n,0` is the start of line n's blank and `CWAITP 0` each line's. Layer settings (CTRL, window, scroll) for line n must be written before line n starts; colours, BGCOLOR and PRIO can still change in line n's blank.
- **Sprites** have unsigned positions and are clipped by the hardware at all four edges (they can hang up to 144 px off the left and 49 lines off the top). They have no flips: HFLIP and VFLIP were dropped to save logic. SPRxPT must be written last, because any write to PT, H, V or CTL restarts the sprite from its pointer. A sprite should not start on beam lines 0–1.
- **Area technique.** Per-channel state in distributed RAM, worked on one channel a clock (as in `bpldma.v` and `sprites.v`), rather than flip-flop arrays with wide muxes. Use it for anything with 8 copies.

## Next jobs

In rough order:

1. **Try the bitstream on the board**: HDMI and VGA at 576p, the boot ROM's console, the serial link (`fpga/ks3/README.md` says what to expect). Timing was closed on 23 October 2026 by:
   - `sprites.v`: the fetch pick is a registered "wants a word" check and a tree of pairs (a FIFO counts as full at 30 words, spec 9 section 4); the size calculator is two stages;
   - `bpldma.v`: a fetch takes two clocks (pick and read the pointer, then update it), with a holding place so a word every 2 clocks is still possible;
   - `audio.v`: each multiply has its own clock;
   - `intc.v`: the pending requests are registered (10 ns more latency, spec 13) and the level search is parallel;
   - `retro68k.v`: the system reset is copied by Vivado (`max_fanout`).
2. **DMA engine**: spec 11 needs its v1 rewrite, then the RTL. The scheduler already has its channel (`blt_*` in `dmac.v`).
3. **SD card and keyboard** (spec 16 for the keyboard).
4. **Trims**, if room is needed (less pressing now that Vivado counts 62%): timers, the audio engine, the copper's storage registers.
5. **Small items**:
   - wire the 68000 RESET instruction;
   - ROMLOCK in the boot ROM;
   - the serial link surviving a reset (spec).
6. **Guide chapters** for audio, the DMA engine, SD and the keyboard.
7. **Optional**: the TG68K 68020 option (`docs/tg68k-feasibility.md`).

### Known gaps

- The video tests are not in CI: they are slow. Consider adding `make vtest VTESTS=spr` as its own CI job.
- `fpga/ks3/README.md` still describes version 1 without sprites, copper and sound; bring it up to date with the first working bitstream.
- Sprite open points (spec 9, section 9):
  - S1: measure the memory budget table in simulation;
  - S2: whether sprites' share of free cycles should be capped.
- No sprite manual-mode (SPRxDAT) test yet, and no test of reusing a sprite down the screen.
