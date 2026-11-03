# Non-project build of gpu_soc_top for the Nexys 4 DDR (XC7A100T-1CSG324).
#   vivado -mode batch -source scripts/build_gpu.tcl -tclargs <NUM_CORES> <PROG_CH> <DATA_CH> [THREADS_PER_BLOCK] [stock|rr] [CORE_MHZ]
#   rr = dispatch_rr.sv (one block assignment / retirement per cycle) instead of the stock dispatcher
set root [file normalize [file join [file dirname [info script]] ..]]
lassign $argv N P M T V F
if {$T eq ""} { set T 4 }
if {$V eq ""} { set V stock }
set tag  N${N}_P${P}_M${M}_T${T}
set disp dispatch
if {$V eq "rr"} { append tag _rr; set disp dispatch_rr }
if {$F eq ""} { set F 50 }
if {$F != 50} { append tag _f$F }
set out  [file join $root build $tag]
file mkdir $out

set rtl [list alu controller core dcr decoder $disp fetcher lsu pc registers scheduler gpu]
foreach f $rtl { read_verilog -sv $root/rtl/$f.sv }
read_verilog -sv $root/soc/gpu_soc_top.sv
read_xdc $root/soc/nexys4ddr.xdc

synth_design -top gpu_soc_top -part xc7a100tcsg324-1 \
    -generic NUM_CORES=$N -generic PROG_CH=$P -generic DATA_CH=$M -generic THREADS_PER_BLOCK=$T -generic CORE_MHZ=$F
report_utilization -file $out/util_synth.rpt
opt_design
place_design
phys_opt_design
route_design
report_utilization                -file $out/util.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $out/util_hier.rpt
report_timing_summary -max_paths 10 -file $out/timing.rpt
report_timing -max_paths 1 -nworst 1 -file $out/critical_path.rpt
report_power                      -file $out/power.rpt
write_bitstream -force $out/gpu_soc.bit
puts "BUILD_DONE $tag"
