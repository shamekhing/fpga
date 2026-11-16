// base_rom.sv
// Base-address table: one 16-bit entry per input row, giving the stream-ROM
// address of that row's count word. Written by model/export_mem.py together
// with the event stream.
module base_rom #(
    parameter string INIT_FILE = "data/streams/base_table.mem",
    parameter int    ROWS      = N_INPUT_STREAMS
) (
    input  logic [4:0]  addr,   // row index 0..27
    output logic [15:0] data    // stream-ROM address of the row's count word
);

  logic [15:0] mem [ROWS];

  initial $readmemh(INIT_FILE, mem);

  assign data = mem[addr];

endmodule
