`timescale 1ns/1ps

// ============================================================
// LACOODA DDR3 BACKEND ADAPTER
// ============================================================
//
// Connects the native LACOODA bus transaction produced by
// ddr3_bridge to the Gowin DDR3 Memory Interface IP.
//
// ddr3_bridge            ddr3_backend              DDR3 IP
//   (native bus)   <-->   (this module)   <-->   (app interface)
//
// WHAT THIS MODULE IS
//
//   * a protocol adapter: one native bus word <-> one 128-bit
//     DDR3 app burst beat
//   * a width converter: 32-bit bus <-> 128-bit app data
//   * THE ONLY CLOCK-DOMAIN CROSSING IN THE SoC
//
// WHAT THIS MODULE IS NOT
//
//   * not a DDR3 controller, PHY, or IP replacement
//   * not a burst engine: app_burst_number is fixed to one
//     burst by the top level, so one beat is one transaction
//   * not a cache and not a scheduler
//   * not responsible for address range or alignment checks.
//     ddr3_bridge.sv rejects invalid and unaligned addresses
//     before forwarding, so this module only ever sees a valid,
//     aligned, translated local address inside
//     [0, memory_pkg::DDR3_BYTES).
//
// CLOCK DOMAINS
//
//   clk     : the SoC clock (27 MHz). Bus side.
//   clk_x1  : the DDR3 IP's own clk_out (~100 MHz). App side.
//
//   The DDR3 IP app interface is synchronous to clk_x1, not to
//   the SoC clock. The Sipeed DDR3 reference drives its whole
//   app-side state machine on clk_x1 (tester.v:106 and :132),
//   which is why this adapter must cross domains.
//
//   Every other module in the SoC stays single-clock. The RPU,
//   ddr3_bridge, CPU, GPU, ROM, RAM and MMIO never see clk_x1.
//
//   clk_x1 is produced by the IP and only runs once the PLL has
//   locked, so the clk_x1-side reset is generated here instead
//   of being supplied by the top level.
//
// HANDOFF CONTRACT (inherited from ddr3_bridge.sv)
//
//   The upstream request is held stable for as long as the
//   transaction takes (ddr3_bridge freezes request_reg), so the
//   toggle-with-stable-payload pattern below is safe.
//
//   A write is acknowledged only after the write command has been
//   accepted (cmd_ready) AND the write data beat has been accepted
//   (wr_data_rdy). Acknowledging merely because a command was
//   accepted would be a protocol violation.
//
//   backend_ready is asserted only after the IP reports
//   init_calib_complete. While it is low, ddr3_bridge returns a
//   bus error instead of forwarding, so this module cannot hang
//   the fabric on an uncalibrated device.
//
// DDR3 APP INTERFACE FACTS (verified against the Sipeed DDR-test
// reference and the IP port list)
//
//   cmd          : 3'd0 = write, 3'd1 = read
//   addr         : app address in 16-byte units, i.e. byte/16.
//                  tester.v:92 - "in every Single-Burst, the addr
//                  should increase by 8", counted in 2-byte units.
//   wr_data      : 128 bits = four 32-bit lanes
//   wr_data_mask : 16 bits, one inhibit bit per byte of wr_data.
//                  16'h0000 writes every byte (the reference ties
//                  it to 16'h0000); a set bit suppresses that byte.
//   rd_data      : 128 bits; the addressed lane is selected by
//                  byte_addr[3:2]
//
// STATIC APP INPUTS OWNED BY THE TOP LEVEL
//
//   app_burst_number = 6'd0 (one burst), burst = 1'b1,
//   sr_req = 1'b0, ref_req = 1'b0
//
// TRANSACTION SEQUENCE
//
//   1. Bus side latches the request and flips req_toggle.
//   2. App side sees the toggle, samples the stable payload and
//      runs the DDR3 command.
//   3. App side captures the read data and publishes the result.
//   4. App side flips ack_toggle.
//   5. Bus side sees the ack, presents a registered response and
//      returns to idle once the upstream request drops.
//
// One outstanding transaction. No pipelining.
// ============================================================

module ddr3_backend (

    // --------------------------------------------------------
    // BUS SIDE (clk domain)
    // --------------------------------------------------------

    input logic clk,
    input logic rst,

    input  bus_pkg::bus_req_s bus_req,
    output bus_pkg::bus_rsp_s bus_rsp,

    // Backend availability, clk domain, consumed by ddr3_bridge.
    output logic backend_ready,

    // --------------------------------------------------------
    // APP SIDE (clk_x1 domain)
    // --------------------------------------------------------

    input logic clk_x1,

    // Calibration status from the IP (clk_x1 domain).
    input logic init_calib_complete,

    // Command channel
    input  logic        cmd_ready,
    output logic [2:0]  cmd,
    output logic        cmd_en,
    output logic [27:0] addr,

    // Write data channel
    input  logic         wr_data_rdy,
    output logic [127:0] wr_data,
    output logic         wr_data_en,
    output logic         wr_data_end,
    output logic [15:0]  wr_data_mask,

    // Read data channel
    input  logic [127:0] rd_data,
    input  logic         rd_data_valid,
    input  logic         rd_data_end

);

    // ========================================================
    // APP COMMAND ENCODING
    // ========================================================

    localparam logic [2:0] DDR3_APP_CMD_WRITE = 3'd0;
    localparam logic [2:0] DDR3_APP_CMD_READ  = 3'd1;

    // ========================================================
    // BUS-SIDE STATE
    // ========================================================
    //
    // BUS_IDLE     : accept one upstream request
    // BUS_WAIT_ACK : hold the request until the app side answers
    // BUS_RESPOND  : present the registered response upstream
    // ========================================================

    typedef enum logic [1:0] {
        BUS_IDLE     = 2'b00,
        BUS_WAIT_ACK = 2'b01,
        BUS_RESPOND  = 2'b10
    } bus_state_e;

    bus_state_e bus_state_reg;

    // ========================================================
    // APP-SIDE STATE
    // ========================================================
    //
    // APP_IDLE      : wait for a new request toggle
    // APP_CAPTURE   : sample the now-stable request payload
    // APP_WRITE     : issue the write command and the data beat
    // APP_READ_CMD  : issue the read command
    // APP_READ_DATA : wait for and capture the read data
    // APP_PUBLISH   : register the result for the bus side
    // APP_ACK       : flip the acknowledge toggle
    // ========================================================

    typedef enum logic [2:0] {
        APP_IDLE      = 3'b000,
        APP_CAPTURE   = 3'b001,
        APP_WRITE     = 3'b010,
        APP_READ_CMD  = 3'b011,
        APP_READ_DATA = 3'b100,
        APP_PUBLISH   = 3'b101,
        APP_ACK       = 3'b110
    } app_state_e;

    app_state_e app_state_reg;

    // ========================================================
    // DDR-SIDE RESET
    // ========================================================
    //
    // Asynchronous assert, synchronous deassert in clk_x1.
    //
    // clk_x1 is produced by the DDR3 IP itself and only runs
    // once the PLL has locked, so this reset cannot come from
    // the top level. Asserting it while the SoC reset is held
    // keeps the app-side FSM from running on an unlocked clock.
    // ========================================================

    logic [1:0] rst_x1_sync_reg;

    always_ff @(posedge clk_x1 or posedge rst) begin
        if (rst) begin
            rst_x1_sync_reg <= 2'b11;
        end else begin
            rst_x1_sync_reg <= {rst_x1_sync_reg[0], 1'b0};
        end
    end

    logic rst_x1;

    assign rst_x1 = rst_x1_sync_reg[1];

    // ========================================================
    // BUS-SIDE REQUEST REGISTERS
    // ========================================================
    //
    // Written once in BUS_IDLE and never modified until the next
    // transaction, so the app side can sample them safely.
    // ========================================================

    logic        req_toggle_reg;

    logic [31:0] req_addr_reg;
    logic        req_write_reg;
    logic [31:0] req_wdata_reg;
    logic [3:0]  req_wstrb_reg;

    // ========================================================
    // BUS-SIDE RESPONSE REGISTERS
    // ========================================================

    logic [31:0] rsp_rdata_reg;
    logic        rsp_error_reg;

    // ========================================================
    // TOGGLE SYNCHRONISERS
    // ========================================================
    //
    // Two flops each. Only the toggles cross domains as events;
    // the payloads cross as stable data sampled after the toggle
    // is observed, which is why no payload flop needs a third
    // synchroniser stage.
    // ========================================================

    logic [1:0] req_toggle_sync_reg;
    logic [1:0] ack_toggle_sync_reg;

    logic req_toggle_sync;
    logic ack_toggle_sync;

    always_ff @(posedge clk) begin
        if (rst) begin
            ack_toggle_sync_reg <= 2'b00;
        end else begin
            ack_toggle_sync_reg <= {
                ack_toggle_sync_reg[0],
                ack_toggle_reg
            };
        end
    end

    assign ack_toggle_sync = ack_toggle_sync_reg[1];

    always_ff @(posedge clk_x1) begin
        if (rst_x1) begin
            req_toggle_sync_reg <= 2'b00;
        end else begin
            req_toggle_sync_reg <= {
                req_toggle_sync_reg[0],
                req_toggle_reg
            };
        end
    end

    assign req_toggle_sync = req_toggle_sync_reg[1];

    // ========================================================
    // APP-SIDE PUBLISH REGISTERS
    // ========================================================
    //
    // Held stable from APP_PUBLISH until the next transaction,
    // so the bus side can sample them when it sees ack_toggle.
    // ========================================================

    logic        ack_toggle_reg;
    logic [31:0] app_rdata_reg;
    logic        app_error_reg;


    // ========================================================
    // APP-SIDE CAPTURED REQUEST
    // ========================================================
    //
    // Sampled in APP_CAPTURE, one cycle after the synchronised
    // toggle edge is observed. By then the payload has already
    // been stable in the bus domain for several clk_x1 cycles,
    // so no third synchroniser stage is required.
    // ========================================================

    logic        app_write_reg;
    logic [31:0] app_wdata_reg;
    logic [3:0]  app_wstrb_reg;
    logic [31:0] app_addr_reg;

    // Derived combinationally from app_addr_reg, and kept out of the
    // always_* processes for the same Icarus reason as the read lane
    // select below: constant bit-selects are not evaluated there.
    logic [1:0]  app_lane;       // byte address [3:2]
    logic [27:0] app_beat_addr;  // byte address [27:4]

    assign app_lane      = app_addr_reg[3:2];
    assign app_beat_addr = {4'b0, app_addr_reg[27:4]};

    logic        rd_cmd_sent_reg;

    // ========================================================
    // BACKEND AVAILABILITY
    // ========================================================
    //
    // init_calib_complete originates in the clk_x1 domain, so it
    // is synchronised into clk before ddr3_bridge consumes it.
    // ========================================================

    logic [1:0] calib_sync_reg;

    always_ff @(posedge clk) begin
        if (rst) begin
            calib_sync_reg <= 2'b00;
        end else begin
            calib_sync_reg <= {
                calib_sync_reg[0],
                init_calib_complete
            };
        end
    end

    assign backend_ready = calib_sync_reg[1];

    // ========================================================
    // BUS-SIDE RESPONSE
    // ========================================================
    //
    // Only BUS_RESPOND drives ready. The response is registered
    // and never forwarded combinationally from the app side.
    // ========================================================

    always_comb begin

        bus_rsp = '0;

        if (!rst && (bus_state_reg == BUS_RESPOND)) begin

            bus_rsp.ready = 1'b1;
            bus_rsp.rdata = rsp_rdata_reg;
            bus_rsp.error = rsp_error_reg;

        end

    end

    // ========================================================
    // BUS-SIDE STATE MACHINE
    // ========================================================
    //
    // BUS_WAIT_ACK completes when the synchronised acknowledge
    // matches the toggle this side raised, so a stale acknowledge
    // from the previous transaction can never complete the new
    // one.
    // ========================================================

    always_ff @(posedge clk) begin

        if (rst) begin

            bus_state_reg  <= BUS_IDLE;
            req_toggle_reg <= 1'b0;
            req_addr_reg   <= '0;
            req_write_reg  <= 1'b0;
            req_wdata_reg  <= '0;
            req_wstrb_reg  <= '0;
            rsp_rdata_reg  <= '0;
            rsp_error_reg  <= 1'b0;

        end else begin

            case (bus_state_reg)

                // ============================================
                // BUS_IDLE
                // ============================================

                BUS_IDLE: begin

                    if (bus_req.valid) begin

                        req_addr_reg   <= bus_req.addr;
                        req_wdata_reg  <= bus_req.wdata;
                        req_wstrb_reg  <= bus_req.wstrb;

                        req_write_reg <=
                            (bus_req.op == bus_pkg::BUS_WRITE);

                        // Publish the payload, then raise the toggle.
                        req_toggle_reg <= ~req_toggle_reg;

                        rsp_rdata_reg <= '0;
                        rsp_error_reg <= 1'b0;

                        bus_state_reg <= BUS_WAIT_ACK;

                    end

                end

                // ============================================
                // BUS_WAIT_ACK
                // ============================================

                BUS_WAIT_ACK: begin

                    if (ack_toggle_sync == req_toggle_reg) begin

                        rsp_rdata_reg <= app_rdata_reg;
                        rsp_error_reg <= app_error_reg;

                        bus_state_reg <= BUS_RESPOND;

                    end

                end

                // ============================================
                // BUS_RESPOND
                // ============================================
                //
                // ready is asserted while the upstream request is
                // still valid. The rising edge on which
                // valid && ready is observed completes the
                // transaction. The upstream master must hold
                // valid until then, as required by bus_pkg.
                // ============================================

                BUS_RESPOND: begin

                    if (!bus_req.valid) begin
                        bus_state_reg <= BUS_IDLE;
                    end

                end

                // ============================================
                // INVALID STATE RECOVERY
                // ============================================

                default: begin

                    bus_state_reg <= BUS_IDLE;

                end

            endcase

        end

    end


    // ========================================================
    // READ LANE SELECT
    // ========================================================
    //
    // A 128-bit beat covers four 32-bit words. The word this
    // transaction asked for is the one selected by byte[3:2].
    // ========================================================

    logic [31:0] rd_data_lane;

    // Constant bit-selects are written as a continuous assignment on
    // purpose: Icarus Verilog 12 cannot evaluate constant selects
    // inside an always_* process ("all bits will be included"), which
    // would silently turn the lane select into a no-op.
    assign rd_data_lane =
        (app_lane == 2'd0) ? rd_data[31:0]  :
        (app_lane == 2'd1) ? rd_data[63:32] :
        (app_lane == 2'd2) ? rd_data[95:64] :
                             rd_data[127:96];


    // ========================================================
    // APP-SIDE STATE MACHINE
    // ========================================================
    //
    // APP_PUBLISH registers the result, then APP_ACK flips the
    // acknowledge. Publishing before acknowledging guarantees the
    // payload has been stable for at least one clk_x1 cycle, and
    // it stays stable until the next transaction, so the bus side
    // can sample it safely when it observes the acknowledge.
    // ========================================================

    always_ff @(posedge clk_x1) begin

        if (rst_x1) begin

            app_state_reg     <= APP_IDLE;
            ack_toggle_reg    <= 1'b0;
            app_rdata_reg     <= '0;
            app_error_reg     <= 1'b0;
            app_write_reg     <= 1'b0;
            app_wdata_reg     <= '0;
            app_wstrb_reg     <= '0;
            app_addr_reg      <= '0;
            rd_cmd_sent_reg   <= 1'b0;

        end else begin

            case (app_state_reg)

                // ============================================
                // APP_IDLE
                // ============================================
                //
                // A differing toggle means a new request is
                // waiting. Its payload is already stable.
                // ============================================

                APP_IDLE: begin

                    if (req_toggle_sync != ack_toggle_reg) begin
                        app_state_reg <= APP_CAPTURE;
                    end

                end

                // ============================================
                // APP_CAPTURE
                // ============================================
                //
                // Sample the payload and derive the burst beat
                // address plus the 32-bit lane select.
                // ============================================

                APP_CAPTURE: begin

                    app_write_reg     <= req_write_reg;
                    app_wdata_reg     <= req_wdata_reg;
                    app_wstrb_reg     <= req_wstrb_reg;

                    app_addr_reg      <= req_addr_reg;

                    rd_cmd_sent_reg   <= 1'b0;

                    if (req_write_reg) begin
                        app_state_reg <= APP_WRITE;
                    end else begin
                        app_state_reg <= APP_READ_CMD;
                    end

                end

                // ============================================
                // APP_WRITE
                // ============================================
                //
                // Complete only when the command AND the write
                // data beat have both been accepted.
                // ============================================

                APP_WRITE: begin

                    if (cmd_ready && wr_data_rdy) begin
                        app_state_reg <= APP_PUBLISH;
                    end

                end

                // ============================================
                // APP_READ_CMD
                // ============================================

                APP_READ_CMD: begin

                    if (cmd_ready && !rd_cmd_sent_reg) begin

                        rd_cmd_sent_reg <= 1'b1;
                        app_state_reg   <= APP_READ_DATA;

                    end

                end

                // ============================================
                // APP_READ_DATA
                // ============================================
                //
                // app_burst_number is fixed to one burst, so a
                // single rd_data_valid carries the whole 128-bit
                // beat. rd_data_end is therefore redundant here
                // and is not consumed.
                // ============================================

                APP_READ_DATA: begin

                    if (rd_data_valid) begin

                        app_rdata_reg <= rd_data_lane;
                        app_state_reg <= APP_PUBLISH;

                    end

                end

                // ============================================
                // APP_PUBLISH
                // ============================================
                //
                // app_error_reg is driven low unconditionally.
                // This backend has no error source of its own:
                // ddr3_bridge rejects out-of-range and unaligned
                // accesses before they reach this module. A future
                // backend timeout would raise the error here.
                // ============================================

                APP_PUBLISH: begin

                    app_error_reg  <= 1'b0;
                    ack_toggle_reg <= req_toggle_sync;

                    app_state_reg  <= APP_ACK;

                end

                // ============================================
                // APP_ACK
                // ============================================

                APP_ACK: begin

                    app_state_reg <= APP_IDLE;

                end

                // ============================================
                // INVALID STATE RECOVERY
                // ============================================

                default: begin

                    app_state_reg <= APP_IDLE;

                end

            endcase

        end

    end


    // ========================================================
    // APP COMMAND AND WRITE-DATA OUTPUTS
    // ========================================================
    //
    // cmd_en, wr_data_en and wr_data_end are one-cycle pulses
    // derived from the FSM state and gated by the IP's own ready
    // signals, which is exactly how the Sipeed reference drives
    // the same interface (tester.v:176).
    //
    // wr_data_mask is an inhibit mask: a set bit suppresses that
    // byte. The addressed lane's bits follow wstrb, and every
    // other lane stays inhibited, so a 32-bit store can never
    // disturb the neighbouring words of the 128-bit beat.
    // ========================================================

    always_comb begin

        cmd          = DDR3_APP_CMD_WRITE;
        cmd_en       = 1'b0;
        addr         = app_beat_addr;

        wr_data      = 128'd0;
        wr_data_en   = 1'b0;
        wr_data_end  = 1'b0;
        wr_data_mask = 16'hFFFF;

        case (app_state_reg)

            // ============================================
            // WRITE BEAT
            // ============================================
            //
            // Whole-vector concatenations instead of bit-selects,
            // so lane placement is evaluated identically by Icarus
            // and by GowinSynthesis.
            // ============================================

            APP_WRITE: begin

                if (cmd_ready && wr_data_rdy) begin

                    cmd    = DDR3_APP_CMD_WRITE;
                    cmd_en = 1'b1;
                    addr   = app_beat_addr;

                    case (app_lane)

                        2'd0: begin
                            wr_data      = {96'd0, app_wdata_reg};
                            wr_data_mask = {12'hFFF, ~app_wstrb_reg};
                        end

                        2'd1: begin
                            wr_data      = {64'd0, app_wdata_reg, 32'd0};
                            wr_data_mask = {8'hFF, ~app_wstrb_reg, 4'hF};
                        end

                        2'd2: begin
                            wr_data      = {32'd0, app_wdata_reg, 64'd0};
                            wr_data_mask = {4'hF, ~app_wstrb_reg, 8'hFF};
                        end

                        default: begin
                            wr_data      = {app_wdata_reg, 96'd0};
                            wr_data_mask = {~app_wstrb_reg, 12'hFFF};
                        end

                    endcase

                    wr_data_en  = 1'b1;
                    wr_data_end = 1'b1;

                end

            end

            // ============================================
            // READ COMMAND
            // ============================================

            APP_READ_CMD: begin

                if (cmd_ready && !rd_cmd_sent_reg) begin

                    cmd    = DDR3_APP_CMD_READ;
                    cmd_en = 1'b1;
                    addr   = app_beat_addr;

                end

            end

            // ============================================
            // IDLE BEAT
            // ============================================

            default: begin

                cmd    = DDR3_APP_CMD_WRITE;
                cmd_en = 1'b0;
                addr   = app_beat_addr;

            end

        endcase

    end

endmodule

