# Spec 5: Memory architecture and DMA arbitration

Status: **draft for review**

This spec describes how the CPU, video, audio and the other DMA engines share the KS3's fast SRAM. It follows the Amiga's model: memory time is cut into fixed **slots**, the CPU has its own share of every slot, DMA has the rest, and each DMA engine owns fixed cycles in every scan line, so its bandwidth is guaranteed.

The SRAM is fast enough to give the CPU its own memory cycle in **every** slot, so the CPU never waits for the display, audio, copper or normal DMA, and there is no even/odd alignment to keep.

## 1. Summary

| Item | Value |
|------|-------|
| Memory | One IS61WV204816BLL-10 SRAM on the KS3: 2M × 16 bit (4 MB), 10 ns. Some boards may have 2 MB; SYSCFG.CHIPMB reports which |
| Memory cycle | 20 ns = 2 clocks at 100 MHz: one 16-bit read or write at any address (byte writes with /UB and /LB) |
| Slot | 100 ns = 5 memory cycles (numbered 0–4) = 2 CPU clocks at 20 MHz |
| CPU | Cycle 0 of every slot. Never waits, except when a HIGH DMA job or an urgent sprite or copper fetch borrows it |
| DMA | Cycles 1–4: display fetch, audio, peripherals, then a free pool for sprites, copper and the DMA engine. Also cycle 0 whenever the CPU isn't using it |
| Beam lock | Every scan line is a whole number of slots; the slot counter restarts each line, so DMA happens at the same beam positions on every line |
| Total bandwidth | 100 MB/s (5 × 2 bytes per 100 ns) |
| Refresh | None needed (SRAM) |

## 2. Memory types (Amiga naming)

| Name | Where | Who can access it |
|------|-------|-------------------|
| **Chip RAM** | The 4 MB SRAM | CPU and every DMA engine |
| **Block RAM** | Inside the FPGA: boot ROM, text screen, font, palette, sprite table, descriptor RAM, FIFOs | CPU through registers/windows; never uses SRAM cycles |

There is no Fast RAM: all RAM is Chip RAM, and the CPU gets it at full speed anyway. On the Amiga, Chip RAM was slowed by display modes that stole CPU cycles; here the display never takes the CPU's cycle.

## 3. Memory map

The full map is in spec 3, section 1. Memory in short:

| Range | Size | Device |
|-------|------|--------|
| `0x000000`–`0x3FFFFF` | 4 MB | Chip RAM (2 MB boards: `0x000000`–`0x1FFFFF`). At reset the boot ROM overlays address 0 for reads |
| `0x400000`–`0xDFFFFF` | | Reserved (bus error) |
| `0xE00000`–`0xE13FFF` | | Custom registers, palette, sprite table, descriptor RAM, text screen, font (block RAM) |
| `0xF00000`–`0xF0FFFF` | | System registers |
| `0xF80000`–`0xF87FFF` | 32 KB | Boot ROM |

- **DMA addresses are the same as CPU addresses** (24-bit). Video, audio, sprites, copper and the DMA engine can all use the whole of Chip RAM.
- **Reset overlay:** after reset the ROM also appears at `0x000000` for CPU reads (writes go to Chip RAM), so the CPU can fetch its stack pointer and start address. The ROM code runs at its real address at `0xF80000`, builds the vector table in RAM, then turns the overlay off (spec 7, section 3).

## 4. Memory cycles and slots

### 4.1 Clocks

Everything comes from one 200 MHz master clock divided by whole numbers (spec 4, section 3.1):

| Clock | Master ÷ | Frequency |
|-------|----------|-----------|
| System / SRAM controller | 2 | 100 MHz |
| fx68k master clock | 5 | 40 MHz with alternating phase enables → **20 MHz 68000** |
| Memory cycle | 4 | 20 ns |
| Slot | 20 | 100 ns = 5 memory cycles |
| Pixel clock | N = 3–8 | 66.7–25 MHz |

The video timing rule (HTOTAL × N a multiple of 20) makes every scan line a whole number of slots. The slot counter `hslot` restarts at 0 at the start of every line.

### 4.2 One memory cycle

The SRAM is asynchronous: give it an address and it answers within 10 ns. With the FPGA's pin delays, a safe access takes **2 clocks (20 ns)**:

| | Clock 0 (0 ns) | Clock 1 (10 ns) | End (20 ns) |
|---|---|---|---|
| **Read** | Address, /CS, /OE and byte selects out | SRAM drives data | Data captured |
| **Write** | Address, data and byte selects out | /WE pulsed low for about 8–10 ns (timed with the 200 MHz master) | Write done |

- Any address, any mix of reads and writes, back to back: there are no rows, banks or bursts to worry about.
- Between a read and a following write, the controller releases /OE early and starts driving data half a clock later, so the SRAM and FPGA never drive the bus at the same time. No gap cycle is needed. This must be checked against the datasheet timings (tHZOE, tPWE, tSD; open point M2).
- Address, data and control outputs come from the FPGA's I/O flip-flops, so their timing is the same every cycle. Those flip-flops add one clock: a cycle issued at a cycle boundary is on the pins from 10 to 30 ns after it, and its read data is captured at 30 ns. The cycle table below is in the controller's terms.

### 4.3 Who owns each cycle

Each 100 ns slot holds 5 memory cycles:

| Cycle | Owner | Notes |
|-------|-------|-------|
| **0** | **CPU** | The Amiga's "even" cycle. If the CPU doesn't need it in this slot, it goes to the free pool |
| 1 | Display fetch | Layers (spec 4, section 5) |
| 2 | Display fetch | Layers |
| 3 | Display fetch if wide fetch is on (visible part of the line), otherwise the free pool | Version 1: the whole line while wide fetch is on |
| 4 | Fixed users in the first 38 slots of each line (from the start of horizontal blanking), otherwise the free pool | Section 7 |

### 4.4 Bandwidth

- Total: 5 cycles × 2 bytes per 100 ns = **100 MB/s**.
- CPU: a 68000 at 20 MHz makes at most one access per bus cycle (200 ns), so it uses cycle 0 in at most every other slot: up to **10 MB/s**. Its other cycle 0s go to the free pool.
- Display fetch: **40 MB/s** normally (cycles 1–2), **60 MB/s** with wide fetch (cycles 1–3).
- Free pool (sprites, copper, DMA engine, extra audio): what's left, typically 40–65 MB/s.

## 5. CPU access

A 20 MHz 68000 bus cycle takes 4 CPU clocks = 2 slots. For a cycle starting in slot *k*:

```
 slot:            k                   k+1
 state:   S0   S1   S2   S3   |  S4   S5   S6   S7
 time:    0    25   50   75   | 100  125  150  175  200 ns
 address:      valid ->
 /AS:               asserted ------------------------>
 SRAM:                        | cycle 0: read (pins 110-130)
 /DTACK:                      | asserted (110) ------>
 CPU latches read data:                      end of S6 (175 ns)
```

- A **read** uses **cycle 0 of slot k+1**. The address and R/W are known since S1–S2. Read data reaches the CPU at 160 ns, 15 ns before it latches it (spec 1, section 4.1).
- A **write** is posted: its byte strobes only appear at S4 (100 ns), so it uses **cycle 0 of slot k+2**, the first slot of the CPU's next bus cycle, where the CPU never makes its own access. /DTACK is given early, so writes have no wait states either.
- Every slot has a cycle 0, so it doesn't matter where in the slot grid a bus cycle starts: **there is no alignment to keep and no realignment wait**.
- Block RAM, registers and ROM don't use SRAM cycles at all.

**When the CPU waits** (2 clocks each time, as /DTACK is held to the next slot's cycle 0):

| Cause | When |
|-------|------|
| A HIGH DMA job (spec 11, section 5) | Only if software asks for it, and always leaving the CPU its CPUSHARE of cycles |
| An urgent sprite fetch (spec 9, section 5) | Only if a sprite would otherwise be late, which needs many large sprites at the same X with wide fetch on |
| An urgent copper fetch (spec 10, section 6) | Only if the copper's queue runs low during a very dense list |

Otherwise the CPU runs at full 20 MHz speed from Chip RAM, whatever the screen and sound are doing.

**Interrupts** stay vectored (design plan D8): the 6800-style /VPA cycle is not used.

## 6. Priority

**Cycle 0**, in order:

1. Sprite fetch, only if a sprite would otherwise miss its first pixel
2. Copper, only if its queue is less than half full (urgent)
3. DMA engine HIGH jobs, except the CPU's share (1 in 2, 1 in 4 or 1 in 8 of its cycles, set per channel)
4. **CPU**
5. Free pool (below)

**Free-pool cycles** (cycle 3 when wide fetch is off, cycle 4 outside the fixed users, cycle 0 when the CPU doesn't want it, and display cycles no layer needs), in order:

1. Sprite fetch, in its fetch window
2. Audio fetch, when a channel's sample cache is running low
3. Copper
4. DMA engine (blitter, copies, peripheral transfers)
5. Idle

## 7. Fixed allocation per line

Cycle 4 of the first **38 slots** of each line, counted from the start of horizontal blanking, belongs to fixed users. Fixed slots that run past the end of the blanking simply continue into the next line; cycle 4 is never used for display, so nothing is disturbed.

| Owner | Cycles per line | Bytes per line | Notes |
|-------|-----------------|----------------|-------|
| Audio channels | 32 | 64 | Shared by the 16 hardware channels: at least 2 MB/s (spec 6, section 4.7) |
| Audio stream | 4 | 8 | At least 250 KB/s; 48 kHz stereo needs 192 KB/s |
| Peripheral transfers | 2 | 4 | Guaranteed minimum for SD card and USB serial through the DMA engine; they normally get far more from the free pool |

If a fixed user doesn't need its cycle this line (a cache is full), the cycle goes to the free pool.

### 7.1 What each owner gets

| Owner | Needs | Gets |
|-------|-------|------|
| Display (layers) | Depends on the video mode and layers | 0.2 × N bytes per pixel normally, 0.3 × N with wide fetch (spec 4, section 5.2) |
| Audio, 16 channels of 16-bit at 48 kHz | 1.5 MB/s at normal pitch | At least 2 MB/s, plus the free pool when a cache runs low |
| Audio stream, 48 kHz 16-bit stereo | 192 KB/s | At least 250 KB/s |
| Sprites | Up to 32 bytes per sprite per line | Free pool in the 128 slots before the sprite, and cycle 0 if urgent (spec 9) |
| DMA engine | – | The rest of the free pool: about 55–65 MB/s of memory cycles at 640×480 with wide fetch off, about 40 with it on (spec 11, section 7) |

During vertical blanking there is no display fetch, so cycles 1–3 go to the free pool too.

### 7.2 No line buffers

Display data is fetched just in time into a 48-byte buffer per layer, as the Amiga fetches bitplane data into its data registers (spec 4, section 5). Nothing is stored for a whole line.

## 8. DMA control register (Amiga DMACON style)

One register, **DMACON**, at `0xE00094` (spec 3). Its 16-bit value is in the low half at `0xE00096`, the same offset as the Amiga's DMACON. Writes use set/clear:

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

## 9. Open points

| # | Item |
|---|------|
| M1 | ~~Confirm fx68k's exact bus timing in simulation~~ Done: it matches the real 68000; writes are posted (section 5) |
| M2 | Check the 20 ns read and write cycles, and read-to-write turnaround, against the IS61WV204816BLL-10 datasheet and the KS3's board timing |
| M3 | Is the KS3 fitted with 4 MB or 2 MB? Check, and test both settings |
| M4 | A faster memory cycle (e.g. 15 ns with careful pin timing) would give 6–7 cycles per slot; not needed for version 1 |

## 10. Tests

- **Cycle table:** for every video preset, check each owner gets its cycles at the same `hslot` on every line.
- **CPU zero-wait:** run fx68k from Chip RAM with all display, audio and normal DMA on; assert /DTACK is never delayed. With HIGH jobs or urgent sprites, assert every delay is exactly 2 clocks and caused by them.
- **SRAM model:** run the controller against an SRAM simulation model with the datasheet timing checks on (setup, hold, pulse widths, bus turnaround). Done in `sim/` for version 1.
- **Board test:** a full 4 MB pattern test from the CPU and from the DMA engine at once, at every video preset.
