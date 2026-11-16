`timescale 1ns/1ps

// ============================================================
// LACOODA DDR3 APP-INTERFACE MODEL — SIMULATION ONLY
// ============================================================
//
// The Gowin DDR3 Memory Interface IP ships as a `pragma protect`
// (AES-128) netlist, so it cannot be elaborated by Icarus Verilog.
// This model reproduces the app-side protocol with realistic
// latencies so that ddr3_backend can be verified in simulation.
//
// Behaviour modelled, taken from the Sipeed DDR-test reference
// (tester.v) and the IP port list:
//
//   cmd          3'd0 = write, 3'd1 = read
//   addr         beat address, 16-byte units
//   wr_data      128-bit beat
//   wr_data_mask bit set = that byte is inhibited (not written)
//   rd_data      returned RD_LATENCY cycles after a read command
//
// The model is NOT part of the synthesizable design and is not
// listed in lacooda.gprj. It exists only for this testbench.
//
// Timing parameters are deliberately pessimistic relative to the
// real IP, so the adapter is verified against a slow backend.
// ============================================================

module ddr3_app_model #(
    parameter int CALIB_CYCLES  = 64,
    parameter int CMD_GAP       = 3,
    parameter int RD_LATENCY    = 20,
    parameter int MEM_IDX_WIDTH = 10
)(
    input  logic         clk,
    input  logic         rst_n,

    // command channel
    input  logic [2:0]   cmd,
    input  logic         cmd_en,
    input  logic [27:0]  addr,
    output logic         cmd_ready,

    // write data channel
    input  logic [127:0] wr_data,
    input  logic         wr_data_en,
    input  logic         wr_data_end,
    input  logic [15:0]  wr_data_mask,
    output logic         wr_data_rdy,

    // read data channel
    output logic [127:0] rd_data,
    output logic         rd_data_valid,
    output logic         rd_data_end,

    // status
    output logic         init_calib_complete,

    // testbench control
    input  logic         force_stall,

    // observability
    output int unsigned  wr_beats,
    output int unsigned  rd_beats,
    output logic [2:0]   last_cmd,
    output logic [27:0]  last_addr,
    output logic [127:0] last_wr_data,
    output logic [15:0]  last_wr_mask
);

    localparam int MEM_BEATS = 1 << MEM_IDX_WIDTH;
    localparam int MEM_BYTES = MEM_BEATS * 16;

    // ========================================================
    // BYTE-ADDRESSABLE BEAT MEMORY
    // ========================================================
    //
    // Stored as bytes so that a masked write only disturbs the
    // bytes it actually enables, exactly like real DDR3 with DQM.
    // ========================================================

    logic [7:0] mem [0:MEM_BYTES-1];

    integer b;

    // ========================================================
    // CALIBRATION
    // ========================================================

    int unsigned calib_cnt;

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin
            calib_cnt           <= 0;
            init_calib_complete <= 1'b0;
        end else if (calib_cnt < CALIB_CYCLES) begin
            calib_cnt           <= calib_cnt + 1;
            init_calib_complete <= 1'b0;
        end else begin
            init_calib_complete <= 1'b1;
        end

    end

    // ========================================================
    // BACKPRESSURE
    // ========================================================
    //
    // After a command the model refuses new commands for CMD_GAP
    // cycles. force_stall lets the testbench hold the backend off
    // for an arbitrary time.
    // ========================================================

    int unsigned gap_cnt;
    logic        gap_busy;

    assign cmd_ready   = init_calib_complete && !gap_busy && !force_stall;
    assign wr_data_rdy = init_calib_complete && !gap_busy && !force_stall;

    logic [MEM_IDX_WIDTH-1:0] mem_idx;

    assign mem_idx = addr[MEM_IDX_WIDTH-1:0];

    // ========================================================
    // COMMAND AND DATA ENGINE
    // ========================================================

    int unsigned rd_cnt;
    logic        rd_pending;

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            gap_busy      <= 1'b0;
            gap_cnt       <= 0;

            rd_pending    <= 1'b0;
            rd_cnt        <= 0;

            rd_data       <= '0;
            rd_data_valid <= 1'b0;
            rd_data_end   <= 1'b0;

            wr_beats      <= 0;
            rd_beats      <= 0;

            last_cmd      <= 3'd0;
            last_addr     <= 28'd0;
            last_wr_data  <= '0;
            last_wr_mask  <= '0;

        end else begin

            rd_data_valid <= 1'b0;
            rd_data_end   <= 1'b0;

            // ------------------------------------------------
            // COMMAND GAP TIMER
            // ------------------------------------------------

            if (gap_busy) begin

                if (gap_cnt + 1 >= CMD_GAP) begin
                    gap_busy <= 1'b0;
                    gap_cnt  <= 0;
                end else begin
                    gap_cnt <= gap_cnt + 1;
                end

            end

            // ------------------------------------------------
            // WRITE BEAT
            // ------------------------------------------------

            if (cmd_en && cmd_ready &&
                (cmd == 3'd0) && wr_data_en && wr_data_rdy) begin

                last_cmd     <= cmd;
                last_addr    <= addr;
                last_wr_data <= wr_data;
                last_wr_mask <= wr_data_mask;

                wr_beats     <= wr_beats + 1;

                gap_busy     <= 1'b1;
                gap_cnt      <= 0;

                for (b = 0; b < 16; b = b + 1) begin
                    if (wr_data_mask[b] == 1'b0) begin
                        mem[mem_idx * 16 + b] <= wr_data[b*8 +: 8];
                    end
                end

            end

            // ------------------------------------------------
            // READ COMMAND
            // ------------------------------------------------

            if (cmd_en && cmd_ready && (cmd == 3'd1)) begin

                last_cmd   <= cmd;
                last_addr  <= addr;

                rd_beats   <= rd_beats + 1;

                gap_busy   <= 1'b1;
                gap_cnt    <= 0;

                rd_pending <= 1'b1;
                rd_cnt     <= 0;

                // Snapshot the whole 128-bit beat.
                for (b = 0; b < 16; b = b + 1) begin
                    rd_data[b*8 +: 8] <= mem[mem_idx * 16 + b];
                end

            end

            // ------------------------------------------------
            // READ DATA RETURN
            // ------------------------------------------------

            if (rd_pending) begin

                if (rd_cnt + 1 >= RD_LATENCY) begin
                    rd_pending    <= 1'b0;
                    rd_data_valid <= 1'b1;
                    rd_data_end   <= 1'b1;
                end else begin
                    rd_cnt <= rd_cnt + 1;
                end

            end

        end

    end

endmodule

