// ============================================================
// mnist_usb_loader  USB bulk OUT image receiver and DDR3 bus master
// ============================================================
module mnist_usb_loader #(
    parameter logic [15:0] USB_VID = 16'hCAFE,
    parameter logic [15:0] USB_PID = 16'h4001,
    parameter logic [31:0] DDR3_BASE = 32'h0800_0000,
    parameter logic [31:0] DDR3_SIZE = 32'h0800_0000
) (
    input  logic              clk,
    input  logic              usb_clk,
    input  logic              rst,
    input  logic              ddr_ready,
    input  logic              read_enable,
    inout  wire [7:0]         ulpi_data,
    input  logic              ulpi_dir,
    input  logic              ulpi_nxt,
    output logic              ulpi_stp,
    output logic              ulpi_rst,
    output logic              host_ready,
    output logic              load_done,
    output logic              load_error,
    output logic [3:0]        error_code,
    output soc_pkg::bus_req_s bus_req,
    input  soc_pkg::bus_rsp_s bus_rsp
);
    localparam logic [31:0] IMAGE_MAGIC = 32'h434F_4F44;

    logic [7:0] ulpi_tx_data, ulpi_rx_data, usb_payload_data;
    logic usb_rx_valid, usb_online;
    logic usb_online_clk1, usb_online_clk2;
    logic [3:0] usb_endpoint;
    logic [15:0] descriptor_addr;
    logic [7:0] descriptor_data;
    logic fifo_full, fifo_empty, fifo_pop;
    logic [7:0] fifo_data;
    logic ddr_ready_usb1, ddr_ready_usb2;
    logic load_inactive_usb1, load_inactive_usb2;
    logic read_enable_usb1, read_enable_usb2;

    logic [8:0] header_byte_count_q;
    logic [31:0] header_words_q [0:3];
    logic [31:0] expected_checksum_q;
    logic [31:0] payload_remaining_q, checksum_q;
    logic [1:0] payload_byte_index_q;
    logic [31:0] word_buffer_q, assembled_word;
    logic [31:0] write_addr_q, bus_addr_q, write_data_q;
    logic write_pending_q;
    logic [32:0] payload_end, padded_payload_end, blocks_required;

    typedef enum logic [2:0] {
        LoadWaitDdr,
        LoadHeader,
        LoadValidate,
        LoadPayload,
        LoadFinished,
        LoadFailed
    } loader_state_e;
    loader_state_e state_q;

    assign ulpi_data = ulpi_dir ? 8'hZZ : ulpi_tx_data;
    assign ulpi_rx_data = ulpi_data;
    assign ulpi_rst = !rst;

    // The ULPI clock is asynchronous to the SoC bus clock.
    always_ff @(posedge usb_clk or posedge rst) begin
        if (rst) begin
            ddr_ready_usb1 <= 1'b0;
            ddr_ready_usb2 <= 1'b0;
            load_inactive_usb1 <= 1'b0;
            load_inactive_usb2 <= 1'b0;
            read_enable_usb1 <= 1'b0;
            read_enable_usb2 <= 1'b0;
        end else begin
            ddr_ready_usb1 <= ddr_ready;
            ddr_ready_usb2 <= ddr_ready_usb1;
            load_inactive_usb1 <= !load_done && !load_error;
            load_inactive_usb2 <= load_inactive_usb1;
            read_enable_usb1 <= read_enable;
            read_enable_usb2 <= read_enable_usb1;
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            usb_online_clk1 <= 1'b0;
            usb_online_clk2 <= 1'b0;
        end else begin
            usb_online_clk1 <= usb_online;
            usb_online_clk2 <= usb_online_clk1;
        end
    end

    USB_Device_Controller_Top u_usb_device (
        .clk_i(usb_clk),
        .reset_i(rst),
        .usbrst_o(),
        .highspeed_o(),
        .suspend_o(),
        .online_o(usb_online),
        .txdat_i(8'd0),
        .txval_i(1'b0),
        .txdat_len_i(12'd0),
        .txiso_pid_i(4'd0),
        .txcork_i(1'b0),
        .txpop_o(),
        .txact_o(),
        .txpktfin_o(),
        .rxdat_o(usb_payload_data),
        .rxval_o(usb_rx_valid),
        .rxrdy_i(!fifo_full && ddr_ready_usb2 && load_inactive_usb2 &&
                 read_enable_usb2),
        .rxact_o(),
        .rxpktval_o(),
        .setup_o(),
        .endpt_o(usb_endpoint),
        .sof_o(),
        .inf_alter_i(8'd0),
        .inf_alter_o(),
        .inf_sel_o(),
        .inf_set_o(),
        .descrom_raddr_o(descriptor_addr),
        .desc_index_o(),
        .desc_type_o(),
        .descrom_rdata_i(descriptor_data),
        .desc_dev_addr_i(16'd0),
        .desc_dev_len_i(16'd18),
        .desc_qual_addr_i(16'd96),
        .desc_qual_len_i(16'd10),
        .desc_fscfg_addr_i(16'd32),
        .desc_fscfg_len_i(16'd32),
        .desc_hscfg_addr_i(16'd64),
        .desc_hscfg_len_i(16'd32),
        .desc_oscfg_addr_i(16'd106),
        .desc_hidrpt_addr_i(16'd0),
        .desc_hidrpt_len_i(16'd0),
        .desc_bos_addr_i(16'd0),
        .desc_bos_len_i(16'd0),
        .desc_strlang_addr_i(16'd0),
        .desc_strvendor_addr_i(16'd0),
        .desc_strvendor_len_i(16'd0),
        .desc_strproduct_addr_i(16'd0),
        .desc_strproduct_len_i(16'd0),
        .desc_strserial_addr_i(16'd0),
        .desc_strserial_len_i(16'd0),
        .desc_have_strings_i(1'b0),
        .ulpi_nxt_i(ulpi_nxt),
        .ulpi_dir_i(ulpi_dir),
        .ulpi_rxdata_i(ulpi_rx_data),
        .ulpi_txdata_o(ulpi_tx_data),
        .ulpi_stp_o(ulpi_stp)
    );

    // Vendor-specific interface with bulk OUT endpoint 1. The host can
    // send the existing 512-byte image header and unpadded payload.
    always_comb begin
        descriptor_data = 8'h00;
        case (descriptor_addr)
            16'd0:  descriptor_data = 8'd18;
            16'd1:  descriptor_data = 8'd1;
            16'd2:  descriptor_data = 8'h00;
            16'd3:  descriptor_data = 8'h02;
            16'd4:  descriptor_data = 8'h00;
            16'd5:  descriptor_data = 8'h00;
            16'd6:  descriptor_data = 8'h00;
            16'd7:  descriptor_data = 8'd64;
            16'd8:  descriptor_data = USB_VID[7:0];
            16'd9:  descriptor_data = USB_VID[15:8];
            16'd10: descriptor_data = USB_PID[7:0];
            16'd11: descriptor_data = USB_PID[15:8];
            16'd12: descriptor_data = 8'h00;
            16'd13: descriptor_data = 8'h01;
            16'd14: descriptor_data = 8'h00;
            16'd15: descriptor_data = 8'h00;
            16'd16: descriptor_data = 8'h00;
            16'd17: descriptor_data = 8'd1;
            16'd32: descriptor_data = 8'd9;
            16'd33: descriptor_data = 8'd2;
            16'd34: descriptor_data = 8'd32;
            16'd35: descriptor_data = 8'd0;
            16'd36: descriptor_data = 8'd1;
            16'd37: descriptor_data = 8'd1;
            16'd38: descriptor_data = 8'd0;
            16'd39: descriptor_data = 8'h80;
            16'd40: descriptor_data = 8'd50;
            16'd41: descriptor_data = 8'd9;
            16'd42: descriptor_data = 8'd4;
            16'd43: descriptor_data = 8'd0;
            16'd44: descriptor_data = 8'd0;
            16'd45: descriptor_data = 8'd2;
            16'd46: descriptor_data = 8'hFF;
            16'd47: descriptor_data = 8'd0;
            16'd48: descriptor_data = 8'd0;
            16'd49: descriptor_data = 8'd0;
            16'd50: descriptor_data = 8'd7;
            16'd51: descriptor_data = 8'd5;
            16'd52: descriptor_data = 8'h01;
            16'd53: descriptor_data = 8'd2;
            16'd54: descriptor_data = 8'd64;
            16'd55: descriptor_data = 8'd0;
            16'd56: descriptor_data = 8'd0;
            16'd57: descriptor_data = 8'd7;
            16'd58: descriptor_data = 8'd5;
            16'd59: descriptor_data = 8'h81;
            16'd60: descriptor_data = 8'd2;
            16'd61: descriptor_data = 8'd64;
            16'd62: descriptor_data = 8'd0;
            16'd63: descriptor_data = 8'd0;
            16'd64: descriptor_data = 8'd9;
            16'd65: descriptor_data = 8'd2;
            16'd66: descriptor_data = 8'd32;
            16'd67: descriptor_data = 8'd0;
            16'd68: descriptor_data = 8'd1;
            16'd69: descriptor_data = 8'd1;
            16'd70: descriptor_data = 8'd0;
            16'd71: descriptor_data = 8'h80;
            16'd72: descriptor_data = 8'd50;
            16'd73: descriptor_data = 8'd9;
            16'd74: descriptor_data = 8'd4;
            16'd75: descriptor_data = 8'd0;
            16'd76: descriptor_data = 8'd0;
            16'd77: descriptor_data = 8'd2;
            16'd78: descriptor_data = 8'hFF;
            16'd79: descriptor_data = 8'd0;
            16'd80: descriptor_data = 8'd0;
            16'd81: descriptor_data = 8'd0;
            16'd82: descriptor_data = 8'd7;
            16'd83: descriptor_data = 8'd5;
            16'd84: descriptor_data = 8'h01;
            16'd85: descriptor_data = 8'd2;
            16'd86: descriptor_data = 8'h00;
            16'd87: descriptor_data = 8'h02;
            16'd88: descriptor_data = 8'd0;
            16'd89: descriptor_data = 8'd7;
            16'd90: descriptor_data = 8'd5;
            16'd91: descriptor_data = 8'h81;
            16'd92: descriptor_data = 8'd2;
            16'd93: descriptor_data = 8'h00;
            16'd94: descriptor_data = 8'h02;
            16'd95: descriptor_data = 8'd0;
            16'd96: descriptor_data = 8'd10;
            16'd97: descriptor_data = 8'd6;
            16'd98: descriptor_data = 8'h00;
            16'd99: descriptor_data = 8'h02;
            16'd100: descriptor_data = 8'h00;
            16'd101: descriptor_data = 8'h00;
            16'd102: descriptor_data = 8'h00;
            16'd103: descriptor_data = 8'd64;
            16'd104: descriptor_data = 8'd1;
            16'd105: descriptor_data = 8'd0;
            16'd106: descriptor_data = 8'd9;
            16'd107: descriptor_data = 8'd7;
            16'd108: descriptor_data = 8'd32;
            16'd109: descriptor_data = 8'd0;
            16'd110: descriptor_data = 8'd1;
            16'd111: descriptor_data = 8'd1;
            16'd112: descriptor_data = 8'd0;
            16'd113: descriptor_data = 8'h80;
            16'd114: descriptor_data = 8'd50;
            16'd115: descriptor_data = 8'd9;
            16'd116: descriptor_data = 8'd4;
            16'd117: descriptor_data = 8'd0;
            16'd118: descriptor_data = 8'd0;
            16'd119: descriptor_data = 8'd2;
            16'd120: descriptor_data = 8'hFF;
            16'd121: descriptor_data = 8'd0;
            16'd122: descriptor_data = 8'd0;
            16'd123: descriptor_data = 8'd0;
            16'd124: descriptor_data = 8'd7;
            16'd125: descriptor_data = 8'd5;
            16'd126: descriptor_data = 8'h01;
            16'd127: descriptor_data = 8'd2;
            16'd128: descriptor_data = 8'd64;
            16'd129: descriptor_data = 8'd0;
            16'd130: descriptor_data = 8'd0;
            16'd131: descriptor_data = 8'd7;
            16'd132: descriptor_data = 8'd5;
            16'd133: descriptor_data = 8'h81;
            16'd134: descriptor_data = 8'd2;
            16'd135: descriptor_data = 8'd64;
            16'd136: descriptor_data = 8'd0;
            16'd137: descriptor_data = 8'd0;
            default: descriptor_data = 8'h00;
        endcase
    end

    async_fifo #(.DEPTH(4096), .WIDTH(8)) u_usb_rx_fifo (
        .wr_clk(usb_clk),
        .wr_rst(rst),
        .wr_en(usb_rx_valid && usb_endpoint == 4'd1 && !fifo_full &&
               ddr_ready_usb2 && load_inactive_usb2 && read_enable_usb2),
        .wr_data(usb_payload_data),
        .full(fifo_full),
        .rd_clk(clk),
        .rd_rst(rst),
        .rd_en(fifo_pop),
        .rd_data(fifo_data),
        .empty(fifo_empty)
    );

    assign host_ready = usb_online_clk2 && ddr_ready && read_enable_usb2 &&
                        !load_done && !load_error;
    assign payload_end = {1'b0, header_words_q[2]} +
                         {1'b0, header_words_q[3]};
    assign padded_payload_end = (payload_end + 33'd3) & 33'h1_FFFF_FFFC;
    assign blocks_required =
        ({1'b0, header_words_q[3]} + 33'd511) >> 9;

    always_comb begin
        assembled_word = word_buffer_q;
        assembled_word[8*payload_byte_index_q +: 8] = fifo_data;

        bus_req = '0;
        bus_req.valid = write_pending_q;
        bus_req.op = soc_pkg::BusWrite;
        bus_req.addr = bus_addr_q;
        bus_req.wdata = write_data_q;
        bus_req.wstrb = soc_pkg::BUS_STRB_ALL;
        fifo_pop = !fifo_empty && !write_pending_q &&
                   ((state_q == LoadHeader) || (state_q == LoadPayload));
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state_q <= LoadWaitDdr;
            header_byte_count_q <= '0;
            header_words_q[0] <= '0;
            header_words_q[1] <= '0;
            header_words_q[2] <= '0;
            header_words_q[3] <= '0;
            expected_checksum_q <= '0;
            payload_remaining_q <= '0;
            checksum_q <= '0;
            payload_byte_index_q <= '0;
            word_buffer_q <= '0;
            write_addr_q <= '0;
            bus_addr_q <= '0;
            write_data_q <= '0;
            write_pending_q <= 1'b0;
            load_done <= 1'b0;
            load_error <= 1'b0;
            error_code <= '0;
        end else begin
            if (write_pending_q && bus_rsp.ready) begin
                write_pending_q <= 1'b0;
                if (bus_rsp.error) begin
                    error_code <= 4'd6;
                    load_error <= 1'b1;
                    state_q <= LoadFailed;
                end else if ((state_q == LoadPayload) &&
                             (payload_remaining_q == 0)) begin
                    if (checksum_q == expected_checksum_q) begin
                        load_done <= 1'b1;
                        state_q <= LoadFinished;
                    end else begin
                        error_code <= 4'd4;
                        load_error <= 1'b1;
                        state_q <= LoadFailed;
                    end
                end
            end

            case (state_q)
                LoadWaitDdr: begin
                    if (ddr_ready)
                        state_q <= LoadHeader;
                end

                LoadHeader: begin
                    if (fifo_pop) begin
                        if (header_byte_count_q < 9'd16)
                            header_words_q[header_byte_count_q[4:2]]
                                [8*header_byte_count_q[1:0] +: 8] <= fifo_data;
                        else if ((header_byte_count_q >= 9'd32) &&
                                 (header_byte_count_q < 9'd36))
                            expected_checksum_q
                                [8*header_byte_count_q[1:0] +: 8] <= fifo_data;

                        if (header_byte_count_q == 9'd511)
                            state_q <= LoadValidate;
                        else
                            header_byte_count_q <= header_byte_count_q + 1'b1;
                    end
                end

                LoadValidate: begin
                    if (header_words_q[0] != IMAGE_MAGIC) begin
                        error_code <= 4'd1;
                        load_error <= 1'b1;
                        state_q <= LoadFailed;
                    end else if ((header_words_q[1] == 0) ||
                                 (header_words_q[3] == 0) ||
                                 (blocks_required != {1'b0, header_words_q[1]}) ||
                                 ({1'b0, header_words_q[3]} >
                                  ({1'b0, header_words_q[1]} << 9))) begin
                        error_code <= 4'd2;
                        load_error <= 1'b1;
                        state_q <= LoadFailed;
                    end else if ((header_words_q[2][1:0] != 0) ||
                                 (padded_payload_end > {1'b0, DDR3_SIZE})) begin
                        error_code <= 4'd3;
                        load_error <= 1'b1;
                        state_q <= LoadFailed;
                    end else begin
                        payload_remaining_q <= header_words_q[3];
                        checksum_q <= '0;
                        payload_byte_index_q <= '0;
                        word_buffer_q <= '0;
                        write_addr_q <= DDR3_BASE + header_words_q[2];
                        state_q <= LoadPayload;
                    end
                end

                LoadPayload: begin
                    if (fifo_pop) begin
                        checksum_q <= checksum_q + {24'd0, fifo_data};
                        payload_remaining_q <= payload_remaining_q - 1'b1;

                        if ((payload_byte_index_q == 2'd3) ||
                            (payload_remaining_q == 1)) begin
                            write_pending_q <= 1'b1;
                            bus_addr_q <= write_addr_q;
                            write_data_q <= assembled_word;
                            write_addr_q <= write_addr_q + 32'd4;
                            word_buffer_q <= '0;
                            payload_byte_index_q <= '0;
                        end else begin
                            word_buffer_q <= assembled_word;
                            payload_byte_index_q <= payload_byte_index_q + 1'b1;
                        end
                    end
                end

                LoadFinished: begin
                    state_q <= LoadFinished;
                end

                LoadFailed: begin
                    state_q <= LoadFailed;
                end

                default: state_q <= LoadWaitDdr;
            endcase
        end
    end

endmodule
