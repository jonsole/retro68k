# Spec 16: Keyboard

Status: **draft for review**

A PS/2 keyboard connects through two spare header pins and a small adapter. The FPGA receives the keyboard's codes, turns them into simple **key events**, keeps a **map of which keys are held down**, and can send commands to the keyboard (for example to set its lights).

Mouse, joysticks and other inputs are to be added later (open point K5).

## 1. Summary

| Item | Value |
|------|-------|
| Keyboard | Any PS/2 keyboard (scan code set 2, the default) |
| Connection | 6-pin mini-DIN socket on an adapter: 5 V, ground, and CLK and DATA through a level shifter to 2 header pins |
| Events | Key number (0–511) plus pressed/released, in a 16-event FIFO. The hardware handles PS/2's prefix bytes |
| Key map | 512 bits, one per key, showing which keys are held down right now |
| Raw mode | Software can get the keyboard's bytes unchanged instead |
| Sending | Commands to the keyboard (lights, repeat rate, reset), with the keyboard's acknowledge handled in hardware |
| Reset keys | Ctrl + Alt + Delete can reset the computer in hardware, even if software has hung (can be turned off) |
| Interrupt | Source KEYB (17) in the interrupt controller |

## 2. The adapter

PS/2 keyboards run at 5 V, and their CLK and DATA lines are open-collector with pull-ups to 5 V. The FPGA's pins are 3.3 V and must not see 5 V. The adapter has:

- a mini-DIN 6 socket,
- 5 V for the keyboard (from the board's USB supply; a keyboard draws up to about 100 mA),
- a 2-channel bidirectional level shifter (the common BSS138 MOSFET type) with pull-ups on both sides,
- connections to 2 spare header pins, plus 5 V and ground.

Which header pins to use is decided with the other header uses (open point K1).

## 3. How it works

### 3.1 Receiving

The keyboard sends 11-bit frames (start bit, 8 data bits, odd parity, stop bit) on its own clock of about 10–17 kHz. The controller samples the lines at 100 MHz, checks parity and framing, and passes good bytes to the decoder. A bad byte sets an error flag; the controller then asks the keyboard to send it again (the PS/2 "resend" command, `0xFE`).

### 3.2 Decoding into key events

PS/2 scan codes are awkward: a released key is sent as `F0` then its code; many keys have an `E0` prefix; Pause sends an 8-byte sequence; Print Screen and some others add "fake shift" codes. The decoder hides all of this:

| Keyboard sends | Event |
|----------------|-------|
| `1C` | Key `0x01C` (A) pressed |
| `F0 1C` | Key `0x01C` released |
| `E0 75` | Key `0x175` (cursor up) pressed: `E0` keys get `0x100` added |
| `E0 F0 75` | Key `0x175` released |
| `E1 14 77 E1 F0 14 F0 77` | Key `0x1FF` (Pause) pressed. Pause has no release |
| `E0 12`, `E0 59` (fake shifts) | Ignored |

Each event is 16 bits: **RELEASED** (bit 15) and the **key number** (bits 8–0). Software turns key numbers into characters with a keyboard layout table (UK, US and others; the boot ROM will include a few).

Replies from the keyboard (`FA` acknowledge, `AA` self-test passed, `EE` echo, `FE` resend, errors) are not key events. They go to KBREPLY.

### 3.3 Key map

The controller keeps 512 bits, one per key number, set while the key is held down. Games can check any key at any time without handling events, as on the Amiga or Atari ST keyboard matrix. The map is cleared when the keyboard resets (`AA`) or when the controller is turned off, so no key stays stuck.

### 3.4 Sending commands

Software writes a byte to KBSEND. The controller does the PS/2 "request to send" (holds CLK low for 100 µs, then DATA low), lets the keyboard clock the byte in, and waits for the keyboard's `FA` acknowledge. KBSEND has a 4-byte queue, and each byte waits for the previous one's acknowledge, so a two-byte command can be written in one go:

| Command | Bytes |
|---------|-------|
| Set lights (Scroll, Num, Caps) | `ED`, then bits 0–2 |
| Set repeat rate and delay | `F3`, then the rate byte |
| Reset and self-test | `FF` |

If the keyboard doesn't answer within 20 ms, TIMEOUT is set and the queue is cleared.

### 3.5 Reset keys

With KBCON.RESETKEYS set (the default), holding **Ctrl + Alt + Delete** resets the computer in hardware, with RESETWHY.KEYBOARD set (spec 12). This works even when software has hung, like the Amiga's Ctrl + Amiga + Amiga. Software that needs those keys for itself can turn it off.

## 4. Registers

In the system area at `0xF00000`. Spec 3 sets the final addresses. All registers are 32-bit and follow the 16-bit-halves rules (spec 10, section 4.1; spec 15, section 6).

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x400` | KBCON | EN (0), RAW (1), RESETKEYS (2) | On; raw bytes instead of events; Ctrl + Alt + Delete resets (on after reset) |
| `0x404` | KBSTAT | COUNT (4–0), TXBUSY (8) | Events waiting (0–16); a command is being sent |
| `0x408` | KBDATA | EMPTY (16), RELEASED (15), KEY (8–0) | Reading the low half takes one event. In raw mode, bits 7–0 are the next byte |
| `0x40C` | KBSEND | 7–0 | Write: queue a byte to send to the keyboard |
| `0x410` | KBREPLY | 7–0 | The keyboard's last reply byte |
| `0x414` | KBIRQ | EVENT (0), REPLY (1), PARITY (2), FRAME (3), TIMEOUT (4), OVERFLOW (5) | EVENT follows the FIFO; the others are sticky, write 1 to clear |
| `0x418` | KBIRQEN | Same layout as KBIRQ | Interrupt enables |
| `0x440`–`0x47C` | KBMAP0–15 | 31–0 each | Key map: key n is bit (n mod 32) of KBMAP(n ÷ 32). Read-only |

**OVERFLOW** means the event FIFO was full and an event was lost; the key map is still correct.

**RESETWHY** (spec 12) gains bit 6, **KEYBOARD**.

## 5. FPGA resources

| Item | Resource |
|------|----------|
| PS/2 receiver and sender, decoder, event FIFO, 512-bit key map | Estimate 250–400 LUTs |
| Block RAM, DSP | None |
| Pins | 2 on the headers |

## 6. Open points

| # | Item |
|---|------|
| K1 | Which header pins (with the NMI button and other header uses) |
| K2 | The adapter: buy a ready-made level-shifter module or make a small board |
| K3 | Some USB keyboards also speak PS/2 through a passive adapter; most new ones don't. List keyboards known to work |
| K4 | A USB keyboard host, if PS/2 keyboards become hard to find |
| K5 | Mouse, joysticks and keyboard input from the PC over USB serial: to be specified later |

## 7. Tests

- **Simulation:** a PS/2 keyboard model sends every key in scan code set 2, including `E0` keys, Pause, Print Screen and fake shifts; check the events and the key map.
- **Errors:** bad parity and framing lead to a resend; a keyboard that doesn't answer gives TIMEOUT.
- **Commands:** set lights (2-byte command) and reset work, waiting for each acknowledge.
- **Reset keys:** Ctrl + Alt + Delete resets with RESETWHY.KEYBOARD, and does nothing when turned off.
- **Real keyboards:** a few PS/2 keyboards, including plugging in while running (the key map clears on `AA`).
