# Spec 4: Video

Status: **draft for review**

## 1. Goals

- DVI output over the HDMI connector, and at the same time **24-bit VGA** through the KS3's ADV7125 video DAC, from 640×480 up to 1280×720. The **pixel clock is the master clock divided by a whole number**, and the timing is programmable
- **Four independent layers**, each with its own display window, source address, pixel format, scroll, scale and palette. The Amiga has one display window and one or two playfields
- **Video memory is fetched on demand by DMA, just in time, as the beam scans**, like the Amiga's bitplane DMA. There are no line buffers. Each layer has only a 48-byte buffer, the equivalent of the Amiga's bitplane data registers
- **Fetch is automatic:** the hardware works out what to fetch from each layer's window, so there are no fetch start/stop registers to keep in step (the Amiga's DDFSTRT/DDFSTOP)
- **Free scaling:** each layer has its own horizontal and vertical step in 1/256ths of a pixel, so 2× and 4× pixels, odd sizes and simple zoom effects all use the same mechanism
- Fully programmable horizontal and vertical timing, with presets for standard modes at 50 and 60 Hz; beam position registers, vertical-blank and line interrupts
- **Everything runs from one master clock, as on the Amiga.** Every scan line is a whole number of memory slots, so DMA happens at the same beam positions on every line, in every mode. Layers only use DMA memory cycles (spec 5), so they never slow the CPU. Sprites can borrow the CPU's cycle only when they would otherwise be late (section 5.4)

Sprites ([spec 9](sprites.md)), the copper and the blitter get their own specs.

## 2. Comparison with the Amiga (OCS/ECS)

| Feature | Amiga | retro68k |
|---------|-------|----------|
| Display window | One per screen (DIWSTRT/DIWSTOP) | One per layer, anywhere on screen |
| Playfields | 1, or 2 in dual-playfield mode | Up to 4 layers + sprites, any priority order |
| Pixel layout | Bitplanes (planar) | Chunky: 1, 2, 4 or 8 bits per pixel, packed in bytes |
| Colours | 32 from 4096 (64 with EHB, 4096 with HAM) | 1024-entry palette of 24-bit colours (16.7 M); each layer picks its palette block |
| Fetch | Bitplane DMA during the line into data registers; DDFSTRT/DDFSTOP set by hand | DMA during the line into small per-layer buffers; timing worked out from each layer's window and scale |
| Line-to-line source step | Modulo (bytes skipped) | Stride (bytes from line to line), signed, so images can be flipped vertically |
| Scrolling | Fine scroll 0–15 px via BPLCON1, plus pointer arithmetic | Scroll X and Y registers per layer, added by hardware |
| Pixel size | Lores/hires (fixed 2:1), line doubling by copper tricks | Any horizontal and vertical step, 1/256 pixel precision |
| Text mode | None | A text layer from block RAM (no Chip RAM cost) |
| Video timing | Fixed (OCS); programmable on ECS | Pixel clock = master ÷ N (N = 3–8); horizontal and vertical timing programmable |

## 3. Clocks, timing, retrace and the beam

### 3.1 One master clock, divided by whole numbers

One MMCM (the Artix-7's clock generator), set once at power-on and never changed, makes a 200 MHz master clock from the KS3's 50 MHz oscillator (50 × 16 = 800 MHz, ÷ 4). Every other clock is the master divided by a whole number, so they all stay in a fixed relationship:

| Clock | Master ÷ | Frequency |
|-------|----------|-----------|
| System / SRAM controller | 2 | 100 MHz |
| fx68k master clock | 5 | 40 MHz (→ 20 MHz 68000) |
| Memory slot | 20 | 100 ns |
| **Pixel clock** | **N = 3–8, programmable** | 66.7 MHz down to 25 MHz |

| N | Pixel clock | Pixels per slot |
|---|-------------|-----------------|
| 8 | 25.0 MHz | 2.5 |
| 7 | 28.57 MHz | 2.86 |
| 6 | 33.3 MHz | 3.33 |
| 5 | 40.0 MHz | 4 |
| 4 | 50.0 MHz | 5 |
| 3 | 66.7 MHz | 6.67 |

The pixel clock is the 200 MHz master passed through a clock buffer with an enable (BUFGCE) that lets every Nth edge through, so its edges always line up with the master's, and signals cross between it and the 100 MHz system clock as ordinary timed paths.

N = 2 (100 MHz) would need 1 Gbit/s per HDMI lane; the Artix-7 -2 might manage it, but it is not assumed. N above 8 would go below DVI's 25 MHz minimum.

If fx68k cannot reach 40 MHz (the 16.7 MHz fallback in spec 5), the slot becomes 24 master clocks (120 ns), and the rule in 3.2 becomes "a multiple of 48". The pixel clocks stay the same.

### 3.2 Every line is a whole number of slots

**Rule: HTOTAL × N must be a multiple of 20.** A line then lasts exactly `S = HTOTAL × N ÷ 20` slots.

- The slot counter `hslot` restarts at 0 at the start of every line. **DMA is locked to the beam:** every fixed DMA slot happens at the same horizontal position on every line, as on the Amiga.
- Every slot has the CPU's memory cycle (spec 5), so changing mode never disturbs the CPU.
- VTOTAL has no such rule.

### 3.3 The HDMI serialiser clock

HDMI sends 10 bits per pixel, so the Artix-7 serialisers (OSERDESE2) need clocks at 5× (with double data rate) and 1× the pixel clock. A whole-number divider can only make slower clocks, so a second MMCM is used **only as a multiplier**. It takes the divided pixel clock as its input and gives back 1× and 5× copies, kept in phase with its input. HDMI transmitter chips do the same thing inside.

- The multiplier's internal oscillator must stay in its range (600–1440 MHz on the -2 grade), so it has two settings, loaded through its reconfiguration port when N changes: ×30 internally for N = 5–8, ×15 for N = 3–4.
- When N changes, the multiplier relocks in well under a millisecond while video is off, and PCLKLOCK in VIDSTAT sets. The master clock, the slots and the CPU are not affected.
- The fastest mode, N = 3, needs 667 Mbit/s per HDMI lane, comfortably inside the Artix-7's limit.

**VGA:** the KS3's ADV7125 DAC takes 8 bits per colour, sent over 4 pins per colour at double rate (the top 4 bits on one clock edge, the bottom 4 on the other). It is clocked from the pixel clock and shows exactly the same picture and timing as HDMI.

### 3.4 Programmable timing

All values are in pixels (horizontal) or lines (vertical). `hpixel` counts from 0 at the first visible pixel, `vline` from 0 at the first visible line. Blanking (front porch, sync, back porch) follows the visible part.

| Register | Meaning |
|----------|---------|
| PCLKDIV | N: pixel clock = 200 MHz ÷ N |
| HVISIBLE, HSYNCSTART, HSYNCEND, HTOTAL | Horizontal: visible width, sync position, total pixels per line. HTOTAL × N must be a multiple of 20 |
| VVISIBLE, VSYNCSTART, VSYNCEND, VTOTAL | Vertical: visible lines, sync position, total lines per frame |
| SYNCPOL | Horizontal and vertical sync polarity |

The timing and clock registers can only be changed while video is off (VIDCON.EN = 0). Turning video on with an HTOTAL that breaks the rule is refused, and VIDSTAT.BADTIMING is set.

Horizontal blanking is the horizontal retrace; lines VVISIBLE to VTOTAL−1 are the vertical retrace.

### 3.5 Presets

The boot ROM has a table of these modes. Software can also set any timing that follows the rule.

| Mode | N | Pixel clock | Total (H × V) | Slots per line | Refresh | Compared with the standard |
|------|---|-------------|---------------|----------------|---------|----------------------------|
| 640×480 | 8 | 25.0 MHz | 800 × 525 | 320 | 59.5 Hz | VGA is 25.175 MHz; monitors accept 25.0. Power-on default |
| 640×480 | 8 | 25.0 MHz | 800 × 625 | 320 | 50.0 Hz | Non-standard; test per monitor |
| 720×576 | 7 | 28.57 MHz | 920 × 621 | 322 | 50.0 Hz | 576p is 27.0 MHz, 864 × 625. Line rate 0.6% low |
| 720×480 | 7 | 28.57 MHz | 920 × 517 | 322 | 60.1 Hz | 480p is 27.0 MHz, 858 × 525. Line rate 1.3% low |
| 800×600 | 5 | 40.0 MHz | 1056 × 628 | 264 | 60.3 Hz | Exactly VESA 800×600 @ 60 |
| 800×600 | 4 | 50.0 MHz | 1040 × 666 | 208 | 72.2 Hz | Exactly VESA 800×600 @ 72 |
| 1024×768 | 3 | 66.7 MHz | 1360 × 817 | 204 | 60.0 Hz | VESA is 65 MHz, 1344 × 806 |
| 1280×720 | 3 | 66.7 MHz | 1480 × 750 | 222 | 60.06 Hz | 720p is 74.25 MHz, 1650 × 750; same line and frame rate, shorter blanking |
| 1280×720 | 3 | 66.7 MHz | 1760 × 758 | 264 | 49.97 Hz | 720p50 is 74.25 MHz, 1980 × 750 |

**The cost of whole-number division:** the TV modes (576p, 480p, 720p) use a different pixel clock and blanking from the standard. Their line and frame rates are matched as closely as possible by adjusting the totals. Computer monitors accept this; some TVs check timing strictly (open point V9). The Amiga had the same issue, which is why PAL and NTSC machines had different crystals.

Low-resolution looks (320×240, 360×288 etc.) are made with layer scaling (section 4.5), not by changing the timing. This keeps the screen locked to one mode and lets low- and high-resolution layers be shown together.

### 3.6 Beam position

| Register | Contents |
|----------|----------|
| BEAMPOS (read) | `vline` (bits 26–16), `hpixel` (bits 10–0) as one 32-bit read so they always match |
| SLOTPOS (read) | `vline` (bits 26–16), `hslot` (bits 8–0): the beam position in memory slots |
| FRAMECOUNT (read) | Frame counter, 16-bit, increments at the start of vertical blanking |

### 3.7 Video interrupts

They reach the CPU through the interrupt controller (spec 13) as four sources with their own vectors: VBLANK, LINE, COPPER and VIDERR (OVERRUN, SPRMISS, SPROVF, BADTIMING). Default level 5.

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
 Chip RAM ─DMA, just in time─▶ 48-byte buffers L0..L3 ──┐
                                                        ├─▶ priority mux ─▶ palette ─▶ HDMI and VGA
 block RAM (text) ─▶ text layer ────────────────────────┤        ▲
 Chip RAM ─DMA, just before X─▶ sprite data registers ───┘   PRIO register
```

### 4.2 Layer types and pixel formats

| Type | Source | Formats | Uses Chip RAM cycles |
|------|--------|---------|-------------|
| Bitmap | Chip RAM | 1, 2, 4 or 8 bits per pixel, chunky, most significant pixel first in each byte | Yes (section 5) |
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
| PTR | 23 | Byte address in Chip RAM of the layer's top-left source pixel (before scrolling) |
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

**Layout seen by the CPU:** cell n is the 16-bit word at `0xE10000 + 2n` (row r, column c is cell `128r + c`); the character code is its low byte, at the odd address. Character k's 16 rows are the bytes at `0xE12000 + 16k`, leftmost pixel in bit 7. At power-on the font holds Spleen 8×16 in code page 437 (BSD licence, `third_party/spleen`).

### 4.8 Priority

The PRIO register lists the order of the four layers and where sprites sit:

| Bits | Field | Meaning |
|------|-------|---------|
| 1–0 | FRONT | Layer number in front |
| 3–2 | SECOND | |
| 5–4 | THIRD | |
| 7–6 | BACK | Layer number at the back |

Any order is allowed, unlike the Amiga's fixed playfield-pair rules. Each sprite sets its own depth among the layers (spec 9, section 6).

## 5. Fetch

### 5.1 Fetched on demand, as the beam scans

There are no line buffers. Video data is fetched by DMA during the line it is shown on, a few pixels ahead of the beam, as the Amiga does with bitplane DMA.

- Each bitmap layer has a **48-byte buffer** (24 words), made from FPGA logic, not block RAM. It does the job of the Amiga's bitplane data registers. The pixel output takes data from the front of the buffer, and DMA tops it up from the back, one 16-bit word per memory cycle.
- **Display fetch cycles** are fixed in every slot of every line (spec 5, section 4.3):
  - **Normal:** memory cycles 1 and 2 of every slot: 4 bytes every 100 ns.
  - **Wide fetch** (VIDCON.WIDE = 1): also cycle 3 in the visible part of the line, 6 bytes every 100 ns. Cycle 3 comes out of the free pool, so the copper and DMA engine get less while it is on. Layers never touch the CPU's cycle 0.
- **Which layer or sprite gets each cycle:** whichever will run out of data soonest (earliest deadline first). With a given screen setup this always works out the same, so the fetch pattern repeats exactly on every line and every frame.
- **Prefetch:** before a layer's window starts, its buffer is filled with its first 16 bytes. For windows that start at the left edge, this happens in the horizontal blanking before the line. For windows that start further right, it happens in display cycles just before the window. This replaces the Amiga's DDFSTRT, which had to be set by hand earlier than the display window.
- Fetching starts at the word holding the first pixel, and leading pixels are skipped to give the exact SCROLLX position. The SRAM has no rows or bursts, so any address costs the same.
- **Vertical scaling** re-fetches the source line for each screen line it appears on. There is nothing kept from the line before.

The buffers sit between the 100 MHz DMA side and the pixel clock. Both come from the same master clock, so the hand-over is fully predictable.

### 5.1.1 Version 1 (fpga/rtl/vfetch.v, layer_pix.v)

What the first implementation does, where it is simpler than the text above:

- **Which layer gets a cycle:** the one with the emptiest buffer (fewest words in it or on the way), lowest layer number on a tie. For layers that use data at the same rate this is the same as earliest deadline first; a true deadline order comes with sprites.
- **Wide fetch** gives cycle 3 to the display on the whole line, not just its visible part.
- **Buffer:** 24 words in use, in a 32-word store (LUT RAM).
- **Per line:** at the start of horizontal blanking the next line's start address and word count are worked out (over three pixel clocks), and the fetcher fills each buffer from then on. A layer moves on by at most one word per pixel, so HSTEP may not take more than 16 bits of source per screen pixel (e.g. 2.0 at 8 bpp); that is past the budget in any case.
- **PTR written mid-frame:** the next line starts at the new PTR (source line 0); SCROLLY applies again from the next frame.

### 5.2 Budget: bytes per pixel

Because data is fetched while it is shown, the budget is a **rate**: how many bytes can be fetched for each pixel the beam passes.

| Fetch | Bytes per pixel |
|-------|-----------------|
| Normal | 0.2 × N |
| Wide | 0.3 × N |

A layer needs `bits per pixel ÷ 8 × HSTEP ÷ 256` bytes per screen pixel. At every point across the screen, **the layers whose windows cover that point must add up to no more than the budget.** The 48-byte buffers smooth out small differences, but not a whole line's worth.

| Mode | N | Normal | Wide |
|------|---|--------|------|
| 640×480 @ 60 or 50 | 8 | 1.6 | 2.4 |
| 720×576 @ 50, 720×480 @ 60 | 7 | 1.4 | 2.1 |
| 800×600 @ 60 | 5 | 1.0 | 1.5 |
| 800×600 @ 72 | 4 | 0.8 | 1.2 |
| 1024×768 @ 60, 1280×720 @ 60 or 50 | 3 | 0.6 | 0.9 |

What one layer costs:

| Layer | Bytes per pixel |
|-------|-----------------|
| 8bpp at 1:1 | 1.0 |
| 4bpp at 1:1, or 8bpp at 2× wide | 0.5 |
| 2bpp at 1:1, or 4bpp at 2× wide | 0.25 |
| 1bpp at 1:1 | 0.125 |
| Text | 0 (block RAM) |

### 5.3 Example budgets

| Screen setup | Bytes per pixel | Fits? |
|--------------|-----------------|-------|
| 640×480: one full layer at 8bpp | 1.0 | Normal (1.6) |
| 640×480: 8bpp layer + 4bpp overlay | 1.5 | Normal |
| 640×480: two 320×240 8bpp layers at 2× + text | 1.0 | Normal |
| 640×480: 8bpp layer + full-screen 8bpp overlay | 2.0 | Wide (2.4) |
| 720×576: two 360×288 8bpp layers at 2× | 1.0 | Normal (1.4) |
| 800×600 @ 60: one full layer at 8bpp | 1.0 | Normal (1.0) |
| 1024×768: one full layer at 4bpp | 0.5 | Normal (0.6) |
| 1280×720: one full layer at 4bpp | 0.5 | Normal (0.6) |
| 1280×720: 640×360 8bpp at 2× + 1280×720 2bpp overlay | 0.5 + 0.25 = 0.75 | Wide (0.9) |
| 1280×720: one full layer at 8bpp | 1.0 | **No** (0.9) |

Windows help: a status bar that sits below a game area, not on top of it, adds nothing to the budget on the lines where the game area is shown.

### 5.4 Sprites: fetched just before they are drawn

Sprite data is fetched on demand, just before the beam reaches each sprite, from the free pool and, only when needed, the CPU's cycle. Nothing is fetched a line ahead. [Spec 9](sprites.md), section 5 has the details:

- Each sprite's fetch starts exactly 128 slots before its first pixel, on the line it is shown (or at the end of the line before, for sprites near the left edge).
- It uses free-pool cycles and display cycles no layer needs first, and takes the CPU's cycle only when the sprite would otherwise be late (2 CPU clocks each).
- Sprites never take cycles a layer needs, so they don't count towards the layer budget in section 5.2.

### 5.5 When a layer runs short

If a layer's buffer runs empty (the setup is over budget at that point on the screen), that layer shows transparent pixels until DMA catches up. The OVERRUN flag for that layer is set, and an interrupt can be raised. The display never glitches in any other way, and the CPU is never affected.

Software can check a setup in advance with the rule in 5.2. A helper in the boot ROM will do this.

### 5.6 When register writes take effect

| Register group | Takes effect |
|----------------|--------------|
| Layer registers: CTRL, PTR, STRIDE, SCROLLX/Y, HSTEP/VSTEP, window | Latched at the start of horizontal blanking before each line, when that line's prefetch begins. **To change line L, write during the visible part of line L−1 (or earlier).** |
| PRIO, BGCOLOR | At the start of each line |
| Palette | Immediately (next pixel) |
| Timing and pixel clock registers | Only while video is off |

- **Writing PTR mid-frame** restarts that layer's source at the new address from the next line. This gives Amiga-style split screens (e.g. a different picture below line 200) with one copper write.
- Otherwise each layer's current source line just moves on by VSTEP each line.

## 6. Registers

Addresses are offsets in the custom register block at `0xE00000`. Spec 3 sets the final addresses.

### 6.1 Global

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x000` | VIDCON | EN (0), WIDE (1), BLANKALL (2) | Video on, wide fetch, force background only |
| `0x004` | VIDSTAT | VBLANK (0), LINE (1), OVERRUN L0–L3 (4–7), INVBLANK (8, read-only), PCLKLOCK (9, read-only), BADTIMING (10), SPRMISS (11), SPROVF (12), COPIRQ (13: copper IRQ instruction or error, spec 10) | Sticky flags, write 1 to clear |
| `0x008` | VIDINTEN | Same bit layout as VIDSTAT | Interrupt enables |
| `0x00C` | BEAMPOS | `vline` 26–16, `hpixel` 10–0 | Read-only |
| `0x010` | FRAMECOUNT | 15–0 | Read-only |
| `0x048` | SLOTPOS | `vline` 26–16, `hslot` 8–0 | Read-only |
| `0x014` | LINECMP | `vline` 26–16, `hpixel` 10–0 | LINE interrupt position |
| `0x018` | BGCOLOR | 23–0 RGB | Background colour |
| `0x01C` | PRIO | See 4.8 | Layer order |
| `0x020` | HVISIBLE | 10–0 | Timing (video off only) |
| `0x024` | HSYNCSTART | 10–0 | |
| `0x028` | HSYNCEND | 10–0 | |
| `0x02C` | HTOTAL | 10–0 | |
| `0x030` | VVISIBLE | 10–0 | |
| `0x034` | VSYNCSTART | 10–0 | |
| `0x038` | VSYNCEND | 10–0 | |
| `0x03C` | VTOTAL | 10–0 | |
| `0x040` | SYNCPOL | HPOL (0), VPOL (1) | 1 = active-high sync |
| `0x044` | PCLKDIV | 3–0 | N: pixel clock = 200 MHz ÷ N, N = 3–8 (video off only) |

DMACON (spec 5, section 8) must also have VIDEN set for bitmap layers to fetch.

### 6.2 Per layer

Layer *n* is at `0x100 + n × 0x40`.

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `+0x00` | CTRL | EN (0), TYPE (1: 0 = bitmap, 1 = text), BPP (3–2: 1/2/4/8), TRANSP (4), PALOFS (15–6, in units of 16 entries) | |
| `+0x04` | PTR | 22–0 | Source byte address in Chip RAM (text layer: cell offset) |
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
| Palette: 1024 × 24-bit | 2 |
| Text buffer 8 KB + font 4 KB | 6 |
| **Total for video** | **8** |

The layer buffers (4 × 48 bytes) and sprite data registers (spec 9) are small enough to build from FPGA logic. The sprite table takes 1 more block RAM (spec 9).

Clocks use two of the XC7A35T's five MMCMs: one for the fixed master clocks, one as the HDMI multiplier.

## 8. Open points

| # | Item |
|---|------|
| V2 | Test 50 Hz modes (640×480 @ 50 and the standard 576p/720p50) on real HDMI monitors and TVs |
| V3 | Whether 4 layers is the right number; each extra layer costs one block RAM and a little logic |
| V4 | 16-bit direct-colour and tile-map layer types (version 2) |
| V5 | Horizontal wrap for bitmap layers (scroll around a fixed-width ring), so endless side-scrollers need less copying |
| V6 | HDMI audio (sending sound over HDMI as well as the jack): possible later, needs the HDMI data-island encoder |
| V8 | Check the pixel pipeline (layers, priority, palette) meets timing at 66.7 MHz in Vivado |
| V10 | Check in Vivado that the multiplier MMCM can take the divided pixel clock from a global clock buffer, and that its jitter is low enough for HDMI |
| V11 | The Next sends audio over HDMI; doing the same (V6) would make the KS3 work with TVs' built-in speakers |
| V9 | Some TVs expect HDMI info packets for 576p/720p and may not accept plain DVI; test, and add the packets if needed (same work as V6) |

## 9. Tests

- **Timing:** check sync positions and frame rate for every preset in simulation; check real monitors lock on to each, on HDMI and VGA.
- **Clock change:** switch between presets at run time; the multiplier MMCM relocks and PCLKLOCK sets, with no effect on the CPU or memory side.
- **Beam lock:** for every preset, assert that each fixed DMA cycle falls at the same `hslot` on every line.
- **Fetch budget:** for every example in 5.3, assert no layer buffer runs empty; for over-budget setups, assert OVERRUN is set on the right layer only.
- **Fetch pattern:** assert the DMA pattern is identical on every line for a fixed screen setup.
- **Sprites:** see spec 9, section 11.
- **Golden images:** render test screens in simulation (windows, scroll, scale, priority, transparency, palette) and compare frame dumps with images made by a Python reference model.
- **Register timing:** a write during line L−1's visible part changes line L exactly; a write during its blanking changes line L+1.
- **CPU slowdown:** with all layers on and wide fetch, layers never take the CPU's cycle 0 (spec 5 CPU zero-wait test).
