# Spec 4: Video

Status: **v1 scope**

## 1. Goals

- DVI output over the HDMI connector and, at the same time, 24-bit VGA through the KS3's ADV7125 video DAC.
- **One fixed video mode, chosen when the FPGA is built:** 640×480 at 60 Hz (the default) or 800×600 at 60 Hz. There are no timing registers.
- **Three bitmap layers**, each with its own display window, scroll, scale and palette block. Each layer is **planar** (1 to 8 Amiga-style bitplanes) or **chunky** (1, 2, 4 or 8 bits per pixel).
- **Amiga-style bitplane DMA:** each plane has a pointer (BPLxPT) that moves through memory as the picture is shown, a modulo (BPLMOD) added at the end of each line, and a data register (BPLxDAT). The copper (or the CPU) resets the pointers every frame.
- **No hidden buffers.** Each plane has just its data register and its shift register, as on the Amiga. The DMA loads the data registers just in time; the copper or CPU can load them too.
- **Fetch is automatic:** the hardware works out when and what to fetch from each layer's window, so there are no fetch start and stop registers (the Amiga's DDFSTRT/DDFSTOP).
- **Direct colour:** the three layers can be joined into one direct-colour picture, one layer per channel (red, green, blue), up to 24 bits per pixel.
- **Everything runs from one master clock.** Every scan line is a whole number of memory slots, so DMA happens at the same beam positions on every line. The display uses only its own memory cycles (spec 5), so it never slows the CPU.

## 2. Comparison with the Amiga (OCS/ECS)

| Feature | Amiga | retro68k v1 |
|---------|-------|-------------|
| Playfields | 1, or 2 in dual-playfield mode | 3 layers, in any order |
| Pixel layout | Planar, 1–6 planes | Per layer: planar with 1–8 planes, or chunky with 1, 2, 4 or 8 bits per pixel |
| Colours | 32 from 4096 (EHB, HAM) | 256-entry palette of 24-bit colours; each layer of up to 4 bits picks a 16-colour block. Direct colour up to 24 bits |
| Plane pointers | BPLxPT, moved on by the fetch and BPLxMOD; rewritten by the copper each frame | The same, per layer: BPL0PT–BPL7PT and BPLMOD |
| Data registers | BPLxDAT, loaded by DMA; writing BPL1DAT starts the shifters | The same: BPL0DAT–BPL7DAT; writing BPL0DAT completes a group |
| Display window | One per screen (DIWSTRT/DIWSTOP) | One per layer (WINX/WINY) |
| Fetch window | DDFSTRT/DDFSTOP, set by hand | Worked out from each layer's window and scroll |
| Scrolling | Fine scroll 0–15 px via BPLCON1, coarse by pointers | The same: SCROLLX (0–15 px) and pointers |
| Pixel size | Lores/hires, line doubling by copper tricks | 1×, 2×, 4× or 8× per layer, horizontal and vertical separately |
| Video timing | Fixed (PAL or NTSC) | Fixed when the FPGA is built |

## 3. Clocks, timing and the beam

### 3.1 Clocks

The KS3 build has one MMCM (the Artix-7's clock generator). It runs at 1000 MHz internally from the board's 50 MHz oscillator, and every clock is a whole-number division of that:

| Clock | Frequency | Use |
|-------|-----------|-----|
| System / SRAM controller | 100 MHz | Memory slots of 100 ns (spec 5) |
| fx68k | 40 MHz | 20 MHz 68000 |
| Pixel clock | 25 MHz (640×480) or 40 MHz (800×600) | Video |
| HDMI serialiser | 5 × pixel clock | Double-rate serialisers (OSERDESE2) |

The pixel clock is the 200 MHz "master" divided by N: N = 8 for 640×480 and N = 5 for 800×600. In simulation it is modelled as the 200 MHz master passed through a clock buffer with an enable, which lets every Nth edge through.

**VGA:** the ADV7125 takes 8 bits per colour over 4 pins at double rate. It shows the same picture and timing as HDMI.

### 3.2 The two modes

| Mode | N | Pixel clock | Total (H × V) | Sync (H, V) | Slots per line | Refresh |
|------|---|-------------|---------------|-------------|----------------|---------|
| 640×480 (default) | 8 | 25.0 MHz | 800 × 525 | 656–752, 490–492, both negative | 320 | 59.5 Hz |
| 800×600 | 5 | 40.0 MHz | 1056 × 628 | 840–968, 601–605, both positive | 264 | 60.3 Hz |

640×480 uses 25.0 MHz instead of VGA's 25.175 MHz; monitors accept this. 800×600 is exactly the VESA mode.

Each line is a whole number of 100 ns slots, so DMA happens at the same beam positions on every line, as on the Amiga.

`hpixel` counts from 0 at the first visible pixel, `vline` from 0 at the first visible line. Blanking (front porch, sync, back porch) follows the visible part. Lines VVISIBLE to VTOTAL − 1 are the vertical retrace.

The build picks the mode with `PIX_N` (8 or 5) in `fpga/ks3/build.sh`. Software reads the screen size from VIDSIZE.

### 3.3 Beam position

| Register | Contents |
|----------|----------|
| BEAMPOS (read) | `vline` (bits 26–16) and `hpixel` (bits 10–0), as one 32-bit read so they always match |
| FRAMECOUNT (read) | Frame counter, 16 bits, counts up at the start of vertical blanking |

### 3.4 Video interrupts

These reach the CPU through the interrupt controller (spec 13), as the sources VBLANK, LINE and VIDERR. The default level is 5.

| Flag | When |
|------|------|
| VBLANK | Start of vertical blanking (`vline` = VVISIBLE, `hpixel` = 0) |
| LINE | Start of line `vline` = LINECMP (`hpixel` = 0), for raster effects without the copper |
| OVERRUN | A layer's next group was not ready when its shifters needed it (section 5.3); goes to VIDERR |

Each flag has an enable bit in VIDINTEN and a sticky flag in VIDSTAT, which is cleared by writing 1.

## 4. Layers

### 4.1 Overview

There are three bitmap layers, L0–L2. For every pixel, the hardware takes the colour of the highest-priority layer whose pixel is not transparent. Where no layer has a pixel, the background colour shows. In direct-colour mode (section 4.9) the three layers make one picture instead.

```
          per layer, per plane
 Chip RAM ──DMA──▶ BPLxDAT ──▶ shifter ──┐
                     ▲                   ├─▶ priority ─▶ palette ─▶ HDMI and VGA
               CPU / copper   L0, L1, L2 ┘     (or direct colour)
```

Each layer runs on its own: its own pointers, data registers, shifters, window, scroll and scale. The layers only meet at the end, where one pixel is picked from them.

### 4.2 Pixel formats

| Format | Layout |
|--------|--------|
| **Planar**, 1–8 planes | As on the Amiga: each plane holds one bit of every pixel, 16 pixels per word, leftmost pixel in bit 15. Plane 0 gives bit 0 of the pixel value, plane 1 bit 1, and so on |
| **Chunky**, 1, 2, 4 or 8 bits per pixel | Pixels packed in words, leftmost pixel in the most significant bits. A chunky layer is one plane: it uses only BPL0PT and BPL0DAT |

### 4.3 Display window

Each layer has a rectangle `XSTART ≤ x < XEND`, `YSTART ≤ y < YEND` (WINX, WINY) in screen pixels and lines: the layer's display start and stop. Outside it the layer is transparent. Windows can overlap or sit side by side, so status bars and split screens need no copper. A full-screen layer is simply 0, 0, HVISIBLE, VVISIBLE.

### 4.4 Plane pointers, modulo and scroll

**Each plane has its own pointer, BPLxPT, which counts up through memory as the plane's words are fetched**, as on the Amiga.

| Register | Bits | Meaning |
|----------|------|---------|
| BPL0PT–BPL7PT | 23 (even) | Byte address in Chip RAM of the plane's next word |
| BPLMOD | 16, signed (even) | Bytes added to every pointer of the layer at the end of each line, as the Amiga's BPL1MOD/BPL2MOD |
| SCROLLX | 4 | Fine scroll: pixels (0–15) skipped at the start of each line, as the Amiga's BPLCON1 delay |

- **At the end of each line** inside the layer's window, each pointer the layer uses ends up at the line's start plus **the line's length plus BPLMOD**. The line's length is the window width in source pixels × bits per pixel ÷ 8, rounded up to whole words (for planar layers, one plane's worth, so 1 bit per pixel). Fine scroll does not change it: with fine scroll, one extra word is fetched and not counted.
- **The pointers are not reset by the hardware.** As on the Amiga, the copper (spec 10) writes them at the start of every frame, normally in the vertical blank (or the CPU does it in its VBLANK interrupt). If nothing rewrites them, the next frame carries on through memory.
- Vertical scrolling and coarse horizontal scrolling are done by changing the pointers. Split screens are done by writing new pointers mid-frame.
- BPLMOD = 0 shows a picture whose lines follow each other. A 320-pixel window into a 640-pixel-wide 4bpp chunky picture has a line length of 160 bytes, so BPLMOD = 160. A negative BPLMOD shows lines again or flips the picture: −(row bytes + line length) steps back one row.
- With vertical scaling, the pointers return to the line's start after each copy of a source line except the last.
- **Fine scroll** on a chunky layer stays within a word: SCROLLX is taken modulo 16 ÷ bits per pixel (0–1 at 8bpp, 0–3 at 4bpp, 0–7 at 2bpp, 0–15 at 1bpp).

| Layout | Pointers | BPLMOD |
|--------|----------|--------|
| Chunky 320×240 at 8bpp | BPL0PT = base | 0 |
| Planar 320×256, 5 planes, separate as on the Amiga | BPLpPT = base + p × 10240 | 0 |
| Planar 320×256, 5 planes, interleaved (plane lines next to each other) | BPLpPT = base + p × 40 | 4 × 40 = 160 |

### 4.5 Scaling

CTRL.HSCALE and CTRL.VSCALE each pick 1×, 2×, 4× or 8× (values 0–3). Each source pixel is repeated that many times across and each source line that many times down: 2× shows a 320×240 picture full-screen at 640×480. There is no fractional scaling or shrinking.

### 4.6 Transparency and palette

- **Palette:** 256 entries of 24-bit RGB, memory-mapped. The CPU and copper can write any entry at any time; a write takes effect from the next pixel, so mid-line colour changes work.
- For layers of up to 4 bits per pixel (chunky 1, 2 or 4bpp, planar 1–4 planes), the colour index is `PALOFS × 16 + pixel value`. Deeper layers (chunky 8bpp, planar 5–8 planes) use the pixel value directly and ignore PALOFS.
- If CTRL.TRANSP is set, pixel value 0 is transparent and lower layers show through. If it is clear, the layer is solid inside its window.

### 4.7 Text

There is no text layer. Text is drawn into a bitmap by software, as on the Amiga; the boot ROM draws its console with an 8×16 font (Spleen, code page 437, BSD licence, `third_party/spleen`) into a 1-plane layer.

### 4.8 Priority

PRIO lists the layer numbers from front to back:

| Bits | Field | Meaning |
|------|-------|---------|
| 1–0 | FRONT | Layer in front |
| 3–2 | MIDDLE | |
| 5–4 | BACK | Layer at the back |

Any order is allowed; the value 3 names no layer. The default is L0 in front, then L1, then L2.

### 4.9 Direct colour

With VIDCON.DIRECT set, the palette and priority are not used. Every visible pixel is made from the three layers' pixel values:

| Channel | From | Depth |
|---------|------|-------|
| Red | L0 | L0's planes (planar) or bits per pixel (chunky) |
| Green | L1 | L1's |
| Blue | L2 | L2's |

- Each channel's value is widened to 8 bits by repeating its bits (a 5-bit value `abcde` becomes `abcdeabc`), so full scale stays full scale.
- One rule covers 24-bit (8/8/8 planes or 8bpp chunky), 16-bit (5/6/5), Amiga 12-bit (4/4/4) and 9-bit (3/3/3) colour. The bandwidth is the total number of planes (section 5.2).
- Software sets the three layers to the same window, scroll and scale. Where a layer has no pixel (outside its window, not enabled, or out of data), its channel is 0.
- CTRL.TRANSP and PALOFS have no effect in direct colour.

## 5. Fetch

### 5.1 Data registers and shifters

- Each plane of each layer has a data register **BPLxDAT** and a 16-bit **shift register**. There is no other storage: the data registers hold the layer's next group of 16 source pixels (one word per plane), while the shifters show the current group.
- **A group is complete when BPL0DAT is written.** The DMA writes a group's words from the highest plane down, with plane 0 last. The CPU or copper can also write the data registers (for example with DMA off), and its write of BPL0DAT completes the group the same way.
- When a layer's shifters need a new group (at the first pixel of its window, then every 16 source pixels), they take all of its data registers at once. That empties the data registers, and the DMA fetches the next group.
- The display owns **memory cycles 1 and 2 of every slot**: 4 bytes every 100 ns (spec 5, section 4.3). It never touches the CPU's cycle 0.
- **Order:** when several layers want a word, the lowest-numbered layer goes first. A layer's group is always asked for to the end once started. With a given screen setup, the fetch pattern is the same on every line and every frame.
- **Start and stop:** at the start of the horizontal blank, each layer whose window covers the next line gets its first group fetched; the number of groups on the line comes from the window width, scale and fine scroll. Nothing is fetched outside the windows.
- With vertical scaling, each source line is fetched again for every screen line it appears on.

### 5.2 Budget

Data is fetched while it is shown, so the budget is a **rate**: the bytes that can be fetched for each pixel the beam passes.

| Mode | Budget (bytes per pixel) |
|------|--------------------------|
| 640×480 | 1.6 |
| 800×600 | 1.0 |

A layer needs `bits per pixel ÷ 8 ÷ HS` bytes per screen pixel (for planar, bits per pixel = planes). At every point across the screen, the layers whose windows cover it must add up to no more than the budget.

| Screen setup | Bytes per pixel | 640×480 | 800×600 |
|--------------|-----------------|---------|---------|
| One 8bpp layer at 1× | 1.0 | Fits | Fits |
| 5 planes at 1× (Amiga 32 colours) | 0.625 | Fits | Fits |
| 5 planes + 3 planes at 2× (dual playfield) | 0.5 | Fits | Fits |
| 8bpp layer + 4bpp layer at 1× | 1.5 | Fits | **No** |
| Direct colour 16-bit (5/6/5) at 2× across | 1.0 | Fits | Fits |
| Direct colour 24-bit at 2× across (320 wide) | 1.5 | Fits | **No** |
| Two 8bpp layers at 1× | 2.0 | **No** | **No** |

Windows help: a status bar below a game area, not on top of it, adds nothing on the lines where the game area is shown.

Each layer has one group of time in hand (its data registers), so the order in 5.1 matters only near the budget: put the deepest layer at L0.

### 5.3 When a layer runs short

If a layer's next group is not complete when its shifters need it, the layer shows transparent pixels (in direct colour: 0) for that group, and tries again at the next one. Its OVERRUN flag is set, and VIDERR can raise an interrupt. Nothing else on the display goes wrong, and the CPU is never affected.

### 5.4 When register writes take effect

| Registers | Take effect |
|-----------|-------------|
| CTRL, WINX, WINY, SCROLLX | At the start of the horizontal blank before each line. **To change line L, write during the visible part of line L − 1 or earlier** |
| BPLxPT, BPLMOD | At once: they are live. The next word fetched uses the new value. A CPU or copper write wins over the DMA's own change in the same clock |
| BPLxDAT | At once; a write of BPL0DAT completes the group |
| PRIO, BGCOLOR | At the start of each line |
| VIDCON.DIRECT, palette | At once (next pixel) |

## 6. Registers

The offsets are within the custom register block at `0xE00000`. Spec 3 has the full map.

### 6.1 Global

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x000` | VIDCON | EN (0), BLANKALL (2), DIRECT (4) | Video on; show the background colour only; direct colour |
| `0x004` | VIDSTAT | VBLANK (0), LINE (1), OVERRUN L0–L2 (6–4), INVBLANK (8, read-only) | Sticky flags, write 1 to clear |
| `0x008` | VIDINTEN | Same layout as VIDSTAT | Interrupt enables |
| `0x00C` | BEAMPOS | `vline` 26–16, `hpixel` 10–0 | Read-only |
| `0x010` | FRAMECOUNT | 15–0 | Read-only |
| `0x014` | LINECMP | `vline` 26–16 | LINE interrupt line |
| `0x018` | BGCOLOR | 23–0 RGB | Background colour |
| `0x01C` | PRIO | See 4.8 | Layer order |
| `0x020` | VIDSIZE | VVISIBLE 26–16, HVISIBLE 10–0 | Read-only: the screen size of the built mode |

For the layers to fetch, DMACON (spec 5, section 8) must also have DMAEN and VIDEN set.

### 6.2 Per layer

Layer n (0–2) is at `0x100 + n × 0x80`.

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `+0x00` | CTRL | EN (0), PLANAR (1), BPP (3–2: chunky 1/2/4/8), TRANSP (4), HSCALE (7–6), VSCALE (9–8), PALOFS (15–12), PLANES (18–16: planes − 1) | |
| `+0x04` | WINX | XSTART 26–16, XEND 10–0 | Window, pixels |
| `+0x08` | WINY | YSTART 26–16, YEND 10–0 | Window, lines |
| `+0x0C` | SCROLLX | 3–0 | Fine scroll, pixels |
| `+0x10` | BPLMOD | 15–0, signed, even | Added to the pointers at the end of each line |
| `+0x20`–`+0x3C` | BPL0PT–BPL7PT | 22–0, even | Plane pointers (chunky: BPL0PT only) |
| `+0x40`–`+0x5C` | BPL0DAT–BPL7DAT | 15–0 | Plane data registers (chunky: BPL0DAT only) |

### 6.3 Memory-mapped area

| Area | Location | Contents |
|------|----------|----------|
| Palette | `0xE04000`–`0xE043FF` | 256 × 32-bit, `0x00RRGGBB` |

## 7. FPGA resources

| Item | Resource |
|------|----------|
| Palette, 256 × 24 bits | 1 block RAM per copy (CPU read port and pixel read port) |
| 24 pointers, 24 data registers, 24 shift registers | Logic |
| Clocks | One MMCM, shared with the rest of the design |

## 8. Open points

| # | Item |
|---|------|
| V1 | Check the pixel pipeline meets timing at 40 MHz in Vivado |
| V2 | Some TVs may not accept plain DVI; test, and add HDMI info packets if needed |

## 9. Tests

- **Timing:** sync positions, totals and frame rate for both modes in simulation; real monitors lock on to both, on HDMI and VGA.
- **Golden images** (`make vtest` in `sim/`): random pictures in every layer format (chunky and planar, scaling, fine scroll, modulo, a flipped layer, transparency, priority, and direct colour), compared pixel by pixel with a Python model of this spec (`sim/vtest/vmodel.py`). No OVERRUN.
- **Boot ROM:** the console and a 4-plane interleaved picture, checked pixel by pixel.
- **Fetch budget:** for every example in 5.2 that fits, no OVERRUN. For one that does not fit, OVERRUN is set on the right layer only.
- **Register timing:** a CTRL write during line L − 1's visible part changes line L.
- **CPU:** with all layers fetching, the CPU never waits (spec 5 zero-wait test).

## 10. Later versions

- More layers, fractional scaling and shrinking
- Programmable timing, more modes (720p, 1024×768, 50 Hz)
- Wide fetch (memory cycle 3 for the display)
- Sprites (spec 9, on hold)
- EHB and HAM modes, a 1024-entry palette, tile-map layers
- HDMI audio
