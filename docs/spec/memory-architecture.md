# Spec 5: Memory architecture and DMA slot arbitration

Status: **draft for review**

This spec describes how the CPU, video, audio and other DMA engines share the SDRAM. It follows the Amiga's model: memory time is cut into fixed **slots**, and the slots alternate between the CPU (even slots) and DMA (odd slots). Each DMA engine owns fixed slots in every scan line, so its bandwidth is guaranteed, and the CPU never waits for video or audio.

## 1. Summary

| Item | Value |
|------|-------|
| Memory | One Winbond W9825G6JH SDRAM, 16M × 16 bit (32 MB), on the miniSpartan6+ |
| SDRAM clock | 100 MHz, CAS latency 2 |
| Slot length | 80 ns = 8 SDRAM clocks = one 68000 clock at 12.5 MHz = two pixels |
| Slots per scan line | 400 (800 pixels × 40 ns = 32 µs) |
| Even slots | CPU first; blitter gets the ones the CPU does not use |
| Odd slots | DMA: a fixed table per line (refresh, audio, sprites, video, storage), leftovers to copper and blitter |
| Page policy | Closed page: every slot opens a row, transfers, and precharges. No slot depends on the one before it |
| CPU waits | **None** in normal running (see section 5) |

## 2. Memory types (Amiga naming)

| Name | Where | Who can access it |
|------|-------|-------------------|
| **Chip RAM** | The 32 MB SDRAM | CPU and every DMA engine |
| **Fast RAM** | 2 MB SRAM on the later CPU board | CPU only, never slowed by DMA |
| **Block RAM** | Inside the FPGA: boot ROM, text screen, font, palette, line buffers, FIFOs | CPU through registers/windows; never uses SDRAM slots |

On the main path (fx68k inside the FPGA) there is no Fast RAM, so all RAM is Chip RAM. Because the CPU has its own guaranteed slots, Chip RAM is still zero-wait for the CPU. On the Amiga that was only true when no high-bandwidth display mode was on.

## 3. Memory map (replaces D5 in the design plan)

| Range | Size | Device |
|-------|------|--------|
| `0x000000`–`0x7FFFFF` | 8 MB | Chip RAM, first 8 MB of the SDRAM. At reset the boot ROM overlays address 0 |
| `0x800000`–`0x9FFFFF` | 2 MB | Chip RAM bank window: any 2 MB bank of the 32 MB, chosen by a register |
| `0xA00000`–`0xBFFFFF` | 2 MB | Fast RAM (CPU board only; unmapped on the main path) |
| `0xE00000`–`0xE0FFFF` | 64 KB | Custom registers: video, audio, DMA control, blitter, copper |
| `0xE10000`–`0xE13FFF` | 16 KB | Text screen and font (block RAM) |
| `0xF00000`–`0xF0FFFF` | 64 KB | System: USB serial, timers, interrupt controller, SD, keyboard |
| `0xF80000`–`0xF87FFF` | 32 KB | Boot ROM (block RAM), like the Amiga's Kickstart at `0xF80000` |
| everything else | | Unmapped: `/BERR` after a timeout |

- **Reset overlay:** after reset the ROM also appears at `0x000000`, so the CPU can fetch its stack pointer and start address. The ROM code jumps to its real address at `0xF80000`, then turns the overlay off with a write to a system register.
- **DMA pointers are 25-bit byte addresses**, so video, audio, sprites, copper and blitter can use all 32 MB, not just what the CPU sees directly.
- The CPU sees no difference between the first 8 MB and the bank window. Both use the CPU's slots and both are zero-wait.

## 4. Slot timing

### 4.1 Clocks

All clocks come from one PLL and are phase-locked:

| Clock | Frequency | Per slot |
|-------|-----------|----------|
| System / SDRAM | 100 MHz | 8 |
| Pixel | 25 MHz | 2 |
| fx68k master clock | 25 MHz with alternating phase enables → 12.5 MHz 68000 | 1 CPU clock |

A 10-bit counter `hslot` (0–399) counts slots across each scan line, and bit 0 decides even or odd. `hslot` and the scan-line counter `vline` (0–524) are readable by the CPU, like the Amiga's beam position registers (VHPOSR).

### 4.2 SDRAM operations that fit in one slot

The mode register is set to burst length 1. Multi-word transfers are back-to-back column commands to the same open row, which lets any slot move 1–4 words. Every slot ends with its bank precharged.

Clock numbers are within the slot (0–7, 10 ns each):

| Slot type | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | Moves |
|-----------|---|---|---|---|---|---|---|---|-------|
| CPU read (1 word) | ACT | – | RD | – | *data* | PRE | – | – | 2 bytes |
| CPU write (1 word, byte mask) | ACT | – | WR + data | – | – | PRE | – | – | 2 bytes |
| DMA read (4 words, same row) | ACT | – | RD | RD | RD *data* | RD *data* | PRE *data* | *data* | 8 bytes |
| DMA write (2 words, same row) | ACT | – | WR + data | WR + data | – | PRE | – | – | 4 bytes |
| Refresh | REF | – | – | – | – | – | – | – | – |

Checked against the W9825G6 datasheet, using the slowest speed grade (-75) as the worst case:

| Rule | Requirement (-75) | Worst case in the table | OK |
|------|-------------------|-------------------------|----|
| ACT → RD/WR (tRCD) | ≥ 20 ns | 20 ns | ✓ |
| ACT → PRE (tRAS) | ≥ 45 ns | 50 ns | ✓ |
| PRE → next ACT (tRP) | ≥ 20 ns | 20 ns (DMA read) | ✓ |
| ACT → next ACT (tRC) | ≥ 65 ns | 80 ns | ✓ |
| Last write data → PRE (tWR) | ≥ 2 clocks | 2 clocks | ✓ |
| REF → next command (tRC) | ≥ 65 ns | 80 ns | ✓ |
| Clock period at CAS latency 2 | ≥ 10 ns | 10 ns | ✓ |

The board's actual chip (W9825G6JH, speed grade to be read off the chip) is at least as fast, so there is some margin. The tightest cases are tRCD and tRP at exactly 20 ns, and only on the slowest grade.

Byte writes from the CPU use the SDRAM's UDQM/LDQM byte masks, driven from the 68000's /UDS and /LDS.

### 4.3 Bandwidth

- Slots per second: 12.5 million (6.25 M even, 6.25 M odd)
- Odd-slot DMA, reading: up to 50 MB/s
- CPU: a 68000 at 12.5 MHz makes at most one memory access every 4 clocks (320 ns), which is 6.25 MB/s. That uses at most **one even slot in two**.

## 5. CPU access: even slots and zero wait states

A 68000 bus cycle takes 4 CPU clocks = 4 slots. Its states S0–S7 map onto slots like this, for a cycle starting in slot *k*:

```
 slot:      k        k+1       k+2       k+3
 state:   S0  S1   S2  S3   S4  S5   S6  S7
          ---------+---------+---------+--------
 address:   valid ->
 /AS:          asserted ------------------>
 SDRAM:                     ACT..RD..data
 /DTACK:                    asserted -------->
 CPU latches read data:                 end of S6
```

- The CPU's SDRAM access always happens in slot **k+2** (S4–S5). The address and R/W are known since S1–S2, and write data since S3. Read data is back at the start of S5, well before the CPU latches it at the end of S6.
- For that to be an even slot, the bus cycle must start in an even slot. Every 68000 bus cycle and internal operation takes an even number of clocks, so **once the CPU is aligned it stays aligned**. The bus interface aligns fx68k at reset.
- **Self-healing, like the Amiga:** if a cycle ever starts in an odd slot, the bus interface holds /DTACK one extra clock. The access then uses slot k+3, which is even, and the cycle takes 5 clocks. The next cycle starts aligned again. This costs one clock, once.
- **Things that would misalign the CPU, and how they are avoided:**
  - *Autovectored interrupts (/VPA)* use the slow 6800-style E-clock cycle, which takes a variable, sometimes odd, number of clocks. **Change to the plan (D8):** interrupts are vectored instead. The FPGA supplies the vector number and /DTACK during the interrupt-acknowledge cycle. This is also faster.
  - *Wait states from other devices* (e.g. a slow register) are always inserted in pairs of clocks.
  - *TAS* (read-modify-write, 10 clocks): the read uses the normal slot and the write uses the next even slot. It may take one realignment clock. TAS is rare.
- Accesses to block RAM, registers and ROM never use an SDRAM slot. During those, and during CPU internal operations, the CPU's even slots are free.

**Result:** the CPU runs at full 12.5 MHz speed from Chip RAM whatever video, audio and sprites are doing.

**Headroom:** if fx68k is later clocked faster (Q1 in the design plan), a 25 MHz 68000 would make an access every 160 ns, one per even slot. The same scheme would still give it zero wait states.

## 6. Even-slot priority

For each even slot, in order:

1. **CPU**, if a CPU bus cycle to Chip RAM started two slots earlier
2. **Blitter**, if it has work
3. **Copper**, if it has work
4. Idle

Because the CPU uses at most one even slot in two, the blitter always gets at least 100 even slots per line, even with the CPU running flat out from Chip RAM.

A future "blitter priority" bit (like the Amiga's BLTPRI) could let the blitter take CPU slots too, slowing the CPU. It is left out of version 1.

## 7. Odd-slot table (DMA)

Each scan line has 400 slots: slots 0–319 cover the 640 visible pixels and slots 320–399 the horizontal blanking. Odd slots are given out by a fixed table. If an owner doesn't need its slot this line (channel off, FIFO full), the slot drops to the free pool.

### 7.1 Fixed allocation (640×480, 8 bits per pixel: the heaviest version 1 mode)

| Owner | Odd slots per line | Where in the line | Bytes per line | Notes |
|-------|--------------------|-------------------|----------------|-------|
| Refresh | 5 | Blanking | – | SDRAM needs 8192 refreshes per 64 ms = 4.1 per line; 5 gives margin |
| Audio | 8 (one per channel; 4 channels in version 1) | Blanking | 8 per channel | One 4-word burst per channel per line |
| Sprites | 16 (2 per sprite, 8 sprites) | Blanking | 16 per sprite | 16 px at 8bpp or 32 px at 4bpp per sprite per line |
| Storage (SD / USB) | 2 guaranteed | Blanking | 16 | More from the free pool |
| Video fetch | 80 (every 4th slot, `hslot % 4 == 1`) | Visible area | 640 | Fetches the **next** line into a line buffer |
| **Free pool** | **89** | Visible area (`hslot % 4 == 3`) and 9 in blanking | | Copper, then blitter, then extra storage |
| **Total** | **200** | | | |

Free odd slots go, in order, to:

1. **Copper**, the display-list coprocessor (version 2)
2. **Blitter**
3. **Storage**, beyond its 2 guaranteed slots
4. Idle

### 7.2 What each owner gets

| Owner | Needs | Gets | Margin |
|-------|-------|------|--------|
| Video 640×480×8bpp | 640 bytes per line | 640 | Exact (fixed 80 slots) |
| Video 640×480×4bpp | 320 | 640 | 50% of video slots return to the free pool |
| Video 320×240×8bpp | 320 bytes every 2nd line (line buffer reused) | 640 | 75% return to the free pool |
| Audio channel at 48 kHz, 16-bit | 1.54 samples per line | 4 samples per line | Pitch can go up about 2.6× before it runs short |
| Refresh | 4.1 per line | 5 | 22% |
| Blitter (worst case: 640×480×8bpp, CPU flat out) | – | ≥ 89 odd + ≥ 100 even slots per line: up to ~47 MB/s of reads or ~24 MB/s of writes | |

During vertical blanking (45 of the 525 lines) there is no video fetch, so those lines give the blitter even more slots.

### 7.3 Line buffers

Video and sprites are fetched one line ahead into block RAM line buffers. Two 640-byte buffers swap each line, so the pixel output never waits for SDRAM. This also lets the fetch slots be spread evenly across the whole line instead of crowding the visible area. Pixel doubling for 320×240 modes repeats the same buffer for two lines.

### 7.4 Higher-bandwidth modes (not in version 1)

A 640×480 mode at 16 bits per pixel would need 160 odd slots per line, which is every odd slot in the visible area. As on the Amiga, where high-resolution modes with many bitplanes steal CPU cycles, a mode like that would have to borrow even slots and slow the CPU. It is left out of version 1.

## 8. DMA control register (Amiga DMACON style)

One register at `0xE00000 + 0x096` (offset chosen to echo the Amiga; final address goes in spec 3) with set/clear writes:

| Bit | Name | Enables |
|-----|------|---------|
| 15 | SETCLR | 1 = set the bits written as 1, 0 = clear them |
| 9 | DMAEN | Master enable for everything below |
| 8 | VIDEN | Video fetch |
| 7 | COPEN | Copper |
| 6 | BLTEN | Blitter |
| 5 | SPREN | Sprites |
| 4 | STOEN | Storage DMA |
| 3–0 | AUD3EN–AUD0EN | Audio channels 0–3 (channels 4–7 later in a second register) |

Refresh cannot be turned off.

## 9. The later CPU board

With the real 68SEC000:

- **Fast RAM** (2 MB SRAM on the CPU board) is CPU-only and always zero-wait.
- The external CPU's clock is made by the same PLL, so it stays phase-locked to the slot grid. Chip RAM accesses go through the same even-slot logic. The bus synchronisers add delay, so Chip RAM accesses from the external CPU may need one or two wait states. Spec 1 will work this out.
- Programs that need full speed run from Fast RAM, exactly as on an Amiga with Fast RAM.

## 10. Open points

| # | Item |
|---|------|
| M1 | Confirm fx68k's exact bus timing (when address and write data are valid) in simulation; section 5 assumes real-68000 timing |
| M2 | Read the speed grade off the board's SDRAM chip (W9825G6JH-6, -6I or -75) |
| M3 | Choose the final register addresses (spec 3) |
| M4 | Blitter design: its data path and how it splits read and write slots (spec to follow) |
| M5 | Copper instruction set (spec to follow; version 2) |
| M6 | Whether sprite count/width should trade off against each other (e.g. 4 wide sprites vs 8 narrow) |

## 11. Tests

- **Slot-table check in simulation:** count slot owners per line for every video mode and assert each owner gets its fixed share.
- **CPU zero-wait test:** run fx68k from Chip RAM with all DMA on; assert that /DTACK is never delayed once the CPU is aligned.
- **Misalignment test:** force a cycle to start in an odd slot; assert exactly one extra clock, then realignment.
- **SDRAM model:** run against a Winbond/Micron SDRAM simulation model with timing checks on, at the -75 timings.
- **Refresh:** assert that no SDRAM row goes unrefreshed for 64 ms (counter check in simulation).
