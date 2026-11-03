open_project tinygpu_simulation.xpr
set_property "xsim.simulate.runtime" "all" [current_fileset -simset]
launch_simulation -simset sim_1
run -all
close_project
