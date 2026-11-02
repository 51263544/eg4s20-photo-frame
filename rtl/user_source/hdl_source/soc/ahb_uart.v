//------------------------------------------------------------------------------
// ahb_uart.v -- AHB-Lite UART 8N1 for P1 (M0 SoC peripheral @ 0x4000_0700)
//
// Reg map (offset, name, R/W):
//   0x00 DATA    R: pop RX FIFO byte   W: push TX FIFO byte
//   0x04 STATUS  R: [0]RX_AVAIL [1]TX_FULL [2]TX_EMPTY [4]RX_OVERRUN
//               W: write 1 to bit4 clears RX_OVERRUN
//   0x08 BAUD    R: current divider    W: divider (baud = HCLK / div), reset 434
//   0x0C CTRL    R: [0]RX_IRQ_EN [1]TX_IRQ_EN   W: irq enables, reset 0
//   0x10 FIFO_CLR W: any value clears both FIFOs
//
// TX FIFO 16 deep, RX FIFO 8 deep (register arrays). RX input double-flop
// synced, start-edge detect + center sampling. IRQ = RX_IRQ_EN & rx not empty.
// HREADYOUT tied 1 (zero wait state), HRESP tied OKAY.
//------------------------------------------------------------------------------

module ahb_uart (
    input  wire        HCLK,
    input  wire        HRESETn,
    // AHB-Lite slave (from Interconnect P1)
    input  wire        HSEL,
    input  wire [31:0] HADDR,
    input  wire [1:0]  HTRANS,
    input  wire [2:0]  HSIZE,
    input  wire        HWRITE,
    input  wire [31:0] HWDATA,
    input  wire        HREADY,
    output wire        HREADYOUT,
    output wire        HRESP,
    output wire [31:0] HRDATA,
    // interrupt / serial pins
    output wire        IRQ,
    output wire        uart_txd,
    input  wire        uart_rxd
);

    // zero wait state, no error response
    assign HREADYOUT = 1'b1;
    assign HRESP     = 1'b0;

    //------------------------------------------------------------------
    // Address phase strobes
    //------------------------------------------------------------------
    wire       sel_wr    = HSEL & HTRANS[1] &  HWRITE & HREADY;
    wire       sel_rd    = HSEL & HTRANS[1] & ~HWRITE & HREADY;
    wire [2:0] reg_sel   = HADDR[4:2];   // 0x00/04/08/0C/10 -> 0..4

    wire wr_data    = sel_wr & (reg_sel == 3'd0);
    wire wr_status  = sel_wr & (reg_sel == 3'd1);
    wire wr_baud    = sel_wr & (reg_sel == 3'd2);
    wire wr_ctrl    = sel_wr & (reg_sel == 3'd3);
    wire wr_fifoclr = sel_wr & (reg_sel == 3'd4);

    //------------------------------------------------------------------
    // BAUD / CTRL registers
    //------------------------------------------------------------------
    reg  [15:0] baud_div;
    reg         rx_irq_en, tx_irq_en;

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            baud_div  <= 16'd217;        // 25e6/217 ~= 115207 (~115200, D-006)
            rx_irq_en <= 1'b0;
            tx_irq_en <= 1'b0;
        end else begin
            if (wr_baud) baud_div <= HWDATA[15:0];
            if (wr_ctrl) begin
                rx_irq_en <= HWDATA[0];
                tx_irq_en <= HWDATA[1];
            end
        end
    end

    //------------------------------------------------------------------
    // TX FIFO (16 x 8)
    //------------------------------------------------------------------
    reg  [7:0] tx_mem [0:15];
    reg  [3:0] tx_wp, tx_rp;
    reg  [4:0] tx_cnt;
    reg        tx_load;                  // one-cycle pulse from TX engine
    wire       tx_pop  = tx_load;
    wire       tx_full  = (tx_cnt == 5'd16);
    wire       tx_empty = (tx_cnt == 5'd0);
    wire       tx_push  = wr_data & ~tx_full & ~wr_fifoclr;
    wire [7:0] tx_rdata = tx_mem[tx_rp];

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            tx_wp <= 4'd0; tx_rp <= 4'd0; tx_cnt <= 5'd0;
        end else if (wr_fifoclr) begin
            tx_wp <= 4'd0; tx_rp <= 4'd0; tx_cnt <= 5'd0;
        end else begin
            if (tx_push) begin
                tx_mem[tx_wp] <= HWDATA[7:0];
                tx_wp <= tx_wp + 4'd1;
            end
            if (tx_pop) tx_rp <= tx_rp + 4'd1;
            case ({tx_push, tx_pop})
                2'b10:   tx_cnt <= tx_cnt + 5'd1;
                2'b01:   tx_cnt <= tx_cnt - 5'd1;
                default: ;
            endcase
        end
    end

    //------------------------------------------------------------------
    // TX engine: shift {stop, data[7:0], start}, one bit per baud period
    //------------------------------------------------------------------
    reg        tx_busy;
    reg [9:0]  tx_shift;
    reg [3:0]  tx_bitcnt;
    reg [15:0] tx_baud_cnt;
    wire       tx_tick = tx_busy && (tx_baud_cnt == baud_div - 16'd1);

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            tx_busy     <= 1'b0;
            tx_load     <= 1'b0;
            tx_shift    <= 10'h3FF;
            tx_bitcnt   <= 4'd0;
            tx_baud_cnt <= 16'd0;
        end else begin
            tx_load <= 1'b0;
            if (!tx_busy) begin
                if (!tx_empty && !wr_fifoclr) begin
                    tx_shift    <= {1'b1, tx_rdata, 1'b0};  // stop,data,start
                    tx_load     <= 1'b1;                      // pop next cycle
                    tx_busy     <= 1'b1;
                    tx_baud_cnt <= 16'd0;
                    tx_bitcnt   <= 4'd0;
                end
            end else if (tx_tick) begin
                tx_baud_cnt <= 16'd0;
                if (tx_bitcnt == 4'd9)
                    tx_busy <= 1'b0;                        // stop period done
                else begin
                    tx_shift  <= {1'b1, tx_shift[9:1]};
                    tx_bitcnt <= tx_bitcnt + 4'd1;
                end
            end else begin
                tx_baud_cnt <= tx_baud_cnt + 16'd1;
            end
        end
    end

    assign uart_txd = tx_busy ? tx_shift[0] : 1'b1;

    //------------------------------------------------------------------
    // RX: double-flop sync, start edge detect, center sampling
    //------------------------------------------------------------------
    reg rxd_s0, rxd_s1, rxd_s2;
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            rxd_s0 <= 1'b1; rxd_s1 <= 1'b1; rxd_s2 <= 1'b1;
        end else begin
            rxd_s0 <= uart_rxd;
            rxd_s1 <= rxd_s0;
            rxd_s2 <= rxd_s1;
        end
    end
    wire rxd_val  = rxd_s1;
    wire rxd_prev = rxd_s2;
    wire rxd_fall = rxd_prev & ~rxd_val;

    localparam [1:0] RX_IDLE  = 2'd0,
                     RX_START = 2'd1,
                     RX_DATA  = 2'd2,
                     RX_STOP  = 2'd3;

    reg [1:0]  rx_state;
    reg [15:0] rx_cnt;
    reg [2:0]  rx_bit;
    reg [7:0]  rx_shift;

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            rx_state <= RX_IDLE;
            rx_cnt   <= 16'd0;
            rx_bit   <= 3'd0;
            rx_shift <= 8'd0;
        end else begin
            case (rx_state)
                RX_IDLE:
                    if (rxd_fall) begin
                        rx_state <= RX_START;
                        rx_cnt   <= 16'd0;
                    end
                RX_START: begin                       // to center of start bit
                    if (rx_cnt == {15'd0, baud_div[15:1]} - 16'd1) begin
                        rx_cnt <= 16'd0;
                        if (!rxd_val) begin
                            rx_state <= RX_DATA;
                            rx_bit   <= 3'd0;
                        end else
                            rx_state <= RX_IDLE;      // glitch, resync
                    end else
                        rx_cnt <= rx_cnt + 16'd1;
                end
                RX_DATA: begin                        // sample each bit center
                    if (rx_cnt == baud_div - 16'd1) begin
                        rx_cnt   <= 16'd0;
                        rx_shift <= {rxd_val, rx_shift[7:1]};
                        if (rx_bit == 3'd7) rx_state <= RX_STOP;
                        else                rx_bit   <= rx_bit + 3'd1;
                    end else
                        rx_cnt <= rx_cnt + 16'd1;
                end
                RX_STOP: begin                        // center of stop bit
                    if (rx_cnt == baud_div - 16'd1) begin
                        rx_cnt   <= 16'd0;
                        rx_state <= RX_IDLE;
                    end else
                        rx_cnt <= rx_cnt + 16'd1;
                end
                default: rx_state <= RX_IDLE;
            endcase
        end
    end

    // strobes derived from FSM state (see RX FIFO block below)

    //------------------------------------------------------------------
    // RX FIFO (8 x 8)
    //------------------------------------------------------------------
    reg  [7:0] rx_mem [0:7];
    reg  [2:0] rx_wp, rx_rp;
    reg  [3:0] rx_count;
    reg        rd_data_q;
    wire       rx_full  = (rx_count == 4'd8);
    wire       rx_avail = (rx_count != 4'd0);
    wire       rx_pop   = rd_data_q & rx_avail;   // data-phase pop, no underflow
    wire [7:0] rx_rdata = rx_mem[rx_rp];

    // strobes derived from FSM state (single driver, combinational)
    wire rx_stop_center = (rx_state == RX_STOP) && (rx_cnt == baud_div - 16'd1);
    wire rx_push        = rx_stop_center &&  rxd_val;                 // valid stop
    wire rx_ovr_set     = rx_stop_center &&  rxd_val && rx_full;      // dropped

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            rx_wp <= 3'd0; rx_rp <= 3'd0; rx_count <= 4'd0;
            rd_data_q <= 1'b0;
        end else begin
            rd_data_q <= sel_rd & (reg_sel == 3'd0);
            if (wr_fifoclr) begin
                rx_wp <= 3'd0; rx_rp <= 3'd0; rx_count <= 4'd0;
            end else begin
                if (rx_push) begin
                    rx_mem[rx_wp] <= rx_shift;
                    rx_wp <= rx_wp + 3'd1;
                end
                if (rx_pop) rx_rp <= rx_rp + 3'd1;
                case ({rx_push, rx_pop})
                    2'b10:   rx_count <= rx_count + 4'd1;
                    2'b01:   rx_count <= rx_count - 4'd1;
                    default: ;
                endcase
            end
        end
    end

    // sticky RX overrun, write-1-clear via STATUS bit4
    reg rx_ovr;
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn)                          rx_ovr <= 1'b0;
        else if (rx_ovr_set)                   rx_ovr <= 1'b1;
        else if (wr_status && HWDATA[4])       rx_ovr <= 1'b0;
    end

    //------------------------------------------------------------------
    // Read data mux
    //------------------------------------------------------------------
    reg [31:0] hrdata_r;
    always @(*) begin
        case (reg_sel)
            3'd0:    hrdata_r = {24'b0, rx_rdata};
            3'd1:    hrdata_r = {27'b0, rx_ovr, 1'b0, tx_empty, tx_full, rx_avail};
            3'd2:    hrdata_r = {16'b0, baud_div};
            3'd3:    hrdata_r = {30'b0, tx_irq_en, rx_irq_en};
            default: hrdata_r = 32'b0;
        endcase
    end
    assign HRDATA = hrdata_r;

    // IRQ: RX fifo not empty and enabled
    assign IRQ = rx_irq_en & rx_avail;

endmodule
