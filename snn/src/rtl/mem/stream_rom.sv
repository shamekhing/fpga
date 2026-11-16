// stream_rom.sv
// Event ROM: 16-bit words holding the merged per-row differential-time
// streams for one test image. Layout per row: one count word (10-bit count
// in the low bits), followed by that row's event words
// {neg[0], column[4:0], dt[7:0]}. The base-address table lives in base_rom.
// Read is combinational so the row sequencer can walk a row without latency.
module stream_rom #(
    parameter string INIT_FILE = "data/streams/stream.mem",
    parameter int    DEPTH     = STREAM_DEPTH
) (
    input  logic [15:0] addr,
    output logic [15:0] data
);

  logic [15:0] mem [DEPTH];

  initial $readmemh(INIT_FILE, mem);

  assign data = mem[addr];

endmodule
