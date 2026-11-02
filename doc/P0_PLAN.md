# P0_PLAN.md — P0a → P0b 逐行改动清单

> 2026-10-27 · 第二轮指令 Q2 交付物 3
> 原则（第二轮 §6）：不改任何 `.enc.v` / 加密 VHDL / 加密 TPG 内部；P0b 只动 PLL 参数与像素流来源。

## 0. 前置事实（本机核实）

- 工具：TD 6.2.168116（`D:\FPGA`，license `Anlogic.lic` 已装）。
- P0a 源工程：`project0/work/M0_Borad/M0_Borad/10_VGA_hdmi_tx_display_MB/prj/hdmi_tx_display.al`
  （TD 5.6 创建，6.2.1 打开后会自动升级工程版本；源文件按 .al 内相对路径引用）。
- **TMDS 发送链与分辨率无关**：`hdmi_tx.vhd:11` 只是把 HS/VS/DE/RGB24 交给加密的
  `DVITransmitter` 做 8b/10b + 串行化，没有任何 1280×1024 假设 → 换时序源即可。
- **TPG 是加密模块**：`video_tpg_12801024p.enc.v` 内部写死 1280×1024 时序，
  官方提供 800600/1024768/1080p/1280800/16801050p 五种加密 TPG，**没有 640×480**。
  → P0b 的"改 H/V 时序参数"实际操作是：**替换 hdmi_top.v:61 的 TPG 实例**
  为我们自己的纯 Verilog 640×480 时序+彩条发生器（不改 hdmi_tx、不动任何加密文件）。

## 1. P0a：官方工程原样出 1280×1024@60 彩条

**动作**：复制（不是引用）官方工程到 `project0/prj/p0a_colorbar/`，在 TD 6.2.1 打开编译下载。

| # | 文件 | 改动 |
|---|---|---|
| 1 | `prj/hdmi_tx_display.al` | 路径改写为 p0a 目录内相对路径；TD_Version 升级由 TD 6.2.1 自动完成 |
| 2 | `source_code/rtl/*.v/.vhd`、`enc_file/*`、`adc_sdc/hdmi.adc` | **原样复制，零改动** |
| 3 | `source_code/adc_sdc/hdmi_ph1.sdc` | 保留官方时序约束（107.5MHz 主约束） |

验收：HDMI + VGA 同时出彩条（11 种图案自动轮播），稳定 10 分钟无黑屏/花屏。
失败判据：黑屏 / 花屏 / 间歇闪 → 停，上报，不加补丁。

### 1.1 P0a 执行记录（2026-10-27，TD 6.2.168116 CLI 实测 ✅）

工程：`project0/prj/p0a_colorbar/`（官方源码逐字复制，零改动）。
实施方式说明：未走 ".al 路径改写" 路线，改用 P-1 已验证的 run 系统模式
（`create_project + add_files + launch_runs`，脚本 `run_p0a.tcl`）——与 P-1 预检同一工具链，
规避 TD 5.6→6.2 的 .al 升级不确定性；源文件与约束本身仍是官方原样。

结果：
- **`p0a_colorbar.bit` 已生成**（629,636 字节，`BIT-1004 Generate bits file`），全流程无 ERROR。
- 资源：619 LUT (3.16%) / 352 REG (1.80%) / 24 IO / 0 BRAM / 0 DSP / 2 PLL。
- 时序（route 后，Slow+Fast 双 corner）：Hold WNS +0.214ns / HTNS 0，**0 hold 违例**。

**关键发现——官方 `hdmi_ph1.sdc` 的 generated clock 倍率写错**：
`-multiply_by 4.76 / 23.8` 使 STA 按 **238MHz / 1190MHz** 约束 PLL 输出，
而实际 PLL 输出为 **107.5MHz / 537.5MHz**（超约束恰 2.215×）。报告中的
167 个 setup "违例"（pclk 域 110 + sclk5 域 57）全部是该伪影：
- pclk 域实际最差路径 5.872ns（fmax 170.3MHz）< 真实周期 9.301ns，**余 3.43ns** ✓
- sclk5 域实际最差路径 1.600ns（fmax 625MHz）< 真实周期 1.861ns，**余 0.26ns** ✓
另：tx_pll clk0_out（25MHz 图案计数域）官方 SDC 未约束（无 generated clock），
属官方工程原始遗留，不影响出图。

→ **P0b 实施时必须修正 SDC**（见 §2.3 增补）。

## 2. P0b：改 640×480@60（像素时钟 25MHz）

### 2.1 PLL 逐行改动（`prj/al_ip/tx_pll.v`，generated 文件，非加密）

PLL 数学（已用官方两颗 PLL 反推验证）：
`VCO = FIN / REFCLK_DIV × FBCLK_DIV × CLKC0_DIV`（FEEDBK_PATH="CLKC0_EXT" 时）
- P0a：50/2×1×43 = **1075 MHz** → C0=25（1075/43）、C1=107.5（/10）、C2=537.5（/2）✓
- P0b 目标：C1=25.0（像素）、C2=125.0（5×）、C0=25.0（图案计数）
  → 取 VCO=1000：`REFCLK_DIV=2, FBCLK_DIV=1, CLKC0_DIV=40`，C1_DIV=40，C2_DIV=8
  → 与 lab_ex4 `video_pll.v`（25/125MHz，VCO=1000，KVCO=2/ICP=9/LPF=8 完全同参）一致，
    滤波参数无需改动。

**精确 25.175MHz 不可行**（整数分频数学无解）：25.175×40=1007=19×53，
从 50MHz 整数分频链永远得不到 1007 的因子；lab_ex4（2026 赛题官方例程）同样用 25.000MHz。
25.000 对 640×480@60 标称 25.175 偏差 −0.70%，HDMI sink 均可接受（lab_ex4 上板验证过的同款偏差）。

`tx_pll.v` 改动行（改前 → 改后）：

| 行 | 参数 | P0a 值 | P0b 值 |
|---|---|---|---|
| 60 | `.CLKC0_DIV` | 43 | **40** |
| 61 | `.CLKC0_CPHASE` | 42 | **39** |
| 64 | `.CLKC1_DIV` | 10 | **40** |
| 65 | `.CLKC1_CPHASE` | 9 | **39** |
| 67 | `.CLKC2_DIV` | 2 | **8** |
| 68 | `.CLKC2_CPHASE` | 1 | **7** |
| 18-20 | 头部注释频率说明 | 25/107.5/537.5 | 25/25/125（注释性修改） |

KVCO(2)/ICP_CURRENT(9)/LPF_CAPACITOR(1)/LPF_RESISTOR(8)/REFCLK_DIV(2)/FBCLK_DIV(1) 全部不动。
备注：更规范的做法是用 TD 的 IpTool 重新生成一颗 PLL IP；本表的手改参数与 IpTool
生成结果（参考 video_pll.v）逐位一致，二者等价，任选其一。

### 2.2 像素流替换（`source_code/rtl/hdmi_top.v`）

仅替换 TPG 实例（`:61-70`），hdmi_tx 实例（`:73-94`）与文件其余部分不动：

| 行 | 改前 | 改后 |
|---|---|---|
| 61 | `video_tpg_12801024p u2_tpg(...)` | `video_tpg_640480 u2_tpg(...)`（我们的纯 Verilog 模块，端口同名：PCLK/Reset/DEN_TPG/TPG_mode/PDEN/HSYNC/VSYNC/PDATA） |
| 38-52 | `SERDES_CLK_TEST` 等 6 个测试输出 | 保留端口但悬空不变（避免动 .al 顶层连接） |

新增文件 `project0/rtl/video_tpg_640480.v`（唯一新 RTL，≤300 行）：
- 640×480@60 时序：H=800(640+16+96+48)、V=525(480+10+2+33)、负极性 HS/VS（与 lab_ex4
  `color_bar.v:42-54` 一致，`video_define.v` 只有一行 `` `define VIDEO_640_480 ``）。
- 复刻官方 TPG 端口语义：PCLK 采样、DEN_TPG 使能、TPG_mode[3:0] 选图案、
  PDEN/HSYNC/VSYNC/PDATA[23:0] 输出（PDATA 供 `hdmi_top.v:57-59` 切 RGB565）。
- 首版实现 4 种图案（横彩条/竖彩条/棋盘/灰阶），后续 P1 接入图层混合时替换数据源。

### 2.3 约束与 SDC

| 文件 | 改动 |
|---|---|
| `hdmi.adc` | **零改动**（引脚不变，仅时钟频率变了，引脚约束与电平无关） |
| `hdmi_ph1.sdc` | 主时钟约束 107.5MHz → 25MHz（create_clock 周期 9.30ns → 40ns）；5×时钟 537.5 → 125MHz 相应改。逐行清单在 P0b 实施时给出（打开文件定位 create_clock 语句） |

**§2.3 增补（P0a 执行记录的必然结论，2026-10-27）**：官方 SDC 的
`create_generated_clock -multiply_by 4.76/23.8` 倍率错误（详见 §1.1），P0b 改写 SDC 时
一并修正为精确倍率，并补 clk0_out 域约束：

```sdc
# 修正后（25MHz 像素 / 125MHz 5×）：
create_clock -name SYS_CLK -period 20 -waveform {0 10} [get_ports {FPGA_SYS_50M_CLK_P}]
create_generated_clock -name pclk  -source [get_ports {FPGA_SYS_50M_CLK_P}] -master_clock SYS_CLK -multiply_by 2    [get_nets {pxlclk_i}]   ;# 50×2/4=25MHz（4 分频由 CLKC0/CLKC1 结构决定，以报告 Clock Summary 实测为准复核）
create_generated_clock -name sclk5 -source [get_ports {FPGA_SYS_50M_CLK_P}] -master_clock SYS_CLK -multiply_by 10   [get_nets {pxlclk_5x_i}] ;# 125MHz
create_generated_clock -name patclk -source [get_ports {FPGA_SYS_50M_CLK_P}] -master_clock SYS_CLK -multiply_by 2   [get_nets {clk25m}]      ;# 25MHz 图案计数域（官方遗漏）
```
> 注：`-multiply_by` 以"频率倍数"语义写入，P0b 跑完先看报告 Clock Summary 的
> C-Freq 是否等于 25/125，不等再按报告实测值反推修正（P0a 教训：写完必须回读验证）。

### 2.4 P0b 验收

- HDMI 与 VGA 同时出 640×480 彩条，边缘无抖动、无撕裂。
- 失败判据：出图但分辨率不符 / 时序错位。
- **降级路径（第二轮 §3.2）**：若加密 TMDS 链对 25MHz 像素时钟有隐藏问题（如内部
  固定行缓存），输出回退 1280×1024 + 640×480 画面 2× 最近邻放大；该决定必须先记入
  `DESIGN_DECISIONS.md` 再动代码。

### 2.5 P0b 执行记录（2026-10-27，TD 6.2.168116 CLI 实测 ✅）

工程：`project0/prj/p0b_640480/`；唯一新 RTL `project0/rtl/video_tpg_640480.v`
（真源）编译副本在工程内。决策偏离见 `DESIGN_DECISIONS.md` D-001..D-004。

改动清单落地核对：
- `al_ip/tx_pll.v`：CLKC0_DIV 43→40、CLKC0_CPHASE 42→39、CLKC1_DIV 10→40、
  CLKC1_CPHASE 9→39、CLKC2_DIV 2→8、CLKC2_CPHASE 1→7 + 头注释（共 7 处，与 §2.1 一致）
- `rtl/hdmi_top.v:61`：TPG 实例 `video_tpg_12801024p` → `video_tpg_640480`（端口一一对应）
- `adc_sdc/hdmi_ph1.sdc`：重写（`pclk/-divide_by 2`=25M、`sclk5/-multiply_by 2.5`=125M、
  补 `patclk/-divide_by 2`=25M；**注意 §2.3 增补里 `multiply_by 2` 写法有误**，
  实测 `multiply_by` 必须 ≥1，25MHz 域必须用 `divide_by 2`，以本节与
  `prj/p0b_640480/adc_sdc/hdmi_ph1.sdc` 为准）

实测结果（route 后，Slow+Fast 双 corner，`p0b_timing.rpt`）：

| 时钟 | C-Freq | fmax | Setup WNS | 判定 |
|---|---|---|---|---|
| pclk（像素域） | 25.000 | 111.8MHz | +31.06ns | ✓ |
| sclk5（TMDS 5×） | 125.000 | 496.3MHz | +5.99ns | ✓ |
| patclk（图案域） | 25.000 | 264.8MHz | +36.22ns | ✓ |
| SYS_CLK | 50.000 | 310.8MHz | +16.78ns | ✓ |

**四域全 0 违例**（STNS=HTNS=0），Hold WNS +0.223ns 0 违例；SDC 回读验证通过
（对比 P0a：官方 SDC 的 167 个伪违例在 P0b 约束体系下归零）。

资源：474 LUT (2.42%) / 319 REG (1.63%) / 24 IO / 0 BRAM / 0 DSP / 1 PLL。
**`p0b_640480.bit` 已生成**（629,636 字节，BIT-1004）。

验收待上板：HDMI + VGA 出 640×480 彩条、11 种图案轮播、边缘无抖动无撕裂。

## 3. 时序与资源预估

| 项 | P0a | P0b |
|---|---|---|
| 像素时钟 | 107.5 MHz | 25.0 MHz |
| 5× TMDS 时钟 | 537.5 MHz | 125.0 MHz |
| 帧率 | 1280×1024@60 | 640×480@60 |
| LUT 预估 | ≈1.5K（TPG+TMDS+PLL） | ≈1.2K（TPG 换成纯 Verilog，更小） |
| BRAM | 0（TPG 无帧缓存） | 0 |
| 关键时序 | 537.5MHz 串行化由 LVDS 硬核承担 | 125MHz 同左，余量更大 |
