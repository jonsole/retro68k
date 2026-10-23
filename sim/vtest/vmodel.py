#!/usr/bin/env python3
"""Reference model of the video (spec 4) and the sprites (spec 9): renders a frame from the video
state the testbench dumped and the Chip RAM contents, and compares it pixel
by pixel with the frame the simulation showed.

    vmodel.py BUILD_DIR RAM.hex [OUT.png]

BUILD_DIR holds frame.ppm, vstate_regs.txt, vstate_spr.txt (every write to
the sprites' registers, with the frame and beam position) and
vstate_pal.hex. Exits 1 on any difference, or if a layer ran out of data
(VIDSTAT.OVERRUN).
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
    regs, layers, bpt, pdma, dat, sprites = {}, [], {}, {}, {}, []
    for line in open(d + "/vstate_regs.txt"):
        f = line.split()
        if f[0] == "layer":
            kv = dict(zip(f[2::2], (int(x) for x in f[3::2])))
            layers.append(kv)
        elif f[0] == "bpt":
            bpt[int(f[1])] = int(f[2])
        elif f[0] == "bpldma":
            pdma[int(f[1])] = int(f[2])
        elif f[0] == "dat":
            dat[int(f[1])] = int(f[2])
        elif f[0] == "sprite":
            sprites.append(dict(zip(f[2::2], (int(x) if x.isdigit() else 0 for x in f[3::2]))))
        else:
            regs[f[0]] = int(f[1])
    pal = [int(l, 16) & 0xFFFFFF for l in open(d + "/vstate_pal.hex")]
    regs["pdma"], regs["dat"], regs["sprites"] = pdma, dat, sprites
    try:
        regs["sprlog"] = [tuple(int(x) for x in l.split()) for l in open(d + "/vstate_spr.txt") if l.strip()]
    except FileNotFoundError:
        regs["sprlog"] = []
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


X0, Y0 = 144, 49                                  # the picture's first pixel and line, in beam coordinates


def render(regs, layers, bpt, pal, ram):
    W, H = regs["hvis"], regs["vvis"]
    direct = (regs["vidcon"] >> 4) & 1
    share = (regs["vidcon"] >> 5) & 1
    # palette p's entry i (spec 4, section 4.6): p 0-2 a layer's, 3 the sprites';
    # with VIDCON.SHAREPAL everything uses PALETTE0
    col_of = lambda p, i: pal[(0 if share else p) * 256 + i]
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
        # the window, from beam coordinates (spec 4, section 3.3) to the picture's, clamped to it
        cx = lambda v: min(max(v - X0, 0), W)
        cy = lambda v: min(max(v - Y0, 0), H)
        xs, ye_, sx = cx(L["xs"]), None, L["sx"]
        xe = max(cx(L["xe"]), xs)
        ys, ye = cy(L["ys"]), cy(L["ye"])
        nplanes = planes if planar else 1
        bpp = 1 if planar else 1 << lb
        depth = planes if planar else bpp
        deep = depth > 4
        ptr = [bpt[8 * n + p] for p in range(8)]
        wr = (c >> 20) & 15
        m = (1 << (wr + 9)) - 1 if wr else 0x7FFFFF       # CTRL.WRAP: only these bits move
        wadd = lambda a, d: (a & ~m) | ((a + d) & m)
        pm = regs["pdma"].get(n, 0xFF)
        # a plane with its DMA off shows its data register in every group
        const = [None if (pm >> p) & 1 else regs["dat"][8 * n + p] for p in range(8)]
        w = xe - xs
        srcpix = (w + (1 << hs) - 1) >> hs
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
                            wv = const[p] if const[p] is not None else word(wadd(ptr[p], 2 * (bi >> 4)))
                            if (wv >> (15 - (bi & 15))) & 1:
                                v |= 1 << p
                    else:
                        fine = (sx & 15) << lb
                        bo = fine + k * bpp
                        v = (word(wadd(ptr[0], 2 * (bo >> 4))) >> (16 - bpp - (bo & 15))) & ((1 << bpp) - 1)
                    idx = v if deep else (palofs * 16 + (v & 15))
                    row[x] = (not (transp and v == 0), idx, v)
                if vsub == vmax:
                    for p in range(nplanes):
                        ptr[p] = wadd(ptr[p], mod)          # BPLSTRIDE: from the line's start
            out[y][n] = (row, depth)

    spr = render_sprites(regs, ram, W, H)        # [y][x] = list of (n, idx, depth), front first
    coll = 0
    img = []
    for y in range(H):
        for x in range(W):
            here = spr[y][x]
            # collisions (spec 9, section 6)
            if len(here) > 1:
                for n, _, _ in here:
                    coll |= 1 << n
            for l in range(3):
                if out[y][l][0][x][0]:
                    for n, _, _ in here:
                        coll |= 1 << (8 * (l + 1) + n)
            if blankall and not direct:
                img.append(regs["bg"])
            elif direct:
                if here:
                    img.append(col_of(3, here[0][1]))     # sprites in front, SPRPALETTE colours
                    continue
                rgb = 0
                for n in range(3):
                    row, d = out[y][n]
                    rgb = (rgb << 8) | widen(row[x][2], d)
                img.append(rgb)
            else:
                # back to front: DEPTH 3 sprites, back layer, DEPTH 2, middle, DEPTH 1, front, DEPTH 0
                col = regs["bg"]
                for p in (3, 2, 1, 0):
                    for n, idx, dep in reversed(here):
                        if dep == p:
                            col = col_of(3, idx)
                    if p > 0:
                        l = (prio >> (2 * (p - 1))) & 3
                        if l < 3:
                            op, idx, _ = out[y][l][0][x]
                            if op:
                                col = col_of(l, idx)
                img.append(col)
    regs["coll_model"] = coll
    return W, H, img


def merge(old, new, be):
    """A write by bytes (spec 3, section 2)."""
    return sum((new if (be >> b) & 1 else old) & (0xFF << (8 * b)) for b in range(4))


def render_sprites(regs, ram, W, H):
    """Each visible pixel: the opaque sprites there, lowest number first.

    Replays the frame's writes to the sprites' registers (spec 9, section 3):
    a write acts from the next line (the line after next if it came at the
    very end of a line, after the settings were taken); a CTL write starts
    the sprite; the vertical blank stops every sprite. At the start of each
    line a running sprite whose window covers it shows, its image line
    moved on by YSTEP (not on its first line, or after a PT write)."""
    word = lambda a: ram.get((a & 0x7FFFFF) >> 1, 0)
    grid = [[[] for _ in range(W)] for _ in range(H)]
    F = regs.get("frame", 0)
    R = [[0] * 6 for _ in range(8)]                # as written: PT, H, V, CTL, DAT, STEP
    ev = []
    for i, (fr, line, h, n, r, val, be) in enumerate(regs["sprlog"]):
        if fr < F:
            R[n][r] = merge(R[n][r], val, be)
        elif fr == F:
            ev.append((line + 1 if h < 836 else line + 2, i, n, r, val, be))
    ev.sort()
    run, pend, yf = [False] * 8, [False] * 8, [0] * 8
    lst = [R[n][0] & 0x7FFFFE for n in range(8)]
    lim = lambda s: 0x800 if s == 0 else max(0x80, min(0x8000, s))
    j = 0
    for y in range(1, 625):                         # beam lines (the vertical blank stops every sprite at line 0)
        while j < len(ev) and ev[j][0] <= y:
            _, _, n, r, val, be = ev[j]
            j += 1
            if r == 0:
                lst[n] = merge(lst[n], val, be) & 0x7FFFFE
                pend[n] = False
            else:
                R[n][r] = merge(R[n][r], val, be)
            if r == 3:
                run[n], pend[n] = True, False
        for n in range(8):
            if not run[n] or not regs["sprites"][n]["dma"]:
                continue
            Hr, Vr, Cr, Sr = R[n][1], R[n][2], R[n][3], R[n][5]
            # beam coordinates: the line is beam pixels 0-863, the picture 144-863
            hs, he = min(Hr & 0x7FF, 864) - X0, ((Hr >> 16) & 0x7FF) - X0
            hs_c, xe = hs, max(min(he, 720), hs)
            vs, ve = Vr & 0x7FF, min((Vr >> 16) & 0x7FF, 625)
            b = (Cr >> 12) & 3
            lb = (2 if b == 3 else b) + 1
            bpp, ppw = 1 << lb, 16 >> lb
            depth, pal = (Cr >> 20) & 3, (Cr >> 24) & 15
            # the scale (spec 9, section 3.2): 5.11 source pixels per screen pixel
            xs, ys = lim(Sr & 0xFFFF), lim(Sr >> 16)
            srcf = -(-(he - hs) * xs // 2048) if he > hs else 0
            srcs = -(-(xe - hs_c) * xs // 2048) if xe > hs_c else 0
            wf = (srcf * bpp + 15) // 16
            wv = min((srcs * bpp + 15) // 16, wf) if srcs else 0
            if wv == 0 or not (vs <= y < ve):
                continue
            if pend[n]:
                s = yf[n] + (ys & 0x7FF)
                yf[n] = s & 0x7FF
                lst[n] = (lst[n] + ((ys >> 11) + (s >> 11)) * 2 * wf) & 0x7FFFFF
            else:
                yf[n] = 0
            pend[n] = True
            if y < Y0:
                continue
            seq = []
            for k in range(wv):
                w = word(lst[n] + 2 * k)
                seq += [(w >> (16 - bpp * (i + 1))) & bpp_mask(bpp) for i in range(ppw)]
            for x in range(max(hs_c, 0), min(xe, W)):
                i = (x - hs_c) * xs >> 11
                v = seq[i] if i < len(seq) else 0
                if v:
                    idx = v if bpp == 8 else (pal << 4) | (v & 15)
                    grid[y - Y0][x].append((n, idx, depth))
    return grid


def bpp_mask(b):
    return (1 << b) - 1


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
    if (regs["vidstat"] >> 4) & 15:
        print("vmodel: OVERRUN or SPRUNDER set: VIDSTAT %x" % regs["vidstat"])
        errors += 1
    if "sprcoll" in regs and regs["sprites"] and regs["sprcoll"] != regs["coll_model"]:
        print("vmodel: SPRCOLL is %08x, expected %08x" % (regs["sprcoll"], regs["coll_model"]))
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
