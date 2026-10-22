# Chapter 4: Sprite Hardware

## Introduction

**Sprites** are small images that the hardware draws over, or between, the layers, at any position on the screen, without your program touching the layers' memory. Moving a sprite is a matter of writing two registers: nothing has to be drawn, saved or restored. They are the natural choice for anything that moves on its own: a mouse pointer, a player's ship, bullets, a cursor.

retro68k has eight sprites, SPR0 to SPR7. Each one is a little playfield of its own: an image in Chip RAM, which the hardware fetches by DMA while the beam sweeps the screen, and a **window** that says where on the screen the image goes. A sprite can be any size; it can have 3, 15 or 255 colours; it can be magnified two or four times; and each sprite can be put in front of all the layers, between any two of them, or behind them all. The hardware also reports when sprites touch each other or the layers.

The chapter covers:

- forming a sprite, step by step, ending with a complete program;
- the image in memory: pixel formats, colours and transparency;
- the window, and how it sets the image's size;
- positioning, and clipping at the edges of the screen;
- moving a sprite, and when writes to its registers take effect;
- magnifying;
- depth: where each sprite goes among the layers;
- reusing a sprite further down the screen with the copper;
- collision detection;
- the data FIFO, the DMA, and how many sprites the memory can feed;
- feeding a sprite from the CPU or copper instead of the DMA;
- a summary of the registers.

You should have read the Playfield Hardware chapter, because sprites are mixed with the layers described there, and "Working with the Hardware Registers" in the Introduction and System Control Hardware chapter. Some examples use the copper, which is described in full in the Coprocessor Hardware chapter.

### Comparison with the Amiga

If you have programmed the Amiga's sprites, the main ideas carry over: eight sprites, a pointer per sprite into Chip RAM, rewritten every frame by the copper, DMA that fetches the image line by line, and collision bits. What changes is that the position and size are no longer control words in the sprite's data: they are plain registers, a window as a layer has, that the CPU or copper writes. The data in memory is the image and nothing else.

| Feature | Amiga (OCS/ECS) | retro68k |
|---------|-----------------|----------|
| Sprites | 8 | 8 |
| Pointer | SPRxPT, rewritten by the copper each frame | SPRxPT, the same |
| Position and size | SPRxPOS/SPRxCTL control words in the data (or written by hand); width fixed at 16 pixels | SPRxH and SPRxV, plain registers: a window of any size |
| Colours | 3 + transparent; 15 with two attached sprites | 3, 15 or 255 + transparent, every sprite |
| Pixel format | Two bitplanes per sprite | Chunky: 2, 4 or 8 bits per pixel |
| Reuse down the screen | More control words after the image | The copper writes the registers again |
| Magnify | None | ×1, ×2, ×4 across and down |
| Priority | Fixed in pairs against the playfields | Per sprite: any depth among the layers |
| Collisions | CLXDAT, CLXCON | SPRCOLL: each sprite against the others and each layer |
| Data registers | SPRxDATA/B, one line | A 32-word FIFO per sprite, SPRxDAT |
| DMA | Two words per sprite per line, in fixed slots | Just in time, shared with the layers, early when memory is free |

### Conventions in this chapter

- Examples are 68000 assembly language for vasm, in Motorola syntax, and start with `include "hw.inc"`; those that use the copper also `include "copper.inc"`.
- In ordinary code **a4 holds CUSTOM** (`$E00000`), as in the other chapters.
- In `hw.inc`, `SPR0` … `SPR7` are the offsets of the eight sprites in the custom block (`$520`, `$540` … `$600`: 32 bytes apart), and `SPR_PT`, `SPR_H`, `SPR_V`, `SPR_CTL` and `SPR_DAT` are the offsets of the registers inside a sprite. So sprite 3's window across is `SPR3+SPR_H(a4)`. The same address also has a ready-added name, `SPR3_H`.
- Sprite positions are in **beam coordinates**, which count the blanking (see "Beam coordinates" in the Playfield Hardware chapter): the 720 × 576 picture is beam pixels 144–863 and beam lines 49–624. `hw.inc` gives the picture's top left corner as `VID_X0` (144) and `VID_Y0` (49), so picture position (x, y) is beam position (VID_X0 + x, VID_Y0 + y). In the text, "pixel 200, line 100" is a picture position unless it is called a beam pixel or beam line.

### About this chapter

"Forming a Sprite" goes through the registers in the order you set them and ends with a complete program: a ball bouncing round the screen. The sections after it explain each part in more depth: the image, the window and size, positioning and clipping, moving, magnifying, and depth. Then come the techniques: reusing a sprite down the screen, and collisions. "Sprite DMA" explains how the hardware fetches sprite images, how much it can fetch, and what happens when it cannot keep up; "Feeding a Sprite by Hand" shows how to do without the DMA. The chapter ends with a summary of the registers.

---

## Forming a Sprite

A sprite needs four things: an image in Chip RAM, a window on the screen, its settings, and its DMA turned on.

### Step 1: the image

A sprite's image is stored line by line, top line first, with no gaps between lines. Each line is a whole number of 16-bit words. The pixels are **chunky**, as in a chunky layer: 2, 4 or 8 bits per pixel, packed into words with the leftmost pixel in the highest bits. A pixel value of 0 is **transparent**: whatever is behind the sprite shows through.

For a 32-pixel-wide sprite at 4 bits per pixel, each line is 32 × 4 = 128 bits, or 8 words (16 bytes). A 32 × 24 image takes 24 × 16 = 384 bytes.

The image must be in Chip RAM, at an even address.

### Step 2: the window

Two registers give the sprite's window, as WINX and WINY give a layer's:

- **SPRxH**: HSTART (bits 10–0), the first beam pixel of the sprite, and HSTOP (bits 26–16), the beam pixel just after it.
- **SPRxV**: VSTART (bits 10–0), the first beam line, and VSTOP (bits 26–16), the beam line just after it.

So a 32 × 24 sprite with its top left corner at pixel 200, line 100 of the picture has HSTART = VID_X0 + 200 = 344, HSTOP = 376, VSTART = VID_Y0 + 100 = 149 and VSTOP = 173:

```asm
        move.l  #((VID_X0+232)<<16)|(VID_X0+200),SPR0+SPR_H(a4)
        move.l  #((VID_Y0+124)<<16)|(VID_Y0+100),SPR0+SPR_V(a4)
```

The window also sets the image's size: there is no separate width or height register. The hardware works out from the window how many words each line of the image has (see "The Window and the Image's Size").

### Step 3: the settings

**SPRxCTL** holds the sprite's settings:

| Bits | Field | Meaning |
|------|-------|---------|
| 13–12 | BPP | Bits per pixel: 0 = 2, 1 = 4, 2 = 8 |
| 17–16 | HMAG | Magnify across: 0 = ×1, 1 = ×2, 2 = ×4 |
| 19–18 | VMAG | Magnify down: 0 = ×1, 1 = ×2, 2 = ×4 |
| 21–20 | DEPTH | 0 = in front of all layers … 3 = behind all layers |
| 27–24 | PAL | 2 and 4 bpp: the 16-colour block of the palette |

For a 4-bit sprite in colours 32–47 (palette block 2), in front of everything:

```asm
        move.l  #(1<<SPR_CTL_BPP_B)|(2<<SPR_CTL_PAL_B),SPR0+SPR_CTL(a4)
```

### Step 4: the pointer, and DMA on

**SPRxPT** points at the image's first line. As a plane pointer does, it moves through the image as the hardware fetches it, so it must be written again for every frame: in each vertical blank, by the CPU or (more usually) by the copper. Write it **after** the window and CTL (see "Moving a Sprite").

Sprite DMA needs three enables: the sprite's bit in **SPRDMA** (all eight are on after reset), and **SPREN** and **DMAEN** in DMACON:

```asm
        move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_SPREN_M,DMACON+2(a4)
```

### Example 4-1: A bouncing ball

This program draws a ball into Chip RAM, shows it as sprite 0 over whatever the screen holds, and bounces it round the screen. It uses no interrupts and no copper: in each vertical blank, the CPU writes the sprite's window and then its pointer.

```asm
; Example 4-1: a 32 x 24 ball on sprite 0, 4 bpp, in colours 33-47,
; bouncing round the screen. Assumes supervisor mode.

            include "hw.inc"

BALL        equ     $040000             ; the image, in Chip RAM
BW          equ     32                  ; pixels across
BH          equ     24                  ; lines
CTL_BALL    equ     (1<<SPR_CTL_BPP_B)|(2<<SPR_CTL_PAL_B)

start:      move.w  #$2700,sr
            lea     CUSTOM,a4
            bsr     draw

            ; colours 33-47: from dark red to yellow
            lea     PALETTE+33*4(a4),a0
            move.l  #$400000,d0
            moveq   #15-1,d1
.col:       move.l  d0,(a0)+
            add.l   #$0C1000,d0
            dbra    d1,.col

            move.l  #CTL_BALL,SPR0+SPR_CTL(a4)
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_SPREN_M,DMACON+2(a4)
            move.l  #VIDCON_EN_M,VIDCON(a4)

            move.w  #VID_X0+100,d6      ; x, beam pixel
            move.w  #VID_Y0+50,d7       ; y, beam line
            moveq   #3,d4               ; dx
            moveq   #2,d5               ; dy

.frame:     move.l  VIDSTAT(a4),d0      ; wait for the vertical blank
            and.l   #VIDSTAT_VBLANK_M,d0
            beq.s   .frame
            move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a4)

            ; the window, then the pointer (always last)
            move.w  d6,d0
            add.w   #BW,d0
            swap    d0
            move.w  d6,d0               ; HSTOP in the high half, HSTART in the low
            move.l  d0,SPR0+SPR_H(a4)
            move.w  d7,d0
            add.w   #BH,d0
            swap    d0
            move.w  d7,d0
            move.l  d0,SPR0+SPR_V(a4)
            move.l  #BALL,SPR0+SPR_PT(a4)

            ; move, bouncing half off each edge (unsigned: all positive)
            add.w   d4,d6
            cmp.w   #VID_X0-BW/2,d6
            bls.s   .bx
            cmp.w   #VID_X0+VID_W-BW/2,d6
            blo.s   .xok
.bx:        neg.w   d4
.xok:       add.w   d5,d7
            cmp.w   #VID_Y0-BH/2,d7
            bls.s   .by
            cmp.w   #VID_Y0+VID_H-BH/2,d7
            blo.s   .frame
.by:        neg.w   d5
            bra.s   .frame

; The ball: pixel (x, y) is inside if (x-16)^2 + (y-12)^2 <= 144; inside
; pixels get colour 1 + y/2 (1-12, so 33-44 on the screen), the rest 0
draw:       lea     BALL,a0
            moveq   #0,d3               ; y
.line:      moveq   #0,d4               ; x
.word:      moveq   #0,d0               ; 4 pixels into d0
            moveq   #4-1,d5
.pix:       lsl.w   #4,d0
            move.w  d4,d1
            sub.w   #16,d1
            muls    d1,d1
            move.w  d3,d2
            sub.w   #12,d2
            muls    d2,d2
            add.l   d2,d1
            cmp.l   #144,d1
            bhi.s   .out
            move.w  d3,d2
            lsr.w   #1,d2
            addq.w  #1,d2
            or.w    d2,d0
.out:       addq.w  #1,d4
            dbra    d5,.pix
            move.w  d0,(a0)+
            cmp.w   #BW,d4
            bne.s   .word
            addq.w  #1,d3
            cmp.w   #BH,d3
            bne.s   .line
            rts
```

The ball goes half off each edge of the picture before it bounces: the hardware clips it there, as "Positioning and Clipping" explains. Its position is always a positive beam position, so the program compares it unsigned (`BLS`, `BLO`).

---

## The Image

### Pixels and colours

| BPP | Pixels per word | Colours | Palette entries used |
|-----|-----------------|---------|----------------------|
| 0: 2 bits | 8 | 3 + transparent | PAL × 16 + 1 to PAL × 16 + 3 |
| 1: 4 bits | 4 | 15 + transparent | PAL × 16 + 1 to PAL × 16 + 15 |
| 2: 8 bits | 2 | 255 + transparent | 1 to 255: the whole palette |

A sprite shares the 256-entry palette with the layers. At 2 and 4 bits per pixel, PAL in SPRxCTL picks a 16-colour block of the palette, exactly as a layer's PALOFS does: a pixel value v shows colour PAL × 16 + v. At 8 bits, the value is the colour number and PAL is not used. Value 0 is always transparent, at every depth.

Giving sprites blocks of their own (for example PAL 14 and 15 for all sprites, if the layers use blocks 0 to 13) lets you change sprite colours without touching the layers'.

### Line length

Each line of the image is a whole number of words. For a source width of w pixels:

> words per line = ⌈w × bits per pixel ÷ 16⌉

| Width | 2 bpp | 4 bpp | 8 bpp |
|-------|-------|-------|-------|
| 16 | 2 words | 4 words | 8 words |
| 24 | 3 | 6 | 12 |
| 32 | 4 | 8 | 16 |
| 64 | 8 | 16 | 32 |
| 20 | 3 (4 pixels unused) | 5 | 10 |

If the width does not fill the last word, the pixels left over at the end of each line are not shown; leave them 0. The lines follow one another with no padding, so line n of the image starts at SPRxPT + n × 2 × (words per line).

---

## The Window and the Image's Size

The window says where the sprite is on the screen and, with the magnify settings, how big its image is:

> source width = (HSTOP − HSTART) ÷ HMAG, source height = (VSTOP − VSTART) ÷ VMAG

each rounded up, where HMAG and VMAG are the magnifications (1, 2 or 4). A sprite 32 pixels wide shown at ×2 has a window 64 pixels wide.

There is no limit on the size except the memory's speed (see "Sprite DMA"): a sprite can be 8 pixels or the whole screen wide, and as tall as the screen. Making a sprite bigger is just a matter of widening its window and storing a bigger image.

A sprite shows in its window once per frame. If HSTOP is not greater than HSTART, or VSTOP not greater than VSTART, the window is empty and the sprite does not show. After reset all the windows are empty.

To hide a sprite, turn its bit in SPRDMA off, or set VSTART to 625 (BEAM_H) or more.

---

## Positioning and Clipping

HSTART, HSTOP, VSTART and VSTOP are **unsigned** 11-bit beam coordinates: beam pixels 0–863 across and beam lines 0–624 down, of which the picture is pixels 144–863 and lines 49–624. A beam line starts with its horizontal blank, and a frame with its vertical blank, so a sprite can start left of or above the picture with ordinary positive numbers. A 32-pixel sprite hanging 20 pixels off the left edge, at picture pixels −20 to 11, is

```asm
        move.l  #((VID_X0+12)<<16)|(VID_X0-20),SPR0+SPR_H(a4)    ; beam pixels 124-155
```

The hardware clips a sprite at all four edges:

- **Left.** Pixels in the horizontal blank, before beam pixel 144, are not shown. They are still fetched, so the sprite costs the same memory. HSTART can be as low as 0, so a sprite can hang off the left edge by up to 144 pixels.
- **Top.** Lines in the vertical blank, before beam line 49, are not shown. They are still fetched and used up, so the first line that shows is the right line of the image: there is nothing to do in software. VSTART can be as low as 0, so a sprite can hang off the top by up to 49 lines (but see below).
- **Right.** Pixels from beam pixel 864 on are not shown, and not fetched. An HSTOP above 864 counts as 864.
- **Bottom.** Lines from beam line 625 on are not shown, and not fetched. A VSTOP above 625 counts as 625.

For a 24-line sprite whose top 10 lines are above the picture:

```asm
        move.l  #((VID_Y0+14)<<16)|(VID_Y0-10),SPR0+SPR_V(a4)    ; beam lines 39-62
        move.l  #BALL,SPR0+SPR_PT(a4)       ; the whole image: lines 0-9 are fetched, not shown
```

**Do not start a sprite on beam line 0 or 1.** The DMA needs a moment after the frame starts, and after SPRxPT is written, to fetch the sprite's first words. Those lines are in the vertical blank, so this matters only for a sprite that hangs more than 47 lines off the top.

---

## Moving a Sprite

### When writes take effect

Writing a sprite's SPRxPT, SPRxH, SPRxV or SPRxCTL **starts the sprite again**: the hardware empties its FIFO, takes the new settings, and fetches the image afresh from SPRxPT's current value. The same happens to all eight sprites at the start of each frame (beam line 0, pixel 0, the start of the vertical blank). This makes the registers simple to use, but it brings two rules:

1. **Write SPRxPT last.** SPRxPT moves as the image is fetched, and the DMA starts fetching as soon as the sprite is started (it fetches ahead, as "Sprite DMA" explains). If you write the pointer and then the window, the restart from the window write takes the pointer where the DMA had already moved it. Write the window and CTL first, then the pointer.
2. **Change a sprite while it is not being drawn**: in the vertical blank, or after the sprite's last line. A write while the sprite is on the screen starts it again partway down, from wherever its pointer had got to.

Writing SPRxDAT and SPRDMA does not restart the sprite.

### Who writes the registers

There are two common ways to move sprites each frame:

- **The CPU**, in its vertical blank handler (or after polling VIDSTAT.VBLANK, as Example 4-1 does), writes each sprite's window and then its pointer.
- **The copper**, at the top of its list, writes each sprite's window and pointer, and the CPU changes the values **in the copper list**: the data words of the `CMOVEL`s. This is the same technique as scrolling with the copper (see the Coprocessor Hardware chapter).

Do not mix the two for one sprite in one frame: if the copper writes the pointer at the start of the vertical blank and the CPU then writes the window, rule 1 is broken.

### Example 4-2: Sprites from the copper list

```asm
; Example 4-2: two sprites positioned by the copper. The CPU moves them by
; changing the list's data words (the window values) between frames.

            include "hw.inc"
            include "copper.inc"

            cnop    0,4
spr_list:
spr0_h:     CMOVEL  SPR0+SPR_H,((VID_X0+232)<<16)|(VID_X0+200)  ; sprite 0: 200-231 across
spr0_v:     CMOVEL  SPR0+SPR_V,((VID_Y0+124)<<16)|(VID_Y0+100)  ;           100-123 down
            CMOVEL  SPR0+SPR_PT,BALL                ; pointer last
spr1_h:     CMOVEL  SPR1+SPR_H,((VID_X0+432)<<16)|(VID_X0+400)
spr1_v:     CMOVEL  SPR1+SPR_V,((VID_Y0+324)<<16)|(VID_Y0+300)
            CMOVEL  SPR1+SPR_PT,BALL
            ; ... the rest of the list (plane pointers, colour changes)
            CSTOP

; Move sprite 1 to beam position (d0, d1): its window's four values are
; the data words at +2 and +6 of the two CMOVELs
move1:      move.w  d0,spr1_h+6         ; HSTART (low half)
            add.w   #32,d0
            move.w  d0,spr1_h+2         ; HSTOP (high half)
            move.w  d1,spr1_v+6         ; VSTART
            add.w   #24,d1
            move.w  d1,spr1_v+2         ; VSTOP
            rts
```

Call `move1` when the copper is not reading those words: for example, once the picture has started (BEAMPOS line VID_Y0 or more), after the copper's work at the start of the frame is done. For many sprites, or to make the change exact, use two lists and swap them (see "Double-Buffered Lists" in the Coprocessor Hardware chapter).

---

## Magnifying

**HMAG** shows each source pixel 1, 2 or 4 times across, and **VMAG** shows each source line on 1, 2 or 4 screen lines. Remember to make the window bigger to match: a 32 × 24 image at ×2 by ×2 needs a 64 × 48 window. Magnify costs no more memory across (the same words are spread over more pixels), but a magnified line is fetched again for each screen line it covers, so VMAG does not save memory cycles.

```asm
        ; the 32 x 24 ball at x2 by x2: a 64 x 48 window
        move.l  #((VID_X0+200+64)<<16)|(VID_X0+200),SPR0+SPR_H(a4)
        move.l  #((VID_Y0+100+48)<<16)|(VID_Y0+100),SPR0+SPR_V(a4)
        move.l  #(1<<SPR_CTL_BPP_B)|(1<<SPR_CTL_HMAG_B)|(1<<SPR_CTL_VMAG_B)|(2<<SPR_CTL_PAL_B),SPR0+SPR_CTL(a4)
        move.l  #BALL,SPR0+SPR_PT(a4)
```

The hardware does not mirror sprites. For an object that faces either way, store both images and point SPRxPT at the one you want.

---

## Depth: Sprites and Layers

Each sprite's **DEPTH** puts it among the three layers, in the order PRIO gives them (see "Priority and Transparency" in the Playfield Hardware chapter). From the front of the screen to the back:

| From the front | |
|----------------|--|
| 1 | Sprites with DEPTH 0 |
| 2 | The front layer |
| 3 | Sprites with DEPTH 1 |
| 4 | The middle layer |
| 5 | Sprites with DEPTH 2 |
| 6 | The back layer |
| 7 | Sprites with DEPTH 3 |
| 8 | The background colour |

Where two sprites overlap, the **lower-numbered** sprite is in front: sprite 0 in front of sprite 1, and so on. Where a layer's pixel is transparent (a layer with TRANSP set, pixel value 0), the sprites and layers behind it show through; a layer without TRANSP hides everything behind it, so a sprite behind such a layer only shows outside the layer's window.

Depth is how a sprite goes behind scenery: in a dual-playfield screen with the scenery as the front layer and the sky as the back, a bird with DEPTH 1 flies behind trees but in front of the sky.

Depth is per sprite and can be changed at any time with SPRxCTL (in the vertical blank: a CTL write restarts the sprite).

In **direct colour** mode (VIDCON.DIRECT) the layers make one picture together, so there is nothing to go between: sprites are drawn in front of the whole picture, in their palette colours, and DEPTH is not used.

---

## Reusing a Sprite down the Screen

Eight sprites can show at once on any line. To show more than eight objects on a screen, reuse a sprite further down: once its first use has been drawn, the copper writes the sprite's registers again for the next use. It is the same idea as the Amiga's, where the sprite's data holds more control words, but here the copper does it.

The rules:

- the new use must start on a line after the old one ends;
- the copper's writes must come after the old use's last line has been drawn (WAIT for a position on a later line), and before the new use's first line;
- as always, the window and CTL first, then the pointer.

### Example 4-3: One sprite, three ships

```asm
; Example 4-3: sprite 0 shows three 32 x 24 ships: at lines 100, 200 and
; 300. Each ship can be a different image or colour.

            include "hw.inc"
            include "copper.inc"

SHIP        equ     $040000             ; two 32 x 24 images at 4 bpp, in Chip RAM
SHIP2       equ     SHIP+24*16
CTL_SHIP    equ     (1<<SPR_CTL_BPP_B)|(3<<SPR_CTL_PAL_B)

            cnop    0,4
ships:      CMOVEL  SPR0+SPR_H,((VID_X0+232)<<16)|(VID_X0+200)  ; ship 1
            CMOVEL  SPR0+SPR_V,((VID_Y0+124)<<16)|(VID_Y0+100)  ; lines 100-123
            CMOVEL  SPR0+SPR_PT,SHIP

            CWAIT   VID_Y0+124,0                    ; ship 1 finished
            CMOVEL  SPR0+SPR_H,((VID_X0+532)<<16)|(VID_X0+500)  ; ship 2
            CMOVEL  SPR0+SPR_V,((VID_Y0+224)<<16)|(VID_Y0+200)  ; lines 200-223
            CMOVEL  SPR0+SPR_CTL,CTL_SHIP|(4<<SPR_CTL_PAL_B)  ; other colours (palette block 7)
            CMOVEL  SPR0+SPR_PT,SHIP

            CWAIT   VID_Y0+224,0                    ; ship 2 finished
            CMOVEL  SPR0+SPR_H,((VID_X0+392)<<16)|(VID_X0+360)  ; ship 3
            CMOVEL  SPR0+SPR_V,((VID_Y0+324)<<16)|(VID_Y0+300)
            CMOVEL  SPR0+SPR_CTL,CTL_SHIP
            CMOVEL  SPR0+SPR_PT,SHIP2               ; another image
            CSTOP
```

The first ship's CTL is written once by the CPU (CTL_SHIP); the list sets it back at the third ship, so it is right again for the first ship of the next frame.

Each restart empties the FIFO, and the sprite's DMA then has from the WAIT to the new ship's first line to fetch ahead. Leave at least a line between uses, as this example does, so that the new image is ready in time.

---

## Collisions

The hardware checks every pixel on the screen for sprites touching: **SPRCOLL** collects what it finds.

| Bits | Set when |
|------|----------|
| 7–0 (SPR) | Bit n: an opaque pixel of sprite n was on the same screen pixel as an opaque pixel of another sprite |
| 15–8 (L0) | Bit 8 + n: an opaque pixel of sprite n was on an opaque pixel of layer 0 |
| 23–16 (L1) | Bit 16 + n: the same, against layer 1 |
| 31–24 (L2) | Bit 24 + n: the same, against layer 2 |

A pixel is **opaque** if it is drawn: a sprite pixel with a value other than 0; a layer pixel inside the layer's window that is not transparent (TRANSP set and value 0). Depth does not matter: a sprite behind a layer still collides with it. Only picture pixels count, not those clipped at the edges or hanging into the blanking.

The bits are **sticky**: once set, a bit stays set until you clear it by writing a 1 to it. The usual way is to read SPRCOLL once a frame, in the vertical blank, and then clear the bits you read:

```asm
        ; in the vertical blank: what touched in the last frame?
        move.l  SPRCOLL(a4),d0
        move.l  d0,SPRCOLL(a4)          ; clear exactly the bits that were set
        btst    #0,d0                   ; ship (sprite 0) hit another sprite?
        bne     hit_sprite
        btst    #16+0,d0                ; ship touched layer 1 (the walls)?
        bne     hit_wall
```

The sprite bits do not say which other sprite was hit: if bits 0 and 3 are set, sprites 0 and 3 might have touched each other, or each might have touched another sprite. If that matters, keep the candidates on sprites of their own, or check the objects' positions in software once SPRCOLL says something touched.

Collisions are found on each line as it is drawn, and reach SPRCOLL just after the line ends; a frame's collisions are all in SPRCOLL by the start of the vertical blank.

---

## Sprite DMA

### How a sprite is fetched

Each sprite has a **FIFO** of 32 words: its data registers. The DMA fetches the image's words into the back of the FIFO, and the sprite takes them from the front as it is drawn. Because it is a FIFO, the image's lines can be any length: a line longer than 32 words simply streams through.

The DMA fills a sprite's FIFO whenever it has room, using any memory cycle nobody else wants: in the horizontal blank, in quiet stretches of a line, in the vertical blank. So a sprite's words are mostly fetched **ahead**, before they are needed. Only when a FIFO is about to run dry does the sprite's fetch become urgent. Then it competes with the layers by deadline (whoever needs a word soonest goes first) and may take the CPU's memory cycle, exactly as a layer does (see "The Fetch Budget" in the Playfield Hardware chapter).

The FIFO is emptied, and the fetch starts again from SPRxPT, at the start of each vertical blank and whenever the sprite's registers are written (see "Moving a Sprite"). During the vertical blank each sprite fills its FIFO with up to 32 words of its first lines, so every sprite starts the frame with a lead.

### How many sprites the memory can feed

Sprites and layers share one budget. The display's own memory cycles give about **12 words for every 16 screen pixels**, guaranteed; cycles the CPU, audio and copper leave free give more.

- A **layer** needs, per 16 source pixels, 1 word for each plane (planar) or b words at b bits per pixel (chunky); scaled ×2 across, half that per 16 screen pixels.
- A **sprite** needs, per 16 source pixels, 2, 4 or 8 words at 2, 4 or 8 bits per pixel, while the beam is over it; magnified ×2 across, half that per 16 screen pixels.

Sprites side by side do not add up: only sprites over the **same** pixels at the same time do. And each FIFO's lead of 32 words lets a sprite fetch ahead into quieter parts of the line, so short overlaps (up to about 64 pixels at 8 bpp, or 256 at 2 bpp) are smoothed out.

How many sprites can be stacked over the same 16 screen pixels with only the guaranteed cycles:

| Layers | Words per 16 pixels | 8 bpp | 8 bpp, ×2 across | 4 bpp | 2 bpp |
|--------|--------------------|-------|------------------|-------|-------|
| None | 0 | 1 | 3 | 3 | 6 |
| One 8 bpp layer at 2× | 4 | 1 | 2 | 2 | 4 |
| Two 5-plane layers at 2× | 5 | 0 | 1 | 1 | 3 |
| Two 4-plane layers at 1× | 8 | 0 | 1 | 1 | 2 |
| Three 4-plane layers at 1× | 12 | 0 | 0 | 0 | 0 |

These are worst cases: wide sprites stacked exactly on top of each other for longer than their lead. Typical game screens, with sprites spread out and the CPU not using every cycle, do far better. Sprites that are only partly stacked, or narrow, fit easily.

### Running out: SPRUNDER

If the DMA cannot keep a sprite's FIFO filled, the sprite **underruns**: **VIDSTAT.SPRUNDER** (bit 7) is set, and the sprite shows nothing more until it next starts (the next vertical blank, or a write to its registers), because its words would no longer line up with its lines. SPRUNDER is sticky (clear it by writing a 1), and with its enable set in VIDINTEN it raises the VIDERR interrupt, as the layers' OVERRUN bits do.

An underrun means the screen asks too much of the memory at that point. Use fewer bits per pixel, magnify across instead of using a wider image, spread the sprites out, or move one of them in front of fewer layers' fetches.

### Turning sprite DMA on and off

| Register | Bits | Function |
|----------|------|----------|
| DMACON | SPREN (5), DMAEN (9) | All sprite DMA. Both must be set |
| SPRDMA | SPR (7–0), SETCLR (15) | DMA per sprite. Set/clear, as DMACON. All on after reset |

A sprite is fetched only while its SPRDMA bit, SPREN and DMAEN are all set. Turning a sprite's DMA off hides it (unless it is fed by hand: next section).

```asm
        move.w  #SPRDMA_SETCLR_M|$0C,SPRDMA+2(a4)  ; sprites 2 and 3 on
        move.w  #$01,SPRDMA+2(a4)                  ; sprite 0 off (SETCLR clear)
```

---

## Feeding a Sprite by Hand

With a sprite's DMA off (its SPRDMA bit clear), the CPU or the copper can feed the sprite itself, by writing words into its FIFO through **SPRxDAT**. The sprite shows as its window and CTL say, and takes its words from the FIFO as it is drawn, exactly as with DMA. Reading SPRxDAT gives the number of words in the FIFO (0–32).

- Each write pushes one 16-bit word. Write the register's low half (`SPRxDAT+2`, or a whole long word); a write when the FIFO is full is ignored.
- The FIFO is emptied at the start of each vertical blank, and when the sprite's PT, H, V or CTL is written, so push the frame's words after those.
- If the FIFO is empty when the sprite needs a word, the sprite **waits**: it is transparent until a word arrives, and the rest of the line follows from there. A hand-fed sprite does not set SPRUNDER.

This is useful for sprites whose image is computed rather than stored, and for effects that change a sprite line by line. The copper is the natural feeder, because it can push words at exact beam positions.

### Example 4-4: A copper-fed beam

```asm
; Example 4-4: sprite 0, fed by the copper, is a 16-pixel-wide beam down
; lines 100-399 whose pattern changes on every line. 2 bpp: 2 words a line.
; The CPU set SPR0's DMA off (SPRDMA) and its palette colours 4*16+1 to +3.

            include "hw.inc"
            include "copper.inc"

CTL_BEAM    equ     (0<<SPR_CTL_BPP_B)|(4<<SPR_CTL_PAL_B)

            cnop    0,4
beam_list:  CMOVEL  SPR0+SPR_H,((VID_X0+360+16)<<16)|(VID_X0+360)  ; pixels 360-375
            CMOVEL  SPR0+SPR_V,((VID_Y0+400)<<16)|(VID_Y0+100)     ; lines 100-399
            CMOVEL  SPR0+SPR_CTL,CTL_BEAM           ; (these empty the FIFO: write them first)
            ; 15 lines' worth in the vertical blank: room for one more line
            CLDI    CY,$1B1B
            CLDI    CX,30
beam_pre:   CMOVR   SPR0+SPR_DAT+2,CY
            CADDI   CY,$0101
            CSUBI   CX,1
            CSKIPEQ
            CJUMP   beam_pre
            ; then 2 words a line, keeping 15 lines ahead
            CWAIT   VID_Y0+100,0                    ; the blank before line 100
beam_loop:  CMOVR   SPR0+SPR_DAT+2,CY
            CMOVR   SPR0+SPR_DAT+2,CY
            CADDI   CY,$0101
            CWAITP  0                               ; the next line's blank
            CSKIP   VID_Y0+385,0                    ; reached line 385? done
            CJUMP   beam_loop
            CSTOP
```

The FIFO holds 32 words: 16 lines of this sprite. The list puts 15 lines' worth in during the vertical blank, leaving room for one line, then pushes one line's words at the start of each line, before the sprite takes that line's words; so the FIFO never overflows (a word written to a full FIFO is lost) and stays 15 lines ahead of the beam. The loop stops 15 lines early: its last push, at the start of line 384, is line 399's words, and the SKIP leaves the loop at the start of line 385.

---

## Summary of Sprite Registers

Offsets in the custom block at `$E00000`.

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| SPRDMA | `$500` | Set/clear | SPR (7–0): DMA on for sprite n; SETCLR (15). All on after reset. Low half at `$502` |
| SPRCOLL | `$504` | W1C | SPR (7–0), L0 (15–8), L1 (23–16), L2 (31–24): collisions, sticky |
| SPRxPT | SPRn + `$00` | RW | The next word of the image (22–1). Write it each frame, last |
| SPRxH | SPRn + `$04` | RW | HSTART (10–0), HSTOP (26–16): unsigned beam pixels (0–863; the picture is 144–863) |
| SPRxV | SPRn + `$08` | RW | VSTART (10–0), VSTOP (26–16): unsigned beam lines (0–624; the picture is 49–624). Start on beam line 2 or later |
| SPRxCTL | SPRn + `$0C` | RW | BPP (13–12), HMAG (17–16), VMAG (19–18), DEPTH (21–20), PAL (27–24) |
| SPRxDAT | SPRn + `$10` | W, R | Write: push a word (15–0) into the FIFO (DMA off). Read: words in the FIFO (5–0) |

SPRn = `$520` + n × `$20`: SPR0 `$520`, SPR1 `$540` … SPR7 `$600`.

Related bits elsewhere:

| Register | Bit | Function |
|----------|-----|----------|
| DMACON | 5, SPREN | Sprite DMA (with DMAEN, bit 9) |
| VIDSTAT | 7, SPRUNDER | A sprite's FIFO ran dry. W1C |
| VIDINTEN | 7, SPRUNDER | Raise VIDERR on SPRUNDER |

### State after reset

SPREN is clear (DMACON is cleared by every reset), SPRDMA has all eight sprites on, and every sprite's PT, H, V and CTL are 0: empty windows, so nothing shows. SPRCOLL is 0.

### Equates in hw.inc

| Equate | Value |
|--------|-------|
| `SPRDMA`, `SPRCOLL` | `$500`, `$504` |
| `SPR0` … `SPR7` | `$520` … `$600` |
| `SPR_PT`, `SPR_H`, `SPR_V`, `SPR_CTL`, `SPR_DAT` | `$00`, `$04`, `$08`, `$0C`, `$10` |
| `SPR0_PT` … `SPR7_DAT` | Each register's full offset |
| `SPR_CTL_BPP_B`, `SPR_CTL_HMAG_B`, `SPR_CTL_VMAG_B`, `SPR_CTL_DEPTH_B`, `SPR_CTL_PAL_B` | CTL fields (`_B` bit numbers, `_M` masks) |
| `SPRDMA_SETCLR_M`, `DMACON_SPREN_M`, `VIDSTAT_SPRUNDER_M` | The enables and status |
