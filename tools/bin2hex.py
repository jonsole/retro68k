#!/usr/bin/env python3
"""Turn a big-endian binary into a $readmemh file of 16-bit words.

    bin2hex.py boot.bin boot.hex [words]

Pads with zeros to `words` (default 16384, the 32 KB boot ROM).
"""
import sys

def main():
    src, dst = sys.argv[1], sys.argv[2]
    words = int(sys.argv[3]) if len(sys.argv) > 3 else 16384
    data = open(src, "rb").read()
    if len(data) % 2:
        data += b"\0"
    if len(data) > 2 * words:
        sys.exit(f"bin2hex: {src} is {len(data)} bytes, more than {2 * words}")
    data += b"\0" * (2 * words - len(data))
    with open(dst, "w") as f:
        for i in range(0, len(data), 2):
            f.write(f"{data[i]:02x}{data[i + 1]:02x}\n")

if __name__ == "__main__":
    main()
