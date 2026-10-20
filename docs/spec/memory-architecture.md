# Spec 5: Memory architecture and DMA slot arbitration

Status: **draft for review**

This spec describes how the CPU, video, audio and other DMA engines share the SDRAM. It follows the Amiga's model: memory time is cut into fixed **slots**, and the slots alternate between the CPU (even slots) and DMA (odd slots). Each DMA engine owns fixed slots in every 32 µs period, so its bandwidth is guaranteed, and the CPU never waits for video or audio.

## 1. Summary

| Item | Value |
|------|-------|
| Memory | One Winbond W9825G6JH SDRAM, 16M × 16 bit (32 MB), on the miniSpartan6+ |
| SDRAM clock | 100 MHz, CAS latency 2 |
| Slot length | 80 ns = 8 SDRAM clocks = one 68000 clock at 12.5 MHz |
| Slot period | 400 slots = 32 µs; the odd-slot table repeats every period. Independent of the video mode |
| Even slots | CPU first; blitter gets the ones the CPU does not use |
| Odd slots | DMA: half for display fetch (layers and sprites), a few fixed ones for refresh, audio and storage, the rest to copper and blitter |
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
| fx68k master clock | 25 MHz with alternating phase enables → 12.5 MHz 68000 | 1 CPU clock |

A counter `slot` (0–399) runs continuously, and bit 0 decides even or odd. The 400-slot period is 32 µs.

The video pixel clock is **not** tied to this grid. Video runs on its own programmable clock and hands data over through dual-port line buffers (spec 4, section 3.1). The memory side never changes when the video mode changes.

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

### 4.4 Bursts and why slots close their row

SDRAM keeps the RAS/CAS idea of older DRAM under new names: **ACTIVE** opens a row (RAS), **READ/WRITE** picks a column (CAS), and **PRECHARGE** closes the row. Once a row is open, a new column can be read or written every clock.

- **DMA slots already burst:** one ACTIVE, then 4 column reads back to back (8 bytes). This is the same idea as the Amiga AGA chipset's wider fetch modes (FMODE), which used page mode to fetch 32 or 64 bits per memory cycle.
- **4 words is the most that fits in a slot.** A 5th read would push the precharge to clock 7, and the bank would not be ready again until clock 9. That is past the start of the next slot, which may need the same bank.
- **Why each slot closes its row:** if a row stayed open into the next slot, that slot's timing would depend on which bank and row it needs. Closing the row every time keeps every slot independent and its timing fixed. That is what guarantees the CPU never waits.
- **Cost:** opening and closing a row takes about half of each slot, so a DMA slot moves data on 4 of its 8 clocks. Even so, the odd slots give up to 50 MB/s, and video uses at most 40% of them in version 1.

**Possible later upgrade: bank interleaving.** The SDRAM has 4 independent banks, and a row can be opened in one bank while another is bursting. Keeping frame buffers in their own bank would let video stream long bursts at close to the full 200 MB/s. The CPU can touch any bank at any time, so this needs a careful worst-case design. It is worth doing only if 16-bit colour modes or a faster blitter need the bandwidth.

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

Because the CPU uses at most one even slot in two, the blitter always gets at least 100 even slots per 32 µs period, even with the CPU running flat out from Chip RAM.

A future "blitter priority" bit (like the Amiga's BLTPRI) could let the blitter take CPU slots too, slowing the CPU. It is left out of version 1.

## 7. Odd-slot table (DMA)

Odd slots are given out by a fixed pattern that repeats every 400-slot period (32 µs). It does not follow the video lines, so it is the same in every video mode.

### 7.1 Fixed allocation per 32 µs period

| Owner | Odd slots per period | Which slots | Notes |
|-------|----------------------|-------------|-------|
| Display fetch (layers and sprites) | 100 | `slot % 4 == 1` | 25 MB/s. Demand-driven: the video fetch engine uses them when a line buffer needs filling (spec 4, section 5) |
| Refresh | 5 | Fixed `slot % 4 == 3` positions | SDRAM needs 8192 refreshes per 64 ms = 4.1 per 32 µs; 5 gives margin |
| Audio | 8 (one per channel; 4 channels in version 1) | Fixed `slot % 4 == 3` positions | One 4-word burst per channel per period |
| Storage (SD / USB) | 2 guaranteed | Fixed `slot % 4 == 3` positions | More from the free pool |
| **Free pool** | **85** | The other `slot % 4 == 3` slots | Display fetch first if wide fetch is on (spec 4), then copper, blitter, extra storage |
| **Total** | **200** | | |

If an owner doesn't need its slot (audio FIFO full, no line waiting to be fetched), the slot drops to the free pool.

Free odd slots go, in order, to:

1. **Display fetch**, if wide fetch is on
2. **Copper**, the display-list coprocessor (version 2)
3. **Blitter**
4. **Storage**, beyond its 2 guaranteed slots
5. Idle

The fixed refresh, audio and storage slots are spread evenly through the period, so none of them is ever more than a few microseconds late.

### 7.2 What each owner gets

| Owner | Needs | Gets | Margin |
|-------|-------|------|--------|
| Display fetch | Depends on the video mode and layers (spec 4, section 5.2) | 25 MB/s normal, ~46 MB/s wide | Spec 4 has per-mode budgets |
| Audio channel at 48 kHz, 16-bit | 96 KB/s | 250 KB/s (8 bytes every 32 µs) | Pitch can go up about 2.6× before it runs short |
| Refresh | 4.1 per 32 µs | 5 | 22% |
| Blitter (worst case: wide fetch fully used, CPU flat out) | – | ≥ 100 even slots per period: ~25 MB/s of reads or ~12 MB/s of writes | More whenever display fetch or the CPU leave slots unused |

Display fetch only uses slots while a line buffer is waiting to be filled. During vertical blanking, and whenever a frame's layers need less than the full budget, its slots go to the free pool.

### 7.3 Line buffers

Video and sprites are fetched one line ahead into block RAM line buffers. These are dual-port: the fetch engine writes them on the memory clock and the display reads them on the pixel clock. Two buffers per layer swap each line, so the pixel output never waits for SDRAM.

### 7.4 Higher-bandwidth modes (not in version 1)

Modes that need more than wide fetch gives (e.g. 1280×720 at 8bpp, or 16 bits per pixel) would have to borrow even slots and slow the CPU, as on the Amiga, where high-resolution modes with many bitplanes steal CPU cycles. Bank interleaving (section 4.4) is the better way to get there. Neither is in version 1.

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
| M7 | Bank interleaving for longer bursts (section 4.4): only if a later mode needs more bandwidth |

## 11. Tests

- **Slot-table check in simulation:** count slot owners per 32 µs period and assert each fixed owner gets its share, in every video mode.
- **CPU zero-wait test:** run fx68k from Chip RAM with all DMA on; assert that /DTACK is never delayed once the CPU is aligned.
- **Misalignment test:** force a cycle to start in an odd slot; assert exactly one extra clock, then realignment.
- **SDRAM model:** run against a Winbond/Micron SDRAM simulation model with timing checks on, at the -75 timings.
- **Refresh:** assert that no SDRAM row goes unrefreshed for 64 ms (counter check in simulation).
