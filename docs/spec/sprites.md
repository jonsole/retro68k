# Spec 9: Sprites

Status: **v1 scope**

Sprites are small images drawn over (or between) the layers at any position, without touching the layers' memory. Version 1 has eight sprites. As on the Amiga, each has a pointer into Chip RAM for its image (SPRxPT), and its window and settings are plain registers (SPRxH, SPRxV, SPRxCTL) that the CPU or copper writes: the copper resets the pointers every frame, and can reuse a sprite further down the screen by writing its registers again. The images are bigger and more colourful than the Amiga's, and their data is fetched just in time, through the same scheduler as the bitplanes, into a FIFO per sprite.

(An earlier design, with a 64-entry sprite table and fractional scaling, is in git history at commit 7df97fd. It was dropped for size.)

## 1. Summary

| Item | Value |
|------|-------|
| Sprites | 8 (SPR0–SPR7). Each can be reused further down the screen by the copper rewriting its registers |
| Window | HSTART–HSTOP across, VSTART–VSTOP down, like a layer's window. The image's size follows from the window and the magnify |
| Width | Any; one line must fit the 32-word FIFO: up to 64 source pixels at 8 bpp, 128 at 4 bpp, 256 at 2 bpp |
| Colours | 2, 4 or 8 bits per pixel. 2 and 4 bpp: 3 or 15 colours + transparent, from any 16-colour block of the palette; 8 bpp: 255 colours + transparent, the whole palette |
| Position | Any pixel; clipped at the left, right and bottom edges by the hardware, at the top by software (section 3) |
| Flip | Horizontal and vertical |
| Magnify | ×1, ×2 or ×4, across and down separately |
| Depth | Per sprite: in front of all layers, between any two (in PRIO order), or behind all |
| Collisions | Sprite–sprite and sprite–layer, per pixel, latched (as the Amiga's CLXDAT) |
| Data registers | A 32-word FIFO per sprite (one line of the widest, deepest sprite) |
| Fetch | Just in time, deadline first, shared with the bitplanes (spec 4, section 5; spec 5, section 6). A sprite's next words are fetched as soon as its FIFO has room and a memory cycle is free, so most of each line is fetched ahead |

## 2. Comparison with the Amiga (OCS/ECS)

| Feature | Amiga | retro68k v1 |
|---------|-------|-------------|
| Sprites | 8 | 8 |
| Pointers | SPRxPT, rewritten by the copper each frame | The same |
| Position and settings | SPRxPOS, SPRxCTL (HSTART, VSTART, VSTOP): fetched by the DMA from control words in the sprite's data, or written by the CPU/copper | SPRxH, SPRxV (start and stop across and down: a window, as a layer has), SPRxCTL: plain registers, written by the CPU or copper only; the data in memory is image only |
| Reuse down the screen | The data holds more control words after each sprite | The copper writes the sprite's registers again, after a WAIT |
| Settings | Position, height | A window (any width up to the FIFO, any height), bits per pixel, flips, magnify, depth among the layers, palette block |
| Width | 16 pixels (lores) | Set by the window: up to 64 source pixels at 8 bpp, 128 at 4 bpp, 256 at 2 bpp |
| Colours | 3 + transparent; 15 with two attached sprites | 3, 15 or 255 + transparent, every sprite |
| Pixel format | Two bitplanes | Chunky: 2, 4 or 8 bits per pixel, first pixel in the high bits |
| Data registers | SPRxDATA, SPRxDATB: one line of 16 pixels | A 32-word FIFO: a whole line of up to 64 pixels at 8 bpp |
| Fetch | Two words per sprite per line, in fixed slots in the horizontal blank | Just in time, deadline first; early when cycles are free |
| Manual mode | Write SPRxDATA/B with DMA off | Push words into SPRxDAT with the sprite's DMA off |
| Priority | Fixed in pairs against the playfields | Per sprite, any depth among the layers |
| Flip, magnify | None | Both |
| Collision | CLXDAT | SPRCOLL: per sprite, against the other sprites and each layer |

## 3. Sprites: pointer, position and settings

Each sprite has three registers (section 6):

- **SPRxPT** points at the sprite's image in Chip RAM: its lines one after another, top line first, each in whole words (section 3, below). As a plane pointer does, it moves through the image as it is fetched, so the hardware does not reset it: the copper (or the CPU) writes the eight pointers in every vertical blank.
- **SPRxH** and **SPRxV** give the sprite's window, and **SPRxCTL** its settings. They are plain registers: the CPU or copper writes them, and they stay as written until written again. The image in memory is pixels only.

**The window** (SPRxH, SPRxV), as a layer's (spec 4, section 4.3):

| Register | Bits | Field | Meaning |
|----------|------|-------|---------|
| SPRxH | 11–0 | HSTART | First screen pixel of the sprite, signed (−2048 to 2047). Pixels left of the screen are clipped |
| SPRxH | 27–16 | HSTOP | Screen pixel just after the sprite, signed. Past the right edge clips |
| SPRxV | 10–0 | VSTART | First picture line of the sprite (0–575; 576 or more: not shown this frame) |
| SPRxV | 26–16 | VSTOP | Picture line just after the sprite. Past the bottom clips |

The image's size follows from the window: **source width** = (HSTOP − HSTART) ÷ HMAG pixels and **source height** = (VSTOP − VSTART) ÷ VMAG lines, each rounded up. A source line is stored in whole words, ⌈source width × BPP ÷ 16⌉ of them, and must fit the FIFO: at most 32 words (64 pixels at 8 bpp, 128 at 4 bpp, 256 at 2 bpp). A wider window shows the sprite's pixels up to that limit and is transparent beyond it.

**Clipping:** at the left, right and bottom the hardware clips: pixels outside the screen are not shown (those left of it are still fetched and dropped). At the top, VSTART cannot be above line 0: to show a sprite partly above the screen, point SPRxPT at its first visible line and set VSTART to 0.

**SPRxCTL:**

| Bits | Field | Meaning |
|------|-------|---------|
| 13–12 | BPP | 0 = 2, 1 = 4, 2 = 8 bits per pixel |
| 14 | HFLIP | Mirror left to right |
| 15 | VFLIP | Mirror top to bottom |
| 17–16 | HMAG | Each source pixel shown 1, 2 or 4 times across (0, 1, 2) |
| 19–18 | VMAG | Each source line shown on 1, 2 or 4 screen lines (0, 1, 2) |
| 21–20 | DEPTH | 0 = in front of all layers; 1 = behind the front layer; 2 = behind the middle layer; 3 = behind all layers (in PRIO order) |
| 27–24 | PAL | 2 and 4 bpp: the 16-colour block of the palette (colour = PAL × 16 + value). Not used at 8 bpp |

A sprite shows inside its window once per frame. A sprite whose DMA is on (SPRDMA) shows every frame where its registers say; to hide it, turn its DMA off, or set VSTART to 576 or more.

**Fetching:** as long as the sprite's window still has lines to come in this frame, the DMA keeps its FIFO filled: from the start of the frame (the vertical blank) until the window's last line has been fetched. So a sprite's first line is fetched ahead too, before VSTART.

**Starting.** At the start of each vertical blank, and whenever SPRxPT, SPRxH, SPRxV or SPRxCTL is written, the sprite starts again: its FIFO is emptied, and it will fetch its image from SPRxPT and show it from VSTART. (It is the copper's job to point SPRxPT at the image's first line, as for bitplanes.)

**Reusing a sprite further down the screen**, as Amiga programs do with their control words: after the sprite's last line, the copper WAITs, then writes the sprite's PT, window and CTL for its next use. The new use must start on a later line than the old one ends, and the writes must come after the old use's last line has been shown.

**How the pointer moves.** Each word fetched moves SPRxPT on by 2. At the end of each source line the pointer goes to that line's start + one line (⌈source width × BPP ÷ 16⌉ words); with VFLIP, to that line's start − one line, so the image is fetched bottom first (point SPRxPT at the image's last line). On the repeated lines of VMAG it goes back to the line's start, so the line is fetched again.

### 3.1 Pixels and colours

Image lines are **chunky**, as chunky layers are: 2, 4 or 8 bits per pixel, packed in words, the first pixel in the highest bits. A value of 0 is transparent. Other values are palette entries: at 8 bpp the value itself; at 2 and 4 bpp, PAL × 16 + the value.

### 3.2 Flip and magnify

- **HFLIP:** the DMA fetches each line's words last first, and the sprite shows each word's pixels in reverse order, so the line is mirrored. The image in memory is unchanged.
- **VFLIP:** the DMA fetches the image's lines bottom first: point SPRxPT at the image's last line, and the pointer steps back a line after each one (section 3).
- **HMAG** repeats each pixel 1, 2 or 4 times across; **VMAG** shows each source line on 1, 2 or 4 screen lines. A repeated line is fetched again (the FIFO cannot replay a line), so VMAG costs memory cycles on every screen line, and HMAG divides the cost across a line (section 5).

### 3.3 Depth and priority

Each sprite's DEPTH puts it in front of all three layers, between any two in their PRIO order, or behind all of them (in front of the background colour). Where two sprites overlap, the lower-numbered channel is in front. A layer's transparent pixels (TRANSP, value 0) show the sprites and layers behind them.

In direct-colour mode (VIDCON.DIRECT, spec 4, section 4.9) sprites are drawn in front of the picture with their palette colours, and DEPTH is not used.

## 4. Data registers: the FIFO

Each sprite has a **FIFO of 32 words**, its data registers: one source line of up to 32 words (64 pixels at 8 bpp, 128 at 4 bpp, 256 at 2 bpp). The DMA pushes the image's words in at the back; the sprite takes them from the front as it is drawn, a line's worth per screen line (⌈source width × BPP ÷ 16⌉ words: 1 to 32).

- **Fetching early.** The DMA pushes a sprite's words whenever its FIFO has room. So while a line is being drawn, the words it has finished with are already being replaced by the next line's, using any memory cycle nobody else wants. Fetching becomes urgent only when the FIFO is about to run out: then the sprite takes part in the deadline-first order with the layers, and may take the CPU's cycle (spec 5, section 6).
- **A sprite at the right edge** has only the horizontal blank (5.3 µs) to fetch its next line ahead, but it has finished its own line by then.
- **Manual mode.** With a sprite's DMA off (SPRDMA), the CPU or copper pushes the image's words into its FIFO by writing SPRxDAT. The sprite shows as its window and CTL say, taking a line's words from the FIFO on each line it shows. If the FIFO runs dry, the sprite is transparent where the words are missing and VIDSTAT.SPRUNDER is set.
- **Underrun.** If the DMA cannot keep a sprite's FIFO filled (section 5), the missing pixels are transparent and VIDSTAT.SPRUNDER (bit 7) is set; it can raise the VIDERR interrupt like OVERRUN.

## 5. Memory budget

Sprites and layers share one budget, ordered by deadline. The display's own memory cycles (1 and 3 of each slot, spec 5) give about **12 words per 16 screen pixels** for certain; cycles the CPU, audio and copper leave free give more.

- A **layer** needs, per 16 source pixels, 1 word per plane (planar) or b words at b bpp (chunky); at 2× scale across, half that per 16 screen pixels.
- A **sprite** needs BPP words per 16 source pixels while the beam is over it (2, 4 or 8); with HMAG ×2, half that per 16 screen pixels.
- Sprites side by side do not add up; sprites over the same pixels at the same time do. Because each FIFO holds a line ahead, what matters is mostly the total per line, not each moment: a whole line at 1× has 45 groups of 16 pixels, about 540 guaranteed words.

Sprites stacked over the same 16 screen pixels, guaranteed (more when cycles are free):

| Layers | Words per 16 pixels | 8 bpp | 8 bpp, ×2 across | 4 bpp | 2 bpp |
|--------|--------------------|-------|------------------|-------|-------|
| None | 0 | 1 | 3 | 3 | 6 |
| One 8 bpp layer at 2× | 4 | 1 | 2 | 2 | 4 |
| Two 5-plane layers at 2× (Amiga style) | 5 | 0 | 1 | 1 | 3 |
| Two 4-plane layers at 1× | 8 | 0 | 1 | 1 | 2 |
| Three 4-plane layers at 1× | 12 | 0 | 0 | 0 | 0 |

The FIFOs' lead lets sprites go well beyond these figures where the screen has quieter parts on the same line. The figures are worked out, not measured; to be measured in simulation (open point S1).

## 6. Registers

Offsets in the custom register block at `0xE00000`.

| Offset | Name | Access | Bits | Description |
|--------|------|--------|------|-------------|
| `0x500` | SPRDMA | Set/clear | SPR (7–0), SETCLR (15) | DMA on for sprite n (bit n). Set/clear, as DMACON. Default all on. A sprite fetches only while SPRDMA bit n, DMACON.SPREN and DMACON.DMAEN are all set |
| `0x504` | SPRCOLL | RW1C | SPR (7–0), L0 (15–8), L1 (23–16), L2 (31–24) | Collisions, sticky until cleared by writing 1. SPR bit n: an opaque pixel of sprite n was on the same screen pixel as another sprite's opaque pixel. Ln bit n: sprite n was on an opaque pixel of layer n (a pixel the layer draws: not transparent) |

Sprite n (0–7) at `0x520 + n × 0x20`:

| Offset | Name | Access | Bits | Description |
|--------|------|--------|------|-------------|
| `+0x00` | SPRxPT | RW | 22–1 | The next word of the sprite's image (even). Written by the copper each frame |
| `+0x04` | SPRxH | RW | HSTART (11–0), HSTOP (27–16), signed | The window across (section 3). Written by the CPU or copper |
| `+0x08` | SPRxV | RW | VSTART (10–0), VSTOP (26–16) | The window down |
| `+0x0C` | SPRxCTL | RW | as section 3 | Settings |
| `+0x10` | SPRxDAT | W, R | write: 15–0; read: COUNT (5–0) | Write: push a word into the FIFO (manual mode). Read: words in the FIFO (0–32) |

VIDSTAT bit 7, **SPRUNDER** (spec 4, section 6.1): a sprite's FIFO ran dry while it was being drawn. Sticky, with an enable in VIDINTEN; raises VIDERR like OVERRUN.

DMACON bit 5, **SPREN**: sprite DMA on (spec 5, section 8).

**When writes take effect:** a write to SPRxPT, SPRxH, SPRxV or SPRxCTL starts the sprite again (section 3): its FIFO is emptied, and the new settings apply from the next line. SPRDMA at once (a sprite whose DMA is turned off keeps what is in its FIFO).

## 7. Examples

A 32 × 24 sprite at 4 bpp, in colours 32–47, behind the front layer, on sprite 0 at line 100, pixel 200. The image is 24 lines of 8 words in Chip RAM at `ship`. Once, from the CPU:

```
    move.l  #((200+32)<<16)|200,SPR0+SPR_H(a4)      ; pixels 200-231
    move.l  #((100+24)<<16)|100,SPR0+SPR_V(a4)      ; lines 100-123
    move.l  #(1<<SPR_CTL_BPP_B)|(1<<SPR_CTL_DEPTH_B)|(2<<SPR_CTL_PAL_B),SPR0+SPR_CTL(a4)
```

In the copper list, every frame (in the vertical blank):

```
    CMOVEL  SPR0+SPR_PT,ship
```

To move the ship, write SPR0H and SPR0V (from the CPU, or with copper MOVEs in the vertical blank).

Reusing sprite 0 for a second ship lower down, from line 300: after the first ship's last line (123), the copper writes sprite 0 again:

```
    CWAIT   200,0
    CMOVEL  SPR0+SPR_H,((400+32)<<16)|400
    CMOVEL  SPR0+SPR_V,((300+24)<<16)|300
    CMOVEL  SPR0+SPR_PT,ship2
```

## 8. FPGA resources

| Item | Resource |
|------|----------|
| 8 FIFOs of 32 × 16 bits | Distributed RAM, about 100 LUTs |
| Fetcher: line addresses (flip, magnify), FIFO fill and deadlines, in the scheduler | About 500 LUTs |
| 8 pixel units: position, magnify, flip, pixel select | About 800 LUTs |
| Mixing with the layers (depth), collisions, registers | About 400 LUTs |
| Total | About 1,800–2,200 LUTs; no block RAM |

## 9. Open points

| # | Item |
|---|------|
| S1 | Measure how many stacked sprites each layer set-up allows (section 5), in simulation |
| S2 | Whether the sprites' share of the free cycles should be limited, so that a screen full of sprites cannot starve the CPU |

## 10. Tests

- **Golden images:** sprites of many window sizes, at every depth and magnify, flipped, clipped at all four edges, reused down the screen, at every DEPTH against layers in different PRIO orders, over transparent layer pixels, compared pixel by pixel with the Python video model extended with sprites.
- **Collisions:** known overlaps set exactly the expected SPRCOLL bits.
- **Manual mode:** a sprite fed by the CPU through SPRxDAT; an underrun sets SPRUNDER.
- **Stress:** sprites stacked over the same pixels with layers of each depth, to measure section 5's table.

## 11. Later versions

- A sprite table, so that the copper need not rewrite sprites to reuse them
- Fractional scaling
- Sprites in direct-colour mode at any depth
