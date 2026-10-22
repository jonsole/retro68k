# retro68k: Vivado build for the ZX Spectrum Next KS3 (non-project batch mode).
# Run through build.sh, which prepares the boot ROM and the build folder:
#   vivado -mode batch -source build.tcl -tclargs <repo root> <build dir>

set root   [file normalize [lindex $argv 0]]
set out    [file normalize [lindex $argv 1]]
set part   xc7a35tcsg324-2
set rtl    $root/fpga/rtl

cd $out
set_part $part

# fx68k (SystemVerilog, read as such), then the design
read_verilog -sv [list \
    $root/fpga/third_party/fx68k/fx68k.sv \
    $root/fpga/third_party/fx68k/fx68kAlu.sv \
    $root/fpga/third_party/fx68k/uaddrPla.sv ]
read_verilog [list \
    $rtl/timebase.v $rtl/cpu_fx68k.v $rtl/sram_ctl.v $rtl/bus_if.v $rtl/bootrom.v \
    $rtl/fifo8.v $rtl/sysregs.v $rtl/serial.v $rtl/intc.v $rtl/timers.v \
    $rtl/layer_pix.v $rtl/bpldma.v $rtl/video.v $rtl/retro68k.v \
    $rtl/por_align.v $rtl/tmds_encoder.v $rtl/top_ks3.v \
    $rtl/platform/artix7/ks3_clocks.v $rtl/platform/artix7/oddr.v \
    $rtl/platform/artix7/hdmi_out.v $rtl/platform/artix7/vga_out.v ]
read_xdc $root/fpga/ks3/ks3.xdc

# boot.hex, microrom.mem and nanorom.mem are in this folder
synth_design -top top_ks3 -include_dirs $rtl
write_checkpoint -force post_synth.dcp
report_utilization -file utilization_synth.txt

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force post_route.dcp

report_utilization     -file utilization.txt
report_timing_summary  -file timing.txt -max_paths 20
report_clock_interaction -file clocks.txt
report_drc             -file drc.txt
report_io              -file io.txt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "retro68k: worst setup slack $wns ns, worst hold slack $whs ns"

write_bitstream -force retro68k_ks3.bit
# A raw image for writing to the configuration flash (as a Next core, later)
write_cfgmem -force -format bin -interface SPIx1 -size 16 \
    -loadbit "up 0x0 retro68k_ks3.bit" -file retro68k_ks3.bin

if {$wns < 0 || $whs < 0} {
    puts "retro68k: TIMING NOT MET (see timing.txt)"
    exit 2
}
puts "retro68k: build done, timing met"
