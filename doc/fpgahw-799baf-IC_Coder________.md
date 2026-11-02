# IC Coder 第二轮指令：六项决策 + 修订执行计划

> 用法：紧接上一轮的扫描报告，把 `===` 之间整段发给 IC Coder。
> 前提：那台机器上 TD 6.2.1、Keil MDK、ARM CMSIS 包（`Keil::V2M-MPS2_CMx_BSP`）均已安装。

===

# 0. 环境状态确认

- TD 6.2.1 ✅ 已装（本机 license 为 NODELOCKED，至 2029）
- Keil MDK ✅ 已装
- ARM CMSIS ✅ 已装（`Keil::V2M-MPS2_CMx_BSP` 1.7.1+，器件 `CMSDK_CM0`）
- 需要新建的：**M0 固件工程**（官方只有 startup.s 和空循环 hex，不能用于串口打印）
- 你的 7 条扫描发现我全部认可，特别是「加密 VHDL 不可仿真」「6_SD 写通路不可用」「引脚表是 HX4S20C」这三条，直接改变了后面的做法。

# 1. 六项决策（按此执行，不要再问）

## Q1 允许重写 `doc/hw/config.json` 吗？→ 允许，但必须做成"三件套"

重写规则：

1. 原文件改名为 `config.hx4s20c.bak.json`，保留不删。
2. 新文件 `config.json` 描述**大拇指底板**，格式保持原样，但每个引脚必须带证据字段：
   ```json
   "hdmi_clk_p": { "pin": "P1", "io": "LVDS33", "src": "EG4S20/微处理器原理综合设计底板/板卡和引脚说明.pdf#3.3" }
   ```
   或引用官方 `.adc` 的具体文件与行号（如 `10_VGA_hdmi_tx_display_MB/source_code/adc_sdc/hdmi.adc:2`）。
3. 同步生成 `doc/hw/PIN_PROVENANCE.md`：一行一个信号，列 `信号 | 引脚 | 来源文件:行 | 备注`。
4. 同步生成 `project0/constraints/board_pinmap.adc`，与 `config.json` **逐条交叉校验**（数量、名称、电平一致），校验脚本放 `project0/tools/check_pins.py`。
5. 若某信号找不到任何官方证据，**标记为 `"status":"unverified"` 并单列一节给我确认**，不许猜。

## Q2 P0 拆成 P0a / P0b 吗？→ 采纳，并且再加一个 P-1（见第 2 节）

- **P0a**：官方 `10_VGA_hdmi_tx_display_MB` 原样编译下载，出 **1280×1024@60 彩条**（HDMI + VGA 同时）。目的是证明：引脚对、TMDS 通路对、加密 VHDL 能工作、PLL 107.5/537.5MHz 正常。
- **P0b**：只改 PLL 与 H/V 时序参数，输出 **640×480@60（像素时钟 25.175MHz，5x = 125.875MHz）**。**不许改加密模块、不许改 TMDS 结构**，只动参数。
- 任何一步不出图，立刻停并上报，不许自行加补丁。

## Q3 P0 要不要串口打印？→ 不要。UART 移到 P1

- P0a/P0b 的唯一验收标准是**屏幕出彩条**，不涉及任何固件。
- 你的判断（SoC 无 UART、固件工程只有 startup）是对的：串口是调试基础设施，但它不该阻塞显示验证。
- 新增 **P1 = M0 最小系统 + UART 外设 + 固件工程**，见第 2 节。这一步做完，后面每一步都有 printf 可用，收益远大于塞进 P0。

## Q4 P2 用 `lab_ex4_tf` 的 SD 控制器吗？→ 采纳，替代 6_SD

理由：`6_SD` 缺写数据端口、初始化没有 400kHz 阶段、PLL 锁死 25MHz，属于教学半成品；`lab_ex4_tf` 是纯 Verilog、带 200kHz 初始化与扇区读写、可 iverilog 仿真，是 2026 赛题官方验证过的实现。

执行规则：

1. 只搬**纯 Verilog 逻辑**，落到 `project0/rtl/sd/`，文件重命名为 `sd_ctrl_*.v`。
2. 每个文件头注明来源路径与原始文件名。
3. 不搬它的引脚约束、不搬它依赖的 IP、不搬它的顶层。
4. 必须给 `sd_ctrl` 写 iverilog testbench（`project0/tb/tb_sd_ctrl.v`），用行为级 SD 卡模型验证：复位→CMD0→CMD8→ACMD41→CMD17 读一个扇区。
5. 接口对外统一成 AHB 从设备（`0x4000_0300`），寄存器：`CMD / ARG / STATUS / RDATA / RDLEN / RESP0..3`。
6. 我们**只需要读**（资源包在 PC 上做好），写通路保留但可不测；`STATUS` 里给出 `card_ready / busy / error_code`。

## Q5 P3 用 125MHz（lab_ex4）还是 150MHz（7 例程）？→ 用 **125MHz 的 2026 版**

理由：

1. 与 2026 赛题例程同源，在 TD 6.2.1 下验证过，版本风险最低。
2. 640×480@60 的像素带宽只有 25MHz 级别，显示读 + 图层写加起来远低于 125MHz 能提供的余量，150MHz 没有任何收益。
3. 三套加密 IP 只保留一套进工程（`user_source/ip_source` 里选 125MHz 那套），其余物理删除或移出工程，避免同名模块冲突。
4. 125MHz 由 PLL 从 50MHz 倍频，注意 IP 要求的相位关系（是否有 180° 相移时钟），照抄 lab_ex4 的 PLL 配置。

## Q6 键盘引脚用 col=E11,D11,C11,F10 / row=E10,C10,F9,D9 吗？→ 采纳，但先做两件事

1. **引脚冲突审计**：把这 8 个脚与现有已分配的 35 个脚做矩阵比对（VGA 16 + HDMI 4 + SD 4 + 音频 1 + ADC 4 + SWD 2 + clk/rst 2 + LED 1）。我这边初查**无冲突**，但你要用脚本复核并输出结果表。
2. **独立键盘测试工程**：在 `project0/test/keypad/` 建一个只做键盘扫描的最小工程，数码管/LED 显示键值，先单独验证 16 个键全对，再并入主工程。扫描逻辑（行输出列输入 or 列输出行输入、消抖时长）以官方 `实验系列一/9 keyboard` 为准。

# 2. 修订后的阶段表（编号以此为唯一准）

| 阶段 | 内容 | 验收（成功） | 失败判据 |
|---|---|---|---|
| **P-1** | 资产治理与 IP 预检（不写 RTL） | config 三件套完成；引脚冲突表为空；SDRAM/TMDS/PLL 在 TD 6.2.1 综合+布线通过 | 任一 IP 综合报错或 license 缺失 |
| **P0a** | 官方彩条 1280×1024 | HDMI + VGA 同时出彩条，稳定 10 分钟 | 黑屏/花屏/间歇闪 |
| **P0b** | 改 640×480@60 | 两路都出 640×480 彩条，边缘无抖动 | 出图但分辨率不符 / 时序错位 |
| **P1** | M0 最小系统 + UART | 串口每 500ms 打印一行计数；Keil 可单步 | 无输出 / HardFault |
| **P2** | SD 控制器挂 AHB | 串口打印 LBA0 前 16 字节（`EB 3C 90`） | 卡片初始化超时 |
| **P3** | SDRAM 双缓冲 + 单图 | 屏幕显示 SD 里的 BMP，切图不撕裂 | 撕裂 / 颜色错 / 只显示半屏 |
| **P4** | 键盘 + 图层 Alpha | 按键切图层与 alpha，实时生效 | 按键无响应 / 边缘黑边 |
| **P5** | ISP 滤镜 | 6 组预设切换即时生效 | 画面延迟 > 1 帧 |
| **P6** | 音频 PWM + FFT | 放歌出声，柱子随节奏动 | 无声 / 频谱不动 |
| **P7** | 资源包与换卡 | 换卡自动切角色，无需重烧 | 需要重新下载才生效 |
| **P8** | 收尾 | WNS ≥ 0、连续 2 小时、Flash 固化 | 时序不收敛 |

## P-1 必须先做的 IP 预检（这是硬门槛）

建一个最小 TD 工程 `project0/test/ip_check/`，只放：

1. `tx_pll`（P0a 用 107.5/537.5MHz，P0b 用 25.175/125.875MHz，两个都生成一份）
2. `hdmi_top` + 加密 VHDL（`hdmi_tx.vhd`、`DVITransmitter.enc.vhd`）
3. 选定的 125MHz `sdr_as_ram` IP
4. 本板 `.adc`

跑完 Read Design → Optimize → Place & Route，输出：**综合是否通过、LUT/FF/BRAM 占用、最高可达频率、有没有 IP license 报错**。

> ⚠️ 特别说明：**帧缓存不能用 BRAM 替代**。EG4S20 总共 504Kb BRAM ≈ 63KB，而 640×480×16bit 一帧要 600KB，差一个数量级。所以片内 SDRAM IP 是**硬依赖**，如果它在本版本 TD 下不可用，整个方案要改（只能走"按行流式直出、无整帧缓存"的路子，复杂度高一个档），必须第一时间告诉我，不要自己绕。

# 3. 设计冻结与降级路径（写进 `project0/doc/DESIGN_DECISIONS.md`）

1. **处理分辨率冻结为 640×480@60**；输出分辨率可配（640×480 原生 / 1280×1024 二倍放大）。像素流水线只认 640×480，显示层做适配，二者解耦。
2. 若 P0b 证明加密 TMDS 不支持 640×480（例如内部有固定行缓存），**降级方案**：输出保持 1280×1024，把 640×480 帧缓存做 2× 最近邻放大铺满画布，UI 重新排版。**不许改加密模块**。
3. 若 P3 发现 SDRAM 带宽不足（撕裂/欠载），降级顺序：① 写入改为整帧突发 ② 降到 8bit 调色板（300KB/帧）③ 降到 320×240 内部处理 + 2× 放大输出。
4. **任何降级必须先在 `DESIGN_DECISIONS.md` 记录原因与数据，再改代码。**

# 4. 验证策略（因为加密 IP 不可仿真）

| 类型 | 模块 | 验证方式 |
|---|---|---|
| 纯 Verilog | `sd_ctrl_*`、`bmp_parser`、`layer_blend`、`isp_3x3`、`fft_512`、`keypad_scan`、`pwm_audio`、`ahb_uart` | **iverilog TB 必须过**，覆盖正常 + 边界（空图/坏头/单色图/满量程音频） |
| 加密 VHDL / IP | `hdmi_top`、`DVITransmitter`、`sdr_as_ram` | 上板验证 + ChipWatcher 抓内部信号 |
| 系统级 | 整机 | 每阶段留可观测点：UART 计数、状态 LED、数码管状态码、帧计数寄存器 |

**每个阶段必须同时给出"成功判据"和"失败判据"**，只写成功标准不算完成。

# 5. 本轮交付物（先给这些，一行 RTL 都不要写）

1. `doc/hw/config.json` + `PIN_PROVENANCE.md` + `board_pinmap.adc` + `check_pins.py`（含运行结果：0 冲突）
2. `doc/IP_PRECHECK.md`：三套 SDRAM IP 的来源/时钟/资源对比 → 选定一套 → TD 6.2.1 实测结果
3. `doc/P0_PLAN.md`：P0a→P0b 的**逐行改动清单**（PLL 参数、H/V 前后肩、DE 极性、要改哪个文件的哪几行）
4. `doc/P1_UART.md`：`ahb_uart` 端口表 + 寄存器表（`0x4000_0700`）+ Keil 工程文件清单 + `code.sct` 修正方案
5. 修订后的 `project0/` 目录树（含 `rtl/ tb/ m0/ constraints/ tools/ doc/ test/`）
6. 一份「引脚总表」：35 个已用脚 + 8 个键盘脚，标出每个脚的用途、电平、是否复用

我确认这 6 份之后再放你进 P0a。

# 6. 本轮追加禁止项

- 禁止用 BRAM 替代帧缓存（容量差 10 倍，见第 2 节说明）
- 禁止修改任何 `.enc.v` / 加密 VHDL / 官方 IP 的内部参数
- 禁止在 `config.json` 写入任何无证据来源的引脚
- 禁止跳过 P-1 的 IP 预检直接写 P0 代码
- 禁止把三套 SDRAM IP 同时放进工程"先试试看"
- 禁止在固件工程里继续用 `code.sct` 的 `RW_IRAM1 0x20000000`，除非同时启用 Port1 的 BRAM（否则加全局变量必 HardFault）

# 7. 开工

先输出第 5 节的 6 份交付物，等我确认。
=== 
