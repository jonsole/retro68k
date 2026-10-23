# Chapter 6: DMA Engine and Blitter Hardware

## Introduction

The **DMA engine** moves data so the 68000 does not have to. It copies and fills memory, draws graphics (it is retro68k's **blitter**), writes the hardware registers, and moves data to and from the USB serial link. You describe a job, start it, and the CPU carries on with other work while the engine does it, using memory cycles nobody else needs.

The engine can:

- copy or fill a block of memory, at up to about 38 MB/s copying and 77 MB/s filling, against about 4 MB/s for the 68000;
- copy or fill a rectangle: part of a sprite sheet into a screen, a window of a picture, a box of colour;
- draw objects with transparent parts, a pixel at a time at any colour depth;
- combine source and destination with any logic function (AND, OR, XOR, NOT and the rest), or add them pixel by pixel, for masks, shading and glows;
- run a chain of jobs from memory with no help from the CPU, on any of four channels at once;
- write a block of registers in one job, start other channels, or be started by the copper or a timer.

This chapter covers:

- forming a job, step by step, and a first example;
- the job registers and descriptors;
- the operations: COPY, FILL, KEYCOPY, LOGIC and ADD;
- pixel depths, pixel positions and the automatic edge masks;
- rectangles, strides and clipping;
- overlapping copies and backwards jobs;
- drawing into planar layers, including the Amiga's cookie cut;
- chains of jobs and the descriptor RAM;
- starting jobs from the copper and from timers;
- registers, palettes and the ROM as sources and destinations;
- moving data to and from the USB serial link;
- status, interrupts and errors;
- priority, HIGH jobs and speed.

You should have read "Working with the Hardware Registers" in the Introduction and System Control Hardware chapter, and the Playfield Hardware chapter, since most blits draw into a layer.

**Note:** The engine is built in the FPGA design (`fpga/rtl/dmx.v`) and tested in simulation (`make -C sim dtest`, which checks random jobs byte for byte against a model), but not yet on the board.

### Comparison with the Amiga

| Feature | Amiga blitter (OCS/ECS) | retro68k DMA engine |
|---------|-------------------------|---------------------|
| Jobs at once | 1 | 4 channels, taking turns |
| Starting a job | Write the registers, write BLTSIZE; wait for the blitter before the next | The same (a channel's job registers, then RUN), or a chain of jobs in memory that runs alone |
| Pixels | Bitplanes: one blit per plane, with shifts and masks | Chunky pixels at 1, 2, 4 or 8 bits, positioned to the pixel; planar layers a plane at a time, as on the Amiga |
| Transparent drawing | A mask plane and the minterms (cookie cut) | Chunky: a colour key, no mask. Planar: the cookie cut, with two LOGIC jobs per plane |
| Logic | Any function of three sources | Any function of source and destination |
| Arithmetic | None | ADD, per pixel, wrapping or saturating, signed or unsigned |
| Edge masks | BLTAFWM, BLTALWM | Worked out by the hardware |
| Line drawing, area fill | Yes | No (version 2) |
| Register writes | The copper only | The copper, or a job: block copies into the registers |
| Disk and other transfers | Their own DMA channels | The same engine, through ports |
| Priority | BLTPRI ("blitter nasty") | The HIGH bit, per job, leaving the CPU a share |

### Conventions in this chapter

- Examples are 68000 assembly language for vasm, in Motorola syntax, starting with `include "hw.inc"`. **a4 holds CUSTOM** (`$E00000`) and **a5 holds SYSTEM** (`$F00000`).
- The engine uses **CPU addresses**: a job's addresses are written as the CPU sees them, so a register is `CUSTOM+BGCOLOR` and a palette entry `CUSTOM+PALETTE0+5*4`.
- The examples use these constants for CTRL (section "The Job Registers"):

```asm
COPY8       equ     3<<DMX_CTRL_BPP_B                                   ; COPY, 8 bits per pixel
FILL8       equ     1|(3<<DMX_CTRL_BPP_B)|(2<<DMX_CTRL_SRCKIND_B)       ; FILL, 8 bits per pixel
RUNIT       equ     DMX_CHCTRL_RUN_M|(1<<DMX_CHCTRL_CPUSHARE_B)         ; RUN, CPU share 1 in 4
```

---

## Forming a Job

A job is eight long words: what to do, where from, where to, how big, and what comes next. You write them into one of the four channels' **job registers** and start the channel. This section clears part of a screen and copies an image onto it, from the CPU.

### Step 1: Turn the engine on

The engine uses memory cycles only while **DMACON.BLTEN** and **DMACON.DMAEN** are both set:

```asm
        move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BLTEN_M,DMACON+2(a4)
```

### Step 2: Describe the job

The job registers of channel n start at `DMXn`, in this order: CTRL, SRC, DST, WIDTH, HEIGHT, STRIDE, VALUE, NEXT. To fill 64 bytes at `$080000` with zeros:

```asm
        lea     DMX0(a4),a0
        move.l  #FILL8,DMX_CTRL(a0)             ; FILL, 8 bpp
        move.l  #$080000,DMX_DST(a0)            ; where
        move.l  #64,DMX_WIDTH(a0)               ; 64 bytes ...
        move.l  #1,DMX_HEIGHT(a0)               ; ... in one row
        move.l  #0,DMX_VALUE(a0)                ; the value
        move.l  #0,DMX_NEXT(a0)                 ; no more jobs after this one
```

SRC and STRIDE are not used by a one-row fill.

### Step 3: Start it

```asm
        move.l  #RUNIT,DMX_CHCTRL(a0)           ; run the job in the registers
```

RUN starts the job already in the registers. The channel is **BUSY** (CHSTAT bit 0) until the job, and any jobs chained after it, are done; then **DONE** (bit 1) is set.

### Step 4: Wait, or do something else

```asm
.wait:  btst    #DMX_CHSTAT_BUSY_B,DMX_CHSTAT+3(a0)
        bne.s   .wait
```

Better, carry on with other work and take the channel's interrupt (see "Status, Interrupts and Errors"). While a channel is busy its job registers ignore writes, so you cannot spoil a running job by accident; another channel can be set up meanwhile.

### Example 6-1: Clear a box and draw an image into it

A 320 × 200 chunky 8 bpp screen at `SCREEN` (rows of 320 bytes). Clear a 64 × 48 box at (100, 50), then copy a 32 × 32 image from a sprite sheet (rows of 256 bytes) into its middle.

```asm
; Example 6-1: clear a box, then copy an image into it (8 bpp chunky)
SCREEN      equ     $100000
SHEET       equ     $140000             ; a 256-pixel-wide sheet
ROW         equ     320

            lea     DMX0(a4),a0
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BLTEN_M,DMACON+2(a4)

            ; the box: 64 x 48 at (100, 50), filled with colour 0
            move.l  #FILL8,DMX_CTRL(a0)
            move.l  #SCREEN+50*ROW+100,DMX_DST(a0)
            move.l  #64,DMX_WIDTH(a0)
            move.l  #48,DMX_HEIGHT(a0)
            move.l  #ROW,DMX_STRIDE(a0)         ; destination stride (low half)
            move.l  #0,DMX_VALUE(a0)
            move.l  #0,DMX_NEXT(a0)
            move.l  #RUNIT,DMX_CHCTRL(a0)
            bsr     wait0

            ; the image: 32 x 32 from the sheet's frame at (64, 0), to (116, 58)
            move.l  #COPY8,DMX_CTRL(a0)
            move.l  #SHEET+64,DMX_SRC(a0)
            move.l  #SCREEN+58*ROW+116,DMX_DST(a0)
            move.l  #32,DMX_WIDTH(a0)
            move.l  #32,DMX_HEIGHT(a0)
            move.l  #(256<<16)|ROW,DMX_STRIDE(a0)   ; source stride, destination stride
            move.l  #RUNIT,DMX_CHCTRL(a0)
            bsr     wait0
            rts

wait0:      btst    #DMX_CHSTAT_BUSY_B,DMX0+DMX_CHSTAT+3(a4)
            bne.s   wait0
            rts
```

The second job only changes the fields that differ: the job registers keep their values from the last job.

---

## The Job Registers

Each channel has these registers. The first eight are the **job registers**; a **descriptor** in memory has exactly the same layout (see "Chains of Jobs").

| Offset | Name | Bits | Meaning |
|--------|------|------|---------|
| `$00` | CTRL | see below | The operation and its options |
| `$04` | SRC | 23–0 | The source's first pixel (CPU address), or a port number |
| `$08` | DST | 23–0 | The destination's first pixel, or a port number |
| `$0C` | WIDTH | 23–0 | Pixels per row (bytes at 8 bpp) |
| `$10` | HEIGHT | ROWS (15–0), SRCBIT (18–16), DSTBIT (22–20) | Rows; the first pixel's place within its byte, at 1, 2 and 4 bpp |
| `$14` | STRIDE | SRCSTRIDE (31–16), DSTSTRIDE (15–0), signed | Bytes from one row's start to the next |
| `$18` | VALUE | 31–0 | FILL's value, KEYCOPY's key colour, or a constant source |
| `$1C` | NEXT | 23–0 | The next descriptor; 0 = the last job |
| `$20` | CHDESC | 23–0 | The descriptor START loads |
| `$24` | CHCTRL | START (0), RUN (1), STOP (2), PAUSE (3), CPUSHARE (5–4) | Control |
| `$28` | CHSTAT | BUSY (0), DONE (1), ERR (2), PAUSED (3) | Status; DONE and ERR are sticky, write 1 to clear |
| `$2C` | CHERR | 23–0 | The address that caused an error |

Channel n is at `DMXn` = `$300` + n × `$40`.

**CTRL:**

| Bits | Name | Meaning |
|------|------|---------|
| 2–0 | OP | 0 COPY, 1 FILL, 2 KEYCOPY, 3 LOGIC, 4 ADD |
| 7–4 | FN | LOGIC: the truth table. ADD: bit 4 saturate, bit 5 signed |
| 9–8 | BPP | 0 = 1, 1 = 2, 2 = 4, 3 = 8 bits per pixel |
| 10 | DESC | Run backwards (see "Overlapping Copies") |
| 11 | HIGH | May take some of the CPU's memory cycles |
| 12 | IRQ | Interrupt when this job is done |
| 14–13 | SRCKIND | 0 memory, 1 port, 2 none (FILL), 3 VALUE |
| 16–15 | DSTKIND | 0 memory, 1 port |

---

## The Operations

### COPY and FILL

**COPY** copies pixels from the source to the destination. **FILL** writes VALUE to every pixel of the destination: at 8 bpp it repeats all four bytes of VALUE by address (the byte at an address ending in 0, 4, 8 or C gets VALUE's top byte), so a fill of whole long words writes VALUE exactly, and a fill with all four bytes the same fills single bytes; at 1, 2 and 4 bpp every pixel gets VALUE's low bits.

```asm
        move.l  #$00000000,DMX_VALUE(a0)        ; 8 bpp: colour 0
        move.l  #$12121212,DMX_VALUE(a0)        ; 8 bpp: colour $12 at any address
        move.l  #3,DMX_VALUE(a0)                ; 2 bpp: colour 3
```

### KEYCOPY: transparent copies

**KEYCOPY** copies like COPY but leaves alone every destination pixel whose source pixel is the **key colour**, VALUE's low bits. This is how you draw an object with a transparent background into a chunky screen: draw the object's background in the key colour (usually 0) and KEYCOPY it.

```asm
KEY8        equ     2|(3<<DMX_CTRL_BPP_B)                   ; KEYCOPY, 8 bpp, from memory
        move.l  #KEY8,DMX_CTRL(a0)
        move.l  #0,DMX_VALUE(a0)                ; colour 0 is transparent
```

At 8 bpp a key pixel is simply a byte not written, so KEYCOPY is as fast as COPY. At 1, 2 and 4 bpp, several pixels share a byte, and the engine reads the destination to keep the pixels it does not change.

### LOGIC: masks and bit operations

**LOGIC** combines each bit of the source with the matching bit of the destination. FN is the truth table: result = FN bit (source × 2 + destination).

| FN | Result | Use |
|----|--------|-----|
| `$8` | source AND destination | Keep only where a mask is set |
| `$E` | source OR destination | Draw a shape on top |
| `$6` | source XOR destination | Draw and undraw with the same job; invert |
| `$2` | destination AND NOT source | Cut a shape out (cookie cut) |
| `$5` | NOT destination | Invert, ignoring the source |
| `$A` | source | The same as COPY |

With SRCKIND = 3 the source is a constant, VALUE's low bits for every pixel: XOR with 1s inverts an area without a source image.

### ADD: shading and effects

**ADD** adds each source pixel to its destination pixel, at the job's colour depth; carries never spill from one pixel into the next. FN bit 4 chooses **saturation** (the result sticks at the limit instead of wrapping), and FN bit 5 **signed** pixels (two's complement) for saturation.

```asm
ADD8        equ     4|(3<<DMX_CTRL_BPP_B)|(3<<DMX_CTRL_SRCKIND_B)   ; ADD a constant, 8 bpp
        move.l  #ADD8|(1<<DMX_CTRL_FN_B),DMX_CTRL(a0)   ; unsigned, saturating
        move.l  #16,DMX_VALUE(a0)                       ; + 16
```

With palettes laid out as ramps (colour 0 dark to colour 15 bright, and so on), adding a constant brightens an area, subtracting (adding the two's complement, with wrap) darkens it, and adding a light map image lights a scene. Adding 16 moves an area into the next 16-colour palette block. Signed saturating ADD at 8 bpp mixes signed 8-bit sound samples.

LOGIC and ADD read every destination word, so they take 3 memory cycles per 2 bytes instead of 2.

---

## Pixel Depths and Positions

A job's pixels are 1, 2, 4 or 8 bits (BPP), packed as the chunky layers pack them: the first pixel of a byte in its top bits. WIDTH counts pixels.

At 8 bpp every pixel is a byte, and an address says where it is. Below 8 bpp an address picks a byte, and **SRCBIT** and **DSTBIT** (in HEIGHT) pick the pixel within it, counting from the top bits: at 1 bpp, 0–7; at 2 bpp, 0–3; at 4 bpp, 0–1. So the pixel at x in a 4 bpp row starting at ROW is at address ROW + x ÷ 2, pixel x mod 2.

```asm
        ; a 4 bpp job starting at pixel x = 37 of a row at ROWADDR
        move.l  #ROWADDR+37/2,DMX_DST(a0)
        move.l  #((37&1)<<DMX_HEIGHT_DSTBIT_B)|ROWS,DMX_HEIGHT(a0)
```

Source and destination can start at different pixels within their bytes: the engine shifts the data to line them up, as the Amiga's barrel shifter does. You never set masks: the engine works out which pixels of each row's first and last bytes belong to the job, and leaves the others as they were.

---

## Rectangles, Strides and Clipping

A job is HEIGHT rows of WIDTH pixels. Each row starts STRIDE bytes after the last, with separate strides for source and destination, so a frame can be copied from a sheet of any width into a screen of any other width. A one-row job is a plain copy or fill: WIDTH can be up to 16 MB.

| Stride | Effect |
|--------|--------|
| The row's bytes | The rows one after another |
| Larger | A rectangle inside a wider picture |
| 0 (source) | The same source row on every destination row: stripes, or a pattern down a column |
| Negative | Rows run up the screen: an image drawn upside down |

**Clipping** is done by trimming the job before you start it; the strides stay the same, so the trimmed rows still line up:

- **Left:** skip k pixels: move SRC and DST on by k pixels (and SRCBIT, DSTBIT below 8 bpp), and take k from WIDTH.
- **Right:** take the pixels past the edge from WIDTH.
- **Top:** skip r rows: add r × SRCSTRIDE to SRC and r × DSTSTRIDE to DST, and take r from HEIGHT.
- **Bottom:** take the rows past the edge from HEIGHT.

If WIDTH or HEIGHT comes to 0 or less, the object is off the screen: skip the job (a job of zero width or height does nothing, and a chain carries on past it).

---

## Overlapping Copies

When the source and destination overlap, as when scrolling part of the screen, the order matters. A job normally runs forwards: rows from the first, pixels from the left. That is right when the destination is **before** the source in memory (moving up or left). When the destination is **after** the source (moving down or right), set **DESC**: the job runs from the last pixel of the last row back to the first. SRC and DST still give the first pixel of the first row either way.

```asm
        ; scroll a 200-row band of a 320-byte-wide screen down by 8 rows
        move.l  #COPY8|DMX_CTRL_DESC_M,DMX_CTRL(a0)
        move.l  #SCREEN+20*320,DMX_SRC(a0)
        move.l  #SCREEN+28*320,DMX_DST(a0)
        move.l  #320,DMX_WIDTH(a0)
        move.l  #200,DMX_HEIGHT(a0)
        move.l  #(320<<16)|320,DMX_STRIDE(a0)
```

---

## Drawing into Planar Layers

A planar layer is several 1 bpp pictures, one per plane (Playfield Hardware chapter). The engine draws into it at BPP = 0, a plane at a time, positioned to the pixel.

- **Separate planes:** one job per plane, chained (see "Chains of Jobs"), each moving SRC and DST on by a plane.
- **Interleaved planes** (each plane's row next to the next plane's): one job does all the planes, if the source is interleaved the same way. HEIGHT = rows × planes, and each stride = one plane row's bytes.

**Transparent objects (the cookie cut).** Keep a 1 bpp **mask** of the object, 1 wherever it has a pixel. For each plane:

1. LOGIC, FN = `$2` (destination AND NOT mask), source = the mask: cut the object's shape out of the background;
2. LOGIC, FN = `$E` (OR), source = the object's plane: put the object in.

KEYCOPY does not help here: in a planar layer a colour is spread over the planes, so no single plane knows which pixels are transparent.

---

## Chains of Jobs

A job's NEXT points at a **descriptor**: eight long words in memory, laid out like the job registers. When a job is done, the channel loads the descriptor at NEXT into its job registers and runs it, and so on until a job's NEXT is 0. The whole chain runs without the CPU.

Descriptors can be in Chip RAM, long-word aligned, or in the **descriptor RAM**: 2 KB at `CUSTOM+DESCRAM` (`$E06000`), room for 64. Loading a descriptor from Chip RAM takes 16 memory cycles; from the descriptor RAM it takes none, which suits short, frequent jobs.

There are two ways to start a chain:

- **START** loads the descriptor at CHDESC and runs it;
- **RUN** runs the job already in the job registers, whose NEXT points at the rest.

### Example 6-2: Draw three objects with one chain

```asm
; Example 6-2: three KEYCOPY jobs, chained in the descriptor RAM, started with START.
; Each object is 32 x 32 at 8 bpp, from a 256-wide sheet to a 320-wide screen.
KEY8        equ     2|(3<<DMX_CTRL_BPP_B)
D0          equ     CUSTOM+DESCRAM
            lea     chain(pc),a1
            lea     D0,a2
            moveq   #3*8-1,d0
.copy:      move.l  (a1)+,(a2)+                 ; the descriptors into the descriptor RAM
            dbra    d0,.copy
            move.l  #D0,DMX3+DMX_CHDESC(a4)
            move.l  #DMX_CHCTRL_START_M|(1<<DMX_CHCTRL_CPUSHARE_B),DMX3+DMX_CHCTRL(a4)
            rts

;           CTRL            SRC          DST                   WIDTH HEIGHT STRIDE       VALUE NEXT
chain:      dc.l    KEY8,   SHEET+0,     SCREEN+40*320+10,     32,   32, (256<<16)|320, 0, D0+32
            dc.l    KEY8,   SHEET+32,    SCREEN+40*320+90,     32,   32, (256<<16)|320, 0, D0+64
            dc.l    KEY8|DMX_CTRL_IRQ_M, SHEET+64, SCREEN+40*320+170, 32, 32, (256<<16)|320, 0, 0
```

The last job sets IRQ, so the channel interrupts when all three are drawn. CHDESC reads back the descriptor running, and the job registers the job being run.

---

## Starting Jobs from the Copper and from Timers

The copper writes the job registers and CHCTRL like any other registers, so it can set up and start a job at a beam position with a few MOVEs and no descriptor at all. Its WAIT with the **B** bit waits until every channel is idle, so a list can start a blit and later wait for it (Coprocessor Hardware chapter).

```asm
            ; in a copper list: fill a 64-pixel-wide bar on 16 rows, started at line 200
            CWAIT   VID_Y0+200,0
            CMOVEL  DMX2+DMX_CTRL,FILL8
            CMOVEL  DMX2+DMX_DST,BAR
            CMOVEL  DMX2+DMX_WIDTH,64
            CMOVEL  DMX2+DMX_HEIGHT,16
            CMOVEL  DMX2+DMX_STRIDE,320
            CMOVEL  DMX2+DMX_VALUE,$07070707
            CMOVEL  DMX2+DMX_NEXT,0
            CMOVE   DMX2+DMX_CHCTRL+2,RUNIT
```

A **timer** can start a channel when it runs out: set its CTRL.DMA bit and CTRL.DMACH to the channel (Interrupts and Timers chapter). This works like writing START to the channel's CHCTRL, so point CHDESC at the chain first. A timer repeating at a steady rate can, for example, refill a buffer at the right moment without the CPU.

A channel already busy ignores a START or RUN, whoever sends it.

---

## Registers, Palettes and the ROM

A job's source and destination can be any of these:

| Addresses | What | Read | Write |
|-----------|------|------|-------|
| `$000000`–`$3FFFFF` | Chip RAM (2 MB boards: to `$1FFFFF`) | Yes | Yes |
| `$E00000`–`$E0FFFF` | The custom registers, the palettes and the descriptor RAM | Yes | Yes |
| `$F80000`–`$F87FFF` | The boot ROM | Yes | No |

Anything else, including the system area at `$F00000` (interrupts, timers, serial, SD card), stops the channel with an error, so a runaway job cannot upset interrupts or the console.

The palettes and the descriptor RAM behave as memory: any job can use them. The **registers** are written as whole long words, exactly as a CPU MOVE.L writes them, so a job that touches them must keep these rules, or it stops with an error:

- COPY or FILL (only COPY reads registers), at 8 bpp, forwards;
- addresses, WIDTH and strides multiples of 4.

So a COPY of four long words from memory to `CUSTOM+L0+L_WINX` sets layer 0's window and scroll in one job, and a COPY of one long word into another channel's CHCTRL starts that channel: one chain can start others. A COPY from `CUSTOM+BEAMPOS` to memory, repeated by the copper, keeps a log of beam positions. Reading a register never changes it, so a DMA read is always safe.

```asm
        ; load 256 colours into PALETTE1 from a table in Chip RAM
        move.l  #COPY8,DMX_CTRL(a0)
        move.l  #COLOURS,DMX_SRC(a0)
        move.l  #CUSTOM+PALETTE1,DMX_DST(a0)
        move.l  #256*4,DMX_WIDTH(a0)
        move.l  #1,DMX_HEIGHT(a0)
        move.l  #RUNIT,DMX_CHCTRL(a0)
```

---

## Moving Data to and from the USB Serial Link

A job can read from or write to a **port** instead of memory: SRCKIND or DSTKIND = 1, with the port number in SRC or DST.

| Port | Device |
|------|--------|
| 0 | SD card (not built yet: an error) |
| 1 | The USB serial link: as a source, bytes received; as a destination, bytes to send |

A port job is a COPY of bytes: 8 bpp, one row, forwards, its memory side not registers. The engine waits for the link: when no byte has come, or there is no room to send, the channel lets the others have their turn and tries again. The serial port must be on (SERCON.EN).

```asm
        ; send a 2 KB block to the PC
        move.l  #COPY8|(1<<DMX_CTRL_DSTKIND_B),DMX_CTRL(a0)
        move.l  #BLOCK,DMX_SRC(a0)
        move.l  #1,DMX_DST(a0)                  ; port 1
        move.l  #2048,DMX_WIDTH(a0)
        move.l  #1,DMX_HEIGHT(a0)
        move.l  #RUNIT,DMX_CHCTRL(a0)

        ; receive 512 bytes from the PC into BUF
        move.l  #COPY8|(1<<DMX_CTRL_SRCKIND_B),DMX_CTRL(a0)
        move.l  #1,DMX_SRC(a0)
        move.l  #BUF,DMX_DST(a0)
        move.l  #512,DMX_WIDTH(a0)
        move.l  #RUNIT,DMX_CHCTRL(a0)
```

While a channel moves data through the link, the CPU should not read or write SERDATA itself.

---

## Status, Interrupts and Errors

**CHSTAT** shows each channel's state: **BUSY** while a chain runs (or is paused), **DONE** when a chain reaches its end or is stopped, **ERR** when a job stopped with an error, and **PAUSED** while held. DONE and ERR stay set until you write 1 to them.

**Interrupts.** Each channel is its own source in the interrupt controller, DMA0–DMA3 (sources 4–7, default level 4). A channel's bit in **DMXINT** (`$3F0`) is set when a job with CTRL.IRQ finishes, or when the channel stops with an error; it requests the interrupt while its bit in **DMXINTEN** (`$3F4`) is set too. Clear DMXINT by writing 1 to the bit.

```asm
dmx3_int:   move.l  #1<<3,DMXINT(a4)            ; channel 3's interrupt: clear it
            ; ... the chain is done, or check DMX3+DMX_CHSTAT for ERR
            rte
```

**STOP** (CHCTRL bit 2) ends a running chain after its current group of words; DONE is set. **PAUSE** (bit 3) holds a channel while set, and lets it carry on when cleared: write CHCTRL again with PAUSE clear (and no START or RUN).

**Errors** stop only the channel concerned: ERR is set, **CHERR** holds the address that caused it, CHDESC the descriptor, and the channel's DMXINT bit is set. The errors are: an address outside the areas above (or a write to the ROM), a register job breaking the register rules, OP 5–7, or a source and destination kind that do not go together (FILL from memory, KEYCOPY from a port, and so on).

---

## Priority and Speed

The engine uses memory cycles the display, sprites, audio and the copper do not need, and cycle 0 when the CPU is not using it, so **a normal job never slows the CPU**. Its four channels take turns, a group of up to 8 words each.

A job with **HIGH** (CTRL bit 11) may also take the CPU's own cycle 0, but leaves the CPU a share of them: 1 in 2, 1 in 4 (the default) or 1 in 8 of those it asks for, set by the channel's **CPUSHARE** (CHCTRL bits 5–4: 0, 1, 2). Each cycle taken makes the CPU wait one slot (100 ns). Use HIGH when the CPU would only be waiting for the job anyway.

How fast a job runs depends on the screen and on the CPU. Some figures for a 576p line (32 µs), worked out from the slot rules:

| Situation | Copy | Fill |
|-----------|------|------|
| CPU busy, one full-screen 8 bpp chunky layer | 33 MB/s | 67 MB/s |
| CPU busy, the layers using the whole display budget | 25 MB/s | 50 MB/s |
| CPU idle, one full-screen 8 bpp chunky layer | 38 MB/s | 77 MB/s |
| In the vertical blank, CPU busy | 45 MB/s | 90 MB/s |

LOGIC and ADD run at about two thirds of the copy speed. Jobs at 1, 2 or 4 bpp that are not byte-aligned read the destination at each row's edges. Clearing a full 720 × 576 8 bpp picture (405 KB) takes about 6–8 ms, well within a 50 Hz frame.

---

## Summary of DMA Engine Registers

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| CTRL | DMXn + `$00` | RW | OP (2–0), FN (7–4), BPP (9–8), DESC (10), HIGH (11), IRQ (12), SRCKIND (14–13), DSTKIND (16–15) |
| SRC | DMXn + `$04` | RW | Source address or port (23–0) |
| DST | DMXn + `$08` | RW | Destination address or port (23–0) |
| WIDTH | DMXn + `$0C` | RW | Pixels per row (23–0) |
| HEIGHT | DMXn + `$10` | RW | ROWS (15–0), SRCBIT (18–16), DSTBIT (22–20) |
| STRIDE | DMXn + `$14` | RW | SRCSTRIDE (31–16), DSTSTRIDE (15–0), signed |
| VALUE | DMXn + `$18` | RW | Fill value, key colour, constant source |
| NEXT | DMXn + `$1C` | RW | Next descriptor (23–0), 0 = none |
| CHDESC | DMXn + `$20` | RW | Descriptor START loads (23–0) |
| CHCTRL | DMXn + `$24` | RW | START (0), RUN (1), STOP (2), PAUSE (3), CPUSHARE (5–4) |
| CHSTAT | DMXn + `$28` | RW1C | BUSY (0), DONE (1), ERR (2), PAUSED (3) |
| CHERR | DMXn + `$2C` | R | Address of the error (23–0) |
| DMXINT | `$3F0` | W1C | CH (3–0): interrupt pending |
| DMXINTEN | `$3F4` | RW | CH (3–0): interrupt enables |
| DESCRAM | `$6000`–`$67FF` | RW | The descriptor RAM, 2 KB |

DMXn = `$300` + n × `$40`: DMX0 `$300`, DMX1 `$340`, DMX2 `$380`, DMX3 `$3C0`. The job registers ignore writes while their channel is BUSY.

Related bits elsewhere:

| Register | Bit | Function |
|----------|-----|----------|
| DMACON | BLTEN (6), DMAEN (9) | The engine may use memory cycles |
| INTENA | DMA0–DMA3 (sources 4–7) | The channels' interrupts |
| TMRn CTRL | DMA (5), DMACH (7–6) | A timer starts a channel when it runs out |

Constants in `hw.inc`: `DMX0`–`DMX3`, `DMX_CTRL` … `DMX_CHERR` (add to DMXn), the CTRL fields (`DMX_CTRL_OP_B`, `DMX_CTRL_FN_B`, `DMX_CTRL_BPP_B`, `DMX_CTRL_DESC_M`, `DMX_CTRL_HIGH_M`, `DMX_CTRL_IRQ_M`, `DMX_CTRL_SRCKIND_B`, `DMX_CTRL_DSTKIND_B`), `DMX_CHCTRL_START_M` and the other CHCTRL and CHSTAT bits, `DMX_OP_COPY` … `DMX_OP_ADD`, `DMX_KIND_MEM` … `DMX_KIND_VALUE`, `DMXINT`, `DMXINTEN`, `DESCRAM`, and the descriptor layout `DMXDESC_CTRL` … `DMXDESC_NEXT`.
