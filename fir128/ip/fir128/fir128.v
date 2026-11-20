module fir128 #(parameter TAPS_PER_CLOCK = 1) (
    input wire clk, reset,
    input wire [3:0] avs_address,
    input wire avs_read, avs_write,
    input wire [31:0] avs_writedata,
    output reg [31:0] avs_readdata,
    output wire [31:0] avm_address,
    output wire [4:0] avm_burstcount,
    output wire avm_read, avm_write,
    output wire [63:0] avm_writedata,
    input wire avm_waitrequest,
    input wire [63:0] avm_readdata,
    input wire avm_readdatavalid, avm_writeresponsevalid,
    input wire [1:0] avm_response,
    output wire irq
);
    localparam [3:0] IDLE=0, CLEAR=1, READ=2, READ_WAIT=3,
                     LOAD=4, MAC=5, PACK=6, WRITE=7, WRITE_WAIT=8, MAC_DRAIN=9, MAC_FINAL=10;
    localparam [6:0] TAP_STEP = TAPS_PER_CLOCK >= 8 ? TAPS_PER_CLOCK / 2 : TAPS_PER_CLOCK;
    localparam [6:0] LAST_TAP = (TAPS_PER_CLOCK >= 8 ? 64 : 128) - TAP_STEP;
    localparam [31:0] INPUT_BASE=32'h3f800000, OUTPUT_BASE=32'h3fc00000;
    localparam [31:0] SAMPLE_COUNT=16384, ID_VALUE=32'h46495231;

    reg [3:0] state;
    reg done, fault, irq_mask, edge_cap;
    reg [31:0] input_base, output_base, count;
    reg [11:0] beat;
    reg [1:0] lane;
    reg [6:0] head, tap;
    reg [63:0] input_word, output_word;
    reg signed [15:0] coefficients [0:127];
    reg signed [15:0] history [0:127];
    reg signed [47:0] sum;
    reg [31:0] clear_cycles, read_cycles, mac_cycles, write_cycles, pack_cycles;
    wire signed [47:0] mac_addend;
    generate
        if (TAPS_PER_CLOCK == 1) begin : serial_mac
            wire [6:0] history_address = head - tap;
            wire signed [31:0] product = history[history_address] * coefficients[tap];
            assign mac_addend = {{16{product[31]}}, product};
        end else begin : parallel_mac
            wire signed [35:0] reduction [1:2*TAP_STEP-1];
            genvar index;
            for (index = 0; index < TAP_STEP; index = index + 1) begin : channels
                wire [6:0] tap_index = tap + index;
                wire [6:0] history_address = head - tap_index;
                reg signed [32:0] product_reg;
                if (TAPS_PER_CLOCK >= 8) begin : symmetric
                    wire [6:0] mirror_address = head - (7'd127 - tap_index);
                    wire signed [15:0] first = history[history_address];
                    wire signed [15:0] second = history[mirror_address];
                    reg signed [16:0] pair_sum;
                    reg signed [15:0] weight;
                    always @(posedge clk) begin
                        if (state == LOAD) begin
                            pair_sum <= 0;
                            weight <= 0;
                            product_reg <= 0;
                        end else if (state == MAC || state == MAC_DRAIN) begin
                            pair_sum <= {first[15], first} + {second[15], second};
                            weight <= coefficients[tap_index];
                            product_reg <= pair_sum * weight;
                        end
                    end
                end else begin : direct
                    always @(posedge clk) begin
                        if (state == LOAD) product_reg <= 0;
                        else if (state == MAC)
                            product_reg <= history[history_address] * coefficients[tap_index];
                    end
                end
                assign reduction[TAP_STEP + index] = {{3{product_reg[32]}}, product_reg};
            end
            for (index = 1; index < TAP_STEP; index = index + 1) begin : add_tree
                assign reduction[index] = reduction[2*index] + reduction[2*index + 1];
            end
            assign mac_addend = {{12{reduction[1][35]}}, reduction[1]};
        end
    endgenerate
    wire busy = state != IDLE;
    wire valid_config = input_base == INPUT_BASE &&
                        output_base == OUTPUT_BASE && count == SAMPLE_COUNT;

    initial $readmemh("ip/fir128/coeff.hex", coefficients);

    function [15:0] quantize;
        input signed [47:0] total;
        reg [47:0] magnitude, rounded;
        begin
            magnitude = total[47] ? -total : total;
            rounded = (magnitude + 48'd16384) >> 15;
            if (total[47])
                quantize = rounded >= 48'd32768 ? 16'h8000 : -rounded[15:0];
            else
                quantize = rounded > 48'd32767 ? 16'h7fff : rounded[15:0];
        end
    endfunction

    assign irq = irq_mask & edge_cap;
    assign avm_read = state == READ;
    assign avm_write = state == WRITE;
    assign avm_address = (avm_write ? output_base : input_base) + {17'd0, beat, 3'b0};
    assign avm_writedata = output_word;
    assign avm_burstcount = 5'd1;

    wire start = state == IDLE && avs_write && avs_address == 4'd4 && avs_writedata[0];

    // Count all busy clocks by state, including cycles waiting for a bus response.
    always @(posedge clk) begin
        if (reset || start) begin
            clear_cycles <= 0;
            read_cycles <= 0;
            mac_cycles <= 0;
            write_cycles <= 0;
            pack_cycles <= 0;
        end else begin
            case (state)
                CLEAR: clear_cycles <= clear_cycles + 1'b1;
                READ, READ_WAIT: read_cycles <= read_cycles + 1'b1;
                MAC, MAC_DRAIN, MAC_FINAL: mac_cycles <= mac_cycles + 1'b1;
                WRITE, WRITE_WAIT: write_cycles <= write_cycles + 1'b1;
                LOAD, PACK: pack_cycles <= pack_cycles + 1'b1;
                default: ;
            endcase
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            done <= 0;
            fault <= 0;
            irq_mask <= 0;
            edge_cap <= 0;
            input_base <= 0;
            output_base <= 0;
            count <= 0;
        end else begin
            if (avs_write) begin
                case (avs_address)
                    4'd2: irq_mask <= avs_writedata[0];
                    4'd3: if (avs_writedata[0]) edge_cap <= 0;
                    4'd6: if (!busy) input_base <= avs_writedata;
                    4'd7: if (!busy) count <= avs_writedata;
                    4'd8: if (!busy) output_base <= avs_writedata;
                    default: ;
                endcase
            end
            case (state)
                IDLE: if (start) begin
                    done <= 0;
                    fault <= !valid_config;
                    edge_cap <= !valid_config;
                    if (valid_config) begin
                        beat <= 0;
                        lane <= 0;
                        head <= 0;
                        tap <= 0;
                        state <= CLEAR;
                    end
                end
                CLEAR: begin
                    history[tap] <= 0;
                    tap <= tap + 1'b1;
                    if (tap == 127) state <= READ;
                end
                READ, READ_WAIT: begin
                    if (state == READ && !avm_waitrequest) state <= READ_WAIT;
                    if (avm_readdatavalid) begin
                        if (avm_response != 0) begin
                            state <= IDLE;
                            fault <= 1;
                            edge_cap <= 1;
                        end else begin
                            input_word <= avm_readdata;
                            state <= LOAD;
                        end
                    end
                end
                LOAD: begin
                    history[head] <= input_word[15:0];
                    input_word <= input_word >> 16;
                    sum <= 0;
                    tap <= 0;
                    state <= MAC;
                end
                MAC: begin
                    sum <= sum + mac_addend;
                    tap <= tap + TAP_STEP;
                    if (tap == LAST_TAP)
                        state <= TAPS_PER_CLOCK == 1 ? PACK : MAC_DRAIN;
                end
                MAC_DRAIN: begin
                    sum <= sum + mac_addend;
                    state <= TAPS_PER_CLOCK >= 8 ? MAC_FINAL : PACK;
                end
                MAC_FINAL: begin
                    sum <= sum + mac_addend;
                    state <= PACK;
                end
                PACK: begin
                    output_word <= {quantize(sum), output_word[63:16]};
                    head <= head + 1'b1;
                    lane <= lane + 1'b1;
                    state <= lane == 3 ? WRITE : LOAD;
                end
                WRITE, WRITE_WAIT: begin
                    if (state == WRITE && !avm_waitrequest) state <= WRITE_WAIT;
                    // Retire each write on the downstream response, not command acceptance.
                    if (avm_writeresponsevalid) begin
                        if (avm_response != 0 || beat == 4095) begin
                            state <= IDLE;
                            fault <= avm_response != 0;
                            done <= avm_response == 0;
                            edge_cap <= 1;
                        end else begin
                            beat <= beat + 1'b1;
                            state <= READ;
                        end
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end

    always @* begin
        case (avs_address)
            4'd0: avs_readdata = {31'd0, done};
            4'd2: avs_readdata = {31'd0, irq_mask};
            4'd3: avs_readdata = {31'd0, edge_cap};
            4'd5: avs_readdata = {29'd0, fault, done, busy};
            4'd6: avs_readdata = input_base;
            4'd7: avs_readdata = count;
            4'd8: avs_readdata = output_base;
            4'd9: avs_readdata = clear_cycles;
            4'd10: avs_readdata = read_cycles;
            4'd11: avs_readdata = ID_VALUE;
            4'd12: avs_readdata = mac_cycles;
            4'd13: avs_readdata = write_cycles;
            4'd14: avs_readdata = pack_cycles;
            4'd15: avs_readdata = TAPS_PER_CLOCK;
            default: avs_readdata = 0;
        endcase
    end
endmodule
