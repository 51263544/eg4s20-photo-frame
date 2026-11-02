#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""修正 ip_check.al：移除非法 Verilog_Include_Directories，global_def.v 注册为设计文件。"""
import re
from pathlib import Path

al = Path(r"d:\project\project0\test\ip_check\prj\ip_check.al")
s = al.read_text(encoding="utf-8")

s = s.replace("        <Verilog_Include_Directories>../rtl/enc;../rtl</Verilog_Include_Directories>\n", "")

# global_def.v 作为 Verilog 设计文件，CompileOrder=1（幂等）
if "global_def.v" not in s:
    entry = """            <File Path="../rtl/enc/global_def.v">
                <FileInfo>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&R" Val="true"/>
                    <Attr Name="BelongTo" Val="design_1"/>
                    <Attr Name="CompileOrder" Val="1"/>
                </FileInfo>
            </File>
"""
    s = s.replace("        <Verilog>\n", "        <Verilog>\n" + entry)
else:
    # 已存在则确保 CompileOrder=1
    pat = (r'(<File Path="[^"]*global_def\.v">.*?CompileOrder" Val=")(\d+)("/>)')
    m = re.search(pat, s, re.S)
    if m and m.group(2) != "1":
        s = s[:m.start(2)] + "1" + s[m.end(2):]

# 重排其余 Verilog 2-9、VHDL 10-14
vlog = ["ip_check_top.v", "hdmi_top.v", "tx_pll.v", "sys_pll.v", "sdram.v",
        "video_tpg_12801024p.enc.v", "sdr_as_ram.enc.v", "sdr_init_ref.enc.v"]
for i, f in enumerate(vlog, 2):
    pat = (r'(<File Path="[^"]*' + re.escape(f) + r'">.*?CompileOrder" Val=")(\d+)("/>)')
    m = re.search(pat, s, re.S)
    assert m, f"not found: {f}"
    s = s[:m.start(2)] + str(i) + s[m.end(2):]

vhdl = ["hdmi_tx.vhd", "DVITransmitter.enc.vhd", "SerializerN_1_lvds.enc.vhd",
        "SerializerN_1_lvds_dat.enc.vhd", "TMDSEncoder.enc.vhd"]
for i, f in enumerate(vhdl, 10):
    pat = (r'(<File Path="[^"]*' + re.escape(f) + r'">.*?CompileOrder" Val=")(\d+)("/>)')
    m = re.search(pat, s, re.S)
    assert m, f"not found: {f}"
    s = s[:m.start(2)] + str(i) + s[m.end(2):]

al.write_text(s, encoding="utf-8")
print("al fixed: global_def.v registered as design file, invalid tag removed")
