#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_pins.py — 引脚约束交叉校验（第二轮指令 Q1 第 4 条）

校验三件事：
  1. board_pinmap.adc 与 doc/hw/config.json 的 pin_assignments 逐条一致
     （数量、信号名、引脚、电平）。
  2. 同一物理引脚不得分配给两个不同信号（VGA/LCD 复用脚只允许出现一次）。
  3. 禁用引脚黑名单：HX4S20C 板的 HDMI(C3/G5/F1/E1)、SD(A12/A13/A14/B14)、
     按键(B2/C1) 不允许出现在任何条目中。

用法：
  python check_pins.py                     # 相对 repo 根运行，或
  python check_pins.py <adc路径> <json路径>

退出码：0 = 0 冲突；1 = 存在冲突。
"""
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]          # d:\project
DEFAULT_ADC = REPO / "project0" / "constraints" / "board_pinmap.adc"
DEFAULT_JSON = REPO / "doc" / "hw" / "config.json"

# HX4S20C（康芯板）引脚黑名单：任何条目命中即失败
FORBIDDEN_PINS = {"C3", "G5", "F1", "E1", "A12", "A13", "A14", "B14B", "B2", "C1"}
# 注意：B14 在我们板上是 LED（合法）；HX4S20C 例程把 B14 当 sd_miso——
# 由“信号-引脚组合黑名单”处理（见 RULES_SIG_PIN）。sd_* 命名两边一致，
# 不能按名字禁，只能按（信号,引脚）组合禁。
FORBIDDEN_SIGNALS = {"o_tmds_ch0_p", "o_tmds_ch1_p", "o_tmds_ch2_p",
                     "o_tmds_clk_p", "key1", "key2", "i_sys_clk"}
# 信号-引脚组合黑名单：HX4S20C 的错误用法，出现即失败
RULES_SIG_PIN = {
    ("sd_miso", "B14"), ("sd_ncs", "A12"), ("sd_dclk", "A14"), ("sd_mosi", "A13"),
    ("key1", "B2"), ("key2", "C1"),
    ("hdmi_clk_p", "C3"), ("hdmi_d0_p", "G5"), ("hdmi_d1_p", "F1"), ("hdmi_d2_p", "E1"),
}


def expand(sig: str):
    """VGA_R[3:0] -> [VGA_R[3], ...]；普通名原样返回。"""
    m = re.match(r"^(\w+)\[(\d+):(\d+)\]$", sig)
    if not m:
        return [sig]
    base, hi, lo = m.group(1), int(m.group(2)), int(m.group(3))
    return [f"{base}[{i}]" for i in range(hi, lo - 1, -1)]


def parse_adc(path: Path):
    entries = {}
    pat = re.compile(
        r"set_pin_assignment\s*\{\s*([^}]+?)\s*\}\s*\{\s*LOCATION\s*=\s*(\w+)"
        r"(?:\s*;\s*IOSTANDARD\s*=\s*(\w+))?", re.I)
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = line.split("#", 1)[0]           # 去注释
        m = pat.search(line)
        if not m:
            continue
        sig, pin, io = m.group(1).strip(), m.group(2).upper(), (m.group(3) or "LVCMOS33").upper()
        for s in expand(sig):
            if s in entries:
                sys.exit(f"FATAL: adc 内部重复定义 {s}")
            entries[s] = {"pin": pin, "io": io, "line": lineno}
    return entries


def parse_json(path: Path):
    data = json.loads(path.read_text(encoding="utf-8"))
    hw = data.get("hardware_config", data)
    assigns = hw.get("constraint_extract_result", {}).get("pin_assignments", [])
    entries = {}
    for a in assigns:
        sig = a["signal"]
        for s in expand(sig):
            entries[s] = {"pin": a["pin"].upper(),
                          "io": (a.get("iostandard") or "LVCMOS33").upper(),
                          "evidence": a.get("evidence", "")}
    return entries


def main():
    adc_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_ADC
    json_path = Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_JSON
    adc = parse_adc(adc_path)
    cfg = parse_json(json_path)

    conflicts = []

    # 1) 数量一致
    if set(adc) != set(cfg):
        only_adc = sorted(set(adc) - set(cfg))
        only_cfg = sorted(set(cfg) - set(adc))
        if only_adc:
            conflicts.append(f"adc 有而 config 无: {only_adc}")
        if only_cfg:
            conflicts.append(f"config 有而 adc 无: {only_cfg}")

    # 2) 逐条比对
    for sig in sorted(set(adc) & set(cfg)):
        a, c = adc[sig], cfg[sig]
        if a["pin"] != c["pin"]:
            conflicts.append(f"{sig}: adc={a['pin']} vs config={c['pin']}")
        if a["io"] != c["io"]:
            conflicts.append(f"{sig}: IOSTANDARD adc={a['io']} vs config={c['io']}")

    # 3) 同脚复用检查（adc 内部已由 parse 保证无重复定义；这里再查 pin->多信号）
    pin2sig = {}
    for sig, v in adc.items():
        pin2sig.setdefault(v["pin"], []).append(sig)
    for pin, sigs in sorted(pin2sig.items()):
        if len(sigs) > 1:
            conflicts.append(f"引脚 {pin} 被多个信号占用: {sigs}")

    # 4) 黑名单
    for sig, v in adc.items():
        if v["pin"] in FORBIDDEN_PINS:
            conflicts.append(f"{sig} 使用了 HX4S20C 禁用引脚 {v['pin']}")
        if sig.lower() in FORBIDDEN_SIGNALS:
            conflicts.append(f"信号名 {sig} 属于 HX4S20C 专用定义")
        if (sig.lower(), v["pin"]) in RULES_SIG_PIN:
            conflicts.append(f"{sig}@{v['pin']} 是 HX4S20C 的错误组合")

    print("=" * 64)
    print(f"board_pinmap.adc 条目数 : {len(adc)}")
    print(f"config.json    条目数   : {len(cfg)}")
    print(f"冲突数                 : {len(conflicts)}")
    print("=" * 64)
    for c in conflicts:
        print("  [CONFLICT]", c)
    if conflicts:
        sys.exit(1)
    print("RESULT: 0 conflicts — PASS")
    sys.exit(0)


if __name__ == "__main__":
    main()
