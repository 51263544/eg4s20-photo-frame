#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一次性生成 project0/test/ip_check 预检工程（P-1）。可重复运行。"""
import shutil
from pathlib import Path

W = Path(r"d:\project\project0\work")
ROOT = Path(r"d:\project\project0\test\ip_check")
RTL = ROOT / "rtl" / "enc"
CST = ROOT / "constraints"
PRJ = ROOT / "prj"
for d in (RTL, CST, PRJ):
    d.mkdir(parents=True, exist_ok=True)

HDMI = W / "M0_Borad" / "M0_Borad" / "10_VGA_hdmi_tx_display_MB"
LAB4 = W / "kangxin_2026" / "lab_ex4_tf" / "src" / "user_source" / "hdl_source"

copies = {
    HDMI / "source_code" / "rtl" / "hdmi_top.v": ROOT / "rtl" / "hdmi_top.v",
    HDMI / "source_code" / "rtl" / "hdmi_tx.vhd": ROOT / "rtl" / "hdmi_tx.vhd",
    HDMI / "prj" / "al_ip" / "tx_pll.v": ROOT / "rtl" / "tx_pll.v",
    HDMI / "source_code" / "rtl" / "enc_file" / "video_tpg_12801024p.enc.v": RTL / "video_tpg_12801024p.enc.v",
    HDMI / "source_code" / "rtl" / "enc_file" / "DVITransmitter.enc.vhd": RTL / "DVITransmitter.enc.vhd",
    HDMI / "source_code" / "rtl" / "enc_file" / "SerializerN_1_lvds.enc.vhd": RTL / "SerializerN_1_lvds.enc.vhd",
    HDMI / "source_code" / "rtl" / "enc_file" / "SerializerN_1_lvds_dat.enc.vhd": RTL / "SerializerN_1_lvds_dat.enc.vhd",
    HDMI / "source_code" / "rtl" / "enc_file" / "TMDSEncoder.enc.vhd": RTL / "TMDSEncoder.enc.vhd",
    LAB4 / "IP" / "sys_pll.v": ROOT / "rtl" / "sys_pll.v",
    LAB4 / "include" / "sdr_as_ram.enc.v": RTL / "sdr_as_ram.enc.v",
    LAB4 / "include" / "sdr_init_ref.enc.v": RTL / "sdr_init_ref.enc.v",
    LAB4 / "include" / "global_def.v": RTL / "global_def.v",
}
for src, dst in copies.items():
    shutil.copy2(src, dst)

# sdram.v 封装：改 include 为同目录，去掉 ifdef SIMULATION 外的复杂度（保留原样逻辑）
sdram_src = (LAB4 / "SD" / "sdram.v").read_text(encoding="utf-8", errors="replace")
sdram_src = sdram_src.replace(
    '`include "../user_source/hdl_source/include/global_def.v"',
    '`include "global_def.v"')
(ROOT / "rtl" / "sdram.v").write_text(sdram_src, encoding="utf-8")

# ip_check_top.v
(ROOT / "rtl" / "ip_check_top.v").write_text(r"""`timescale 1ns/1ps
//============================================================================
// ip_check_top.v — P-1 IP 预检顶层（TD 6.2.1 通性验证，不上板）
// 链路1：官方 HDMI 全链（tx_pll 107.5/537.5 + 加密 TPG/TMDS + VGA）
// 链路2：片内 SDRAM 硬核（lab_ex4 125MHz IP 集：sys_pll 100/125/125@180°
//        + sdr_as_ram.enc.v + sdr_init_ref.enc.v + EG_PHY_SDRAM_2M_32）
// 仅验证：加密模块可综合、PLL 2 片并存、硬宏可布线、引脚合法。
//============================================================================
module ip_check_top (
    input  wire        clk,          // R7 50MHz
    input  wire        rst_n,        // A9
    output wire        HDMI_CLK_P,
    output wire        HDMI_D0_P,
    output wire        HDMI_D1_P,
    output wire        HDMI_D2_P,
    output wire [4:0]  VGA_R,
    output wire [5:0]  VGA_G,
    output wire [4:0]  VGA_B,
    output wire        VGA_HS,
    output wire        VGA_VS,
    output wire        LED
);
    wire rst = ~rst_n;              // 官方链路 RST_I 为高有效

    //---------------- 链路1：官方 HDMI（1280x1024@60, 107.5MHz）------------
    wire pll_lock;
    wire clk25, pxl_clk, tmds5x_clk;
    tx_pll u_txpll (
        .refclk    (clk),
        .reset     (rst),
        .extlock   (pll_lock),
        .clk0_out  (clk25),
        .clk1_out  (pxl_clk),
        .clk2_out  (tmds5x_clk)
    );
    hdmi_top u_hdmi (
        .PXLCLK_I    (pxl_clk),
        .PXLCLK_5X_I (tmds5x_clk),
        .RST_I       (rst),
        .DEN_TPG     (1'b1),
        .TPG_mode    (4'd0),
        .LOCKED_I    (pll_lock),
        .HDMI_CLK_P  (HDMI_CLK_P),
        .HDMI_D2_P   (HDMI_D2_P),
        .HDMI_D1_P   (HDMI_D1_P),
        .HDMI_D0_P   (HDMI_D0_P),
        .SERDES_CLK_TEST   (),
        .SERDES_DATA1_TEST (),
        .SERDES_DATA2_TEST (),
        .ODDR_CLK_TEST     (),
        .ODDR_DATA1_TEST   (),
        .ODDR_DATA2_TEST   (),
        .VGA_HS (VGA_HS),
        .VGA_VS (VGA_VS),
        .VGA_R  (VGA_R),
        .VGA_G  (VGA_G),
        .VGA_B  (VGA_B)
    );

    //---------------- 链路2：片内 SDRAM（125MHz IP 集）---------------------
    wire spll_lock;
    wire clk100, clk125, clk125_sft;
    sys_pll u_spll (
        .refclk   (clk),
        .reset    (rst),
        .extlock  (spll_lock),
        .clk0_out (clk100),
        .clk1_out (clk125),
        .clk2_out (clk125_sft)
    );
    wire sdr_init_done, sdr_init_ref_vld, sdr_busy, sdr_rd_en;
    wire [31:0] sdr_rd_dout;
    sdram u_sdr (
        .Clk             (clk125),
        .Clk_sft         (clk125_sft),
        .Rst             (rst),
        .Sdr_init_done   (sdr_init_done),
        .Sdr_init_ref_vld(sdr_init_ref_vld),
        .Sdr_busy        (sdr_busy),
        .App_wr_en       (1'b0),
        .App_wr_addr     (21'd0),
        .App_wr_dm       (4'd0),
        .App_wr_din      (32'd0),
        .App_rd_en       (1'b0),
        .App_rd_addr     (21'd0),
        .Sdr_rd_en       (sdr_rd_en),
        .Sdr_rd_dout     (sdr_rd_dout)
    );
    assign LED = sdr_init_done;      // SDRAM 初始化完成指示（编译期可观察信号）
endmodule
""", encoding="utf-8")

# ip_check.adc
(CST / "ip_check.adc").write_text(r"""# ip_check.adc — P-1 预检约束（仅时钟 + HDMI/VGA/LED 输出，证据同 board_pinmap.adc）
set_pin_assignment	{ clk }		{ LOCATION = R7; IOSTANDARD = LVCMOS33; }
set_pin_assignment	{ rst_n }	{ LOCATION = A9; IOSTANDARD = LVCMOS33; }
set_pin_assignment	{ HDMI_CLK_P }	{ LOCATION = P1; IOSTANDARD = LVDS33; }
set_pin_assignment	{ HDMI_D0_P }	{ LOCATION = N1; IOSTANDARD = LVDS33; }
set_pin_assignment	{ HDMI_D1_P }	{ LOCATION = P4; IOSTANDARD = LVDS33; }
set_pin_assignment	{ HDMI_D2_P }	{ LOCATION = J3; IOSTANDARD = LVDS33; }
set_pin_assignment	{ VGA_HS }	{ LOCATION = M14; IOSTANDARD = LVCMOS33; SLEWRATE = FAST; }
set_pin_assignment	{ VGA_VS }	{ LOCATION = P14; IOSTANDARD = LVCMOS33; SLEWRATE = FAST; }
set_pin_assignment	{ VGA_R[0] }	{ LOCATION = H14; IOSTANDARD = LVCMOS33; SLEWRATE = FAST; }
set_pin_assignment	{ VGA_R[1] }	{ LOCATION = H13; IOSTANDARD = LVCMOS33; SLEWRATE = FAST; }
set_pin_assignment	{ VGA_R[2] }	{ LOCATION = H16; IOSTANDARD = LVCMOS33; SLEWRATE = FAST; }
set_pin_assignment	{ VGA_R[3] }	{ LOCATION = G16; IOSTANDARD = LVCMOS33; SLEWRATE = FAST; }
set_pin_assignment	{ VGA_R[4] }	{ LOCATION = H15; IOSTANDARD = LVCMOS33; SLEWRATE = FAST; }
set_pin_assignment	{ VGA_G[0] }	{ LOCATION = G11; IOSTANDARD = LVCMOS33; SLEWRATE = FAST; }
set_pin_assignment	{ VGA_G[1] }	{ LOCATION = J11; IOSTANDARD = LVCMOS33; SLEWRATE = FAST; }
set_pin_assignment	{ VGA_G[2] }	{ LOCATION = K16; IOSTANDARD = LVCMOS33; SLEWRATE = FAST; }
set_pin_assignment	{ VGA_G[3] }	{ LOCATION = K15; IOSTANDARD = LVCMOS33; SLEWRATE = FAST; }
set_pin_assignment	{ VGA_G[4] }	{ LOCATION = J16; IOSTANDARD = LVCMOS33; SLEWRATE = FAST; }
set_pin_assignment	{ VGA_G[5] }	{ LOCATION = J14; IOSTANDARD = LVCMOS33; SLEWRATE = FAST; }
set_pin_assignment	{ VGA_B[0] }	{ LOCATION = J13; IOSTANDARD = LVCMOS33; SLEWRATE = FAST; }
set_pin_assignment	{ VGA_B[1] }	{ LOCATION = K14; IOSTANDARD = LVCMOS33; SLEWRATE = FAST; }
set_pin_assignment	{ VGA_B[2] }	{ LOCATION = J12; IOSTANDARD = LVCMOS33; SLEWRATE = FAST; }
set_pin_assignment	{ VGA_B[3] }	{ LOCATION = K12; IOSTANDARD = LVCMOS33; SLEWRATE = FAST; }
set_pin_assignment	{ VGA_B[4] }	{ LOCATION = L14; IOSTANDARD = LVCMOS33; SLEWRATE = FAST; }
set_pin_assignment	{ LED }		{ LOCATION = B14; IOSTANDARD = LVCMOS33; }
""", encoding="utf-8")

# ip_check.sdc
(CST / "ip_check.sdc").write_text(
    'create_clock -name clk -period 20.000 [get_ports {clk}]\n', encoding="utf-8")

# ip_check.al（依官方 .al XML 结构改写）
def vfile(path, order, belong="design_1", vhdl=False):
    return f"""            <File Path="{path}">
                <FileInfo>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&R" Val="true"/>
                    <Attr Name="BelongTo" Val="{belong}"/>
                    <Attr Name="CompileOrder" Val="{order}"/>
                </FileInfo>
            </File>"""

verilog = "\n".join([
    vfile("../rtl/ip_check_top.v", 1),
    vfile("../rtl/hdmi_top.v", 2),
    vfile("../rtl/tx_pll.v", 3),
    vfile("../rtl/sys_pll.v", 4),
    vfile("../rtl/sdram.v", 5),
    vfile("../rtl/enc/video_tpg_12801024p.enc.v", 6),
    vfile("../rtl/enc/sdr_as_ram.enc.v", 7),
    vfile("../rtl/enc/sdr_init_ref.enc.v", 8),
])
vhdl = "\n".join([
    vfile("../rtl/hdmi_tx.vhd", 1, vhdl=True),
    vfile("../rtl/enc/DVITransmitter.enc.vhd", 2, vhdl=True),
    vfile("../rtl/enc/SerializerN_1_lvds.enc.vhd", 3, vhdl=True),
    vfile("../rtl/enc/SerializerN_1_lvds_dat.enc.vhd", 4, vhdl=True),
    vfile("../rtl/enc/TMDSEncoder.enc.vhd", 5, vhdl=True),
])
al = f"""<?xml version="1.0" encoding="UTF-8"?>
<Project Version="3" Minor="2" Path="D:/project/project0/test/ip_check/prj">
    <Project_Created_Time></Project_Created_Time>
    <TD_Version>6.2.168116</TD_Version>
    <UCode>00000000</UCode>
    <Name>ip_check</Name>
    <HardWare>
        <Family>EG4</Family>
        <Device>EG4S20BG256</Device>
        <Speed></Speed>
    </HardWare>
    <Source_Files>
        <Verilog>
{verilog}
        </Verilog>
        <VHDL>
{vhdl}
        </VHDL>
        <ADC_FILE>
{vfile("../constraints/ip_check.adc", 1, belong="constrain_1")}
        </ADC_FILE>
        <SDC_FILE>
{vfile("../constraints/ip_check.sdc", 2, belong="constrain_1")}
        </SDC_FILE>
    </Source_Files>
    <FileSets>
        <FileSet Name="design_1" Type="DesignFiles">
        </FileSet>
        <FileSet Name="constrain_1" Type="ConstrainFiles">
        </FileSet>
    </FileSets>
    <TOP_MODULE>
        <LABEL></LABEL>
        <MODULE>ip_check_top</MODULE>
        <CREATEINDEX>auto</CREATEINDEX>
    </TOP_MODULE>
    <Property>
    </Property>
    <Device_Settings>
    </Device_Settings>
    <Configurations>
    </Configurations>
    <Runs>
        <Run Name="syn_1" Type="Synthesis" ConstraintSet="constrain_1" Description="" Active="true">
            <Strategy Name="Default_Synthesis_Strategy">
            </Strategy>
        </Run>
        <Run Name="phy_1" Type="PhysicalDesign" ConstraintSet="constrain_1" Description="" SynRun="syn_1" Active="true">
            <Strategy Name="Default_PhysicalDesign_Strategy">
            </Strategy>
        </Run>
    </Runs>
    <Project_Settings>
        <Step_Last_Change>2026-10-27 20:00:00.000</Step_Last_Change>
        <Current_Step>60</Current_Step>
        <Step_Status>true</Step_Status>
    </Project_Settings>
</Project>
"""
(PRJ / "ip_check.al").write_text(al, encoding="utf-8")

# run.tcl
(PRJ / "run_ip_check.tcl").write_text(r"""# P-1 ip_check 一键全流程（综合 -> 布局布线 -> 时序报告）
proc step_begin { step } {
  set beginFile ".$step.begin.f"
  set ch [open $beginFile w]
  puts $ch "<?xml version=\"1.0\"?>"
  close $ch
}
proc step_end { step } {
  set endFile ".$step.end.f"
  set ch [open $endFile w]
  close $ch
}
step_begin read_design
open_project {ip_check.al}
import_device eagle_s20.db -package EG4S20BG256
elaborate -top {ip_check_top}
export_db {ip_check_elaborate.db}
step_end read_design
step_begin opt_rtl
read_adc {../constraints/ip_check.adc}
optimize_rtl
report_area -file ip_check_rtl.area
export_db {ip_check_rtl.db}
step_end opt_rtl
step_begin opt_gate
read_sdc {../constraints/ip_check.sdc}
optimize_gate -maparea ip_check_gate.area
legalize_phy_inst
export_db {ip_check_gate.db}
step_end opt_gate
step_begin place
place
export_db {ip_check_place.db}
step_end place
step_begin route
route
report_timing -file ip_check_timing.rpt
export_db {ip_check_route.db}
step_end route
puts "IP_CHECK_FLOW_DONE"
exit
""", encoding="utf-8")

print("OK: ip_check project generated at", ROOT)
