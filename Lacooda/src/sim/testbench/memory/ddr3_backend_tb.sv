`timescale 1ns/1ps

// ============================================================
// LACOODA DDR3 BACKEND TESTBENCH
// ============================================================
//
// Verifies ddr3_backend against the behavioural app model:
//
//   * backend_ready tracks init_calib_complete across the CDC
//   * write: command encoding, beat address, lane placement and
//     the byte inhibit mask
//   * read:  lane selection out of the 128-bit beat
//   * masked (partial) writes merge correctly in the beat
//   * the bus side survives backend backpressure
//   * reset recovery
//
// The SoC clock (27 MHz) and the app clock (100 MHz) run at their
// real ratio, so the crossing is exercised for real.
// ============================================================

module ddr3_backend_tb;

    import cpu_pkg::*;

    // SoC clock: 27 MHz
    logic clk = 1'b0;
    always #18.5185 clk = ~clk;

    // App clock: the IP's clk_out, ~100 MHz
    logic clk_x1 = 1'b0;
    always #5 clk_x1 = ~clk_x1;

    logic rst = 1'b1;

    bus_pkg::bus_req_s bus_req;
    bus_pkg::bus_rsp_s bus_rsp;

    logic backend_ready;

    logic         cmd_ready;
    logic [2:0]   cmd;
    logic         cmd_en;
    logic [27:0]  addr;
    logic         wr_data_rdy;
    logic [127:0] wr_data;
    logic         wr_data_en;
    logic         wr_data_end;
    logic [15:0]  wr_data_mask;
    logic [127:0] rd_data;
    logic         rd_data_valid;
    logic         rd_data_end;
    logic         init_calib_complete;
    logic         force_stall;

    int unsigned  wr_beats;
    int unsigned  rd_beats;
    logic [2:0]   last_cmd;
    logic [27:0]  last_addr;
    logic [127:0] last_wr_data;
    logic [15:0]  last_wr_mask;

    int tests  = 0;
    int errors = 0;

    // ========================================================
    // DEVICE UNDER TEST
    // ========================================================

    ddr3_backend dut (
        .clk                 (clk),
        .rst                 (rst),

        .bus_req             (bus_req),
        .bus_rsp             (bus_rsp),

        .backend_ready       (backend_ready),

        .clk_x1              (clk_x1),
        .init_calib_complete (init_calib_complete),

        .cmd_ready           (cmd_ready),
        .cmd                 (cmd),
        .cmd_en              (cmd_en),
        .addr                (addr),

        .wr_data_rdy         (wr_data_rdy),
        .wr_data             (wr_data),
        .wr_data_en          (wr_data_en),
        .wr_data_end         (wr_data_end),
        .wr_data_mask        (wr_data_mask),

        .rd_data             (rd_data),
        .rd_data_valid       (rd_data_valid),
        .rd_data_end         (rd_data_end)
    );

    // ========================================================
    // DDR3 APP MODEL
    // ========================================================

    ddr3_app_model #(
        .CALIB_CYCLES  (64),
        .CMD_GAP       (3),
        .RD_LATENCY    (20),
        .MEM_IDX_WIDTH (10)
    ) u_model (
        .clk                 (clk_x1),
        .rst_n               (~rst),

        .cmd                 (cmd),
        .cmd_en              (cmd_en),
        .addr                (addr),
        .cmd_ready           (cmd_ready),

        .wr_data             (wr_data),
        .wr_data_en          (wr_data_en),
        .wr_data_end         (wr_data_end),
        .wr_data_mask        (wr_data_mask),
        .wr_data_rdy         (wr_data_rdy),

        .rd_data             (rd_data),
        .rd_data_valid       (rd_data_valid),
        .rd_data_end         (rd_data_end),

        .init_calib_complete (init_calib_complete),

        .force_stall         (force_stall),

        .wr_beats            (wr_beats),
        .rd_beats            (rd_beats),
        .last_cmd            (last_cmd),
        .last_addr           (last_addr),
        .last_wr_data        (last_wr_data),
        .last_wr_mask        (last_wr_mask)
    );
