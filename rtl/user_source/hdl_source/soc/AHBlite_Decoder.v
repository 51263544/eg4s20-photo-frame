module AHBlite_Decoder
#(
    /*RAMCODE enable parameter*/
    parameter Port0_en = 1,
    /************************/

    /*WaterLight enable parameter*/
    parameter Port1_en = 0,
    /************************/

    /*RAMDATA enable parameter*/
    parameter Port2_en = 0,
    /************************/

    /*UART enable parameter*/
    parameter Port3_en=0
    /************************/
)(
    input [31:0] HADDR,

    /*RAMCODE OUTPUT SELECTION SIGNAL*/
    output wire P0_HSEL,

    /*WaterLight OUTPUT SELECTION SIGNAL*/
    output wire P1_HSEL,

    /*RAMDATA OUTPUT SELECTION SIGNAL*/
    output wire P2_HSEL,

    /*UART OUTPUT SELECTION SIGNAL*/
    output wire P3_HSEL,

    /*AUDIO OUTPUT SELECTION SIGNAL*/
    output wire P4_HSEL
);

//RAMCODE-----------------------------------

//0x00000000-0x0000ffff
/*Insert RAMCODE decoder code there*/
assign P0_HSEL = (HADDR[31:16]==16'h0000)? Port0_en : 1'b0;
/***********************************/

//PERIPHRAL-----------------------------

//P2: SD ctrl (P2_SD_DISPLAY), window 0x4001_0000-0x4001_FFFF
//     regs at 0x4001_0000 (CTRL/STATUS/SEC_ADDR/RAW_DATA/PIXEL_OFFSET/FILE_LEN)
assign P2_HSEL = (HADDR[31:16]==16'h4001);
/***********************************/

//0X40000010 UART RX DATA
//0X40000014 UART TX STATE
//0X40000018 UART TX DATA
/*Insert UART decoder code there*/

//P3: debug milestone register (P2_SD_DISPLAY), window 0x4002_0000-0x4002_FFFF
//     one 32-bit reg at 0x4002_0000, shown on the HDMI status bands
assign P3_HSEL = (HADDR[31:16]==16'h4002);
/***********************************/

//P1: AHB UART, window 0x4000_0000-0x4000_FFFF
//     regs at 0x4000_0700 (DATA/STATUS/BAUD/CTRL/FIFO_CLR)
assign P1_HSEL = (HADDR[31:16]==16'h4000);
/***********************************/

//P4: audio (P6), window 0x4003_0000-0x4003_FFFF
//     regs at 0x4003_0000 (DATA/CTRL/STATUS/RATE/VOL/TICKCNT)
assign P4_HSEL = (HADDR[31:16]==16'h4003);
/***********************************/

//RAMDATA-----------------------------
//0X20000000-0X2000FFFF
//P1 port is taken by AHB UART; RAMDATA comes later (P2 plan B)
/***********************************/

endmodule