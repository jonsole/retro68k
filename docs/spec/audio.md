# Spec 6: Audio

Status: **draft for review**

Sound comes from two sources that are mixed together and sent to the audio jack:

- **4 hardware channels**, like the Amiga's Paula: each plays a sample from Chip RAM by itself, with its own pitch, volume and loop, and needs no CPU work while it plays.
- **A stereo stream**: plays a buffer in Chip RAM that the DMA engine fills by mixing any number of **voices** (spec 11, MIX operation). This gives 30–40 voices on spare memory slots, far more than hardware channels could.

## 1. Summary

| Item | Value |
|------|-------|
| Output rate | 200 MHz ÷ D, programmable. Default D = 4167: 47.996 kHz. D = 4535: 44.10 kHz |
| Hardware channels | 4: 8- or 16-bit samples, any pitch, stereo volume (pan), loop, queued next sample |
| Stream | 16-bit stereo, played from a ring buffer in Chip RAM, interrupt at the half-way point and at the end |
| Software voices | Mixed into the stream buffer by the DMA engine's MIX operation; about 40 voices on spare slots at 640×480 |
| Mixer | Channels + stream added at 18-bit precision, master volume, saturated to 16 bits |
| Output | Second-order sigma-delta DAC at 100 MHz on the miniSpartan6+'s two audio pins and stereo jack |
| CPU work | None for hardware channels while they play. For mixed voices: update notes and restart the mix chain once per block (e.g. every 5–10 ms) |

## 2. Comparison with the Amiga (Paula)

| Feature | Amiga | retro68k |
|---------|-------|----------|
| Channels | 4, hard-panned (2 left, 2 right) | 4 hardware channels with any pan, plus 30–40 DMA-mixed voices |
| Sample size | 8-bit | 8- or 16-bit |
| Volume | 0–64 | 0–255 per side (left and right) |
| Pitch | Period register (clock ticks per sample) | Step per output sample, 8.16 fixed point |
| Output | 8-bit DACs, analogue filter | 16-bit mix, sigma-delta DAC |
| Next sample | Location and length reloaded at the end of each sample | Same: next-sample registers taken at the end or loop point |
| Mixing more voices | In software on the CPU (very costly) | DMA engine, in hardware |

## 3. Output

### 3.1 Sample rate

The output rate is the 200 MHz master clock divided by D (AUDRATE register), in keeping with the rest of the system's whole-number clocks.

| D | Rate |
|---|------|
| 4167 | 47.996 kHz (default) |
| 4535 | 44.101 kHz |
| 6250 | 32.000 kHz |
| 9070 | 22.051 kHz |

Lower rates leave more memory slots for more mixed voices.

### 3.2 Mixer

At every output sample:

```
 left  = stream.left  + Σ (channel sample × channel left volume)
 right = stream.right + Σ (channel sample × channel right volume)
 then × master volume, saturated to 16 bits
```

The multiplies use the FPGA's DSP slices (the LX25 has 38). Adding is done at 18 bits so four loud channels plus the stream only clip at the final step.

### 3.3 DAC

The miniSpartan6+ drives its stereo jack from two FPGA pins through a filter on the board. A second-order sigma-delta modulator running at 100 MHz turns each 16-bit sample into a fast 1-bit stream on each pin. The real quality depends on the board's filter and has to be measured (open point A1). An I2S DAC chip (e.g. PCM5102A) can be added on the final PCB for better quality; the mixer output stays the same.

## 4. Hardware channels (Amiga-style)

Each of the 4 channels plays one sample at a time from Chip RAM.

- **Sample:** START address and LENGTH in bytes. 8-bit or 16-bit signed samples (16-bit samples start on an even address).
- **Loop:** when the end is reached, the channel continues from LOOPSTART for LOOPLEN bytes, repeatedly. With LOOPLEN = 0 it stops instead (a one-shot sound such as a drum).
- **Pitch:** STEP, in 8.16 fixed point, is how far the channel moves through the sample for each output sample. `0x010000` plays it as recorded (at the output rate), `0x020000` an octave higher, `0x008000` an octave lower. To play a sample recorded at rate R: STEP = R ÷ output rate × 65536.
- **Volume:** VOLL and VOLR, 0–255 each, so a channel can be placed anywhere from left to right.
- **No interpolation:** each output sample takes the nearest source sample, as on the Amiga (open point A2 considers linear interpolation).
- **Queued next sample (as on the Amiga):** writes to START, LENGTH, LOOPSTART and LOOPLEN while a channel is playing are held, and take effect when the current sample ends or loops. A music player can queue the next note without exact timing. Writes to STEP and the volumes take effect at once.
- **Interrupt** when a sample ends or loops (if enabled), so software can queue the next one.

**Memory:** each channel has a small FIFO (a few bursts) filled from its own fixed audio slot in every video line (spec 5, section 7.1): 12 bytes per line, at least 375 KB/s. A 16-bit channel at 48 kHz needs 96 KB/s at normal pitch, so it can play up to about 3.9× faster than recorded before it runs short.

## 5. Stream

The stream plays a stereo buffer: 16-bit signed samples, left then right, in a ring buffer in Chip RAM.

- **STRBASE** and **STRLEN** (in frames, one frame = left + right = 4 bytes) define the ring. The stream plays from start to end and wraps round.
- **Interrupts** at the half-way point and at the end. Each one means the other half is now free to refill.
- **STRPOS** reads back the frame being played.
- The stream reads from Chip RAM through 2 fixed audio slots per line: 24 bytes per line, against 6 needed at 48 kHz.

## 6. Mixing many voices with the DMA engine

> **On hold.** Stepping through a sample and taking the nearest value sounds poor when mixing at a fixed 48 kHz rate (a metallic buzz when pitched down, off-key aliasing when pitched up). The DMA engine's MIX operation needs proper resampling, for example 8-tap windowed-sinc interpolation with pre-filtered octave copies, before it is worth building. Parked until then. Until then, the stream can be filled by the CPU or by any other software mixer.

The DMA engine's **MIX** operation (spec 11, section 3) adds one voice into a stream buffer: for each output frame it reads the voice's sample, multiplies by the left and right volumes, adds to the buffer with saturation, and steps through the sample by the voice's pitch, looping as needed. After the job, the engine writes the voice's new position back into its descriptor, so the next block carries on smoothly.

**Typical set-up** (the "double buffer" pattern):

1. Make a stream buffer of 2 × 256 frames (5.3 ms per half at 48 kHz).
2. Make one MIX descriptor per voice, chained. The first has the OVER bit set, so it writes its voice instead of adding. This clears the old contents without a separate FILL.
3. Start the stream.
4. On each half-way or end interrupt:
   - point the chain's descriptors at the half that just finished playing,
   - update any notes that changed (sample pointer, STEP, volumes),
   - start the chain on a DMA channel.

   The engine mixes all voices into that half while the other half plays.

**Delay:** a new note is heard after the current half finishes, so up to two halves later (10.7 ms with 256-frame halves).

**Voices:** each voice costs about 48,000–56,000 memory slots per second at 48 kHz (sample reads, buffer read, buffer write).

| Slots available (640×480) | Voices at 48 kHz |
|---------------------------|------------------|
| Spare odd slots only (CPU busy in Chip RAM) | about 40 |
| Spare odd + even slots (CPU idle, in ROM or block RAM) | well over 100 |
| HIGH-priority jobs | in between, at the cost of CPU slots |

Lower output rates give proportionally more voices.

## 7. Memory slots

The 8 fixed audio slots per line in spec 5, section 7.1 are used as:

| Slots | Use |
|-------|-----|
| 4 | Hardware channels 0–3, one each |
| 2 | Stream |
| 2 | Reserved (for example for 2 more hardware channels later) |

Mixing voices with the DMA engine uses the engine's own slots (spec 11, section 5), not these.

## 8. Registers

Offsets in the custom register block at `0xE00000`. Spec 3 sets the final addresses.

**Global:**

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x400` | AUDCON | EN (0) | Audio output on |
| `0x404` | AUDRATE | 15–0 | D: output rate = 200 MHz ÷ D |
| `0x408` | AUDVOL | L 15–8, R 7–0 | Master volume |
| `0x40C` | AUDSTAT | CH0–3 END (0–3), STRHALF (4), STREND (5), CH0–3 STARVED (8–11), STRSTARVED (12) | Sticky flags, write 1 to clear |
| `0x410` | AUDINTEN | Same layout as AUDSTAT | Interrupt enables |

**Per hardware channel** (channel n at `0x440 + n × 0x20`):

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `+0x00` | CTRL | EN (0), BITS16 (1) | On; 16-bit samples |
| `+0x04` | START | 24–0 | Sample start (queued) |
| `+0x08` | LENGTH | 23–0 | Bytes (queued) |
| `+0x0C` | LOOPSTART | 24–0 | Loop start (queued) |
| `+0x10` | LOOPLEN | 23–0 | Loop length in bytes; 0 = one-shot (queued) |
| `+0x14` | STEP | 23–0 | Pitch, 8.16 fixed point |
| `+0x18` | VOL | L 15–8, R 7–0 | Volume |
| `+0x1C` | POS | 24–0 | Read: current position |

**Stream:**

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x4C0` | STRCON | EN (0) | Stream on |
| `0x4C4` | STRBASE | 24–0 | Ring buffer start (4-byte aligned) |
| `0x4C8` | STRLEN | 15–0 | Ring length in frames (even) |
| `0x4CC` | STRPOS | 15–0 | Read: frame being played |

**DMACON** (spec 5, section 8): bits 3–0 enable hardware channels 0–3; bit 4 (freed when storage moved into the DMA engine) becomes **STREN**, the stream.

**Interrupts:** level 4, shared with the DMA engine; vectored, so each has its own handler.

**STARVED** flags: set if a channel or the stream ran out of data (should never happen within the limits above). The output repeats the last sample until data arrives.

## 9. FPGA resources

| Item | Resource |
|------|----------|
| Channel and stream FIFOs | 1 block RAM (already in the design plan's budget) |
| Mixer multiplies | 10 DSP slices (4 channels × 2 sides, + master × 2) |
| Channel logic, mixer, sigma-delta | Estimate 600–900 LUTs |

## 10. Open points

| # | Item |
|---|------|
| A1 | Measure the audio quality through the miniSpartan6+'s filter; decide whether the final PCB needs an I2S DAC |
| A2 | **Resampling quality.** Nearest-sample stepping sounds poor at a fixed output rate. Hardware channels and MIX need interpolation: linear, 4-point cubic, or 8-tap windowed sinc with pre-filtered octave copies (the best option, using DSP slices and one block RAM of coefficients). To decide before either is built |
| A3 | MIX of several voices in one job (reading and writing the buffer once for up to 4 voices) would roughly double the number of voices |
| A4 | Audio over HDMI (video spec open point V6) |
| A5 | 2 more hardware channels in the reserved slots, if wanted |

## 11. Tests

- **Rates:** check the output rate for each D value in simulation.
- **Channels:** 8- and 16-bit, one-shot and looping, pitches from 1/16× to 3.9×, queued next sample taken exactly at the end or loop point, END interrupts.
- **Stream:** ring wrap, half and end interrupts, STRPOS.
- **Mixer:** saturation with all four channels and the stream at full volume; master volume.
- **DMA mixing end to end:** 32 voices mixed into a 2 × 256-frame stream for many blocks; compare the output with a Python reference mixer; no STARVED, positions continue smoothly across blocks.
- **Sigma-delta:** run the modulator on a sine wave in simulation and check the noise level after a model of the board's filter.
