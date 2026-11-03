# Non-project Vivado build of cnn_top for the Nexys 4 DDR (XC7A100T-1CSG324).
#   vivado -mode batch -source scripts/build_cnn.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set out  [file join $root build]
file mkdir $out

read_verilog [list $root/cnn_core.v $root/cnn_top.v]
read_xdc $root/cnn_nexys4ddr.xdc
synth_design -top cnn_top -part xc7a100tcsg324-1
report_utilization -file $out/util_synth.rpt
opt_design
place_design
phys_opt_design
route_design
report_utilization              -file $out/util.rpt
report_utilization -hierarchical -file $out/util_hier.rpt
report_timing_summary -max_paths 10 -file $out/timing.rpt
report_power                    -file $out/power.rpt
write_bitstream -force $out/cnn_top.bit
