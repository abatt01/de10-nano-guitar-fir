`timescale 1ns/1ps
module fir128_tb #(parameter TAPS_PER_CLOCK = 1);
    reg clk = 0;
    always #10 clk = ~clk;
    reg reset = 1;
    reg [3:0] csr_address = 0;
    reg csr_write = 0;
    reg [31:0] csr_wdata = 0;
    wire [31:0] csr_rdata, address;
    wire [4:0] burstcount;
    wire rd, wr, irq;
    wire [63:0] write_data;
    reg [63:0] read_data = 0;
    reg read_valid = 0, write_valid = 0;
    reg [15:0] input_pcm [0:16383], expected [0:16383];
    integer reads = 0, writes = 0, retired = 0;
    integer cycle = 0, delay_count = 0, k;
    integer read_clocks = 0, write_clocks = 0, start_cycle, elapsed;
    reg [31:0] clear_count, read_count, mac_count, write_count, pack_count, lanes;
    reg response_is_write = 0;
    wire wait_request = (cycle % 7) < 4;
    reg stalled = 0;
    reg [31:0] stalled_address;
    reg [63:0] stalled_data;
    reg stalled_write;

    fir128 #(.TAPS_PER_CLOCK(TAPS_PER_CLOCK)) dut (
        .clk(clk), .reset(reset), .avs_address(csr_address), .avs_read(1'b1),
        .avs_write(csr_write), .avs_writedata(csr_wdata), .avs_readdata(csr_rdata),
        .avm_address(address), .avm_burstcount(burstcount), .avm_read(rd),
        .avm_write(wr), .avm_writedata(write_data), .avm_waitrequest(wait_request),
        .avm_readdata(read_data), .avm_readdatavalid(read_valid),
        .avm_writeresponsevalid(write_valid), .avm_response(2'b00), .irq(irq)
    );

    always @(posedge clk) begin
        cycle <= cycle + 1;
        read_valid <= 0;
        write_valid <= 0;
        if (!reset) begin
            if (rd || (!response_is_write && (delay_count != 0 || read_valid)))
                read_clocks <= read_clocks + 1;
            if (wr || (response_is_write && (delay_count != 0 || write_valid)))
                write_clocks <= write_clocks + 1;
            if (rd && wr) $fatal(1, "Concurrent read and write");
            if (stalled && (address !== stalled_address ||
                (stalled_write && (!wr || write_data !== stalled_data)) ||
                (!stalled_write && !rd))) $fatal(1, "Command changed under backpressure");
            stalled <= (rd || wr) && wait_request;
            stalled_write <= wr;
            stalled_address <= address;
            stalled_data <= write_data;
            if ((rd || wr) && !wait_request) begin
                if (burstcount != 1 || delay_count != 0) $fatal(1, "Unexpected command");
                delay_count <= 6;
                response_is_write <= wr;
                if (rd) begin
                    if (reads != retired || reads >= 4096 ||
                        address !== 32'h3f800000 + 8 * reads)
                        $fatal(1, "Read address/order %h at beat %d", address, reads);
                    for (k = 0; k < 4; k = k + 1)
                        read_data[16*k +: 16] <= input_pcm[4*reads + k];
                    reads <= reads + 1;
                end else begin
                    if (writes + 1 != reads || writes >= 4096 ||
                        address !== 32'h3fc00000 + 8 * writes)
                        $fatal(1, "Write address/order %h at beat %d", address, writes);
                    for (k = 0; k < 4; k = k + 1)
                        if (write_data[16*k +: 16] !== expected[4*writes + k])
                            $fatal(1, "Sample %d: actual=%h expected=%h", 4*writes + k,
                                   write_data[16*k +: 16], expected[4*writes + k]);
                    writes <= writes + 1;
                end
            end else if (delay_count > 0) begin
                delay_count <= delay_count - 1;
                if (delay_count == 1) begin
                    read_valid <= !response_is_write;
                    write_valid <= response_is_write;
                end
            end
            if (write_valid) retired <= retired + 1;
        end
    end

    task write_csr(input [3:0] index, input [31:0] value);
        @(negedge clk);
        csr_address = index;
        csr_wdata = value;
        csr_write = 1;
        @(negedge clk);
        csr_write = 0;
    endtask

    task read_csr(input [3:0] index, output [31:0] value);
        csr_address = index;
        #1;
        value = csr_rdata;
    endtask

    initial begin
        $readmemh("build/input.hex", input_pcm);
        $readmemh("build/expected.hex", expected);
        repeat (3) @(negedge clk);
        reset = 0;
        csr_address = 11;
        #1;
        if (csr_rdata !== 32'h46495231) $fatal(1, "Wrong ID");
        if (dut.quantize(48'sd16384) !== 16'h0001 ||
            dut.quantize(-48'sd16384) !== 16'hffff ||
            dut.quantize(-48'sd16383) !== 16'h0000 ||
            dut.quantize(48'sd1073741824) !== 16'h7fff ||
            dut.quantize(-48'sd1073774592) !== 16'h8000)
            $fatal(1, "Quantization vectors failed");
        write_csr(2, 1);
        write_csr(4, 1);
        csr_address = 5;
        #1;
        if (csr_rdata !== 4 || !irq || rd || wr) $fatal(1, "Invalid config accepted");
        write_csr(3, 1);
        if (irq) $fatal(1, "IRQ acknowledge failed");
        write_csr(6, 32'h3f800000);
        write_csr(7, 16384);
        write_csr(8, 32'h3fc00000);
        write_csr(4, 1);
        start_cycle = cycle;
        wait (irq);
        @(negedge clk);
        elapsed = cycle - start_cycle;
        csr_address = 5;
        #1;
        if (csr_rdata !== 2 || reads != 4096 || writes != 4096 || retired != 4096)
            $fatal(1, "Completion before final write response");
        read_csr(9, clear_count);
        read_csr(10, read_count);
        read_csr(12, mac_count);
        read_csr(13, write_count);
        read_csr(14, pack_count);
        read_csr(15, lanes);
        if (lanes != TAPS_PER_CLOCK || clear_count != 128 ||
            mac_count != 16384 * (128 / TAPS_PER_CLOCK + (TAPS_PER_CLOCK == 4 ? 1 : 0)) ||
            pack_count != 32768 || read_count != read_clocks || write_count != write_clocks ||
            clear_count + read_count + mac_count + write_count + pack_count != elapsed)
            $fatal(1, "Counters do not match bus and job observations");
        $display("RTL PASS: all 16384 samples, DDR bounds/order, backpressure, IRQ and counters");
        $display("Taps per clock     %0d", lanes);
        $display("Clear history      %0d cycles", clear_count);
        $display("DDR read and wait  %0d cycles", read_count);
        $display("MAC and drain      %0d cycles", mac_count);
        $display("Load and pack      %0d cycles", pack_count);
        $display("DDR write and wait %0d cycles", write_count);
        $display("Accelerator total  %0d cycles", elapsed);
        $finish;
    end

    initial begin
        repeat (2400000) @(posedge clk);
        $fatal(1, "Timeout");
    end
endmodule
