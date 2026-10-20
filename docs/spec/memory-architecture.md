# Spec 5: Memory architecture and DMA slot arbitration

Status: **draft for review**

This spec describes how the CPU, video, audio and other DMA engines share the SDRAM. It follows the Amiga's model: memory time is cut into fixed **slots**, and the slots alternate between the CPU (even slots) and DMA (odd slots). Each DMA engine owns fixed slots in every scan line, so its bandwidth is guaranteed. The CPU runs at 20 MHz. It owns the even slots and may also use any odd slot that DMA leaves free, so it rarely waits; when it does, it loses 2 clocks, as on the Amiga.

## 1. Summary

| Item | Value |
|------|-------|
| Memory | One Winbond W9825G6JH SDRAM, 16M × 16 bit (32 MB), on the miniSpartan6+. **8 MB is used as Chip RAM**; the rest is unused |
| SDRAM clock | 100 MHz, CAS latency 2 |
| Slot length | 100 ns = 10 SDRAM clocks = 2 CPU clocks at 20 MHz (the Amiga's ratio). Fallback if fx68k cannot reach 20 MHz: 120 ns at 16.7 MHz |
| Slots per line | Every scan line is a whole, even number of slots (204–322 depending on the video mode). The slot counter restarts each line, so DMA is locked to the beam |
| Even slots | CPU first; sprites and blitter get the ones the CPU does not use |
| Odd slots | DMA, at fixed beam positions: half for display fetch, a few for refresh, audio and peripheral transfers, the rest free. The CPU may use any odd slot DMA leaves free |
| Page policy | Closed page: every slot opens a row, transfers, and precharges. No slot depends on the one before it |
| CPU waits | 2 clocks, only when an access lands on an odd slot DMA is using, or a sprite about to miss its deadline takes an even slot (section 5) |

## 2. Memory types (Amiga naming)

| Name | Where | Who can access it |
|------|-------|-------------------|
| **Chip RAM** | 8 MB of the SDRAM | CPU and every DMA engine |
| **Fast RAM** | 2 MB SRAM on the later CPU board | CPU only, never slowed by DMA |
| **Block RAM** | Inside the FPGA: boot ROM, text screen, font, palette, FIFOs | CPU through registers/windows; never uses SDRAM slots |

On the main path (fx68k inside the FPGA) there is no Fast RAM, so all RAM is Chip RAM. The CPU owns half of all slots and can use free DMA slots too, so Chip RAM runs close to full speed for the CPU. On the Amiga, Chip RAM was also slowed by display modes that stole CPU cycles; here display fetch never takes the CPU's even slots.

## 3. Memory map (replaces D5 in the design plan)

| Range | Size | Device |
|-------|------|--------|
| `0x000000`–`0x7FFFFF` | 8 MB | Chip RAM: the first 8 MB of the SDRAM. At reset the boot ROM overlays address 0 |
| `0x800000`–`0x9FFFFF` | 2 MB | Reserved |
| `0xA00000`–`0xBFFFFF` | 2 MB | Fast RAM (CPU board only; unmapped on the main path) |
| `0xE00000`–`0xE0FFFF` | 64 KB | Custom registers: video, audio, DMA control, blitter, copper |
| `0xE10000`–`0xE13FFF` | 16 KB | Text screen and font (block RAM) |
| `0xF00000`–`0xF0FFFF` | 64 KB | System: USB serial, timers, interrupt controller, SD, keyboard |
| `0xF80000`–`0xF87FFF` | 32 KB | Boot ROM (block RAM), like the Amiga's Kickstart at `0xF80000` |
| everything else | | Unmapped: `/BERR` after a timeout |

- **Reset overlay:** after reset the ROM also appears at `0x000000` for CPU reads (writes go to Chip RAM), so the CPU can fetch its stack pointer and start address. The ROM code runs at its real address at `0xF80000`, builds the vector table in RAM, then turns the overlay off (spec 7, section 3).
- **DMA addresses are the same as CPU addresses** (24-bit). Video, audio, sprites, copper and the DMA engine can all use the whole 8 MB of Chip RAM, which the CPU also sees directly. There is no bank window.
- **Why 8 MB:** plenty for this machine (a 640×480 256-colour screen is 300 KB). The SDRAM chip holds 32 MB, but the other 24 MB is left unused. It could become a RAM disk or an SD card cache later, through the DMA engine (open point M10).

## 4. Slot timing

### 4.1 Clocks

Everything comes from one 200 MHz master clock divided by whole numbers (spec 4, section 3.1):

| Clock | Master ÷ | Frequency | Per slot |
|-------|----------|-----------|----------|
| System / SDRAM | 2 | 100 MHz | 10 |
| fx68k master clock | 5 | 40 MHz with alternating phase enables → **20 MHz 68000** | 2 CPU clocks |
| Memory slot | 20 | 100 ns | 1 |
| Pixel clock | N = 3–8 | 66.7–25 MHz | 6.7–2.5 pixels |

**Fallback:** if fx68k does not meet timing at 40 MHz on the LX25 (design plan Q1), it runs at 33.3 MHz (÷ 6), giving a 16.7 MHz 68000. The slot is then 120 ns (12 SDRAM clocks; the extra 2 clocks are idle) and the video rule becomes HTOTAL × N a multiple of 48. Everything else in this spec stays the same.

The video timing rule (HTOTAL × N a multiple of 40) makes every scan line a whole, even number of slots. The slot counter `hslot` restarts at 0 at the start of every line, and bit 0 decides even or odd. Because every line has an even number of slots, the even/odd pattern carries on unbroken across lines and across video mode changes.

### 4.2 SDRAM operations that fit in one slot

The mode register is set to burst length 1. Multi-word transfers are back-to-back column commands to the same open row, which lets any slot move 1–6 words. Every slot ends with its bank precharged.

Clock numbers are within the slot (0–9, 10 ns each):

| Slot type | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | Moves |
|-----------|---|---|---|---|---|---|---|---|---|---|-------|
| CPU read (1 word) | ACT | – | RD | – | *data* | PRE | – | – | – | – | 2 bytes |
| CPU write (1 word, byte mask) | ACT | – | WR + data | – | – | PRE | – | – | – | – | 2 bytes |
| DMA read (6 words, same row) | ACT | – | RD | RD | RD *data* | RD *data* | RD *data* | RD *data* | PRE *data* | *data* | 12 bytes |
| DMA write (4 words, same row) | ACT | – | WR + data | WR + data | WR + data | WR + data | – | PRE | – | – | 8 bytes |
| Refresh | REF | – | – | – | – | – | – | – | – | – | – |

Checked against the W9825G6 datasheet, using the slowest speed grade (-75) as the worst case:

| Rule | Requirement (-75) | Worst case in the table | OK |
|------|-------------------|-------------------------|----|
| ACT → RD/WR (tRCD) | ≥ 20 ns | 20 ns | ✓ |
| ACT → PRE (tRAS) | ≥ 45 ns | 50 ns | ✓ |
| PRE → next ACT (tRP) | ≥ 20 ns | 20 ns (DMA read) | ✓ |
| ACT → next ACT (tRC) | ≥ 65 ns | 100 ns | ✓ |
| Last write data → PRE (tWR) | ≥ 2 clocks | 2 clocks | ✓ |
| REF → next command (tRC) | ≥ 65 ns | 100 ns | ✓ |
| Clock period at CAS latency 2 | ≥ 10 ns | 10 ns | ✓ |

The board's actual chip (W9825G6JH, speed grade to be read off the chip) is at least as fast, so there is some margin. The tightest cases are tRCD and tRP at exactly 20 ns, and only on the slowest grade.

DMA bursts can start at any even address. A burst that would cross the end of a 1 KB SDRAM row is cut short there.

Byte writes from the CPU use the SDRAM's UDQM/LDQM byte masks, driven from the 68000's /UDS and /LDS.

### 4.3 Bandwidth

- Slots per second: 10 million (5 M even, 5 M odd)
- Odd-slot DMA, reading: up to 60 MB/s
- CPU: a 68000 at 20 MHz makes at most one memory access every 4 clocks (200 ns), which is 10 MB/s. That is at most **one slot in two**, the same rate as the even slots.

### 4.4 Bursts and why slots close their row

SDRAM keeps the RAS/CAS idea of older DRAM under new names: **ACTIVE** opens a row (RAS), **READ/WRITE** picks a column (CAS), and **PRECHARGE** closes the row. Once a row is open, a new column can be read or written every clock.

- **DMA slots already burst:** one ACTIVE, then 6 column reads back to back (12 bytes). This is the same idea as the Amiga AGA chipset's wider fetch modes (FMODE), which used page mode to fetch 32 or 64 bits per memory cycle.
- **6 words is the most that fits in a slot.** A 7th read would push the precharge to clock 9, and the bank would not be ready again until clock 11. That is past the start of the next slot, which may need the same bank.
- **Why each slot closes its row:** if a row stayed open into the next slot, that slot's timing would depend on which bank and row it needs. Closing the row every time keeps every slot independent and its timing fixed. That is what makes the CPU's timing predictable.
- **Cost:** opening and closing a row takes about 4 clocks of each slot, so a DMA slot moves data on 6 of its 10 clocks. The odd slots give up to 60 MB/s.

**Possible later upgrade: bank interleaving.** The SDRAM has 4 independent banks, and a row can be opened in one bank while another is bursting. Keeping frame buffers in their own bank would let video stream long bursts at close to the full 200 MB/s. The CPU can touch any bank at any time, so this needs a careful worst-case design. It is worth doing only if 16-bit colour modes or a faster blitter need the bandwidth.

## 5. CPU access at 20 MHz

At 20 MHz a CPU clock is 50 ns, so one slot is 2 CPU clocks and a 68000 bus cycle (4 clocks) is 2 slots, as on the Amiga. For a cycle starting in slot *k*:

```
 slot:            k                   k+1
 state:   S0   S1   S2   S3   |  S4   S5   S6   S7
 time:    0    25   50   75   | 100  125  150  175  200 ns
 address:      valid ->
 /AS:               asserted ------------------------>
 SDRAM:                       | ACT .. RD .. data(140)
 /DTACK:                      | asserted ----------->
 CPU latches read data:                      end of S6 (175 ns)
```

- The CPU's SDRAM access happens in slot **k+1** (S4–S7). The address and R/W are known since S1–S2, and write data since S3. Read data is back at 140 ns, 35 ns before the CPU latches it at the end of S6. /DTACK is asserted at the start of S4, in time for the CPU to see it at the end of S4.
- The 68000 moves in steps of 2 clocks (one slot), so an access can land in an **even** or an **odd** slot.

**Who gets the slot:**

| The access lands in | Result |
|---------------------|--------|
| An even slot | The CPU gets it (unless a sprite is about to miss its deadline, section 6) |
| An odd slot that DMA is not using at that moment | The CPU gets it. No wait |
| An odd slot that DMA is using | /DTACK is held for 2 clocks and the access moves to the next slot, which is even. The CPU loses 2 clocks |

- **Self-aligning, like the Amiga:** after a 2-clock wait, back-to-back bus cycles land on even slots, so the CPU stays aligned until an instruction's internal steps shift it by an odd number of slots again.
- **Which odd slots are busy:** display-fetch slots while a layer needs data (in the visible part of lines that have layers), wide-fetch slots, and the few fixed refresh, audio and peripheral slots. Odd slots in the free pool go to the CPU before sprites, the copper or the DMA engine.
- **When a sprite takes an even slot** the CPU wanted (spec 4, section 5.4), the access also moves on by one slot: a 2-clock wait.
- **Things that would knock the CPU off the 2-clock grid,** and how they are avoided:
  - *Autovectored interrupts (/VPA)* use the slow 6800-style E-clock cycle, which takes a variable, sometimes odd, number of clocks. **Change to the plan (D8):** interrupts are vectored instead. The FPGA supplies the vector number and /DTACK during the interrupt-acknowledge cycle. This is also faster.
  - *Wait states from other devices* (e.g. a slow register) are always inserted in pairs of clocks.
- Accesses to block RAM, registers and ROM never use an SDRAM slot. During those, and during CPU internal operations, the CPU's even slots are free for sprites and the blitter.

**Result:** the CPU runs at 20 MHz and loses 2 clocks only when it meets busy DMA. A first guess is a few percent on a busy screen; simulation will measure it (open point M9). Running from ROM or block RAM is never slowed.

**At the 16.7 MHz fallback** the same scheme applies, with 120 ns slots.

## 6. Slot priority

**Even slots**, in order:

1. **Sprite fetch**, only if a sprite would otherwise miss its deadline (spec 4, section 5.4)
2. **Copper, urgent**: when its prefetch queue is less than half full (spec 10, section 6)
3. **DMA engine, HIGH jobs**, except the CPU's share (1 in 2, 1 in 4 or 1 in 8 even slots, set per channel), which is always left for the CPU (spec 11, section 5)
4. **CPU**
5. **Sprite fetch**, in its fetch window
6. **Copper**
7. **DMA engine** (blitter), normal jobs
8. Idle

**Odd slots**, in order:

1. **The slot's fixed owner** (section 7), if it needs the slot
2. **Sprite fetch**, only if a sprite would otherwise miss its deadline
3. **Copper, urgent**: when its prefetch queue is less than half full
4. **CPU**, if its access lands here
5. **Sprite fetch**, in its fetch window
6. **Audio fetch**, when a channel's sample cache is running low (spec 6, section 4.7)
7. **Copper**
8. **DMA engine** (blitter, copies, peripheral transfers)
9. Idle

**The DMA engine's share:** a 20 MHz CPU running flat out from Chip RAM can use every even slot. Normal DMA jobs then get the free odd slots: at 640×480 with wide fetch off, 65 per line, about 24 MB/s of reads. Whenever the CPU is doing internal work, or running from ROM or block RAM, the engine gets the even slots too. A job with the HIGH bit set (like the Amiga's BLTPRI) can take the CPU's even slots too, leaving it 1 in 2, 1 in 4 or 1 in 8 of them. Spec 11 has the details and speeds.

## 7. Odd-slot table (DMA)

Odd slots are given out by a fixed pattern that starts again at the beginning of every scan line, so every DMA engine gets its slots at the same beam positions on every line. A line has S slots (320 at 640×480; 204–322 in other modes, see spec 4, section 3.5).

### 7.1 Fixed allocation per line

| Odd slots | Owner |
|-----------|-------|
| `hslot % 4 == 1` | **Display fetch**: layers, just in time (spec 4, section 5). In the horizontal blanking, these slots do the prefetch for the next line |
| `hslot % 4 == 3`, the first F counted from the start of horizontal blanking | **Fixed users**: refresh, audio and peripheral transfers (below) |
| Other `hslot % 4 == 3` slots | **Display fetch** in the visible part if wide fetch is on; otherwise the **free pool** |

Fixed users, F = R + 10 slots per line:

| Owner | Slots | Notes |
|-------|-------|-------|
| Refresh | R = 4 or 5 | The SDRAM needs one refresh per 7.8 µs. R = ceil(1.2 × line time ÷ 7.8 µs): 5 for lines over 26 µs, 4 for shorter ones |
| Audio | 8: 6 shared by the 16 hardware channels, 2 for the stream (spec 6, sections 4.7 and 5) | One 6-word burst per slot |
| Peripheral transfers (SD / USB, through the DMA engine) | 2 guaranteed | Spec 11, section 5 |

In most modes all F fixed slots fall inside the horizontal blanking. In modes with short blanking (800×600 @ 72, 1024×768, 1280×720 @ 60), up to 7 of them run on into the start of the next visible line. That takes a few wide-fetch slots, which the 48-byte layer buffers absorb.

If an owner doesn't need its slot this line (audio caches full, layer off), the slot goes to the next user in the odd-slot priority list (section 6), starting with the CPU.

### 7.2 What each owner gets

| Owner | Needs | Gets | Margin |
|-------|-------|------|--------|
| Display fetch | Depends on the video mode and layers | Spec 4, section 5.2 lists the budget per mode | |
| Audio, 16 hardware channels at 48 kHz, 16-bit | 96 KB/s each at STEP 1 (1.5 MB/s for all 16) | 72 bytes per line: at least 2.2 MB/s, shared; more from the free pool when a cache runs low | All 16 always fit with octave copies (spec 6, section 4.7) |
| Audio stream, 48 kHz 16-bit stereo | 192 KB/s | 24 bytes per line: 750 KB/s | ~4× |
| Refresh | 1 per 7.8 µs | R per line, 20% or more spare | |
| Sprites | 1–3 slots per sprite per line, in the 64 slots before the sprite | Free odd slots and spare display slots first, then the CPU's even slots if needed (spec 9, section 5) | 16 sprites per line fit (spec 9 lists the limits) |
| DMA engine (blitter) | – | Free odd slots (about 24 MB/s of reads at 640×480, wide fetch off), plus every even slot the CPU leaves; HIGH jobs also most of the CPU's | Spec 11, section 7 |

During vertical blanking, display fetch has nothing to do, so its slots go to the free pool.

### 7.3 No line buffers

Display data is fetched just in time into a 48-byte buffer per layer, as the Amiga fetches bitplane data into its data registers. Nothing is stored for a whole line. The pixel output only depends on DMA keeping each small buffer topped up, and the fixed slot pattern guarantees that whenever the setup is within budget.

### 7.4 Higher-bandwidth modes (not in version 1)

Modes that need more than wide fetch gives (e.g. 1280×720 at 8bpp, or 16 bits per pixel) would have to take even slots and slow the CPU, as on the Amiga, where high-resolution modes with many bitplanes steal CPU cycles. Bank interleaving (section 4.4) is the better way to get there. Neither is in version 1.

## 8. DMA control register (Amiga DMACON style)

One register at `0xE00000 + 0x096` (offset chosen to echo the Amiga; final address goes in spec 3) with set/clear writes:

| Bit | Name | Enables |
|-----|------|---------|
| 15 | SETCLR | 1 = set the bits written as 1, 0 = clear them |
| 9 | DMAEN | Master enable for everything below |
| 8 | VIDEN | Video fetch |
| 7 | COPEN | Copper |
| 6 | DMXEN | DMA engine (blitter, copies, peripheral transfers; spec 11) |
| 5 | SPREN | Sprites |
| 4 | STREN | Audio stream (spec 6) |
| 3 | AUDEN | Audio hardware channels (each also has its own enable; spec 6) |
| 2–0 | – | Unused |

Refresh cannot be turned off.

## 9. The later CPU board

With the real 68SEC000:

- **Fast RAM** (2 MB SRAM on the CPU board) is CPU-only and always zero-wait.
- The external CPU's 20 MHz clock is the master ÷ 10, so it stays phase-locked to the slot grid. Chip RAM accesses go through the same slot logic. The bus synchronisers add delay, so Chip RAM accesses from the external CPU may need one or two wait states. Spec 1 will work this out.
- Programs that need full speed run from Fast RAM, exactly as on an Amiga with Fast RAM.

## 10. Open points

| # | Item |
|---|------|
| M1 | Confirm fx68k's exact bus timing (when address and write data are valid) in simulation; section 5 assumes real-68000 timing |
| M2 | Read the speed grade off the board's SDRAM chip (W9825G6JH-6, -6I or -75) |
| M3 | Choose the final register addresses (spec 3) |
| M7 | Bank interleaving for longer bursts (section 4.4): only if a later mode needs more bandwidth |
| M8 | Check the sprite scheduler's "take a CPU slot only when needed" decision fits in one 100 MHz clock |
| M9 | Measure in simulation how often the 20 MHz CPU waits, running typical code from Chip RAM with busy screens |
| M10 | Whether to use the unused 24 MB of the SDRAM (e.g. a RAM disk reached only through the DMA engine) |

## 11. Tests

- **Slot-table check in simulation:** for every video preset, count slot owners per line and assert each fixed owner gets its share at the same `hslot` on every line.
- **CPU wait test:** run fx68k from Chip RAM with all DMA on; assert that every /DTACK delay is exactly 2 clocks and caused by a busy odd slot or an urgent sprite, and log how often it happens (M9).
- **Alignment test:** force an access onto a busy odd slot; assert a 2-clock wait, then that back-to-back cycles land on even slots.
- **SDRAM model:** run against a Winbond/Micron SDRAM simulation model with timing checks on, at the -75 timings.
- **Refresh:** assert that no SDRAM row goes unrefreshed for 64 ms (counter check in simulation).
