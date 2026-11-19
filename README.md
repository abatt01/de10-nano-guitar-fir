# DE10-Nano fixed-point FIR accelerator

A 128-tap low-pass FIR for signed 16-bit PCM. The Cyclone V FPGA reads samples from HPS DDR, filters them, writes the results back, and signals completion to Linux with an interrupt. The board runner compares the FPGA output bit-for-bit with a Cortex-A9 C implementation and reports elapsed times for both paths.

[Build, validate, run on the board, and restore the prior FPGA image](fir128/README.md).

The project includes the FIR RTL, ARM runner, deterministic audio fixture generator, integer reference, RTL testbench, and device-tree overlay. The FPGA build uses Terasic's Revision E System CD as an external dependency.

The [living project report](docs/guitar-fir-report.pdf) records the system design,
validation evidence, and hardware bring-up status.

## Live board result

The ARM and FPGA produced identical output for all 16,384 samples in one
generated guitar-style clip. The ARM took **22.968 ms** and the FPGA path took
**47.828 ms end to end**, including memory transfers and the interrupt wait.

[Terminal output](docs/guitar-fir-terminal.png) ·
[Input and filtered waveforms](docs/guitar-fir-waveform.png) ·
[Raw timing log](docs/guitar-fir-live.txt)

[FPGA profiling and four-tap results](docs/fir-profiling.md)
