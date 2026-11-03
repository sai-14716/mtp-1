# Program the first xc7a100t on the JTAG chain:  vivado -mode batch -source program_board.tcl -tclargs <file.bit>
set bit [file normalize [lindex $argv 0]]
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "PROGRAMMED $bit"
close_hw_manager
