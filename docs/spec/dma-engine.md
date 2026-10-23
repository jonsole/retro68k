# Spec 11: DMA engine and blitter

Status: **version 1, for review**

One engine moves data for the CPU: copying and filling memory, feeding peripherals, writing hardware registers, and drawing graphics (the blitter). The CPU describes jobs in memory, starts a channel, and carries on with other work while the engine runs them.

## 1. Summary

| Item | Value |
|------|-------|
| Channels | 4, running at the same time and taking turns, a group of memory cycles each |
| Programming | Chains of 32-byte **descriptors** (job descriptions) in Chip RAM or in a 2 KB descriptor RAM inside the FPGA |
| Jobs | COPY, FILL, KEYCOPY (transparent copy with a colour key), LOGIC (any function of source and destination), ADD (per pixel); in 1D (linear) or 2D (rectangles with a stride). MIX (audio voices) is on hold |
| Pixel formats | 1, 2, 4 or 8 bits per pixel, positioned to the pixel: chunky layers directly, planar layers one plane at a time (section 6.1) |
| Sources and destinations | Chip RAM, the custom registers and palettes, the descriptor RAM, the boot ROM (read only), or a peripheral port (USB serial; the SD card later) |
| Memory cycles | Normally only free ones, so the CPU is never slowed. A **HIGH** bit per job lets it take some of the CPU's cycles, like the Amiga's "blitter nasty" |
| Speed at 576p | Copy about 25–38 MB/s, fill 50–77 MB/s, depending on the screen and how busy the CPU is (section 7). A 68000 at 20 MHz copies about 4 MB/s |
| Finishing | An interrupt per descriptor if asked, status flags per channel |

## 2. Comparison with the Amiga

| Feature | Amiga blitter | retro68k DMA engine |
|---------|---------------|---------------------|
| Jobs at once | 1 | 4 channels |
| Starting jobs | CPU or copper writes registers, then waits for the blitter to finish before the next job | CPU or copper starts a chain of jobs; the engine works through it alone |
| Pixel layout | Bitplanes: one blit per plane, with shifts and masks | Chunky pixels at any depth: one blit for all colour depths. Planar layers: one blit per plane, as on the Amiga (section 6.1) |
| Masked (cookie-cut) drawing | Uses a separate mask plane and the minterm logic | Chunky: colour-key copy, no mask needed. Planar: a mask and two LOGIC jobs per plane |
| Logic | Any function of 3 sources (minterms) | Any function of source and destination (4-bit truth table) |
| Arithmetic | None | ADD per pixel, wrapping or saturating, signed or unsigned |
| Edge masks | First-word and last-word mask registers | Automatic, from the starting pixel and the width |
| Register writes | Copper only | Copper, and DMA jobs: block copies and fills into registers |
| Peripherals | Separate disk DMA | The same engine, through peripheral ports |
| Priority | BLTPRI ("blitter nasty") for all blits | HIGH bit per job |
| Line drawing, area fill | Yes | Not in version 1 (open point D3) |

## 3. Descriptors

A job is a 32-byte descriptor, long-word aligned. Each one can point to the next, so a chain of jobs runs without the CPU.

| Offset | Name | Bits | Meaning |
|--------|------|------|---------|
| `+0x00` | CTRL | see below | Operation and options |
| `+0x04` | SRC | 23–0 | Source address (section 4) of the first pixel, or port number |
| `+0x08` | DST | 23–0 | Destination address (section 4) of the first pixel, or port number |
| `+0x0C` | WIDTH | 23–0 | Pixels per row (bytes when BPP = 8) |
| `+0x10` | HEIGHT | HEIGHT 15–0, SRCBIT 18–16, DSTBIT 22–20 | Rows (1 for a linear job). SRCBIT and DSTBIT: the first pixel's position within its byte, counted in pixels from the most significant end, at 1, 2 and 4 bpp (0–7, 0–3, 0–1); 0 at 8 bpp |
| `+0x14` | STRIDE | SRCSTRIDE 31–16, DSTSTRIDE 15–0, both signed | Bytes from the start of one row to the start of the next |
| `+0x18` | VALUE | 31–0 | FILL's value, KEYCOPY's key colour, or the constant source for LOGIC and ADD |
| `+0x1C` | NEXT | 23–0 | Address of the next descriptor; 0 = end of chain |

A WIDTH or HEIGHT of 0 makes the job do nothing; the chain carries on with NEXT.

**CTRL bits:**

| Bits | Name | Meaning |
|------|------|---------|
| 2–0 | OP | 0 COPY, 1 FILL, 2 KEYCOPY, 3 LOGIC, 4 ADD, 5 MIX (on hold: an error in version 1), 6 and 7 reserved (an error) |
| 7–4 | FN | LOGIC: truth table, result bit = FN[src × 2 + dst]. For example `0x8` = AND, `0xE` = OR, `0x6` = XOR, `0x5` = NOT destination, `0x2` = destination AND NOT source. ADD: bit 4 = saturate, bit 5 = signed |
| 9–8 | BPP | 0 = 1, 1 = 2, 2 = 4, 3 = 8 bits per pixel |
| 10 | DESC | Run backwards: from the last pixel of the last row to the first pixel of the first row, for overlapping copies where the destination is after the source. SRC and DST still give the first pixel |
| 11 | HIGH | May take the CPU's memory cycles (section 5) |
| 12 | IRQ | Raise the channel's interrupt when this descriptor finishes |
| 14–13 | SRCKIND | 0 = memory, 1 = port, 2 = none (FILL), 3 = VALUE (LOGIC and ADD with a constant) |
| 16–15 | DSTKIND | 0 = memory, 1 = port |

**Operations:**

| OP | Does | Reads the destination? |
|----|------|------------------------|
| COPY | dst = src | Only for bytes the job covers in part, at 1, 2 or 4 bpp |
| FILL | dst = VALUE | Same |
| KEYCOPY | dst = src, except where the source pixel equals the key colour (VALUE's low BPP bits), which is left alone | At 8 bpp no: a key pixel is a byte not written. At 1, 2 and 4 bpp yes |
| LOGIC | dst = FN(src, dst), bit by bit | Yes |
| ADD | dst = dst + src, pixel by pixel | Yes |

**FILL's value:** at 8 bpp the fill repeats all four bytes of VALUE, by address: the byte at address a gets VALUE's byte a mod 4, most significant first. So a fill that starts on a long word writes VALUE exactly (into memory or registers), and a fill of single bytes repeats VALUE's low byte if all four bytes are the same. At 1, 2 and 4 bpp every pixel gets VALUE's low BPP bits. SRCKIND = 3 (VALUE as a source, for LOGIC and ADD) gives every source pixel the same value, in the same way.

**ADD:**

- Each pixel is added separately, at the job's colour depth (1, 2, 4 or 8 bits). Carries never spill into the next pixel.
- **Wrap** (FN bit 4 = 0): the result wraps round, e.g. 250 + 10 = 4 at 8 bpp.
- **Saturate** (FN bit 4 = 1): the result sticks at the limit instead. Unsigned (FN bit 5 = 0): 0 to the top value, e.g. 250 + 10 = 255. Signed (FN bit 5 = 1): pixels are two's complement, e.g. −128 to +127 at 8 bpp.
- The source can be memory, a port, or a constant (SRCKIND = 3).
- Uses:
  - Shading and lighting with palettes laid out as ramps: add a constant to darken or brighten an area, or add a light map image.
  - Moving an area to another palette block by adding 16, 32 and so on.
  - Additive effects such as glows and explosions.
  - Mixing 8-bit signed audio samples with signed saturation (linear job, BPP = 8).
- To subtract, add the two's complement, e.g. add 0xFF to subtract 1 at 8 bpp with wrap.

**Linear jobs** (memcpy, memset, port transfers): BPP = 8, HEIGHT = 1, WIDTH = length in bytes (up to 16 MB, more than the whole of Chip RAM).

**2D jobs** (blits): WIDTH × HEIGHT pixels, with each row starting STRIDE bytes after the last. Source and destination have their own strides, so an image can be copied out of a sprite sheet into a screen. A stride of 0 repeats the same row; a negative stride runs up the screen (an image drawn upside down).

**Clipping is done by software, with no extra hardware.** To draw only part of an image (for example an object partly off the screen), trim the job before starting it, keeping both strides the same:

- **Left edge:** skip k pixels: move SRC and DST on by k pixels (bytes, plus SRCBIT/DSTBIT at 1, 2 and 4 bpp), and subtract k from WIDTH.
- **Right edge:** subtract the pixels past the edge from WIDTH.
- **Top edge:** skip r rows: add r × SRCSTRIDE to SRC and r × DSTSTRIDE to DST, and subtract r from HEIGHT.
- **Bottom edge:** subtract the rows past the edge from HEIGHT.
- If WIDTH or HEIGHT reaches 0, the object is fully off the screen: the job does nothing.

Because the stride is separate from the width, the trimmed rows still line up with the image and the screen.

**Which kinds go together:**

| OP | SRCKIND | DSTKIND |
|----|---------|---------|
| COPY | memory or port | memory or port (not both ports) |
| FILL | none | memory |
| KEYCOPY | memory | memory |
| LOGIC, ADD | memory, port or VALUE | memory |

A port job is linear: BPP = 8, HEIGHT = 1, no DESC. Any other combination stops the channel with an error.

### 3.1 MIX: one audio voice

> **On hold.** Stepping through a sample and taking the nearest value sounds poor when mixing at a fixed rate (a metallic buzz when pitched down, off-key aliasing when pitched up). MIX needs proper resampling, for example 8-tap windowed-sinc interpolation with pre-filtered octave copies, before it is worth building; and the audio unit (spec 6) now plays four channels with interpolation by itself. OP 5 stops the channel with an error in version 1. The previous design is kept in the history of this file.

## 4. Where data can come from and go to

**DMA addresses are CPU addresses** (24-bit). A job sees memory as the CPU does:

| Address | Area | Read | Write | Uses Chip RAM cycles? |
|---------|------|------|-------|-----------------------|
| `0x000000`–`0x3FFFFF` | **Chip RAM** (4 MB; 2 MB boards: `0x000000`–`0x1FFFFF`) | Yes | Yes | Yes |
| `0xE00000`–`0xE0FFFF` | Custom registers (video, sprites, audio, DMA engine, copper), the palettes at `0xE04000` and the descriptor RAM at `0xE06000` | Yes | Yes | No |
| `0xF80000`–`0xF87FFF` | Boot ROM | Yes | No | No |

Anything else, including Chip RAM past the end on a 2 MB board and the system area at `0xF00000` (interrupt controller, timers, serial, SD card), stops the channel with an error. The system area is left out so a runaway job cannot disturb interrupts or the serial console; its devices are reached through ports instead.

**Rules for registers** (the custom block outside the palettes and the descriptor RAM):

- Register accesses are 32-bit, so the addresses, the lengths in bytes and the strides must be multiples of 4, at BPP = 8 with no DESC. Anything else is an error.
- Only COPY and FILL may write registers. A COPY from memory into a block of registers sets up a whole layer, or several, in one job; a COPY of one long word into another channel's CHCTRL starts that channel, just as a CPU write does, so one chain can start others. COPY can also read registers into memory, for example to save a screen setup or keep a log of beam positions.
- Reading a register never changes anything, by design, so a DMA read is always safe. Sticky flags are cleared only by writing 1.
- A DMA register write has exactly the same effect as a CPU write to the same register, including its timing rules (for example, layer settings for line n must be written before line n starts, spec 4, section 5.4).
- Register, palette, descriptor RAM and ROM accesses take one 100 MHz clock each on the FPGA's internal register bus. The CPU goes first, then the copper, then the engine: a job waits a clock when either is using the bus.

The palettes and the descriptor RAM are memory: any operation can use them, at any alignment, a byte at a time.

**Ports:**

| Port | Device |
|------|--------|
| 0 | SD card data FIFO (spec 15), paced by the card; reserved until the SD controller has its FIFO |
| 1 | USB serial FIFOs (spec 14), paced by the link: a source reads the receive FIFO, a destination writes the transmit FIFO |
| 2–7 | Reserved |

When a port isn't ready, that channel waits and the other channels keep running. Port addresses don't move on.

## 5. Memory cycles and priority

The engine is the DMA engine channel (BLT) of the memory scheduler (spec 5, section 6): after the hard-deadline channels, audio and the copper in the free order, ahead of the DMA port.

- **One memory cycle** (20 ns) reads or writes 2 bytes at any even address, with byte selects for single bytes (spec 5, section 4.2). A copy costs 2 cycles per 2 bytes (one read, one write); a fill costs 1; a job that reads the destination costs 3.
- **Normal jobs** use cycles nobody else wants: cycle 4, cycle 2 when audio isn't using it, display cycles (1 and 3) no layer needs (all of them in the vertical blank), and cycle 0 whenever the CPU isn't using it. **The CPU is never slowed.**
- **HIGH jobs** may also take the CPU's cycle 0, but always leave the CPU a share of them, so it can still run interrupts and code from Chip RAM. The share is set per channel by CHCTRL.CPUSHARE: **1 in 2, 1 in 4 (default) or 1 in 8** of the cycle 0s the CPU asks for. Each cycle taken makes the CPU wait one slot (100 ns), as an urgent display fetch does. Use HIGH when the CPU would only be waiting for the job anyway.
- **Between channels:** channels with work to do take turns, a group of up to 8 memory cycles each, so a long blit can't hold up a peripheral transfer for more than a fraction of a microsecond. A channel waiting for a port, or for the register bus, gives up its turn.
- **Descriptors** in Chip RAM take 16 read cycles (32 bytes) to load. Descriptors in the descriptor RAM take none, which suits short, frequent jobs.

## 6. How a blit works

The engine works through each row in groups of up to 8 words (16 bytes). Each group goes through the same four steps:

1. **Read:** up to 16 bytes from the source into the engine's buffer, one word per memory cycle. Jobs that read the destination (LOGIC, ADD, KEYCOPY below 8 bpp, and bytes covered in part at 1, 2 or 4 bpp) also read the matching destination words.
2. **Shift** (1, 2 and 4 bpp): when the source and destination start at different pixels within a byte (SRCBIT ≠ DSTBIT), the data is shifted by the difference. Bits carry from one word into the next, as in the Amiga's barrel shifter. At 8 bpp there is never any shifting: every pixel is a byte.
3. **Combine:** key compare (KEYCOPY), logic function (LOGIC) or per-pixel add (ADD).
4. **Write:** one word per memory cycle, using the SRAM's byte selects to leave an untouched byte alone.

**Edge masks are automatic.** The engine works out which pixels of the first and last bytes of each row belong to the job from DSTBIT and WIDTH. There are no mask registers to set, unlike the Amiga's first-word and last-word masks.

**Read-modify-write:** the SRAM can only skip whole bytes when writing. When a write would change only some pixels in a byte, the engine reads the destination, merges, and writes it back. This happens:

- at the row edges of 1, 2 and 4 bpp jobs that don't start or end on a byte,
- for every byte of KEYCOPY at 1, 2 and 4 bpp (two or more pixels share a byte),
- always for LOGIC and ADD.

At 8 bpp, COPY, FILL and KEYCOPY never need it: a skipped key pixel is simply a byte not written. **8 bpp chunky is the fastest format for game graphics.**

### 6.1 Planar layers

A planar layer (spec 4, section 4.2) is several 1 bpp pictures, one per plane. The engine draws into it at BPP = 0, a plane at a time, positioned to the pixel:

- **Separate planes:** one job per plane, chained, with SRC and DST moved on by a plane each time.
- **Interleaved planes** (each row of each plane next to the row of the next plane): one job does all the planes, if the source is interleaved the same way: HEIGHT = rows × planes, and each stride = one plane row's bytes.
- **Transparent drawing (cookie cut)**, as on the Amiga: keep a 1 bpp mask of the object (1 where it has a pixel). For each plane, a LOGIC job with FN = `0x2` (destination AND NOT mask) cuts the object's shape out of the background, then a LOGIC job with FN = `0xE` (OR) puts the object's plane in. KEYCOPY is for chunky layers: in a planar layer, a colour is spread over the planes.

## 7. Speed

A 576p line is 32 µs: 320 slots, 1,600 memory cycles. The engine gets what the other users leave:

| Cycles per line | Free for the engine |
|-----------------|---------------------|
| Cycle 4 | 320, less the copper's |
| Cycle 2 | 320, less audio's (a few: 4 channels of 8-bit samples need about 2 words per line) |
| Cycle 0 | The CPU's leftovers: at least 160 when the 68000 runs flat out from Chip RAM (a bus cycle is two slots), 320 when it runs from ROM or waits |
| Cycles 1 and 3 | 640 less the layers' fetches (spec 4, section 5.2), less sprites' |

Some screens, before the copper and sprites take their (usually small) share:

| Situation (normal job) | Free cycles per line | Copy | Fill |
|------------------------|----------------------|------|------|
| CPU busy, one full-screen 8 bpp chunky layer (about 370 words a line) | about 1,070 | 33 MB/s | 67 MB/s |
| CPU busy, layers using the whole display budget (640 words a line) | about 800 | 25 MB/s | 50 MB/s |
| CPU idle, one full-screen 8 bpp chunky layer | about 1,230 | 38 MB/s | 77 MB/s |
| Vertical blank (49 lines a frame), CPU busy | about 1,440 | 45 MB/s | 90 MB/s |

A HIGH job takes up to 3 in 4 (default CPUSHARE) of the cycle 0s a busy CPU would use: about 120 more cycles a line, 4 MB/s more copy speed. HIGH with "1 in 2" adds nothing to the speed (the CPU never asks for more than every other cycle 0); it only makes the CPU wait in turn.

Jobs that read the destination (LOGIC, ADD) need 3 cycles per 2 bytes instead of 2, so they run at about two thirds of the copy speed. Jobs at 1, 2 or 4 bpp that are not byte-aligned add a read at each row edge.

For comparison, a 68000 at 20 MHz copies about 4 MB/s (`MOVE.L (A0)+,(A1)+` or `MOVEM.L`). Clearing a full-screen 720 × 576 8 bpp picture (405 KB) takes about 6–8 ms with the engine, well within one 50 Hz frame (20 ms), with the CPU busy.

These figures are worked out from the slot rules; open point D2 is to measure them in simulation.

## 8. Channels and registers

Offsets in the custom register block at `0xE00000` (spec 3, section 3.5).

**Per channel** (channel n at `0x300 + n × 0x10`):

| Offset | Name | Bits | Meaning |
|--------|------|------|---------|
| `+0x0` | CHDESC | 23–0 | Write: the first descriptor of a chain (long-word aligned). Read: the descriptor now running, or the last one run |
| `+0x4` | CHCTRL | START (0), STOP (1), PAUSE (2), CPUSHARE (5–4) | START (strobe) begins the chain at CHDESC; ignored while BUSY. STOP (strobe) ends it after the current group of cycles. PAUSE holds it while set. CPUSHARE: the cycle 0s the CPU keeps during this channel's HIGH jobs: 0 = 1 in 2, 1 = 1 in 4 (default), 2 = 1 in 8 |
| `+0x8` | CHSTAT | BUSY (0), DONE (1), ERR (2), PAUSED (3) | BUSY: a chain is running (or paused). DONE: a chain reached its end (NEXT = 0) or was stopped. ERR: a job stopped with an error. DONE and ERR are sticky, write 1 to clear |
| `+0xC` | CHERR | 23–0 | The address that caused the error, or the descriptor's address for a bad descriptor |

**Global:**

| Offset | Name | Bits | Meaning |
|--------|------|------|---------|
| `0x340` | DMXINT | CH 3–0 | A channel's interrupt is pending (a descriptor with IRQ finished, or an error); write 1 to clear |
| `0x344` | DMXINTEN | CH 3–0 | Interrupt enables per channel |

**Descriptor RAM:** 2 KB at `0xE06000`–`0xE067FF`, room for 64 descriptors (or small buffers). One block RAM. Its contents are undefined after reset.

**DMACON** (spec 5, section 8): bit 6, **BLTEN**, with DMAEN, lets the engine use memory cycles. While it is clear, running channels wait (CHSTAT.BUSY stays set). Register and port transfers that need no memory cycles also wait, so clearing BLTEN holds the whole engine.

**Interrupts:** each channel is its own source in the interrupt controller (spec 13), DMA0–DMA3 (sources 4–7), default level 4. A channel requests its interrupt while its DMXINT bit and DMXINTEN bit are both set.

**Errors:** a bad address (section 4), a register access breaking the rules, a bad OP or a bad combination of kinds (section 3) stops the channel: ERR is set, CHERR holds the address, CHDESC the descriptor, and the channel's DMXINT bit is set. The other channels carry on.

**Typical use:**

1. Write descriptors to the descriptor RAM (`0xE06000`) or Chip RAM.
2. Write the first descriptor's address to CHDESC, then START to CHCTRL.
3. Carry on. Take the interrupt, or poll CHSTAT.BUSY.

The copper can also start channels, for example to change a screen area at a set beam position, and its WAIT with the B bit waits until every channel is idle (spec 10).

## 9. Suggested channel use

Software decides, but a sensible default:

| Channel | Use |
|---------|-----|
| 0 | SD card |
| 1 | USB serial |
| 2 | General memory copies and fills |
| 3 | Graphics (blits) |

## 10. FPGA resources

| Item | Resource |
|------|----------|
| Descriptor RAM, 2 KB | 1 block RAM |
| Per-channel state (the running descriptor's fields and positions) | Distributed RAM, one channel worked on at a time (as in `bpldma.v` and `sprites.v`) |
| Data buffer between reads and writes (16 bytes and the shifter's carry) | Logic |
| The shared datapath: 2D address units, pixel shifter, edge masks, colour key compare, logic function, per-pixel adder | Estimate 1,500–2,500 LUTs, to confirm by synthesis. The design is at about 61% of the LUTs (Vivado), with little timing margin at 100 MHz, so the datapath is pipelined from the start |

## 11. Open points

| # | Item |
|---|------|
| D1 | Check the engine fits and meets timing at 100 MHz |
| D2 | Measure the speed figures of section 7 in simulation |
| D3 | Line drawing and area fill (Amiga blitter features), and scaling or rotating blits: version 2 |
| D4 | MIX (section 3.1): on hold until it has proper resampling |
| D5 | Port 0 waits for the SD controller's FIFO (spec 15; version 1 of the SD controller is a plain SPI byte master) |

## 12. Tests

- **Copy and fill:** linear and 2D, every BPP, starting and ending part-way through a byte, positive, zero and negative strides, forwards and backwards (DESC) with overlapping areas. Compare with a Python reference model.
- **KEYCOPY and LOGIC:** every BPP, with key pixels at the edges; a planar cookie-cut draw (section 6.1).
- **ADD:** every BPP, wrap and saturate, signed and unsigned, memory and constant sources; check carries never cross pixels.
- **Chains:** a chain of mixed jobs in Chip RAM and in the descriptor RAM; IRQ only on the marked ones; jobs of zero width or height.
- **Channels:** all 4 running at once; a stalled port channel does not hold up the others; STOP and PAUSE.
- **Priority:** normal jobs never delay the CPU; HIGH jobs leave the CPU at least its CPUSHARE of cycle 0s (all three settings), and every CPU delay is one slot.
- **Errors:** a bad address (including the system area and past the end of a 2 MB board's RAM), a bad OP and a bad combination stop only that channel, set ERR and CHERR, and raise its interrupt.
- **Registers:** a block COPY into a layer's registers gives exactly the same result as CPU writes; a COPY into CHCTRL that starts another channel works; register reads into memory; a misaligned register access is an error; a CPU register access is never delayed by the engine.
- **Ports:** a USB serial transfer each way, paced by the FIFOs (with the FT232H model in `sim/`).
- **Speed:** the figures in section 7.
