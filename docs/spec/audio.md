# Spec 6: Audio

Status: **draft for review**

Sound comes from two sources that are mixed together and sent to the audio jack:

- **16 hardware channels.** Each plays a sample from Chip RAM by itself, at any pitch, volume and pan, with loops, and needs no CPU work while it plays. One shared engine does all 16, with a high-quality 16-tap resampling filter.
- **A stereo stream.** Plays a buffer in Chip RAM that software fills: a software synthesiser, an emulator, decoded music, or anything else.

## 1. Summary

| Item | Value |
|------|-------|
| Output rate | 200 MHz ÷ D, programmable. Default D = 4167: 47.996 kHz. D = 4535: 44.10 kHz |
| Hardware channels | 16, processed one after another by one shared engine |
| Sample formats | 16-bit or 8-bit signed PCM |
| Pitch | Step per output sample, 8.16 fixed point (1/65536 steps, up to 255×) |
| Resampling | 16-tap windowed-sinc filter: about −105 dB aliasing, flat to within 1 dB up to 0.3 × the sample's rate (14.4 kHz for a 48 kHz sample). Optional pre-filtered octave copies for clean pitch-ups. Per-channel "nearest" mode for an authentic Amiga sound |
| Volume and pan | 0–255 left and right per channel; master volume |
| Loops | Loop start and length; queued next sample, as on the Amiga |
| Stream | 16-bit stereo, played from a ring buffer in Chip RAM, interrupt at the half-way point and at the end |
| Mixer | 24-bit sum, master volume, saturated to 16 bits |
| Output | Second-order sigma-delta DAC at 100 MHz on the miniSpartan6+'s two audio pins and stereo jack |
| CPU work | None while channels play; the CPU only starts notes and changes settings |

## 2. Comparison with the Amiga (Paula)

| Feature | Amiga | retro68k |
|---------|-------|----------|
| Channels | 4, hard-panned (2 left, 2 right) | 16, any pan, plus a stereo stream |
| Sample size | 8-bit | 16- or 8-bit |
| Volume | 0–64 | 0–255 per side (left and right), plus master volume |
| Pitch | Each channel's DAC runs at the sample's own rate (period register) | All channels are resampled to one output rate by a 16-tap filter |
| Sound at high pitches | Analogue filter smooths the steps | Clean: proper resampling, octave copies for pitch-ups |
| Output | 8-bit DACs | 16-bit mix, sigma-delta DAC |
| Next sample | Location and length reloaded at the end of each sample | Same: queued registers taken at the end or loop point |

## 3. Output

### 3.1 Sample rate

The output rate is the 200 MHz master clock divided by D (AUDRATE register), in keeping with the rest of the system's whole-number clocks.

| D | Rate |
|---|------|
| 4167 | 47.996 kHz (default) |
| 4535 | 44.101 kHz |
| 6250 | 32.000 kHz |
| 9070 | 22.051 kHz |

### 3.2 Mixer

At every output sample:

```
 left  = stream.left  + Σ (channel sample × channel left volume)
 right = stream.right + Σ (channel sample × channel right volume)
 then × master volume, saturated to 16 bits
```

The sum is kept at 24 bits, so nothing clips until the final step. Sixteen loud channels together can be about 16 times louder than one, so the master volume should be set to suit how many channels are playing loudly at once.

### 3.3 DAC

The miniSpartan6+ drives its stereo jack from two FPGA pins through a filter on the board. A second-order sigma-delta modulator running at 100 MHz turns each 16-bit sample into a fast 1-bit stream on each pin. The real quality depends on the board's filter and has to be measured (open point A1). An I2S DAC chip (e.g. PCM5102A) can be added on the final PCB for better quality; the mixer output stays the same.

## 4. Hardware channels

### 4.1 One shared engine

The 16 channels are not 16 separate pieces of hardware. One engine visits them one after another for every output sample:

1. For each channel that is on: take 16 source samples around the channel's position from its sample cache, multiply each by a filter coefficient and add them up (one DSP slice, 16 clocks).
2. Multiply the result by the channel's left and right volumes and add to the mix (two more DSP slices).
3. Move the position on by STEP, following loops.

At 48 kHz there are about 2,080 clocks of 100 MHz per output sample. All 16 channels take about 350, so the engine has plenty of time to spare. More channels, or higher output rates, could be added later without new multipliers.

### 4.2 Samples and loops

- **Formats:** 16-bit signed (big-endian, as the 68000 stores it) or 8-bit signed, per channel.
- **START** is the address of the first sample. **LENGTH**, **LOOPSTART** and **LOOPLEN** are counted in samples.
- At the end of the sample, the channel continues from LOOPSTART for LOOPLEN samples, repeatedly. With LOOPLEN = 0 it stops (a one-shot sound such as a drum).
- **Queued next sample (as on the Amiga):** writes to CTRL format bits, START, LENGTH, LOOPSTART and LOOPLEN while a channel is playing are held, and take effect when the current sample ends or loops. A music player can queue the next note without exact timing. Writes to STEP and VOL take effect at once.
- The filter looks 8 samples behind and 8 ahead of the position. Before the start of a sample it uses silence. Around a loop it uses the samples from the loop start, so loops are seamless.

### 4.3 Pitch

STEP is how far the channel moves through the sample for each output sample, in 8.16 fixed point:

| STEP | Effect |
|------|--------|
| `0x010000` | Plays at the output rate, as recorded if the sample was recorded at that rate |
| `0x008000` | An octave lower |
| `0x020000` | An octave higher |

To play a sample recorded at rate R at its own pitch: STEP = R ÷ output rate × 65536. Musical notes then multiply that by 2^(semitones ÷ 12).

### 4.4 Resampling filter

Each output sample is made from the 16 source samples nearest the exact position, weighted by a **windowed-sinc** filter (Kaiser window, β = 10.5, cut-off at 0.38 × the sample's own rate). The filter is stored as 128 phases × 16 coefficients in block RAM; the top 7 bits of the position's fraction choose the phase.

Measured on the filter design:

| | Result |
|---|---|
| Treble | Within 0.01 dB up to 0.2 × the sample's rate, −1 dB at 0.3 × (9.6 kHz and 14.4 kHz for a 48 kHz sample) |
| Aliasing and images | At least 105 dB down |

This is for STEP up to 1 (playing at or below the sample's own rate). Higher pitches need the next section.

### 4.5 Pitching up: octave copies

When STEP is above 1, the channel skips through the sample faster than the filter allows, and high frequencies alias. The cure is to play a copy of the sample that has been filtered and halved in rate in advance:

- A sample can be stored with **up to 3 octave copies** after it: the original (LENGTH samples), then a half-rate copy (LENGTH ÷ 2), a quarter-rate copy (LENGTH ÷ 4) and an eighth-rate copy (LENGTH ÷ 8), one after another in memory. CTRL.OCTAVES says how many copies there are.
- For each output sample the engine picks the smallest copy that brings the effective step to 1 or below, and scales the position, loop points and step to match. This happens automatically, including when STEP changes during a note (pitch slides, vibrato).
- LENGTH, LOOPSTART and LOOPLEN must be multiples of 2^OCTAVES.
- The copies are made once, when the sample is prepared, by a conversion tool (in `tools/`) or by the CPU. Each copy is low-pass filtered, then every other sample kept. They add up to 87.5% more memory with 3 copies.
- **Trade-off:** between octaves, a copy has less treble than the original. For example at STEP 1.5 the half-rate copy is used, and the top quarter of the treble range is lost. This is the usual trade-off of this method (open point A2).
- With OCTAVES = 0, pitching up simply aliases.

### 4.6 Nearest mode

With CTRL.NEAREST set, the channel skips the filter and takes the nearest source sample, as the Amiga did. This gives the gritty, aliased sound of Amiga trackers on purpose. It costs nothing extra.

### 4.7 Sample cache and memory

- Each channel has a **64-byte sample cache** (32 samples at 16-bit) in block RAM, holding the samples around its position and a little ahead.
- A **fetcher** keeps the caches topped up, reading 12-byte bursts from Chip RAM. It always serves the channel whose cache is lowest first.
- **Guaranteed bandwidth:** 6 of audio's 8 fixed slots per line (spec 5, section 7.1) are shared by the 16 channels. That is at least 2.2 MB/s, or 140 KB/s per channel with all 16 playing. A 16-bit channel at 48 kHz needs 96 KB/s at STEP 1, so with octave copies (which keep the effective step at 1 or below) all 16 channels always fit.
- **Beyond that:** fast pitch-ups without octave copies, or many 16-bit channels at high steps, can need more. When a cache runs low, the fetcher also takes free odd slots, after the CPU and sprites but before the copper and the DMA engine (spec 5, section 6).
- If a cache runs empty, the channel repeats its last value until data arrives and STARVED is set. This should not happen within the guaranteed limits.

## 5. Stream

The stream plays a stereo buffer that software fills: 16-bit signed samples, left then right, in a ring buffer in Chip RAM.

- **STRBASE** and **STRLEN** (in frames, one frame = left + right = 4 bytes) define the ring. The stream plays from start to end and wraps round.
- **Interrupts** at the half-way point and at the end. Each one means the other half is now free to refill.
- **STRPOS** reads back the frame being played.
- The stream reads from Chip RAM through the other 2 fixed audio slots per line: 24 bytes per line, against 6 needed at 48 kHz.

The DMA engine's MIX operation (spec 11, section 3.1) was meant for filling the stream with many mixed voices. It is on hold; with 16 good-quality hardware channels it may not be needed at all.

## 6. Registers

Offsets in the custom register block at `0xE00000`. Spec 3 sets the final addresses.

**Global:**

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x400` | AUDCON | EN (0) | Audio output on |
| `0x404` | AUDRATE | 15–0 | D: output rate = 200 MHz ÷ D |
| `0x408` | AUDVOL | L 15–8, R 7–0 | Master volume |
| `0x40C` | AUDSTAT | STRHALF (0), STREND (1), STARVED (2) | Sticky flags, write 1 to clear |
| `0x410` | AUDINTEN | Same layout as AUDSTAT | Interrupt enables |
| `0x414` | AUDCHEND | 15–0 | Channel n reached its end or looped; sticky, write 1 to clear |
| `0x418` | AUDCHINTEN | 15–0 | Interrupt enables for AUDCHEND |

**Stream:**

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x420` | STRCON | EN (0) | Stream on |
| `0x424` | STRBASE | 22–0 | Ring buffer start (4-byte aligned) |
| `0x428` | STRLEN | 15–0 | Ring length in frames (even) |
| `0x42C` | STRPOS | 15–0 | Read: frame being played |

**Per channel** (channel n = 0–15 at `0x440 + n × 0x20`):

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `+0x00` | CTRL | EN (0), BITS16 (1), NEAREST (2), OCTAVES (5–4) | On; 16-bit samples; nearest mode; number of octave copies (0–3). Format bits are queued |
| `+0x04` | START | 22–0 | Sample start address (queued) |
| `+0x08` | LENGTH | 22–0 | Samples (queued) |
| `+0x0C` | LOOPSTART | 22–0 | Loop start, in samples from START (queued) |
| `+0x10` | LOOPLEN | 22–0 | Loop length in samples; 0 = one-shot (queued) |
| `+0x14` | STEP | 23–0 | Pitch, 8.16 fixed point |
| `+0x18` | VOL | L 15–8, R 7–0 | Volume |
| `+0x1C` | POS | 22–0 | Read: current position, in samples from START |

**DMACON** (spec 5, section 8): bit 3 becomes **AUDEN** (the hardware channels; each also has its own CTRL.EN), bit 4 is **STREN** (the stream). Bits 2–0 are unused.

**Interrupts:** level 4, shared with the DMA engine; vectored, so each source has its own handler.

## 7. FPGA resources

| Item | Resource |
|------|----------|
| Filter coefficients: 128 phases × 16 taps × 18 bits | 2 block RAMs |
| Sample caches (16 × 64 bytes) and stream FIFO | 1 block RAM |
| DSP slices | 5: filter, left and right volume, master volume left and right |
| Channel state (16 channels), fetcher, mixer, sigma-delta | Estimate 900–1,300 LUTs |

## 8. Open points

| # | Item |
|---|------|
| A1 | Measure the audio quality through the miniSpartan6+'s filter; decide whether the final PCB needs an I2S DAC |
| A2 | Treble loss between octave copies: a second coefficient table with a lower cut-off could reduce it, at the cost of 2 more block RAMs |
| A3 | Is 128 filter phases enough? Rounding the position to 1/128 of a sample adds a little noise; interpolating between phases or using 256 phases would remove it |
| A4 | Audio over HDMI (video spec open point V6) |
| A5 | Effects such as echo or reverb in hardware, using spare engine time |

## 9. Tests

- **Rates:** check the output rate for each D value in simulation.
- **Filter:** play sine sweeps at STEP from 1/16 to 8, with and without octave copies; measure the aliasing and treble against the figures in 4.4 and 4.5, using a Python reference resampler.
- **Channels:** 8- and 16-bit, one-shot and looping, seamless loops (no click at the loop point), queued next sample taken exactly at the end or loop point, AUDCHEND interrupts, nearest mode.
- **All 16 at once:** 16 channels of 16-bit samples with octave copies, at a busy screen mode, for many seconds: never STARVED.
- **Stream:** ring wrap, half and end interrupts, STRPOS.
- **Mixer:** 24-bit sum and saturation with all channels and the stream at full volume; master volume.
- **Sigma-delta:** run the modulator on a sine wave in simulation and check the noise level after a model of the board's filter.
