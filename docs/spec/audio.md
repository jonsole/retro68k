# Spec 6: Audio

Status: **v1 scope**

Four sample channels, in the spirit of the Amiga's Paula. Each plays a sample from Chip RAM by itself, at any pitch, with its own left and right volume, and needs no CPU work while it plays. A sample can loop, or the next one can be queued, exactly as on the Amiga.

(The larger draft, with 16 channels, a 16-tap resampling filter and a stereo stream, is in git history before this version. It may come back later.)

## 1. Summary

| Item | Value |
|------|-------|
| Channels | 4, all alike |
| Output rate | 100 MHz ÷ AUDRATE. Default 2083: 48.008 kHz. 2268: 44.092 kHz |
| Sample formats | 8-bit or 16-bit signed PCM, per channel |
| Pitch | A step per output sample, 4.16 fixed point: 1/65536 to just under 16 samples per output sample |
| Resampling | Linear interpolation between neighbouring samples; or "nearest" (no interpolation), per channel, for the raw Amiga sound |
| Volume and pan | Left and right volume per channel, 0–64 each (64 = full). After reset: channels 0 and 3 left, 1 and 2 right, as on the Amiga |
| Loops and queues | As the Amiga: a channel takes its address and length registers when it starts and again at the end of each block, and interrupts each time |
| Memory | One or two 16-bit reads per channel per output sample, at most 8 per output sample: under 1 MB/s. Its own channel in the scheduler (spec 5, section 6) |
| Mixer | The four channels summed; no clipping is possible |
| Output | Second-order sigma-delta DAC at 100 MHz on the KS3's audio pins: `audioext_l`, `audioext_r` (the jack) and `audioint` (the internal speaker, mono) |
| Interrupt | AUDIO (source 9): a channel took its registers (AUDSTAT) |

## 2. Comparison with the Amiga (Paula)

| Feature | Amiga | retro68k v1 |
|---------|-------|-------------|
| Channels | 4 | 4 |
| Sample size | 8-bit | 8- or 16-bit, per channel |
| Pitch | Each channel's DAC runs at the sample's own rate (AUDxPER) | All channels resampled to one output rate (AUDxSTEP); linear interpolation, or nearest for the Amiga sound |
| Volume | 0–64 per channel | 0–64 left and 0–64 right per channel |
| Stereo | Hard-panned: 0 and 3 left, 1 and 2 right | Any pan; that is the reset setting |
| Starting, looping, queuing | AUDxLC and AUDxLEN taken at the start and at the end of each block; an interrupt each time | The same |
| Enables | DMACON.AUD0EN–AUD3EN | The same |
| Interrupts | One per channel (AUD0–AUD3) | One source, AUDIO, with a bit per channel in AUDSTAT |
| Output | 8-bit DACs, analogue filter | 16-bit mix, sigma-delta DAC |

**Periods:** an Amiga period P (in 3,546,895 Hz ticks, PAL) gives a sample rate of 3,546,895 ÷ P. At the default 48.008 kHz the matching step is

```
   STEP = 3,546,895 × 65536 ÷ (P × 48,008)   ≈  4,841,856 ÷ P
```

so an Amiga MOD player needs only a table from periods to steps.

## 3. Output

### 3.1 Output rate

Every AUDRATE clocks of 100 MHz the audio unit makes one stereo output sample: it works out each channel's sample, mixes them, and hands the result to the DAC. AUDRATE is 16 bits, at least 200. The default, 2083, gives 48.008 kHz.

### 3.2 Mixer

```
   left  = Σ (channel sample × channel left volume)  ÷ 256
   right = Σ (channel sample × channel right volume) ÷ 256
```

A channel sample is 16 bits signed (an 8-bit sample is shifted up by 8), a volume 0–64, so each product fits in 22 bits, and four of them in 24: the result always fits in 16 bits. As on the Amiga, one channel at full volume uses a quarter of the output range, and nothing can clip.

### 3.3 DAC

A second-order sigma-delta modulator at 100 MHz turns each 16-bit output into a 1-bit stream on each pin; the board's filter turns that back into sound. `audioint` gets the mono mix, (left + right) ÷ 2. The input is scaled to half the modulator's range, which keeps it stable at full scale. The real quality depends on the board's filter and has to be measured (open point A1).

## 4. Channels

### 4.1 Blocks: starting, looping and queuing

A channel plays **blocks**. A block is a sample in Chip RAM: an address (AUDxLC) and a length in samples (AUDxLEN).

- When a channel is turned on (its AUDnEN bit in DMACON, with DMAEN), it takes AUDxLC and AUDxLEN, starts at the first sample, and sets its bit in AUDSTAT.
- When it plays past the end of the block, it takes AUDxLC and AUDxLEN **again**, carries on from the start of that block, and sets its bit in AUDSTAT again.

So, as on the Amiga:

- **A loop:** write AUDxLC and AUDxLEN once and turn the channel on. It plays the block over and over.
- **A sample with a loop:** write the whole sample, turn the channel on, and when AUDSTAT says the channel has taken it, write the loop part. The whole sample plays once, then the loop part for ever.
- **A queue:** each time the channel takes its registers, write the next block. It plays the blocks one after another with no gap.
- **A one-shot sound:** queue a block of silence after it, or turn the channel off when the second AUDSTAT bit comes.

The registers can be written at any time; the channel only takes them at the start of a block. A block of length 0 stops the channel (silent, no more interrupts) until it is turned off and on again.

Turning a channel off silences it at once. Turning it on again starts from its registers.

### 4.2 Pitch

Each output sample, a channel's position moves on by AUDxSTEP, 4.16 fixed point: `$10000` plays one sample per output sample (the sample's own rate is the output rate), `$8000` half that (an octave down), `$20000` twice (an octave up). The largest step is just under 16. A step past the end of a block carries on into the next block by the amount left over (if that is past the end of the next block too, it starts at its first sample).

### 4.3 Interpolation

The channel's sample is worked out from the two samples around its position:

```
   s = s0 + (s1 − s0) × frac ÷ 65536
```

where s0 is the sample at the position, s1 the one after it, and frac the position's fraction. At the last sample of a block, s1 is s0. With AUDxCTRL.NEAREST set, s = s0: each sample is held until the next, as on the Amiga.

### 4.4 Sample formats

- **8-bit** (CTRL.BITS16 = 0): signed bytes, two to a word, the first in the high byte. AUDxLC can be any byte address.
- **16-bit** (CTRL.BITS16 = 1): signed big-endian words. AUDxLC must be even.

### 4.5 Memory

For each output sample, each playing channel reads the word holding s0, and the word holding s1 if that is a different one: at most 8 reads per output sample, 384,000 a second at 48 kHz, under 1 MB/s. The audio channel owns memory cycle 2 of every slot (spec 5, section 6), 20 MB/s, so it is never short. Reads happen just before they are needed; there are no sample caches.

## 5. Registers

Offsets in the custom register block at `0xE00000`.

| Offset | Name | Access | Bits | Description |
|--------|------|--------|------|-------------|
| `0x404` | AUDRATE | RW | 15–0 | Output rate = 100 MHz ÷ AUDRATE. Default 2083 (48.008 kHz). Values below 200 act as 200 |
| `0x40C` | AUDSTAT | W1C | CH (3–0) | Bit n: channel n took its registers (started or reached the end of a block). Sticky; write 1 to clear |
| `0x410` | AUDINTEN | RW | CH (3–0) | Bit n: AUDSTAT bit n raises the AUDIO interrupt |

Channel n (0–3) at `0x440 + n × 0x20`:

| Offset | Name | Access | Bits | Description |
|--------|------|--------|------|-------------|
| `+0x00` | AUDxCTRL | RW | BITS16 (1), NEAREST (2) | Sample format; no interpolation |
| `+0x04` | AUDxLC | RW | 22–0 | Block address, in bytes (even for 16-bit). Taken at the start of each block |
| `+0x08` | AUDxLEN | RW | 22–0 | Block length, in samples. Taken at the start of each block. 0 stops the channel |
| `+0x0C` | AUDxSTEP | RW | 19–0 | Pitch: samples per output sample, 4.16. Default `$10000` |
| `+0x10` | AUDxVOL | RW | L (22–16), R (6–0) | Left and right volume, 0–64; above 64 acts as 64. Defaults: channels 0 and 3 left (64, 0), 1 and 2 right (0, 64) |
| `+0x14` | AUDxPOS | R | 22–0 | The sample the channel is playing, in the block |

Channel n plays while DMACON.DMAEN and DMACON.AUDnEN (bit n) are both set (spec 5, section 8). CTRL, STEP and VOL take effect from the next output sample; LC and LEN at the start of the next block.

**Interrupt:** source 9, AUDIO, in the interrupt controller (spec 13): any AUDSTAT bit with its AUDINTEN bit set. Default level 4. The handler reads AUDSTAT to see which channels, writes their next blocks if any, and clears their bits.

## 6. Examples

Playing a looped 8-bit sample on channel 1 at 22,050 Hz, centre:

```
    move.l  #sample,AUD1+AUD_LC(a4)
    move.l  #samplelen,AUD1+AUD_LEN(a4)
    move.l  #(22050*65536)/48008,AUD1+AUD_STEP(a4)    ; $7596
    move.l  #(32<<16)|32,AUD1+AUD_VOL(a4)            ; centre
    move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_AUD1EN_M,DMACON+2(a4)
```

A sample with a loop: as above, then, when AUDSTAT bit 1 is set (the channel has taken the whole sample), write the loop part:

```
    move.l  #sample+loopstart,AUD1+AUD_LC(a4)
    move.l  #looplen,AUD1+AUD_LEN(a4)
    move.l  #2,AUDSTAT(a4)                           ; clear bit 1
```

## 7. FPGA resources

| Item | Resource |
|------|----------|
| Registers and channel state (4 channels) | About 1,000 flip-flops |
| One shared engine: address, interpolation, volume, mixer; registers | About 1,250 LUTs, 3 DSP slices |
| Three sigma-delta modulators | About 280 LUTs |
| Total (Yosys, first build) | About 1,540 LUTs. Could be trimmed by about 300 by sharing one adder across the engine's steps (open point A4) |

## 8. Open points

| # | Item |
|---|------|
| A1 | The KS3's audio filter, and the real quality of the sigma-delta output, measured on the board |
| A2 | Interpolating across the end of a block into the next one (now s1 = s0 at the last sample: a tiny step at a loop point when interpolating) |
| A3 | Sound over HDMI |
| A4 | A smaller engine: one adder used in turn for the addresses and positions (there are 2,000 clocks per output sample) |

## 9. Tests

- **Golden output:** a test ROM plays all four channels at once, 8- and 16-bit, nearest and interpolated, steps below and above 1, odd addresses, and queued blocks of different lengths; the testbench records every output sample, and a Python model of section 3 and 4 must give exactly the same numbers.
- **DAC:** the sigma-delta streams, averaged over each output sample, follow the output samples.

## 10. Later versions

- More channels; the resampling filter and the stereo stream of the earlier draft
- A master volume; modulation (the Amiga's ADKCON)
- Sound over HDMI (A3)
