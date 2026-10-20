# Tools

| Tool | What it does |
|------|--------------|
| `regmap.py` | Reads `fpga/regmap.def` (every hardware register and field), checks it, checks it against `docs/spec/registers.md`, and writes `firmware/include/hw.inc` (vasm), `firmware/include/hw.h` (C) and `fpga/rtl/regmap.vh` (Verilog) |

## Register map

To add or change a register:

1. Edit `fpga/regmap.def`.
2. Update the register's table in `docs/spec/registers.md` (and its own spec).
3. Run `python3 tools/regmap.py`. It stops with a message if the two disagree, if anything overlaps or is misaligned, or if a generated name would be defined twice.
4. Commit the `.def`, the spec and the generated files together.

`python3 tools/regmap.py --verify` only checks, and fails if the generated files are out of date. GitHub runs it on every push.

Only the Python standard library is needed (Python 3.8 or newer).

### Generated names

| In `regmap.def` | Assembler (`hw.inc`) | C (`hw.h`) | Verilog (`regmap.vh`) |
|-----------------|----------------------|------------|-----------------------|
| block `CUSTOM` | `CUSTOM` (base), `CUSTOM_SIZE` | `CUSTOM_BASE`, `CUSTOM_SIZE` | `` `RM_CUSTOM_BASE `` |
| reg `VIDCON` | `VIDCON` (offset in block) | `VIDCON` (the register), `VIDCON_OFS` | `` `RM_VIDCON `` (offset) |
| field `VIDCON.EN` | `VIDCON_EN_B` (bit), `VIDCON_EN_M` (mask); multi-bit fields add `_W` (width) | `VIDCON_EN_SHIFT`, `VIDCON_EN_MASK` | `` `RM_VIDCON_EN `` (bit or `hi:lo`) |
| array `L` of 4 | `L_NUM`, `L_SPAN`, `L0`…`L3`, `L_CTRL` (offset in an element), `L2_CTRL` | `L_NUM`, `L_SPAN`, `L_AT(n)`, `L_CTRL(n)` | `` `RM_L_BASE ``, `` `RM_L_SPAN ``, `` `RM_L_CTRL `` |
| struct `SPR` | `SPR_SIZEOF`, `SPR_POS` … | `spr_t`, `SPR_POS_OFS` … | `` `RM_SPR_POS `` … |
| const `INT_VBLANK` | `INT_VBLANK` | `INT_VBLANK` | `` `RM_INT_VBLANK `` |

Example (assembler):

```
        include "hw.inc"
        lea     CUSTOM,a6
        move.l  #VIDCON_EN_M,VIDCON(a6)        ; video on
        move.l  #picture,L0_PTR(a6)            ; layer 0 source
```

Example (C):

```c
#include "hw.h"
VIDCON = VIDCON_EN_MASK;
L_PTR(0) = (uint32_t)picture;
```
