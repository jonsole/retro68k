# Spec 15: SD card

Status: **draft for review**

The SD card is the computer's storage: programs, data, music, pictures. The FPGA has an **SD host controller** that talks the card's native 4-bit bus. Hardware does the bit-level work (clocking, checksums, timeouts, moving 512-byte blocks); software does the card set-up sequence and the file system (e.g. FAT32).

## 1. Summary

| Item | Value |
|------|-------|
| Slot | The miniSpartan6+'s microSD slot, all 6 signals wired to the FPGA: CLK, CMD, DAT0–3 |
| Cards | SD, SDHC and SDXC (any size), at 3.3 V |
| Bus | Native SD, 1-bit or 4-bit |
| Speed | Default Speed (25 MHz): up to 12.5 MB/s. High Speed (50 MHz): up to 25 MB/s. (UHS modes need 1.8 V signalling, which the board can't do) |
| Clock | 100 MHz ÷ (2 × CLKDIV): 400 kHz for start-up, 25 or 50 MHz after |
| Hardware does | Commands and responses with CRC7, 512-byte data blocks with CRC16 on every data line, multi-block transfers, automatic stop command, busy waiting, timeouts |
| Software does | Card start-up (CMD0, CMD8, ACMD41, CMD2, CMD3, CMD7, ACMD6, CMD6), file system |
| Data | A 2 KB FIFO (4 blocks), read and written by the CPU or by the DMA engine (port 0) |
| Card detect | By the card's pull-up on DAT3, checked while the bus is idle |
| Interrupt | Source SD (16) in the interrupt controller: command done, data done, error, card inserted or removed |

## 2. Native SD bus or SPI mode?

SD cards can also be run in a simpler SPI mode, as many hobby computers do, but it uses one data line and is limited to a few MB/s. The native 4-bit bus is about 4–8× faster and the hardware is not much bigger, so this controller uses the native bus.

## 3. How a transfer works

### 3.1 Commands

1. Software writes the 32-bit argument to SDARG.
2. Software writes SDCMD with the command number, the kind of response expected, and whether data follows.
3. The controller sends the 48-bit command with its CRC7, waits for the response (with a timeout), checks its CRC, and stores it in SDRESP0–3 (all 136 bits for the R2 response).
4. CMDDONE is set, or an error flag (CMDTIMEOUT, CMDCRC).

Responses with "busy" (R1b, e.g. after a stop or erase) are handled by waiting until the card releases DAT0 before CMDDONE.

### 3.2 Data blocks

- Blocks are 512 bytes. SDBLKCNT says how many follow a read or write command (CMD17/18, CMD24/25).
- **Reading:** the controller receives each block on DAT0–3 (or DAT0 in 1-bit mode), checks the CRC16 on each line, and puts the data in the FIFO. If the FIFO is full, it stops the SD clock between blocks until there is room, so data is never lost.
- **Writing:** the controller takes each block from the FIFO, sends it with its CRC16s, checks the card's "CRC OK" token, then waits while the card is busy writing.
- **Multi-block:** with AUTOSTOP set, the controller sends CMD12 (stop transmission) by itself after the last block.
- DATADONE is set at the end, or an error flag (DATACRC, DATATIMEOUT, WRITEERR).

### 3.3 Moving the data

- **DMA engine (normal use):** a channel moves data between the FIFO (port 0) and Chip RAM, paced automatically. The CPU only starts the command and the DMA chain, then takes the DATADONE interrupt. A typical file-system read of many blocks needs no CPU time while it runs.
- **CPU:** for small jobs, the CPU reads or writes SDDATA, 4 bytes at a time.

At 25 MB/s, writing into Chip RAM needs about 3 million slots per second. Peripheral transfers are guaranteed about 750 KB/s (spec 11, section 5); the rest comes from spare slots, which are plentiful unless the screen and the CPU are both very busy. Reading a 1 MB file typically takes 50–100 ms.

## 4. Starting a card

Software runs the standard start-up sequence through the command registers. A sketch:

1. CLKDIV = 125 (400 kHz), 1-bit bus, then CMD0 (go idle).
2. CMD8 (check voltage; tells new cards from old ones).
3. ACMD41 repeatedly until the card is ready; the response says whether it is SDHC/SDXC (block addressing) or SDSC (byte addressing).
4. CMD2 (card ID), CMD3 (get the card's address), CMD7 (select it).
5. ACMD42 to turn off the card's pull-up on DAT3, then ACMD6 to switch to the 4-bit bus; set SDCON.BUS4.
6. Optionally CMD6 to switch to High Speed; then CLKDIV = 1 (50 MHz). Otherwise CLKDIV = 2 (25 MHz).

The boot ROM will include this, and a small FAT32 reader, so programs can be loaded from the card.

## 5. Card detect

The board has no card-detect switch. Instead the slot's DAT3 line doubles as card detect: a card connects an internal pull-up (about 50 kΩ) to DAT3 when it is first powered.

- While no card is set up, the controller turns on a weak pull-down in the FPGA pin and watches DAT3: high means a card is present.
- Insertion and removal set CARDCHANGE and SDSTAT.CARDIN.
- Once software has turned off the card's DAT3 pull-up (ACMD42) for 4-bit use, detection only works again after the card is reset. Removal during use shows up as command timeouts. Software can check for re-insertion by resetting the card (CMD0).

Whether the board's pull-up and pull-down resistors allow this is open point SD1.

## 6. Registers

In the system area at `0xF00000`. Spec 3 sets the final addresses. All registers are 32-bit and follow the 16-bit-halves rule (spec 10, section 4.1).

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x300` | SDCON | EN (0), BUS4 (1), AUTOSTOP (2), DETECT (3), CLKDIV (15–8) | On; 4-bit bus; send CMD12 after multi-block; watch DAT3 for card detect; SD clock = 100 MHz ÷ (2 × CLKDIV) |
| `0x304` | SDARG | 31–0 | Command argument |
| `0x308` | SDCMD | INDEX (5–0), RESP (9–8: none, 48-bit, 48-bit busy, 136-bit), DATA (10), WRITE (11), MULTI (12), APP (13) | Writing starts the command. APP sends CMD55 first (for ACMD commands) |
| `0x30C`–`0x318` | SDRESP0–3 | 31–0 each | Response, most significant word first |
| `0x31C` | SDBLKCNT | 15–0 | Number of 512-byte blocks |
| `0x320` | SDSTAT | CMDBUSY (0), DATABUSY (1), CARDBUSY (2), CARDIN (3), FIFOCOUNT (15–4, in bytes ÷ 4) | Read-only |
| `0x324` | SDIRQ | CMDDONE (0), DATADONE (1), CMDTIMEOUT (2), CMDCRC (3), DATATIMEOUT (4), DATACRC (5), WRITEERR (6), CARDCHANGE (7) | Sticky, write 1 to clear |
| `0x328` | SDIRQEN | Same layout as SDIRQ | Interrupt enables |
| `0x32C` | SDTIMEOUT | 15–0 | Data timeout in milliseconds (default 250) |
| `0x330` | SDDATA | 31–0 | FIFO: read takes 4 bytes, write adds 4 bytes |

**Reading SDDATA with the 68000:** reading its high half takes 4 bytes from the FIFO and returns the first two; reading its low half then returns the other two. A MOVE.L reads it correctly. (This is the general read rule for 32-bit registers: reading the high half captures the whole register, as for the time counter in spec 12.)

## 7. FPGA resources

| Item | Resource |
|------|----------|
| 2 KB data FIFO | 1 block RAM |
| Command and data engines, CRC7 and 4 × CRC16, clock divider | Estimate 500–800 LUTs |
| Pins | 6, already wired on the board |

## 8. Open points

| # | Item |
|---|------|
| SD1 | Check the board's resistors on DAT3 and the other lines; card detect needs the card's pull-up to win against the FPGA's weak pull-down |
| SD2 | Is High Speed (50 MHz) reliable with the board's track lengths? Test with several cards |
| SD3 | A small hardware "read N blocks into memory" helper (command + DMA in one), if the software sequence turns out slow |
| SD4 | Card power is always on (no switch), so a crashed card can only be reset with CMD0, not by cycling power |

## 9. Tests

- **Simulation:** against an SD card model: start-up sequence, single and multi-block reads and writes in 1-bit and 4-bit modes, CRC errors injected on each line, timeouts, busy after write, AUTOSTOP.
- **FIFO pacing:** with the FIFO full, the SD clock pauses between blocks and no data is lost.
- **Real cards:** several brands and sizes (SDSC, SDHC, SDXC), Default and High Speed; read speed into Chip RAM with the DMA engine at idle and busy screens.
- **Card detect:** insert and remove with no card set up; CARDCHANGE fires.
- **Data integrity:** write and read back a full card pattern; compare.
