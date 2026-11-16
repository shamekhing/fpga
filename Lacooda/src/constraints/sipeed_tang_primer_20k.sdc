// ============================================================
// LACOODA timing constraints - Sipeed Tang Primer 20K
//
// Timing target: 27 MHz (37.037 ns), matching the onboard oscillator and
// the Gowin process configuration's Global_Freq. 100 MHz (10 ns) is a
// future target that requires a PLL and a new timing run.
//
// Without this create_clock the analyzer only sees an inferred clock
// (WARN TA1132 'clk27' was determined to be a clock but was not created)
// and falls back to the synthesis Global Frequency as the period.
// ============================================================

create_clock -name clk27 -period 37.037 -waveform {0.000 18.518} [get_ports {clk27}]
