//------------------------------------------------------------------------------
// isp_filter.v -- P5 image filter: 3x3 colour matrix + per-channel offset
//
// Runs in the pixel clock domain, one pixel per clock (25.175 MHz), placed
// between the SDRAM readout (video_delay) and the HDMI transmitter.  hs/vs/de
// are delayed by the same single cycle as the data, so the sync stays aligned
// with the pixel stream.
//
// Math:  out = clamp(((c0*R + c1*G + c2*B) + offset) >> 7)
// Coefficients are Q1.7 (128 = 1.0) 9-bit signed, offsets are Q1.7 too, i.e.
// applied before the shift (a pixel-unit offset k is k*128 here).
// The six presets are the ones the plan calls for:
//   0 original   identity
//   1 grayscale  ITU-R BT.601 luma (0.299 / 0.587 / 0.114)
//   2 sepia      classic 0.393/0.769/0.189 style matrix
//   3 cold       R x0.86, G x0.96, B x1.14
//   4 contrast   (v - 128) x 1.5 + 128
//   5 invert     255 - v
//------------------------------------------------------------------------------
module isp_filter(
        input  wire        clk,
        input  wire        rst,             // active high
        input  wire [2:0]  mode,            // 0..5, values >5 behave as 0
        input  wire [23:0] px_i,            // {R[23:16], G[15:8], B[7:0]}
        input  wire        de_i,
        input  wire        hs_i,
        input  wire        vs_i,
        output reg  [23:0] px_o,
        output reg         de_o,
        output reg         hs_o,
        output reg         vs_o
);

    // ---- coefficient set for the selected preset -----------------------------
    reg signed [8:0] c_rr, c_rg, c_rb;
    reg signed [8:0] c_gr, c_gg, c_gb;
    reg signed [8:0] c_br, c_bg, c_bb;
    // offsets are applied BEFORE the >>7, so they live in the same Q1.7 scale as
    // the coefficients: a pixel-unit offset k is k*128 here.  That needs 18 bits
    // (invert uses 255*128 = 32640) -- a 10-bit reg would silently wrap and turn
    // the invert preset into a black screen.
    reg signed [17:0] off_r, off_g, off_b;

    always @(*) begin
        // defaults: identity
        c_rr = 9'sd128; c_rg = 9'sd0;   c_rb = 9'sd0;
        c_gr = 9'sd0;   c_gg = 9'sd128; c_gb = 9'sd0;
        c_br = 9'sd0;   c_bg = 9'sd0;   c_bb = 9'sd128;
        off_r = 18'sd0; off_g = 18'sd0; off_b = 18'sd0;

        case (mode)
            3'd1: begin                                   // grayscale (luma)
                c_rr = 9'sd38; c_rg = 9'sd75; c_rb = 9'sd15;
                c_gr = 9'sd38; c_gg = 9'sd75; c_gb = 9'sd15;
                c_br = 9'sd38; c_bg = 9'sd75; c_bb = 9'sd15;
            end
            3'd2: begin                                   // sepia
                c_rr = 9'sd50;  c_rg = 9'sd98;  c_rb = 9'sd24;
                c_gr = 9'sd45;  c_gg = 9'sd88;  c_gb = 9'sd22;
                c_br = 9'sd35;  c_bg = 9'sd68;  c_bb = 9'sd17;
            end
            3'd3: begin                                   // cold tint
                c_rr = 9'sd110;
                c_gg = 9'sd123;
                c_bb = 9'sd146;
            end
            3'd4: begin                                   // high contrast x1.5
                c_rr = 9'sd192;
                c_gg = 9'sd192;
                c_bb = 9'sd192;
                // (192*v - 8192) >> 7 = 1.5*v - 64, i.e. (v-128)*1.5 + 128
                off_r = -18'sd8192; off_g = -18'sd8192; off_b = -18'sd8192;
            end
            3'd5: begin                                   // invert
                c_rr = -9'sd128;
                c_gg = -9'sd128;
                c_bb = -9'sd128;
                // (32640 - 128*v) >> 7 = 255 - v
                off_r = 18'sd32640; off_g = 18'sd32640; off_b = 18'sd32640;
            end
            default: ;                                    // 0 and >5: original
        endcase
    end

    // ---- datapath ------------------------------------------------------------
    wire signed [8:0] r = $signed({1'b0, px_i[23:16]});
    wire signed [8:0] g = $signed({1'b0, px_i[15:8]});
    wire signed [8:0] b = $signed({1'b0, px_i[7:0]});

    wire signed [17:0] p_rr = c_rr * r;
    wire signed [17:0] p_rg = c_rg * g;
    wire signed [17:0] p_rb = c_rb * b;
    wire signed [17:0] p_gr = c_gr * r;
    wire signed [17:0] p_gg = c_gg * g;
    wire signed [17:0] p_gb = c_gb * b;
    wire signed [17:0] p_br = c_br * r;
    wire signed [17:0] p_bg = c_bg * g;
    wire signed [17:0] p_bb = c_bb * b;

    wire signed [19:0] sum_r = p_rr + p_rg + p_rb + off_r;
    wire signed [19:0] sum_g = p_gr + p_gg + p_gb + off_g;
    wire signed [19:0] sum_b = p_br + p_bg + p_bb + off_b;

    function [7:0] clip;                                  // >>7 then clamp to 0..255
        input signed [19:0] v;
        reg   signed [12:0] s;
        begin
            s = v >>> 7;
            if (s < 0)
                clip = 8'd0;
            else if (s > 13'sd255)
                clip = 8'd255;
            else
                clip = s[7:0];
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            px_o <= 24'd0;
            de_o <= 1'b0;
            hs_o <= 1'b0;
            vs_o <= 1'b0;
        end else begin
            px_o <= {clip(sum_r), clip(sum_g), clip(sum_b)};
            de_o <= de_i;
            hs_o <= hs_i;
            vs_o <= vs_i;
        end
    end

endmodule
