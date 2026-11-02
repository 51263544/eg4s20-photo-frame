#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从骨架生成单文件最小 .al（bisect 用）。"""
from pathlib import Path

TPL = """<?xml version="1.0" encoding="UTF-8"?>
<Project Version="3" Minor="2" Path="D:/project/project0/test/ip_check/prj">
    <Project_Created_Time></Project_Created_Time>
    <TD_Version>5.6.56362</TD_Version>
    <UCode>00000000</UCode>
    <Name>{name}</Name>
    <HardWare>
        <Family>EG4</Family>
        <Device>EG4S20BG256</Device>
        <Speed></Speed>
    </HardWare>
    <Source_Files>
        <Verilog>
            <File Path="{path}">
                <FileInfo>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&R" Val="true"/>
                    <Attr Name="BelongTo" Val="design_1"/>
                    <Attr Name="CompileOrder" Val="1"/>
                </FileInfo>
            </File>
        </Verilog>
        <VHDL>
        </VHDL>
        <ADC_FILE>
        </ADC_FILE>
        <SDC_FILE>
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
        <MODULE>{top}</MODULE>
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

PRJ = Path(r"d:\project\project0\test\ip_check\prj")
(PRS := PRJ / "al_hello.al").write_text(
    TPL.format(name="al_hello", path="../rtl/hello.v", top="hello"), encoding="utf-8")
(PRS2 := PRJ / "al_top_only.al").write_text(
    TPL.format(name="al_top_only", path="../rtl/ip_check_top.v", top="ip_check_top"), encoding="utf-8")
print("minimal .al files written")
