#!/usr/bin/env bash
# retro68k: build the FPGA for the ZX Spectrum Next KS3, in one go.
#
#   fpga/ks3/build.sh                 build fpga/ks3/build/retro68k_ks3.bit
#   fpga/ks3/build.sh --program       build, then load it over JTAG with Vivado
#   fpga/ks3/build.sh --program-only  just load the last build
#   fpga/ks3/build.sh --ofl CABLE     load with openFPGALoader instead (e.g. --ofl digilent_hs2)
#   fpga/ks3/build.sh --pix-n N       pixel clock 200/N MHz (default 8: 640x480)
#
# Needs Vivado (the free edition covers the XC7A35T) on the PATH or in $VIVADO,
# python3, and git. The 68000 assembler (vasm) is used from the PATH or $VASM;
# if neither has it, it is downloaded and built into fpga/ks3/tools/ (needs
# curl, make and a C compiler).
#
# Loading over JTAG changes nothing in the board's flash: power-cycle the KS3
# and it starts the Next as usual.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="$here/build"
pix_n=8
do_build=1
do_program=0
ofl_cable=""

while [ $# -gt 0 ]; do
    case "$1" in
        --program)      do_program=1 ;;
        --program-only) do_program=1; do_build=0 ;;
        --ofl)          do_program=1; ofl_cable="${2:?--ofl needs a cable name}"; shift ;;
        --pix-n)        pix_n="${2:?--pix-n needs a number}"; shift ;;
        -h|--help)      sed -n '2,18p' "$0"; exit 0 ;;
        *)              echo "build.sh: unknown option $1 (try --help)" >&2; exit 1 ;;
    esac
    shift
done

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

case "$pix_n" in 3|4|5|6|7|8) ;; *) die "--pix-n must be 3 to 8" ;; esac

vivado="${VIVADO:-$(command -v vivado || true)}"

if [ "$do_build" = 1 ]; then
    [ -n "$vivado" ] || die "Vivado not found: put it on the PATH (source <Vivado>/settings64.sh) or set VIVADO"
    command -v python3 >/dev/null || die "python3 not found"

    # ---- fx68k
    if [ ! -f "$root/fpga/third_party/fx68k/fx68k.sv" ]; then
        say "Fetching the fx68k submodule"
        git -C "$root" submodule update --init fpga/third_party/fx68k
    fi

    # ---- vasm
    vasm="${VASM:-$(command -v vasmm68k_mot || true)}"
    if [ -z "$vasm" ]; then
        vasm="$here/tools/vasm/vasmm68k_mot"
        if [ ! -x "$vasm" ]; then
            say "Building vasm (68000 assembler) into fpga/ks3/tools"
            mkdir -p "$here/tools"
            curl -sSL -o "$here/tools/vasm.tar.gz" http://sun.hasenbraten.de/vasm/release/vasm.tar.gz
            tar -xzf "$here/tools/vasm.tar.gz" -C "$here/tools"
            make -C "$here/tools/vasm" CPU=m68k SYNTAX=mot >/dev/null
        fi
    fi

    # ---- boot ROM and memory files
    say "Assembling the boot ROM"
    mkdir -p "$out"
    "$vasm" -quiet -Fbin -I "$root/firmware/include" -o "$out/boot.bin" "$root/firmware/boot/boot.s"
    python3 "$root/tools/bin2hex.py" "$out/boot.bin" "$out/boot.hex"
    cp "$root/fpga/rtl/font8x16.hex" "$out/"
    cp "$root/fpga/third_party/fx68k/microrom.mem" "$root/fpga/third_party/fx68k/nanorom.mem" "$out/"

    # ---- Vivado
    say "Running Vivado (synthesis, place and route, bitstream): about 10-20 minutes"
    set +e
    (cd "$out" && "$vivado" -mode batch -nojournal -log vivado.log \
        -source "$here/build.tcl" -tclargs "$root" "$out" "$pix_n")
    status=$?
    set -e
    grep -h "^retro68k:" "$out/vivado.log" || true
    case $status in
        0) ;;
        2) die "timing not met: see $out/timing.txt (the bitstream was written anyway)" ;;
        *) die "Vivado failed: see $out/vivado.log" ;;
    esac
    say "Done: $out/retro68k_ks3.bit"
    echo "    reports: utilization.txt, timing.txt, clocks.txt, drc.txt, io.txt"
fi

if [ "$do_program" = 1 ]; then
    bit="$out/retro68k_ks3.bit"
    [ -f "$bit" ] || die "no bitstream yet: run build.sh first"
    if [ -n "$ofl_cable" ]; then
        command -v openFPGALoader >/dev/null || die "openFPGALoader not found"
        say "Loading over JTAG with openFPGALoader ($ofl_cable)"
        openFPGALoader -c "$ofl_cable" "$bit"
    else
        [ -n "$vivado" ] || die "Vivado not found (or use --ofl CABLE)"
        say "Loading over JTAG with Vivado"
        (cd "$out" && "$vivado" -mode batch -nojournal -log program.log \
            -source "$here/program.tcl" -tclargs "$bit")
    fi
fi
