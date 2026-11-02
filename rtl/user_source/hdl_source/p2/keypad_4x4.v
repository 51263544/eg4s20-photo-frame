//------------------------------------------------------------------------------
// keypad_4x4.v -- 4x4 matrix keypad scanner, debounce and P5 preset selector
//
// Board wiring (vendor `keyboard.adc` / `keyboard_scan.v`): KEY_ROW[3:0] are
// driven by the FPGA (one-hot low), KEY_COL[3:0] are read back through the
// board pull-ups, so a pressed key pulls its column low.
//
// Scan order and bit mapping are copied verbatim from the vendor example:
//   row 4'b1110 -> key[3:0]    row 4'b1101 -> key[7:4]
//   row 4'b1011 -> key[11:8]   row 4'b0111 -> key[15:12]
// (v19/v20 of this module had the two mapping mistakes that made every press
//  look random: `press_vec` was a level instead of an edge, and the nibble order
//  was reversed with respect to the vendor design.)
//
// Timing: 25.175 MHz pixel clock, 2500 cycles per row (~99 us), so a full scan
// takes ~400 us.  Columns are sampled in the MIDDLE of each row interval, half
// a tick after the row was driven, so the line has settled before it is read.
// A key state is accepted only after two identical consecutive scans.
//
// P5 binding: the first six keys in reading order (KEY15..KEY10) select filter
// presets 0..5 directly; any other key steps to the next preset and wraps
// 5 -> 0, so the filter stays usable on a differently wired board.
//------------------------------------------------------------------------------
module keypad_4x4(
        input  wire        clk,
        input  wire        rst,             // active high
        input  wire [3:0]  col,             // KEY_COL, active low
        output reg  [3:0]  row,             // KEY_ROW, one-hot low
        output reg  [15:0] key_down,        // debounced state, 1 = pressed
        output reg  [15:0] key_event,       // 1-cycle pulse per new press
        output reg  [31:0] ev_cnt,          // 16 x 2-bit press counters
        output reg  [2:0]  mode_r           // filter preset, 0..5
);

    localparam DIV = 2500;                  // 25.175 MHz / 2500 ~ 10 kHz

    reg [11:0] div;
    reg [1:0]  step;                        // row currently driven low
    reg [15:0] key_cur;                     // raw columns sampled this scan
    reg [15:0] key_last;                    // columns of the previous scan
    reg [15:0] key_stbl;                    // debounced columns
    reg [15:0] key_stbl_d;                  // previous debounced columns

    wire tick     = (div == (DIV - 1));
    wire mid      = (div == 12'd1249);      // sample point, mid row interval
    wire scan_end = tick && (step == 2'd3);

    // true edge: pressed now, released one cycle ago (columns are active low)
    wire [15:0] press_vec = (~key_stbl) & key_stbl_d;

    // ---- row scan ------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            div     <= 12'd0;
            step    <= 2'd0;
            row     <= 4'b1110;
            key_cur <= 16'hFFFF;
        end else begin
            div <= tick ? 12'd0 : (div + 12'd1);

            // sample in the middle of the interval: the row has been low for
            // ~50 us, so the column lines have settled
            if (mid) begin
                case (step)
                    2'd0: key_cur[3:0]   <= col;
                    2'd1: key_cur[7:4]   <= col;
                    2'd2: key_cur[11:8]  <= col;
                    default: key_cur[15:12] <= col;
                endcase
            end

            if (tick) begin
                if (step == 2'd3) begin
                    step <= 2'd0;
                    row  <= 4'b1110;
                end else begin
                    step <= step + 2'd1;
                    row  <= ~(4'b0001 << (step + 2'd1));
                end
            end
        end
    end

    // ---- two-scan debounce ---------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            key_last <= 16'hFFFF;
            key_stbl <= 16'hFFFF;
        end else if (scan_end) begin
            if (key_cur == key_last)
                key_stbl <= key_cur;        // same result twice -> accept
            key_last <= key_cur;
        end
    end

    // ---- one pulse per press -------------------------------------------------
    // ev_cnt holds a 2-bit counter per key.  A sticky level was not enough: it
    // can only report the *first* press of a key, because after that the level
    // never changes again.  A counter keeps every press observable across the
    // clock boundary (the AHB side compares against a shadow copy and turns
    // each change into one event bit).
    integer ki;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            key_down  <= 16'h0000;
            key_event <= 16'h0000;
            key_stbl_d <= 16'hFFFF;
            ev_cnt    <= 32'd0;
        end else begin
            key_down   <= ~key_stbl;
            key_event  <= press_vec;        // exactly one cycle per transition
            key_stbl_d <= key_stbl;
            for (ki = 0; ki < 16; ki = ki + 1)
                if (press_vec[ki])
                    ev_cnt[2*ki +: 2] <= ev_cnt[2*ki +: 2] + 2'd1;
        end
    end

    // ---- pressed key -> reading-order index ----------------------------------
    // key[15] is KEY15 (top-left on the silk), so index = 15 - bit.
    integer i;
    reg [3:0] k_idx;
    reg       k_any;
    always @(*) begin
        k_idx = 4'd15;
        k_any = 1'b0;
        for (i = 0; i < 16; i = i + 1) begin
            if (key_event[i] && (k_any == 1'b0)) begin
                k_any = 1'b1;
                k_idx = 4'd15 - i[3:0];
            end
        end
    end

    // ---- preset selector -----------------------------------------------------
    // Only KEY15..KEY10 (indices 0..5) do anything; the other ten keys are
    // deliberately ignored now that the row/column mapping is confirmed.
    always @(posedge clk or posedge rst) begin
        if (rst)
            mode_r <= 3'd0;
        else if (k_any && (k_idx <= 4'd5))
            mode_r <= k_idx[2:0];
    end

endmodule
