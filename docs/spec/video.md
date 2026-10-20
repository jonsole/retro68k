# Spec 4: Video

Status: **draft for review**

## 1. Goals

- DVI output over the HDMI connector, from 640×480 up to 1280×720. The **pixel clock is the master clock divided by a whole number**, and the timing is programmable
- **Four independent layers**, each with its own display window, source address, pixel format, scroll, scale and palette. The Amiga has one display window and one or two playfields
- **Video memory is fetched on demand by DMA, just in time, as the beam scans**, like the Amiga's bitplane DMA. There are no line buffers. Each layer has only a 32-byte buffer, the equivalent of the Amiga's bitplane data registers
- **Fetch is automatic:** the hardware works out what to fetch from each layer's window, so there are no fetch start/stop registers to keep in step (the Amiga's DDFSTRT/DDFSTOP)
- **Free scaling:** each layer has its own horizontal and vertical step in 1/256ths of a pixel, so 2× and 4× pixels, odd sizes and simple zoom effects all use the same mechanism
- Fully programmable horizontal and vertical timing, with presets for standard modes at 50 and 60 Hz; beam position registers, vertical-blank and line interrupts
- **Everything runs from one master clock, as on the Amiga.** Every scan line is a whole number of memory slots, so DMA happens at the same beam positions on every line, in every mode. Layers only use DMA slots (spec 5), so they never slow the CPU. Sprites can borrow a CPU slot when they would otherwise be late (section 5.4)

Sprites, the copper and the blitter get their own specs. This spec defines how sprites slot into the layer priority order.

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
| Text mode | None | A text layer from block RAM (no SDRAM cost) |
| Video timing | Fixed (OCS); programmable on ECS | Pixel clock = master ÷ N (N = 4–12); horizontal and vertical timing programmable |

## 3. Clocks, timing, retrace and the beam

### 3.1 One master clock, divided by whole numbers

One PLL, set once at power-on and never changed, makes a 300 MHz master clock from the board's 50 MHz oscillator (50 × 12 = 600 MHz, ÷ 2). Every other clock is the master divided by a whole number, so they all stay in a fixed relationship:

| Clock | Master ÷ | Frequency |
|-------|----------|-----------|
| System / SDRAM | 3 | 100 MHz |
| fx68k master clock | 12 | 25 MHz (→ 12.5 MHz 68000) |
| Memory slot | 24 | 80 ns |
| **Pixel clock** | **N = 4–12, programmable** | 75 MHz down to 25 MHz |

| N | Pixel clock | Pixels per slot |
|---|-------------|-----------------|
| 12 | 25.0 MHz | 2 |
| 11 | 27.27 MHz | 2.18 |
| 10 | 30.0 MHz | 2.4 |
| 8 | 37.5 MHz | 3 |
| 6 | 50.0 MHz | 4 |
| 5 | 60.0 MHz | 4.8 |
| 4 | 75.0 MHz | 6 |

N = 7 and 9 also work. N below 4 would push the HDMI lanes past 750 Mbit/s, and N above 12 would go below DVI's 25 MHz minimum.

### 3.2 Every line is a whole number of slots

**Rule: HTOTAL × N must be a multiple of 48.** A line then lasts exactly `S = HTOTAL × N ÷ 24` slots, and S is even.

- The slot counter `hslot` restarts at 0 at the start of every line. **DMA is locked to the beam:** every fixed DMA slot happens at the same horizontal position on every line, as on the Amiga.
- Because S is even, the even/odd pattern carries on unbroken from one line to the next. The CPU's even slots (spec 5) are the same in every video mode, and changing mode never disturbs the CPU.
- VTOTAL has no such rule.

### 3.3 The HDMI serialiser clock

HDMI sends 10 bits per pixel, so the Spartan-6 serialisers (OSERDES2) need clocks at 10× and 2× the pixel clock. A whole-number divider can only make slower clocks, so a second PLL is used **only as a ×10 multiplier**. It takes the divided pixel clock as its input and gives back 1×, 2× and 10× copies, kept in phase with its input. HDMI transmitter chips do the same thing inside.

- The multiplier has two settings, loaded through the PLL's reconfiguration port when N changes, to keep its internal oscillator in range: ×20 internally for N = 6–12, ×10 for N = 4–5.
- When N changes, the multiplier relocks in well under a millisecond while video is off, and PCLKLOCK in VIDSTAT sets. The master clock, the slots and the CPU are not affected.
- N = 4 means 750 Mbit/s per HDMI lane, which needs the Spartan-6 -3 speed grade (open point V7).

### 3.4 Programmable timing

All values are in pixels (horizontal) or lines (vertical). `hpixel` counts from 0 at the first visible pixel, `vline` from 0 at the first visible line. Blanking (front porch, sync, back porch) follows the visible part.

| Register | Meaning |
|----------|---------|
| PCLKDIV | N: pixel clock = 300 MHz ÷ N |
| HVISIBLE, HSYNCSTART, HSYNCEND, HTOTAL | Horizontal: visible width, sync position, total pixels per line. HTOTAL × N must be a multiple of 48 |
| VVISIBLE, VSYNCSTART, VSYNCEND, VTOTAL | Vertical: visible lines, sync position, total lines per frame |
| SYNCPOL | Horizontal and vertical sync polarity |

The timing and clock registers can only be changed while video is off (VIDCON.EN = 0). Turning video on with an HTOTAL that breaks the rule is refused, and VIDSTAT.BADTIMING is set.

Horizontal blanking is the horizontal retrace; lines VVISIBLE to VTOTAL−1 are the vertical retrace.

### 3.5 Presets

The boot ROM has a table of these modes. Software can also set any timing that follows the rule.

| Mode | N | Pixel clock | Total (H × V) | Slots per line | Refresh | Compared with the standard |
|------|---|-------------|---------------|----------------|---------|----------------------------|
| 640×480 | 12 | 25.0 MHz | 800 × 525 | 400 | 59.5 Hz | VGA is 25.175 MHz; monitors accept 25.0. Power-on default |
| 640×480 | 12 | 25.0 MHz | 800 × 625 | 400 | 50.0 Hz | Non-standard; test per monitor |
| 720×576 | 11 | 27.27 MHz | 864 × 631 | 396 | 50.0 Hz | 576p is 27.0 MHz, 864 × 625. Line rate 1% high |
| 720×480 | 11 | 27.27 MHz | 864 × 525 | 396 | 60.1 Hz | 480p is 27.0 MHz, 858 × 525 |
| 800×600 | 8 | 37.5 MHz | 1008 × 620 | 336 | 60.0 Hz | Shorter blanking than VESA's 40 MHz mode |
| 800×600 | 6 | 50.0 MHz | 1040 × 666 | 260 | 72.2 Hz | Exactly VESA 800×600 @ 72 |
| 1024×768 | 5 | 60.0 MHz | 1248 × 800 | 260 | 60.1 Hz | Shorter blanking than VESA's 65 MHz mode |
| 1280×720 | 4 | 75.0 MHz | 1668 × 750 | 278 | 59.95 Hz | 720p is 74.25 MHz, 1650 × 750 |
| 1280×720 | 4 | 75.0 MHz | 2004 × 750 | 334 | 49.9 Hz | 720p50 is 74.25 MHz, 1980 × 750 |

**The cost of whole-number division:** the TV modes (576p, 480p, 720p) come out about 1% off their standard pixel clocks. The line and frame rates are matched by adjusting the totals. Computer monitors accept this; some TVs check timing strictly (open point V9). The Amiga had the same issue, which is why PAL and NTSC machines had different crystals. On the final PCB, a 27 MHz crystal would allow a 297 MHz master (27 × 11), which hits the TV clocks exactly: 74.25 MHz at N = 4 and 27.0 MHz at N = 11. The CPU would then run at 12.375 MHz.

Low-resolution looks (320×240, 360×288 etc.) are made with layer scaling (section 4.5), not by changing the timing. This keeps the screen locked to one mode and lets low- and high-resolution layers be shown together.

### 3.6 Beam position

| Register | Contents |
|----------|----------|
| BEAMPOS (read) | `vline` (bits 26–16), `hpixel` (bits 10–0) as one 32-bit read so they always match |
| SLOTPOS (read) | `vline` (bits 26–16), `hslot` (bits 8–0): the beam position in memory slots |
| FRAMECOUNT (read) | Frame counter, 16-bit, increments at the start of vertical blanking |

### 3.7 Video interrupts

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
 SDRAM ──DMA, just in time──▶ 32-byte buffers L0..L3 ──┐
                                                        ├─▶ priority mux ─▶ palette ─▶ DVI encoder ─▶ HDMI
 block RAM (text) ─▶ text layer ────────────────────────┤        ▲
 SDRAM ──DMA, just before X──▶ sprite data registers ───┘   PRIO register
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

### 5.1 Fetched on demand, as the beam scans

There are no line buffers. Video data is fetched by DMA during the line it is shown on, a few pixels ahead of the beam, as the Amiga does with bitplane DMA.

- Each bitmap layer has a **32-byte buffer** (4 bursts), made from FPGA logic, not block RAM. It does the job of the Amiga's bitplane data registers. The pixel output takes data from the front of the buffer, and DMA tops it up from the back.
- **Display fetch slots** are fixed beam positions in every line (spec 5, section 7):
  - **Normal:** every slot with `hslot % 4 == 1`: 8 bytes every 4 slots.
  - **Wide fetch** (VIDCON.WIDE = 1): also every slot with `hslot % 4 == 3` in the visible part of the line. Those come out of the free pool, so the copper and blitter lose them while it is on, and sprites are more likely to borrow CPU slots. Layers never touch the CPU's slots.
- **Which layer or sprite gets each slot:** whichever will run out of data soonest (earliest deadline first). With a given screen setup this always works out the same, so the fetch pattern repeats exactly on every line and every frame.
- **Prefetch:** before a layer's window starts, its buffer is filled with its first 2 bursts. For windows that start at the left edge, this happens in the horizontal blanking before the line. For windows that start further right, it happens in display slots just before the window. This replaces the Amiga's DDFSTRT, which had to be set by hand earlier than the display window.
- The first burst is rounded down to an 8-byte boundary, and leading pixels are skipped to give the exact SCROLLX position. A burst never crosses an SDRAM row, because rows are 1 KB and bursts are 8-byte aligned.
- **Vertical scaling** re-fetches the source line for each screen line it appears on. There is nothing kept from the line before.

The buffers sit between the 100 MHz DMA side and the pixel clock. Both come from the same master clock, so the hand-over is fully predictable.

### 5.2 Budget: bytes per pixel

Because data is fetched while it is shown, the budget is a **rate**: how many bytes can be fetched for each pixel the beam passes.

| Fetch | Bytes per pixel |
|-------|-----------------|
| Normal | N ÷ 12 |
| Wide | N ÷ 6 |

A layer needs `bits per pixel ÷ 8 × HSTEP ÷ 256` bytes per screen pixel. At every point across the screen, **the layers whose windows cover that point must add up to no more than the budget.** The 32-byte buffers smooth out small differences, but not a whole line's worth.

| Mode | N | Normal | Wide |
|------|---|--------|------|
| 640×480 @ 60 or 50 | 12 | 1.0 | 2.0 |
| 720×576 @ 50, 720×480 @ 60 | 11 | 0.92 | 1.83 |
| 800×600 @ 60 | 8 | 0.67 | 1.33 |
| 800×600 @ 72 | 6 | 0.5 | 1.0 |
| 1024×768 @ 60 | 5 | 0.42 | 0.83 |
| 1280×720 @ 60 or 50 | 4 | 0.33 | 0.67 |

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
| 640×480: one full layer at 8bpp | 1.0 | Normal (1.0) |
| 640×480: two full layers at 4bpp (like dual playfield) | 1.0 | Normal |
| 640×480: two 320×240 8bpp layers at 2× + text | 1.0 | Normal |
| 640×480: 8bpp layer + full-screen 8bpp overlay | 2.0 | Wide (2.0) |
| 720×576: two 360×288 8bpp layers at 2× | 1.0 | Wide (1.83) |
| 800×600 @ 60: one full layer at 8bpp | 1.0 | Wide (1.33) |
| 1024×768: one full layer at 4bpp | 0.5 | Wide (0.83) |
| 1280×720: one full layer at 4bpp | 0.5 | Wide (0.67) |
| 1280×720: 640×360 4bpp at 2× + 1280×720 2bpp overlay | 0.25 + 0.25 = 0.5 | Wide (0.67) |
| 1280×720: one full layer at 8bpp | 1.0 | **No** (0.67) |
| 1280×720: 640×360 8bpp at 2× | 0.5 | Wide |

Windows help: a status bar that sits below a game area, not on top of it, adds nothing to the budget on the lines where the game area is shown.

### 5.4 Sprites: fetched just before they are drawn

Sprite data is fetched on demand, just before the beam reaches each sprite, in the same way as layer data. Nothing is fetched a line ahead.

- **Which sprites are on the next line:** at the start of horizontal blanking, the sprite unit checks every sprite's Y position and height (held in registers, so no memory access) and sorts the active ones by X.
- **Fetch window:** each active sprite's line of data (16 bytes, 2 bursts; the sprite spec will confirm the size) is fetched into its **sprite data register** (16 bytes, built from logic) during the **32 slots before its first pixel**. That is 64 pixels ahead at 640×480. Sprites near the left edge are fetched at the end of the blanking before the line.
- **Slots a sprite can use, in order of preference:**
  1. Free odd slots (`hslot % 4 == 3`, when wide fetch is not using them)
  2. Display-fetch slots that no layer needs at that moment (its buffer is full)
  3. Even slots the CPU is not using
  4. **Even slots the CPU wants: taken only when the sprite would otherwise miss its deadline**
- The scheduler takes a CPU slot as late as possible: only when the slots left before the deadline, not counting the CPU's, are fewer than the bursts the sprite still needs. With a given screen setup and program, the pattern is the same every time.
- **Cost to the CPU:** each slot taken delays the CPU by 2 clocks (160 ns), and only if it wanted that slot. Two clocks is an even number, so the CPU stays on its even slots afterwards (spec 5, section 5).
  - Sprites spread out across the line, with wide fetch off: the free slots are enough, so the CPU is not slowed.
  - Several sprites starting at the same X, or wide fetch on: some CPU slots are taken. The worst case is 8 sprites on one line, each taking both its bursts from the CPU: 16 slots = 32 CPU clocks, 8% of a 640×480 line. This only happens on lines with sprites, and only when the CPU is accessing Chip RAM at those moments.
- **Always fits:** the 32-slot window holds 8 `hslot % 4 == 1` slots (for layers), 8 `hslot % 4 == 3` slots and 16 even slots. Even 8 sprites starting at the same X (16 bursts) fit without touching the layers' slots. Fixed blanking slots (refresh, audio, storage) are never taken. If a sprite still misses its deadline (e.g. an unusual setup that crowds blanking), that sprite's line is transparent and SPRMISS is set in VIDSTAT.

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
| `0x004` | VIDSTAT | VBLANK (0), LINE (1), OVERRUN L0–L3 (4–7), INVBLANK (8, read-only), PCLKLOCK (9, read-only), BADTIMING (10), SPRMISS (11) | Sticky flags, write 1 to clear |
| `0x008` | VIDINTEN | Same bit layout as VIDSTAT | Interrupt enables |
| `0x00C` | BEAMPOS | `vline` 26–16, `hpixel` 10–0 | Read-only |
| `0x010` | FRAMECOUNT | 15–0 | Read-only |
| `0x048` | SLOTPOS | `vline` 26–16, `hslot` 8–0 | Read-only |
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
| `0x044` | PCLKDIV | 3–0 | N: pixel clock = 300 MHz ÷ N, N = 4–12 (video off only) |

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
| Palette: 1024 × 24-bit | 2 |
| Text buffer 8 KB + font 4 KB | 6 |
| **Total for video** | **8** |

The layer buffers (4 × 32 bytes) and sprite data registers (8 × 2 × 16 bytes) are small enough to build from FPGA logic.

Clocks use two of the LX25's four PLLs: one for the fixed master clocks, one as the HDMI ×10 multiplier.

## 8. Open points

| # | Item |
|---|------|
| V1 | Sprite spec: size, formats, collision detection; section 5.4 sets how they are fetched |
| V11 | Reusing a sprite's hardware further right on the same line once it has been drawn, to show more than 8 sprites per line. The just-in-time fetch makes this possible |
| V2 | Test 50 Hz modes (640×480 @ 50 and the standard 576p/720p50) on real HDMI monitors and TVs |
| V3 | Whether 4 layers is the right number; each extra layer costs one block RAM and a little logic |
| V4 | 16-bit direct-colour and tile-map layer types (version 2) |
| V5 | Horizontal wrap for bitmap layers (scroll around a fixed-width ring), so endless side-scrollers need less copying |
| V6 | HDMI audio (sending sound over HDMI as well as the jack): possible later, needs the HDMI data-island encoder |
| V7 | Confirm the FPGA speed grade from the chip marking; 720p needs the -3 grade's serialiser speed |
| V8 | Check the pixel pipeline (layers, priority, palette) meets timing at 75 MHz in ISE |
| V10 | Check in ISE that the ×10 PLL can take the divided pixel clock from a global clock buffer, and that its jitter is low enough for HDMI |
| V9 | Some TVs expect HDMI info packets for 576p/720p and may not accept plain DVI; test, and add the packets if needed (same work as V6) |

## 9. Tests

- **Timing:** check sync positions and frame rate for every preset in simulation; check real monitors lock on to each.
- **Clock change:** switch between presets at run time; the ×10 PLL relocks and PCLKLOCK sets, with no effect on the CPU or memory side.
- **Beam lock:** for every preset, assert that each fixed DMA slot falls at the same `hslot` on every line, and that the CPU's even slots stay even across line boundaries.
- **Fetch budget:** for every example in 5.3, assert no layer buffer runs empty; for over-budget setups, assert OVERRUN is set on the right layer only.
- **Fetch pattern:** assert the DMA pattern is identical on every line for a fixed screen setup.
- **Sprites:** 8 sprites at the same X with wide fetch on: all are drawn, the CPU loses at most 16 slots on that line, and it stays on even slots afterwards. Sprites spread across the line with wide fetch off: the CPU loses none.
- **Golden images:** render test screens in simulation (windows, scroll, scale, priority, transparency, palette) and compare frame dumps with images made by a Python reference model.
- **Register timing:** a write during line L−1's visible part changes line L exactly; a write during its blanking changes line L+1.
- **No CPU slowdown:** with all layers on and wide fetch, the CPU zero-wait test from spec 5 still passes.
