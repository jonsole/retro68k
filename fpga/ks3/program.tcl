# Load retro68k_ks3.bit straight into the FPGA over JTAG (the flash is not touched).
#   vivado -mode batch -source program.tcl -tclargs <bitfile>
set bit [lindex $argv 0]
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a35t*] 0]
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "retro68k: FPGA loaded"
close_hw_manager
