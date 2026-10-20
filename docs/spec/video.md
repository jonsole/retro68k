# Spec 4: Video

Status: **draft for review**

## 1. Goals

- DVI output over the HDMI connector at a **programmable pixel clock and timing**, from 640×480 up to 1280×720
- **Four independent layers**, each with its own display window, source address, pixel format, scroll, scale and palette. The Amiga has one display window and one or two playfields
- **Fetch is automatic:** the hardware works out what to fetch from each layer's window, so there are no fetch start/stop registers to keep in step (the Amiga's DDFSTRT/DDFSTOP)
- **Free scaling:** each layer has its own horizontal and vertical step in 1/256ths of a pixel, so 2× and 4× pixels, odd sizes and simple zoom effects all use the same mechanism
- Fully programmable horizontal and vertical timing, with presets for standard modes at 50 and 60 Hz; beam position registers, vertical-blank and line interrupts
- Video runs on its own clock, separate from the memory system. It only uses DMA slots (spec 5), so it never slows the CPU

Sprites, the copper and the blitter get their own specs. This spec defines how sprites slot into the layer priority order.

## 2. Comparison with the Amiga (OCS/ECS)

| Feature | Amiga | retro68k |
|---------|-------|----------|
| Display window | One per screen (DIWSTRT/DIWSTOP) | One per layer, anywhere on screen |
| Playfields | 1, or 2 in dual-playfield mode | Up to 4 layers + sprites, any priority order |
| Pixel layout | Bitplanes (planar) | Chunky: 1, 2, 4 or 8 bits per pixel, packed in bytes |
| Colours | 32 from 4096 (64 with EHB, 4096 with HAM) | 1024-entry palette of 24-bit colours (16.7 M); each layer picks its palette block |
| Fetch control | DDFSTRT/DDFSTOP set by hand | Worked out from each layer's window and scale |
| Line-to-line source step | Modulo (bytes skipped) | Stride (bytes from line to line), signed, so images can be flipped vertically |
| Scrolling | Fine scroll 0–15 px via BPLCON1, plus pointer arithmetic | Scroll X and Y registers per layer, added by hardware |
| Pixel size | Lores/hires (fixed 2:1), line doubling by copper tricks | Any horizontal and vertical step, 1/256 pixel precision |
| Text mode | None | A text layer from block RAM (no SDRAM cost) |
| Video timing | Fixed (OCS); programmable on ECS | Pixel clock, horizontal and vertical timing all programmable |

## 3. Pixel clock, timing, retrace and the beam

### 3.1 Video has its own clock

The video output runs on its own **pixel clock**, separate from the 100 MHz memory clock and the slot grid in spec 5. The two sides meet at the line buffers, which are dual-port block RAM: the fetch engine writes them on the memory clock, and the display reads them on the pixel clock. Changing the pixel clock therefore changes nothing in the memory system.

```
 100 MHz memory side                 │  pixel-clock side
 SDRAM ─▶ fetch engine ─▶ line buffers (dual-port) ─▶ layers ─▶ priority ─▶ palette ─▶ TMDS ─▶ HDMI
             ▲            "line start" signal  ◀──── timing generator
```

### 3.2 Making the pixel clock

- A Spartan-6 **DCM_CLKGEN** makes the pixel clock from the board's 50 MHz oscillator: `pixel clock = 50 MHz × M ÷ D`. The DCM_CLKGEN can load new M and D values while running. A PLL after it cleans up the jitter and makes the ×2 and ×10 clocks the TMDS serialisers need (5:1 DDR serialising, as in Xilinx XAPP495).
- The CPU writes M and D (or picks a preset), with video off. The hardware relocks the clocks and sets PCLKLOCK in VIDSTAT when the new clock is stable.
- **Range:** about 25 MHz to 74.25 MHz. The top end is set by the TMDS lanes: 74.25 MHz is 742.5 Mbit/s per lane, within the Spartan-6 -3 grade's limit of roughly 1 Gbit/s. 1080p at 60 Hz (148.5 MHz) is out of reach on this chip.
- The board's FPGA speed grade still has to be confirmed from the chip marking (open point V7). Scarab's example projects are set up for grade -3.

### 3.3 Programmable timing

All values are in pixels (horizontal) or lines (vertical). `hpixel` counts from 0 at the first visible pixel, `vline` from 0 at the first visible line. Blanking (front porch, sync, back porch) follows the visible part.

| Register | Meaning |
|----------|---------|
| HVISIBLE, HSYNCSTART, HSYNCEND, HTOTAL | Horizontal: visible width, sync position, total pixels per line |
| VVISIBLE, VSYNCSTART, VSYNCEND, VTOTAL | Vertical: visible lines, sync position, total lines per frame |
| SYNCPOL | Horizontal and vertical sync polarity |
| PCLKM, PCLKD | Pixel clock = 50 MHz × M ÷ D |

The timing and clock registers can only be changed while video is off (VIDCON.EN = 0).

Horizontal blanking is the horizontal retrace; lines VVISIBLE to VTOTAL−1 are the vertical retrace.

### 3.4 Presets

The boot ROM has a table of standard modes. Software can also set any timing directly.

| Mode | Pixel clock | Total (H × V) | Refresh | Notes |
|------|-------------|---------------|---------|-------|
| 640×480 | 25.2 MHz | 800 × 525 | 60 Hz | Default at power-on; works on almost any screen |
| 640×480 | 25.0 MHz | 800 × 625 | 50 Hz | Non-standard; test per monitor |
| 720×576 | 27.0 MHz | 864 × 625 | 50 Hz | Standard "576p" PAL-rate TV mode; good for 50 Hz music and demos |
| 720×480 | 27.0 MHz | 858 × 525 | 59.94 Hz | Standard "480p" |
| 800×600 | 40.0 MHz | 1056 × 628 | 60 Hz | VESA |
| 1024×768 | 65.0 MHz | 1344 × 806 | 60 Hz | VESA |
| 1280×720 | 74.25 MHz | 1650 × 750 | 60 Hz | Standard "720p" |
| 1280×720 | 74.25 MHz | 1980 × 750 | 50 Hz | Standard "720p50" |

Some exact clocks are not reachable with M ≤ 256 and D ≤ 256. The nearest one within ±0.5% is used, which screens accept (e.g. 25.2 MHz for VGA's 25.175).

Low-resolution looks (320×240, 360×288 etc.) are made with layer scaling (section 4.5), not by changing the timing. This keeps the screen locked to one mode and lets low- and high-resolution layers be shown together.

### 3.5 Beam position

| Register | Contents |
|----------|----------|
| BEAMPOS (read) | `vline` (bits 26–16), `hpixel` (bits 10–0) as one 32-bit read so they always match |
| FRAMECOUNT (read) | Frame counter, 16-bit, increments at the start of vertical blanking |

### 3.6 Video interrupts

All go through the interrupt controller at level 5 (design plan D8).

| Source | When |
|--------|------|
| VBLANK | Start of vertical blanking (`vline` = VVISIBLE, `hpixel` = 0) |
| LINE | `vline` and `hpixel` match LINECMP, for raster effects without the copper |
| OVERRUN | A layer did not get all its data for a line (section 5.4) |

Each has an enable bit in VIDINTEN and a sticky flag in VIDSTAT, cleared by writing 1.

## 4. Layers

### 4.1 Overview

There are 4 layers (L0–L3), a sprite layer and a background colour. For every pixel, the hardware takes the colour of the highest-priority layer whose pixel is not transparent. If no layer has a pixel there, the background colour shows.

```
 SDRAM ──fetch──▶ line buffers L0..L3 ──┐
                                        ├─▶ priority mux ─▶ palette ─▶ DVI encoder ─▶ HDMI
 block RAM (text) ─▶ text layer ────────┤        ▲
 sprite unit ───────────────────────────┘   PRIO register
```

### 4.2 Layer types and pixel formats

| Type | Source | Formats | SDRAM slots |
|------|--------|---------|-------------|
| Bitmap | Chip RAM (SDRAM) | 1, 2, 4 or 8 bits per pixel, chunky, most significant pixel first in each byte | Yes (section 5) |
| Text | Text buffer in block RAM | 8×16 character cells | None |

Only one layer at a time can be a text layer (there is one text buffer).

Planned for later versions: 16-bit direct colour (RGB565), tile-map layers.

### 4.3 Display window

Each layer has a rectangle: `XSTART ≤ x < XEND`, `YSTART ≤ y < YEND`, in screen pixels and lines. Outside its window a layer is transparent.

- Windows can overlap, sit side by side, or cover only part of the screen. This makes split screens, status bars, picture-in-picture and borders possible without the copper.
- A full-screen layer is simply 0, 0, HVISIBLE, VVISIBLE.

### 4.4 Source address, stride and scroll

For each layer:

| Register | Bits | Meaning |
|----------|------|---------|
| PTR | 25 | Byte address in Chip RAM of the layer's top-left source pixel (before scrolling) |
| STRIDE | 16, signed | Bytes from one source line to the next. Negative values flip the image vertically |
| SCROLLX | 16 | Source pixels skipped at the left |
| SCROLLY | 16 | Source lines skipped at the top |

The address of the first source line is `PTR + SCROLLY × STRIDE`. The first pixel on each line is source pixel `SCROLLX`. Because these are pixel counts, the hardware takes care of fine scrolling at any bit depth. There is no separate fine-scroll register as on the Amiga.

A large virtual screen, for example 2048×1024 at 8bpp with STRIDE = 2048, can be scrolled in any direction just by changing SCROLLX and SCROLLY.

### 4.5 Scaling

| Register | Format | Meaning |
|----------|--------|---------|
| HSTEP | 8.8 fixed point | Source pixels per screen pixel |
| VSTEP | 8.8 fixed point | Source lines per screen line |

| Value | Effect |
|-------|--------|
| `0x0100` | 1:1 |
| `0x0080` | 2× bigger (320×240 fills the screen) |
| `0x0040` | 4× bigger (160×120 fills the screen) |
| `0x0200` | Half size (shows twice as much; costs twice the fetch bandwidth) |
| `0x00C0` | 1.33× bigger (480-pixel-wide image fills 640) |

- Scaling uses nearest-neighbour: no filtering, so pixels stay sharp.
- HSTEP above `0x0100` shrinks the image and fetches more data per line. Section 5 covers the budget.
- VSTEP accumulates per line. When the integer part steps, the source line moves on by STRIDE (or by a multiple of STRIDE for VSTEP ≥ 2).

### 4.6 Transparency and palette

- Each layer has a palette offset (0–1023, in steps of 16). The colour index for a pixel is `offset + pixel value`. This lets a 4bpp layer use any 16-colour block and an 8bpp layer any of the four 256-colour banks.
- If the layer's TRANSP bit is set, pixel value 0 is transparent and lower layers show through. If it is clear, the layer is solid.
- **Palette:** 1024 entries × 24-bit RGB, memory-mapped so the CPU and copper can write any entry at any time. A write takes effect from the next pixel, so mid-line colour changes (copper bars) work.

### 4.7 Text layer

| Item | Value |
|------|-------|
| Character cell | 8×16 pixels |
| Text buffer | 128 columns × 32 rows of 16-bit cells in block RAM (8 KB); 80×30 visible at 640×480. Higher resolutions use a window or 2× scaling, because the buffer is 128×32 cells |
| Cell format | Bits 7–0 character code, bits 11–8 foreground colour, bits 15–12 background colour |
| Font | 256 characters × 16 bytes in block RAM (4 KB), writable, so the font can be redefined |
| Colours | Palette offset + 0–15; with TRANSP set, background colour 0 is transparent so text can sit over graphics |
| Scrolling | SCROLLX/SCROLLY in pixels, wrapping around the 128×32 buffer. A console can scroll by moving SCROLLY a row at a time without copying memory |
| Scaling | HSTEP/VSTEP as for bitmaps (e.g. `0x0080` horizontally for 40 columns) |

The text layer uses PTR as the cell offset into the text buffer, and ignores STRIDE.

### 4.8 Priority

The PRIO register lists the order of the four layers and where sprites sit:

| Bits | Field | Meaning |
|------|-------|---------|
| 1–0 | FRONT | Layer number in front |
| 3–2 | SECOND | |
| 5–4 | THIRD | |
| 7–6 | BACK | Layer number at the back |
| 10–8 | SPRPOS | Sprites go in front of position 0–4 (0 = in front of everything, 4 = behind all layers) |

Any order is allowed, unlike the Amiga's fixed playfield-pair rules. The sprite spec may add per-sprite priority later.

## 5. Fetch

### 5.1 What gets fetched and when

- Data for screen line *L* is fetched while line *L*−1 is displayed, into a **line buffer**, one per layer, double-buffered. At the start of each line, the timing generator tells the fetch engine (across the clock boundary) to begin fetching the next line.
- The fetch engine works on the memory side and uses the **display fetch slots** from spec 5. It also fetches sprite data from the same pool.
  - **Normal:** slots with `slot % 4 == 1`: 100 bursts per 32 µs, i.e. 25 MB/s.
  - **Wide fetch** (VIDCON.WIDE = 1): also the free-pool slots with `slot % 4 == 3`, for about 185 bursts per 32 µs (46 MB/s). Those slots come out of the free pool, so the blitter and copper get less bandwidth while it is on. The CPU's slots are never touched.
- Layers are fetched in priority order, front first, after sprites. For each layer active on line *L*, the fetch engine:
  1. works out the first source byte from PTR, SCROLLX, SCROLLY, STRIDE and VSTEP,
  2. works out how many source pixels the window needs: `ceil((XEND − XSTART) × HSTEP / 256)`,
  3. rounds the start down to an 8-byte boundary (one burst) and fetches whole bursts.

A burst never crosses an SDRAM row, because rows are 1 KB and bursts are 8-byte aligned.

One layer can fetch at most 1 KB (128 bursts) per line, the size of its line buffer.

### 5.2 Budget per line

The bursts available in one display line depend on how long the line lasts:

`line time = HTOTAL ÷ pixel clock`
`bursts per line = 100 × line time ÷ 32 µs` (normal) or `185 × line time ÷ 32 µs` (wide)

Cost per layer per line:

`bursts = ceil((start offset within burst + source pixels × bits per pixel ÷ 8) ÷ 8)`

Sprites take 2 bursts per sprite shown on the line (sprite spec to confirm). Text layers cost nothing.

| Mode | Line time | Normal: bursts (bytes) | Wide: bursts (bytes) |
|------|-----------|------------------------|----------------------|
| 640×480 @ 60 | 31.7 µs | 99 (792) | 183 (1464) |
| 720×576 @ 50 | 32.0 µs | 100 (800) | 185 (1480) |
| 800×600 @ 60 | 26.4 µs | 82 (656) | 152 (1216) |
| 1024×768 @ 60 | 20.7 µs | 64 (512) | 119 (952) |
| 1280×720 @ 60 | 22.2 µs | 69 (552) | 128 (1024) |

### 5.3 Example budgets

| Screen setup | Bursts needed per line | Fits? |
|--------------|------------------------|-------|
| 640×480: one full layer at 8bpp, scrolled, + 8 sprites | 81 + 16 = 97 | Normal (99) |
| 640×480: two full layers at 4bpp (like dual playfield) + 8 sprites | 82 + 16 = 98 | Normal (99) |
| 640×480: two 320×240 8bpp layers at 2× + text + 8 sprites | 82 + 16 = 98 | Normal (99) |
| 640×480: 8bpp layer + 8bpp full-screen overlay | 162 | Wide (183) |
| 720×576 @ 50: 360×288 8bpp at 2× + 360×288 8bpp at 2× + 8 sprites | 92 + 16 = 108 | Wide (185) |
| 1280×720: one full layer at 4bpp | 81 | Wide (128) |
| 1280×720: 640×360 8bpp at 2× + 1280×720 2bpp overlay | 81 + 41 = 122 | Wide (128) |
| 1280×720: one full layer at 8bpp | 161 | **No**: over budget and over the 1 KB line buffer |
| 1024×768: one full layer at 8bpp | 129 | **No** (119); use 4bpp or a smaller window |

### 5.4 When a line is over budget

If the slots run out before every layer is fetched, the layers fetched last (lowest priority) lose pixels from the right-hand end of their window. Those pixels show as transparent. The OVERRUN flag for that layer is set, and an interrupt can be raised. The display never glitches in any other way, and the CPU is never affected.

Software can check a setup in advance with the formula in 5.2. A helper in the boot ROM will do this.

### 5.5 When register writes take effect

| Register group | Takes effect |
|----------------|--------------|
| Layer registers: CTRL, PTR, STRIDE, SCROLLX/Y, HSTEP/VSTEP, window | Latched at the start of the line *before* each display line (when its fetch begins). **To change line L, write before line L−1 begins.** |
| PRIO, BGCOLOR | At the start of each display line |
| Palette | Immediately (next pixel) |
| Timing and pixel clock registers | Only while video is off |

- **Writing PTR mid-frame** restarts that layer's source at the new address on the next latched line. This gives Amiga-style split screens (e.g. a different picture below line 200) with one copper write.
- Otherwise each layer's current source line just moves on by VSTEP each line.

## 6. Registers

Addresses are offsets in the custom register block at `0xE00000`. Spec 3 sets the final addresses.

### 6.1 Global

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x000` | VIDCON | EN (0), WIDE (1), BLANKALL (2) | Video on, wide fetch, force background only |
| `0x004` | VIDSTAT | VBLANK (0), LINE (1), OVERRUN L0–L3 (4–7), INVBLANK (8, read-only), PCLKLOCK (9, read-only) | Sticky flags, write 1 to clear |
| `0x008` | VIDINTEN | Same bit layout as VIDSTAT | Interrupt enables |
| `0x00C` | BEAMPOS | `vline` 26–16, `hpixel` 10–0 | Read-only |
| `0x010` | FRAMECOUNT | 15–0 | Read-only |
| `0x014` | LINECMP | `vline` 26–16, `hpixel` 10–0 | LINE interrupt position |
| `0x018` | BGCOLOR | 23–0 RGB | Background colour |
| `0x01C` | PRIO | See 4.8 | Layer and sprite order |
| `0x020` | HVISIBLE | 10–0 | Timing (video off only) |
| `0x024` | HSYNCSTART | 10–0 | |
| `0x028` | HSYNCEND | 10–0 | |
| `0x02C` | HTOTAL | 10–0 | |
| `0x030` | VVISIBLE | 10–0 | |
| `0x034` | VSYNCSTART | 10–0 | |
| `0x038` | VSYNCEND | 10–0 | |
| `0x03C` | VTOTAL | 10–0 | |
| `0x040` | SYNCPOL | HPOL (0), VPOL (1) | 1 = active-high sync |
| `0x044` | PCLK | M 23–16, D 7–0 | Pixel clock = 50 MHz × M ÷ D (video off only) |

DMACON (spec 5, section 8) must also have VIDEN set for bitmap layers to fetch.

### 6.2 Per layer

Layer *n* is at `0x100 + n × 0x40`.

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `+0x00` | CTRL | EN (0), TYPE (1: 0 = bitmap, 1 = text), BPP (3–2: 1/2/4/8), TRANSP (4), PALOFS (15–6, in units of 16 entries) | |
| `+0x04` | PTR | 24–0 | Source byte address (text layer: cell offset) |
| `+0x08` | STRIDE | 15–0 signed | Bytes per source line |
| `+0x0C` | WINX | XSTART 26–16, XEND 10–0 | Window, pixels |
| `+0x10` | WINY | YSTART 26–16, YEND 10–0 | Window, lines |
| `+0x14` | SCROLLX | 15–0 | Source pixels |
| `+0x18` | SCROLLY | 15–0 | Source lines |
| `+0x1C` | HSTEP | 15–0, 8.8 | Horizontal step |
| `+0x20` | VSTEP | 15–0, 8.8 | Vertical step |

### 6.3 Memory-mapped areas

| Area | Location | Contents |
|------|----------|----------|
| Palette | `0xE04000`–`0xE04FFF` | 1024 × 32-bit, `0x00RRGGBB` |
| Text buffer | `0xE10000`–`0xE11FFF` | 128 × 32 cells × 16-bit |
| Font | `0xE12000`–`0xE12FFF` | 256 characters × 16 bytes |

## 7. Block RAM use

| Item | 18 Kb blocks |
|------|--------------|
| Line buffers: 4 layers × 2 × 1 KB | 4 |
| Palette: 1024 × 24-bit | 2 |
| Text buffer 8 KB + font 4 KB | 6 |
| **Total for video** | **12** |

Each line buffer holds up to 1 KB of source data per line: 640 pixels at 8bpp with room for a 1.6× shrink, or 1280 pixels at 4bpp.

The pixel clock also needs one DCM_CLKGEN and one PLL (the LX25 has 8 DCMs and 4 PLLs).

## 8. Open points

| # | Item |
|---|------|
| V1 | Sprite spec: count, size, formats, how they use their 16 slots per line, collision detection |
| V2 | Test 50 Hz modes (640×480 @ 50 and the standard 576p/720p50) on real HDMI monitors and TVs |
| V3 | Whether 4 layers is the right number; each extra layer costs one block RAM and a little logic |
| V4 | 16-bit direct-colour and tile-map layer types (version 2) |
| V5 | Horizontal wrap for bitmap layers (scroll around a fixed-width ring), so endless side-scrollers need less copying |
| V6 | HDMI audio (sending sound over HDMI as well as the jack): possible later, needs the HDMI data-island encoder |
| V7 | Confirm the FPGA speed grade from the chip marking; 720p needs the -3 grade's serialiser speed |
| V8 | Check the pixel pipeline (layers, priority, palette) meets timing at 74.25 MHz in ISE |
| V9 | Some TVs expect HDMI info packets for 576p/720p and may not accept plain DVI; test, and add the packets if needed (same work as V6) |

## 9. Tests

- **Timing:** check sync positions and frame rate for every preset in simulation; check real monitors lock on to each.
- **Clock change:** switch between presets at run time; the clocks relock and PCLKLOCK sets, with no effect on the CPU or memory side.
- **Fetch budget:** for every example in 5.3, assert the burst count matches the formula and that over-budget setups set OVERRUN on the right layer only.
- **Golden images:** render test screens in simulation (windows, scroll, scale, priority, transparency, palette) and compare frame dumps with images made by a Python reference model.
- **Register timing:** a write before line L−1 changes line L exactly; a write after it changes line L+1.
- **No CPU slowdown:** with all layers on and wide fetch, the CPU zero-wait test from spec 5 still passes.
