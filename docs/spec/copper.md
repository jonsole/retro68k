# Spec 10: Copper

Status: **v1 scope**

## 1. Summary

The copper is a small coprocessor that follows the beam, as on the Amiga: it runs a list of instructions from Chip RAM every frame and writes custom registers at chosen beam positions. It changes colours partway down the screen, resets the bitplane pointers for each frame, opens split screens, and so on, without the CPU.

| Item | Value |
|------|-------|
| Program | A list of 32-bit instructions in Chip RAM, restarted from COP1LC at the start of every vertical blank |
| Instructions | MOVE, WAIT, SKIP (as the Amiga), plus JUMP and STOP |
| Can write | The custom register block only (`0xE00000`–`0xE07FFF`): all video, DMA and copper registers and the palette. Not the system block |
| Beam position | Full range (11-bit line and pixel), pixel exact |
| Memory | Its own DMA channel in the scheduler (spec 5, section 6): best effort, cycle 4 and any cycle nobody else wants |
| Prefetch | The next instruction, so the MOVE after a WAIT runs as soon as the WAIT is over |
| Interrupt | A MOVE to COPINT raises the copper's interrupt (source COPPER) |

## 2. Comparison with the Amiga

| | Amiga | retro68k v1 |
|--|-------|-------------|
| Instructions | MOVE, WAIT, SKIP, 32 bits each | The same, plus JUMP and STOP |
| MOVE | 16-bit data to a custom register | The same: 16-bit data to a register half; a 32-bit register (a BPLxPT) takes two MOVEs, high half first |
| WAIT/SKIP position | 8-bit line (wraps after line 255), horizontal in steps of 4 low-resolution pixels, with compare masks | 11-bit line and pixel, pixel exact. No masks: a **pixel-only** WAIT repeats an effect on every line |
| Waiting for the blitter | BFD bit in WAIT | The same: the BLT bit waits until the DMA engine is idle too |
| Lists | COP1LC, COP2LC; strobes COPJMP1, COPJMP2; list 1 restarts each frame | The same |
| Jumping | A MOVE to COPJMP2 | JUMP to any address; the strobes still work |
| End of list | WAIT for an impossible position ($FFFFFFFE) | STOP (the Amiga way works too) |
| Interrupt | A MOVE to INTREQ | A MOVE to COPINT |
| Protection | CDANG guards the low registers | The copper can't reach the system block at all |
| Speed | One instruction per 8 low-resolution pixels or so | Waits are pixel exact; a MOVE after a WAIT is prefetched |

## 3. Frame order

The list restarts from COP1LC at the start of each **vertical blank**, line 576, so its writes for the coming picture (plane pointers, colours) land before that picture's first line is fetched. Beam positions in WAIT and SKIP therefore count in **frame order**: lines 576–624 (the vertical blank) come first, then lines 0–575 of the picture.

- A WAIT for a picture line (0–575) waits for that line of the coming picture.
- A WAIT for a blanking line (576–624) waits in the blank before it.
- A position the beam has already passed in this frame satisfies a WAIT at once and makes a SKIP skip.

## 4. Instructions

Every instruction is 32 bits, at a 4-byte-aligned address. Bit 31 says which kind:

```
 MOVE   0 | register offset (30-16, even)          | data (15-0)
 WAIT   1 | 000 | P | line (26-16)        | B | 0000 | pixel (10-0)
 SKIP   1 | 001 | P | line (26-16)        | 0 | 0000 | pixel (10-0)
 JUMP   1 | 010 | 0000 0 | address (22-2), bits 1-0 = 0
 STOP   1 | 011 | 0 ...
```

| Instruction | Does |
|-------------|------|
| **MOVE** | Writes the 16-bit data to the register half at that byte offset in the custom block (`0xE00000` + offset). An offset with bit 1 clear is a high half, with bit 1 set a low half. The copper follows the halves rule (spec 3, section 2) with its own latch: a high-half write is held until its low half follows, so a 32-bit register is written whole. 16-bit registers (palette entries' halves, BPLxDAT, BPLMOD, DMACON) need one MOVE, to their low half |
| **WAIT** | Waits until the beam has reached the position (frame order, section 3). With **P** set (pixel only), the line is ignored: it waits until the pixel position is reached on the current line, or on the next line if it has already passed. With **B** set, it also waits until the DMA engine (spec 11) is idle |
| **SKIP** | If the beam has reached the position, skips the next instruction. With P set, compares the pixel position only |
| **JUMP** | Continues at the address |
| **STOP** | Stops until the next frame (or a COPJMP strobe). A WAIT for line 2047 does the same, as on the Amiga |

Unused bit patterns are reserved; the copper treats them as STOP and sets COPSTAT.ERR.

**Loops:** SKIP and JUMP make loops that end at a beam position. For example, to repeat a block of MOVEs on every line until line 400: `loop: WAIT P 0, 0` … MOVEs … `SKIP 400, 0` / `JUMP loop`.

## 5. Timing

- **Beam position:** the copper compares against the beam position seen on the memory side (spec 4, section 3.1), a few clocks behind the pixel clock. A WAIT ends within about one pixel of its position.
- **MOVE after a WAIT:** the next instruction is already fetched, so the write happens 10–20 ns after the WAIT ends. Writes that follow need their own fetches.
- **Fetches:** each instruction is two 16-bit words. The copper's channel is best effort: cycle 4 of every slot, plus any cycle nobody else wants (spec 5, section 6), so at least 20 MB/s: one instruction every 200 ns or better, about 5 pixels at 576p, and much faster in the blanking.
- **When writes take effect:** as for the CPU (spec 4, section 5.4): the palette at once (a colour change shows within about 1–2 pixels of the WAIT position), layer settings from the next line, BPLxPT, BPLMOD and BPLxDAT at once.
- **Register bus:** the copper and the CPU share the register bus; the copper goes first, so a CPU register access may wait one clock.

## 6. Registers

Offsets in the custom register block at `0xE00000`.

| Offset | Name | Access | Bits | Description |
|--------|------|--------|------|-------------|
| `0x700` | COPCON | RW | EN (0), IRQEN (1) | Copper on (DMACON.DMAEN and COPEN must also be set); COPINT raises the interrupt |
| `0x704` | COP1LC | RW | 22–2 | First list: restarted at every vertical blank |
| `0x708` | COP2LC | RW | 22–2 | Second list |
| `0x70C` | COPJMP1 | W | – | Strobe: restart at COP1LC now |
| `0x710` | COPJMP2 | W | – | Strobe: continue at COP2LC now |
| `0x714` | COPPC | R | 22–2 | The instruction being run |
| `0x718` | COPSTAT | RW1C | WAITING (0), STOPPED (1), ERR (2), IRQ (3) | ERR (a reserved instruction) and IRQ (set by COPINT) are sticky: write 1 to clear |
| `0x71C` | COPINT | W | – | Strobe: sets COPSTAT.IRQ. Meant to be written by the copper itself |

**Interrupt:** source COPPER (2) in the interrupt controller (spec 13) is COPSTAT.IRQ with COPCON.IRQEN, with its own vector. The handler clears it by writing 1 to COPSTAT.IRQ.

**Double-buffered lists:** build next frame's list in a second buffer, then write its address to COP1LC. The copper picks it up at the next vertical blank, so a half-built list is never run.

## 7. Examples

Resetting a 4-plane layer's pointers each frame and making a colour bar on lines 100–107 (`L1`, `BPLxPT` and `PALETTE` as in `hw.inc`):

```
    MOVE  L1+L_BPL0PT,   picture>>16          ; high half (held) ...
    MOVE  L1+L_BPL0PT+2, picture & $FFFF      ; ... low half: BPL0PT written whole
    ...                                       ; the same for BPL1PT-BPL3PT
    WAIT  100, 0
    MOVE  PALETTE,   $00FF                    ; colour 0, high half: red = $FF (held) ...
    MOVE  PALETTE+2, $0000                    ; ... low half: green, blue = 0: colour 0 is red
    WAIT  108, 0
    MOVE  PALETTE,   $0000                    ; back to black
    MOVE  PALETTE+2, $0000
    STOP
```

A palette entry is a 32-bit register (`0x00RRGGBB`), so a colour change is two MOVEs: the high half (red) first, then the low half (green and blue), which writes the entry at once. To change only green and blue, one MOVE to the low half is enough: the held high half is the entry's current value.

A per-line effect without unrolling (a raster bar that moves one colour per line), using a pixel-only WAIT and a loop:

```
    WAIT  50, 0
loop:
    WAIT  P 0, 700                            ; near the end of every line
    MOVE  BGCOLOR+2, ...                      ; next line's background
    SKIP  300, 0                              ; past line 300: leave the loop
    JUMP  loop
    STOP
```

The assembler macros for these (`CMOVE`, `CWAIT`, `CSKIP`, `CJUMP`, `CSTOP`) are in `firmware/include/copper.inc`.

## 8. FPGA resources

| Item | Resource |
|------|----------|
| Program counter, one prefetched instruction, the high-half latch, beam compare | Logic, about 300–400 LUTs |

## 9. Open points

| # | Item |
|---|------|
| C1 | Whether a 32-bit MOVEL (an 8-byte instruction) is worth adding, to set a pointer in one instruction |
| C2 | Exact pixel delay from a WAIT to a palette change, measured on the board |

## 10. Tests

- **Golden images:** copper lists that change colours mid-line and per line, reset plane pointers, and open a split screen (new BPLxPT at a line), compared with the Python video model extended with a copper model.
- **Frame order:** WAITs on blanking lines and picture lines; SKIP and JUMP loops ending at a line.
- **Halves:** a 32-bit register written by two MOVEs is never seen half-written; the CPU's own halves are not disturbed.
- **Strobes and lists:** COPJMP1/2 and COP1LC double buffering.
- **COPINT:** raises the interrupt once per write.

## 11. Later versions

- MOVEL (open point C1), CALL/RET, an ADD instruction
- WAIT with compare masks, if anything needs them
- A second copper
