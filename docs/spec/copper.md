# Spec 10: Copper

Status: **draft for review**

The copper is a tiny processor that follows the beam. It runs a list of instructions from Chip RAM: wait until the beam reaches a position, then write hardware registers. This changes the display part-way down (or across) the screen, with no CPU work and exact timing: split screens, colour gradients, reusing sprites lower down, changing scroll per line, starting DMA jobs at a set moment.

## 1. Summary

| Item | Value |
|------|-------|
| Program | A list of 8-byte instructions in Chip RAM, restarted every frame |
| Instructions | MOVE, MOVEN (several registers), ADD, WAIT, WAITH, SKIP, JUMP, CALL/RET, loops, IRQ, WAITDMX, STOP |
| Can write | The custom registers, palette, sprite table, text screen and font (the same areas as DMA jobs; not the system area) |
| Wait precision | One pixel, in any video mode |
| Write speed | One register write per 10 ns from its queue, so 8 writes in less than one pixel at 640×480, right after a WAIT |
| Memory use | A 64-byte prefetch queue; typically a few slots per line. Urgent only when the queue runs low |
| Frame start | The list restarts from COPLC at the start of vertical blanking, in time to set up line 0 |

## 2. Comparison with the Amiga

| Feature | Amiga copper | retro68k copper |
|---------|--------------|-----------------|
| Instructions | MOVE, WAIT, SKIP | MOVE, MOVEN, ADD, WAIT, WAITH, SKIP, JUMP, CALL/RET, loops, IRQ, WAITDMX, STOP |
| Register writes | 16-bit, one per 4 lores pixels at best | 32-bit, up to 8 back to back in under a pixel after a WAIT |
| Wait precision | 4 lores pixels across, 1 line down | 1 pixel, 1 line |
| Loops | Only by SKIP tricks | Two loop counters, subroutines |
| Gradients | One MOVE per line with a new value each time | ADD changes a register by a fixed amount, so a gradient is a 3-instruction loop |
| Wait for the blitter | WAIT's blitter-finished bit | WAITDMX: wait for chosen DMA engine channels |
| Lists | COP1LC restarted each frame, COP2LC by strobe | COPLC each frame; JUMP and CALL anywhere |

## 3. Beam position and frame order

- The copper compares against `vline` and `hpixel` (spec 4, section 3.6). It checks every 100 MHz clock, so it can hit any pixel.
- **Frame order:** each frame's list starts at the beginning of vertical blanking (`vline` = VVISIBLE). The copper therefore sees the lines in this order: the blanking lines VVISIBLE … VTOTAL−1 first, then the visible lines 0 … VVISIBLE−1. WAIT and SKIP compare positions in this order. Software still writes real line numbers. For example, in a 640×480 @ 60 frame, WAIT 500,0 comes before WAIT 0,0.
- This gives the copper all of vertical blanking to set up the first visible line, which needs its layer registers written before line −1, in other words during blanking (spec 4, section 5.6), and its sprites before line 0's selection point (spec 9, section 5.1).

## 4. Instructions

Every instruction is 8 bytes: two 32-bit words, **W0** and **W1**, in Chip RAM, 8-byte aligned. The top 4 bits of W0 are the opcode.

| Opcode | Name | W0 | W1 | Does |
|--------|------|----|----|------|
| 0 | MOVE | reg 15–0 | value | Write value to the register at offset reg |
| 1 | MOVEN | count 27–16, reg 15–0 | first value | Write `count` values to `count` consecutive registers (4 bytes apart). The values follow: W1, then the next words, padded to a multiple of 8 bytes |
| 2 | ADD | reg 15–0 | delta | register = register + delta (wraps round). For gradients and steady changes |
| 3 | WAIT | v 26–16, h 10–0 | – | Wait until the beam is at or past (v, h) in frame order |
| 4 | WAITH | h 10–0 | – | Wait until the next time the beam reaches pixel h: on this line if not yet passed, otherwise on the next line |
| 5 | SKIP | v 26–16, h 10–0 | – | Skip the next instruction if the beam is at or past (v, h) |
| 6 | JUMP | – | address | Continue at address |
| 7 | CALL | – | address | Continue at address; remember the return point (up to 4 deep) |
| 8 | RET | – | – | Return from CALL |
| 9 | SETC | counter 0 | n | Set loop counter 0 or 1 to n |
| 10 | DBNZ | counter 0 | address | Decrease the counter; if it is not 0, continue at address |
| 11 | IRQ | – | – | Raise the copper interrupt |
| 12 | WAITDMX | channels 3–0 | – | Wait until the chosen DMA engine channels are idle |
| 15 | STOP | – | – | Do nothing more until the next frame |

Opcodes 13 and 14 are reserved. An unknown opcode, a misaligned list, or a register outside the allowed areas stops the copper and sets ERR (section 7).

**Register writes** have exactly the same effect as CPU writes, including their timing rules (layers latch before each line, sprites at their selection and fetch points, palette at once). The copper can write to the same areas as DMA jobs (spec 11, section 4): the custom registers, palette, sprite table, descriptor RAM, text screen and font. It cannot write the system area (interrupts, timers, serial).

## 5. Timing

- **Execution:** the copper runs one instruction per 100 MHz clock (10 ns) while its queue has instructions. That is less than half a pixel at 640×480.
- **After a WAIT:** the queue had the whole wait to fill, so up to **8 instructions** run back to back straight after the WAIT, always with the same timing.
- **Palette changes mid-line:** a palette write takes effect at a fixed number of pixels after the WAIT that comes before it. The exact delay (a few pixels) depends on the pixel pipeline and will be given per video mode in the register map. It never changes, so colour bars and split colours line up the same way every time.
- **Long runs:** more than 8 instructions in a row are limited by fetching: about 1.5 instructions per memory slot when the copper is urgent.

## 6. Memory slots

The copper reads its list in 12-byte bursts into a **64-byte prefetch queue** (8 instructions).

- **Normally** it uses spare slots, after the CPU, sprites and audio and before the DMA engine (spec 5, section 6). Most lists need only a few slots per line.
- **When the queue is less than half full,** the copper becomes **urgent** and goes ahead of the CPU, in odd and even slots. This keeps its timing exact even when the CPU is busy in Chip RAM or wide fetch has taken the spare odd slots. Each slot it takes from the CPU costs the CPU 2 clocks, as for sprites.
- A dense list (dozens of instructions per line) can slow the CPU a little, as the copper could on the Amiga. A typical list (a WAIT and a few MOVEs on some lines) costs the CPU almost nothing.
- While waiting with a full queue, the copper uses no slots.

## 7. Registers

Offsets in the custom register block at `0xE00000`. Spec 3 sets the final addresses.

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x700` | COPCON | EN (0) | Copper on (DMACON.COPEN must also be set) |
| `0x704` | COPLC | 22–0 | Start of the list, used from the next frame. Writing it switches lists cleanly at the frame boundary |
| `0x708` | COPJMP | – | Write: restart at COPLC now, without waiting for the next frame |
| `0x70C` | COPPC | 22–0 | Read: address of the instruction being run |
| `0x710` | COPSTAT | WAITING (0), STOPPED (1), ERR (2) | ERR is sticky, write 1 to clear |
| `0x714` | COPERR | 22–0 | Address of the instruction that caused an error |

**Interrupts:** the IRQ instruction and ERR raise the video interrupt (level 5) through a COPIRQ flag in VIDSTAT (bit 13) with its enable in VIDINTEN. Interrupts are vectored, so it can have its own handler.

**Double-buffered lists:** software builds next frame's list in a second buffer and writes its address to COPLC. The copper switches at the start of the next vertical blanking, so a half-built list is never run.

## 8. Examples

**Split screen:** a different picture below line 300.

```
        WAIT  299, 0               ; during line 299, before line 300's latch
        MOVE  L0.PTR, picture2
        STOP
```

(Layer registers latch at the start of horizontal blanking before each line, spec 4, section 5.6. Writing during line 299 changes line 300.)

**Sky gradient:** background colour gets 1 step bluer on each of 200 lines.

```
        MOVE  BGCOLOR, 0x000020
        SETC  0, 200
loop:   WAITH 0                    ; start of the next line
        ADD   BGCOLOR, 0x000001
        DBNZ  0, loop
        STOP
```

**Colour bar across part of a line:**

```
        WAIT  100, 200
        MOVE  PALETTE+4, 0xFF0000  ; colour 1 turns red from about pixel 200
        WAIT  100, 400
        MOVE  PALETTE+4, 0x0000FF  ; blue from about pixel 400
```

**Reusing a sprite lower down** (more than 64 sprites per frame): sprite 5 is shown on lines 100–240, then again from line 245 with a different image. The new values must be written after the old sprite's last fetch (on line 240) and before the new sprite's selection point for line 245, which is during line 244 (spec 9, section 5.1). Leaving a few lines' gap makes that easy:

```
        WAIT  242, 0
        MOVEN 3, SPR5.POS          ; POS, PTR, SIZE of table entry 5
              (x, y=245), image2, size2
```

**Start a DMA job at a set moment,** for example redrawing a status bar right after the beam has passed it:

```
        WAIT  40, 0
        MOVE  DMX2.CHDESC, statusbar_job
        MOVE  DMX2.CHCTRL, START
```

## 9. FPGA resources

| Item | Resource |
|------|----------|
| Prefetch queue (64 bytes), call stack, 2 counters | Logic |
| Decoder, beam compare, register-bus writer | Estimate 400–700 LUTs |
| Block RAM | None |

## 10. Open points

| # | Item |
|---|------|
| C1 | Indirect moves from a table in Chip RAM (e.g. a different palette value per line from a list), if ADD is not enough |
| C2 | The exact pixel delay for palette and BGCOLOR writes after a WAIT, per video mode |
| C3 | Whether a second copper (e.g. one for the display, one for sprites) would be useful |
| C4 | WAIT masks (as on the Amiga) for repeating patterns; loops may already cover this |

## 11. Tests

- **Frame order:** WAITs in the blanking lines run before WAITs on visible lines; the list restarts at each vertical blanking.
- **Precision:** WAIT on many (v, h) positions in every video preset; a palette write lands on the same pixel every frame.
- **Latching:** a layer write during line L−1 changes line L; a sprite write before the selection point changes that line.
- **Instructions:** every opcode, MOVEN with odd counts and padding, ADD wrap, nested CALL to depth 4, both counters, SKIP before and after its position.
- **Errors:** unknown opcode, a write to the system area, deeper than 4 calls: the copper stops, ERR and COPERR set, interrupt raised.
- **Busy system:** with the CPU flat out in Chip RAM and wide fetch on, a list with 8 writes after each WAIT still keeps exact timing; measure the CPU slots taken.
- **COPLC switch:** changing COPLC mid-frame takes effect only at the next vertical blanking.
