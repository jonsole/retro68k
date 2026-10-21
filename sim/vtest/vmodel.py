#!/usr/bin/env python3
"""Reference model of the video (spec 4): renders a frame from the video
state the testbench dumped and the Chip RAM contents, and compares it pixel
by pixel with the frame the simulation showed.

    vmodel.py BUILD_DIR RAM.hex [OUT.png]

BUILD_DIR holds frame.ppm, vstate_regs.txt and vstate_pal.hex. Exits 1 on
any difference, or if a layer ran out of data (VIDSTAT.OVERRUN).
"""
import sys


def load_ram(path):
    ram, a = {}, 0
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        if line[0] == "@":
            a = int(line[1:], 16)
        else:
            ram[a] = int(line, 16)
            a += 1
    return ram


def load_state(d):
    regs, layers, bpt = {}, [], {}
    for line in open(d + "/vstate_regs.txt"):
        f = line.split()
        if f[0] == "layer":
            kv = dict(zip(f[2::2], (int(x) for x in f[3::2])))
            layers.append(kv)
        elif f[0] == "bpt":
            bpt[int(f[1])] = int(f[2])
        else:
            regs[f[0]] = int(f[1])
    pal = [int(l, 16) & 0xFFFFFF for l in open(d + "/vstate_pal.hex")]
    return regs, layers, bpt, pal


def load_ppm(path):
    t = open(path).read().split()
    assert t[0] == "P3"
    w, h = int(t[1]), int(t[2])
    v = list(map(int, t[4:]))
    return w, h, [(v[i] << 16) | (v[i + 1] << 8) | v[i + 2] for i in range(0, len(v), 3)]


def widen(v, d):
    top = (v << (8 - d)) & 0xFF
    r, k = top, 1
    while k * d < 8:
        r |= top >> (k * d)
        k += 1
    return r


def render(regs, layers, bpt, pal, ram):
    W, H = regs["hvis"], regs["vvis"]
    direct = (regs["vidcon"] >> 4) & 1
    blankall = (regs["vidcon"] >> 2) & 1
    prio = regs["prio"]
    word = lambda a: ram.get((a & 0x7FFFFF) >> 1, 0)

    # Per layer and line: (opaque, index, raw) for every pixel
    out = [[None] * 3 for _ in range(H)]
    for n, L in enumerate(layers):
        c = L["ctrl"]
        en, planar, lb, transp = c & 1, (c >> 1) & 1, (c >> 2) & 3, (c >> 4) & 1
        hs, vs, palofs, planes = (c >> 6) & 3, (c >> 8) & 3, (c >> 12) & 15, ((c >> 16) & 7) + 1
        mod = L["mod"] - 0x10000 if L["mod"] & 0x8000 else L["mod"]
        xs, xe, ys, ye, sx = L["xs"], L["xe"], L["ys"], L["ye"], L["sx"]
        nplanes = planes if planar else 1
        bpp = 1 if planar else 1 << lb
        depth = planes if planar else bpp
        deep = depth > 4
        ptr = [bpt[8 * n + p] for p in range(8)]
        w = xe - xs
        srcpix = (w + (1 << hs) - 1) >> hs
        length = (srcpix * bpp + 15) // 16 * 2          # bytes per plane line
        vmax = (1 << vs) - 1
        vsub = 0
        for y in range(H):
            row = [(False, 0, 0)] * W
            if en and ys <= y < ye:
                vsub = 0 if (y == ys or vsub == vmax) else vsub + 1
                for x in range(max(xs, 0), min(xe, W)):
                    k = (x - xs) >> hs
                    if planar:
                        bi = (sx & 15) + k
                        v = 0
                        for p in range(nplanes):
                            if (word(ptr[p] + 2 * (bi >> 4)) >> (15 - (bi & 15))) & 1:
                                v |= 1 << p
                    else:
                        fine = (sx & 15) << lb
                        bo = fine + k * bpp
                        v = (word(ptr[0] + 2 * (bo >> 4)) >> (16 - bpp - (bo & 15))) & ((1 << bpp) - 1)
                    idx = v if deep else (palofs * 16 + (v & 15))
                    row[x] = (not (transp and v == 0), idx, v)
                if vsub == vmax:
                    for p in range(nplanes):
                        ptr[p] += length + mod
            out[y][n] = (row, depth)

    img = []
    for y in range(H):
        for x in range(W):
            if blankall and not direct:
                img.append(regs["bg"])
            elif direct:
                rgb = 0
                for n in range(3):
                    row, d = out[y][n]
                    rgb = (rgb << 8) | widen(row[x][2], d)
                img.append(rgb)
            else:
                col = regs["bg"]
                for p in (2, 1, 0):                      # back to front
                    l = (prio >> (2 * p)) & 3
                    if l < 3:
                        op, idx, _ = out[y][l][0][x]
                        if op:
                            col = pal[idx]
                img.append(col)
    return W, H, img


def main():
    d, ramfile = sys.argv[1], sys.argv[2]
    regs, layers, bpt, pal = load_state(d)
    W, H, want = render(regs, layers, bpt, pal, load_ram(ramfile))
    fw, fh, got = load_ppm(d + "/frame.ppm")
    errors = 0
    if (fw, fh) != (W, H):
        print("vmodel: frame is %dx%d, expected %dx%d" % (fw, fh, W, H))
        errors += 1
    else:
        for i in range(W * H):
            if got[i] != want[i]:
                if errors < 10:
                    print("vmodel: pixel (%d, %d) is %06x, expected %06x" % (i % W, i // W, got[i], want[i]))
                errors += 1
    if (regs["vidstat"] >> 4) & 7:
        print("vmodel: OVERRUN set: VIDSTAT %x" % regs["vidstat"])
        errors += 1
    if len(sys.argv) > 3:
        try:
            from PIL import Image
            im = Image.new("RGB", (W, H))
            im.putdata([((c >> 16) & 255, (c >> 8) & 255, c & 255) for c in want])
            im.save(sys.argv[3])
        except ImportError:
            pass
    print("vmodel: %d differences in %d x %d" % (errors, W, H))
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
