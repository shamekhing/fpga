// ============================================================
// fpga_top  Tang Primer 20K board wrapper: pins to the viewer SoC
// ============================================================
// Everything else - DDR3 clocks, the USB/microSD loader, the CPU, the
// HDMI display path and the LED meanings - lives in mnist_view_top.
// The two rate buttons sit on header pins (T12, T11): short them to
// ground for a press.
// ============================================================
module fpga_top #(
    parameter bit SD_ENABLE = 1'b0,
    parameter bit USB_ENABLE = !SD_ENABLE,
    parameter logic [15:0] USB_VID = 16'hCAFE,
    parameter logic [15:0] USB_PID = 16'h4001,
    parameter bit USB_READ_ACTIVE_LEVEL = 1'b1
) (
    input  logic clk27,
    input  logic btn_n0,
    input  logic btn_n1,
    input  logic btn_n2,
    input  logic btn_n3,
    inout  wire [15:0] DDR3_DQ,
    inout  wire [1:0]  DDR3_DQS,
    output wire [12:0] DDR3_A,
    output wire [2:0]  DDR3_BA,
    output wire        DDR3_nRAS,
    output wire        DDR3_nCAS,
    output wire        DDR3_nWE,
    output wire        DDR3_CK,
    output wire        DDR3_CKE,
    output wire        DDR3_nRESET,
    output wire [1:0]  DDR3_DM,
    output wire        DDR3_ODT,
    output wire        sd_cs_n,
    output wire        sd_sck,
    output wire        sd_mosi,
    input  wire        sd_miso,
    input  wire        sw2,
    input  wire        ulpi_clk,
    inout  wire [7:0]  ulpi_data,
    input  wire        ulpi_dir,
    input  wire        ulpi_nxt,
    output wire        ulpi_stp,
    output wire        ulpi_rst,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_data_p,
    output wire [2:0]  tmds_data_n,
    output logic led0,
    output logic led1,
    output logic led2,
    output logic led3,
    output logic led4,
    output logic led5
);

    mnist_view_top #(
        .SD_ENABLE(SD_ENABLE),
        .USB_ENABLE(USB_ENABLE),
        .USB_VID(USB_VID), .USB_PID(USB_PID),
        .USB_READ_ACTIVE_LEVEL(USB_READ_ACTIVE_LEVEL)
    ) u_soc (
        .clk27(clk27),
        .btn_n0(btn_n0), .btn_n1(btn_n1),
        .btn_n2(btn_n2), .btn_n3(btn_n3),
        .DDR3_DQ(DDR3_DQ), .DDR3_DQS(DDR3_DQS),
        .DDR3_A(DDR3_A), .DDR3_BA(DDR3_BA),
        .DDR3_nRAS(DDR3_nRAS), .DDR3_nCAS(DDR3_nCAS),
        .DDR3_nWE(DDR3_nWE), .DDR3_CK(DDR3_CK),
        .DDR3_CKE(DDR3_CKE), .DDR3_nRESET(DDR3_nRESET),
        .DDR3_DM(DDR3_DM), .DDR3_ODT(DDR3_ODT),
        .sd_cs_n(sd_cs_n), .sd_sck(sd_sck),
        .sd_mosi(sd_mosi), .sd_miso(sd_miso),
        .ulpi_clk(ulpi_clk), .ulpi_data(ulpi_data),
        .ulpi_dir(ulpi_dir), .ulpi_nxt(ulpi_nxt),
        .ulpi_stp(ulpi_stp), .ulpi_rst(ulpi_rst),
        .sw2(sw2),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_data_p(tmds_data_p), .tmds_data_n(tmds_data_n),
        .led0(led0), .led1(led1), .led2(led2),
        .led3(led3), .led4(led4), .led5(led5)
    );

endmodule
