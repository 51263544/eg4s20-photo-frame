
module CortexM0_SoC (
        input  wire  sys_clk,    // 25MHz from top-level sys_pll C0 (P2: shared with SD chain)
        input  wire  sys_rstn,   // RSTn & pll extlock, done at top level
        input  wire  RSTn,       // raw reset key, P1-proven POR/DBG reset source
        inout  wire  SWDIO,
        input  wire  SWCLK,
        input  wire  uart_rxd,   // FPGA receive, board T7 <- CH340 TXD
        output wire  uart_txd,   // FPGA transmit, board T8 -> CH340 RXD
        // P6 audio: AHB slave @0x4003_0000 (25MHz face) + sigma-delta PWM (50MHz)
        input  wire  clk_50m,    // raw board clock, audio PWM carrier domain
        input  wire  arst_50m,   // active high reset for the 50MHz domain
        output wire  audio_pwm,  // AUDIO_PWM (board pin F3)

output wire [15:0] dbg_disp_val, // 7-segment hex value written by firmware
output wire        dbg_disp_en,  // 1 = firmware owns the 7-segment display

        input  wire [31:0] key_cnt,   // P6: 16 x 2-bit key press counters
    input  wire [15:0] key_lvl,   // P6: debounced key level (0x40030020[31:16])
    output wire [127:0] spec_h,   // P6: 16 band spectrum bar heights
        // P6 microphone ADC (SPI: CS=J6 MISO=K5 SCK=H3 RSTN=G6)
        output wire  adc_cs_n,
        output wire  adc_sck,
        output wire  adc_rst_n,
        input  wire  adc_miso,
        // P2 SD display chain: sd_ctrl register face (all 25MHz domain)
        output wire         sd_sec_read,
        output wire [31:0]  sd_sec_read_addr,
        output wire         sd_cmd_pack_reset,
        output wire [31:0]  pixel_offset,
        output wire [31:0]  file_len,
        output wire         frame_write_req,
        output wire [1:0]   write_buf_idx,
        output wire [1:0]   disp_buf_idx,
        output wire         disp_en,
        output wire         stream_active, // SD byte stream is a live STREAM command
        input  wire         sd_init_done,
        output wire         sd_reinit,     // P7: restart SD init (card swapped live)
        input  wire         sd_sec_read_end,
        input  wire         sd_byte_valid,
        input  wire [7:0]   sd_byte_data,
        input  wire         frame_commit_tgl,
        input  wire         wr_req_ack,
        output wire         dbg_ahb_active,  // M0 issuing a transfer (HTRANS != IDLE)
        output reg  [7:0]   dbg_fw_state,    // fw milestone reg (P3 @0x4002_0000)
        output reg  [7:0]   dbg_last_addr,   // addr bits [13:6] of last completed AHB xfer
        output reg  [7:0]   dbg_probe        // composite startup diagnostic, see below
);

//------------------------------------------------------------------------------
// P2 SoC = P1 SoC with Port2 enabled for sd_ctrl. Clock comes from the shared
// sys_pll (25MHz), so M0 command path to the SD chain has zero CDC.
//------------------------------------------------------------------------------
// DEBUG IOBUF
//------------------------------------------------------------------------------

wire SWDO;
wire SWDOEN;
wire SWDI;

assign SWDI = SWDIO;
assign SWDIO = (SWDOEN) ?  SWDO : 1'bz;

//------------------------------------------------------------------------------
// Interrupt
//------------------------------------------------------------------------------

wire [31:0] IRQ;
wire uart_irq;
// IRQ[0] = AHB UART rx-not-empty interrupt
assign IRQ = {31'b0, uart_irq};

wire RXEV;
assign RXEV = 1'b0;

//------------------------------------------------------------------------------
// AHB
//------------------------------------------------------------------------------

wire [31:0] HADDR;
wire [ 2:0] HBURST;
wire        HMASTLOCK;
wire [ 3:0] HPROT;
wire [ 2:0] HSIZE;
wire [ 1:0] HTRANS;
wire [31:0] HWDATA;
wire        HWRITE;
wire [31:0] HRDATA;
wire        HRESP;
wire        HMASTER;
wire        HREADY;

// M0 fetches instructions continuously, so HTRANS[1] (NONSEQ/SEQ) toggles at
// a high duty cycle whenever the core is executing out of RAMCODE.
assign dbg_ahb_active = HTRANS[1];

//------------------------------------------------------------------------------
// RESET AND DEBUG
//------------------------------------------------------------------------------

wire SYSRESETREQ;
reg cpuresetn;

always @(posedge sys_clk or negedge sys_rstn)begin
        if (~sys_rstn) cpuresetn <= 1'b0;
        else if (SYSRESETREQ) cpuresetn <= 1'b0;
        else cpuresetn <= 1'b1;    // sys_rstn already gated by PLL extlock at top
end

wire CDBGPWRUPREQ;
reg CDBGPWRUPACK;

always @(posedge sys_clk or negedge RSTn)begin
        if (~RSTn) CDBGPWRUPACK <= 1'b0;
        else CDBGPWRUPACK <= CDBGPWRUPREQ;
end


//------------------------------------------------------------------------------
// Instantiate Cortex-M0 processor logic level
//------------------------------------------------------------------------------

cortexm0ds_logic u_logic (

        // System inputs
        .FCLK           (sys_clk),       //FREE running clock
        .SCLK           (sys_clk),       //system clock
        .HCLK           (sys_clk),       //AHB clock
        .DCLK           (sys_clk),       //Debug clock
        .PORESETn       (RSTn),          //Power on reset (P1-proven: raw key, independent of PLL)
        .HRESETn        (cpuresetn),     //AHB and System reset
        .DBGRESETn      (RSTn),          //Debug Reset (P1-proven: raw key)
        .RSTBYPASS      (1'b0),          //Reset bypass
        .SE             (1'b0),          // dummy scan enable port for synthesis

        // Power management inputs
        .SLEEPHOLDREQn  (1'b1),          // Sleep extension request from PMU
        .WICENREQ       (1'b0),          // WIC enable request from PMU
        .CDBGPWRUPACK   (CDBGPWRUPACK),  // Debug Power Up ACK from PMU

        // Power management outputs
        .CDBGPWRUPREQ   (CDBGPWRUPREQ),
        .SYSRESETREQ    (SYSRESETREQ),

        // System bus
        .HADDR          (HADDR[31:0]),
        .HTRANS         (HTRANS[1:0]),
        .HSIZE          (HSIZE[2:0]),
        .HBURST         (HBURST[2:0]),
        .HPROT          (HPROT[3:0]),
        .HMASTER        (HMASTER),
        .HMASTLOCK      (HMASTLOCK),
        .HWRITE         (HWRITE),
        .HWDATA         (HWDATA[31:0]),
        .HRDATA         (HRDATA[31:0]),
        .HREADY         (HREADY),
        .HRESP          (HRESP),

        // Interrupts
        .IRQ            (IRQ),          //Interrupt
        .NMI            (1'b0),         //Watch dog interrupt
        .IRQLATENCY     (8'h0),
        .ECOREVNUM      (28'h0),

        // Systick
        .STCLKEN        (1'b0),
        .STCALIB        (26'h0),

        // Debug - JTAG or Serial wire
        // Inputs
        .nTRST          (1'b1),
        .SWDITMS        (SWDI),
        .SWCLKTCK       (SWCLK),
        .TDI            (1'b0),
        // Outputs
        .SWDO           (SWDO),
        .SWDOEN         (SWDOEN),

        .DBGRESTART     (1'b0),

        // Event communication
        .RXEV           (RXEV),         // Generate event when a DMA operation completed.
        .EDBGRQ         (1'b0)          // multi-core synchronous halt request
);

//------------------------------------------------------------------------------
// AHBlite Interconncet
//------------------------------------------------------------------------------

wire            HSEL_P0;
wire    [31:0]  HADDR_P0;
wire    [2:0]   HBURST_P0;
wire            HMASTLOCK_P0;
wire    [3:0]   HPROT_P0;
wire    [2:0]   HSIZE_P0;
wire    [1:0]   HTRANS_P0;
wire    [31:0]  HWDATA_P0;
wire            HWRITE_P0;
wire            HREADY_P0;
wire            HREADYOUT_P0;
wire    [31:0]  HRDATA_P0;
wire            HRESP_P0;

wire            HSEL_P1;
wire    [31:0]  HADDR_P1;
wire    [2:0]   HBURST_P1;
wire            HMASTLOCK_P1;
wire    [3:0]   HPROT_P1;
wire    [2:0]   HSIZE_P1;
wire    [1:0]   HTRANS_P1;
wire    [31:0]  HWDATA_P1;
wire            HWRITE_P1;
wire            HREADY_P1;
wire            HREADYOUT_P1;
wire    [31:0]  HRDATA_P1;
wire            HRESP_P1;

wire            HSEL_P2;
wire    [31:0]  HADDR_P2;
wire    [2:0]   HBURST_P2;
wire            HMASTLOCK_P2;
wire    [3:0]   HPROT_P2;
wire    [2:0]   HSIZE_P2;
wire    [1:0]   HTRANS_P2;
wire    [31:0]  HWDATA_P2;
wire            HWRITE_P2;
wire            HREADY_P2;
wire            HREADYOUT_P2;
wire    [31:0]  HRDATA_P2;
wire            HRESP_P2;

wire            HSEL_P3;
wire    [31:0]  HADDR_P3;
wire    [2:0]   HBURST_P3;
wire            HMASTLOCK_P3;
wire    [3:0]   HPROT_P3;
wire    [2:0]   HSIZE_P3;
wire    [1:0]   HTRANS_P3;
wire    [31:0]  HWDATA_P3;
wire            HWRITE_P3;
wire            HREADY_P3;
wire            HREADYOUT_P3;
wire    [31:0]  HRDATA_P3;
wire            HRESP_P3;

wire            HSEL_P4;
wire    [31:0]  HADDR_P4;
wire    [2:0]   HBURST_P4;
wire            HMASTLOCK_P4;
wire    [3:0]   HPROT_P4;
wire    [2:0]   HSIZE_P4;
wire    [1:0]   HTRANS_P4;
wire    [31:0]  HWDATA_P4;
wire            HWRITE_P4;
wire            HREADY_P4;
wire            HREADYOUT_P4;
wire    [31:0]  HRDATA_P4;
wire            HRESP_P4;

AHBlite_Interconnect Interconncet(
        .HCLK           (sys_clk),
        .HRESETn        (cpuresetn),

        // CORE SIDE
        .HADDR          (HADDR),
        .HTRANS         (HTRANS),
        .HSIZE          (HSIZE),
        .HBURST         (HBURST),
        .HPROT          (HPROT),
        .HMASTLOCK      (HMASTLOCK),
        .HWRITE         (HWRITE),
        .HWDATA         (HWDATA),
        .HRDATA         (HRDATA),
        .HREADY         (HREADY),
        .HRESP          (HRESP),

        // P0
        .HSEL_P0        (HSEL_P0),
        .HADDR_P0       (HADDR_P0),
        .HBURST_P0      (HBURST_P0),
        .HMASTLOCK_P0   (HMASTLOCK_P0),
        .HPROT_P0       (HPROT_P0),
        .HSIZE_P0       (HSIZE_P0),
        .HTRANS_P0      (HTRANS_P0),
        .HWDATA_P0      (HWDATA_P0),
        .HWRITE_P0      (HWRITE_P0),
        .HREADY_P0      (HREADY_P0),
        .HREADYOUT_P0   (HREADYOUT_P0),
        .HRDATA_P0      (HRDATA_P0),
        .HRESP_P0       (HRESP_P0),

        // P1
        .HSEL_P1        (HSEL_P1),
        .HADDR_P1       (HADDR_P1),
        .HBURST_P1      (HBURST_P1),
        .HMASTLOCK_P1   (HMASTLOCK_P1),
        .HPROT_P1       (HPROT_P1),
        .HSIZE_P1       (HSIZE_P1),
        .HTRANS_P1      (HTRANS_P1),
        .HWDATA_P1      (HWDATA_P1),
        .HWRITE_P1      (HWRITE_P1),
        .HREADY_P1      (HREADY_P1),
        .HREADYOUT_P1   (HREADYOUT_P1),
        .HRDATA_P1      (HRDATA_P1),
        .HRESP_P1       (HRESP_P1),

        // P2
        .HSEL_P2        (HSEL_P2),
        .HADDR_P2       (HADDR_P2),
        .HBURST_P2      (HBURST_P2),
        .HMASTLOCK_P2   (HMASTLOCK_P2),
        .HPROT_P2       (HPROT_P2),
        .HSIZE_P2       (HSIZE_P2),
        .HTRANS_P2      (HTRANS_P2),
        .HWDATA_P2      (HWDATA_P2),
        .HWRITE_P2      (HWRITE_P2),
        .HREADY_P2      (HREADY_P2),
        .HREADYOUT_P2   (HREADYOUT_P2),
        .HRDATA_P2      (HRDATA_P2),
        .HRESP_P2       (HRESP_P2),

        // P3
        .HSEL_P3        (HSEL_P3),
        .HADDR_P3       (HADDR_P3),
        .HBURST_P3      (HBURST_P3),
        .HMASTLOCK_P3   (HMASTLOCK_P3),
        .HPROT_P3       (HPROT_P3),
        .HSIZE_P3       (HSIZE_P3),
        .HTRANS_P3      (HTRANS_P3),
        .HWDATA_P3      (HWDATA_P3),
        .HWRITE_P3      (HWRITE_P3),
        .HREADY_P3      (HREADY_P3),
        .HREADYOUT_P3   (HREADYOUT_P3),
        .HRDATA_P3      (HRDATA_P3),
        .HRESP_P3       (HRESP_P3),

        // P4
        .HSEL_P4        (HSEL_P4),
        .HADDR_P4       (HADDR_P4),
        .HBURST_P4      (HBURST_P4),
        .HMASTLOCK_P4   (HMASTLOCK_P4),
        .HPROT_P4       (HPROT_P4),
        .HSIZE_P4       (HSIZE_P4),
        .HTRANS_P4      (HTRANS_P4),
        .HWDATA_P4      (HWDATA_P4),
        .HWRITE_P4      (HWRITE_P4),
        .HREADY_P4      (HREADY_P4),
        .HREADYOUT_P4   (HREADYOUT_P4),
        .HRDATA_P4      (HRDATA_P4),
        .HRESP_P4       (HRESP_P4)
);

//------------------------------------------------------------------------------
// P3: debug milestone register @0x4002_0000 (single-cycle write slave).
// Firmware ORs milestone bits in; top level shows them on the HDMI bands.
//------------------------------------------------------------------------------
assign HREADYOUT_P3 = 1'b1;
assign HRDATA_P3    = {24'd0, dbg_fw_state};
assign HRESP_P3     = 1'b0;

// Address-phase strobe registered into the data phase (HWDATA is only valid
// in the data phase; committing at the address-phase end captures stale bus).
reg p3_wr_q;
always @(posedge sys_clk or negedge cpuresetn) begin
    if (!cpuresetn)
        p3_wr_q <= 1'b0;
    else
        p3_wr_q <= HSEL_P3 && HTRANS_P3[1] && HWRITE_P3;
end

always @(posedge sys_clk or negedge cpuresetn) begin
    if (!cpuresetn)
        dbg_fw_state <= 8'd0;
    else if (p3_wr_q)
        dbg_fw_state <= HWDATA_P3[7:0];
end

// Last completed AHB transaction address bits [13:6] (BRAM word index /64).
// Shown on the HDMI bands: running core = flickering pattern, locked-up core
// = frozen at the crash-site fetch address. Map the value against the .map.
always @(posedge sys_clk) begin
    if (HTRANS[1] && HREADY)
        dbg_last_addr <= HADDR[13:6];
end

//------------------------------------------------------------------------------
// AHB RAMCODE
//------------------------------------------------------------------------------

wire [31:0] RAMCODE_RDATA,RAMCODE_WDATA;
wire [13:0] RAMCODE_WADDR;
wire [13:0] RAMCODE_RADDR;
wire [3:0]  RAMCODE_WRITE;

// STARTUP FORENSICS PROBE v8 (HDMI bands, bit0 = leftmost = band 1):
//   Phase 1: for the first ~2.7s (2^26 sys_clk) after reset the bands show
//   the 0xE1 boot signature (bands 1,6,7,8 white) so the flashed bit version
//   is identifiable on the board (v7=0x99 bands 1,4,5,8; v6=0xCC 3,4,7,8;
//   v5=0xAA 2,4,6,8).
//   Phase 2, bit7 = 0: firmware milestones win: dbg_fw_state != 0 shows
//   the ORed dbg_mark() bits (0=reached main, 1=uart_init, 2=banner, 3=SD
//   wait loop, 4=SD init done, 5=exFAT mounted, 6=frame played) ORed with the
//   failure code the firmware wrote (see fail_show() in main.c). All 8 bits
//   are forwarded since v8, so a code may use bit7 too.
//   Phase 2, bit7 = 1: startup died before main. Two alternating frames
//   (boot_cnt[23], ~0.34 s each):
//     frame A: [6]=SYSRESETREQ seen since reset release,
//              [5]=HWRITE and [4:0]=HADDR[4:0] of the LAST completed
//              transfer with HADDR[13:6] != 0 (v4 evidence: write @0x303C
//              = lib heap-guard 8th STM word 1; HADDR[5] dropped here).
//     frame B: [6]=a write to 0x3040 completed (guard STM8 word 2),
//              [5:0]=saturating count of granule!=0 writes since reset
//              (death inside zeroinit ~0x10; death after full zeroinit
//              + guard start saturates at 0x3F).
//   Both frames have bit7 = 1, milestone patterns never exceed 0x7F, so
//   the two modes cannot be confused. Stall capture kept as insurance
//   (structurally impossible: all four HREADYOUT are constant 1).
reg [25:0] boot_cnt;
reg        boot_done;
reg  [7:0] stall_cnt;
reg        stuck_sticky;
reg  [1:0] stall_slave;
reg  [4:0] stall_off;
reg  [6:0] death_info;
reg        reset_sticky;
reg        seen_3040;
reg  [5:0] wr_cnt;
wire       disp_tog = boot_cnt[23];
always @(posedge sys_clk or negedge sys_rstn) begin
    if (!sys_rstn) begin
        boot_cnt     <= 26'd0;
        boot_done    <= 1'b0;
        stall_cnt    <= 8'd0;
        stuck_sticky <= 1'b0;
        stall_slave  <= 2'd0;
        stall_off    <= 5'd0;
        death_info   <= 7'd0;
        reset_sticky <= 1'b0;
        seen_3040    <= 1'b0;
        wr_cnt       <= 6'd0;
    end else begin
        boot_cnt <= boot_cnt + 26'd1;
        if (&boot_cnt)
            boot_done <= 1'b1;
        if (HTRANS[1] && !HREADY) begin
            stall_cnt <= stall_cnt + 8'd1;
            if (&stall_cnt) begin
                stuck_sticky <= 1'b1;
                stall_slave  <= HSEL_P1 ? 2'd1 :
                                HSEL_P2 ? 2'd2 :
                                HSEL_P3 ? 2'd3 : 2'd0;
                stall_off    <= HADDR[4:0];
            end
        end else
            stall_cnt <= 8'd0;
        if (HTRANS[1] && HREADY && (HADDR[13:6] != 8'd0)) begin
            death_info <= {HWRITE, HADDR[5:0]};
            if (HWRITE && (&wr_cnt == 1'b0))
                wr_cnt <= wr_cnt + 6'd1;
        end
        if (HTRANS[1] && HREADY && HWRITE && (HADDR[31:0] == 32'h00003040))
            seen_3040 <= 1'b1;
        if (SYSRESETREQ)
            reset_sticky <= 1'b1;
    end
end
always @(posedge sys_clk or negedge sys_rstn) begin
    if (!sys_rstn)
        dbg_probe <= 8'h00;
    else if (!boot_done)
        dbg_probe <= 8'h3D;               /* v53 boot signature: SD hot plug + fast keys */
    else if (stuck_sticky)
        dbg_probe <= {1'b1, stall_slave, stall_off};
    else
        dbg_probe <= dbg_fw_state;                /* all 8 bits, no mask */
end

AHBlite_Block_RAM RAMCODE_Interface(
        /* Connect to Interconnect Port 0 */
        .HCLK           (sys_clk),
        .HRESETn        (cpuresetn),
        .HSEL           (HSEL_P0),
        .HADDR          (HADDR_P0),
        .HPROT          (HPROT_P0),
        .HSIZE          (HSIZE_P0),
        .HTRANS         (HTRANS_P0),
        .HWDATA         (HWDATA_P0),
        .HWRITE         (HWRITE_P0),
        .HRDATA         (HRDATA_P0),
        .HREADY         (HREADY_P0),
        .HREADYOUT      (HREADYOUT_P0),
        .HRESP          (HRESP_P0),
        .BRAM_WRADDR    (RAMCODE_WADDR),
        .BRAM_RDADDR    (RAMCODE_RADDR),
        .BRAM_RDATA     (RAMCODE_RDATA),
        .BRAM_WDATA     (RAMCODE_WDATA),
        .BRAM_WRITE     (RAMCODE_WRITE)
        /**********************************/
);

//------------------------------------------------------------------------------
// AHB UART (P1 slave @ 0x4000_0700)
//------------------------------------------------------------------------------

ahb_uart u_uart (
        .HCLK           (sys_clk),
        .HRESETn        (cpuresetn),
        .HSEL           (HSEL_P1),
        .HADDR          (HADDR_P1),
        .HTRANS         (HTRANS_P1),
        .HSIZE          (HSIZE_P1),
        .HWRITE         (HWRITE_P1),
        .HWDATA         (HWDATA_P1),
        .HREADY         (HREADY_P1),
        .HREADYOUT      (HREADYOUT_P1),
        .HRESP          (HRESP_P1),
        .HRDATA         (HRDATA_P1),
        .IRQ            (uart_irq),
        .uart_txd       (uart_txd),
        .uart_rxd       (uart_rxd)
);

//------------------------------------------------------------------------------
// sd_ctrl (P2 slave @ 0x4001_0000) -- M0 command iface to SD display chain
//------------------------------------------------------------------------------

sd_ctrl u_sd_ctrl (
        .HCLK           (sys_clk),
        .HRESETn        (cpuresetn),
        .HSEL           (HSEL_P2),
        .HADDR          (HADDR_P2),
        .HTRANS         (HTRANS_P2),
        .HWRITE         (HWRITE_P2),
        .HWDATA         (HWDATA_P2),
        .HREADY         (HREADY_P2),
        .HREADYOUT      (HREADYOUT_P2),
        .HRESP          (HRESP_P2),
        .HRDATA         (HRDATA_P2),
        // SD chain command face
        .sd_sec_read    (sd_sec_read),
        .sd_sec_read_addr(sd_sec_read_addr),
        .pack_reset     (sd_cmd_pack_reset),
        .pixel_offset   (pixel_offset),
        .file_len       (file_len),
        .frame_write_req(frame_write_req),
        .write_buf_idx  (write_buf_idx),
        .disp_buf_idx   (disp_buf_idx),
        .disp_en        (disp_en),
        .stream_active  (stream_active),
        // SD chain status face
        .sd_init_done   (sd_init_done),
        .sd_reinit      (sd_reinit),
        .sec_end        (sd_sec_read_end),
        .raw_byte_valid (sd_byte_valid),
        .raw_byte_data  (sd_byte_data),
        .frame_commit_tgl(frame_commit_tgl),
        .wr_req_ack     (wr_req_ack)
);

//------------------------------------------------------------------------------
// audio_ctrl (P4 slave @ 0x4003_0000) -- P6 audio: FIFO + sigma-delta PWM
//   AHB face on sys_clk (25MHz), modulator on the raw 50MHz board clock.
//------------------------------------------------------------------------------

audio_ctrl u_audio (
        .HCLK           (sys_clk),
        .HRESETn        (cpuresetn),
        .HSEL           (HSEL_P4),
        .HADDR          (HADDR_P4),
        .HTRANS         (HTRANS_P4),
        .HWRITE         (HWRITE_P4),
        .HWDATA         (HWDATA_P4),
        .HREADY         (HREADY_P4),
        .HREADYOUT      (HREADYOUT_P4),
        .HRESP          (HRESP_P4),
        .HRDATA         (HRDATA_P4),
        .clk_50m        (clk_50m),
        .arst           (arst_50m),
        .audio_pwm      (audio_pwm),
        // firmware display channel: 4 hex digits on the 7-segment display.
        // With the UART link dead this is the only readable console we have.
        .key_cnt        (key_cnt),
        .key_lvl        (key_lvl),
        .spec_h         (spec_h),
        .adc_cs_n       (adc_cs_n),
        .adc_sck        (adc_sck),
        .adc_rst_n      (adc_rst_n),
        .adc_miso       (adc_miso),
        .disp_val       (dbg_disp_val),
        .disp_en        (dbg_disp_en)
);

//------------------------------------------------------------------------------
// RAM
//------------------------------------------------------------------------------

Block_RAM RAM_CODE(
        .clka           (sys_clk),
        .addra          (RAMCODE_WADDR),
        .addrb          (RAMCODE_RADDR),
        .dina           (RAMCODE_WDATA),
        .doutb          (RAMCODE_RDATA),
        .wea            (RAMCODE_WRITE)
);

endmodule
