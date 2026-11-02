#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按 SWUG105 官方 run 系统模式生成 ip_check 全流程脚本。

模式：
  import_device -> create_project(自动打开) -> top_module -> add_files
  -> add_include_dir -> create_run(syn/phy) -> launch_runs -> wait_run
  -> open_run -> report -> close_project
注意：以 ip_check/ 根目录为工作目录；add_files 相对路径基于 .al 所在目录。
"""
from pathlib import Path

files = [
    "rtl/ip_check_top.v",
    "rtl/hdmi_top.v",
    "rtl/tx_pll.v",
    "rtl/sys_pll.v",
    "rtl/sdram.v",
    "rtl/enc/global_def.v",
    "rtl/enc/video_tpg_12801024p.enc.v",
    "rtl/enc/sdr_as_ram.enc.v",
    "rtl/enc/sdr_init_ref.enc.v",
    "rtl/hdmi_tx.vhd",
    "rtl/enc/DVITransmitter.enc.vhd",
    "rtl/enc/SerializerN_1_lvds.enc.vhd",
    "rtl/enc/SerializerN_1_lvds_dat.enc.vhd",
    "rtl/enc/TMDSEncoder.enc.vhd",
    "constraints/ip_check.adc",
    "constraints/ip_check.sdc",
]
add = "add_files {" + " ".join(files) + "}"

tcl = f"""# P-1 ip_check full flow (SWUG105 run-system pattern)
import_device eagle_s20.db -package EG4S20BG256
create_project ip_check ./ -family EG4 -device EG4S20BG256
top_module ip_check_top

{add}
add_include_dir ./rtl/enc

catch {{ create_run -constrset constrain_1 syn_1 }} msg_syn
catch {{ create_run -syn_run syn_1 -constrset constrain_1 phy_1 }} msg_phy
puts "CREATE_RUN syn: $msg_syn"
puts "CREATE_RUN phy: $msg_phy"

launch_runs syn_1
wait_run syn_1 -quiet
open_run syn_1
report_area -file ip_check_rtl.area

launch_runs -step route phy_1
wait_run phy_1 -quiet
open_run phy_1
report_timing -file ip_check_timing.rpt
report_area -file ip_check_final.area

puts "IP_CHECK_FLOW_DONE"
close_project
exit
"""
Path(r"d:\project\project0\test\ip_check\run_ip_check.tcl").write_text(
    tcl, encoding="ascii", errors="replace")
print("run_ip_check.tcl rewritten (run-system pattern)")
