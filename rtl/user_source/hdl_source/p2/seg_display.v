//------------------------------------------------------------------------------
// seg_display.v -- 4-digit common-cathode 7-segment display driver
//
// Board wiring (vendor `keyboard.adc`): DigitronCS_Out[3:0] -> SEG_SEL[3:0]
// (digit select, ACTIVE LOW), Digitron_Out[7:0] -> SEG_LED[7:0] (segments,
// ACTIVE HIGH, bit0 = a ... bit6 = g, bit7 = dp).
//
// It shows the active P5 filter preset (0..5) on every digit, so the number is
// readable regardless of which end of the display is the leftmost one.  Refresh
// is ~500 Hz (one digit every 0.5 ms), well above visible flicker.
//------------------------------------------------------------------------------
module seg_display(
        input  wire        clk,          // pixel clock 25.175 MHz
        input  wire        rst,          // active high
        input  wire [3:0]  num,          // value to show, 0..15 (hex)
        // firmware take-over channel (P6): when ext_en is high the display
        // shows the 16-bit value the M0 wrote to AUDIO_DISP instead of the
        // preset number.  This is the debugging console now that UART is dead.
        input  wire        ext_en,
        input  wire [15:0] ext_val,
        output reg  [7:0]  seg,          // SEG_LED, active high
        output reg  [3:0]  sel           // SEG_SEL, active low (one digit on)
);

    localparam SCAN = 14'd12500;         // ~0.5 ms per digit at 25.175 MHz

    reg [13:0] div;
    reg [1:0]  dig;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            div <= 14'd0;
            dig <= 2'd0;
        end else if (div == (SCAN - 1'b1)) begin
            div <= 14'd0;
            dig <= dig + 1'b1;           // free running 0..3
        end else begin
            div <= div + 1'b1;
        end
    end

    // segment font, bit0=a bit1=b bit2=c bit3=d bit4=e bit5=f bit6=g bit7=dp
    function [7:0] font;
        input [3:0] v;
        begin
            case (v)
                4'h0: font = 8'h3F;
                4'h1: font = 8'h06;
                4'h2: font = 8'h5B;
                4'h3: font = 8'h4F;
                4'h4: font = 8'h66;
                4'h5: font = 8'h6D;
                4'h6: font = 8'h7D;
                4'h7: font = 8'h07;
                4'h8: font = 8'h7F;
                4'h9: font = 8'h6F;
                4'hA: font = 8'h77;
                4'hB: font = 8'h7C;
                4'hC: font = 8'h39;
                4'hD: font = 8'h5E;
                4'hE: font = 8'h79;
                default: font = 8'h71;   // F
            endcase
        end
    endfunction

    // register the outputs so the segments and the digit select change on the
    // same edge (a combinational mux would glitch a digit's worth of light)
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sel <= 4'b1111;              // all digits off while in reset
            seg <= 8'h00;
        end else begin
            if (ext_en) begin
                // Nibble order was measured on the board: sel = 0111 is the
                // LEFTMOST digit and sel = 1110 the rightmost one, so the most
                // significant nibble goes to 0111 (otherwise the number reads
                // backwards: 0xAC3B showed up as "B3CA").
                case (dig)
                    2'd0: begin sel <= 4'b1110; seg <= font(ext_val[3:0]);   end
                    2'd1: begin sel <= 4'b1101; seg <= font(ext_val[7:4]);   end
                    2'd2: begin sel <= 4'b1011; seg <= font(ext_val[11:8]);  end
                    default: begin sel <= 4'b0111; seg <= font(ext_val[15:12]); end
                endcase
            end else begin
                case (dig)
                    2'd0: begin sel <= 4'b1110; seg <= font(num); end
                    2'd1: begin sel <= 4'b1101; seg <= font(num); end
                    2'd2: begin sel <= 4'b1011; seg <= font(num); end
                    default: begin sel <= 4'b0111; seg <= font(num); end
                endcase
            end
        end
    end

endmodule
