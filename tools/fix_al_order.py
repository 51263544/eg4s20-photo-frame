#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""重排 ip_check.al 的 CompileOrder：Verilog 1-8, VHDL 9-13（全局唯一）。"""
import re
from pathlib import Path

al = Path(r"d:\project\project0\test\ip_check\prj\ip_check.al")
s = al.read_text(encoding="utf-8")
vlog = ["ip_check_top.v", "hdmi_top.v", "tx_pll.v", "sys_pll.v", "sdram.v",
        "video_tpg_12801024p.enc.v", "sdr_as_ram.enc.v", "sdr_init_ref.enc.v"]
vhdl = ["hdmi_tx.vhd", "DVITransmitter.enc.vhd", "SerializerN_1_lvds.enc.vhd",
        "SerializerN_1_lvds_dat.enc.vhd", "TMDSEncoder.enc.vhd"]


def setorder(src, fname, order):
    pat = (r'(<File Path="[^"]*' + re.escape(fname) +
           r'">.*?CompileOrder" Val=")(\d+)("/>)')
    m = re.search(pat, src, re.S)
    assert m, f"not found: {fname}"
    return src[:m.start(2)] + str(order) + src[m.end(2):]


for i, f in enumerate(vlog, 1):
    s = setorder(s, f, i)
for i, f in enumerate(vhdl, 9):
    s = setorder(s, f, i)
al.write_text(s, encoding="utf-8")
print("orders renumbered OK")
