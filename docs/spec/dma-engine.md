# Spec 11: DMA engine and blitter

Status: **draft for review**

One engine moves data for the CPU: copying and filling memory, feeding peripherals, and drawing graphics (the blitter). The CPU describes jobs in memory, starts a channel, and carries on with other work while the engine runs them.

## 1. Summary

| Item | Value |
|------|-------|
| Channels | 4, running at the same time and taking turns burst by burst |
| Programming | Chains of 32-byte **descriptors** (job descriptions) in Chip RAM or in a small descriptor RAM inside the FPGA |
| Jobs | Copy, fill, transparent copy (colour key), logic operations and add, in 1D (linear) or 2D (rectangles with a stride); MIX for audio voices |
| Pixel formats | Bytes, or 1, 2, 4 or 8 bits per pixel, positioned to the pixel |
| Sources and destinations | Chip RAM, the FPGA's block RAM areas (palette, sprite table, text screen, font, ROM), or a peripheral port (SD card, USB) |
| Memory slots | Normally only spare ones, so the CPU is never slowed. A **HIGH** bit per job lets it take CPU slots, like the Amiga's "blitter nasty" |
| Speed at 640×480 | Copy 10–34 MB/s, fill 16–56 MB/s, depending on how busy the CPU is (section 7). A 68000 at 20 MHz copies about 4.5 MB/s |
| Finishing | Interrupt per descriptor if asked, status flags per channel |

## 2. Comparison with the Amiga

| Feature | Amiga blitter | retro68k DMA engine |
|---------|---------------|---------------------|
| Jobs at once | 1 | 4 channels |
| Starting jobs | CPU or copper writes registers, then waits for the blitter to finish before the next job | CPU or copper starts a chain of jobs; the engine works through it alone |
| Pixel layout | Bitplanes: one blit per plane, with shifts and masks | Chunky pixels: one blit for all colour depths |
| Masked (cookie-cut) drawing | Uses a separate mask plane and the minterm logic | Colour-key copy: source pixels of the key colour are skipped. No mask needed |
| Logic | Any function of 3 sources (minterms) | Any function of source and destination (4-bit truth table) |
| Arithmetic | None | ADD per pixel, wrapping or saturating, signed or unsigned |
| Audio mixing | None (done by the CPU in software) | MIX: one audio voice per job, with pitch, stereo volume and looping |
| Peripherals | Separate disk DMA | The same engine, through peripheral ports |
| Priority | BLTPRI ("blitter nasty") for all blits | HIGH bit per job |
| Line drawing, area fill | Yes | Not in version 1 (open point D3) |

## 3. Descriptors

A job is a 32-byte descriptor. Each one can point to the next, so a chain of jobs runs without the CPU.

| Offset | Name | Bits | Meaning |
|--------|------|------|---------|
| `+0x00` | CTRL | see below | Operation and options |
| `+0x04` | SRC | 24–0 | Source byte address, or port number |
| `+0x08` | DST | 24–0 | Destination byte address, or port number |
| `+0x0C` | WIDTH | 23–0 | Pixels per row (bytes when BPP = 8) |
| `+0x10` | HEIGHT | HEIGHT 15–0, SRCBIT 18–16, DSTBIT 22–20 | Rows (1 for a linear job). SRCBIT/DSTBIT: starting pixel within the first byte, for 1, 2 and 4bpp |
| `+0x14` | STRIDE | SRCSTRIDE 31–16, DSTSTRIDE 15–0 (signed) | Bytes from one row to the next |
| `+0x18` | VALUE | 31–0 | Fill pattern (repeated), or the colour key for KEYCOPY |
| `+0x1C` | NEXT | 24–0 | Address of the next descriptor; 0 = end of chain |

**CTRL bits:**

| Bits | Name | Meaning |
|------|------|---------|
| 2–0 | OP | 0 COPY, 1 FILL, 2 KEYCOPY, 3 LOGIC, 4 ADD, 5 MIX (section 3.1, own descriptor layout) |
| 7–4 | FN | LOGIC: truth table, result bit = FN[src × 2 + dst]. For example `0x8` = AND, `0xE` = OR, `0x6` = XOR, `0x5` = NOT destination. ADD: bit 4 = saturate, bit 5 = signed (see below) |
| 9–8 | BPP | 0 = 1, 1 = 2, 2 = 4, 3 = 8 bits per pixel |
| 10 | DESC | Run backwards (last byte first), for overlapping copies |
| 11 | HIGH | May take CPU slots (section 5) |
| 12 | IRQ | Raise the channel's interrupt when this descriptor finishes |
| 14–13 | SRCKIND | 0 = memory, 1 = port, 2 = none (FILL), 3 = VALUE (ADD a constant) |
| 16–15 | DSTKIND | 0 = memory, 1 = port |

**Operations:**

| OP | Does | Reads the destination? |
|----|------|------------------------|
| COPY | dst = src | Only for partial bytes at 1, 2 or 4bpp |
| FILL | dst = VALUE, repeated | Same |
| KEYCOPY | dst = src, except where the source pixel equals the key colour, which is left alone | At 8bpp no: byte write masks skip key pixels. At 1, 2 and 4bpp yes |
| LOGIC | dst = FN(src, dst), bit by bit | Yes |
| ADD | dst = dst + src, pixel by pixel | Yes |

**ADD:**

- Each pixel is added separately, at the job's colour depth (1, 2, 4 or 8 bits). Carries never spill into the next pixel.
- **Wrap** (FN bit 4 = 0): the result wraps round, e.g. 250 + 10 = 4 at 8bpp.
- **Saturate** (FN bit 4 = 1): the result sticks at the limit instead. Unsigned (FN bit 5 = 0): 0 to the top value, e.g. 250 + 10 = 255. Signed (FN bit 5 = 1): pixels are two's complement, e.g. −128 to +127 at 8bpp.
- The source can be memory, a port, or a constant (SRCKIND = 3, taking the pixel value from the low bits of VALUE, repeated).
- Uses:
  - Shading and lighting with palettes laid out as ramps: add a constant to darken or brighten an area, or add a light map image.
  - Moving an area to another palette block by adding 16, 32 and so on.
  - Additive effects such as glows and explosions.
  - Mixing 8-bit signed audio samples with signed saturation (linear job, BPP = 8).
- To subtract, add the two's complement, e.g. add 0xFF to subtract 1 at 8bpp with wrap.

**Linear jobs** (memcpy, memset, port transfers): BPP = 8, HEIGHT = 1, WIDTH = length in bytes (up to 16 MB).

**2D jobs** (blits): WIDTH × HEIGHT pixels, with each row starting STRIDE bytes after the last. Source and destination can have different strides, so an image can be copied out of a sprite sheet into a screen.

### 3.1 MIX: one audio voice

MIX adds one voice into a 16-bit stereo audio buffer, for the audio stream (spec 6, section 6). It uses its own 32-byte layout:

| Offset | Name | Bits | Meaning |
|--------|------|------|---------|
| `+0x00` | CTRL | OP 2–0 (= 5), LOOP (4), OVER (5), MONO (6), ENDED (7), BITS16 (8), HIGH (11), IRQ (12), COUNT 31–20 | See below |
| `+0x04` | POS | 24–0 | Current byte address in the voice's sample. **Written back** at the end of the job |
| `+0x08` | DST | 24–0 | Buffer to mix into (16-bit, left then right, 4-byte aligned) |
| `+0x0C` | END | 24–0 | End of the sample (first byte after it) |
| `+0x10` | LOOP | 24–0 | Where to continue when END is reached, if LOOP is set |
| `+0x14` | STEP | 23–0 | Pitch: source samples per output frame, 8.16 fixed point |
| `+0x18` | VOL / FRAC | VOLL 31–24, VOLR 23–16, FRAC 15–0 | Volumes 0–255; FRAC is the fractional part of the position, **written back** |
| `+0x1C` | NEXT | 24–0 | Next descriptor |

**CTRL bits for MIX:**

| Bits | Name | Meaning |
|------|------|---------|
| 4 | LOOP | At END, continue from LOOP; otherwise the voice stops |
| 5 | OVER | Write instead of add (the first voice of a block, so the buffer needn't be cleared) |
| 6 | MONO | The buffer is mono 16-bit; VOLL is used |
| 7 | ENDED | Set by the engine when a non-looping voice reaches END. While set, the job adds nothing (or writes silence if OVER is set) and finishes at once |
| 8 | BITS16 | Samples are 16-bit signed; otherwise 8-bit signed |
| 31–20 | COUNT | Output frames to mix (1–4095) |

**For each output frame:**

1. Read the sample at POS (8-bit samples are scaled up to 16 bits).
2. `left += sample × VOLL ÷ 256`, `right += sample × VOLR ÷ 256`, saturating at the 16-bit limits (or write instead of add, with OVER).
3. Add STEP to POS.FRAC. When POS reaches END, go to LOOP (keeping the overshoot) or set ENDED.

At the end of the job, POS, FRAC and ENDED are written back to the descriptor, so the same descriptor carries on smoothly in the next block. To start a new note, software writes POS, FRAC = 0, END, LOOP, STEP and the volumes, and clears ENDED.

**Cost:** about 1 memory slot per stereo frame at normal pitch (sample read, buffer read, buffer write), a little more at higher pitches. The multiplies use 2 DSP slices.

## 4. Where data can come from and go to

| Kind | Addresses | Uses SDRAM slots? |
|------|-----------|-------------------|
| Chip RAM | `0x000000`–`0x1FFFFFF` (the full 32 MB, as for all DMA) | Yes |
| Block RAM areas | Palette, sprite table, descriptor RAM, text screen, font (destination or source); boot ROM (source only) | **No**: these are inside the FPGA, so a job such as "load a new palette from Chip RAM" only uses slots for its reads |
| Port 0 | SD card data FIFO | No; paced by the card |
| Port 1 | USB FIFO (FT2232H channel B) | No; paced by the USB chip |
| Ports 2–7 | Reserved | |

Block RAM areas sit at their CPU addresses (`0xE04000` palette, `0xE05000` sprite table, `0xE06000` descriptor RAM, `0xE10000` text and font, `0xF80000` ROM). DMA addresses in Chip RAM are 25-bit byte addresses as in spec 5. Any other address stops the channel with an error.

**Ports** are paced by the peripheral: when the port isn't ready, that channel waits and the other channels keep running. Port addresses don't increment.

## 5. Memory slots and priority

The engine replaces "blitter" and "storage" in the slot lists of spec 5.

- **Reads** move up to 12 bytes per slot, **writes** up to 8 bytes (spec 5, section 4.2). A copy of 24 bytes takes 2 read slots and 3 write slots.
- **Normal jobs** use:
  - free odd slots, after the CPU, sprites and the copper,
  - even slots the CPU is not using.
  The CPU is never slowed.
- **HIGH jobs** may also take the CPU's even slots, but always leave the CPU **1 even slot in every 4**, so it can still run interrupts and code from Chip RAM, slowly. Each slot taken costs the CPU 2 clocks, as for sprites. Use HIGH when the CPU would only be waiting for the job anyway.
- **Peripheral transfers** also get the **2 fixed odd slots per line** that spec 5 reserved for storage, so SD and USB always get at least 24 bytes per line (about 750 KB/s at 640×480), however busy the screen is.
- **Between channels:** ready channels take turns, one burst each.
- **Descriptors** in Chip RAM take 3 read slots each to load. Descriptors in the descriptor RAM take none, which suits short, frequent jobs.

## 6. How a blit works

Each burst goes through the same four steps:

1. **Read:** a burst of up to 12 bytes from the source into the engine's 64-byte buffer. Jobs that read the destination (LOGIC, ADD, and edge bytes at 1, 2 or 4bpp) also read the matching destination burst.
2. **Shift** (1, 2 and 4bpp only): when the source and destination start at different pixels within a byte (SRCBIT ≠ DSTBIT), the data is shifted by the difference. Bits carry from one word into the next, as in the Amiga's barrel shifter. At 8bpp there is never any shifting, because every pixel starts on a byte.
3. **Combine:** key compare (KEYCOPY), logic function (LOGIC) or per-pixel add (ADD).
4. **Write:** up to 8 bytes, using the SDRAM's byte write masks to leave untouched bytes alone.

**Edge masks are automatic.** The engine works out which pixels of the first and last bytes in each row belong to the job from DSTBIT and WIDTH. There are no mask registers to set, unlike the Amiga's first-word and last-word masks.

**Read-modify-write:** the SDRAM can only skip whole bytes when writing. When a write would change only some pixels in a byte, the engine reads the destination, merges, and writes it back. This happens:

- at the row edges of 1, 2 and 4bpp jobs that don't start or end on a byte,
- for every byte of KEYCOPY at 1, 2 and 4bpp (two or more pixels share a byte),
- always for LOGIC and ADD.

At 8bpp, COPY, FILL and KEYCOPY never need it: a skipped key pixel is simply a byte not written. **8bpp is the fastest format for game graphics.**

## 7. Speed

At 640×480, wide fetch off (65 free odd slots and 160 even slots per line):

| Situation | Copy | Fill | Chip RAM → block RAM |
|-----------|------|------|----------------------|
| CPU busy in Chip RAM, normal job (free odd slots only) | 9.8 MB/s | 16 MB/s | 24 MB/s |
| CPU busy, HIGH job (+ 3 of every 4 even slots) | 28 MB/s | 46 MB/s | 69 MB/s |
| CPU idle, waiting or running from ROM/block RAM (all spare slots) | 34 MB/s | 56 MB/s | 84 MB/s |

Jobs that read the destination are slower: LOGIC and ADD at 8bpp need 7 slots per 24 bytes instead of 5, so they run at about 70% of the copy speed.

For comparison, a 68000 at 20 MHz copies about 4–4.5 MB/s (`MOVE.L (A0)+,(A1)+` or `MOVEM.L`). Clearing a 640×480 8bpp screen (300 KB) takes about 5–19 ms with the engine. That fits in one 60 Hz frame (16.7 ms) unless the CPU is busy in Chip RAM and the job is not HIGH.

With wide fetch on, the free odd slots in the visible area go to video, so normal jobs mostly run during blanking and in the CPU's unused slots.

## 8. Channels and registers

Offsets in the custom register block at `0xE00000`. Spec 3 sets the final addresses.

**Per channel** (channel n at `0x300 + n × 0x10`):

| Offset | Name | Bits | Meaning |
|--------|------|------|---------|
| `+0x0` | CHDESC | 24–0 | Write: first descriptor of a chain. Read: the descriptor now running |
| `+0x4` | CHCTRL | START (0), STOP (1), PAUSE (2) | START begins the chain at CHDESC. STOP ends it after the current burst. PAUSE holds it |
| `+0x8` | CHSTAT | BUSY (0), DONE (1), ERR (2), PAUSED (3) | DONE and ERR are sticky, write 1 to clear |
| `+0xC` | CHERR | 24–0 | Address that caused an error |

**Global:**

| Offset | Name | Bits | Meaning |
|--------|------|------|---------|
| `0x340` | DMXINT | 3–0 | Channel interrupt pending (descriptor with IRQ finished, or error); write 1 to clear |
| `0x344` | DMXINTEN | 3–0 | Interrupt enables per channel |

**Descriptor RAM:** 2 KB at `0xE06000`–`0xE067FF`, room for 64 descriptors. One block RAM.

**DMACON** (spec 5, section 8): bit 6 becomes **DMXEN** (DMA engine), and bit 4 (STOEN) is no longer needed, because storage transfers go through the engine.

**Interrupts:** the DMA engine shares interrupt level 4 with audio (design plan D8). Interrupts are vectored, so each has its own handler.

**Typical use:**
1. Write descriptors to the descriptor RAM or Chip RAM.
2. Write the first descriptor's address to CHDESC, then START to CHCTRL.
3. Carry on. Take the interrupt, or poll CHSTAT.BUSY.

The copper can also start channels, for example to change a screen area at a set beam position.

## 9. Suggested channel use

Software decides, but a sensible default:

| Channel | Use |
|---------|-----|
| 0 | SD card |
| 1 | USB |
| 2 | General memory copies and fills |
| 3 | Graphics (blits) |

## 10. FPGA resources

| Item | Resource |
|------|----------|
| Descriptor RAM, 2 KB | 1 block RAM |
| Data buffer between reads and writes (64 bytes) | Logic |
| 4 channel state machines, 2D address units, pixel shifter, colour key compare, logic function, per-pixel adder, MIX unit | Estimate 1,500–2,400 LUTs and 2 DSP slices; to confirm by synthesis |

## 11. Open points

| # | Item |
|---|------|
| D1 | Check the engine fits and meets timing at 100 MHz |
| D2 | Should HIGH leave the CPU 1 in 4 even slots, or be adjustable (1 in 2, 1 in 8)? |
| D3 | Line drawing and area fill (Amiga blitter features), and scaling or rotating blits: version 2 |
| D4 | Writes to custom registers from a descriptor (a "mini copper"): left out of version 1 for safety |

## 12. Tests

- **Copy and fill:** linear and 2D, every BPP, starting and ending part-way through a byte, positive and negative strides, forwards and backwards (DESC) with overlapping areas. Compare with a Python reference model.
- **KEYCOPY and LOGIC:** every BPP, with key pixels at the edges.
- **ADD:** every BPP, wrap and saturate, signed and unsigned, memory and constant sources; check carries never cross pixels.
- **MIX:** 8- and 16-bit voices, looping and one-shot, OVER and MONO, pitches from 1/16× to 4×; positions written back and continuing exactly across blocks; compare with a Python reference mixer.
- **Chains:** a chain of mixed jobs in Chip RAM and in descriptor RAM; IRQ only on the marked ones.
- **Channels:** all 4 running at once; a stalled port channel does not hold up the others.
- **Priority:** normal jobs never delay the CPU; HIGH jobs leave the CPU at least 1 in 4 even slots, and every CPU delay is 2 clocks.
- **Errors:** a bad address stops only that channel, sets ERR and CHERR, and raises its interrupt.
- **Speed:** measure the figures in section 7 in simulation.
