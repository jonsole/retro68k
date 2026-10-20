# Spec 13: Interrupt controller

Status: **draft for review**

The interrupt controller gathers every interrupt request in the machine and passes them to the 68000. Each source gets **its own vector**, so the CPU jumps straight to the right handler with no need to work out who interrupted. Each source's **priority level** can be changed. The controller lives in the **system area** at `0xF00000`, so DMA jobs and the copper cannot change it.

## 1. Summary

| Item | Value |
|------|-------|
| Sources | 24, plus NMI |
| Vectors | One per source: vector = VECBASE + source number (default VECBASE = 64, the first 68000 user vector) |
| Levels | Each source can be set to level 1–6, or 0 (off). Defaults follow the design plan |
| NMI (level 7) | The NMI button, and a "break" request from the USB host |
| Within a level | Lower source number goes first |
| Software interrupt | The CPU can raise one for itself, to do work later at a lower priority |
| Spurious requests | Handled with the 68000's spurious-interrupt vector (24) |

## 2. Comparison with the Amiga (Paula)

| Feature | Amiga | retro68k |
|---------|-------|----------|
| Sources | 14 | 24 + NMI |
| Vectors | Autovectored: one vector per level; the handler reads INTREQR to find the source | One vector per source |
| Levels | Fixed per source | Programmable per source |
| Masking | INTENA, with a master bit | INTENA, with a master bit |
| Software interrupt | SOFTINT | SOFTINT |
| NMI | Level 7, rarely used | Button and USB "break", for a debug monitor |

## 3. How an interrupt reaches the CPU

1. A unit (video, audio, DMA engine, timer…) sets a status flag. If that flag's enable is on in the unit, the unit raises its **request line** to the controller. Each unit keeps its own flags and enables, as described in its spec.
2. If the source is enabled in **INTENA** and the master enable is on, the request is **pending**.
3. The controller finds the highest level with a pending source and drives the 68000's IPL lines with that level.
4. When the CPU's interrupt mask allows it, the 68000 runs an **interrupt-acknowledge cycle** for that level. The controller answers with the vector of the pending source at that level with the lowest source number, and asserts /DTACK. This is a normal internal bus cycle, with no SDRAM slot and no wait states, so it never knocks the CPU off its slot grid (spec 5, section 5).
5. The handler clears the cause in the unit (usually by writing 1 to the unit's sticky flag). The request drops. If another source at the same level is still pending, the CPU is interrupted again straight after the handler returns.

Requests are **level-sensitive**: a source stays pending until its unit's flag is cleared, so no interrupt is ever lost.

**Spurious interrupt:** if a request disappears between steps 3 and 4 (for example, the CPU cleared the flag itself), the controller answers with vector 24, the 68000's spurious-interrupt vector. Its handler can simply return.

**Response time:** the 68000 checks for interrupts between instructions, then takes 44 clocks to start the handler. At 20 MHz that is 2.2 µs plus the rest of the current instruction (at most about 8 µs, for a long divide).

## 4. Sources

| Source | Vector (default) | Name | From | Default level |
|--------|------------------|------|------|---------------|
| 0 | 64 | VBLANK | Video: start of vertical blanking (VIDSTAT.VBLANK) | 5 |
| 1 | 65 | LINE | Video: line compare (VIDSTAT.LINE) | 5 |
| 2 | 66 | COPPER | Copper IRQ instruction or error (VIDSTAT.COPIRQ) | 5 |
| 3 | 67 | VIDERR | Video problems: OVERRUN, SPRMISS, SPROVF, BADTIMING | 5 |
| 4 | 68 | DMA0 | DMA engine channel 0 (DMXINT bit 0) | 4 |
| 5 | 69 | DMA1 | DMA engine channel 1 | 4 |
| 6 | 70 | DMA2 | DMA engine channel 2 | 4 |
| 7 | 71 | DMA3 | DMA engine channel 3 | 4 |
| 8 | 72 | AUDSTR | Audio stream: half-way or end (AUDSTAT.STRHALF, STREND) | 4 |
| 9 | 73 | AUDCH | Audio channel ended or looped (AUDCHEND) | 4 |
| 10 | 74 | AUDERR | Audio STARVED | 4 |
| 11 | 75 | TIMER0 | Timer 0 underflow | 6 |
| 12 | 76 | TIMER1 | Timer 1 underflow | 6 |
| 13 | 77 | TIMER2 | Timer 2 underflow | 6 |
| 14 | 78 | TIMER3 | Timer 3 underflow | 6 |
| 15 | 79 | SERIAL | USB serial: data received, or room to send | 3 |
| 16 | 80 | SD | SD card: transfer done or card inserted/removed | 2 |
| 17 | 81 | KEYB | Keyboard: key event | 2 |
| 18 | 82 | SOFT | Software interrupt (SOFTINT) | 1 |
| 19–23 | 83–87 | – | Reserved (e.g. GPIO pins on the headers, the CPU board) | 0 (off) |

The video flags that share one source (VIDERR) and the audio flags (AUDSTR, AUDCH) are told apart by reading the unit's status register in the handler.

**Choosing levels:** the defaults put timers highest (an operating system tick should not be held up by graphics), then video (VBLANK and LINE handlers have to run on time for smooth animation), then audio and DMA, serial, and the slow devices. Software can change any of them, for example raising LINE to level 6 for precise raster effects.

## 5. NMI (level 7)

Level 7 cannot be masked by the 68000. It is kept for getting control back from a hung or misbehaving program:

- **NMI button:** a button on a spare header pin, debounced in the FPGA.
- **USB break:** a "break" request from the computer at the other end of the USB link (spec 7), so a debug monitor on the PC can stop the 68000 at any moment.

Both use vector 31, the 68000's usual level 7 vector; the controller supplies it during the acknowledge like any other vector. NMISTAT says which one it was. NMIEN can turn each off, for example so the USB break only works while debugging. NMI is edge-triggered on the 68000, so each press or break gives exactly one interrupt.

## 6. Software interrupt

Writing SOFTINT.SET raises source 18; writing SOFTINT.CLR clears it. A typical use: a high-priority handler (e.g. VBLANK) does the urgent part and raises the software interrupt to do the rest at level 1, once nothing more important is waiting. This is the Amiga's SOFTINT idea.

## 7. Registers

In the system area at `0xF00000`. Spec 3 sets the final addresses. All registers are 32-bit and follow the 16-bit-halves rule (spec 10, section 4.1).

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x000` | INTCON | MASTER (0) | All interrupts (except NMI) on/off. Off after reset |
| `0x004` | INTENA | 23–0 | Enable per source. All off after reset |
| `0x008` | INTPEND | 23–0 | Read: sources pending (requesting and enabled) |
| `0x00C` | INTRAW | 23–0 | Read: sources requesting, before INTENA |
| `0x010` | INTLEVEL0 | 8 × 4 bits | Levels of sources 0–7: source n in bits 4n+2 … 4n (0 = off, 1–6) |
| `0x014` | INTLEVEL1 | 8 × 4 bits | Sources 8–15 |
| `0x018` | INTLEVEL2 | 8 × 4 bits | Sources 16–23 |
| `0x01C` | VECBASE | 7–0 | First vector (64–232, default 64). Source n uses VECBASE + n |
| `0x020` | SOFTINT | SET (0), CLR (1) | Write 1 to raise or clear the software interrupt |
| `0x024` | LASTSRC | 4–0 | Read: the source given at the last interrupt acknowledge, for debugging |
| `0x028` | NMICON | BUTTONEN (0), USBEN (1) | Enable each NMI source. Both on after reset |
| `0x02C` | NMISTAT | BUTTON (0), USB (1) | Which caused the last NMI; sticky, write 1 to clear |

After reset everything except NMI is off, so the boot ROM can set up its vector table (in RAM, once the ROM overlay is off) before enabling anything.

## 8. FPGA resources

| Item | Resource |
|------|----------|
| 24-source priority encoder, level table, vector logic, NMI debounce | Estimate 200–300 LUTs |
| Block RAM, DSP | None |

## 9. Open points

| # | Item |
|---|------|
| I1 | Which header pins carry the NMI button and any GPIO interrupts (spec 7) |
| I2 | Whether the USB break should also be able to reset the machine (a "hard break") |
| I3 | Use of the reserved sources 19–23 |

## 10. Tests

- **Vectors and levels:** every source gives VECBASE + n at its set level; changing a level takes effect at once.
- **Priority:** several sources at one level are served lowest number first; a higher level interrupts a running lower-level handler.
- **Masking:** INTENA, the master bit, and the 68000's own mask each block interrupts as expected; nothing is lost while blocked.
- **Spurious:** a request withdrawn before the acknowledge gives vector 24.
- **NMI:** button and USB break each give exactly one interrupt per event, set NMISTAT, and can be turned off.
- **SOFTINT:** set, clear, and runs only after higher-level handlers finish.
- **Alignment:** interrupt-acknowledge cycles never add wait states or knock the CPU off its slot grid.
