// Adapter only: factory ch52 transmitter, preserved application ports.
module eth_udp_tx_gmii(input clk125M,reset_n,tx_en_pulse, output tx_done,
 input [47:0] dst_mac,src_mac,input [31:0] dst_ip,src_ip,
 input [15:0] dst_port,src_port,data_length,output payload_req_o,input [7:0] payload_dat_i,
 output gmii_tx_clk,gmii_txen,output [7:0] gmii_txd);
 ch52_eth_udp_tx_gmii u_factory(.clk125m(clk125M),.reset_p(~reset_n),.tx_en_pulse(tx_en_pulse),
 .tx_done(tx_done),.dst_mac(dst_mac),.src_mac(src_mac),.dst_ip(dst_ip),.src_ip(src_ip),
 .dst_port(dst_port),.src_port(src_port),.data_length(data_length),.payload_req_o(payload_req_o),
 .payload_dat_i(payload_dat_i),.gmii_tx_clk(gmii_tx_clk),.gmii_txen(gmii_txen),.gmii_txd(gmii_txd));
endmodule
