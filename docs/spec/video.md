# Spec 4: Video

Status: **draft for review**

## 1. Goals

- 640×480 DVI output over the HDMI connector
- **Four independent layers**, each with its own display window, source address, pixel format, scroll, scale and palette. The Amiga has one display window and one or two playfields
- **Fetch is automatic:** the hardware works out what to fetch from each layer's window, so there are no fetch start/stop registers to keep in step (the Amiga's DDFSTRT/DDFSTOP)
- **Free scaling:** each layer has its own horizontal and vertical step in 1/256ths of a pixel, so 2× and 4× pixels, odd sizes and simple zoom effects all use the same mechanism
- Programmable vertical timing (50 or 60 Hz), beam position registers, vertical-blank and line interrupts
- Fixed, predictable memory cost: video only uses its own odd slots (spec 5), so it never slows the CPU

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
| Video timing | Fixed (OCS); programmable on ECS | Vertical timing programmable; horizontal fixed to the slot grid |

## 3. Timing, retrace and the beam

### 3.1 Fixed horizontal timing

The pixel clock is 25 MHz (40 ns), and one memory slot is 2 pixels. Horizontal timing is fixed at 800 pixels per line, because spec 5's slot table is laid out on it.

| | Pixels | Slots (`hslot`) |
|---|---|---|
| Visible | 0–639 | 0–319 |
| Front porch | 640–655 | 320–327 |
| Horizontal sync | 656–751 | 328–375 |
| Back porch | 752–799 | 376–399 |

Horizontal blanking (pixels 640–799, slots 320–399) is the horizontal retrace.

### 3.2 Programmable vertical timing

`vline` counts lines from 0 (the first visible line). These registers set the rest of the frame:

| Register | 60 Hz default | 50 Hz setting | Meaning |
|----------|---------------|---------------|---------|
| VVISIBLE | 480 | 480 | Number of visible lines |
| VSYNCSTART | 490 | 515 | First line of vertical sync |
| VSYNCEND | 492 | 517 | First line after sync |
| VTOTAL | 525 | 625 | Lines per frame |

- **60 Hz:** 25 MHz ÷ 800 ÷ 525 = 59.5 Hz. This is standard 640×480 timing on a 25.0 MHz clock instead of 25.175 MHz; monitors accept it.
- **50 Hz:** 25 MHz ÷ 800 ÷ 625 = exactly 50 Hz. This is useful for PAL-timed music and demos. Most HDMI monitors and TVs accept it, but not all, so it must be tested on real screens (open point V2).
- Fewer visible lines (e.g. 400) are allowed; the extra lines become border/blank.
- The timing registers can only be changed while video is off (VIDCON.EN = 0).

Vertical blanking (lines VVISIBLE to VTOTAL−1) is the vertical retrace.

### 3.3 Beam position

| Register | Contents |
|----------|----------|
| BEAMPOS (read) | `vline` (bits 25–16), `hslot` (bits 8–0) as one 32-bit read so they always match |
| FRAMECOUNT (read) | Frame counter, 16-bit, increments at the start of vertical blanking |

### 3.4 Video interrupts

All go through the interrupt controller at level 5 (design plan D8).

| Source | When |
|--------|------|
| VBLANK | Start of vertical blanking (`vline` = VVISIBLE, `hslot` = 0) |
| LINE | `vline` = LINECMP and `hslot` = HCMP (both programmable), for raster effects without the copper |
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
- A full-screen layer is simply 0, 0, 640, 480.

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
| Text buffer | 128 columns × 32 rows of 16-bit cells in block RAM (8 KB); 80×30 visible at 1:1 |
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

- Data for screen line *L* is fetched during line *L*−1 into a **line buffer**, one per layer, double-buffered.
- Fetching uses the video's odd slots (spec 5): every slot with `hslot % 4 == 1` in the visible part of the line. That gives **80 bursts = 640 bytes per line**.
- **Wide fetch** (VIDCON.WIDE = 1) also takes the slots with `hslot % 4 == 3`, giving **160 bursts = 1280 bytes per line**. Those slots come out of the free pool, so the blitter and copper get less bandwidth while it is on. The CPU's slots are never touched.
- Layers are fetched in priority order, front first. For each layer active on line *L*, the fetch engine:
  1. works out the first source byte from PTR, SCROLLX, SCROLLY, STRIDE and VSTEP,
  2. works out how many source pixels the window needs: `ceil((XEND − XSTART) × HSTEP / 256)`,
  3. rounds the start down to an 8-byte boundary (one burst) and fetches whole bursts.

A burst never crosses an SDRAM row, because rows are 1 KB and bursts are 8-byte aligned.

One layer can fetch at most 1 KB (128 bursts) per line, the size of its line buffer.

### 5.2 Cost per layer per line

`bursts = ceil((start offset within burst + source pixels × bits per pixel ÷ 8) ÷ 8)`

Text layers cost nothing.

### 5.3 Example budgets

| Screen setup | Bursts per line | Fits in |
|--------------|-----------------|---------|
| One 640×480 layer, 8bpp | 80 (+1 when scrolled) | Wide fetch when scrolled |
| One 640×480 layer, 4bpp | 40 (+1) | Normal |
| Two 640×480 layers, 4bpp each (like dual playfield) | 80 (+2) | Wide fetch when scrolled |
| Game: two 320×240 8bpp layers at 2× + text layer | 40 + 40 (+2) | Wide fetch |
| Game: 320×224 8bpp at 2× (lines 0–447) above a 640×32 4bpp status bar (lines 448–479) | 40 (+1) on every line, as only one layer is active per line | Normal |
| Desktop: 640×480 8bpp + 640×480 8bpp overlay | 160 (+2) | Over budget; reduce one layer's window or depth |

### 5.4 When a line is over budget

If the slots run out before every layer is fetched, the layers fetched last (lowest priority) lose pixels from the right-hand end of their window. Those pixels show as transparent. The OVERRUN flag for that layer is set, and an interrupt can be raised. The display never glitches in any other way, and the CPU is never affected.

Software can check a setup in advance with the formula in 5.2. A helper in the boot ROM will do this.

### 5.5 When register writes take effect

| Register group | Takes effect |
|----------------|--------------|
| Layer registers: CTRL, PTR, STRIDE, SCROLLX/Y, HSTEP/VSTEP, window | Latched at the start of the line *before* each display line (when its fetch begins). **To change line L, write before line L−1 begins.** |
| PRIO, BGCOLOR | At the start of each display line |
| Palette | Immediately (next pixel) |
| Timing registers | Only while video is off |

- **Writing PTR mid-frame** restarts that layer's source at the new address on the next latched line. This gives Amiga-style split screens (e.g. a different picture below line 200) with one copper write.
- Otherwise each layer's current source line just moves on by VSTEP each line.

## 6. Registers

Addresses are offsets in the custom register block at `0xE00000`. Spec 3 sets the final addresses.

### 6.1 Global

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x000` | VIDCON | EN (0), WIDE (1), BLANKALL (2) | Video on, wide fetch, force background only |
| `0x004` | VIDSTAT | VBLANK (0), LINE (1), OVERRUN L0–L3 (4–7), INVBLANK (8, read-only) | Sticky flags, write 1 to clear |
| `0x008` | VIDINTEN | Same bit layout as VIDSTAT | Interrupt enables |
| `0x00C` | BEAMPOS | `vline` 25–16, `hslot` 8–0 | Read-only |
| `0x010` | FRAMECOUNT | 15–0 | Read-only |
| `0x014` | LINECMP | `vline` 25–16, `hslot` 8–0 | LINE interrupt position |
| `0x018` | BGCOLOR | 23–0 RGB | Background colour |
| `0x01C` | PRIO | See 4.8 | Layer and sprite order |
| `0x020` | VVISIBLE | 9–0 | Timing (video off only) |
| `0x024` | VSYNCSTART | 9–0 | |
| `0x028` | VSYNCEND | 9–0 | |
| `0x02C` | VTOTAL | 9–0 | |

DMACON (spec 5, section 8) must also have VIDEN set for bitmap layers to fetch.

### 6.2 Per layer

Layer *n* is at `0x100 + n × 0x40`.

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `+0x00` | CTRL | EN (0), TYPE (1: 0 = bitmap, 1 = text), BPP (3–2: 1/2/4/8), TRANSP (4), PALOFS (15–6, in units of 16 entries) | |
| `+0x04` | PTR | 24–0 | Source byte address (text layer: cell offset) |
| `+0x08` | STRIDE | 15–0 signed | Bytes per source line |
| `+0x0C` | WINX | XSTART 25–16, XEND 9–0 | Window, pixels |
| `+0x10` | WINY | YSTART 25–16, YEND 9–0 | Window, lines |
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

Each line buffer holds up to 1 KB of source data per line: 640 pixels at 8bpp with room for a 1.6× shrink.

## 8. Open points

| # | Item |
|---|------|
| V1 | Sprite spec: count, size, formats, how they use their 16 slots per line, collision detection |
| V2 | Test 50 Hz output on real HDMI monitors and TVs |
| V3 | Whether 4 layers is the right number; each extra layer costs one block RAM and a little logic |
| V4 | 16-bit direct-colour and tile-map layer types (version 2) |
| V5 | Horizontal wrap for bitmap layers (scroll around a fixed-width ring), so endless side-scrollers need less copying |
| V6 | HDMI audio (sending sound over HDMI as well as the jack): possible later, needs the HDMI data-island encoder |

## 9. Tests

- **Timing:** check sync positions and frame rate at 60 and 50 Hz settings in simulation; check a real monitor locks on.
- **Fetch budget:** for every example in 5.3, assert the burst count matches the formula and that over-budget setups set OVERRUN on the right layer only.
- **Golden images:** render test screens in simulation (windows, scroll, scale, priority, transparency, palette) and compare frame dumps with images made by a Python reference model.
- **Register timing:** a write before line L−1 changes line L exactly; a write after it changes line L+1.
- **No CPU slowdown:** with all layers on and wide fetch, the CPU zero-wait test from spec 5 still passes.
