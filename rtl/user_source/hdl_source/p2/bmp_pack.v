//------------------------------------------------------------------------------
// bmp_pack.v -- BMP byte-stream to 32bit pixel packer for P2
//
// Adapted from lab_ex4_tf bmp_read.v packing logic. Counts every byte passed
// by (stream_en & byte_valid) as a file byte index; assembles 24bit pixels
// for bytes in [pixel_offset, file_len) and emits {R,G,B,0} words to the
// SDRAM write FIFO. The counter runs continuously across sectors, so the
// M0 only issues per-sector STREAM commands in cluster-chain order.
//
// BMP 24bit layout: B,G,R byte order, rows bottom-up (handled by SDRAM
// write-side v-flip). 640x480x3 = 921600 pixel bytes -> 307200 words.
//------------------------------------------------------------------------------
module bmp_pack (
    input  wire        clk,
    input  wire        rst,          // synchronous, active high (SD domain)
    input  wire        clear,        // pack session reset (byte_cnt=0)
    input  wire        stream_en,    // gate from sd_ctrl (stream transfer active)
    input  wire        byte_valid,   // 1 cycle per sector byte
    input  wire [7:0]  byte_in,
    input  wire [31:0] pixel_offset, // file byte where pixel data starts (54)
    input  wire [31:0] file_len,     // total file bytes (pack window end)
    output reg         we,           // write FIFO push
    output reg  [31:0] wdata         // {R,G,B,0}
);

    reg [31:0] byte_cnt;
    reg [1:0]  byte_idx;               // only advances inside the window
    reg [7:0]  b0, b1;

    wire       byte_step = stream_en & byte_valid;
    wire       in_window = (byte_cnt >= pixel_offset) && (byte_cnt < file_len);

    always @(posedge clk) begin
        if (rst) begin
            byte_cnt <= 32'd0;
            byte_idx <= 2'd0;
            b0       <= 8'd0;
            b1       <= 8'd0;
            we       <= 1'b0;
            wdata    <= 32'd0;
        end else begin
            we <= 1'b0;
            if (clear) begin
                byte_cnt <= 32'd0;
                byte_idx <= 2'd0;
            end else if (byte_step) begin
                if (in_window) begin
                    case (byte_idx)
                        2'd0: begin b0 <= byte_in; byte_idx <= 2'd1; end
                        2'd1: begin b1 <= byte_in; byte_idx <= 2'd2; end
                        2'd2: begin
                            // BMP order B,G,R -> first byte is B
                            we    <= 1'b1;
                            wdata <= {byte_in, b1, b0, 8'h00};
                            byte_idx <= 2'd0;
                        end
                        default: byte_idx <= 2'd0;
                    endcase
                end
                byte_cnt <= byte_cnt + 32'd1;
            end
        end
    end

endmodule
