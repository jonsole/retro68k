#!/bin/sh
# Lint the RTL with Verilator. A value cut short to fit where it goes
# (WIDTHTRUNC) is an error: it is how a register rebuilt from the wrong
# number of bits slips past Icarus and Yosys. Widening (WIDTHEXPAND) is
# allowed. Where cutting is meant, slice it or waive that line with
#   /* verilator lint_off WIDTHTRUNC */ ... /* verilator lint_on WIDTHTRUNC */
# The third-party CPU core is not checked (fpga/lint.vlt).
set -e
cd "$(dirname "$0")/.."
t=$(mktemp -d)
sv2v fpga/third_party/fx68k/fx68k.sv fpga/third_party/fx68k/fx68kAlu.sv fpga/third_party/fx68k/uaddrPla.sv > "$t/fx68k.v"
verilator --lint-only --default-language 1364-2005 -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wwarn-WIDTHTRUNC \
    -Ifpga/rtl --top-module retro68k fpga/lint.vlt fpga/rtl/*.v fpga/rtl/platform/sim/oddr.v "$t/fx68k.v"
rm -rf "$t"
echo "lint: no widths cut short"