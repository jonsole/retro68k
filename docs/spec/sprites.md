# Spec 9: Sprites

Status: **on hold, not in version 1.** Sprites were removed from v1 to save logic. The last implementation is in git history at commit 7df97fd. The rest of this spec is kept as it was for a later version.

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
| Fetch | On the line the sprite is shown, starting a fixed 128 slots before its first pixel (sprites near the left edge start at the end of the line before). Can borrow the CPU's memory cycle when needed |

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
| `+0x04` | PTR | 22–0 | Chip RAM byte address of the image's top line |
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

Before any sprite on line L can be fetched, the hardware has to know which sprites are on that line and where they start. This **selection** is the one step that happens ahead of the fetch.

- **Selection point:** a fixed **136 slots before line L begins** (13.6 µs). At 640×480 that is slot 184 of line L−1.
- At the selection point, the sprite unit reads EN, X, Y and HEIGHT from all 64 table entries (block RAM, 10 entries per slot, so 7 slots) and picks those that cover line L. The extra 8 slots before the earliest possible fetch (136 = 128 + 8) are the time this takes.
- **Up to 16 sprites per line,** taken in table order. If more than 16 cover a line, the extras are not drawn on that line and SPROVF is set in VIDSTAT. Putting the most important sprites first in the table makes sure they always show.
- Each picked sprite is given one of **16 sprite units**. A unit holds the sprite's data for one line in its **data register**: 32 bytes, double-buffered, because a unit can be fetching for line L while still drawing a sprite at the right-hand end of line L−1. 16 units × 64 bytes = 1 KB, built from FPGA logic.

## 5. Fetching at a fixed distance before the sprite

This replaces the fetch window in spec 4, section 5.4.

- **Fetch point:** every sprite's fetch starts exactly **D = 128 slots (12.8 µs) before the slot holding its first visible pixel**. At 640×480 that is 320 pixels ahead; at 1280×720, 853 pixels.
  - Sprites far enough right are fetched on the line they are shown.
  - Sprites nearer the left edge than that have their fetch point at the end of the line before.
- **At the fetch point,** the unit reads the rest of the sprite's settings: PTR, STRIDE, CTRL, SCALE and COLL. It works out the source line (from Y, VSTEP and VFLIP) and starts fetching.
- A line of up to 32 bytes takes up to 16 memory cycles (16 bits each, any address). They are done in the cycles right after the fetch point, and are always complete before the first pixel in the cases listed below.
- **Cycles a sprite can use, in order of preference:**
  1. Free-pool cycles (spec 5, section 6)
  2. Display cycles that no layer needs at that moment
  3. **The CPU's cycle 0, only when the sprite would otherwise miss its first pixel**
- **What always fits:** a 128-slot window has 128 cycle-3s, at least 90 free cycle-4s, and at least 64 cycle-0s the CPU leaves even when running flat out.
  - With wide fetch off: at least 282 cycles. 16 full-size sprites (32 bytes each = 256 cycles) all starting at the same X fit, without touching the CPU.
  - With wide fetch on, cycle 3 is taken in the visible part, leaving at least 154 cycles: 16 sprites of up to 16 bytes, or 9 full-size sprites, at the same X without touching the CPU; up to 13 full-size by borrowing CPU cycles. Spread out across the line, all 16 fit.
  - If a sprite still misses its first pixel, its line is transparent and SPRMISS is set.
- **Cost to the CPU:** each cycle taken costs 2 CPU clocks, and only if the CPU wanted that cycle.
  - Typical (sprites spread out, or wide fetch off): nothing.
  - Worst case (13 full-size sprites at the same X, wide fetch on, CPU running flat out from Chip RAM): 64 cycles, 128 CPU clocks, 20% of a 640×480 line, on that line only.

### 5.0 Version 1 (fpga/rtl/sprites.v, sprite_pix.v)

What the first implementation does, where it is simpler than the text above:

- **Selection** reads EN, X, Y, HEIGHT and also **VSTEP** at the selection point (it needs VSTEP to know whether a scaled sprite covers the line), from a small copy of those fields kept beside the table. The other settings are read at the fetch point, as described.
- **Fetch order:** due units are fetched one sprite at a time, those for the line on screen first, then in unit (table) order. Since a unit only becomes due at its fetch point, this is close to earliest-deadline-first.
- **Urgent:** a sprite may take the CPU's cycle 0 in the last 16 slots before its first pixel.
- **The beam in slots** is counted from the start of each line as the 100 MHz side sees it, so the selection and fetch points are fixed but may sit up to a slot later than the exact figures above.
- A 64-pixel 8 bpp sprite (not allowed, section 3) is simply not drawn.
- HSTEP is limited to the allowed `0x0040`–`0x0100` when it is read (VSTEP is not checked).

### 5.1 When writes take effect

| Settings | Read at | To change a sprite on line L, write before |
|----------|---------|---------------------------------------------|
| EN, X, Y, HEIGHT (which lines it is on, and where) | The selection point | 136 slots before line L begins |
| PTR, STRIDE, CTRL, SCALE, COLL (what it looks like) | The sprite's own fetch point | 128 slots before the sprite's first pixel on line L |

- The appearance deadline is a fixed distance before each sprite, wherever it is on the screen. A copper program or interrupt can change a sprite's image, colours or scale a fixed time ahead of where it is drawn, even part-way down the screen.
- **Reusing a table entry lower down the screen** (Amiga-style multiplexing, for more than 64 sprites in a frame): change its Y, X and PTR before the selection point of the first line it should appear on.
- The selection point has to come first because the hardware can't start a sprite's fetch until it knows the sprite is on the line and where its fetch point is.

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
| S1 | Check the 16 sprite units fit and meet timing at 66.7 MHz pixel clock on the XC7A35T. If not, 8 sprites per line is the fallback |
| S2 | Sprite reuse further right on the same line (more than 16 per line): possible later with the just-in-time fetch |
| S3 | Should 64-pixel 8bpp sprites (64 bytes per line, 32 memory cycles) be allowed? It would need bigger data registers |
| S4 | Shrinking sprites (HSTEP above `0x0100`) would need more data per line; left out for now |

## 11. Tests

- **Golden images:** render sprites at every width, depth, flip and scale, clipped at each edge, in front of and behind layers, and compare with a Python reference model.
- **Line limit:** 17 sprites on a line: the first 16 by table index are drawn and SPROVF is set.
- **Fetch:** 16 full-size sprites at the same X with wide fetch off: no SPRMISS, no CPU cycles taken. With wide fetch on: exactly the cases in section 5 fit, and every CPU delay is 2 clocks.
- **Depth:** two overlapping sprites, one behind a layer and one in front: the front one always shows, whatever their table order.
- **Collision:** set up known overlaps between groups and layers; check SPRHIT and CLXGRP after the frame, including a sprite hidden behind a layer.
- **Write timing:** a position write just before line L's selection point changes line L, just after it changes line L+1. An appearance write just before a sprite's fetch point changes that line, just after it changes the next one. Check this for sprites at several X positions, including near the left edge.
- **Fixed offset:** for sprites at many X positions, assert the fetch starts exactly 128 slots before the first pixel.
