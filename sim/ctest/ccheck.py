#!/usr/bin/env python3
"""Check the copper test's frame (ctest.s): colour 0 changes at beam positions.

    ccheck.py DIR

Reads DIR/frame.ppm. Every row is checked whole: each change of colour
must come at the expected pixel plus the same small delay (the time from
the WAIT ending to the colour showing, open point C2 of spec 10), and the
colours between the changes must be exactly right.
"""
import sys

BLACK, RED, GREEN, BLUE = (0, 0, 0), (255, 0, 0), (0, 255, 0), (0, 0, 255)


def loop_colour(k):
    y = 0x0010 + 0x0808 * k                 # Y = green and blue, red kept (0)
    return (0, (y >> 8) & 255, y & 255)


def expected():
    """For each row: the colour at its start, then (pixel, colour) changes."""
    rows = {}
    for r in range(576):
        if r < 100:
            rows[r] = (BLACK, [])
        elif r == 100:
            rows[r] = (BLACK, [(200, RED), (500, GREEN)])
        elif r < 200:
            rows[r] = (GREEN, [])
        elif r <= 210:
            before = GREEN if r == 200 else loop_colour(r - 201)
            rows[r] = (before, [(360, loop_colour(r - 200))])
        elif r < 300:
            rows[r] = (loop_colour(10), [])
        elif r == 300:
            rows[r] = (loop_colour(10), [(0, BLUE)])
        else:
            rows[r] = (BLUE, [])
    return rows


def main():
    d = sys.argv[1]
    f = open(d + "/frame.ppm").read().split()
    w, h = int(f[1]), int(f[2])
    px = list(map(int, f[4:]))
    pix = lambda x, y: tuple(px[3 * (y * w + x): 3 * (y * w + x) + 3])

    errors, delays = 0, []
    for r, (start, changes) in expected().items():
        row = [pix(x, r) for x in range(w)]
        x, cur = 0, start
        for (at, col) in changes + [(w, None)]:
            # the run of cur up to the change, which may come a little late
            while x < w and row[x] == cur and row[x] != col:
                x += 1
            if col is None:
                break
            if x < at or x > at + 8 or x >= w or row[x] != col:
                if errors < 10:
                    print(f"ccheck: row {r}: expected {cur} up to about x={at}, then {col}; "
                          f"at x={x} found {row[x] if x < w else '-'}")
                errors += 1
                break
            delays.append(x - at)
            cur = col
        if col is None and x != w:
            if errors < 10:
                print(f"ccheck: row {r}: expected {cur} to the end; at x={x} found {row[x]}")
            errors += 1

    if delays:
        print(f"ccheck: {len(delays)} colour changes, delay {min(delays)}-{max(delays)} pixels")
    if delays and max(delays) - min(delays) > 2:
        print("ccheck: the delay varies by more than 2 pixels")
        errors += 1
    print(f"ccheck: {errors} errors")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
