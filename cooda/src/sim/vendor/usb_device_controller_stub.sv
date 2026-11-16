// Elaboration-only model. Gowin's generated USB core is protected and is
// used by the hardware project; this stub does not model USB transfers.
module USB_Device_Controller_Top (
    input wire clk_i,
    input wire reset_i,
    output wire usbrst_o,
    output wire highspeed_o,
    output wire suspend_o,
    output wire online_o,
    input wire [7:0] txdat_i,
    input wire txval_i,
    input wire [11:0] txdat_len_i,
    input wire [3:0] txiso_pid_i,
    input wire txcork_i,
    output wire txpop_o,
    output wire txact_o,
    output wire txpktfin_o,
    output wire [7:0] rxdat_o,
    output wire rxval_o,
    input wire rxrdy_i,
    output wire rxact_o,
    output wire rxpktval_o,
    output wire setup_o,
    output wire [3:0] endpt_o,
    output wire sof_o,
    input wire [7:0] inf_alter_i,
    output wire [7:0] inf_alter_o,
    output wire [7:0] inf_sel_o,
    output wire inf_set_o,
    output wire [15:0] descrom_raddr_o,
    output wire [7:0] desc_index_o,
    output wire [7:0] desc_type_o,
    input wire [7:0] descrom_rdata_i,
    input wire [15:0] desc_dev_addr_i,
    input wire [15:0] desc_dev_len_i,
    input wire [15:0] desc_qual_addr_i,
    input wire [15:0] desc_qual_len_i,
    input wire [15:0] desc_fscfg_addr_i,
    input wire [15:0] desc_fscfg_len_i,
    input wire [15:0] desc_hscfg_addr_i,
    input wire [15:0] desc_hscfg_len_i,
    input wire [15:0] desc_oscfg_addr_i,
    input wire [15:0] desc_hidrpt_addr_i,
    input wire [15:0] desc_hidrpt_len_i,
    input wire [15:0] desc_bos_addr_i,
    input wire [15:0] desc_bos_len_i,
    input wire [15:0] desc_strlang_addr_i,
    input wire [15:0] desc_strvendor_addr_i,
    input wire [15:0] desc_strvendor_len_i,
    input wire [15:0] desc_strproduct_addr_i,
    input wire [15:0] desc_strproduct_len_i,
    input wire [15:0] desc_strserial_addr_i,
    input wire [15:0] desc_strserial_len_i,
    input wire desc_have_strings_i,
    input wire ulpi_nxt_i,
    input wire ulpi_dir_i,
    input wire [7:0] ulpi_rxdata_i,
    output wire [7:0] ulpi_txdata_o,
    output wire ulpi_stp_o
);
    assign usbrst_o = 1'b0;
    assign highspeed_o = 1'b0;
    assign suspend_o = 1'b0;
    assign online_o = 1'b0;
    assign txpop_o = 1'b0;
    assign txact_o = 1'b0;
    assign txpktfin_o = 1'b0;
    assign rxdat_o = 8'd0;
    assign rxval_o = 1'b0;
    assign rxact_o = 1'b0;
    assign rxpktval_o = 1'b0;
    assign setup_o = 1'b0;
    assign endpt_o = 4'd0;
    assign sof_o = 1'b0;
    assign inf_alter_o = 8'd0;
    assign inf_sel_o = 8'd0;
    assign inf_set_o = 1'b0;
    assign descrom_raddr_o = 16'd0;
    assign desc_index_o = 8'd0;
    assign desc_type_o = 8'd0;
    assign ulpi_txdata_o = 8'd0;
    assign ulpi_stp_o = 1'b0;
endmodule
