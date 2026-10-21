# Spec 15: SD card

Status: **draft for review**

The SD card is the computer's storage: programs, data, music, pictures. On the ZX Spectrum Next KS3 the SD slot is wired for **SPI mode** only, so the FPGA has an **SPI-mode SD host controller**. Hardware does the bit-level work (clocking, command checksums, data tokens, moving 512-byte blocks, busy waiting, timeouts); software does the card start-up sequence and the file system (e.g. FAT32).

## 1. Summary

| Item | Value |
|------|-------|
| Slot | The KS3's SD slot: `sd_sclk`, `sd_mosi`, `sd_miso` and `sd_cs0`. `sd_cs1` (a second card select) is wired but unused for now |
| Cards | SD, SDHC and SDXC (any size), at 3.3 V |
| Bus | SPI mode, 1 bit each way |
| Speed | SPI clock up to 25 MHz: about 2.5–3 MB/s |
| Clock | 100 MHz ÷ (2 × CLKDIV): 400 kHz for start-up, 25 MHz after |
| Hardware does | 48-bit commands with CRC7, the R1/R1b/R3/R7/R2 responses, 512-byte data blocks with start tokens and CRC16, data-response tokens on writes, busy waiting, multi-block transfers with the automatic stop, timeouts |
| Software does | Card start-up (CMD0, CMD8, ACMD41, CMD58, optional CMD59), file system |
| Data | A 2 KB FIFO (4 blocks), read and written by the CPU or by the DMA engine (port 0) |
| Card detect | None on the KS3; software notices cards by sending commands (section 5) |
| Interrupt | Source SD (16) in the interrupt controller: command done, data done, errors |

## 2. Why SPI mode

SD cards have two ways to talk: the native bus (1 or 4 data lines, up to 25 MB/s) and the simpler SPI mode (1 line each way). The KS3 board only wires the SPI signals, so this controller uses SPI mode. It is slower, about 2.5–3 MB/s, but that is still plenty for loading programs and files: a 1 MB file loads in under half a second.

## 3. How a transfer works

### 3.1 Chip select and clocks

- `sd_cs0` selects the card. SDCON.CS chooses which select line a command uses (0 = `sd_cs0`, the slot; 1 = `sd_cs1`, unused for now).
- The controller pulls the select line low for each command and its data, and releases it afterwards with 8 extra clocks, as SPI-mode cards expect.
- **Start-up clocks:** writing 1 to SDCON.INITCLK sends 80 clocks with the select line high (cards need at least 74 before the first command). The bit clears itself when done.

### 3.2 Commands

1. Software writes the 32-bit argument to SDARG.
2. Software writes SDCMD with the command number, the kind of response expected, and whether data follows.
3. The controller sends the 48-bit command with its CRC7. It then clocks in 0xFF bytes until the card answers (up to 8 bytes), and stores the response:

| Response (SDCMD.RESP) | What the card sends | Where it goes |
|-----------------------|---------------------|---------------|
| 0: R1 | 1 status byte | SDRESP0 bits 7–0 |
| 1: R1b | 1 status byte, then busy (MISO held low) | SDRESP0 bits 7–0; the controller waits while busy |
| 2: R3 / R7 | 1 status byte + 32 bits (OCR, or voltage check) | SDRESP0 bits 7–0; SDRESP1 the 32 bits |
| 3: R2 | 2 status bytes | SDRESP0 bits 15–0 |

4. CMDDONE is set. If the card doesn't answer, CMDTIMEOUT is set. If any error bit is set in the R1 status byte (bits 6–1), CMDERR is set as well, so software needn't check every response by hand.

APP sends CMD55 first (for ACMD commands), checking its R1 before sending the real command.

### 3.3 Data blocks

- Blocks are 512 bytes. SDBLKCNT says how many follow a read or write command (CMD17/18, CMD24/25).
- **Reading:** for each block, the controller waits for the card's start token (`0xFE`), receives 512 bytes into the FIFO, then the 2-byte CRC16. With SDCON.CRCCHK set it checks the CRC and sets DATACRC on a mismatch. If the card sends an error token instead of `0xFE`, TOKENERR is set. If the FIFO is full, the controller stops the SPI clock between blocks until there is room, so data is never lost.
- **Writing:** for each block, the controller sends a start token (`0xFE` for one block, `0xFC` for multi-block), 512 bytes from the FIFO and the CRC16. It reads the card's data-response token: "accepted" carries on; "CRC error" or "write error" sets WRITEERR. It then waits while the card holds MISO low (busy).
- **Multi-block:** with SDCON.AUTOSTOP set, the controller ends a multi-block read with CMD12 (stop transmission) and a multi-block write with the stop token (`0xFD`), then waits out the busy time.
- **Short blocks:** SDCMD.BLK16 makes the data block 16 bytes instead of 512. This is for reading the card's CID and CSD registers (CMD10, CMD9), which SPI mode sends as small data blocks.
- DATADONE is set at the end, or an error flag (DATATIMEOUT, DATACRC, TOKENERR, WRITEERR).

### 3.4 Moving the data

- **DMA engine (normal use):** a channel moves data between the FIFO (port 0) and Chip RAM, paced automatically. The CPU only starts the command and the DMA chain, then takes the DATADONE interrupt.
- **CPU:** for small jobs, the CPU reads or writes SDDATA, 4 bytes at a time.

At 25 MHz the card moves about 3 MB/s. The DMA engine's guaranteed peripheral cycles (spec 5) plus a little of the free pool cover this easily, even with a busy screen.

## 4. Starting a card

Software runs the standard SPI-mode start-up sequence through the command registers. A sketch:

1. CLKDIV = 125 (400 kHz); write SDCON.INITCLK and wait for it to clear (80 clocks with the select line high).
2. CMD0 (go idle) with the select line low: this puts the card into SPI mode. Expect R1 = `0x01` (idle).
3. CMD8 with argument `0x1AA` (voltage check, R7): new cards echo `0x1AA`; old SDv1 cards reply "illegal command".
4. ACMD41 (APP set; argument with bit 30 set for SDHC/SDXC) repeatedly until R1 = `0x00` (ready).
5. CMD58 (read OCR, R3): bit 30 (CCS) set means SDHC/SDXC, which use block addresses; clear means SDSC, which uses byte addresses.
6. Optionally CMD59 with argument 1 to make the card check command and data CRCs; set SDCON.CRCCHK to check them on reads too.
7. For SDSC cards, CMD16 with 512 sets the block length.
8. Set CLKDIV = 2 (25 MHz).

The boot ROM will include this and a small FAT32 reader, so programs can be loaded from the card.

## 5. No card detect

The KS3 has no card-detect switch, and in SPI mode the card's DAT3 pin is its select line, so it can't be used for detection either. Software finds out about the card by talking to it:

- **Is there a card?** Run the start-up sequence. If CMD0 gets no answer (CMDTIMEOUT), there is no card, or it isn't working.
- **Was it removed?** Commands and data transfers start timing out (CMDTIMEOUT, DATATIMEOUT).
- **Was it swapped?** A new card answers CMD0 and needs starting again. A file system can read the card's ID (CMD10, CID) after start-up and compare it with the one it had before.

A disk menu or file requester can simply try CMD0 again when the user asks for a fresh directory listing.

## 6. Registers

In the system area at `0xF00000`. Spec 3 sets the final addresses. All registers are 32-bit and follow the 16-bit-halves rules (spec 10, section 4.1; section 3 of spec 3).

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x300` | SDCON | EN (0), CS (1), INITCLK (2), CRCCHK (3), AUTOSTOP (4), CLKDIV (15–8) | On; which select line (0 = `sd_cs0`); write 1 to send 80 start-up clocks with the select line high (clears when done); check CRC16 on received blocks; stop multi-block transfers automatically; SPI clock = 100 MHz ÷ (2 × CLKDIV) |
| `0x304` | SDARG | 31–0 | Command argument |
| `0x308` | SDCMD | INDEX (5–0), RESP (9–8: R1, R1b, R3/R7, R2), DATA (10), WRITE (11), MULTI (12), APP (13), BLK16 (14) | Writing starts the command. APP sends CMD55 first (for ACMD commands). BLK16 makes the data block 16 bytes (CID, CSD) |
| `0x30C` | SDRESP0 | 15–0 | R1 status in bits 7–0 (R2: both status bytes in bits 15–0) |
| `0x310` | SDRESP1 | 31–0 | The 32 bits after R1 in R3 and R7 responses |
| `0x314`–`0x318` | SDRESP2–3 | 31–0 each | Reserved, read as 0 (kept so the register layout stays the same) |
| `0x31C` | SDBLKCNT | 15–0 | Number of blocks |
| `0x320` | SDSTAT | CMDBUSY (0), DATABUSY (1), CARDBUSY (2), INITBUSY (3), FIFOCOUNT (15–4, in bytes ÷ 4) | Read-only. CARDBUSY: the card is holding MISO low |
| `0x324` | SDIRQ | CMDDONE (0), DATADONE (1), CMDTIMEOUT (2), CMDERR (3), DATATIMEOUT (4), DATACRC (5), WRITEERR (6), TOKENERR (7) | Sticky, write 1 to clear |
| `0x328` | SDIRQEN | Same layout as SDIRQ | Interrupt enables |
| `0x32C` | SDTIMEOUT | 15–0 | Data and busy timeout in milliseconds (default 250) |
| `0x330` | SDDATA | 31–0 | FIFO: read takes 4 bytes, write adds 4 bytes |

**Reading SDDATA with the 68000:** reading its high half takes 4 bytes from the FIFO and returns the first two; reading its low half then returns the other two. A MOVE.L reads it correctly. (This is the general read rule for 32-bit registers: reading the high half captures the whole register, as for the time counter in spec 12.)

## 7. FPGA resources

| Item | Resource |
|------|----------|
| 2 KB data FIFO | 1 block RAM |
| SPI engine, command and data state machines, CRC7 and CRC16, clock divider | Estimate 200–300 LUTs |
| Pins | 5 on the KS3: `sd_sclk`, `sd_mosi`, `sd_miso`, `sd_cs0`, `sd_cs1` |

## 8. Open points

| # | Item |
|---|------|
| SD1 | Is 25 MHz SPI reliable on the KS3's wiring with all cards? Test with several brands; fall back to 12.5 MHz (CLKDIV = 4) if not |
| SD2 | Some cards accept faster SPI clocks after CMD6 "high speed"; worth trying later for about 5 MB/s |
| SD3 | What `sd_cs1` is meant for on the board (a second card on an expansion?), and whether to support it |
| SD4 | A small hardware "read N blocks into memory" helper (command + DMA in one), if the software sequence turns out slow |
| SD5 | Card power is always on (no switch), so a crashed card can only be reset with CMD0, not by cycling power |

## 9. Tests

- **Simulation:** against an SPI-mode SD card model: start-up clocks, the full start-up sequence for SDSC and SDHC cards, single and multi-block reads and writes, 16-byte CID/CSD blocks, error tokens, data-response errors, CRC errors with CRCCHK on, busy after writes, AUTOSTOP for reads (CMD12) and writes (stop token), timeouts.
- **FIFO pacing:** with the FIFO full, the SPI clock pauses between blocks and no data is lost.
- **R1 errors:** a response with an error bit sets CMDERR.
- **No card:** CMD0 with no card gives CMDTIMEOUT, not a hang.
- **Real cards:** several brands and sizes (SDSC, SDHC, SDXC) at 400 kHz and 25 MHz; read speed into Chip RAM with the DMA engine at idle and busy screens.
- **Data integrity:** write and read back a full card pattern; compare.
