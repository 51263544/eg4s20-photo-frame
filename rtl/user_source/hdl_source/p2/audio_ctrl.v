//==============================================================================
// audio_ctrl.v  --  P6 audio: AHB slave + sample FIFO + 1-bit sigma-delta PWM
//
// Memory map (window 0x4003_0000 - 0x4003_FFFF, 32-bit registers):
//   0x00  W  DATA    push one 32-bit word = two 16-bit PCM samples,
//                    {s1[15:0], s0[15:0]}; s0 is played first.
//                    Write is dropped if the FIFO is full (check STATUS first).
//   0x04  W  CTRL    bit0 PLAYMODE enable (0 = forced silence)
//                    bit1 FLUSH  (self clearing) empties the FIFO
//                    bit2 MUTE   (keeps the FIFO running, outputs silence)
//   0x08  R  STATUS  [9:0]  fill level in words
//                    [16]   full   [17] empty   [18] almost_full  [19] almost_empty
//                    [20]   enable [21] mute    [22] fifo_reset
//   0x0C  W/R RATE   sample tick period in clk_50m cycles (default 1134 -> 44.09kHz)
//   0x10  W/R VOL    0..256 gain in Q8 (256 = unity, default 256)
//   0x14  R  TICKCNT free running 32-bit sample counter (audio clock proof)
//
// Audio chain: signed 16-bit PCM -> volume -> offset binary -> 1st order
// sigma-delta modulator at clk_50m -> AUDIO_PWM (board low-pass + power amp).
// A first order modulator at 50MHz/44.1kHz has an oversampling ratio of ~1134,
// i.e. ~ -73dB of in band noise, far better than the 8-bit PWM DAC of the
// vendor demo (which is what the board filter was designed for).
//
// Clocking: the AHB face runs on HCLK (25MHz sys domain); the modulator runs on
// clk_50m.  The two domains meet only through an Anlogic async FIFO, whose reset
// is synchronised internally by the IP.
//==============================================================================
`timescale 1ns/1ps

module audio_ctrl (
    // ---- AHB-Lite slave (HCLK / HRESETn domain) ----
    input  wire         HCLK,
    input  wire         HRESETn,
    input  wire         HSEL,
    input  wire [31:0]  HADDR,
    input  wire [1:0]   HTRANS,
    input  wire         HWRITE,
    input  wire [31:0]  HWDATA,
    input  wire         HREADY,
    output wire         HREADYOUT,
    output wire         HRESP,
    output wire [31:0]  HRDATA,

    // ---- audio side ----
    input  wire         clk_50m,        // 50MHz board clock, PWM carrier domain
    input  wire         arst,           // active high reset for clk_50m domain
    output wire         audio_pwm,      // 1-bit PWM / sigma-delta output

    // ---- firmware display channel (7-segment, replaces the dead UART) ----
    output wire [15:0]  disp_val,       // value the firmware wrote to +0x18
    output wire         disp_en,        // +0x18 bit16 = take over the display

    // ---- keypad events from the 50MHz domain (P6 music toggle) ---------------
    input  wire [31:0]  key_cnt,         // 16 x 2-bit press counters (pxl_clk)
    input  wire [15:0]  key_lvl,         // debounced pressed level (pxl_clk)

    // ---- 16 band spectrum analyser bars (P6) --------------------------------
    output wire [127:0] spec_h,         // 16 x 8 bit heights, byte 0 = bass

    // ---- microphone ADC (SPI: CS=J6 MISO=K5 SCK=H3 RSTN=G6) ----------------
    output wire         adc_cs_n,
    output wire         adc_sck,
    output wire         adc_rst_n,
    input  wire         adc_miso
);

    //--------------------------------------------------------------------------
    // AHB access decode (same proven pattern as sd_ctrl: zero wait state slave)
    //--------------------------------------------------------------------------
    assign HREADYOUT = 1'b1;
    assign HRESP     = 1'b0;

    wire        sel_wr  = HSEL & HTRANS[1] &  HWRITE & HREADY;
    wire        sel_rd  = HSEL & HTRANS[1] & ~HWRITE & HREADY;
    wire [3:0]  reg_sel = HADDR[5:2];

    reg  [3:0]  reg_sel_q;
    reg         wr_strobe_q;

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            reg_sel_q   <= 4'd0;
            wr_strobe_q <= 1'b0;
        end else if (HREADY) begin
            reg_sel_q   <= reg_sel;
            wr_strobe_q <= sel_wr;
        end
    end

    // data phase write strobes (HWDATA is only valid in the data phase)
    wire wr_data  = wr_strobe_q & (reg_sel_q == 3'd0);
    wire wr_ctrl  = wr_strobe_q & (reg_sel_q == 3'd1);
    wire wr_rate  = wr_strobe_q & (reg_sel_q == 3'd3);
    wire wr_vol   = wr_strobe_q & (reg_sel_q == 3'd4);

    //--------------------------------------------------------------------------
    // Control / rate / volume registers (HCLK domain)
    //--------------------------------------------------------------------------
    reg  [16:0] disp_q;                // [15:0] value, [16] display enable
    reg  [16:0] tone_q;                // 0x24: [15:0] amp, [16] enable (hw tone)
    reg  [15:0] tstep_q;               // 0x30: phase step, 65536 == 44091.7Hz
    reg  [11:0] shelf_q;               // 0x34: high shelf gain, 256 = 0dB
    reg         mic_q;                 // 0x38 bit0: bars follow the microphone
    reg         enable_q;
    reg         mute_q;
    reg         flush_q;
    reg         mode_q;                // CTL bit7: 1 = 195kHz PWM, 0 = sigma-delta
    reg [15:0]  rate_q;
    reg [8:0]   vol_q;

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            enable_q <= 1'b0;
            mute_q   <= 1'b0;
            flush_q  <= 1'b0;
            mode_q   <= 1'b0;          // default: 1-bit sigma-delta (quiet)
            rate_q   <= 16'd1134;      // 50MHz / 1134 = 44.09kHz
            vol_q    <= 9'd256;        // unity
            disp_q   <= 17'd0;
            tone_q   <= 17'd0;
            tstep_q  <= 16'd1486;      // 999.9Hz at 44.09kHz (the old fixed step)
            shelf_q  <= 12'd256;       // 0dB: the firmware starts on preset 0
            mic_q    <= 1'b0;          // bars follow the SD player by default
        end else begin
            flush_q <= 1'b0;           // self clearing pulse
            if (wr_ctrl) begin
                enable_q <= HWDATA[0];
                mute_q   <= HWDATA[2];
                mode_q   <= HWDATA[7];
                if (HWDATA[1]) flush_q <= 1'b1;
            end
            if (wr_rate)
                rate_q <= (HWDATA[15:0] < 16'd16) ? 16'd16 : HWDATA[15:0];
            if (wr_vol)
                vol_q <= (HWDATA[8:0] > 9'd256) ? 9'd256 : HWDATA[8:0];
            if (wr_strobe_q && (reg_sel_q == 3'd6))
                disp_q <= HWDATA[16:0];
            if (wr_strobe_q && (reg_sel_q == 4'd9))
                tone_q <= HWDATA[16:0];
            if (wr_strobe_q && (reg_sel_q == 4'd12))
                tstep_q <= HWDATA[15:0];
            if (wr_strobe_q && (reg_sel_q == 4'd13))
                shelf_q <= HWDATA[11:0];
            if (wr_strobe_q && (reg_sel_q == 4'd14))
                mic_q <= HWDATA[0];
        end
    end

    //--------------------------------------------------------------------------
    // Key events (P6).
    //
    // History of this block, because it was wrong twice:
    //  1) it first latched the pxl_clk pulse with a 2FF in the 50MHz domain and
    //     compared a *sticky level* against the last value HCLK had seen.  That
    //     can only ever report the FIRST press of a key -- after that the level
    //     no longer changes, so the second press produced no event (KEY7 could
    //     be started but never stopped).
    //  2) the clear used the address-phase sel_rd, one cycle before the CPU
    //     sampled HRDATA, so every read returned zero.
    //
    // Now keypad_4x4 hands over 16 x 2-bit press counters and this block turns
    // counter differences into event bits, so every press -- of any key, any
    // number of times -- shows up exactly once.  The counters change at most
    // once per ~100ms debounce interval, so a plain 2FF resync is safe.
    //--------------------------------------------------------------------------
    reg  [31:0] kc_s0, kc_s1;           // 2FF resync of the press counters
    reg  [31:0] kc_shadow;              // counter values already reported
    reg  [15:0] keyev_q;                // pending events, cleared on read

    // Data-phase read strobe for the key register.  This MUST NOT be the
    // address-phase sel_rd: the read data is driven in the data phase, so
    // clearing keyev_q on sel_rd wipes the events in the very cycle before the
    // CPU samples them.  rd_data_q is one cycle behind sel_rd, i.e. the cycle
    // in which HRDATA is valid, and reg_sel_q was latched by that same edge so
    // it still says 8.
    reg         rd_data_q;
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn)
            rd_data_q <= 1'b0;
        else
            rd_data_q <= sel_rd;
    end

    wire rd_key = rd_data_q & (reg_sel_q == 4'd8);

    // Debounced key level: lets the firmware see *which bit* a key press is on
    // even if the event path fails, which is how the KEY3/KEY4 mystery is being
    // pinned down.  Replaces the hardwired 16'd0 that made AU_KEY_DOWN read 0.
    reg  [15:0] kl_s0, kl_s1;
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            kl_s0 <= 16'd0;
            kl_s1 <= 16'd0;
        end else begin
            kl_s0 <= key_lvl;
            kl_s1 <= kl_s0;
        end
    end

    wire [15:0] kc_new;                 // one bit per key whose counter moved
    genvar gk;
    generate
        for (gk = 0; gk < 16; gk = gk + 1) begin : g_key_cnt
            assign kc_new[gk] = (kc_s1[2*gk +: 2] != kc_shadow[2*gk +: 2]);
        end
    endgenerate

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            kc_s0     <= 32'd0;
            kc_s1     <= 32'd0;
            kc_shadow <= 32'd0;
            keyev_q   <= 16'd0;
        end else begin
            kc_s0     <= key_cnt;
            kc_s1     <= kc_s0;
            kc_shadow <= kc_s1;
            /* a read consumes what was pending, but an event arriving in the
             * very same cycle is kept */
            keyev_q   <= (rd_key ? 16'd0 : keyev_q) | kc_new;
        end
    end

    //--------------------------------------------------------------------------
    // Sample FIFO: 512 x 32bit async FIFO (write 25MHz, read 50MHz)
    //--------------------------------------------------------------------------
    wire [31:0] fifo_dout;
    wire        fifo_full;
    wire        fifo_empty;
    wire        fifo_afull;
    wire        fifo_aempty;
    wire [8:0]  fifo_wrusedw;
    wire [8:0]  fifo_rdusedw;
    wire        fifo_re;

    wire fifo_rst = ~HRESETn | flush_q;

    wfifo_32_32_512 u_audio_fifo (
        .rst        (fifo_rst),
        .clkw       (HCLK),
        .we         (wr_data & ~fifo_full),
        .di         (HWDATA),
        .clkr       (clk_50m),
        .re         (fifo_re),
        .dout       (fifo_dout),
        .valid      (),
        .full_flag  (fifo_full),
        .empty_flag (fifo_empty),
        .afull      (fifo_afull),
        .aempty     (fifo_aempty),
        .wrusedw    (fifo_wrusedw),
        .rdusedw    (fifo_rdusedw)
    );

    //--------------------------------------------------------------------------
    // Control CDC: the AHB registers live in the HCLK domain but the modulator
    // samples them on clk_50m, so every one of them is 2FF synchronised here.
    // They are quasi-static (the firmware writes them at start-up only), so the
    // occasional stale word during a change is harmless and the two flip-flops
    // keep the tools from reporting a bogus single-cycle crossing.
    //--------------------------------------------------------------------------
    reg        en_s0,  en_s1;
    reg        mu_s0,  mu_s1;
    reg [15:0] rate_s0, rate_s1;
    reg [8:0]  vol_s0,  vol_s1;

    always @(posedge clk_50m or posedge arst) begin
        if (arst) begin
            en_s0 <= 1'b0;  en_s1 <= 1'b0;
            mu_s0 <= 1'b0;  mu_s1 <= 1'b0;
            rate_s0 <= 16'd1134; rate_s1 <= 16'd1134;
            vol_s0  <= 9'd256;   vol_s1  <= 9'd256;
        end else begin
            en_s0   <= enable_q;    en_s1   <= en_s0;
            mu_s0   <= mute_q;      mu_s1   <= mu_s0;
            rate_s0 <= rate_q;      rate_s1 <= rate_s0;
            vol_s0  <= vol_q;       vol_s1  <= vol_s0;
        end
    end

    //--------------------------------------------------------------------------
    // Sample clock + sample fetch (clk_50m domain)
    //--------------------------------------------------------------------------
    reg [15:0] tick_cnt;
    reg        samp_tick;
    reg        half;                  // 0 = low half of the current word, 1 = high
    reg [15:0] pcm_q;                 // latched signed PCM sample
    reg [31:0] samp_cnt;              // proof-of-life counter for the fw

    // pop the FIFO after the high half has been consumed
    assign fifo_re = samp_tick & half & ~fifo_empty;

    always @(posedge clk_50m or posedge arst) begin
        if (arst) begin
            tick_cnt  <= 16'd0;
            samp_tick <= 1'b0;
            half      <= 1'b0;
            pcm_q     <= 16'd0;
            samp_cnt  <= 32'd0;
        end else begin
            // ---------------- sample tick generator ----------------
            if (tick_cnt >= rate_s1 - 16'd1) begin
                tick_cnt  <= 16'd0;
                samp_tick <= 1'b1;
            end else begin
                tick_cnt  <= tick_cnt + 16'd1;
                samp_tick <= 1'b0;
            end

            // ---------------- fetch one sample ----------------
            if (samp_tick)
                samp_cnt <= samp_cnt + 32'd1;
            if (samp_tick && !fifo_empty) begin
                pcm_q <= half ? fifo_dout[31:16] : fifo_dout[15:0];
                half  <= ~half;
            end else if (samp_tick) begin
                pcm_q <= 16'd0;       // underrun: silence
                half  <= 1'b0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // Hardware test tone (v33).  A 1kHz sine made straight from the 50MHz
    // clock and injected *after* the FIFO, before the modulator, so it
    // bypasses the whole streaming path (SD, firmware, async FIFO).
    // This is the test that says where the distortion lives: a clean tone here
    // means the modulator plus the analogue chain are fine and the fault is in
    // the FIFO/firmware feed; a dirty tone here means the problem is
    // downstream of pcm_u.
    //   0x24: [15:0] amplitude (32767 = full scale), [16] enable
    //--------------------------------------------------------------------------
    reg  [16:0] tone_s0, tone_s1;

    always @(posedge clk_50m or posedge arst) begin
        if (arst) begin
            tone_s0 <= 17'd0;
            tone_s1 <= 17'd0;
        end else begin
            tone_s0 <= tone_q;
            tone_s1 <= tone_s0;
        end
    end

    wire        tone_en  = tone_s1[16];
    wire [15:0] tone_amp = tone_s1[15:0];

    reg  [15:0] tstep_s0, tstep_s1;

    always @(posedge clk_50m or posedge arst) begin
        if (arst) begin
            tstep_s0 <= 16'd1486;
            tstep_s1 <= 16'd1486;
        end else begin
            tstep_s0 <= tstep_q;
            tstep_s1 <= tstep_s0;
        end
    end

    reg  [15:0] tone_ph;

    always @(posedge clk_50m or posedge arst) begin
        if (arst)           tone_ph <= 16'd0;
        else if (samp_tick) tone_ph <= tone_ph + tstep_s1;  // 0x30 sets the pitch
    end

    wire [5:0] tone_idx = tone_ph[15:10];
    reg signed [15:0] tone_rom;

    always @(*) begin
        case (tone_idx)
            6'd0: tone_rom = 16'sd0;
            6'd1: tone_rom = 16'sd3212;
            6'd2: tone_rom = 16'sd6393;
            6'd3: tone_rom = 16'sd9512;
            6'd4: tone_rom = 16'sd12539;
            6'd5: tone_rom = 16'sd15446;
            6'd6: tone_rom = 16'sd18204;
            6'd7: tone_rom = 16'sd20787;
            6'd8: tone_rom = 16'sd23170;
            6'd9: tone_rom = 16'sd25329;
            6'd10: tone_rom = 16'sd27245;
            6'd11: tone_rom = 16'sd28898;
            6'd12: tone_rom = 16'sd30273;
            6'd13: tone_rom = 16'sd31356;
            6'd14: tone_rom = 16'sd32137;
            6'd15: tone_rom = 16'sd32609;
            6'd16: tone_rom = 16'sd32767;
            6'd17: tone_rom = 16'sd32609;
            6'd18: tone_rom = 16'sd32137;
            6'd19: tone_rom = 16'sd31356;
            6'd20: tone_rom = 16'sd30273;
            6'd21: tone_rom = 16'sd28898;
            6'd22: tone_rom = 16'sd27245;
            6'd23: tone_rom = 16'sd25329;
            6'd24: tone_rom = 16'sd23170;
            6'd25: tone_rom = 16'sd20787;
            6'd26: tone_rom = 16'sd18204;
            6'd27: tone_rom = 16'sd15446;
            6'd28: tone_rom = 16'sd12539;
            6'd29: tone_rom = 16'sd9512;
            6'd30: tone_rom = 16'sd6393;
            6'd31: tone_rom = 16'sd3212;
            6'd32: tone_rom = 16'sd0;
            6'd33: tone_rom = -16'sd3212;
            6'd34: tone_rom = -16'sd6393;
            6'd35: tone_rom = -16'sd9512;
            6'd36: tone_rom = -16'sd12539;
            6'd37: tone_rom = -16'sd15446;
            6'd38: tone_rom = -16'sd18204;
            6'd39: tone_rom = -16'sd20787;
            6'd40: tone_rom = -16'sd23170;
            6'd41: tone_rom = -16'sd25329;
            6'd42: tone_rom = -16'sd27245;
            6'd43: tone_rom = -16'sd28898;
            6'd44: tone_rom = -16'sd30273;
            6'd45: tone_rom = -16'sd31356;
            6'd46: tone_rom = -16'sd32137;
            6'd47: tone_rom = -16'sd32609;
            6'd48: tone_rom = -16'sd32767;
            6'd49: tone_rom = -16'sd32609;
            6'd50: tone_rom = -16'sd32137;
            6'd51: tone_rom = -16'sd31356;
            6'd52: tone_rom = -16'sd30273;
            6'd53: tone_rom = -16'sd28898;
            6'd54: tone_rom = -16'sd27245;
            6'd55: tone_rom = -16'sd25329;
            6'd56: tone_rom = -16'sd23170;
            6'd57: tone_rom = -16'sd20787;
            6'd58: tone_rom = -16'sd18204;
            6'd59: tone_rom = -16'sd15446;
            6'd60: tone_rom = -16'sd12539;
            6'd61: tone_rom = -16'sd9512;
            6'd62: tone_rom = -16'sd6393;
            6'd63: tone_rom = -16'sd3212;
            default: tone_rom = 16'sd0;
        endcase
    end

    wire signed [31:0] tone_mul = tone_rom * $signed({1'b0, tone_amp});
    wire signed [15:0] tone_s16 = tone_en ? tone_mul[30:15] : 16'sd0;

    //--------------------------------------------------------------------------
    // Source select, then the high shelf, then volume and offset binary.
    //--------------------------------------------------------------------------
    wire signed [15:0] pcm_src = tone_en ? tone_s16 : pcm_q;
    wire               audible = tone_en | (en_s1 && !mu_s1);

    //--------------------------------------------------------------------------
    // High shelf: cancel the board's audio low-pass.
    //
    // The board analogue path (LMV358 RC low-pass into the FM8002A class-D amp)
    // is about -10dB at 2kHz, -19dB at 4kHz and -37dB at 8kHz, measured on a
    // music recording, which is why music sounds muffled while a 1kHz test
    // tone still sounds fine.  A cheap inverse is
    //
    //     y = lp + G*(x - lp)          lp = one pole at ~880Hz
    //
    // with G = shelf_q/256 the high-frequency gain (256 = 0dB, 512 = +6dB,
    // 1024 = +12dB).  Coefficient in 0x34 so presets can be A/B'd by ear.
    //
    // Everything here advances ONCE PER SAMPLE (samp_tick), i.e. every 22.7us
    // at 44.1kHz, so the three pipeline stages each get a whole sample period
    // to settle.  Doing the 18x12 multiplier and the following 16x9 volume
    // multiply combinationally in one 20ns cycle failed timing by -6.6ns.
    //--------------------------------------------------------------------------
    reg  signed [17:0] shelf_lp;
    reg  [11:0]        shelf_s0, shelf_s1;

    always @(posedge clk_50m or posedge arst) begin
        if (arst) begin
            shelf_s0 <= 12'd256;
            shelf_s1 <= 12'd256;
        end else begin
            shelf_s0 <= shelf_q;
            shelf_s1 <= shelf_s0;
        end
    end

    wire [11:0]        shelf_g  = shelf_s1;

    reg  signed [17:0] sh_x;          // stage 1: captured sample + lp snapshot
    reg  signed [17:0] sh_lp;
    reg  signed [17:0] sh_hp;         // stage 2: high part
    reg  [11:0]        sh_g;
    reg  signed [22:0] sh_add;        // stage 3: (hp*G)>>8
    reg  signed [15:0] sh_eq;         // stage 4: equalised sample

    wire signed [17:0] sh_xin = {{2{pcm_src[15]}}, pcm_src};
    wire signed [31:0] sh_prod = sh_hp * $signed({1'b0, sh_g});
    wire signed [22:0] sh_sum  = {{5{sh_lp[17]}}, sh_lp} + sh_add;

    always @(posedge clk_50m or posedge arst) begin
        if (arst) begin
            shelf_lp <= 18'sd0;
            sh_x     <= 18'sd0;
            sh_lp    <= 18'sd0;
            sh_hp    <= 18'sd0;
            sh_g     <= 12'd256;
            sh_add   <= 23'sd0;
            sh_eq    <= 16'sd0;
        end else if (samp_tick) begin
            // stage 1: keep the one-pole low-pass estimate of the signal
            shelf_lp <= shelf_lp + ((sh_xin - shelf_lp) >>> 3);   // ~880Hz pole
            sh_x     <= sh_xin;
            sh_lp    <= shelf_lp;
            sh_hp    <= sh_x - shelf_lp;
            sh_g     <= shelf_g;
            // stage 2 -> 3: high-frequency boost
            sh_add   <= sh_prod[30:8];
            // stage 3 -> 4: recombine and clip to 16 bits
            sh_eq    <= (sh_sum >  23'sd32767) ?  16'sd32767 :
                        (sh_sum < -23'sd32768) ? -16'sd32768 :
                                                 sh_sum[15:0];
        end
    end

    wire signed [15:0] pcm_eq = sh_eq;

    wire signed [24:0] pcm_mul = pcm_eq * $signed({1'b0, vol_s1});   // 16 x 9 -> 25
    wire signed [15:0] pcm_vol = pcm_mul[23:8];                    // >>8, Q8 gain
    wire        [15:0] pcm_u   = audible
                                 ? {~pcm_vol[15], pcm_vol[14:0]}   // offset binary
                                 : 16'h8000;                       // digital silence

    //--------------------------------------------------------------------------
    // Output stage.  Two modulators, selectable at run time (0x04 bit 7):
    //
    //   mode_pwm = 1 (default): 8-bit counter PWM at 50MHz/256 = 195.3kHz, the
    //     carrier the board's PWM low-pass filter was designed for (the vendor
    //     demo uses exactly this).  The 8-bit truncation error is fed back into
    //     a first order noise shaper running at the carrier rate, so the
    //     quantisation noise is pushed above the audio band instead of sitting
    //     in it -- 8-bit PWM on its own would be audibly noisy.
    //
    //   mode_pwm = 0: the original 1-bit sigma-delta at the full 50MHz.  It is
    //     numerically better but dumps its carrier energy at 25..50MHz, where a
    //     filter built for 195kHz cannot remove it cleanly and the amplifier
    //     input can rectify it.  Kept for A/B testing.
    //--------------------------------------------------------------------------
    reg         mode_s0, mode_s1;       // mode_q resynced into the 50MHz domain
    wire        mode_pwm = mode_s1;     // from CTRL bit 7, 1 = 195kHz PWM

    always @(posedge clk_50m or posedge arst) begin
        if (arst) begin
            mode_s0 <= 1'b0;
            mode_s1 <= 1'b0;
        end else begin
            mode_s0 <= mode_q;
            mode_s1 <= mode_s0;
        end
    end

    // --- noise shaped 8-bit PWM -------------------------------------------------
    reg  [7:0]  pwm_cnt;
    reg  [7:0]  pwm_duty;
    reg  [16:0] ns_acc;                 // sample + truncation residue

    wire [16:0] ns_sum = ns_acc + {1'b0, pcm_u};
    wire [7:0]  ns_out = ns_sum[15:8];  // duty for the next carrier period
    wire [16:0] ns_rem = {9'd0, ns_sum[7:0]};

    always @(posedge clk_50m or posedge arst) begin
        if (arst) begin
            pwm_cnt  <= 8'd0;
            pwm_duty <= 8'd128;         // mid rail = silence
            ns_acc   <= 17'd0;
        end else begin
            pwm_cnt <= pwm_cnt + 8'd1;
            if (samp_tick) begin
                ns_acc   <= ns_rem;
                pwm_duty <= ns_out;
            end
        end
    end

    wire pwm_bit = (pwm_cnt < pwm_duty);

    // --- 1st order 1-bit sigma-delta at 50MHz ----------------------------------
    reg  [16:0] sd_acc;
    wire        sd_bit = sd_acc[16];

    always @(posedge clk_50m or posedge arst) begin
        if (arst)
            sd_acc <= 17'd0;
        else
            sd_acc <= sd_acc + {1'b0, pcm_u} - (sd_bit ? 17'd65536 : 17'd0);
    end

    assign audio_pwm = mode_pwm ? pwm_bit : sd_bit;

    //--------------------------------------------------------------------------
    // 16 band log spectrum for the on screen bars.  Fed with pcm_src (after the
    // shelf, before the volume) so the bars do not move when the volume changes.
    //--------------------------------------------------------------------------
    //--------------------------------------------------------------------------
    // microphone ADC (SPI, 100kSPS) and the bars source selector.
    //
    // mic_q (0x38 bit0) does not touch the playback path at all: it only
    // switches what the analyser listens to, so the microphone cannot feed back
    // into the speaker.  The analyser's own DC blocker removes the ADC's
    // unsigned offset, so the raw frame can be used as a signed sample.
    //--------------------------------------------------------------------------
    wire [15:0] mic_data;
    wire        mic_valid;
    wire [15:0] mic_edges;
    wire [15:0] mic_frames;
    wire [15:0] mic_peak;
    wire [15:0] mic_trough;

    mic_adc u_mic_adc (
        .clk       (clk_50m),
        .arst      (arst),
        .adc_cs_n  (adc_cs_n),
        .adc_sck   (adc_sck),
        .adc_rst_n (adc_rst_n),
        .adc_miso  (adc_miso),
        .mic_data  (mic_data),
        .mic_valid (mic_valid),
        .mic_edges (mic_edges),
        .mic_frames(mic_frames),
        .mic_peak  (mic_peak),
        .mic_trough(mic_trough)
    );

    wire [15:0] spec_pcm  = mic_q ? mic_data : pcm_src;
    wire        spec_tick = mic_q ? mic_valid : samp_tick;

    spectrum_bank u_spectrum (
        .clk       (clk_50m),
        .arst      (arst),
        .samp_tick (spec_tick),
        .pcm       (spec_pcm),
        .sp_h      (spec_h)
    );

    //--------------------------------------------------------------------------
    // Read data mux.  Pure status registers only -- no side effects -- so
    // sampling with the address-phase latched reg_sel_q is safe here.
    //
    // CDC note: only *write side* FIFO flags (full/afull/wrusedw) are used for
    // the fill level, because they live in the HCLK domain.  empty_flag and the
    // sample counter come from the 50MHz domain and are 2FF synchronised first
    // (they are status only, a stale value is harmless).
    //--------------------------------------------------------------------------
    reg        empty_sync0, empty_sync1;
    reg [31:0] cnt_sync0,   cnt_sync1;

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            empty_sync0 <= 1'b1;
            empty_sync1 <= 1'b1;
            cnt_sync0   <= 32'd0;
            cnt_sync1   <= 32'd0;
        end else begin
            empty_sync0 <= fifo_empty;
            empty_sync1 <= empty_sync0;
            cnt_sync0   <= samp_cnt;
            cnt_sync1   <= cnt_sync0;
        end
    end

    //--------------------------------------------------------------------------
    // Sample-rate measurement, entirely in the HCLK domain so the firmware does
    // not have to trust its own delay loop: every 25,000,000 HCLK cycles (1s at
    // 25MHz) latch how far the audio sample counter moved.  Result at +0x1C,
    // a fresh-window toggle at STATUS[14].
    //--------------------------------------------------------------------------
    localparam [24:0] SEC_CYCLES = 25'd25_000_000;

    reg [24:0] sec_cnt;
    reg [31:0] meas_val, samp_prev;
    reg        meas_tgl;

    //--------------------------------------------------------------------------
    // Audio health counters.
    //
    // The board has no working log channel, so "the music crackles" used to be
    // unattributable.  Two counters make it measurable:
    //   under_cnt -- sample ticks that found the FIFO empty.  The DAC then
    //                repeats the previous sample, and that repeated-sample
    //                pattern is exactly what a listener hears as crackle.
    //   drop_cnt  -- words the CPU pushed while the FIFO was full, i.e. sample
    //                pairs that were silently thrown away.
    // Both are latched once per 1s window and read back at +0x28 / +0x2C.
    //--------------------------------------------------------------------------
    reg [31:0] under_cnt;               // clk_50m domain
    reg [31:0] under_s0, under_s1;      // resync into HCLK
    reg [31:0] drop_cnt;                // HCLK domain
    reg [31:0] under_meas, drop_meas;   // last completed 1s window

    always @(posedge clk_50m or posedge arst) begin
        if (arst)
            under_cnt <= 32'd0;
        else if (samp_tick && fifo_empty)
            under_cnt <= under_cnt + 32'd1;
    end

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            under_s0   <= 32'd0;
            under_s1   <= 32'd0;
            drop_cnt   <= 32'd0;
            under_meas <= 32'd0;
            drop_meas  <= 32'd0;
        end else begin
            under_s0 <= under_cnt;
            under_s1 <= under_s0;
            if (wr_data && fifo_full)
                drop_cnt <= drop_cnt + 32'd1;
            if (sec_cnt >= (SEC_CYCLES - 25'd1)) begin
                under_meas <= under_s1;
                drop_meas  <= drop_cnt;
            end
        end
    end

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            sec_cnt   <= 25'd0;
            meas_val  <= 32'd0;
            samp_prev <= 32'd0;
            meas_tgl  <= 1'b0;
        end else if (sec_cnt >= (SEC_CYCLES - 25'd1)) begin
            sec_cnt   <= 25'd0;
            meas_val  <= samp_cnt - samp_prev;
            samp_prev <= samp_cnt;
            meas_tgl  <= ~meas_tgl;
        end else begin
            sec_cnt   <= sec_cnt + 25'd1;
        end
    end

    reg [31:0] rd_mux;

    always @(*) begin
        case (reg_sel_q)
            4'd2: rd_mux = {17'd0, meas_tgl, fifo_afull, fifo_full, empty_sync1,
                            mute_q, enable_q, fifo_wrusedw};   /* +0x08 STATUS */
            3'd3: rd_mux = {16'd0, rate_q};
            3'd4: rd_mux = {23'd0, vol_q};
            3'd5: rd_mux = cnt_sync1;
            3'd6: rd_mux = {15'd0, disp_q};
            3'd7: rd_mux = meas_val;
            4'd8: rd_mux = {kl_s1, keyev_q};   // [31:16] live key level, [15:0] events
            4'd9: rd_mux = {15'd0, tone_q};    // hardware tone control
            4'd10: rd_mux = under_meas;        // FIFO starvations in last 1s
            4'd11: rd_mux = drop_meas;         // lost pushes in last 1s
            4'd12: rd_mux = {16'd0, tstep_q};  // hardware tone phase step
            4'd13: rd_mux = {20'd0, shelf_q};  // high shelf gain
            4'd14: rd_mux = {31'd0, mic_q};    // [0] bars follow the microphone
            4'd15: rd_mux = {16'd0, mic_data}; // raw 16 bit ADC frame
            4'd1:  rd_mux = {mic_peak, mic_trough}; // +0x04 read: mic bring-up:
                                                     // [31:16] 1s peak, [15:0] 1s trough
            default: rd_mux = 32'd0;
        endcase
    end

    assign HRDATA = rd_mux;

    assign disp_val = disp_q[15:0];
    assign disp_en  = disp_q[16];

endmodule
