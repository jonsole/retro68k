# Spec 16: Keyboard

Status: **draft for review**

The KS3 has two keyboards: any **PS/2 keyboard** plugged into its PS/2 socket, and the Next's own **Spectrum keyboard** (a membrane key matrix). The FPGA turns both into the same simple **key events**, keeps one **map of which keys are held down**, and can send commands to the PS/2 keyboard (for example to set its lights). Software sees one keyboard, whichever is used.

Mouse, joysticks and other inputs are to be added later (open point K5).

## 1. Summary

| Item | Value |
|------|-------|
| Keyboard | Any PS/2 keyboard (scan code set 2, the default) |
| PS/2 connection | The KS3's PS/2 socket. 5 V power and level shifting are on the board, so no adapter is needed |
| Spectrum keyboard | The Next's built-in membrane keyboard, an 8 × 7 matrix scanned by the FPGA. Its keys are reported as the equivalent PS/2 keys |
| Events | Key number (0–511) plus pressed/released, in a 16-event FIFO. The hardware handles PS/2's prefix bytes |
| Key map | 512 bits, one per key, showing which keys are held down right now |
| Raw mode | Software can get the keyboard's bytes unchanged instead |
| Sending | Commands to the keyboard (lights, repeat rate, reset), with the keyboard's acknowledge handled in hardware |
| Reset keys | Ctrl + Alt + Delete on a PS/2 keyboard can reset the computer in hardware, even if software has hung (can be turned off). The KS3's reset button always resets |
| Interrupt | Source KEYB (17) in the interrupt controller |

## 2. Connections

| Keyboard | FPGA pins | Notes |
|----------|-----------|-------|
| PS/2 keyboard | `ps2_clk`, `ps2_data` | Level shifting and 5 V are on the KS3 |
| Spectrum keyboard | `keyb_row_o` (8 rows, outputs), `keyb_col_i` (7 columns, inputs) | The membrane matrix |
| PS/2 mouse | `ps2_pin6` (clock), `ps2_pin2` (data) | Same socket, for a Y-splitter. Later (open point K5) |

## 3. How it works

### 3.1 Receiving (PS/2)

The keyboard sends 11-bit frames (start bit, 8 data bits, odd parity, stop bit) on its own clock of about 10–17 kHz. The controller samples the lines at 100 MHz, checks parity and framing, and passes good bytes to the decoder. A bad byte sets an error flag; the controller then asks the keyboard to send it again (the PS/2 "resend" command, `0xFE`).

### 3.2 Decoding into key events (PS/2)

PS/2 scan codes are awkward: a released key is sent as `F0` then its code; many keys have an `E0` prefix; Pause sends an 8-byte sequence; Print Screen and some others add "fake shift" codes. The decoder hides all of this:

| Keyboard sends | Event |
|----------------|-------|
| `1C` | Key `0x01C` (A) pressed |
| `F0 1C` | Key `0x01C` released |
| `E0 75` | Key `0x175` (cursor up) pressed: `E0` keys get `0x100` added |
| `E0 F0 75` | Key `0x175` released |
| `E1 14 77 E1 F0 14 F0 77` | Key `0x1FF` (Pause) pressed. Pause has no release |
| `E0 12`, `E0 59` (fake shifts) | Ignored |

Each event is 16 bits: **RELEASED** (bit 15) and the **key number** (bits 8–0). The key numbers are PS/2 scan code set 2 numbers, so the Spectrum keyboard (3.3) uses them too. Software turns key numbers into characters with a keyboard layout table (UK, US and others; the boot ROM will include a few).

Replies from the keyboard (`FA` acknowledge, `AA` self-test passed, `EE` echo, `FE` resend, errors) are not key events. They go to KBREPLY.

### 3.3 Spectrum keyboard

The Next's membrane keyboard is a matrix of 8 rows and 7 columns. Columns 0–4 hold the 40 keys of the original Spectrum; columns 5–6 hold the Next's extra keys.

- **Scanning:** the controller drives one row low at a time and reads the 7 columns. A full scan of all 8 rows takes 1 ms.
- **Debouncing:** a key must read the same for 5 ms (5 scans) before it counts as pressed or released.
- **Ghosting:** with no diodes in the matrix, three keys pressed at the corners of a rectangle make a fourth look pressed. The controller ignores a new key that would complete such a rectangle, as most matrix keyboards do.
- **Key events:** each key is reported with the **PS/2 key number of the equivalent key**, through the same event FIFO and key map as the PS/2 keyboard. Examples:

| Spectrum key | Reported as | Key number |
|--------------|-------------|------------|
| A … Z | The same letter | e.g. A = `0x01C` |
| 0 … 9 | The same digit | e.g. 1 = `0x016` |
| ENTER | Enter | `0x05A` |
| SPACE | Space | `0x029` |
| CAPS SHIFT | Left Shift | `0x012` |
| SYMBOL SHIFT | Right Ctrl | `0x114` |
| BREAK (Next) | Escape | `0x076` |
| DELETE (Next) | Backspace | `0x066` |
| Cursor keys (Next) | Cursor keys | `0x16B`, `0x174`, `0x175`, `0x172` |
| Other Next keys (EDIT, GRAPH, EXTEND …) | Unused key numbers | `0x0F0` upwards |

The full table is a small ROM in the controller; the exact list of Next extra keys and their matrix positions is open point K6.

- Software can't tell which keyboard a key came from, and doesn't need to. A program that wants the Spectrum's own symbol-shift combinations reads the Right Ctrl key as SYMBOL SHIFT.
- **KBCON.MATRIX** turns scanning on and off. It is on after reset.
- Both keyboards can be used at once; the key map shows a key as down if it is held on either.

### 3.4 Key map

The controller keeps 512 bits, one per key number, set while the key is held down. Games can check any key at any time without handling events, as on the Amiga or Atari ST keyboard matrix. The map is cleared when the keyboard resets (`AA`) or when the controller is turned off, so no key stays stuck.

### 3.5 Sending commands (PS/2)

Software writes a byte to KBSEND. The controller does the PS/2 "request to send" (holds CLK low for 100 µs, then DATA low), lets the keyboard clock the byte in, and waits for the keyboard's `FA` acknowledge. KBSEND has a 4-byte queue, and each byte waits for the previous one's acknowledge, so a two-byte command can be written in one go:

| Command | Bytes |
|---------|-------|
| Set lights (Scroll, Num, Caps) | `ED`, then bits 0–2 |
| Set repeat rate and delay | `F3`, then the rate byte |
| Reset and self-test | `FF` |

If the keyboard doesn't answer within 20 ms, TIMEOUT is set and the queue is cleared.

### 3.6 Reset keys

With KBCON.RESETKEYS set (the default), holding **Ctrl + Alt + Delete** on a PS/2 keyboard resets the computer in hardware, with RESETWHY.KEYBOARD set (spec 7). This works even when software has hung, like the Amiga's Ctrl + Amiga + Amiga. Software that needs those keys for itself can turn it off. The Spectrum keyboard has no Alt key; the KS3's reset button does the same job (RESETWHY.BUTTON).

## 4. Registers

In the system area at `0xF00000`. Spec 3 sets the final addresses. All registers are 32-bit and follow the 16-bit-halves rules (spec 10, section 4.1; spec 15, section 6).

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x400` | KBCON | EN (0), RAW (1), RESETKEYS (2), MATRIX (3) | On; raw PS/2 bytes instead of events; Ctrl + Alt + Delete resets (on after reset); scan the Spectrum keyboard (on after reset) |
| `0x404` | KBSTAT | COUNT (4–0), TXBUSY (8) | Events waiting (0–16); a command is being sent |
| `0x408` | KBDATA | EMPTY (16), RELEASED (15), KEY (8–0) | Reading the low half takes one event. In raw mode, bits 7–0 are the next PS/2 byte (Spectrum keyboard events are still reported as key events) |
| `0x40C` | KBSEND | 7–0 | Write: queue a byte to send to the keyboard |
| `0x410` | KBREPLY | 7–0 | The keyboard's last reply byte |
| `0x414` | KBIRQ | EVENT (0), REPLY (1), PARITY (2), FRAME (3), TIMEOUT (4), OVERFLOW (5) | EVENT follows the FIFO; the others are sticky, write 1 to clear |
| `0x418` | KBIRQEN | Same layout as KBIRQ | Interrupt enables |
| `0x440`–`0x47C` | KBMAP0–15 | 31–0 each | Key map: key n is bit (n mod 32) of KBMAP(n ÷ 32). Read-only |

**OVERFLOW** means the event FIFO was full and an event was lost; the key map is still correct.

**RESETWHY** (spec 7, section 7) has bit 6, **KEYBOARD**, for this.

## 5. FPGA resources

| Item | Resource |
|------|----------|
| PS/2 receiver and sender, decoder, matrix scanner and its key table, event FIFO, 512-bit key map | Estimate 350–500 LUTs |
| Block RAM, DSP | None |
| Pins | 2 for PS/2 and 15 for the matrix, already wired on the KS3 |

## 6. Open points

| # | Item |
|---|------|
| K3 | Some USB keyboards also speak PS/2 through a passive adapter; most new ones don't. List keyboards known to work |
| K4 | A USB keyboard host, if PS/2 keyboards become hard to find |
| K5 | Mouse (on the PS/2 socket's spare pins), the KS3's two joystick ports, and keyboard input from the PC over USB serial: to be specified later |
| K6 | The exact matrix positions of the Next's extra keys and the key numbers they report |

## 7. Tests

- **Simulation:** a PS/2 keyboard model sends every key in scan code set 2, including `E0` keys, Pause, Print Screen and fake shifts; check the events and the key map.
- **Spectrum keyboard:** a matrix model presses every key, with bounce; check one clean event per press and release, the PS/2 key numbers, the ghosting rule, and that MATRIX turns scanning off.
- **Errors:** bad parity and framing lead to a resend; a keyboard that doesn't answer gives TIMEOUT.
- **Commands:** set lights (2-byte command) and reset work, waiting for each acknowledge.
- **Reset keys:** Ctrl + Alt + Delete resets with RESETWHY.KEYBOARD, and does nothing when turned off.
- **Real keyboards:** a few PS/2 keyboards, including plugging in while running (the key map clears on `AA`), and the KS3's own keyboard, used together.
