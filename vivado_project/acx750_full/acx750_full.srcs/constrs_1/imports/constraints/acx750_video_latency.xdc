# Straight-line XDC; strict 48-bit endpoint checks live in the audit Tcl.
set lat_src [get_cells -hier -filter {NAME =~ *u_video_latency/gray_time_reg* && IS_SEQUENTIAL}]
set lat_cam [get_cells -hier -regexp {.*u_video_latency/u_cam_time/syncstages_ff_reg\[0\].*}]
set lat_pix [get_cells -hier -regexp {.*u_video_latency/u_pix_time/syncstages_ff_reg\[0\].*}]
set_bus_skew 10.000 -from $lat_src -to $lat_cam
set_bus_skew 10.000 -from $lat_src -to $lat_pix
