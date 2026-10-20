# Spec 14: USB serial

Status: **draft for review**

The USB serial link connects the computer to a PC through the miniSpartan6+'s USB port. It carries the console (text in and out), program and file uploads, and debug commands. On the PC it appears as an ordinary serial port, so any terminal program works.

## 1. Summary

| Item | Value |
|------|-------|
| Hardware | FT2232H on the miniSpartan6+: channel A programs the FPGA (JTAG); **channel B** is this link, wired to the FPGA as an 8-bit parallel FIFO |
| On the PC | A normal serial port (e.g. `/dev/ttyUSB1` or `COM5`). The baud rate setting is ignored |
| Speed | Several MB/s each way (the FT2232H's asynchronous FIFO mode allows up to about 8 MB/s; the PC side usually sets the real limit) |
| Flow control | Automatic in hardware, both ways: no data is ever lost and no XON/XOFF or RTS/CTS is needed |
| Buffers | 2 KB receive and 2 KB transmit FIFOs in the FPGA, plus the FT2232H's own 4 KB each way |
| CPU access | A data register for bytes, status with counts, interrupts on thresholds and a timeout |
| DMA | DMA engine port 1 (spec 11): bulk transfers with no CPU work |
| Low delay | The FPGA tells the FT2232H to send at once when the transmit FIFO empties, so console text appears without the usual 16 ms USB delay |
| Control commands | A special 16-byte sequence from the PC triggers NMI (break into the debugger), reset, or reset into the upload loader, even when the 68000 has hung |

## 2. How the FIFO link works

The FT2232H channel B runs in **asynchronous 245 FIFO mode**. Its EEPROM must be set for this (design plan Q6; the FTDI FT_Prog tool does it once).

| Signal | Direction | Meaning |
|--------|-----------|---------|
| D7–D0 | Both | Data byte |
| RXF# | FTDI → FPGA | Low: the FT2232H has a byte from the PC waiting |
| RD# | FPGA → FTDI | Pulse low to read that byte |
| TXE# | FTDI → FPGA | Low: the FT2232H has room for a byte to the PC |
| WR# | FPGA → FTDI | Pulse high-to-low to write a byte |
| SIWU# | FPGA → FTDI | "Send immediate": send what it holds to the PC now |

**Flow control comes for free:**

- **PC to computer:** the FPGA only reads from the FT2232H while its receive FIFO has room. When the FIFO is full, the FT2232H's buffer fills, and USB then holds the PC back. Nothing is dropped, however fast the PC sends or however slowly software reads.
- **Computer to PC:** the FPGA only writes when TXE# says there is room. If the PC isn't reading, the FT2232H's buffer and then the transmit FIFO fill up (section 4.3).

**Low delay:** the FT2232H normally waits up to 16 ms (its latency timer) before sending a small amount of data. When the FPGA's transmit FIFO becomes empty after sending, it pulses SIWU#, so short console messages reach the PC straight away.

## 3. Control commands from the PC

The link has no separate "break" signal in FIFO mode, so the PC sends commands in the data stream. The receiver watches for this 16-byte sequence:

```
 00 FF 52 36 38 4B 2D 43 54 4C FF 00 A5 5A  c  ~c
 (0x00 0xFF "R68K-CTL" 0xFF 0x00 0xA5 0x5A, then a command byte c and its inverse)
```

| c | Command | Effect |
|---|---------|--------|
| `0x01` | BREAK | NMI (spec 13, NMISTAT.USB), to enter a debug monitor |
| `0x02` | RESET | Reset the computer (RESETWHY.USB) |
| `0x03` | UPLOAD | Reset the computer with RESETWHY.UPLOAD set, so the boot ROM waits for a program over the link instead of starting normally |

- The sequence is recognised in hardware, so it works even when the 68000 has crashed.
- The 16 bytes are removed from the data stream; software never sees them.
- A partly matching sequence that turns out different is passed on unchanged.
- The chance of binary data containing the sequence by accident is about 1 in 2^120 at each position, so file transfers need no escaping.
- **SERCON.CTLEN** turns recognition off, for example while a program needs the raw stream. It is on after reset, so a hung machine can always be reached. RESET and UPLOAD stay available even when CTLEN is off if SERCON.CTLLOCK is set before turning it off.

A small PC tool in `tools/` will send these commands, and upload programs using the boot ROM's loader protocol (to be defined with the boot ROM).

## 4. Using the link from the CPU

### 4.1 Reading and writing bytes

- **Receive:** reading the low byte of SERDATA takes the next byte from the receive FIFO. SERSTAT.RXCOUNT says how many are waiting. Reading when the FIFO is empty returns SERDATA.EMPTY set and no byte.
- **Send:** writing the low byte of SERDATA puts a byte in the transmit FIFO. SERSTAT.TXSPACE says how much room there is.
- The CPU never waits on a full or empty FIFO; it checks the counts or uses interrupts.

### 4.2 Interrupts

The link is source SERIAL (15) in the interrupt controller (spec 13). It can interrupt when:

| Flag | When |
|------|------|
| RXREADY | At least RXLEVEL bytes are waiting |
| RXTIMEOUT | At least one byte has waited longer than RXTIME microseconds without reaching RXLEVEL. This catches the end of a message without polling |
| TXREADY | At least TXLEVEL bytes of room are free |
| TXOVF | A byte was written while the transmit FIFO was full, and was lost |

A typical console driver sets RXLEVEL = 1 (interrupt on every key) or a larger level plus a short timeout for bulk data.

### 4.3 When nothing is reading on the PC

If no program on the PC has the port open, sent data piles up: first in the FT2232H, then in the transmit FIFO. Software can treat a full FIFO as "nobody listening". With **SERCON.TXDROP** set, the oldest bytes are dropped to make room instead, so debug output never holds a program up. Dropped bytes are counted in SERSTAT.DROPPED.

### 4.4 Bulk transfers with the DMA engine

The DMA engine's **port 1** is this link (spec 11, section 4). A channel can copy a whole file to or from Chip RAM at full speed, paced automatically by the FIFOs, while the CPU does other work. Control-command recognition still works during DMA.

## 5. Registers

In the system area at `0xF00000`. Spec 3 sets the final addresses. All registers are 32-bit and follow the 16-bit-halves rule (spec 10, section 4.1).

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x200` | SERCON | EN (0), CTLEN (1), CTLLOCK (2), TXDROP (3) | Link on; recognise control commands (on after reset); keep RESET and UPLOAD working when CTLEN is off; drop old data instead of filling up |
| `0x204` | SERSTAT | RXCOUNT 27–16, TXSPACE 11–0 | Bytes waiting; room to send (0–2048) |
| `0x208` | SERDATA | Read: EMPTY (8), byte 7–0. Write: byte 7–0 | Reading the low byte takes one byte; writing it sends one byte |
| `0x20C` | SERLEVEL | RXLEVEL 27–16, TXLEVEL 11–0 | Interrupt thresholds |
| `0x210` | SERTIME | 15–0 | RXTIMEOUT time, in microseconds |
| `0x214` | SERIRQ | RXREADY (0), RXTIMEOUT (1), TXREADY (2), TXOVF (3) | Flags. RXREADY and TXREADY follow the FIFO levels; RXTIMEOUT and TXOVF are sticky, write 1 to clear |
| `0x218` | SERIRQEN | Same layout as SERIRQ | Interrupt enables |
| `0x21C` | SERDROP | 15–0 | Read: bytes dropped by TXDROP since last read (then cleared) |

## 6. FPGA resources

| Item | Resource |
|------|----------|
| Receive and transmit FIFOs, 2 KB each | 2 block RAMs (already in the design plan's budget as "SDRAM and USB FIFOs") |
| FIFO interface, control-sequence matcher, timers, registers | Estimate 250–400 LUTs |
| Pins | 13, already wired on the board (not the headers) |

## 7. Open points

| # | Item |
|---|------|
| U1 | Check the miniSpartan6+'s FT2232H EEPROM has channel B in 245 FIFO mode (design plan Q6); set it with FT_Prog if not |
| U2 | Measure real throughput with Linux and Windows drivers |
| U3 | The boot ROM's upload protocol (with the boot ROM spec) |
| U4 | Should the link offer several logical channels (e.g. console and debugger at once)? For now software can share the one stream |
| U5 | Synchronous 245 FIFO mode (up to about 40 MB/s) needs the FT2232H's 60 MHz clock output, which the board may not wire to the FPGA; check the schematic |

## 8. Tests

- **Loopback:** a PC test sends megabytes of random data; the computer echoes it back; check it arrives complete and in order, with software reading slowly and quickly.
- **Flow control:** stop reading on the computer for seconds while the PC sends; nothing is lost.
- **No listener:** with the PC port closed, sends fill up; with TXDROP, old bytes drop and are counted.
- **Control commands:** BREAK gives one NMI; RESET and UPLOAD reset with the right RESETWHY; the 16 bytes never appear in the data; near-miss sequences pass through unchanged; CTLEN and CTLLOCK behave as described; commands work while the 68000 is stuck in a loop with interrupts off.
- **Interrupts:** RXREADY, RXTIMEOUT, TXREADY and TXOVF at their thresholds.
- **DMA:** port 1 transfers in both directions at full speed.
- **Latency:** a single byte sent by the computer reaches the PC in well under 16 ms.
