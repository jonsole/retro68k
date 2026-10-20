# Spec 7: System: reset, boot ROM and start-up

Status: **draft for review**

This spec covers how the computer starts: what resets it and what a reset does, the boot ROM and its overlay at address 0, what the boot ROM does first, and the leftover system pieces: header pins, the board's LEDs and switches, and identification registers.

The other system-area devices have their own specs: timers (12), interrupt controller (13), USB serial (14), SD card (15) and keyboard (16).

## 1. Summary

| Item | Value |
|------|-------|
| Reset sources | Power-on, reset button, watchdog, software, USB serial RESET/UPLOAD, Ctrl + Alt + Delete |
| What survives a reset | Chip RAM contents (except at power-on), the boot ROM contents, the USB link |
| Boot ROM | 32 KB of block RAM at `0xF80000`, loaded with the FPGA bitstream; can be made writable for development |
| Overlay | After every reset the ROM also appears at address 0 for reads, so the 68000 finds its start-up vectors; writes there go to Chip RAM. Software turns it off |
| 68000 RESET instruction | Resets the custom hardware and devices, not the CPU or the overlay |
| Start-up | Under 1 ms from the end of FPGA configuration to the first 68000 instruction |
| Board LEDs and switches | 8 LEDs for start-up progress and error codes; 4 switches for start-up options |
| Header pins | Port D: keyboard, NMI button, reset button. Ports A, B, C, E, F: free on the main path, kept for the CPU board later |

## 2. Reset

### 2.1 Reset sources

| Source | How | RESETWHY bit |
|--------|-----|--------------|
| Power-on | The FPGA finishes loading its configuration | POWER (0) |
| Watchdog | Not kicked in time (spec 12, section 5) | WATCHDOG (1) |
| Reset button | Button on port D, debounced (10 ms) | BUTTON (2) |
| Software | Writing `0xA55A` to SYSRESET | SOFTWARE (3) |
| USB RESET | Control command from the PC (spec 14, section 3) | USB (4) |
| USB UPLOAD | Control command from the PC: reset, then wait for a program | UPLOAD (5) |
| Keyboard | Ctrl + Alt + Delete (spec 16, section 3.5) | KEYBOARD (6) |
| CPU halted | A double bus fault, if SYSCON.HALTRESET is set (spec 1, section 8) | HALTED (7) |

RESETWHY shows the cause of the last reset. It is kept in the system control registers (section 7); earlier specs that mention RESETWHY refer to this register.

### 2.2 What a reset does

All the sources above give the same **full reset**:

- The 68000 is reset and starts again from the vectors at address 0 (section 3).
- Every custom register and system device goes back to its reset value: video off, sprites, copper, DMA engine and audio stopped, all interrupts off, timers stopped, watchdog off, keyboard settings back to default.
- The ROM overlay is turned on.
- **Chip RAM keeps its contents.** The SDRAM controller keeps refreshing the memory throughout the reset, so after anything except power-on, memory holds what it held before. Debug tools can look at what a crashed program left behind, and software can choose to keep data across resets (as some Amiga programs did).
- **The boot ROM keeps its contents,** including any changes made while it was writable (section 3.3). Only reloading the FPGA restores the original.
- **The USB serial link stays up.** Its buffers are cleared, but the FT2232H and the PC's serial port are not disturbed, so a terminal stays connected across resets.

### 2.3 Power-on sequence

1. The FPGA loads its configuration from the board's SPI flash. For the LX25 this takes roughly 100–250 ms, depending on the flash speed setting.
2. The master PLL locks (spec 4, section 3.1).
3. The SDRAM is started up: 200 µs wait, precharge, 8 refreshes, mode register set (spec 5). This happens only at power-on.
4. The 68000 is released from reset.

Steps 2–4 take under 1 ms. At every later reset only step 4 happens, within a few microseconds.

### 2.4 The 68000's RESET instruction

The 68000's RESET instruction resets external hardware without resetting the CPU. Here it resets:

- the custom hardware (video, sprites, copper, DMA engine, audio) and its registers,
- the interrupt controller, timers (except the watchdog and the 64-bit time counter), SD card controller and keyboard controller.

It does **not** change the overlay, memory, the watchdog, the time counter, RESETWHY, or the USB link. An operating system can use it to put all the hardware into a known state without restarting.

## 3. Boot ROM and overlay

### 3.1 The boot ROM

- 32 KB of block RAM at `0xF80000`–`0xF87FFF` (design plan D11), like the Amiga's Kickstart at `0xF80000`.
- Its contents are part of the FPGA bitstream. The build puts the assembled boot ROM into the bitstream, so the ROM can be changed without changing the FPGA design itself.
- Reading it costs no memory slots and no wait states.

### 3.2 The overlay

After any reset, the 68000 reads its first two long words (stack pointer and start address) from address 0. Chip RAM is at address 0, so the **overlay** makes the ROM appear there too:

| While the overlay is on | Effect |
|-------------------------|--------|
| CPU reads from `0x000000`–`0x007FFF` | Come from the boot ROM |
| CPU writes to `0x000000`–`0x007FFF` | Go to Chip RAM underneath |
| DMA and video | Always see Chip RAM; the overlay is for the CPU only |

So the boot ROM can:

1. start (its start address points into `0xF80000`, its real address),
2. build the 68000's vector table in Chip RAM at address 0 (writes already go to RAM),
3. turn the overlay off by clearing SYSCON.OVERLAY.

From then on, address 0 is Chip RAM for reading and writing. The overlay comes back at every reset, but not after the RESET instruction.

### 3.3 Writable boot ROM, for development

Rebuilding the FPGA with Xilinx ISE takes minutes. To try new boot ROM code quickly:

- Setting **SYSCON.ROMWE** makes the boot ROM writable.
- A program (or the USB upload loader) copies a new ROM image to `0xF80000`, then resets.
- The new ROM runs from the next reset onwards, until the FPGA is reloaded.
- **SYSCON.ROMLOCK** makes ROMWE impossible to set until the next power-on, for when the system should not be changed by accident. The boot ROM sets it unless the development switch is on (section 5).

## 4. What the boot ROM does

The boot ROM's own spec will define this in detail. In outline:

1. Show progress on the LEDs (section 5) at each step.
2. Read RESETWHY and the switches.
3. On power-on only: test Chip RAM.
4. Set up the vector table in RAM, turn the overlay off, set up interrupts and a 1000 Hz timer tick.
5. Start the default screen: 640×480 with an 80×30 text layer.
6. **If RESETWHY.UPLOAD, or switch 1 is on:** wait for a program over the USB serial link and run it.
7. **Otherwise:** start the SD card. If it holds a boot file, load and run it.
8. **If there is no boot file, or switch 0 is on:** start the monitor, on the screen and the USB serial console at once. BASIC comes later (phase 7).

## 5. LEDs, switches and identification

The miniSpartan6+ has 8 LEDs and 4 switches wired to the FPGA.

- **LEDs:** software sets them through SYSLED. The boot ROM uses them for start-up progress, and for an error code if start-up fails (for example "Chip RAM test failed"), so problems can be seen with no screen or PC connected.
- **Switches:** read through SYSSW. The boot ROM uses them as start-up options:

| Switch | Effect at start-up |
|--------|--------------------|
| 0 | Go straight to the monitor |
| 1 | Wait for a program over USB |
| 2 | Default screen at 50 Hz instead of 60 Hz |
| 3 | Development: leave the boot ROM writable (don't set ROMLOCK) |

- **Identification:** SYSID reads `0x5236384B` ("R68K"). SYSVER gives the FPGA build version. SYSCFG describes the hardware, so one boot ROM and one operating system can run on different builds:

| SYSCFG field | Meaning |
|--------------|---------|
| CPU (1–0) | 0 = fx68k inside the FPGA, 1 = external 68SEC000 |
| CPUMHZ (9–2) | CPU clock in MHz (20, or 16 for the fallback) |
| CHIPMB (15–10) | Chip RAM size in MB (8) |
| FASTMB (21–16) | Fast RAM size in MB (0 on the main path, 2 with the CPU board) |

## 6. Header pins

The miniSpartan6+ has 64 header pins in ports A–F (design plan D1).

| Port | Main path (CPU inside the FPGA) | With the CPU board (phase 8) |
|------|----------------------------------|------------------------------|
| D (4 pins) | D0 keyboard CLK, D1 keyboard DATA, D2 NMI button, D3 reset button | The same |
| A, B, C, E, F (60 pins) | Free: joysticks, mouse and other expansion later | 56 for the CPU bus (design plan D3); 4 spare |

Keeping the keyboard and buttons on port D means they stay in the same place when the CPU board arrives. The buttons connect the pin to ground; the FPGA's internal pull-ups hold them high otherwise.

## 7. Registers

System control registers, in the system area at `0xF00000`. Spec 3 sets the final addresses. All registers are 32-bit and follow the 16-bit-halves rules.

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x800` | SYSID | 31–0 | Read: `0x5236384B` ("R68K") |
| `0x804` | SYSVER | 31–0 | Read: FPGA build version |
| `0x808` | SYSCFG | see section 5 | Read: hardware description |
| `0x80C` | RESETWHY | POWER (0), WATCHDOG (1), BUTTON (2), SOFTWARE (3), USB (4), UPLOAD (5), KEYBOARD (6), HALTED (7) | Read: cause of the last reset |
| `0x810` | SYSCON | OVERLAY (0), ROMWE (1), ROMLOCK (2), PROTECT (3), HALTRESET (4) | Overlay on (set at every reset); boot ROM writable; lock ROMWE off until power-on; user-mode hardware accesses give bus errors; reset when the CPU halts (spec 1) |
| `0x814` | SYSRESET | 15–0 | Write `0xA55A` to reset the computer; other values are ignored |
| `0x818` | SYSLED | 7–0 | The board's 8 LEDs (1 = on) |
| `0x81C` | SYSSW | 3–0 | Read: the board's 4 switches (1 = on) |
| `0x820` | SYSSTAT | HALTED (0) | Read: the CPU is halted (spec 1, section 8) |
| `0x824` | BUSERRADDR | 23–0 | Read: address of the last bus error (spec 1, section 6) |
| `0x828` | BUSERRWHY | UNMAPPED (0), ROMWRITE (1), PROTECT (2), CPUSPACE (3) | Read: cause of the last bus error |

## 8. FPGA resources

| Item | Resource |
|------|----------|
| Boot ROM, 32 KB | 16 block RAMs (already in the design plan's budget) |
| Reset control, overlay decode, debounce, system registers | Estimate 100–200 LUTs |

## 9. Open points

| # | Item |
|---|------|
| SY1 | Measure the FPGA configuration time from the board's SPI flash, and whether a faster flash read mode can be set in the bitstream |
| SY2 | The boot ROM spec: monitor commands, upload protocol (with spec 14), boot file name and format, LED codes |
| SY3 | Should a long press of the reset button (e.g. 3 seconds) reset into UPLOAD? |
| SY4 | Check the board's switches and LEDs are on pins that can be read and driven freely (they are in the board's pin file) |

## 10. Tests

- **Each reset source** resets the CPU and hardware and sets the right RESETWHY bit.
- **Memory survives:** write a pattern to Chip RAM, reset by each non-power source, check the pattern is still there.
- **Overlay:** after reset, reads at 0 come from ROM and writes go to RAM; clearing OVERLAY shows the written RAM; DMA always sees RAM.
- **RESET instruction:** resets the hardware but not the CPU, overlay, watchdog or time counter.
- **Writable ROM:** with ROMWE, a new image runs after reset; with ROMLOCK, ROMWE can't be set until power-on.
- **USB link across reset:** a terminal stays connected and keeps working after every kind of reset except power-on.
- **Start-up time:** from configuration done to the first instruction under 1 ms.
