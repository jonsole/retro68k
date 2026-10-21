#!/usr/bin/env python3
"""Convert an 8x16 BDF font into a binary font for the boot ROM.

    bdf2font.py font.bdf font8x16.bin

256 characters x 16 bytes, one byte per pixel row, leftmost pixel in
bit 7 (4096 bytes). The boot ROM includes it to draw its console.
"""
import sys

W, H = 8, 16

def parse(path):
    glyphs = {}
    ascent = descent = None
    enc = None
    bbx = None
    rows = None
    for line in open(path, encoding="latin-1"):
        f = line.split()
        if not f:
            continue
        if f[0] == "FONT_ASCENT":
            ascent = int(f[1])
        elif f[0] == "FONT_DESCENT":
            descent = int(f[1])
        elif f[0] == "ENCODING":
            enc = int(f[1])
        elif f[0] == "BBX":
            bbx = [int(x) for x in f[1:5]]
        elif f[0] == "BITMAP":
            rows = []
        elif f[0] == "ENDCHAR":
            glyphs[enc] = (bbx, rows)
            rows = None
        elif rows is not None:
            rows.append(int(f[0], 16))
    if ascent is None or ascent + descent != H:
        sys.exit(f"bdf2font: expected a font {H} pixels high (ascent + descent)")
    return glyphs, ascent

def main():
    glyphs, ascent = parse(sys.argv[1])
    font = bytearray(256 * H)
    for code in range(256):
        if code not in glyphs:
            continue
        (bw, bh, bx, by), rows = glyphs[code]
        nbytes = (bw + 7) // 8
        top = ascent - (by + bh)              # first row of the glyph in the cell
        for r, bits in enumerate(rows):
            y = top + r
            if 0 <= y < H:
                v = bits >> (8 * nbytes - 8) if nbytes > 1 else bits
                v = (v >> bx) if bx >= 0 else (v << -bx)
                font[code * H + y] = v & 0xFF
    with open(sys.argv[2], "wb") as out:
        out.write(bytes(font))

if __name__ == "__main__":
    main()
