//------------------------------------------------------------------------------
// sd_ctrl.v -- AHB-Lite slave for P2 SD card display chain (M0 command iface)
//
// AHB base 0x4001_0000 (Decoder Port2). All logic runs in the 25MHz SoC clock
// domain = SD chain domain, so the M0 command path needs no CDC.
//
// Reg map (offset, name, R/W):
//   0x00 CTRL     W: [0]RAW_READ [1]STREAM [2]PACK_RESET [3]FRAME_START
//                    [4]BUF_TOGGLE (swap write buffer) [5]COMMIT [6]DISP_EN
//   0x04 STATUS   R: [0]sd_init_done [1]hw_busy [2]raw_done [3]stream_tgl
//                    [4]commit_tgl [5]wr_pending
//   0x08 SEC_ADDR W: 32bit sector address (write before command)
//   0x0C RAW_DATA R: raw sector byte port, pointer auto-increments (512 max)
//   0x10 PIXEL_OFFSET W: BMP pixel data start offset within file (typ 54)
//   0x14 FILE_LEN     W: BMP file length in bytes (pack window end)
//
// Sector engine: one command reads exactly one sector.
//   IDLE: accept RAW_READ/STREAM if idle -> BUSY, sd_sec_read=1
//   BUSY: wait sec_end -> raw_done=1 (RAW) or stream_tgl toggles (STREAM)
// RAW bytes are captured into the 512B raw_mem; STREAM bytes pass through
// (stream_active gates bmp_pack), so the packer never sees RAW traffic.
//------------------------------------------------------------------------------
module sd_ctrl (
    input  wire        HCLK,
    input  wire        HRESETn,
    // AHB-Lite slave (from Interconnect Port2)
    input  wire        HSEL,
    input  wire [31:0] HADDR,
    input  wire [1:0]  HTRANS,
    input  wire        HWRITE,
    input  wire [31:0] HWDATA,
    input  wire        HREADY,
    output wire        HREADYOUT,
    output wire        HRESP,
    output reg  [31:0] HRDATA,
    // to sd_card_top (same clock domain)
    output wire        sd_sec_read,
    output wire [31:0] sd_sec_read_addr,
    input  wire        sec_end,
    // packer parameters / control
    output wire [31:0] pixel_offset,
    output wire [31:0] file_len,
    output reg         pack_reset,
    output wire        stream_active,  // gates bmp_pack during STREAM cmds
    // frame write session + buffer management
    output wire        frame_write_req,
    input  wire        wr_req_ack,
    output wire [1:0]  write_buf_idx,
    output wire [1:0]  disp_buf_idx,
    output wire        disp_en,
    // transition effect control (0x18): mode[2:0], dark
    output wire [2:0]  fx_mode,
    output wire        fx_dark,
    output wire [1:0]  fx_amb,      // 0 = off, 1 = ripple, 2 = light sweep
    // status / data from the SD chain
    input  wire        sd_init_done,
    // Asserted for ~1.3ms when a sector transfer has been stuck for ~20ms.
    // The board has no card-detect pin, so this is how a card that was pulled
    // or swapped while powered gets noticed: the card FSM restarts its init.
    output wire        sd_reinit,
    input  wire        frame_commit_tgl,
    input  wire        raw_byte_valid,   // sd_card_top data stream, 1 cyc/byte
    input  wire [7:0]  raw_byte_data
);

    assign HREADYOUT = 1'b1;
    assign HRESP     = 1'b0;

    //------------------------------------------------------------------
    // Address phase strobes
    //------------------------------------------------------------------
    // Address-phase strobes. AHBLite pipelines HADDR: during the data phase
    // HADDR already shows the NEXT transfer, so combinational decode both
    // mis-aims the write strobes (HWDATA is only valid in the data phase)
    // and the read mux whenever accesses interleave. Latch the decode at the
    // end of the address phase, exactly like AHBlite_Block_RAM's addr_reg.
    wire       sel_wr   = HSEL & HTRANS[1] &  HWRITE & HREADY;
    wire       sel_rd   = HSEL & HTRANS[1] & ~HWRITE & HREADY;
    wire [2:0] reg_sel  = HADDR[4:2];     // 0x00..0x14 -> 0..5

    reg        wr_strobe_q;
    reg [2:0]  reg_sel_q;
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            wr_strobe_q <= 1'b0;
            reg_sel_q   <= 3'd0;
        end else if (HREADY) begin
            wr_strobe_q <= HSEL & HTRANS[1] & HWRITE;
            reg_sel_q   <= HADDR[4:2];
        end
    end

    // data-phase-qualified write strobes (HWDATA valid when these are high)
    wire wr_ctrl    = wr_strobe_q & (reg_sel_q == 3'd0);
    wire wr_secaddr = wr_strobe_q & (reg_sel_q == 3'd2);
    // RAW_DATA read pointer: must advance on the DATA phase of the read, i.e.
    // on the cycle in which the byte is actually handed to the master (this
    // core samples HRDATA in the data phase -- see AHBlite_SlaveMUX's
    // registered hsel_reg and Block_RAM's registered doutb).  Advancing it in
    // the address phase made every read return the *next* byte, so a sector
    // came back rotated by one -- exFAT mount then died on the "EXFAT "
    // signature at step 3 and every BMP failed the "BM" header test.
    reg  rd_data_q;                                  // read data-phase pulse
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) rd_data_q <= 1'b0;
        else          rd_data_q <= sel_rd;
    end
    wire rd_rawdata = rd_data_q & (reg_sel_q == 3'd3);
    wire wr_pxoff   = wr_strobe_q & (reg_sel_q == 3'd4);
    wire wr_filelen = wr_strobe_q & (reg_sel_q == 3'd5);

    //------------------------------------------------------------------
    // Parameter registers
    //------------------------------------------------------------------
    reg  [31:0] sec_addr_q;
    reg  [31:0] pixel_offset_q;
    reg  [31:0] file_len_q;
    assign sd_sec_read_addr = sec_addr_q;
    assign pixel_offset     = pixel_offset_q;
    assign file_len         = file_len_q;

    //------------------------------------------------------------------
    // Transition effect control (write-only, 0x18)
    //   [2:0] mode  0 none / 1 dip to black / 2 wipe / 3 blinds / 4 flash
    //   [3]   dark  1 = fade the picture out, 0 = fade back in
    // The pixel stage ramps a coefficient toward the requested end, so the M0
    // only has to raise `dark` before the commit and lower it afterwards.
    //------------------------------------------------------------------
    wire        wr_fx = wr_strobe_q & (reg_sel_q == 3'd6);
    reg  [5:0]  fx_q;
    assign fx_mode = fx_q[2:0];
    assign fx_dark = fx_q[3];
    assign fx_amb  = fx_q[5:4];

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            sec_addr_q     <= 32'd0;
            pixel_offset_q <= 32'd54;
            file_len_q     <= 32'd0;
            fx_q           <= 6'd16;   // ripple layer on by default
        end else begin
            if (wr_secaddr) sec_addr_q     <= HWDATA;
            if (wr_pxoff)   pixel_offset_q <= HWDATA;
            if (wr_filelen) file_len_q     <= HWDATA;
            if (wr_fx)      fx_q           <= HWDATA[5:0];
        end
    end

    //------------------------------------------------------------------
    // Stuck-transfer watchdog -> card re-initialisation (hot plug)
    //   A normal sector read takes ~2ms; the S_CMD17 state retries forever
    //   when the card answers badly or is not there at all.  After ~21ms of
    //   hw_busy we abort the transfer (the firmware then sees its timeout)
    //   and pulse sd_reinit for ~1.3ms so the card FSM re-runs CMD0..CMD16.
    //------------------------------------------------------------------
    reg [19:0] busy_tmr;
    reg [15:0] hold_tmr;
    reg        reinit_q;

    assign sd_reinit = reinit_q;

    //------------------------------------------------------------------
    // Sector engine
    //------------------------------------------------------------------
    localparam S_IDLE = 1'b0;
    localparam S_BUSY = 1'b1;

    reg  state;
    reg  mode_raw;
    reg  raw_done_q;
    reg  stream_tgl_q;
    reg  hw_busy_prev;

    wire idle        = (state == S_IDLE);
    wire hw_busy     = (state == S_BUSY);
    wire cmd_raw     = wr_ctrl & HWDATA[0];
    wire cmd_stream  = wr_ctrl & HWDATA[1];

    assign sd_sec_read  = hw_busy;
    assign stream_active = hw_busy & ~mode_raw;

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            state        <= S_IDLE;
            mode_raw     <= 1'b0;
            raw_done_q   <= 1'b0;
            stream_tgl_q <= 1'b0;
        end else if (reinit_q) begin
            // card gone / swapped: abort, so the firmware sees its timeout
            // instead of waiting forever on a transfer that cannot finish
            state      <= S_IDLE;
            raw_done_q <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (cmd_raw & ~hw_busy_prev) begin
                        mode_raw   <= 1'b1;
                        raw_done_q <= 1'b0;
                        state      <= S_BUSY;
                    end else if (cmd_stream & ~hw_busy_prev) begin
                        mode_raw   <= 1'b0;
                        raw_done_q <= 1'b0;
                        state      <= S_BUSY;
                    end
                end
                S_BUSY: begin
                    if (sec_end) begin
                        state <= S_IDLE;
                        if (mode_raw)
                            raw_done_q <= 1'b1;
                        else
                            stream_tgl_q <= ~stream_tgl_q;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // one-cycle delay so a CTRL write in the same cycle as S_BUSY exit
    // (edge case) cannot double-trigger; also holds during BUSY entry cycle
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn)
            hw_busy_prev <= 1'b0;
        else
            hw_busy_prev <= hw_busy;
    end

    // watchdog itself: needs hw_busy, so it lives after the engine
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            busy_tmr <= 20'd0;
            hold_tmr <= 16'd0;
            reinit_q <= 1'b0;
        end else if (reinit_q) begin
            hold_tmr <= hold_tmr + 16'd1;
            if (hold_tmr[15])
                reinit_q <= 1'b0;
        end else if (!hw_busy) begin
            busy_tmr <= 20'd0;
            hold_tmr <= 16'd0;
        end else if (!busy_tmr[19]) begin
            busy_tmr <= busy_tmr + 20'd1;
        end else begin
            busy_tmr <= 20'd0;
            hold_tmr <= 16'd0;
            reinit_q <= 1'b1;
        end
    end

    //------------------------------------------------------------------
    // Raw sector buffer (512 x 8), comb read port with auto-increment ptr
    // NOTE: raw_wp / raw_rp / raw_mem are driven from THIS block only
    // (single-driver requirement, HDL-8007).
    //------------------------------------------------------------------
    reg [7:0] raw_mem [0:511];
    reg [8:0] raw_wp;
    reg [8:0] raw_rp;

    wire raw_capture = hw_busy & mode_raw & raw_byte_valid;
    wire raw_arm     = wr_ctrl & HWDATA[2];              // PACK_RESET
    wire raw_new     = cmd_raw & idle & ~hw_busy_prev;   // fresh RAW_READ

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            raw_wp     <= 9'd0;
            raw_rp     <= 9'd0;
            pack_reset <= 1'b0;
        end else begin
            pack_reset <= 1'b0;
            if (raw_arm) begin               // new file session
                raw_wp     <= 9'd0;
                raw_rp     <= 9'd0;
                pack_reset <= 1'b1;
            end else if (raw_new) begin      // new raw sector command
                raw_wp <= 9'd0;
                raw_rp <= 9'd0;
            end else begin
                if (raw_capture) begin
                    raw_mem[raw_wp] <= raw_byte_data;
                    raw_wp <= raw_wp + 9'd1;
                end
                if (rd_rawdata)
                    raw_rp <= raw_rp + 9'd1;
            end
        end
    end

    wire [7:0] raw_rdata = raw_mem[raw_rp];

    //------------------------------------------------------------------
    // Frame write session + buffer/display control
    //------------------------------------------------------------------
    reg        frame_req_q;
    reg        buf_sel_q;
    reg  [1:0] disp_buf_q;
    reg        disp_en_q;

    assign frame_write_req = frame_req_q;
    assign write_buf_idx   = {1'b0, buf_sel_q};
    assign disp_buf_idx    = disp_buf_q;
    assign disp_en         = disp_en_q;

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            frame_req_q <= 1'b0;
            buf_sel_q   <= 1'b0;
            disp_buf_q  <= 2'd0;
            disp_en_q   <= 1'b0;
        end else begin
            if (frame_req_q & wr_req_ack)
                frame_req_q <= 1'b0;
            if (wr_ctrl) begin
                if (HWDATA[3]) frame_req_q <= 1'b1;
                if (HWDATA[4]) buf_sel_q   <= ~buf_sel_q;
                if (HWDATA[5]) begin
                    disp_buf_q <= {1'b0, buf_sel_q};
                    disp_en_q  <= 1'b1;
                end
                if (HWDATA[6])
                    disp_en_q <= 1'b0;    // explicit DISP_EN command hides picture
            end
        end
    end

    //------------------------------------------------------------------
    // Read data mux (registered index -> data-phase aligned, like the
    // Block_RAM sync-read latency the zero-wait timing expects)
    //------------------------------------------------------------------
    always @(*) begin
        case (reg_sel_q)
            3'd1:    HRDATA = {26'd0, frame_req_q, frame_commit_tgl,
                               stream_tgl_q, raw_done_q, hw_busy,
                               sd_init_done};
            3'd3:    HRDATA = {24'd0, raw_rdata};
            3'd6:    HRDATA = {26'd0, fx_q};          /* +0x18 transition fx   */
            default: HRDATA = 32'd0;
        endcase
    end

endmodule
