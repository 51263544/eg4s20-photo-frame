//------------------------------------------------------------------------------
// p2_sd_display.v -- P2 top: M0 SoC + SD card BMP slideshow into SDRAM
// framebuffer + HDMI display out.
//
// Clock plan (EG4S20 has 2 PLLs, both used):
//   sys_pll (freq-modified lab copy): C0=25MHz  sys_clk  (SoC + SD chain)
//                                     C1=125MHz mem_clk  (SDRAM ctrl)
//                                     C2=125MHz mem_clk_sft (antiphase)
//   tx_pll (P0b verbatim):            C0=25MHz  pxl_clk  (video timing)
//                                     C2=125MHz pxl_5x   (HDMI serializer)
//
// Data flow:
//   M0 --AHB P2--> sd_ctrl --cmd--> sd_card_top(SPI) --bytes--> bmp_pack
//     --{R,G,B,0}--> frame_read_write(write) --wfifo--> sdram (dual buffer)
//   video_timing_data(pxl) --read_req--> frame_read_write(read) --rfifo-->
//     video_delay --hs/vs/de/rgb888--> hdmi_tx (P0b proven chain)
//
// Buffer management is all M0 firmware (sd_ctrl regs): write into the
// non-displayed buffer, on write_finish toggle the M0 commits it.
//------------------------------------------------------------------------------
module p2_sd_display(
        input  wire        clk,          // 50MHz R7
        input  wire        RSTn,         // reset key A9, active low
        inout  wire        SWDIO,
        input  wire        SWCLK,
        input  wire        uart_rxd,
        output wire        uart_txd,
        // SD card SPI
        output wire        SD_nCS,
        output wire        SD_DCLK,
        output wire        SD_MOSI,
        input  wire        SD_MISO,
        // HDMI (P0b tx chain)
        output wire        HDMI_CLK_P,
        output wire        HDMI_D2_P,
        output wire        HDMI_D1_P,
        output wire        HDMI_D0_P,
        // VGA debug tap (P0b pins, same signals as HDMI)
        output wire        VGA_HS,
        output wire        VGA_VS,
        output wire [4:0]  VGA_R,
        output wire [5:0]  VGA_G,
        output wire [4:0]  VGA_B,
        output wire        LED,
        output wire [7:0]  SEG_LED,
        output wire [3:0]  SEG_SEL,      // 4-digit display, one-hot low select
        // 4x4 matrix keypad: P5 filter preset selector (see keypad_4x4.v)
        input  wire [3:0]  key_col,      // KEY_COL, pulled up on the board
        output wire [3:0]  key_row,      // KEY_ROW, one-hot low
        // P6 audio: 1-bit sigma-delta PWM into the board low-pass + amp
        output wire        audio_pwm,
        // P6 microphone ADC (SPI: CS=J6 MISO=K5 SCK=H3 RSTN=G6)
        output wire        adc_cs_n,
        output wire        adc_sck,
        output wire        adc_rst_n,
        input  wire        adc_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480 words
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;

//------------------------------------------------------------------------------
// Reset: both PLL locks + 20ms stability counter (lab_ex4_tf proven scheme,
// generated in the 50MHz input domain, released far from any activity)
//------------------------------------------------------------------------------
wire sys_pll_lock;
wire tx_pll_lock;
// Power-on initial values are REQUIRED: GOWIN registers default to 0,
// and with rst_all_reg starting at 0 the "!rst_all_reg" branch would
// release reset immediately (LED off illusion) before the PLLs ever
// locked -- M0 came up on an unstable clock and ran away. lab_ex4_tf
// declares the same initializers.
reg  [19:0] rst_cnt = 20'd0;
reg         rst_all_reg = 1'b1;

always @(posedge clk) begin
    if (!RSTn) begin
        rst_cnt     <= 20'd0;
        rst_all_reg <= 1'b1;
    end else if (!rst_all_reg) begin
        rst_all_reg <= 1'b0;    // once released, ignore PLL jitter
    end else if (sys_pll_lock && tx_pll_lock) begin
        if (rst_cnt < 20'd1_000_000) begin   // 20ms @ 50MHz
            rst_cnt     <= rst_cnt + 1'b1;
            rst_all_reg <= 1'b1;
        end else begin
            rst_all_reg <= 1'b0;
        end
    end else begin
        rst_cnt     <= 20'd0;
        rst_all_reg <= 1'b1;
    end
end

wire rst_all   = rst_all_reg;      // active high global reset
wire sys_rstn  = ~rst_all;         // for SoC (low active)
wire hdmi_rstn = ~rst_all;         // for hdmi_tx (P0b RST_N style)

//------------------------------------------------------------------------------
// PLLs
//------------------------------------------------------------------------------
wire sys_clk;       // 25MHz
wire mem_clk;       // 125MHz
wire mem_clk_sft;   // 125MHz antiphase
wire pxl_clk;       // 25MHz video
wire pxl_5x;        // 125MHz serializer

sys_pll u_sys_pll (
    .refclk    (clk),
    .reset     (1'b0),
    .extlock   (sys_pll_lock),
    .clk0_out  (sys_clk),
    .clk1_out  (mem_clk),
    .clk2_out  (mem_clk_sft)
);

tx_pll u_tx_pll (
    .refclk    (clk),
    .reset     (1'b0),
    .extlock   (tx_pll_lock),
    .clk0_out  (pxl_clk),
    .clk1_out  (),
    .clk2_out  (pxl_5x)
);

//------------------------------------------------------------------------------
// M0 SoC (P1 base, Port2 = sd_ctrl)
//------------------------------------------------------------------------------
wire        sd_sec_read;
wire [31:0] sd_sec_read_addr;
wire        sd_cmd_pack_reset;
wire [31:0] pixel_offset;
wire [31:0] file_len;
wire        frame_write_req;
wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;
wire        disp_en;
wire        sd_init_done;
wire        sd_reinit;                  // sd_ctrl -> card FSM: card swapped
wire        sd_sec_read_end;
wire        sd_byte_valid;
wire [7:0]  sd_byte_data;
wire        frame_commit_tgl;
wire        wr_req_ack;
wire        dbg_ahb_active;
wire [7:0]  dbg_fw_state;
wire [7:0]  dbg_last_addr;
wire [7:0]  dbg_probe;
wire        stream_active;
wire [31:0] key_cnt;             // 16 x 2-bit key press counters (pxl_clk)
wire [15:0] key_lvl;             // debounced key level, for diagnostics
wire [127:0] spec_h;             // 16 x 8 bit spectrum bar heights (P6)
// firmware 4-hex-digit console (audio_ctrl P4 +0x18 -> 7-segment display)
wire [15:0] fw_disp_val;
wire        fw_disp_en;

CortexM0_SoC u_soc (
        .sys_clk        (sys_clk),
        .sys_rstn       (sys_rstn),
        .RSTn           (RSTn),
        .SWDIO          (SWDIO),
        .SWCLK          (SWCLK),
        .uart_rxd       (uart_rxd),
        .uart_txd       (uart_txd),
        // P6 audio (AHB slave @0x4003_0000, PWM on the raw 50MHz clock)
        .clk_50m        (clk),
        .arst_50m       (rst_all),
        .audio_pwm      (audio_pwm),
        .key_cnt        (key_cnt),
        .key_lvl        (key_lvl),
        .spec_h         (spec_h),
        .adc_cs_n       (adc_cs_n),
        .adc_sck        (adc_sck),
        .adc_rst_n      (adc_rst_n),
        .adc_miso       (adc_miso),
    .dbg_disp_val   (fw_disp_val),
        .dbg_disp_en    (fw_disp_en),
        .sd_sec_read    (sd_sec_read),
        .sd_sec_read_addr(sd_sec_read_addr),
        .sd_cmd_pack_reset(sd_cmd_pack_reset),
        .pixel_offset   (pixel_offset),
        .file_len       (file_len),
        .frame_write_req(frame_write_req),
        .write_buf_idx  (write_buf_idx),
        .disp_buf_idx   (disp_buf_idx),
        .disp_en        (disp_en),
        .stream_active  (stream_active),
        .sd_init_done   (sd_init_done),
        .sd_reinit      (sd_reinit),
        .sd_sec_read_end(sd_sec_read_end),
        .sd_byte_valid  (sd_byte_valid),
        .sd_byte_data   (sd_byte_data),
        .frame_commit_tgl(frame_commit_tgl),
        .wr_req_ack     (wr_req_ack),
        .dbg_ahb_active (dbg_ahb_active),
        .dbg_fw_state   (dbg_fw_state),
        .dbg_last_addr  (dbg_last_addr),
        .dbg_probe      (dbg_probe)
);

//------------------------------------------------------------------------------
// LED diagnostic (all three states timed by the 50MHz input clock, so the
// code stays meaningful even if sys_clk dies; and every state BLINKS, so the
// unknown LED polarity can never mask the message):
//   slow  ~0.7Hz = rst_all still asserted (PLL lock / reset counter problem)
//   medium ~3Hz  = reset released but M0 never drove the AHB (core dead)
//   fast  ~12Hz  = M0 AHB activity seen at least once (sticky latch)
//------------------------------------------------------------------------------
reg [25:0] led_diag_cnt;
always @(posedge clk) led_diag_cnt <= led_diag_cnt + 1'b1;

reg [1:0] ahb_active_sync;
always @(posedge clk) ahb_active_sync <= {ahb_active_sync[0], dbg_ahb_active};

reg ahb_seen = 1'b0;
always @(posedge clk) begin
    if (!rst_all && ahb_active_sync[1])
        ahb_seen <= 1'b1;
end

assign LED = ahb_seen ? led_diag_cnt[21] :
             rst_all  ? led_diag_cnt[25] :
                        led_diag_cnt[23];

//------------------------------------------------------------------------------
// SD card SPI controller (kangxin copy) + BMP packer (25MHz domain)
//------------------------------------------------------------------------------
sd_card_top u_sd_card (
        .clk                    (sys_clk),
        .rst                    (rst_all),
        .sd_reinit              (sd_reinit),
        .SD_nCS                 (SD_nCS),
        .SD_DCLK                (SD_DCLK),
        .SD_MOSI                (SD_MOSI),
        .SD_MISO                (SD_MISO),
        .sd_init_done           (sd_init_done),
        .sd_sec_read            (sd_sec_read),
        .sd_sec_read_addr       (sd_sec_read_addr),
        .sd_sec_read_data       (sd_byte_data),
        .sd_sec_read_data_valid (sd_byte_valid),
        .sd_sec_read_end        (sd_sec_read_end),
        .sd_sec_write           (1'b0),
        .sd_sec_write_addr      (32'd0),
        .sd_sec_write_data      (8'd0),
        .sd_sec_write_data_req  (),
        .sd_sec_write_end       ()
);

wire        pack_we;
wire [31:0] pack_data;

bmp_pack u_bmp_pack (
        .clk          (sys_clk),
        .rst          (rst_all),
        .clear        (sd_cmd_pack_reset),
        .stream_en    (stream_active), // only during STREAM cmds (not RAW)
        .byte_valid   (sd_byte_valid),
        .byte_in      (sd_byte_data),
        .pixel_offset (pixel_offset),
        .file_len     (file_len),
        .we           (pack_we),
        .wdata        (pack_data)
);

//------------------------------------------------------------------------------
// v14 diagnostic: synthesised test frame (bypasses SD streaming + bmp_pack).
// DBG_PAT=1 proves the SDRAM write -> read -> HDMI chain on its own: a smooth
// x/y gradient with hard markers (white left/centre/right columns, blue top
// row, yellow centre row).  DBG_PAT=0 restores the real SD pixel stream.
//------------------------------------------------------------------------------
localparam DBG_PAT = 0;

reg  [18:0] pat_cnt;
reg  [9:0]  pat_x;
reg  [8:0]  pat_y;
reg  [9:0]  pat_wait;
reg  [1:0]  pat_st;
reg  [6:0]  pat_div;

wire pat_tick = (pat_div == 7'd0);          /* 1 in 128 sys_clk ~ 195k words/s */
wire pat_we   = DBG_PAT && (pat_st == 2'd3) && pat_tick;

wire [23:0] pat_pix = (pat_x == 10'd0)   ? 24'hFFFFFF :
                      (pat_y ==  9'd0)   ? 24'h0000FF :
                      (pat_x == 10'd320) ? 24'hFFFFFF :
                      (pat_y ==  9'd240) ? 24'hFFFF00 :
                      (pat_x == 10'd639) ? 24'hFF0000 :
                                           {pat_x[7:0], pat_y[7:0], 8'h00};
wire [31:0] pat_data = {pat_pix, 8'h00};

always @(posedge sys_clk or posedge rst_all) begin
    if (rst_all) begin
        pat_cnt  <= 19'd0;
        pat_x    <= 10'd0;
        pat_y    <=  9'd0;
        pat_wait <= 10'd0;
        pat_st   <=  2'd0;
        pat_div  <=  7'd0;
    end else begin
        pat_div <= pat_div + 1'b1;
        case (pat_st)
        2'd0: begin                       /* idle: reset raster, then kick    */
            pat_cnt <= 19'd0;
            pat_x   <= 10'd0;
            pat_y   <=  9'd0;
            if (pat_wait == 10'd0) begin
                pat_st   <= 2'd1;
                pat_wait <= 10'd4;
            end else
                pat_wait <= pat_wait - 1'b1;
        end
        2'd1: begin                       /* write_req pulse                  */
            if (pat_wait == 10'd0) begin
                pat_st   <= 2'd2;
                pat_wait <= 10'd64;       /* let S_ACK latch len + clear fifo */
            end else
                pat_wait <= pat_wait - 1'b1;
        end
        2'd2: begin
            if (pat_wait == 10'd0)
                pat_st <= 2'd3;
            else
                pat_wait <= pat_wait - 1'b1;
        end
        default: begin                    /* stream exactly 307200 words      */
            if (pat_tick) begin
                pat_cnt <= pat_cnt + 1'b1;
                if (pat_x == 10'd639) begin
                    pat_x <= 10'd0;
                    pat_y <= pat_y + 1'b1;
                end else
                    pat_x <= pat_x + 1'b1;
            end
            if (pat_tick && pat_cnt == 19'd307199) begin
                pat_st   <= 2'd0;
                pat_wait <= 10'd4000;     /* ~160us before the next frame     */
            end
        end
        endcase
    end
end

wire        pat_req  = DBG_PAT && (pat_st == 2'd1);
wire        fwr_req  = DBG_PAT ? pat_req  : frame_write_req;
wire        fwr_en   = DBG_PAT ? pat_we   : pack_we;
wire [31:0] fwr_data = DBG_PAT ? pat_data : pack_data;
wire [1:0]  fwr_idx  = DBG_PAT ? 2'd0     : write_buf_idx;
wire [1:0]  frd_idx  = DBG_PAT ? 2'd0     : disp_buf_idx;
wire        fdisp_en = DBG_PAT ? 1'b1     : disp_en;

//------------------------------------------------------------------------------
// Frame write/read into internal SDRAM (lab_ex4_tf proven chain)
//------------------------------------------------------------------------------
wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;
wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;
wire       frame_write_finish;   // declared before first use (218)

// write_finish -> toggle in mem domain, synced into sys domain for M0
reg frame_write_toggle_mem;
always @(posedge mem_clk or posedge rst_all) begin
    if (rst_all)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

reg [1:0] commit_sync;
always @(posedge sys_clk or posedge rst_all) begin
    if (rst_all)
        commit_sync <= 2'b00;
    else
        commit_sync <= {commit_sync[0], frame_write_toggle_mem};
end
assign frame_commit_tgl = commit_sync[1];

wire video_read_req;
wire video_read_req_ack;
wire video_read_en;
wire [MEM_DATA_BITS-1:0] video_read_data;

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) u_frame_rw (
    .mem_clk          (mem_clk),
    .rst              (rst_all),
    .Sdr_init_done    (Sdr_init_done),
    .Sdr_init_ref_vld (Sdr_init_ref_vld),
    .Sdr_busy         (Sdr_busy),

    .App_rd_en        (App_rd_en),
    .App_rd_addr      (App_rd_addr),
    .Sdr_rd_en        (Sdr_rd_en),
    .Sdr_rd_dout      (Sdr_rd_dout),

    .read_clk         (pxl_clk),
    .read_req         (video_read_req),
    .read_req_ack     (video_read_req_ack),
    .read_finish      (),
    .read_addr_0      (BUF0_ADDR),
    .read_addr_1      (BUF1_ADDR),
    .read_addr_2      (24'd0),
    .read_addr_3      (24'd0),
    .read_addr_index  (frd_idx),
    .read_len         (FRAME_PIXELS),
    .read_en          (video_read_en),
    .read_data        (video_read_data),

    .App_wr_en        (App_wr_en),
    .App_wr_addr      (App_wr_addr),
    .App_wr_din       (App_wr_din),
    .App_wr_dm        (App_wr_dm),

    .write_clk        (sys_clk),
    .write_req        (fwr_req),
    .write_req_ack    (wr_req_ack),
    .write_finish     (frame_write_finish),
    .write_addr_0     (BUF0_ADDR),
    .write_addr_1     (BUF1_ADDR),
    .write_addr_2     (24'd0),
    .write_addr_3     (24'd0),
    .write_addr_index (fwr_idx),
    .write_len        (FRAME_PIXELS),
    .write_en         (fwr_en),
    .write_data       (fwr_data)
);

sdram u_sdram (
    .Clk              (mem_clk),
    .Clk_sft          (mem_clk_sft),
    .Rst              (rst_all),
    .Sdr_init_done    (Sdr_init_done),
    .Sdr_init_ref_vld (Sdr_init_ref_vld),
    .Sdr_busy         (Sdr_busy),
    .App_wr_en        (App_wr_en),
    .App_wr_addr      (App_wr_addr),
    .App_wr_dm        (App_wr_dm),
    .App_wr_din       (App_wr_din),
    .App_rd_en        (App_rd_en),
    .App_rd_addr      (App_rd_addr),
    .Sdr_rd_en        (Sdr_rd_en),
    .Sdr_rd_dout      (Sdr_rd_dout)
);

//------------------------------------------------------------------------------
// Video readout + HDMI output (P0b proven tx chain, TPG removed)
//------------------------------------------------------------------------------
wire hs_0, vs_0, de_0;
wire VGA_DE;                // declared before video_delay port use
wire [23:0] vout_raw;
wire        vd_hs;          // hs/vs out of video_delay, aligned with vout_raw
wire        vd_vs;

video_timing_data u_video_timing (
    .video_clk    (pxl_clk),
    .rst          (rst_all),
    .read_req     (video_read_req),
    .read_req_ack (video_read_req_ack),
    .hs           (hs_0),
    .vs           (vs_0),
    .de           (de_0)
);

video_delay u_video_delay (
    .video_clk  (pxl_clk),
    .rst        (rst_all),
    .read_en    (video_read_en),
    .read_data  (video_read_data[31:8]),
    .hs         (hs_0),
    .vs         (vs_0),
    .de         (de_0),
    .hs_r       (vd_hs),        // v13+: registered here, exported after the ISP
    .vs_r       (vd_vs),
    .de_r       (VGA_DE),
    .vout_data  (vout_raw)
);

//------------------------------------------------------------------------------
// P5 ISP filter: 3x3 colour matrix + offset, six presets, switched from the
// 4x4 keypad. One pixel per pixel clock, one cycle of latency, and hs/vs/de
// travel with the same single register so the sync stays on the pixel it
// belongs to.  Placed between the SDRAM readout and the HDMI transmitter, so
// the filter also applies to the debug bars (harmless: they are pure B/W).
//------------------------------------------------------------------------------
wire [2:0]  isp_mode;
wire [23:0] isp_px;
wire        isp_de;
wire        isp_hs;
wire        isp_vs;

isp_filter u_isp_filter (
    .clk  (pxl_clk),
    .rst  (rst_all),
    .mode (isp_mode),
    .px_i (vout_raw),
    .de_i (VGA_DE),
    .hs_i (vd_hs),
    .vs_i (vd_vs),
    .px_o (isp_px),
    .de_o (isp_de),
    .hs_o (isp_hs),
    .vs_o (isp_vs)
);

keypad_4x4 u_keypad (
    .clk       (pxl_clk),
    .rst       (rst_all),
    .col       (key_col),
    .row       (key_row),
    .key_down  (key_lvl),
    .ev_cnt    (key_cnt),
    .key_event (),
    .mode_r    (isp_mode)        // preset advances on every new key press
);

// DEBUG status readout on the proven HDMI monitor: 8 vertical bands of 80px,
// band i = white when status bit i (seg_code[i]) is set, black when clear.
// bit0 leftmost ... bit7 rightmost. bit3 (live AHB activity) will flicker.
// Set DBG_BARS=0 to restore the normal SDRAM picture path.


localparam DBG_BARS = 1;

reg [9:0] dbg_hcnt;
reg [2:0] dbg_band;
always @(posedge pxl_clk or posedge rst_all) begin
    if (rst_all) begin
        dbg_hcnt <= 10'd0;
        dbg_band <= 3'd0;
    end else if (VGA_DE) begin
        if (dbg_hcnt == 10'd79) begin
            dbg_hcnt <= 10'd0;
            if (dbg_band != 3'd7)
                dbg_band <= dbg_band + 1'b1;
        end else begin
            dbg_hcnt <= dbg_hcnt + 1'b1;
        end
    end else begin
        dbg_hcnt <= 10'd0;
        dbg_band <= 3'd0;
    end
end

//------------------------------------------------------------------------------
// v12 STREAM PROGRESS BAR (band i on screen = bit i-1, bit0 = leftmost band):
//   [0] >=1 packed pixel word      [1] >=32K    [2] >=128K   [3] >=256K
//   [4] >=307200 = one whole frame packed: the SD stream pushed all 921600
//       BMP bytes through bmp_pack
//   [5] frame_commit_tgl = hardware finished writing a full frame into SDRAM
//   [6] disp_en = M0 committed a picture (CTRL bit5)
//   [7] ~0.75Hz alive marker (blinks on every build => identifies v12)
// v11 already proved SDRAM init, read bursts, read-data return and the video
// readout are alive, and that disp_en NEVER sets. So this build measures how
// far the SD -> SDRAM stream gets: a bar freezing mid-way means the M0 stalled
// inside the sector streaming loop; a full bar with [6] dark means it stalled
// in the commit handshake instead.
//------------------------------------------------------------------------------
reg [18:0] pack_cnt;
reg [1:0]  fwr_q;
always @(posedge sys_clk or posedge rst_all) begin
    if (rst_all) begin
        pack_cnt <= 19'd0;
        fwr_q    <= 2'b00;
    end else begin
        fwr_q <= {fwr_q[0], frame_write_req};
        if (fwr_q[1] == 1'b0 && frame_write_req == 1'b1)
            pack_cnt <= 19'd1;               // new frame -> restart the bar
        else if (pack_we)
            pack_cnt <= pack_cnt + 1'b1;
    end
end

reg [18:0] pack_s0, pack_s1;
reg [1:0]  den_q, cmt_q;
reg [25:0] alive_cnt;
always @(posedge pxl_clk or posedge rst_all) begin
    if (rst_all) begin
        pack_s0   <= 19'd0;
        pack_s1   <= 19'd0;
        den_q     <= 2'b00;
        cmt_q     <= 2'b00;
        alive_cnt <= 26'd0;
    end else begin
        pack_s0   <= pack_cnt;
        pack_s1   <= pack_s0;
        den_q     <= {den_q[0], disp_en};
        cmt_q     <= {cmt_q[0], frame_commit_tgl};
        alive_cnt <= alive_cnt + 1'b1;
    end
end

wire [7:0] pipe_stat = {alive_cnt[25], den_q[1], cmt_q[1],
                        (pack_s1 >= 19'd307200), (pack_s1 >= 19'd262144),
                        (pack_s1 >= 19'd131072), (pack_s1 >= 19'd32768),
                        (pack_s1 >= 19'd1)};

wire [7:0] dbg_bars_word = pipe_stat;
wire dbg_on = (dbg_bars_word >> dbg_band) & 8'd1;
wire [23:0] dbg_pixel = dbg_on ? 24'hFFFFFF : 24'h000000;

// v13: bands stay up until M0 commits the first frame (disp_en), then the real
// SDRAM picture takes over.  Kept as the fallback view: if the screen still
// shows bars, the probe byte in them says exactly how far the pipeline got.
wire bars_mode = DBG_BARS & ~DBG_PAT & ~den_q[1];

//------------------------------------------------------------------------------
// P6: 16 band spectrum bars overlaid on the picture.
//
// Two pixel counters run on the ISP's own de/hs/vs (already one clock late and
// already compensated downstream), so the overlay is in the same clock domain
// and the same timing reference as isp_px - no extra latency to chase.
//
// Geometry: 64 px left margin, 8 bars of 64 px pitch, 54 px wide, 10 px gap.
// Height comes straight from spectrum_bank's 8 bit value (0..255 px tall,
// growing upwards from y = 479).
//------------------------------------------------------------------------------
reg  [127:0] spec_s0, spec_s1;          // 2FF into the pixel clock domain
reg  [9:0]   ovf_x, ovf_y;              // pixel coordinates
reg  [23:0]  spec_px;
reg          spec_on;

wire [9:0]   ovf_xm  = ovf_x - 10'd64;               // >= 64 guaranteed below
wire [2:0]   ovf_idx = ovf_xm[8:6];                  // /64: 8 bars
wire [5:0]   ovf_bin = ovf_xm[5:0];                  // position inside a bar
wire [7:0]   ovf_h   = spec_s1[8*ovf_idx +: 8];      // this bar's height

always @(posedge pxl_clk or posedge rst_all) begin
    if (rst_all) begin
        spec_s0  <= 128'd0;
        spec_s1  <= 128'd0;
        ovf_x    <= 10'd0;
        ovf_y    <= 10'd0;
        spec_px  <= 24'd0;
        spec_on  <= 1'b0;
    end else begin
        spec_s0 <= spec_h;
        spec_s1 <= spec_s0;

        if (isp_de) begin
            if (ovf_x == 10'd639) begin
                ovf_x <= 10'd0;
                ovf_y <= (ovf_y == 10'd479) ? 10'd0 : ovf_y + 10'd1;
            end else begin
                ovf_x <= ovf_x + 10'd1;
            end
        end

        spec_on <= 1'b0;
        // halve each colour channel separately - a whole word >> 1 would carry the
        // blue LSB into green and turn the wash into colour noise
        spec_px <= {1'b0, isp_px[23:17], 1'b0, isp_px[15:9], 1'b0, isp_px[7:1]} + 24'h10647F;
        if (isp_de && (ovf_x >= 10'd64) && (ovf_x < 10'd576) && (ovf_bin < 6'd54)) begin
            if (ovf_h != 8'd0 && (ovf_y >= (10'd480 - {2'd0, ovf_h}))) begin
                spec_on <= 1'b1;
                if (ovf_y < (10'd482 - {2'd0, ovf_h}))
                    spec_px <= {1'b0, isp_px[23:17], 1'b0, isp_px[15:9], 1'b0, isp_px[7:1]} + 24'h7F7F7F;
            end
        end
    end
end

wire [23:0] vout_data = bars_mode ? dbg_pixel
                      : (spec_on  ? spec_px
                      : (fdisp_en ? isp_px : 24'd0));

assign VGA_R = vout_data[23:19];
assign VGA_G = vout_data[15:10];
assign VGA_B = vout_data[7:3];

assign VGA_HS = isp_hs;     // one cycle of ISP latency, already compensated
assign VGA_VS = isp_vs;

hdmi_tx #(.FAMILY("EG4")) u_hdmi_tx (
        .PXLCLK_I   (pxl_clk),
        .PXLCLK_5X_I(pxl_5x),
        .RST_N      (hdmi_rstn),
        .VGA_HS     (isp_hs),
        .VGA_VS     (isp_vs),
        .VGA_DE     (isp_de),
        .VGA_RGB    (vout_data),
        .HDMI_CLK_P (HDMI_CLK_P),
        .HDMI_D2_P  (HDMI_D2_P),
        .HDMI_D1_P  (HDMI_D1_P),
        .HDMI_D0_P  (HDMI_D0_P)
);

//------------------------------------------------------------------------------
// SEG_LED[7:0] = firmware milestone register (dbg_fw_state, written via AHB
// P3 @0x4002_0000), shown on the digit pins and the HDMI status bands:
//   [0] reached main   [1] uart_init done   [2] banner printed
//   [3] SD wait loop   [4] SD init done     [5] exFAT mounted
//   [6] a frame played [7] main-loop heartbeat (flickers when alive)
// dbg_last_addr (bits [13:6] of the last AHB xfer) is still captured.
//------------------------------------------------------------------------------
// P5: the 4-digit display shows the active ISP preset (0 = original .. 5 = invert)
// so the keypad can be verified without a serial console.
seg_display u_seg_display (
    .clk  (pxl_clk),
    .rst  (rst_all),
    .num  ({1'b0, isp_mode}),
    .ext_en  (fw_disp_en),
    .ext_val (fw_disp_val),
    .seg  (SEG_LED),
    .sel  (SEG_SEL)
);

endmodule
