//==============================================================================
// spectrum_bank.v  --  8 band octave-spaced spectrum analyser for the bar overlay
//
// Deliberately NOT an FFT: a radix-2 FFT needs twiddle ROM, bit reversal, a data
// RAM and a butterfly datapath, and with no simulator on this project one
// addressing mistake there costs many build/flash cycles.  This is a classic
// analogue-style filter bank instead:
//
//   * a cascade of 8 TWO-pole low passes, each stage fed by the previous one.
//     One pole was not selective enough: a 1 kHz tone still stood 15dB tall in
//     eight neighbouring bands, so eight bars lit up.  Two poles give 12dB/oct
//     skirts and keep a tone to two or three bars;
//   * octave spacing, alpha = 1.5 * 2^-(n+1) with n = 0..7, which puts the
//     corners at 10.5k, 5.3k, 2.6k, 1.3k, 660, 330, 165, 82 Hz - one equaliser
//     octave per bar.  (The 1.5 variant is the faster pole, i.e. the higher
//     corner, so it must not be paired with a slower 1.0 pole after it or the
//     corners stop being monotonic and the band differences go negative.)
//   * band g = lp2[g] - lp2[g+1], i.e. the energy between two neighbouring
//     corners - a true octave band, not a DFT bin;
//   * anything more than 12dB below the loudest band is gated to zero, so the
//     display shows the shape of the spectrum instead of a flat hump;
//   * every pole is a literal shift plus one small add.  No multipliers, no
//     variable shifts, no arrays indexed by a variable: fully unrolled.
//
// Eight bands rather than sixteen is deliberate: this lives in the 50MHz audio
// domain next to a 75%-full EG4S20, and the 16 band two-pole version could not
// be routed (PHY-8102, single site conflict).  Eight fat bars also read better
// on a 640x480 overlay.
//
// TIMING: the log/height maths (priority encoder + mantissa mux + multiply) is
// far too slow for one 20ns clock, so it runs as a 5 phase pipeline; samp_tick
// restarts the phase counter and there are 1134 clocks per audio sample.
//   ph0 magnitude + envelope, ph1 leading one, ph2 mantissa + peak register,
//   ph3 height, ph4 gate + publish.
//==============================================================================
`timescale 1ns/1ps

module spectrum_bank (
    input  wire               clk,          // 50 MHz
    input  wire               arst,         // active high
    input  wire               samp_tick,    // one clock per audio sample
    input  wire signed [15:0] pcm,          // audio after the shelf, pre volume
    output reg  [127:0]       sp_h          // 16 x 8 bit; only bytes 0..7 used
);

    localparam N = 8;

    // DC blocker: the FIFO freezes pcm at the last sample when nothing plays,
    // and a constant would sit in the lowest bands forever.
    reg  signed [17:0] dc_lp;
    wire signed [17:0] xin_dc = {{2{pcm[15]}}, pcm} - dc_lp;

    // One register between the audio source and the cascade.  Without it the
    // path pcm -> (tone ROM, amp multiply, shelf) -> cascade -> first pole ran to
    // 24.5ns: the analyser is fed by pcm_src, which is the far end of a 64 entry
    // sine ROM and a multiplier, so everything downstream of pcm must start from
    // a register.
    reg  signed [17:0] xin_r;

    reg  signed [17:0] lp  [0:N-1];
    reg  signed [17:0] lp2 [0:N-1];

    //--------------------------------------------------------------------------
    // two pole cascade, alpha = 1.5 * 2^-(sh) with sh = 2..9 (octave corners).
    // Each stage only reads the PREVIOUS stage's registers, so no long
    // combinational chain is created - just two adders per stage.
    //--------------------------------------------------------------------------
    wire signed [17:0] lp_nxt  [0:N-1];
    wire signed [17:0] lp2_nxt [0:N-1];

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : st
            wire signed [17:0] xin = (g == 0) ? xin_r : lp2[g-1];

            wire signed [18:0] d1  = xin - lp[g];
            wire signed [18:0] s1  = d1 >>> (g + 2);          // 0.25 .. 0.002
            wire signed [18:0] a1  = s1 + (s1 >>> 1);         // x 1.5
            wire signed [17:0] p1  = lp[g] + a1[17:0];

            wire signed [18:0] d2  = p1 - lp2[g];
            wire signed [18:0] s2  = d2 >>> (g + 2);
            wire signed [18:0] a2  = s2 + (s2 >>> 1);

            assign lp_nxt[g]  = p1;
            assign lp2_nxt[g] = lp2[g] + a2[17:0];
        end
    endgenerate

    //--------------------------------------------------------------------------
    // band magnitudes of the NEXT sample, sampled into mag on samp_tick
    //--------------------------------------------------------------------------
    wire [17:0] mag_n [0:N-1];

    generate
        for (g = 0; g < N; g = g + 1) begin : bdn
            wire signed [18:0] diff = (g == N-1) ? {lp2[N-1][17], lp2[N-1]}
                                                 : ({lp2[g][17], lp2[g]} - {lp2[g+1][17], lp2[g+1]});
            assign mag_n[g] = diff[18] ? (~diff[17:0] + 18'd1) : diff[17:0];
        end
    endgenerate

    reg [17:0] mag  [0:N-1];
    reg [17:0] env  [0:N-1];
    reg [17:0] mmax;

    //--------------------------------------------------------------------------
    // peak across all bands (3 levels of 2:1), registered into mmax in ph1
    //--------------------------------------------------------------------------
    wire [17:0] mx0 [0:3];
    wire [17:0] mx1 [0:1];
    wire [17:0] mag_max;

    generate
        for (g = 0; g < 4; g = g + 1) begin : mxa
            assign mx0[g] = (mag[2*g] > mag[2*g+1]) ? mag[2*g] : mag[2*g+1];
        end
        for (g = 0; g < 2; g = g + 1) begin : mxb
            assign mx1[g] = (mx0[2*g] > mx0[2*g+1]) ? mx0[2*g] : mx0[2*g+1];
        end
    endgenerate
    assign mag_max = (mx1[0] > mx1[1]) ? mx1[0] : mx1[1];

    //--------------------------------------------------------------------------
    // peak envelope: fast attack, slow release (ph0)
    //--------------------------------------------------------------------------
    wire [17:0] env_nxt [0:N-1];

    generate
        for (g = 0; g < N; g = g + 1) begin : ev
            wire [17:0] up   = env[g] + ((mag[g] - env[g]) >> 1);
            wire [17:0] down = env[g] - ((env[g] - mag[g]) >> 5);
            assign env_nxt[g] = (mag[g] >= env[g]) ? up : down;
        end
    endgenerate

    //--------------------------------------------------------------------------
    // pipeline phase counter
    //--------------------------------------------------------------------------
    reg [2:0] ph;

    always @(posedge clk or posedge arst) begin
        if (arst)
            ph <= 3'd0;
        else if (samp_tick || (ph == 3'd4))
            ph <= 3'd0;
        else
            ph <= ph + 3'd1;
    end

    //--- leading-one index (18 level priority chain, gets its own clock) ------
    function [4:0] topbit(input [17:0] v);
        integer k;
        begin
            topbit = 5'd0;
            for (k = 0; k < 18; k = k + 1)
                if (v[k]) topbit = k[4:0];
        end
    endfunction

    // about 24 pixels per octave, 3 sub steps per octave inside a band
    function [9:0] hgt_of(input [4:0] e, input [2:0] mn);
        begin
            if (e < 5'd9)
                hgt_of = 10'd0;
            else
                hgt_of = (({5'd0, e} - 10'd9) * 10'd24) + ({7'd0, mn} * 10'd3);
        end
    endfunction

    reg [4:0] tb  [0:N-1];
    reg [2:0] man [0:N-1];
    reg [9:0] hgt [0:N-1];

    integer i;
    always @(posedge clk or posedge arst) begin
        if (arst) begin
            for (i = 0; i < N; i = i + 1) begin
                lp[i]  <= 18'sd0;
                lp2[i] <= 18'sd0;
                mag[i] <= 18'd0;
                env[i] <= 18'd0;
                tb[i]  <= 5'd0;
                man[i] <= 3'd0;
                hgt[i] <= 10'd0;
            end
            dc_lp <= 18'sd0;
            mmax  <= 18'd0;
            xin_r <= 18'sd0;
            sp_h  <= 128'd0;
        end else begin
            xin_r <= xin_dc;

            if (samp_tick) begin
                dc_lp <= dc_lp + (xin_dc >>> 10);
                for (i = 0; i < N; i = i + 1) begin
                    lp[i]  <= lp_nxt[i];
                    lp2[i] <= lp2_nxt[i];
                    mag[i] <= mag_n[i];
                end
            end

            case (ph)
                3'd0: begin      // envelope follows the freshly captured magnitude
                    for (i = 0; i < N; i = i + 1)
                        env[i] <= env_nxt[i];
                end
                3'd1: begin      // 18 level chain: env -> tb
                    for (i = 0; i < N; i = i + 1)
                        tb[i] <= topbit(env[i]);
                    mmax <= mag_max;
                end
                3'd2: begin      // three bits under the leading one, no variable shift
                    for (i = 0; i < N; i = i + 1)
                        man[i] <= (tb[i] == 5'd17) ? env[i][16:14] :
                                  (tb[i] == 5'd16) ? env[i][15:13] :
                                  (tb[i] == 5'd15) ? env[i][14:12] :
                                  (tb[i] == 5'd14) ? env[i][13:11] :
                                  (tb[i] == 5'd13) ? env[i][12:10] :
                                  (tb[i] == 5'd12) ? env[i][11:9]  :
                                  (tb[i] == 5'd11) ? env[i][10:8]  :
                                  (tb[i] == 5'd10) ? env[i][9:7]   :
                                  (tb[i] == 5'd9)  ? env[i][8:6]   :
                                  (tb[i] == 5'd8)  ? env[i][7:5]   : 3'd0;
                end
                3'd3: begin      // constant multiply only
                    for (i = 0; i < N; i = i + 1)
                        hgt[i] <= hgt_of(tb[i], man[i]);
                end
                default: begin   // 12dB peak gate + publish (bytes 8..15 stay 0)
                    for (i = 0; i < N; i = i + 1)
                        sp_h[8*i +: 8] <= ((tb[i] < 5'd9) || ((mag[i] << 2) < mmax))
                                          ? 8'd0
                                          : ((hgt[i] > 10'd255) ? 8'hFF : hgt[i][7:0]);
                end
            endcase
        end
    end

endmodule
