#!/usr/bin/env python3
"""Reference model of the DMA engine and blitter (spec 11): what a job does
to Chip RAM, pixel by pixel.

Used two ways:
  - as a library: dgen.py builds tests with run_job();
  - from the command line, to check a simulation:

        dmodel.py JOBS.json RAM_BEFORE.hex RAM_AFTER.hex

    JOBS.json lists each channel's jobs in order (the channels use separate
    memory, so the order between channels does not matter). RAM_BEFORE is
    the Chip RAM given to the simulation, RAM_AFTER what the testbench
    dumped at the end (both $readmemh files of 16-bit words). Exits 1 on any
    difference.

A job is a dict with the descriptor's fields, decoded:
  op ('COPY', 'FILL', 'KEYCOPY', 'LOGIC', 'ADD'), fn, bpp (1, 2, 4, 8),
  desc, srckind ('mem', 'value', 'none'), src, dst, width, height,
  srcbit, dstbit, sstride, dstride (signed), value.
Only Chip RAM sources and destinations are modelled here.
"""
import json
import sys

OPS = {"COPY": 0, "FILL": 1, "KEYCOPY": 2, "LOGIC": 3, "ADD": 4}
KINDS = {"mem": 0, "port": 1, "none": 2, "value": 3}


def get_pix(mem, addr, pos, b):
    """Pixel pos (0 = most significant) of the byte at addr, b bits wide."""
    sh = 8 - b * (pos + 1)
    return (mem[addr] >> sh) & ((1 << b) - 1)


def put_pix(mem, addr, pos, b, v):
    sh = 8 - b * (pos + 1)
    m = ((1 << b) - 1) << sh
    mem[addr] = (mem[addr] & ~m & 0xFF) | ((v << sh) & m)


def locate(base, bit, i, b):
    """Byte address and pixel position of pixel i of a row starting at
    (base, bit)."""
    off = bit * b + i * b               # bits from the row's first byte
    return base + (off >> 3), (off & 7) // b


def value_pix(value, addr, b):
    """FILL's value (and the VALUE source) for the pixel at addr: at 8 bpp
    VALUE's byte addr mod 4, most significant first; below, its low b bits."""
    if b == 8:
        return (value >> (24 - 8 * (addr & 3))) & 0xFF
    return value & ((1 << b) - 1)


def add_pix(d, s, b, sat, signed):
    top = (1 << b) - 1
    if not sat:
        return (d + s) & top
    if not signed:
        return min(d + s, top)
    sx = lambda v: v - (1 << b) if v >> (b - 1) else v
    r = sx(d) + sx(s)
    r = max(-(1 << (b - 1)), min((1 << (b - 1)) - 1, r))
    return r & top


def logic_pix(d, s, b, fn):
    r = 0
    for k in range(b):
        sb, db = (s >> k) & 1, (d >> k) & 1
        r |= ((fn >> (sb * 2 + db)) & 1) << k
    return r


def run_job(mem, j):
    """Apply one job to mem (a bytearray of Chip RAM), in the engine's order:
    forwards, or with DESC from the last pixel of the last row back to the
    first. Each source pixel is read just before its destination pixel is
    written, which is what the hardware gives for every overlap a job is
    allowed (spec 11, section 3: DESC when the destination is after the
    source)."""
    b, w, h = j["bpp"], j["width"], j["height"]
    if w == 0 or h == 0:
        return
    op = j["op"]
    rows = range(h - 1, -1, -1) if j["desc"] else range(h)
    cols = range(w - 1, -1, -1) if j["desc"] else range(w)
    for r in rows:
        srow = j["src"] + r * j["sstride"]
        drow = j["dst"] + r * j["dstride"]
        for i in cols:
            da, dp = locate(drow, j["dstbit"], i, b)
            if j["srckind"] == "mem":
                sa, sp = locate(srow, j["srcbit"], i, b)
                s = get_pix(mem, sa, sp, b)
            else:                                       # FILL, or VALUE as the source
                s = value_pix(j["value"], da, b)
            d = get_pix(mem, da, dp, b)
            if op in ("COPY", "FILL"):
                v = s
            elif op == "KEYCOPY":
                if s == j["value"] & ((1 << b) - 1):
                    continue
                v = s
            elif op == "LOGIC":
                v = logic_pix(d, s, b, j["fn"])
            elif op == "ADD":
                v = add_pix(d, s, b, (j["fn"] >> 0) & 1, (j["fn"] >> 1) & 1)
            put_pix(mem, da, dp, b, v)


def encode(j, nxt=0, irq=0):
    """The job as eight descriptor long words (spec 11, section 3)."""
    bppc = {1: 0, 2: 1, 4: 2, 8: 3}[j["bpp"]]
    fn = j.get("fn", 0)
    if j["op"] == "ADD":
        fn = (fn & 3)                     # bit 4 saturate, bit 5 signed: FN bits 0 and 1
    ctrl = (OPS[j["op"]] | (fn << 4) | (bppc << 8) | (j["desc"] << 10) | (irq << 12)
            | (KINDS[j["srckind"]] << 13))
    return [ctrl, j["src"] if j["srckind"] == "mem" else 0, j["dst"], j["width"],
            j["height"] | (j["srcbit"] << 16) | (j["dstbit"] << 20),
            ((j["sstride"] & 0xFFFF) << 16) | (j["dstride"] & 0xFFFF),
            j.get("value", 0), nxt]


def load_hex(path, size=0x400000):
    mem, a = bytearray(size), 0
    for line in open(path):
        line = line.split("//")[0].strip()
        if not line:
            continue
        if line[0] == "@":
            a = int(line[1:], 16) * 2
        else:
            w = int(line, 16)
            if a + 1 < size:
                mem[a], mem[a + 1] = w >> 8, w & 0xFF
            a += 2
    return mem


def main():
    jobs = json.load(open(sys.argv[1]))
    mem = load_hex(sys.argv[2])
    got = load_hex(sys.argv[3])
    for ch in jobs["channels"]:
        for j in ch:
            run_job(mem, j)
    lo, hi = jobs.get("check", [0, len(mem)])
    errors = 0
    for a in range(lo, hi):
        if mem[a] != got[a]:
            if errors < 10:
                print("dmodel: byte %06x is %02x, expected %02x" % (a, got[a], mem[a]))
            errors += 1
    print("dmodel: %d jobs, %d differences in %06x-%06x"
          % (sum(len(c) for c in jobs["channels"]), errors, lo, hi))
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
