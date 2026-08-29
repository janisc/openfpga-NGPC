project_open ngpc_pocket
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 2000 -less_than_slack 0 -file worst2.rpt
project_close
