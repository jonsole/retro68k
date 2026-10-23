# Spec 16: Keyboard

Status: **v1 scope**

Version 1 supports a **PS/2 keyboard** only. The hardware receives the keyboard's bytes and puts them in a small FIFO. Software reads the bytes and decodes the scan codes. Software can also send a byte to the keyboard, for example to set its lights.

Later versions may add more (section 6).

## 1. Summary

| Item | Value |
|------|-------|
| Keyboard | Any PS/2 keyboard (scan code set 2, the default) |
| Connection | The KS3's PS/2 socket. 5 V power and level shifting are on the board, so no adapter is needed |
| Receiving | Each PS/2 frame is checked (parity, start and stop bits). Good bytes go into a 16-byte FIFO, unchanged |
| Decoding | Done by software: release codes (`F0`), `E0` prefixes, Pause and so on |
| Sending | One byte at a time, with a busy flag. The keyboard's reply (`FA` and others) arrives in the FIFO like any other byte |
| Interrupt | Source KEYB (17) in the interrupt controller: FIFO not empty, or an error |

## 2. Connections

| Signal | FPGA pin | Notes |
|--------|----------|-------|
| PS/2 clock | `ps2_clk` | Open collector, both ways |
| PS/2 data | `ps2_data` | Open collector, both ways |

## 3. How it works

### 3.1 Receiving

- The keyboard sends 11-bit frames: a start bit (0), 8 data bits (lowest first), odd parity and a stop bit (1). Its clock runs at about 10–17 kHz.
- The controller samples both lines at 100 MHz, with a short filter on the clock line against noise.
- A good byte goes into the FIFO.
- A bad byte is dropped. Bad parity sets KBIRQ.PARITY. A bad start or stop bit sets KBIRQ.FRAME. Software can send `FE` (resend) if it wants the byte again.
- If the FIFO is full, the new byte is dropped and KBIRQ.OVERFLOW is set.
- A frame not finished within 2 ms is dropped, so a glitch cannot leave the receiver out of step: the next frame starts afresh. The clock line must hold a new level for 0.64 µs to count.
- When KBCON.EN is 0, nothing is received and the FIFO is empty.

### 3.2 Reading the FIFO

- KBSTAT.COUNT says how many bytes are waiting (0–16).
- Reading the low half of KBDATA takes one byte from the FIFO. A MOVE.B or MOVE.W of its low half (`KBDATA+3`, `KBDATA+2`) or a MOVE.L of KBDATA all work. (A read of the high half alone also takes a byte, and loses it: don't.)
- If the FIFO is empty, the read returns KBDATA.EMPTY set and no byte.
- KBIRQ.DATA is 1 while the FIFO is not empty. It is not sticky. With KBIRQEN.DATA set, this gives the interrupt.

### 3.3 Decoding (software)

The bytes are scan code set 2, as the keyboard sends them. Software decodes them. A few examples:

| Keyboard sends | Meaning |
|----------------|---------|
| `1C` | A pressed |
| `F0 1C` | A released |
| `E0 75` | Cursor up pressed |
| `E0 F0 75` | Cursor up released |
| `E1 14 77 E1 F0 14 F0 77` | Pause pressed (Pause has no release) |
| `AA` | Self-test passed (sent after power-on or a reset command) |
| `FA` | Acknowledge, after a byte sent to the keyboard |

The boot ROM will include a small decoder and a layout table.

### 3.4 Sending

1. Software checks that KBSTAT.TXBUSY is 0.
2. Software writes the byte to the low half of KBSEND.
3. The controller holds the clock low for 100 µs, pulls data low, releases the clock, and sends the byte (with parity) on the keyboard's clock. TXBUSY is 1 during this.
4. TXBUSY goes back to 0 when the keyboard has taken the byte.
5. The keyboard answers with a byte, usually `FA`. It arrives in the FIFO. Software waits for it before sending the next byte.

| Command | Bytes |
|---------|-------|
| Set lights (Scroll, Num, Caps) | `ED`, wait for `FA`, then bits 0–2, wait for `FA` |
| Set repeat rate and delay | `F3`, wait for `FA`, then the rate byte, wait for `FA` |
| Reset and self-test | `FF`, wait for `FA`, then `AA` |

- A write to KBSEND while TXBUSY is 1 is ignored.
- If the keyboard does not take the byte within 15 ms, the controller gives up. TXBUSY goes to 0 and KBIRQ.TIMEOUT is set.
- Nothing is received while a byte is being sent.

## 4. Registers

In the system area at `0xF00000`. All registers are 32-bit and follow the rules in registers.md, section 2.

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x400` | KBCON | EN (0) | On. 0 after reset. Turning it off empties the FIFO |
| `0x404` | KBSTAT | COUNT (4–0), TXBUSY (8) | Read: bytes waiting (0–16); a byte is being sent |
| `0x408` | KBDATA | EMPTY (8), BYTE (7–0) | Reading the low half takes one byte. EMPTY = 1: the FIFO was empty |
| `0x40C` | KBSEND | BYTE (7–0) | Write the low half: send this byte to the keyboard |
| `0x410` | KBIRQ | DATA (0), PARITY (1), FRAME (2), OVERFLOW (3), TIMEOUT (4) | DATA follows the FIFO (1 = not empty). The others are sticky, write 1 to clear |
| `0x414` | KBIRQEN | Same layout as KBIRQ | Interrupt enables |

The interrupt (source KEYB, 17) is on while any bit is set in both KBIRQ and KBIRQEN.

## 5. FPGA resources

| Item | Resource |
|------|----------|
| PS/2 receiver and sender, 16-byte FIFO, registers | About 90 LUTs (Vivado) |
| Block RAM, DSP | None |
| Pins | 2, already wired on the KS3 |

## 6. Later versions

| Item | Notes |
|------|-------|
| Spectrum keyboard | The Next's membrane keyboard (8 × 7 matrix, `keyb_row_o` and `keyb_col_i`), scanned and debounced in hardware |
| Key map | 512 bits, one per key, showing which keys are held down |
| Decoded key events | Key number plus pressed/released, with the PS/2 prefixes handled in hardware |
| Command handling in hardware | A send queue that waits for each `FA`, automatic resend on errors, a separate reply register |
| Ctrl + Alt + Delete reset in hardware | Software can do this in v1: it watches for the keys and writes SYSRESET (spec 7) |
| Mouse, joysticks | The PS/2 socket's spare pins (`ps2_pin6`, `ps2_pin2`) and the KS3's two joystick ports |
| USB keyboard | A USB host, if PS/2 keyboards become hard to find |

## 7. Open points

| # | Item |
|---|------|
| K3 | Some USB keyboards also speak PS/2 through a passive adapter; most new ones don't. List keyboards known to work |

## 8. Tests

- **Simulation:** a PS/2 keyboard model sends bytes; check they come out of KBDATA in order, and COUNT and EMPTY are right.
- **Errors:** bad parity sets PARITY, a bad stop bit sets FRAME, and the byte is dropped. A 17th byte sets OVERFLOW.
- **Sending:** a byte sent to the model arrives with the right parity; TXBUSY follows the transfer; a model that never clocks gives TIMEOUT.
- **Interrupt:** KEYB is on while the FIFO is not empty and DATA is enabled, and goes off when the FIFO is read empty.
- **Real keyboards:** a few PS/2 keyboards. Type every key and check the bytes; set the lights; plug in while running (`AA` arrives).
