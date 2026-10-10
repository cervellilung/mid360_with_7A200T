// Adapter only: factory ch52 decoder, no protocol logic changes.
module eth_udp_rx_gmii(
 input reset, input [47:0] local_mac, input [31:0] local_ip, input [15:0] local_port,
 output clk125m_o, output [47:0] exter_mac, output [31:0] exter_ip,
 output [15:0] exter_port,rx_data_length, input data_overflow_i,
 output payload_valid_o, output [7:0] payload_dat_o, output one_pkt_done,pkt_error,
 output [31:0] debug_crc_check, input gmii_rx_clk,input [7:0] gmii_rxd,input gmii_rxdv);
 ch52_eth_udp_rx_gmii u_factory(.reset_p(reset),.local_mac(local_mac),.local_ip(local_ip),
 .local_port(local_port),.clk125m_o(clk125m_o),.exter_mac(exter_mac),.exter_ip(exter_ip),
 .exter_port(exter_port),.rx_data_length(rx_data_length),.data_overflow_i(data_overflow_i),
 .payload_valid_o(payload_valid_o),.payload_dat_o(payload_dat_o),.one_pkt_done(one_pkt_done),
 .pkt_error(pkt_error),.debug_crc_check(debug_crc_check),.gmii_rx_clk(gmii_rx_clk),
 .gmii_rxd(gmii_rxd),.gmii_rxdv(gmii_rxdv));
endmodule
