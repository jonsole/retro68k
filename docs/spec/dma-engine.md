# Spec 11: DMA engine and blitter

Status: **draft for review**

One engine moves data for the CPU: copying and filling memory, feeding peripherals, and drawing graphics (the blitter). The CPU describes jobs in memory, starts a channel, and carries on with other work while the engine runs them.

## 1. Summary

| Item | Value |
|------|-------|
| Channels | 4, running at the same time and taking turns burst by burst |
| Programming | Chains of 32-byte **descriptors** (job descriptions) in Chip RAM or in a small descriptor RAM inside the FPGA |
| Jobs | Copy, fill, transparent copy (colour key), logic operations, in 1D (linear) or 2D (rectangles with a stride) |
| Pixel formats | Bytes, or 1, 2, 4 or 8 bits per pixel, positioned to the pixel |
| Sources and destinations | Chip RAM, the FPGA's block RAM areas (palette, sprite table, text screen, font, ROM), or a peripheral port (SD card, USB) |
| Memory slots | Normally only spare ones, so the CPU is never slowed. A **HIGH** bit per job lets it take CPU slots, like the Amiga's "blitter nasty" |
| Speed at 640×480 | Copy 10–34 MB/s, fill 16–56 MB/s, depending on how busy the CPU is (section 6). A 68000 at 20 MHz copies about 4.5 MB/s |
| Finishing | Interrupt per descriptor if asked, status flags per channel |

## 2. Comparison with the Amiga

| Feature | Amiga blitter | retro68k DMA engine |
|---------|---------------|---------------------|
| Jobs at once | 1 | 4 channels |
| Starting jobs | CPU or copper writes registers, then waits for the blitter to finish before the next job | CPU or copper starts a chain of jobs; the engine works through it alone |
| Pixel layout | Bitplanes: one blit per plane, with shifts and masks | Chunky pixels: one blit for all colour depths |
| Masked (cookie-cut) drawing | Uses a separate mask plane and the minterm logic | Colour-key copy: source pixels of the key colour are skipped. No mask needed |
| Logic | Any function of 3 sources (minterms) | Any function of source and destination (4-bit truth table) |
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
| 2–0 | OP | 0 COPY, 1 FILL, 2 KEYCOPY, 3 LOGIC |
| 7–4 | FN | Truth table for LOGIC: result bit = FN[src × 2 + dst]. For example `0x8` = AND, `0xE` = OR, `0x6` = XOR, `0x5` = NOT destination |
| 9–8 | BPP | 0 = 1, 1 = 2, 2 = 4, 3 = 8 bits per pixel |
| 10 | DESC | Run backwards (last byte first), for overlapping copies |
| 11 | HIGH | May take CPU slots (section 5) |
| 12 | IRQ | Raise the channel's interrupt when this descriptor finishes |
| 14–13 | SRCKIND | 0 = memory, 1 = port, 2 = none (FILL) |
| 16–15 | DSTKIND | 0 = memory, 1 = port |

**Operations:**

| OP | Does | Reads the destination? |
|----|------|------------------------|
| COPY | dst = src | Only for partial bytes at 1, 2 or 4bpp |
| FILL | dst = VALUE, repeated | Same |
| KEYCOPY | dst = src, except where the source pixel equals the key colour, which is left alone | At 8bpp no: byte write masks skip key pixels. At 1, 2 and 4bpp yes |
| LOGIC | dst = FN(src, dst), bit by bit | Yes |

**Linear jobs** (memcpy, memset, port transfers): BPP = 8, HEIGHT = 1, WIDTH = length in bytes (up to 16 MB).

**2D jobs** (blits): WIDTH × HEIGHT pixels, with each row starting STRIDE bytes after the last. Source and destination can have different strides, so an image can be copied out of a sprite sheet into a screen.

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

## 6. Speed

At 640×480, wide fetch off (65 free odd slots and 160 even slots per line):

| Situation | Copy | Fill | Chip RAM → block RAM |
|-----------|------|------|----------------------|
| CPU busy in Chip RAM, normal job (free odd slots only) | 9.8 MB/s | 16 MB/s | 24 MB/s |
| CPU busy, HIGH job (+ 3 of every 4 even slots) | 28 MB/s | 46 MB/s | 69 MB/s |
| CPU idle, waiting or running from ROM/block RAM (all spare slots) | 34 MB/s | 56 MB/s | 84 MB/s |

For comparison, a 68000 at 20 MHz copies about 4–4.5 MB/s (`MOVE.L (A0)+,(A1)+` or `MOVEM.L`). Clearing a 640×480 8bpp screen (300 KB) takes about 5–19 ms with the engine. That fits in one 60 Hz frame (16.7 ms) unless the CPU is busy in Chip RAM and the job is not HIGH.

With wide fetch on, the free odd slots in the visible area go to video, so normal jobs mostly run during blanking and in the CPU's unused slots.

## 7. Channels and registers

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

## 8. Suggested channel use

Software decides, but a sensible default:

| Channel | Use |
|---------|-----|
| 0 | SD card |
| 1 | USB |
| 2 | General memory copies and fills |
| 3 | Graphics (blits) |

## 9. FPGA resources

| Item | Resource |
|------|----------|
| Descriptor RAM, 2 KB | 1 block RAM |
| Data buffer between reads and writes (64 bytes) | Logic |
| 4 channel state machines, 2D address units, pixel shifter, colour key compare, logic function | Estimate 1,200–2,000 LUTs; to confirm by synthesis |

## 10. Open points

| # | Item |
|---|------|
| D1 | Check the engine fits and meets timing at 100 MHz |
| D2 | Should HIGH leave the CPU 1 in 4 even slots, or be adjustable (1 in 2, 1 in 8)? |
| D3 | Line drawing and area fill (Amiga blitter features), and scaling or rotating blits: version 2 |
| D4 | Writes to custom registers from a descriptor (a "mini copper"): left out of version 1 for safety |
| D5 | Should audio also be able to stream through a port (e.g. for long samples from SD card)? |

## 11. Tests

- **Copy and fill:** linear and 2D, every BPP, starting and ending part-way through a byte, positive and negative strides, forwards and backwards (DESC) with overlapping areas. Compare with a Python reference model.
- **KEYCOPY and LOGIC:** every BPP, with key pixels at the edges.
- **Chains:** a chain of mixed jobs in Chip RAM and in descriptor RAM; IRQ only on the marked ones.
- **Channels:** all 4 running at once; a stalled port channel does not hold up the others.
- **Priority:** normal jobs never delay the CPU; HIGH jobs leave the CPU at least 1 in 4 even slots, and every CPU delay is 2 clocks.
- **Errors:** a bad address stops only that channel, sets ERR and CHERR, and raises its interrupt.
- **Speed:** measure the figures in section 6 in simulation.
