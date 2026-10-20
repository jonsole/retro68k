# Spec 9: Sprites

Status: **draft for review**

Sprites are small images drawn over (or between) the layers at any position, without changing the layers' memory. This spec defines what a sprite can be and how the hardware shows it. How sprite data is fetched from memory is set by the video spec (spec 4, section 5.4) and the slot rules in spec 5. This spec extends both.

## 1. Summary

| Item | Value |
|------|-------|
| Sprites defined | 64, in a sprite table in block RAM |
| Sprites per line | Up to 16 |
| Width | 16, 32 or 64 pixels, at up to 32 bytes per line |
| Height | 1 to 1024 lines |
| Colours | 2, 4 or 8 bits per pixel (3, 15 or 255 colours + transparent), any 16-entry block of the 1024-colour palette |
| Position | Any pixel, including partly off any edge of the screen |
| Flip | Horizontal and vertical |
| Scaling | 1× to 4× bigger, in 1/256 steps, separately across and down |
| Depth | Each sprite chooses where it sits among the 4 layers |
| Images | Taken from anywhere in Chip RAM, with a stride, so frames can come straight from a sprite sheet |
| Collision | Sprite–sprite (by groups) and sprite–layer, per pixel, latched each frame |
| Fetch | Just in time, just before the sprite's X position. Can borrow a CPU slot when needed |

## 2. Comparison with the Amiga (OCS/ECS)

| Feature | Amiga | retro68k |
|---------|-------|----------|
| Count | 8 hardware sprites; more by reusing them further down the screen (multiplexing) | 64 in a table, any 16 on a line, no multiplexing needed |
| Width | 16 pixels (lores) | 16, 32 or 64 pixels |
| Colours | 3 + transparent (15 when two are attached) | 3, 15 or 255 + transparent |
| Palette | Fixed colour registers 16–31, shared in pairs | Any 16-colour block of 1024 colours, per sprite |
| Data | A DMA list in Chip RAM, including control words, rewritten to move or animate | Position and image pointer in a table; move or animate by changing one value |
| Scaling, flipping | None | Both |
| Priority | Fixed against playfields, in pairs | Per sprite, any depth among the layers |
| Collision | One shared register (CLXDAT) for sprite pairs and bitplanes | Per-sprite hit flags, collision groups, and a group-pair register like CLXDAT |

## 3. The sprite table

The sprite table holds 64 entries of 32 bytes (2 KB, one block RAM) at `0xE05000`–`0xE057FF`. The CPU and the copper can read and write it at any time. Sprite 0 is entry 0, and so on.

| Offset | Name | Bits | Meaning |
|--------|------|------|---------|
| `+0x00` | POS | X 11–0, Y 27–16 (both signed 12-bit) | Screen position of the top-left pixel. Negative values or values past the edge clip the sprite |
| `+0x04` | PTR | 24–0 | Chip RAM byte address of the image's top line |
| `+0x08` | SIZE | HEIGHT−1 9–0, STRIDE 31–16 (signed) | Height in source lines; bytes from one source line to the next |
| `+0x0C` | CTRL | see below | |
| `+0x10` | SCALE | HSTEP 15–0, VSTEP 31–16 (8.8 fixed point) | `0x0100` = 1:1, `0x0080` = 2× bigger, `0x0040` = 4× bigger. Values from `0x0040` to `0x0100` are allowed |
| `+0x14` | COLL | GROUP 1–0, HITGROUPS 7–4, HITLAYERS 11–8 | Collision settings (section 7) |
| `+0x18`, `+0x1C` | – | | Reserved, read as 0 |

**CTRL bits:**

| Bits | Name | Meaning |
|------|------|---------|
| 0 | EN | Sprite on |
| 2–1 | WIDTH | 0 = 16, 1 = 32, 2 = 64 pixels (source pixels, before scaling) |
| 4–3 | BPP | 0 = 2, 1 = 4, 2 = 8 bits per pixel |
| 5 | HFLIP | Mirror left–right |
| 6 | VFLIP | Mirror top–bottom |
| 10–8 | DEPTH | 0 = in front of everything; 1–3 = behind the 1st–3rd layer in PRIO order; 4 = behind all layers |
| 21–16 | PALOFS | Palette block: colour index = PALOFS × 16 + pixel value |

**Width and colour depth:** one line of a sprite can be up to 32 bytes:

| Width | 2bpp | 4bpp | 8bpp |
|-------|------|------|------|
| 16 px | 4 bytes | 8 bytes | 16 bytes |
| 32 px | 8 bytes | 16 bytes | 32 bytes |
| 64 px | 16 bytes | 32 bytes | not allowed (64 bytes) |

Pixel value 0 is always transparent. An 8bpp sprite uses PALOFS in steps of 16 like the others, so it can start its 256 colours at any 16-colour boundary.

**Sprite sheets:** STRIDE lets a sprite's image be a rectangle inside a bigger picture. For example, a sheet of 32×32 4bpp animation frames laid out 8 across has STRIDE = 128, and changing frames just means changing PTR.

**Size on screen:** width × 256 ÷ HSTEP by height × 256 ÷ VSTEP. A 64-pixel sprite at 4× is 256 pixels wide.

## 4. Choosing the sprites for each line

- At the start of line L−1, the sprite unit reads the 64 table entries (64 clocks at 100 MHz, from block RAM, no SDRAM) and picks those that cover line L.
- **Up to 16 sprites per line,** taken in table order. If more than 16 cover a line, the extras are not drawn on that line and SPROVF is set in VIDSTAT. Putting the most important sprites first in the table makes sure they always show.
- Each picked sprite is given one of **16 sprite units**. A unit works out which source line to show (from Y, VSTEP and VFLIP) and holds the sprite's data for that line in its **data register**: 32 bytes, double-buffered so the next line can be fetched while the current one is drawn. 16 units × 64 bytes = 1 KB, built from FPGA logic.
- **When writes take effect:** sprite table values are read at the start of line L−1 for line L. **To change a sprite on line L, write before line L−1 begins.** This is one line earlier than layers (spec 4, section 5.6), because sprites near the left edge are fetched during line L−1.

## 5. Fetching: just before the sprite

This replaces the 32-slot window in spec 4, section 5.4.

- Each sprite's line of data is fetched in the **64 slots before its first pixel** (6.4 µs; 160 pixels ahead at 640×480). For sprites near the left edge, the window starts in line L−1.
- A line of up to 12 bytes takes 1 burst, up to 24 bytes 2 bursts, up to 32 bytes 3 bursts.
- **Slots a sprite can use, in order of preference** (unchanged from spec 4):
  1. Free odd slots
  2. Display-fetch slots that no layer needs at that moment
  3. Even slots the CPU is not using
  4. **Even slots the CPU wants, only when the sprite would otherwise miss its deadline**
- **What always fits:** a 64-slot window has 16 `hslot % 4 == 3` slots and 32 even slots besides the layers' own slots.
  - With wide fetch off: 16 sprites of 3 bursts (48 bursts) all starting at the same X still fit.
  - With wide fetch on, the odd slots are taken, so the even slots must carry it: 16 sprites of up to 2 bursts, or 10 sprites of 3 bursts, all at the same X. Spread out across the line, all 16 fit.
  - If a sprite still misses its deadline, its line is transparent and SPRMISS is set.
- **Cost to the CPU:** each slot taken costs 2 CPU clocks, and only if the CPU wanted that slot.
  - Typical (sprites spread out, wide fetch off): nothing.
  - Worst case (16 full-size sprites at the same X, wide fetch on, CPU running flat out from Chip RAM): 48 slots, 96 CPU clocks, 15% of a 640×480 line, on that line only.

## 6. Drawing

For each pixel, each sprite unit whose sprite covers that pixel gives a colour index, or "transparent" for pixel value 0.

- **Between sprites:** the front sprite is the one with the smallest DEPTH; if two have the same DEPTH, the lower table index is in front. Sorting by depth first avoids the "priority quirk" of some consoles, where a sprite set behind a layer could still hide a sprite in front of it.
- **Against layers:** the chosen sprite pixel goes in front of the layers its DEPTH puts it in front of, and behind the others (layer order from the PRIO register, spec 4, section 4.8). Transparent layer pixels let it show through.
- **Scaling:** like layers, nearest-neighbour with no filtering, so pixels stay sharp.
- **Clipping:** parts of a sprite off the left, right, top or bottom of the screen are simply not drawn. A sprite can slide smoothly on and off any edge.

## 7. Collision detection

Each sprite has a collision **GROUP** (0–3), a set of **HITGROUPS** it reacts to, and a set of **HITLAYERS** (layers 0–3) it reacts to. For example: player = group 0, hits groups 1 and 2 and layer 1 (walls); enemies = group 1, hit group 0; bullets = group 2.

At every visible pixel where a sprite has a non-transparent pixel:

- If another sprite in one of its HITGROUPS also has a non-transparent pixel there, the sprite's **hit flag** is set.
- If a layer in its HITLAYERS has a non-transparent pixel there, the hit flag is set. This check ignores priority: a sprite behind a layer still collides with it.
- The **group-pair register** CLXGRP gets a bit set for each pair of groups that touched (4 × 4 bits), like the Amiga's CLXDAT.

**Reading the results:** hits are collected during the frame. At the start of vertical blanking they are copied to SPRHIT0 (sprites 0–31) and SPRHIT1 (sprites 32–63) and CLXGRP, and the collection starts again from clear. Software reads one complete frame's results during vertical blanking without having to clear anything.

Collision only counts pixels that are actually drawn: inside the screen, on lines where the sprite was among the 16 shown.

## 8. Registers

Offsets in the custom register block at `0xE00000`. Spec 3 sets the final addresses.

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x200` | SPRCON | EN (0) | All sprites on/off (DMACON.SPREN must also be set) |
| `0x204` | SPRHIT0 | 31–0 | Hit flags, sprites 0–31, from the last complete frame |
| `0x208` | SPRHIT1 | 31–0 | Hit flags, sprites 32–63 |
| `0x20C` | CLXGRP | 15–0 | Bit (4 × a + b): groups a and b touched in the last frame |
| `0x5000`–`0x57FF` | Sprite table | | 64 × 32 bytes (section 3) |

New flags in VIDSTAT (spec 4, section 6.1): **SPROVF** (bit 12, more than 16 sprites on a line) and **SPRMISS** (bit 11, a sprite missed its fetch deadline). Both are sticky, write 1 to clear, and can raise the video interrupt.

The PRIO register's SPRPOS field (spec 4, section 4.8) is replaced by each sprite's DEPTH.

## 9. FPGA resources

| Item | Resource |
|------|----------|
| Sprite table, 2 KB | 1 block RAM |
| Data registers, 16 × 2 × 32 bytes | About 130 LUTs used as RAM |
| 16 sprite units (position, scaling, flip, pixel select) | Estimate 1,500–2,500 LUTs; to confirm by synthesis (S1) |
| Depth sort and collision logic | Included in the estimate above |

## 10. Open points

| # | Item |
|---|------|
| S1 | Check the 16 sprite units fit and meet timing at 66.7 MHz pixel clock on the LX25. If not, 8 sprites per line is the fallback |
| S2 | Sprite reuse further right on the same line (more than 16 per line): possible later with the just-in-time fetch |
| S3 | Should 64-pixel 8bpp sprites (64 bytes per line) be allowed, at 6 bursts? It would need bigger data registers |
| S4 | Shrinking sprites (HSTEP above `0x0100`) would need more data per line; left out for now |

## 11. Tests

- **Golden images:** render sprites at every width, depth, flip and scale, clipped at each edge, in front of and behind layers, and compare with a Python reference model.
- **Line limit:** 17 sprites on a line: the first 16 by table index are drawn and SPROVF is set.
- **Fetch:** 16 full-size sprites at the same X with wide fetch off: no SPRMISS, no CPU slots taken. With wide fetch on: exactly the cases in section 5 fit, and every CPU delay is 2 clocks.
- **Depth:** two overlapping sprites, one behind a layer and one in front: the front one always shows, whatever their table order.
- **Collision:** set up known overlaps between groups and layers; check SPRHIT and CLXGRP after the frame, including a sprite hidden behind a layer.
- **Write timing:** a table write before line L−1 changes line L; a later write changes line L+1.
