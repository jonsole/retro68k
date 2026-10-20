#!/usr/bin/env python3
"""retro68k register map generator.

Reads fpga/regmap.def (the one source for every hardware address) and:
  * checks it for mistakes (alignment, overlaps, bad fields, duplicate names),
  * checks it against the tables in docs/spec/registers.md,
  * writes firmware/include/hw.inc (vasm), firmware/include/hw.h (C)
    and fpga/rtl/regmap.vh (Verilog).

Usage:
  python3 tools/regmap.py            check, then write the generated files
  python3 tools/regmap.py --verify   check, and fail if a generated file is out of date (for CI)

Uses only the Python standard library.
"""

import argparse
import re
import shlex
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEF_FILE = ROOT / "fpga" / "regmap.def"
SPEC_FILE = ROOT / "docs" / "spec" / "registers.md"
OUT_ASM = ROOT / "firmware" / "include" / "hw.inc"
OUT_C = ROOT / "firmware" / "include" / "hw.h"
OUT_V = ROOT / "fpga" / "rtl" / "regmap.vh"

ACCESS = {"R", "W", "RW", "W1C", "RW1C", "SC", "Q"}
NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")


class DefError(Exception):
    pass


@dataclass
class Field:
    name: str
    hi: int
    lo: int

    @property
    def width(self):
        return self.hi - self.lo + 1

    @property
    def mask(self):
        return ((1 << self.width) - 1) << self.lo


@dataclass
class Reg:
    offset: int
    name: str
    access: str
    spec: str
    fields: list = field(default_factory=list)
    copy_from: str = None
    line: int = 0


@dataclass
class Group:
    """An array (repeated registers at a base) or a struct (a layout in memory)."""
    kind: str  # "array" or "struct"
    name: str
    count: int
    base: int
    stride: int
    spec: str
    regs: list = field(default_factory=list)
    line: int = 0


@dataclass
class RegList:
    name: str
    count: int
    offset: int
    access: str
    spec: str
    line: int = 0


@dataclass
class Area:
    name: str
    offset: int
    size: int
    access: str
    spec: str
    line: int = 0


@dataclass
class Block:
    name: str
    base: int
    size: int
    text: str
    regs: list = field(default_factory=list)
    groups: list = field(default_factory=list)
    reglists: list = field(default_factory=list)
    areas: list = field(default_factory=list)


@dataclass
class Const:
    name: str
    value: int
    text: str


@dataclass
class RegMap:
    blocks: list = field(default_factory=list)
    structs: list = field(default_factory=list)
    consts: list = field(default_factory=list)


# ---------------------------------------------------------------- parsing

def num(tok, line):
    try:
        return int(tok, 0)
    except ValueError:
        raise DefError(f"line {line}: '{tok}' is not a number")


def check_name(name, line):
    if not NAME_RE.match(name):
        raise DefError(f"line {line}: bad name '{name}' (use capitals, digits and _)")


def parse_fields(tokens, line):
    fields, copy_from = [], None
    for tok in tokens:
        if tok.startswith("fields="):
            copy_from = tok.split("=", 1)[1]
            continue
        if "=" not in tok:
            raise DefError(f"line {line}: field '{tok}' must be NAME=BIT or NAME=HIGH:LOW")
        name, bits = tok.split("=", 1)
        check_name(name, line)
        if ":" in bits:
            hi, lo = (num(b, line) for b in bits.split(":", 1))
        else:
            hi = lo = num(bits, line)
        if not (0 <= lo <= hi <= 31):
            raise DefError(f"line {line}: field {name} bits {bits} must be within 31..0, high first")
        fields.append(Field(name, hi, lo))
    return fields, copy_from


def parse_reg(tok, line):
    if len(tok) < 5:
        raise DefError(f"line {line}: reg needs OFFSET NAME ACCESS SPEC")
    offset = num(tok[1], line)
    name = tok[2]
    check_name(name, line)
    access = tok[3]
    if access not in ACCESS:
        raise DefError(f"line {line}: unknown access '{access}'")
    fields, copy_from = parse_fields(tok[5:], line)
    return Reg(offset, name, access, tok[4], fields, copy_from, line)


def parse(text):
    rm = RegMap()
    block = None
    group = None
    for line_no, raw in enumerate(text.splitlines(), 1):
        try:
            tok = shlex.split(raw, comments=True)
        except ValueError as e:
            raise DefError(f"line {line_no}: {e}")
        if not tok:
            continue
        kw = tok[0]
        if group is not None and kw not in ("reg", "end"):
            raise DefError(f"line {line_no}: only 'reg' and 'end' are allowed inside {group.kind} {group.name}")
        if kw == "block":
            if len(tok) < 4:
                raise DefError(f"line {line_no}: block needs NAME BASE SIZE")
            check_name(tok[1], line_no)
            block = Block(tok[1], num(tok[2], line_no), num(tok[3], line_no), tok[4] if len(tok) > 4 else "")
            rm.blocks.append(block)
        elif kw == "reg":
            r = parse_reg(tok, line_no)
            if group is not None:
                group.regs.append(r)
            elif block is None:
                raise DefError(f"line {line_no}: reg outside a block")
            else:
                block.regs.append(r)
        elif kw == "regs":
            if block is None or len(tok) < 6:
                raise DefError(f"line {line_no}: regs needs NAME COUNT OFFSET ACCESS SPEC inside a block")
            check_name(tok[1], line_no)
            if tok[4] not in ACCESS:
                raise DefError(f"line {line_no}: unknown access '{tok[4]}'")
            block.reglists.append(RegList(tok[1], num(tok[2], line_no), num(tok[3], line_no), tok[4], tok[5], line_no))
        elif kw == "array":
            if block is None or len(tok) < 6:
                raise DefError(f"line {line_no}: array needs NAME COUNT OFFSET STRIDE SPEC inside a block")
            check_name(tok[1], line_no)
            group = Group("array", tok[1], num(tok[2], line_no), num(tok[3], line_no), num(tok[4], line_no), tok[5], line=line_no)
            block.groups.append(group)
        elif kw == "struct":
            if len(tok) < 4:
                raise DefError(f"line {line_no}: struct needs NAME SIZE SPEC")
            check_name(tok[1], line_no)
            group = Group("struct", tok[1], 1, 0, num(tok[2], line_no), tok[3], line=line_no)
            rm.structs.append(group)
        elif kw == "end":
            if group is None:
                raise DefError(f"line {line_no}: 'end' without array or struct")
            group = None
        elif kw == "area":
            if block is None or len(tok) < 6:
                raise DefError(f"line {line_no}: area needs NAME OFFSET SIZE ACCESS SPEC inside a block")
            check_name(tok[1], line_no)
            block.areas.append(Area(tok[1], num(tok[2], line_no), num(tok[3], line_no), tok[4], tok[5], line_no))
        elif kw == "const":
            if len(tok) < 3:
                raise DefError(f"line {line_no}: const needs NAME VALUE")
            check_name(tok[1], line_no)
            rm.consts.append(Const(tok[1], num(tok[2], line_no), tok[3] if len(tok) > 3 else ""))
        else:
            raise DefError(f"line {line_no}: unknown keyword '{kw}'")
    if group is not None:
        raise DefError(f"{group.kind} {group.name} (line {group.line}) has no 'end'")
    resolve_copies(rm)
    return rm


def resolve_copies(rm):
    for block in rm.blocks:
        by_name = {r.name: r for r in block.regs}
        for r in block.regs:
            if r.copy_from:
                src = by_name.get(r.copy_from)
                if src is None:
                    raise DefError(f"line {r.line}: fields={r.copy_from}: no such register in block {block.name}")
                r.fields = list(src.fields) + r.fields


# ---------------------------------------------------------------- checks

def check(rm):
    errors = []
    symbols = {}

    def symbol(name, where):
        if name in symbols:
            errors.append(f"name {name} used twice ({symbols[name]} and {where})")
        symbols[name] = where

    def check_fields(r, where):
        used = 0
        for f in r.fields:
            if used & f.mask:
                errors.append(f"{where}: field {f.name} overlaps another field")
            used |= f.mask
        names = [f.name for f in r.fields]
        if len(names) != len(set(names)):
            errors.append(f"{where}: duplicate field names")

    def check_group_regs(g, where_prefix):
        size = g.stride
        for r in g.regs:
            where = f"{where_prefix} {g.name}.{r.name} (line {r.line})"
            if r.offset % 4:
                errors.append(f"{where}: offset 0x{r.offset:X} is not a multiple of 4")
            if r.offset + 4 > size:
                errors.append(f"{where}: offset 0x{r.offset:X} is outside the {size}-byte {g.kind}")
            if r.copy_from:
                errors.append(f"{where}: fields= is only supported in blocks")
            check_fields(r, where)
        offs = [r.offset for r in g.regs]
        if len(offs) != len(set(offs)):
            errors.append(f"{where_prefix} {g.name}: two registers share an offset")

    for b in rm.blocks:
        symbol(b.name, f"block {b.name}")
        words = {}

        def claim(off, size, what):
            if off % 4 or size % 4:
                errors.append(f"block {b.name}: {what} at 0x{off:X} is not 4-byte aligned")
            if off < 0 or off + size > b.size:
                errors.append(f"block {b.name}: {what} at 0x{off:X} is outside the block")
            for w in range(off, off + size, 4):
                if w in words:
                    errors.append(f"block {b.name}: {what} at 0x{w:X} overlaps {words[w]}")
                    return
                words[w] = what

        for r in b.regs:
            claim(r.offset, 4, r.name)
            symbol(r.name, f"register in {b.name}")
            check_fields(r, f"{b.name}.{r.name} (line {r.line})")
        for rl in b.reglists:
            for i in range(rl.count):
                claim(rl.offset + 4 * i, 4, f"{rl.name}{i}")
                symbol(f"{rl.name}{i}", f"register in {b.name}")
        for g in b.groups:
            symbol(g.name, f"array in {b.name}")
            check_group_regs(g, f"array")
            for n in range(g.count):
                for r in g.regs:
                    claim(g.base + n * g.stride + r.offset, 4, f"{g.name}{n}.{r.name}")
        for a in b.areas:
            claim(a.offset, a.size, a.name)
            symbol(a.name, f"area in {b.name}")
    for s in rm.structs:
        symbol(s.name, "struct")
        check_group_regs(s, "struct")
    for c in rm.consts:
        symbol(c.name, "const")
    return errors


def spec_registers(md_text):
    """Collect (block, offset, name) for every register row in docs/spec/registers.md."""
    found = set()
    block = None
    array = None
    row = re.compile(r"^\| `(\+?)0x([0-9A-Fa-f]+)`(?:–`0x([0-9A-Fa-f]+)`)? \| ([A-Z][A-Z0-9_]*)(?:–(\d+))? \|")
    arr = re.compile(r"at `0x([0-9A-Fa-f]+) \+ n × 0x([0-9A-Fa-f]+)`")
    for line in md_text.splitlines():
        if line.startswith("## "):
            block = "CUSTOM" if "Custom block" in line else "SYSTEM" if "System block" in line else None
            array = None
            continue
        if line.startswith("### "):
            array = None
            continue
        m = arr.search(line)
        if m and not line.startswith("|"):
            array = (int(m.group(1), 16), int(m.group(2), 16))
            continue
        if not line.startswith("|"):
            continue
        m = row.match(line)
        if not m or block is None:
            continue
        rel, start, end, name, last = m.group(1), int(m.group(2), 16), m.group(3), m.group(4), m.group(5)
        if rel:
            if array is None:
                continue
            found.add((block, array[0] + start, name))
        elif end and last is not None:
            base = re.sub(r"\d+$", "", name)
            first = int(re.search(r"(\d+)$", name).group(1))
            for i, off in enumerate(range(start, int(end, 16) + 1, 4)):
                found.add((block, off, f"{base}{first + i}"))
        elif end:
            continue  # an area, e.g. palette
        else:
            found.add((block, start, name))
    return found


def def_registers(rm):
    found = set()
    for b in rm.blocks:
        if b.name not in ("CUSTOM", "SYSTEM"):
            continue
        for r in b.regs:
            found.add((b.name, r.offset, r.name))
        for rl in b.reglists:
            for i in range(rl.count):
                found.add((b.name, rl.offset + 4 * i, f"{rl.name}{i}"))
        for g in b.groups:
            for r in g.regs:
                found.add((b.name, g.base + r.offset, r.name))
    return found


def check_spec(rm, md_text):
    spec = spec_registers(md_text)
    ours = def_registers(rm)
    errors = []
    for blk, off, name in sorted(spec - ours):
        errors.append(f"registers.md lists {name} at {blk}+0x{off:X}, but regmap.def does not")
    for blk, off, name in sorted(ours - spec):
        errors.append(f"regmap.def has {name} at {blk}+0x{off:X}, but registers.md does not list it")
    return errors


# ---------------------------------------------------------------- output helpers

HEADER = "Generated by tools/regmap.py from fpga/regmap.def. Do not edit; edit regmap.def and rerun."


# ---------------------------------------------------------------- assembler

def gen_asm(rm):
    out = [f"; {HEADER}", "; 68000 assembler (vasm, Motorola syntax) equates for retro68k.", ";",
           "; Registers are offsets from their block (CUSTOM or SYSTEM), e.g.", ";   lea CUSTOM,a6",
           ";   move.l #VIDCON_EN_M,VIDCON(a6)", "; Fields: NAME_B = lowest bit, NAME_W = width, NAME_M = mask in place.",
           "; Arrays: G_NUM = how many, G_SPAN = bytes between them, Gn = where element n starts,", ";   G_REG = register offset within an element, Gn_REG = the same, ready-added.", ""]

    seen = set()

    def eq(name, value, comment=""):
        if name in seen:
            raise DefError(f"generated assembler name {name} is defined twice")
        seen.add(name)
        line = f"{name:<28} equ ${value:X}"
        if comment:
            line = f"{line:<44} ; {comment}"
        out.append(line)

    def fields(prefix, r):
        for f in r.fields:
            eq(f"{prefix}_{f.name}_B", f.lo)
            if f.width > 1:
                eq(f"{prefix}_{f.name}_W", f.width)
            eq(f"{prefix}_{f.name}_M", f.mask)

    for b in rm.blocks:
        out += ["", f"; ---- {b.name}: {b.text}"]
        eq(b.name, b.base)
        eq(f"{b.name}_SIZE", b.size)
        for r in b.regs:
            eq(r.name, r.offset, f"{r.access}, spec {r.spec}")
            fields(r.name, r)
        for rl in b.reglists:
            eq(f"{rl.name}_NUM", rl.count)
            for i in range(rl.count):
                eq(f"{rl.name}{i}", rl.offset + 4 * i, f"{rl.access}, spec {rl.spec}")
        for g in b.groups:
            out.append(f"; {g.name}0..{g.name}{g.count - 1}: {g.count} x {g.stride} bytes, spec {g.spec}")
            eq(f"{g.name}_NUM", g.count)
            eq(f"{g.name}_SPAN", g.stride)
            for n in range(g.count):
                eq(f"{g.name}{n}", g.base + n * g.stride)
            for r in g.regs:
                eq(f"{g.name}_{r.name}", r.offset, f"{r.access}, spec {r.spec} (add to {g.name}n)")
                fields(f"{g.name}_{r.name}", r)
            for n in range(g.count):
                for r in g.regs:
                    eq(f"{g.name}{n}_{r.name}", g.base + n * g.stride + r.offset)
        for a in b.areas:
            eq(a.name, a.offset, f"{a.access}, spec {a.spec}")
            eq(f"{a.name}_SIZE", a.size)
    for s in rm.structs:
        out += ["", f"; ---- {s.name}: {s.stride}-byte layout in memory, spec {s.spec}"]
        eq(f"{s.name}_SIZEOF", s.stride)
        for r in s.regs:
            eq(f"{s.name}_{r.name}", r.offset)
            fields(f"{s.name}_{r.name}", r)
    out += ["", "; ---- Named numbers"]
    for c in rm.consts:
        eq(c.name, c.value, c.text)
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- C

def gen_c(rm):
    out = [f"/* {HEADER} */", "/* C header for retro68k hardware. */", "",
           "#ifndef RETRO68K_HW_H", "#define RETRO68K_HW_H", "", "#include <stdint.h>", "",
           "/* A 32-bit hardware register. The 68000 writes 32-bit values high half first,",
           "   so a normal assignment updates the register in one go (spec 3, section 2). */",
           "#define HW_REG32(addr) (*(volatile uint32_t *)(uintptr_t)(addr))", ""]

    def u(v):
        return f"0x{v:X}u"

    seen = set()

    def d(name, value):
        key = name.split("(")[0]
        if key in seen:
            raise DefError(f"generated C name {key} is defined twice")
        seen.add(key)
        out.append(f"#define {name:<34} {value}")

    def fields(prefix, r):
        for f in r.fields:
            d(f"{prefix}_{f.name}_SHIFT", f.lo)
            d(f"{prefix}_{f.name}_MASK", u(f.mask))

    for b in rm.blocks:
        out += ["", f"/* ---- {b.name}: {b.text} */"]
        d(f"{b.name}_BASE", u(b.base))
        d(f"{b.name}_SIZE", u(b.size))
        for r in b.regs:
            out.append(f"/* {r.name}: {r.access}, spec {r.spec} */")
            d(f"{r.name}_OFS", u(r.offset))
            d(r.name, f"HW_REG32({b.name}_BASE + {r.name}_OFS)")
            fields(r.name, r)
        for rl in b.reglists:
            d(f"{rl.name}_NUM", rl.count)
            d(f"{rl.name}_OFS(n)", f"({u(rl.offset)} + 4u * (n))")
            d(f"{rl.name}(n)", f"HW_REG32({b.name}_BASE + {rl.name}_OFS(n))")
        for g in b.groups:
            out.append(f"/* {g.name}(n): {g.count} x {g.stride} bytes, spec {g.spec} */")
            d(f"{g.name}_NUM", g.count)
            d(f"{g.name}_SPAN", u(g.stride))
            d(f"{g.name}_AT(n)", f"({u(g.base)} + (n) * {g.name}_SPAN)")
            for r in g.regs:
                d(f"{g.name}_{r.name}_OFS", u(r.offset))
                d(f"{g.name}_{r.name}(n)", f"HW_REG32({b.name}_BASE + {g.name}_AT(n) + {g.name}_{r.name}_OFS)")
                fields(f"{g.name}_{r.name}", r)
        for a in b.areas:
            d(f"{a.name}_OFS", u(a.offset))
            d(f"{a.name}_SIZE", u(a.size))
            d(a.name, f"((volatile uint32_t *)(uintptr_t)({b.name}_BASE + {a.name}_OFS))")
    for s in rm.structs:
        out += ["", f"/* ---- {s.name}: {s.stride}-byte layout in memory, spec {s.spec} */"]
        members, pos, pad = [], 0, 0
        for r in sorted(s.regs, key=lambda r: r.offset):
            while pos < r.offset:
                members.append(f"    uint32_t reserved{pad};")
                pad += 1
                pos += 4
            members.append(f"    uint32_t {r.name.lower()};")
            pos += 4
        while pos < s.stride:
            members.append(f"    uint32_t reserved{pad};")
            pad += 1
            pos += 4
        out.append(f"typedef struct {{\n" + "\n".join(members) + f"\n}} {s.name.lower()}_t;")
        out.append(f"_Static_assert(sizeof({s.name.lower()}_t) == {s.stride}, \"{s.name} layout\");")
        d(f"{s.name}_SIZEOF", s.stride)
        for r in s.regs:
            d(f"{s.name}_{r.name}_OFS", u(r.offset))
            fields(f"{s.name}_{r.name}", r)
    out += ["", "/* ---- Named numbers */"]
    for c in rm.consts:
        d(c.name, u(c.value) + (f"  /* {c.text} */" if c.text else ""))
    out += ["", "#endif /* RETRO68K_HW_H */"]
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- Verilog

def gen_verilog(rm):
    out = [f"// {HEADER}", "// Verilog defines for retro68k register offsets and fields.",
           "// Offsets are byte offsets within their block; fields are bit ranges, e.g. data[`RM_L_CTRL_BPP].", "",
           "`ifndef RETRO68K_REGMAP_VH", "`define RETRO68K_REGMAP_VH", ""]

    seen = set()

    def d(name, value):
        if name in seen:
            raise DefError(f"generated Verilog name RM_{name} is defined twice")
        seen.add(name)
        out.append(f"`define RM_{name:<32} {value}")

    def fields(prefix, r):
        for f in r.fields:
            d(f"{prefix}_{f.name}", f"{f.hi}:{f.lo}" if f.width > 1 else f"{f.lo}")

    for b in rm.blocks:
        out += ["", f"// ---- {b.name}: {b.text}"]
        d(f"{b.name}_BASE", f"24'h{b.base:06X}")
        d(f"{b.name}_SIZE", f"25'h{b.size:06X}")
        for r in b.regs:
            d(r.name, f"16'h{r.offset:04X}")
            fields(r.name, r)
        for rl in b.reglists:
            d(f"{rl.name}_BASE", f"16'h{rl.offset:04X}")
            d(f"{rl.name}_NUM", rl.count)
        for g in b.groups:
            d(f"{g.name}_BASE", f"16'h{g.base:04X}")
            d(f"{g.name}_SPAN", f"16'h{g.stride:04X}")
            d(f"{g.name}_NUM", g.count)
            for r in g.regs:
                d(f"{g.name}_{r.name}", f"16'h{r.offset:04X}")
                fields(f"{g.name}_{r.name}", r)
        for a in b.areas:
            d(f"{a.name}_BASE", f"16'h{a.offset:04X}")
            d(f"{a.name}_SIZE", f"17'h{a.size:05X}")
    for s in rm.structs:
        out += ["", f"// ---- {s.name}: {s.stride}-byte layout in memory"]
        d(f"{s.name}_SIZEOF", s.stride)
        for r in s.regs:
            d(f"{s.name}_{r.name}", f"8'h{r.offset:02X}")
            fields(f"{s.name}_{r.name}", r)
    out += ["", "// ---- Named numbers"]
    for c in rm.consts:
        d(c.name, f"32'h{c.value:08X}")
    out += ["", "`endif"]
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--verify", action="store_true", help="fail if generated files are out of date (do not write)")
    args = ap.parse_args()

    try:
        rm = parse(DEF_FILE.read_text())
    except DefError as e:
        print(f"regmap.def: {e}", file=sys.stderr)
        return 1
    errors = check(rm)
    errors += check_spec(rm, SPEC_FILE.read_text())
    if errors:
        for e in errors:
            print(f"error: {e}", file=sys.stderr)
        return 1

    try:
        outputs = {OUT_ASM: gen_asm(rm), OUT_C: gen_c(rm), OUT_V: gen_verilog(rm)}
    except DefError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    stale = []
    for path, text in outputs.items():
        current = path.read_text() if path.exists() else None
        if current == text:
            continue
        if args.verify:
            stale.append(path)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            print(f"wrote {path.relative_to(ROOT)}")
    if stale:
        for p in stale:
            print(f"out of date: {p.relative_to(ROOT)} (run python3 tools/regmap.py)", file=sys.stderr)
        return 1
    n = len(def_registers(rm))
    print(f"regmap OK: {n} registers checked against docs/spec/registers.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
