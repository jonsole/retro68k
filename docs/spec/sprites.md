# Spec 9: Sprites

Status: **v1 scope**

Sprites are small images drawn over (or between) the layers at any position, without touching the layers' memory. Version 1 has eight sprite channels, organised as on the Amiga: each channel follows a list in Chip RAM, so one channel can show many sprites down the screen. The images are bigger and more colourful than the Amiga's, and their data is fetched just in time, through the same scheduler as the bitplanes, into a FIFO per sprite.

(An earlier design, with a 64-entry sprite table and fractional scaling, is in git history at commit 7df97fd. It was dropped for size.)

## 1. Summary

| Item | Value |
|------|-------|
| Channels | 8 (SPR0–SPR7). Each shows one sprite at a time; a channel shows many sprites down the screen by following its list |
| Width | 16, 32 or 64 pixels |
| Height | 1 to 1024 lines |
| Colours | 2, 4 or 8 bits per pixel. 2 and 4 bpp: 3 or 15 colours + transparent, from any 16-colour block of the palette; 8 bpp: 255 colours + transparent, the whole palette |
| Position | Any pixel, including partly off any edge |
| Flip | Horizontal and vertical |
| Magnify | ×1, ×2 or ×4, across and down separately |
| Depth | Per sprite: in front of all layers, between any two (in PRIO order), or behind all |
| Collisions | Sprite–sprite and sprite–layer, per pixel, latched (as the Amiga's CLXDAT) |
| Data registers | A 32-word FIFO per sprite (one line of the widest, deepest sprite) |
| Fetch | Just in time, deadline first, shared with the bitplanes (spec 4, section 5; spec 5, section 6). A sprite's next words are fetched as soon as its FIFO has room and a memory cycle is free, so most of each line is fetched ahead |

## 2. Comparison with the Amiga (OCS/ECS)

| Feature | Amiga | retro68k v1 |
|---------|-------|-------------|
| Channels | 8, each following a list in Chip RAM | The same |
| Reuse down the screen | The list holds several sprites, each after the last ends | The same |
| Pointers | SPRxPT, rewritten by the copper each frame | The same |
| Control words | SPRxPOS, SPRxCTL: position, height | POS and CTL: position, height, width, depth, flips, magnify, depth among the layers, palette block |
| Width | 16 pixels (lores) | 16, 32 or 64 pixels |
| Colours | 3 + transparent; 15 with two attached sprites | 3, 15 or 255 + transparent, every sprite |
| Pixel format | Two bitplanes | Chunky: 2, 4 or 8 bits per pixel, first pixel in the high bits |
| Data registers | SPRxDATA, SPRxDATB: one line of 16 pixels | A 32-word FIFO: a whole line of up to 64 pixels at 8 bpp |
| Fetch | Two words per sprite per line, in fixed slots in the horizontal blank | Just in time, deadline first; early when cycles are free |
| Manual mode | Write SPRxDATA/B with DMA off | Push words into SPRxDAT with the sprite's DMA off |
| Priority | Fixed in pairs against the playfields | Per sprite, any depth among the layers |
| Flip, magnify | None | Both |
| Collision | CLXDAT | SPRCOLL: per sprite, against the other sprites and each layer |

## 3. Sprite lists

Each channel has a pointer, **SPRxPT**, into a list in Chip RAM. As on the Amiga, the hardware does not reset it: the copper (or the CPU) writes the eight pointers in every vertical blank.

A list is a sequence of sprites, each a **header** of two long words followed by its **image**:

```
 header:  POS   long: Y (27-16), X (11-0)
          CTL   long: END, HEIGHT-1, WIDTH, BPP, HFLIP, VFLIP, HMAG, VMAG, DEPTH, PAL
 image:   HEIGHT lines, each WIDTH x BPP / 16 words, top line first
 header:  the next sprite in this channel, further down
 ...
 header:  CTL.END set: no more sprites in this channel this frame
```

The pointer moves through the list as it is fetched, so at the end of a sprite it points at the next header. Lists are word-aligned (headers on even addresses).

**POS** (the same layout as the POS register):

| Bits | Field | Meaning |
|------|-------|---------|
| 11–0 | X | Screen pixel of the sprite's left edge, signed (−2048 to 2047). Off the left edge clips |
| 27–16 | Y | Screen line of the sprite's top line, signed. Off the top clips |

**CTL** (the same layout as the CTL register):

| Bits | Field | Meaning |
|------|-------|---------|
| 9–0 | HEIGHT | Source lines − 1 (1 to 1024 lines) |
| 11–10 | WIDTH | 0 = 16, 1 = 32, 2 = 64 source pixels |
| 13–12 | BPP | 0 = 2, 1 = 4, 2 = 8 bits per pixel |
| 14 | HFLIP | Mirror left to right |
| 15 | VFLIP | Mirror top to bottom |
| 17–16 | HMAG | Each source pixel shown 1, 2 or 4 times across (0, 1, 2) |
| 19–18 | VMAG | Each source line shown on 1, 2 or 4 screen lines (0, 1, 2) |
| 21–20 | DEPTH | 0 = in front of all layers; 1 = behind the front layer; 2 = behind the middle layer; 3 = behind all layers (in PRIO order) |
| 27–24 | PAL | 2 and 4 bpp: the 16-colour block of the palette (colour = PAL × 16 + value). Not used at 8 bpp |
| 31 | END | End of the list: this channel shows nothing more this frame. The other fields are ignored |

A sprite is shown on screen lines Y to Y + (HEIGHT + 1) × VMAG − 1, and pixels X to X + WIDTH × HMAG − 1. The next sprite in the same channel must start on a later line than the last line of the one before (one line later is enough). If its Y has already passed when its header is fetched, its lines up to the current one are skipped, as if clipped.

At the start of each vertical blank, every channel whose DMA is on fetches its first header from SPRxPT.

### 3.1 Pixels and colours

Image lines are **chunky**, as chunky layers are: 2, 4 or 8 bits per pixel, packed in words, the first pixel in the highest bits. A value of 0 is transparent. Other values are palette entries: at 8 bpp the value itself; at 2 and 4 bpp, PAL × 16 + the value.

### 3.2 Flip and magnify

- **HFLIP:** the DMA fetches each line's words last first, and the sprite shows each word's pixels in reverse order, so the line is mirrored. The image in memory is unchanged.
- **VFLIP:** the DMA fetches the image's lines bottom first. The pointer still ends after the image, at the next header.
- **HMAG** repeats each pixel 1, 2 or 4 times across; **VMAG** shows each source line on 1, 2 or 4 screen lines. A repeated line is fetched again (the FIFO cannot replay a line), so VMAG costs memory cycles on every screen line, and HMAG divides the cost across a line (section 5).

### 3.3 Depth and priority

Each sprite's DEPTH puts it in front of all three layers, between any two in their PRIO order, or behind all of them (in front of the background colour). Where two sprites overlap, the lower-numbered channel is in front. A layer's transparent pixels (TRANSP, value 0) show the sprites and layers behind them.

In direct-colour mode (VIDCON.DIRECT, spec 4, section 4.9) sprites are drawn in front of the picture with their palette colours, and DEPTH is not used.

## 4. Data registers: the FIFO

Each sprite has a **FIFO of 32 words**, its data registers: one line of the widest, deepest sprite (64 pixels at 8 bpp). The DMA pushes the image's words in at the back; the sprite takes them from the front as it is drawn, a line's worth per screen line (WIDTH × BPP / 16 words: 1 to 32).

- **Fetching early.** The DMA pushes a sprite's words whenever its FIFO has room. So while a line is being drawn, the words it has finished with are already being replaced by the next line's, using any memory cycle nobody else wants. Fetching becomes urgent only when the FIFO is about to run out: then the sprite takes part in the deadline-first order with the layers, and may take the CPU's cycle (spec 5, section 6).
- **A sprite at the right edge** has only the horizontal blank (5.3 µs) to fetch its next line ahead, but it has finished its own line by then.
- **Manual mode.** With a sprite's DMA off (SPRDMA), the CPU or copper can write its POS and CTL registers and push words into its FIFO by writing SPRxDAT. The sprite then shows as described by POS and CTL, taking a line's words from the FIFO on each line it shows. If the FIFO runs dry, the sprite is transparent where the words are missing and VIDSTAT.SPRUNDER is set.
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

Sprite n (0–7) at `0x520 + n × 0x10`:

| Offset | Name | Access | Bits | Description |
|--------|------|--------|------|-------------|
| `+0x00` | SPRxPT | RW | 22–1 | The next word of the sprite's list (even). Written by the copper each frame |
| `+0x04` | SPRxPOS | RW | X (11–0), Y (27–16) | The sprite being shown: loaded from each header by the DMA; written by the CPU or copper in manual mode |
| `+0x08` | SPRxCTL | RW | as section 3 | The same |
| `+0x0C` | SPRxDAT | W, R | write: 15–0; read: COUNT (5–0) | Write: push a word into the FIFO (manual mode). Read: words in the FIFO (0–32) |

VIDSTAT bit 7, **SPRUNDER** (spec 4, section 6.1): a sprite's FIFO ran dry while it was being drawn. Sticky, with an enable in VIDINTEN; raises VIDERR like OVERRUN.

DMACON bit 5, **SPREN**: sprite DMA on (spec 5, section 8).

**When writes take effect:** SPRxPT at once (the next word fetched); POS and CTL from the next line (the DMA loads them from each header before the sprite's first line); SPRDMA at once (a sprite whose DMA is turned off keeps what is in its FIFO).

## 7. Examples

A 32 × 24 sprite at 4 bpp, in colours 32–47, behind the front layer, on channel 0. In Chip RAM:

```
ship:       dc.l    (100<<16)|200                       ; POS: line 100, pixel 200
            dc.l    (24-1)|(1<<10)|(1<<12)|(1<<20)|(2<<24)   ; CTL: 24 lines, 32 px, 4 bpp, depth 1, block 2
            ; 24 lines x 8 words of image
            ...
            dc.l    0                                   ; POS (not used)
            dc.l    $80000000                           ; CTL.END
```

In the copper list, every frame:

```
            CMOVEL  SPR0+SPR_PT,ship
```

To move the ship, change the POS long in memory (or a copper MOVE can write it into the list for the next frame). To reuse channel 0 for another sprite lower down, put that sprite's header and image where the END header is.

## 8. FPGA resources

| Item | Resource |
|------|----------|
| 8 FIFOs of 32 × 16 bits | Distributed RAM, about 100 LUTs |
| List fetcher: headers, line addresses (flip), FIFO fill and deadlines, in the scheduler | About 600 LUTs |
| 8 pixel units: position, magnify, flip, pixel select | About 800 LUTs |
| Mixing with the layers (depth), collisions, registers | About 400 LUTs |
| Total | About 1,800–2,200 LUTs; no block RAM |

## 9. Open points

| # | Item |
|---|------|
| S1 | Measure how many stacked sprites each layer set-up allows (section 5), in simulation |
| S2 | Whether the sprites' share of the free cycles should be limited, so that a screen full of sprites cannot starve the CPU |

## 10. Tests

- **Golden images:** sprites in every width, depth and magnify, flipped, clipped at all four edges, reused down the screen, at every DEPTH against layers in different PRIO orders, over transparent layer pixels, compared pixel by pixel with the Python video model extended with sprites.
- **Collisions:** known overlaps set exactly the expected SPRCOLL bits.
- **Manual mode:** a sprite fed by the CPU through SPRxDAT; an underrun sets SPRUNDER.
- **Stress:** sprites stacked over the same pixels with layers of each depth, to measure section 5's table.

## 11. Later versions

- A sprite table, so that software need not build lists
- Fractional scaling
- Sprites in direct-colour mode at any depth
