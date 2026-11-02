//==============================================================================
// mic_adc.v  --  SPI master for the on board microphone ADC (P6)
//
// Pins (from the vendor AudioADC example's .adc and the baseboard schematic):
//   ADC_CS = J6, ADC_MISO = K5, ADC_SCK = H3, ADC_RSTN = G6
//
// The vendor frame (spi_rx.v / v1.v in work\M0_Borad\...\1_AudioADC_max100k):
//   adc_rst_n released after 2^15 refclocks (~0.65ms at 50MHz)
//   data frames start only after 2^20 refclocks (~21ms) -- the ADC needs time
//   CS low for 30 SCK periods (conversion) -> 16 bits shifted out MSB first,
//   sampled on the rising edge of SCK -> CS high, 50 SCK periods per frame.
//   SCK = 200MHz/40 = 5MHz, so 5M/50 = 100kSPS.
//
// Here the same sequence runs in the 50MHz domain with plain counters:
//   300 clocks (6.0us)  CS low, SCK low        <- conversion time (30 SCK)
//   160 clocks          16 bits, 10 clocks each <- 5MHz SCK
//    40 clocks         CS high, SCK low        <- frame gap (50 total)
//   = 500 clocks = 10.0us = 100kSPS
//
// MISO is sampled just before SCK rises (sub == 4), which is exactly the point
// the vendor samples at: their sck IS clk_baud, so sampling on the clk_baud
// posedge captures the bit the ADC presented on the previous falling edge.
//
// mic_edges counts every MISO transition seen: if it stays 0 while frames are
// being clocked, the ADC is not answering (wrong pin, dead bus, bad frame) --
// that is the decisive bring-up measurement, readable at +0x04.
//==============================================================================
`timescale 1ns/1ps

module mic_adc (
    input  wire        clk,             // 50 MHz
    input  wire        arst,
    output reg         adc_cs_n,
    output reg         adc_sck,
    output reg         adc_rst_n,
    input  wire        adc_miso,
    output reg  [15:0] mic_data,        // raw 16-bit frame, MSB first
    output reg         mic_valid,       // one clock pulse per delivered frame
    output reg  [15:0] mic_edges,       // MISO transitions seen (saturates)
    output reg  [15:0] mic_frames,      // completed frames (wraps)
    output reg  [15:0] mic_peak,        // max sample in the last 1s window
    output reg  [15:0] mic_trough       // min sample in the last 1s window
);

    localparam S_WAIT = 2'd0;
    localparam S_BITS = 2'd1;
    localparam S_HOLD = 2'd2;

    reg [1:0]  state;
    reg [9:0]  wcnt;                    // 0..299 conversion wait
    reg [5:0]  hcnt;                    // 0..39 frame gap
    reg [3:0]  sub;                     // 0..9 inside one SCK period
    reg [3:0]  bi;                      // 0..15 bit index
    reg [15:0] dat;

    reg [20:0] rst_cnt;                 // 2^20 = 21ms settling, like the vendor
    reg        miso_q;

    // 1s window min/max: the spread of the raw ADC frames is the one number
    // that says whether the microphone path carries real signal (a quiet room
    // gives a few hundred counts, speech thousands) or nothing at all.
    reg [24:0] win_cnt;
    reg [15:0] win_max, win_min;

    always @(posedge clk or posedge arst) begin
        if (arst) begin
            state      <= S_WAIT;
            wcnt       <= 10'd0;
            hcnt       <= 6'd0;
            sub        <= 4'd0;
            bi         <= 4'd0;
            dat        <= 16'd0;
            rst_cnt    <= 21'd0;
            adc_cs_n   <= 1'b1;
            adc_sck    <= 1'b0;
            adc_rst_n  <= 1'b0;
            mic_data   <= 16'd0;
            mic_valid  <= 1'b0;
            mic_edges  <= 16'd0;
            mic_frames <= 16'd0;
            miso_q     <= 1'b0;
            win_cnt    <= 25'd0;
            win_max    <= 16'd0;
            win_min    <= 16'hFFFF;
            mic_peak   <= 16'd0;
            mic_trough <= 16'hFFFF;
        end else begin
            mic_valid <= 1'b0;

            // 1s min/max window over the delivered frames
            if (mic_valid) begin
                if (mic_data > win_max)
                    win_max <= mic_data;
                if (mic_data < win_min)
                    win_min <= mic_data;
            end
            if (win_cnt == 25'd49_999_999) begin
                win_cnt    <= 25'd0;
                mic_peak   <= win_max;
                mic_trough <= win_min;
                win_max    <= 16'd0;
                win_min    <= 16'hFFFF;
            end else begin
                win_cnt <= win_cnt + 25'd1;
            end

            // MISO activity counter: any edge at all proves the ADC is alive.
            miso_q <= adc_miso;
            if (adc_miso != miso_q && mic_edges != 16'hFFFF)
                mic_edges <= mic_edges + 16'd1;

            // ADC reset: held low for 0.65ms, then released for good.
            if (rst_cnt != 21'h1FFFFF)
                rst_cnt <= rst_cnt + 21'd1;
            adc_rst_n <= (rst_cnt > 21'd32768);

            // Do not clock the ADC until it has settled (21ms), as the vendor.
            if (rst_cnt < 21'h100000) begin
                adc_cs_n <= 1'b1;
                adc_sck  <= 1'b0;
            end else begin
                case (state)
                    S_WAIT: begin
                        adc_cs_n <= 1'b0;
                        adc_sck  <= 1'b0;
                        if (wcnt == 10'd299) begin
                            wcnt  <= 10'd0;
                            sub   <= 4'd0;
                            bi    <= 4'd0;
                            state <= S_BITS;
                        end else begin
                            wcnt <= wcnt + 10'd1;
                        end
                    end

                    S_BITS: begin
                        adc_cs_n <= 1'b0;
                        adc_sck  <= (sub >= 4'd5);
                        // Sample just before SCK rises: the ADC changed the bit
                        // on the previous falling edge, so this is the setup
                        // time the vendor gets too.
                        if (sub == 4'd4)
                            dat[15 - bi] <= adc_miso;
                        if (sub == 4'd9) begin
                            sub <= 4'd0;
                            if (bi == 4'd15) begin
                                state <= S_HOLD;
                                hcnt  <= 6'd0;
                            end else begin
                                bi <= bi + 4'd1;
                            end
                        end else begin
                            sub <= sub + 4'd1;
                        end
                    end

                    default: begin      // S_HOLD
                        adc_sck  <= 1'b0;
                        adc_cs_n <= 1'b1;
                        if (hcnt == 6'd39) begin
                            state      <= S_WAIT;
                            wcnt       <= 10'd0;
                            mic_frames <= mic_frames + 16'd1;
                            // Hand the analyser every second frame (50kSPS), so
                            // its octave corners - tuned for the 44.1kHz music
                            // path - land within an octave of the right place
                            // instead of 2.27x too high.
                            if (mic_frames[0] == 1'b0) begin
                                mic_data  <= dat;
                                mic_valid <= 1'b1;
                            end
                        end else begin
                            hcnt <= hcnt + 6'd1;
                        end
                    end
                endcase
            end
        end
    end

endmodule
