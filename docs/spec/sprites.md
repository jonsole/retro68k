# Spec 9: Sprites

Status: **v1 scope**

Sprites are small images drawn over (or between) the layers at any position, without touching the layers' memory. Version 1 has eight sprites. As on the Amiga, each has a pointer into Chip RAM for its image (SPRxPT), and its window and settings are plain registers (SPRxH, SPRxV, SPRxCTL) that the CPU or copper writes: the copper resets the pointers every frame, and can reuse a sprite further down the screen by writing its registers again. The images are bigger and more colourful than the Amiga's, and their data is fetched just in time, through the same scheduler as the bitplanes, into a FIFO per sprite.

(An earlier design, with a 64-entry sprite table and fractional scaling, is in git history at commit 7df97fd. It was dropped for size.)

## 1. Summary

| Item | Value |
|------|-------|
| Sprites | 8 (SPR0–SPR7). Each can be reused further down the screen by the copper rewriting its registers |
| Window | HSTART–HSTOP across, VSTART–VSTOP down, like a layer's window. The image's size follows from the window and the magnify |
| Size | Any, as a layer's: set by the window. Only the memory budget limits it (section 5) |
| Colours | 2, 4 or 8 bits per pixel. 2 and 4 bpp: 3 or 15 colours + transparent, from any 16-colour block of the sprite palette; 8 bpp: 255 colours + transparent, the whole sprite palette. The sprites have a 256-colour palette of their own, separate from the layers' |
| Position | Any pixel; clipped at the left, right and bottom edges by the hardware, at the top by software (section 3) |
| Magnify | ×1, ×2 or ×4, across and down separately |
| Depth | Per sprite: in front of all layers, between any two (in PRIO order), or behind all |
| Collisions | Sprite–sprite and sprite–layer, per pixel, latched (as the Amiga's CLXDAT) |
| Data registers | A 32-word FIFO per sprite, streaming: lines of any length pass through it |
| Fetch | Just in time, deadline first, shared with the bitplanes (spec 4, section 5; spec 5, section 6). A sprite's next words are fetched as soon as its FIFO has room and a memory cycle is free, so most of each line is fetched ahead |

## 2. Comparison with the Amiga (OCS/ECS)

| Feature | Amiga | retro68k v1 |
|---------|-------|-------------|
| Sprites | 8 | 8 |
| Pointers | SPRxPT, rewritten by the copper each frame | The same |
| Position and settings | SPRxPOS, SPRxCTL (HSTART, VSTART, VSTOP): fetched by the DMA from control words in the sprite's data, or written by the CPU/copper | SPRxH, SPRxV (start and stop across and down: a window, as a layer has), SPRxCTL: plain registers, written by the CPU or copper only; the data in memory is image only |
| Reuse down the screen | The data holds more control words after each sprite | The copper writes the sprite's registers again, after a WAIT |
| Settings | Position, height | A window (any size), bits per pixel, magnify, depth among the layers, palette block |
| Width | 16 pixels (lores) | Any: set by the window |
| Colours | 3 + transparent; 15 with two attached sprites | 3, 15 or 255 + transparent, every sprite |
| Pixel format | Two bitplanes | Chunky: 2, 4 or 8 bits per pixel, first pixel in the high bits |
| Data registers | SPRxDATA, SPRxDATB: one line of 16 pixels | A 32-word FIFO, streaming: lines of any length pass through it |
| Fetch | Two words per sprite per line, in fixed slots in the horizontal blank | Just in time, deadline first; early when cycles are free |
| Manual mode | Write SPRxDATA/B with DMA off | Push words into SPRxDAT with the sprite's DMA off |
| Priority | Fixed in pairs against the playfields | Per sprite, any depth among the layers |
| Magnify | None | ×1, ×2, ×4 across and down |
| Collision | CLXDAT | SPRCOLL: per sprite, against the other sprites and each layer |

## 3. Sprites: pointer, position and settings

Each sprite has three registers (section 6):

- **SPRxPT** points at the sprite's image in Chip RAM: its lines one after another, top line first, each in whole words (section 3, below). As a plane pointer does, it moves through the image as it is fetched, so the hardware does not reset it: the copper (or the CPU) writes the eight pointers in every vertical blank.
- **SPRxH** and **SPRxV** give the sprite's window, and **SPRxCTL** its settings. They are plain registers: the CPU or copper writes them, and they stay as written until written again. The image in memory is pixels only.

**The window** (SPRxH, SPRxV), as a layer's (spec 4, section 4.3), in beam coordinates (spec 4, section 3.3: the picture is pixels 144–863, lines 49–624):

| Register | Bits | Field | Meaning |
|----------|------|-------|---------|
| SPRxH | 10–0 | HSTART | First beam pixel of the sprite (0–863; 864 or more: not shown). Pixels before 144 are in the horizontal blank: fetched, not shown |
| SPRxH | 26–16 | HSTOP | Beam pixel just after the sprite (no higher than 864 counts) |
| SPRxV | 10–0 | VSTART | First beam line of the sprite (0–624; 625 or more: not shown). Lines before 49 are in the vertical blank: fetched, not shown |
| SPRxV | 26–16 | VSTOP | Beam line just after the sprite (no higher than 625 counts) |

The image's size follows from the window: **source width** = (HSTOP − HSTART) ÷ HMAG pixels and **source height** = (VSTOP − VSTART) ÷ VMAG lines, each rounded up. A source line is stored in whole words, ⌈source width × BPP ÷ 16⌉ of them. There is no size limit: lines of any length stream through the FIFO (section 4); only the memory budget (section 5) limits how big and how many sprites can be.

**Clipping:** the hardware clips at all four edges. A sprite's line is a beam line, and its frame the beam's frame, so a sprite can start up to 144 pixels left of the picture (HSTART 0) and up to 49 lines above it (VSTART 0): those pixels and lines are fetched and used up, but not shown. Pixels past the right edge and lines past the bottom are neither fetched nor shown. The DMA needs a little time after the frame starts (and after the copper writes SPRxPT) to fetch a sprite's first words, so a sprite should not start on beam lines 0–1; such lines are in the blank anyway.

**SPRxCTL:**

| Bits | Field | Meaning |
|------|-------|---------|
| 13–12 | BPP | 0 = 2, 1 = 4, 2 = 8 bits per pixel |
| 17–16 | HMAG | Each source pixel shown 1, 2 or 4 times across (0, 1, 2) |
| 19–18 | VMAG | Each source line shown on 1, 2 or 4 screen lines (0, 1, 2) |
| 21–20 | DEPTH | 0 = in front of all layers; 1 = behind the front layer; 2 = behind the middle layer; 3 = behind all layers (in PRIO order) |
| 27–24 | PAL | 2 and 4 bpp: the 16-colour block of the sprite palette (colour = PAL × 16 + value). Not used at 8 bpp |

A sprite shows inside its window once per frame. A sprite whose DMA is on (SPRDMA) shows every frame where its registers say; to hide it, turn its DMA off, or set VSTART to 625 or more.

**Fetching:** as long as the sprite's window still has lines to come in this frame, the DMA keeps its FIFO filled: from the start of the frame (beam line 0, the start of the vertical blank) until the window's last line has been fetched. So a sprite's first line is fetched ahead too, before VSTART.

**Starting.** At the start of each frame (beam line 0, pixel 0), and whenever SPRxPT, SPRxH, SPRxV or SPRxCTL is written, the sprite starts again: its FIFO is emptied, and it will fetch its image from SPRxPT and show it from VSTART. (It is the copper's job to point SPRxPT at the image's first line, as for bitplanes.)

**Reusing a sprite further down the screen**, as Amiga programs do with their control words: after the sprite's last line, the copper WAITs, then writes the sprite's PT, window and CTL for its next use. The new use must start on a later line than the old one ends, and the writes must come after the old use's last line has been shown.

**How the pointer moves.** Each word fetched moves SPRxPT on by 2. At the end of each source line the pointer goes to that line's start + one line (⌈source width × BPP ÷ 16⌉ words). On the repeated lines of VMAG it goes back to the line's start, so the line is fetched again.

### 3.1 Pixels and colours

Image lines are **chunky**, as chunky layers are: 2, 4 or 8 bits per pixel, packed in words, the first pixel in the highest bits. A value of 0 is transparent. Other values are entries of the **sprite palette**, SPRPALETTE (`0xE04C00`–`0xE04FFF`, spec 4, section 6.3), which the sprites share and the layers do not use: at 8 bpp the value itself; at 2 and 4 bpp, PAL × 16 + the value. With VIDCON.SHAREPAL set, sprites use PALETTE0 instead, as the layers then do.

### 3.2 Magnify

There is no flip: for an object that faces either way, store both images.

- **HMAG** repeats each pixel 1, 2 or 4 times across; **VMAG** shows each source line on 1, 2 or 4 screen lines. A repeated line is fetched again (the FIFO cannot replay a line), so VMAG costs memory cycles on every screen line, and HMAG divides the cost across a line (section 5).

### 3.3 Depth and priority

Each sprite's DEPTH puts it in front of all three layers, between any two in their PRIO order, or behind all of them (in front of the background colour). Where two sprites overlap, the lower-numbered channel is in front. A layer's transparent pixels (TRANSP, value 0) show the sprites and layers behind them.

In direct-colour mode (VIDCON.DIRECT, spec 4, section 4.9) sprites are drawn in front of the picture in their colours from the sprite palette, and DEPTH is not used.

## 4. Data registers: the FIFO

Each sprite has a **FIFO of 32 words**, its data registers. The DMA pushes the image's words in at the back; the sprite takes them from the front as it is drawn, a line's worth per screen line (⌈source width × BPP ÷ 16⌉ words). The FIFO streams: a line can be longer than the FIFO, as long as the DMA keeps it from running dry. Its size only sets how far ahead the DMA can fetch: up to 32 words.

- **Fetching early.** The DMA pushes a sprite's words whenever its FIFO has room. So while a line is being drawn, the words it has finished with are already being replaced by the next line's, using any memory cycle nobody else wants. Fetching becomes urgent only when the FIFO is about to run out: then the sprite takes part in the deadline-first order with the layers, and may take the CPU's cycle (spec 5, section 6).
- **The lead** is up to 32 words per sprite: 64 source pixels at 8 bpp, 128 at 4 bpp, 256 at 2 bpp. A sprite at the right edge fills its FIFO for its next line in the horizontal blank (5.3 µs).
- **Manual mode.** With a sprite's DMA off (SPRDMA), the CPU or copper pushes the image's words into its FIFO by writing SPRxDAT. The sprite shows as its window and CTL say, taking a line's words from the FIFO on each line it shows. If the FIFO is empty when a word is needed, the sprite waits for it: it is transparent until a word is written, and the rest of the line follows from there. SPRUNDER is not set in manual mode.
- **Underrun.** If the DMA cannot keep a sprite's FIFO filled (section 5), VIDSTAT.SPRUNDER (bit 7) is set, and the sprite shows nothing more until it next starts (the next vertical blank, or a write to its registers): its words would no longer line up with its lines. SPRUNDER can raise the VIDERR interrupt like OVERRUN.

## 5. Memory budget

Sprites and layers share one budget, ordered by deadline. The display's own memory cycles (1 and 3 of each slot, spec 5) give about **12 words per 16 screen pixels** for certain; cycles the CPU, audio and copper leave free give more.

- A **layer** needs, per 16 source pixels, 1 word per plane (planar) or b words at b bpp (chunky); at 2× scale across, half that per 16 screen pixels.
- A **sprite** needs BPP words per 16 source pixels while the beam is over it (2, 4 or 8); with HMAG ×2, half that per 16 screen pixels.
- Sprites side by side do not add up; sprites over the same pixels at the same time do. Each FIFO's lead (32 words) lets a sprite fetch ahead into quieter stretches of the line, so short overlaps (up to about the lead's width: 64 pixels at 8 bpp, 256 at 2 bpp) are smoothed out; longer overlaps of wide sprites are limited by the budget at that moment, as the table shows.

Sprites stacked over the same 16 screen pixels, guaranteed (more when cycles are free):

| Layers | Words per 16 pixels | 8 bpp | 8 bpp, ×2 across | 4 bpp | 2 bpp |
|--------|--------------------|-------|------------------|-------|-------|
| None | 0 | 1 | 3 | 3 | 6 |
| One 8 bpp layer at 2× | 4 | 1 | 2 | 2 | 4 |
| Two 5-plane layers at 2× (Amiga style) | 5 | 0 | 1 | 1 | 3 |
| Two 4-plane layers at 1× | 8 | 0 | 1 | 1 | 2 |
| Three 4-plane layers at 1× | 12 | 0 | 0 | 0 | 0 |

The FIFOs' lead lets sprites go beyond these figures for short overlaps, and where the screen has quieter parts nearby on the same line. The figures are worked out, not measured; to be measured in simulation (open point S1).

## 6. Registers

Offsets in the custom register block at `0xE00000`.

| Offset | Name | Access | Bits | Description |
|--------|------|--------|------|-------------|
| `0x500` | SPRDMA | Set/clear | SPR (7–0), SETCLR (15) | DMA on for sprite n (bit n). Set/clear, as DMACON. Default all on. A sprite fetches only while SPRDMA bit n, DMACON.SPREN and DMACON.DMAEN are all set |
| `0x504` | SPRCOLL | RW1C | SPR (7–0), L0 (15–8), L1 (23–16), L2 (31–24) | Collisions, sticky until cleared by writing 1. SPR bit n: an opaque pixel of sprite n was on the same screen pixel as another sprite's opaque pixel. Ln bit n: sprite n was on an opaque pixel of layer n (a pixel the layer draws: not transparent). Only pixels on the screen count, not those clipped |

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

A 32 × 24 sprite at 4 bpp, in colours 32–47, behind the front layer, on sprite 0 at picture line 100, pixel 200 (beam coordinates add VID_X0 = 144 and VID_Y0 = 49). The image is 24 lines of 8 words in Chip RAM at `ship`. Once, from the CPU:

```
    move.l  #((VID_X0+200+32)<<16)|(VID_X0+200),SPR0+SPR_H(a4)  ; picture pixels 200-231
    move.l  #((VID_Y0+100+24)<<16)|(VID_Y0+100),SPR0+SPR_V(a4)  ; picture lines 100-123
    move.l  #(1<<SPR_CTL_BPP_B)|(1<<SPR_CTL_DEPTH_B)|(2<<SPR_CTL_PAL_B),SPR0+SPR_CTL(a4)
```

In the copper list, every frame (in the vertical blank):

```
    CMOVEL  SPR0+SPR_PT,ship
```

To move the ship, write SPR0H and SPR0V and then SPR0PT (from the CPU, or with copper MOVEs in the vertical blank). SPRxPT always goes last: each of these writes starts the sprite again from SPRxPT, which moves as the image is fetched.

Reusing sprite 0 for a second ship lower down, from line 300: after the first ship's last line (123), the copper writes sprite 0 again:

```
    CWAIT   VID_Y0+200,0
    CMOVEL  SPR0+SPR_H,((VID_X0+400+32)<<16)|(VID_X0+400)
    CMOVEL  SPR0+SPR_V,((VID_Y0+300+24)<<16)|(VID_Y0+300)
    CMOVEL  SPR0+SPR_PT,ship2
```

## 8. FPGA resources

Measured with Yosys (synth_xilinx, XC7A35T):

| Item | LUTs |
|------|------|
| sprites.v: registers, sizes, fetcher, deadlines, 8 FIFOs of 32 × 16 bits (distributed RAM) | About 2,000 |
| 8 pixel units (sprite_pix.v) | About 90 each, 730 in all |
| Mixing with the layers (depth), collisions (video.v) | A few hundred |
| Total | About 3,000; no block RAM |

To keep it small, the per-sprite state lives in distributed RAM, worked on one sprite a clock: the registers as written, the place in the image (pointer, line start, words and lines left), and the sizes worked out from the window (one shared calculator visits a sprite each clock). Only what the pixel side needs all at once at a line's start is in flip-flops.

## 9. Open points

| # | Item |
|---|------|
| S1 | Measure how many stacked sprites each layer set-up allows (section 5), in simulation |
| S2 | Whether the sprites' share of the free cycles should be limited, so that a screen full of sprites cannot starve the CPU |

## 10. Tests

- **Golden images:** sprites of many window sizes, at every depth and magnify, clipped at all four edges, reused down the screen, at every DEPTH against layers in different PRIO orders, over transparent layer pixels, compared pixel by pixel with the Python video model extended with sprites.
- **Collisions:** known overlaps set exactly the expected SPRCOLL bits.
- **Manual mode:** a sprite fed by the CPU through SPRxDAT; an underrun sets SPRUNDER.
- **Stress:** sprites stacked over the same pixels with layers of each depth, to measure section 5's table.

## 11. Later versions

- A sprite table, so that the copper need not rewrite sprites to reuse them
- Fractional scaling
- Sprites in direct-colour mode at any depth
