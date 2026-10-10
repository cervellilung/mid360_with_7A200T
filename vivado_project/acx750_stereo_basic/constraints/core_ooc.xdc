# Processing-core clock only; this is not an ACX750 board pin constraint set.
create_clock -name core_clk -period 10.000 [get_ports clk]
