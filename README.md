# EG4S20 相册播放器（SD 卡 BMP 轮播 + WAV 音乐 + 实时频谱）

安路 EG4S20BG256（20K LUT / 504 Kb BRAM / 片内 64 Mb SDRAM）+ 内嵌 ARM Cortex-M0 软核的
课程设计/参赛作品。插上 SD 卡即自动播放卡内的立绘壁纸，带 6 种 ISP 滤镜、8 段实时频谱柱、
WAV 音乐播放和麦克风输入，全部由一块 FPGA 加一颗 M0 软核完成，无外部编解码芯片。

- 视频输出：HDMI 640×480@59.94（纯 TMDS，无 DDC/EDID）
- 显示：SDRAM 双缓冲，`WRITE_V_FLIP` 自动纠正 BMP 的自下而上存储
- 音频：RTL 内的 1 bit sigma-delta 调制器（默认）/ 8 bit 噪声整形 PWM，输出到板上 PWM 低通 + 功放
- 频谱柱：8 段两极点对数滤波器组（不用 FFT，无乘法器、无 ROM）
- 存储：exFAT 只读解析器，支持长文件名、跨扇区目录项、NoFatChain 连续文件、superfloppy 卡
- 启动：已固化到配置 Flash，上电自启动

## 目录结构

```
rtl/                 FPGA 工程（安路 TD 直接打开这个目录跑 run_p2.tcl）
  run_p2.tcl         综合/布局布线/bitgen 脚本
  m0_code.hex        M0 固件镜像（RTL 通过 $readmemh 加载，路径相对 soc/ 为 ../../../m0_code.hex）
  user_source/hdl_source/
    p2/              ★ 本项目自写的 RTL：顶层、sd_ctrl、bmp_pack、isp_filter、audio_ctrl、
                       spectrum_bank、mic_adc、keypad_4x4、seg_display
    soc/             M0 SoC 集成（AHB 互连/译码/MUX/BRAM/UART/cortexm0ds_logic）
    SD/              厂商 SD 卡与 SDRAM 帧缓冲 RTL
    IP/              异步 FIFO、PLL
    p0b/             HDMI/TMDS 发送（VHDL）
    include/         全局定义与加密的 SDRAM IP（.enc.v）
  adc_sdc/           引脚约束 p2_pin.adc、时序约束 p2.sdc
  al_ip/             生成的 PLL 实例
firmware/            M0 固件（Keil MDK）
  main.c             主流程：轮播、按键、音乐、频谱源、角色包切换、SD 热插拔恢复
  exfat.c/.h         exFAT 只读解析（mount / 目录扫描 / FAT 链）
  audio.c/.h         音频与频谱寄存器驱动、WAV 头解析、测试音
  sd_ctrl.h          AHB 从口寄存器定义
  code.sct           分散加载文件（MicroLIB 栈放到 0x3A00）
  m0_p2.uvprojx      Keil 工程
doc/                 设计与验收文档（见下）
tools/               辅助脚本
  png2bmp.py         素材转换：PNG → 640×480 24bit BMP（--fit panel 适配 16:9 屏）
  check_card.py      离线校验 SD 卡结构（免管理员裸读，重放固件同一套扫描逻辑）
  verify_release.ps1 一键校验发布件 MD5（可选校验插着的卡）
release/             冻结的发布件（bit + hex + MD5SUMS.txt）
skills/              AI 协作过程中沉淀的工程经验（踩坑清单）
DESIGN_DECISIONS.md  设计决策记录 D-001…D-013
```

## 构建

### 1. 固件（Keil MDK 5，ARMCC 5）

```
UV4.exe -r firmware\m0_p2.uvprojx -j0 -o build.log     # 退出码 0/1 = 成功（1 只是警告）
```

产物 `firmware\m0_code.hex` 必须**同时**拷贝到：

- `rtl\m0_code.hex`（RTL 综合时 `$readmemh` 读这个）

### 2. FPGA（安路 Tang Dynasty）

```
cd rtl
td_commands_prompt.exe run_p2.tcl        # 约 100 秒
```

成功标志：控制台末尾出现 `P2_FLOW_DONE`，且 `p2_sd_display.bit` 生成。
**重新构建前先删 `p2_sd_display_Runs` 目录和 `p2_sd_display.al`**，否则 TD 报
`PRJ-8806` / `PRJ-5301` 且不出 bit。

### 3. 烧写

- 调试：下载模式选 `PROGRAM_SRAM`（掉电丢失，每次上电要重下）
- 固化：下载模式选 `PROGRAM_FLASH`、Speed 5 MHz、MemorySize 默认 → Program → 断电重上电，
  之后上电自启动

## 操作说明

| 按键 | 功能 | 数码管反馈 |
|---|---|---|
| KEY15…KEY10 | 6 种 ISP 滤镜：原图 / 灰度 / 怀旧 / 冷色 / 高对比 / 反色（纯 RTL，不经 M0） | 显示编号 0…5 |
| KEY9 | 切换角色包（多包循环）；单包时重播该包语音 | `0Cxx` |
| KEY8 | 主音量 100 / 50 / 25 % | `F30x` |
| KEY7 | 音乐开 / 关（`/music*.wav`，卡根目录） | `F701` / `F700` |
| KEY6 | 纯音开启时切频率 500/1k/2k/4k/8k；否则切调制器 | `F10x` / `F00x` |
| KEY5 | 1 kHz 硬件测试纯音开 / 关（绕过 SD 与固件，用于验 DAC） | `F005` / `F0FF` |
| KEY4 | 软件高频补偿 0 / +6 / +12 / +18 dB（板载模拟链路低频响较窄） | `F20x` |
| KEY3 | 与 KEY4 同义（兼容早期版本） | `F20x` |
| KEY2 | 音乐诊断：采样率 / 声道位深 / FIFO 水位 / 欠载计数 | `AC44` `0210` `1C0` `A0xx` |
| KEY1 | 频谱柱信号源：SD 播放器 ↔ 麦克风 ADC | `F400` / `F401` |
| KEY0 | 实时显示麦克风 ADC 原始码（调试用） | 十六进制 |

数码管最左边一位是第 1 位；任何按键按下后会先显示该键的位图（`0001`=KEY0 … `8000`=KEY15）。

## SD 卡结构

```
卡根目录/
  music*.wav                 ← 音乐（可多首，KEY7 播第一首，循环）
  CHARS/
    <角色名>/
      *.bmp                  ← 640×480 24bit BMP，按文件名顺序轮播
      voice.wav              ← 可选，切到该角色时播一次
      char.ini               ← 可选，只解析 dwell=秒数（1…60）
```

兼容旧布局：如果卡根目录直接放 BMP（没有 `CHARS/`），也能正常轮播。

卡必须是 **exFAT**（FAT32/NTFS 不认）。分区表可以没有（superfloppy 也支持）。
素材转换：

```
python tools\png2bmp.py <PNG目录> <输出目录> --fit panel
```

## 发布件与校验

| 文件 | MD5 | 大小 |
|---|---|---|
| `release/p2_sd_display.bit` | `1F4BFAC58E9612AFD868D0C73FFD55E2` | 648 258 B |
| `release/m0_code.hex` | `FAD1C79C10CD1F09AC063E44E8578D27` | 19 540 B |

一键校验：`powershell -ExecutionPolicy Bypass -File tools\verify_release.ps1 [-Card F]`
（`-Card F` 顺便按固件逻辑离线校验插着的卡）

开机签名：HDMI 上电后先显示 8 条竖条，`0x3D` 对应第 1、3、4、5、6 条白，约 0.3 s 后进入画面。

## 资源与时序（v53）

- LUT 8 211 / 19 600（41.9 %）
- `sys_clk` 25 MHz：setup +0.524 ns / hold +0.046 ns
- `clk` 50 MHz（音频）：+5.477 / +0.102 ns
- `pxl_clk` 25 MHz：+16.301 / +0.214 ns
- 唯一负 slack 是片内 SDRAM 硬核（`EG_PHY_SDRAM_2M_32`）接口的固有路径（−2.692 ns，
  100 % cell 固有延迟、0 网线），同构配置历来上板验证正常

## 已知限制

- **串口从未打通**：`T7/T8` 的映射是从核心板原理图文本层推断的，实测（含对调）无输出，
  判断为板级连线问题。调试信息改由「8 位数码管 + HDMI 条带签名 + 闪码」提供。
- **模拟音频带宽窄**：底板 `LMV358` + RC 在 2 kHz 以上衰减明显（4 kHz −19 dB、8 kHz −37 dB），
  这是厂商为压 195 kHz 载波付出的代价，只能用软件高频补偿部分弥补。
- **轮播与音乐不能同时**：SPI 6.25 MHz 实测上限 ≈ 320 KB/s，壁纸 226 KB/s + 44.1 kHz 立体声
  176 KB/s = 402 KB/s。当前实现为「放音乐时画面停住」。
- **载入速度** 约 4.07 s/帧（理论 1.18 s），差额是每扇区固定的 CMD17 往返开销。

## 文档索引

| 文件 | 内容 |
|---|---|
| `doc/PROJECT_STATUS.md` | 各阶段状态、剩余工作、复盘 |
| `doc/P5_P6_P7_ACCEPT.md` | 滤镜 / 音频 / 角色包的验收记录与按键总表 |
| `doc/P2_BRINGUP.md` | SD→显示通路验收、时序结论、串口遗留说明 |
| `doc/P2_SD_DISPLAY.md` | 方案（时钟、双缓冲、寄存器表、故障码） |
| `doc/P8_RELEASE.md` | 固化流程、版本冻结、验收表 |
| `doc/DEMO_SCRIPT.md` | 2–3 分钟演示分镜 |
| `doc/P1_UART.md` / `doc/P0_PLAN.md` / `doc/PIN_PROVENANCE.md` | 早期阶段与引脚溯源 |
| `DESIGN_DECISIONS.md` | 13 条关键设计决策及理由 |
| `skills/fpga-eg4s20-bringup/SKILL.md` | 踩坑合集（AHB 数据相、exFAT 陷阱、音频/频谱、时序与工具链） |

## 依赖与许可说明

- 厂商提供的加密 IP（`rtl/user_source/hdl_source/include/*.enc.v`、`p0b/*.enc.vhd`）与
  `rtl/user_source/hdl_source/soc/cortexm0ds_logic.v` 为 ARM/安路版权素材，**仅供本项目构建使用**，
  是否公开分发请自行确认许可。
- 需要安路 Tang Dynasty 6.2.1（含 EG4S20 器件库）与 Keil MDK 5 + ARMCC 5。
- 本项目自写部分（`rtl/user_source/hdl_source/p2/`、`firmware/`、`tools/`、`doc/`）可自由用于学习与教学。
