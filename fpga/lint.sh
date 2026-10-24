#!/bin/sh
# Lint the RTL with Verilator. A value cut short to fit where it goes
# (WIDTHTRUNC) is an error: it is how a register rebuilt from the wrong
# number of bits slips past Icarus and Yosys. Widening (WIDTHEXPAND) is
# allowed. Where cutting is meant, slice it or waive that line with
#   /* verilator lint_off WIDTHTRUNC */ ... /* verilator lint_on WIDTHTRUNC */
# The third-party CPU core is replaced by a stub with its ports
# (fpga/lint_fx68k_stub.v).
set -e
cd "$(dirname "$0")/.."
verilator --lint-only --default-language 1364-2005 -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wwarn-WIDTHTRUNC \
    -Ifpga/rtl --top-module retro68k fpga/rtl/*.v fpga/rtl/platform/sim/oddr.v fpga/lint_fx68k_stub.v
# The board's HDMI encoder sits outside retro68k's hierarchy: lint it on its own
verilator --lint-only --default-language 1364-2005 -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wwarn-WIDTHTRUNC \
    --top-module tmds_encoder fpga/rtl/tmds_encoder.v
echo "lint: no widths cut short"