# FPGA RTL

Planned modules:

- `bus_if.v` – 68000 bus interface: decode, `/DTACK`, byte lanes
- `vga_timing.v` – 640×480 @ 60 Hz sync generator
- `video.v` – text and bitmap modes, sprites
- `vram_arb.v` – arbitration between CPU and video fetch
- `audio.v` – PCM channels / synth, I2S or PWM output
- `top.v` – pin-level top module
