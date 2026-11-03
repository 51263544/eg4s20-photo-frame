# EG4S20 数码相框 / 角色立绘播放器（P2 项目最终交付版 v60）

安路 **EG4S20BG256** FPGA 上从零搭建的片上系统：自写 AHB-Lite 总线 + 内嵌 **Cortex-M0** 软核，
从 TF 卡 exFAT 分区读取 640×480 24bit BMP 角色立绘，经 SDRAM 双缓冲送到 HDMI 输出，
并带 **6 种色彩滤镜、5 种转场、圆形涟漪/光带环境动效、WAV 音乐播放、频谱柱、麦克风输入、
矩阵键盘与数码管交互、TF 卡热插拔恢复、Flash 固化自启动**。

- 版本：**v60**（2026-11-02 19:25:18）
- 位流：`release/EG4S20_P2_Slideshow_v60.bit` — 648258 B，MD5 `FE453F83385603B6ED8E80DDFE048137`
- 固件：`release/m0_code_v60.hex` — 19910 B，MD5 `C1DA2F07FC7DB72A669521DB24B2D0E3`
- 开机签名（HDMI 最上方 8 条竖带的亮灭，确认烧的是这版）：`0xCF` → 第 **1 2 3 4 7 8** 条亮
- 资源：LUT 12668 / 19600 = **64.6%**、REG 5510 / 19600 = 28.1%、IO 58 / 188 = 30.9%
- 时序：`sys_clk` +2.217 / −0.017 ns、`clk`(50 MHz 音频) +5.108 / +0.128、`pxl_clk` +5.871 / +0.214、
  `pxl_5x` +5.727 / +0.244；仅有 SDRAM 硬核内部固有违例 `mem_clk` −2.692、`mem_clk_sft` −0.126 ns
  （从 P0 起一直存在，同构组合已上板长期验证）
- 规模：HDL 34 个文件 / 27820 行（其中 ARM Cortex-M0 核 `cortexm0ds_logic.v` 是 19913 行厂商 RTL，
  **项目自写约 7900 行**）、固件 1902 行；另有 7 个厂商加密 IP 文件仅随工程构建。逐文件行数见 `源码清单.md`。

---

## 1. 目录结构

```
rtl/                          FPGA 工程（TD 可直接打开/重建）
  run_p2.tcl                  一键综合实现脚本（TD 命令行）
  p2_sd_display.bit           本版位流（与 release/ 同一份）
  m0_code.hex                 本版固件镜像（Block_RAM.v 用 $readmemh 读它）
  user_source/hdl_source/
    p2/                       项目自写主体：顶层、sd_ctrl、bmp_pack、isp_filter、
                              keypad_4x4、seg_display、spectrum_bank、mic_adc、audio_ctrl
    soc/                      Cortex-M0 SoC：AHB 互联/解码/多路、Block RAM、UART、M0 核封装
    SD/                       TF 卡 SPI 读、帧 FIFO、SDRAM 控制器、视频时序
    IP/                       异步 FIFO 封装、PLL
    p0b/                      HDMI TMDS 发送（厂商）
    include/                  全局参数、SDRAM 加密 IP 封装
  adc_sdc/                    引脚约束 p2_pin.adc、时序约束 p2.sdc
  al_ip/                      tx_pll 等 IP 实例
firmware/                     固件（Keil MDK 工程）
  main.c                      主逻辑：轮播、音乐、按键、转场、角色包
  exfat.c/.h                  自写只读 exFAT 驱动（挂载、目录扫描、FAT 链）
  audio.c/.h                  音频寄存器封装（音量、速率、纯音、shelf、麦克风）
  sd_ctrl.h                   硬件寄存器定义（SD/bmp_pack/转场/音频）
  ahb_uart.h                  串口寄存器定义（本板串口通道未打通，见已知限制）
  startup_CMSDK_CM0.s         M0 启动文件
  code.sct                    scatter：0x0000 起 IROM 8 KB、0x2000 起 RAM 4.75 KB、栈顶 0x4000
  m0_p2.uvprojx               Keil 工程
tools/                        辅助脚本
  png2bmp.py                  素材转换（PNG→640×480 BMP，含 alpha 合成、16:9 面板适配）
  check_card.py               免管理员直接读卡并重放固件的 mount/scan 逻辑，检查卡结构
  check_pins.py               引脚约束自检
  verify_release.ps1          校验发布件 MD5（可选顺带检查卡）
  make_test_wav.py            生成测试音频
  jit_measure.py / ltsa.py / wavinfo.py / card_dump.py / scan_sim.py / rec3_seg.py / rec3_peaks.py
                              调试期取证脚本（抖动测量、频响、WAV 头解析、exFAT 重放、录音分析）
doc/                          设计与验收文档（见第 6 节索引）
skills/fpga-eg4s20-bringup/   本项目的工程经验手册（踩坑清单 + 调试方法论）
DESIGN_DECISIONS.md           决策记录 D-001…D-013
release/                      发布件（位流 + 固件镜像 + MD5SUMS.txt）
```

## 2. 系统结构

```
                  +------------------------- Cortex-M0 SoC (25 MHz) -------------------------+
  TF 卡 --SPI-->  sd_card_top --> sd_ctrl (AHB 从口) --+--> bmp_pack --> 写帧 FIFO --+
                  (6.25 MHz)      (命令/参数/流式搬运) |                              |
                                                        |                     SDRAM 双缓冲
  4×4 键盘 -----> keypad_4x4 (扫描/去抖/按键计数) ----+                              |
  4 位数码管 <--- seg_display <-- audio_ctrl (+0x18) --+                              v
  PWM 音频 ----> LMV358 低通 -> FM8002A -> 3.5mm/喇叭  |              读帧 FIFO --> video_delay
  麦克风 SPI ---> mic_adc ----> spectrum_bank ----------+                    |
                                                        |                    v
  HDMI TMDS <--- hdmi_tx <--- 转场/动效叠加 <--- isp_filter (3×3 色彩矩阵) <--+
```

- **总线**：自写 AHB-Lite，5 个从口 —— `0x0000_0000` Block RAM（代码/数据 16 KB）、
  `0x4000_0700` UART、`0x4001_0000` sd_ctrl、`0x4002_0000` 调试探针、`0x4003_0000` audio_ctrl。
- **帧缓冲**：片内 SDRAM 8 MB，两个 640×480×32bit 缓冲区交替，写新帧时显示旧帧，无撕裂。
- **音频**：44.1 kHz 16bit，一阶 sigma-delta 调制（默认，底噪最低）或 8bit 噪声整形 PWM 可选。

## 3. 构建

一次性依赖：**TD 6.2.1**（`D:\FPGA\bin\td_commands_prompt.exe`）、**Keil MDK 5**（`D:\Keil_v5\UV4\UV4.exe`）。

### 3.1 固件

```powershell
cd firmware
Start-Process 'D:\Keil_v5\UV4\UV4.exe' -ArgumentList '-r','m0_p2.uvprojx','-j0','-o','build.log' -Wait
```

- 退出码 0 = 干净，1 = 只有警告（本项目正常情况就是 1），≥2 = 有错误，看 `build.log`。
- 产物 `m0_code.hex` **必须复制到 `rtl/m0_code.hex`**：`Block_RAM.v` 里写的是
  `$readmemh("../../../m0_code.hex", mem)`，相对 RTL 源文件路径解析，所以只有放在 `rtl/` 下才会被综合进去。
  复制后核对两份 MD5 一致。
- 工程里唯一需要留意的设置：Keil 的 C/C++ 编译选项必须带 **MicroLIB**，scatter 用 `code.sct`
  （早期用标准库时，`__main` 的堆初始化会在这颗核上死锁，见 `DESIGN_DECISIONS.md`）。

### 3.2 位流

```powershell
cd rtl
Remove-Item -Recurse -Force .\p2_sd_display_Runs        # 必须删：否则 TD 报 Run syn_1 already existed
Remove-Item -Force .\p2_sd_display.al, .\p2_sd_display_inst.bid, .\al
& 'D:\FPGA\bin\td_commands_prompt.exe' run_p2.tcl *> build.log
```

- 约 100–150 s。**脚本退出码 0 不代表成功**，必须看日志末尾是否有 `P2_FLOW_DONE`，
  且 `p2_sd_display.bit` 时间戳是刚才。
- 新增 `.v` 文件必须手工加进 `run_p2.tcl:6` 的 `add_files { ... }`，否则不会被综合。
- LUT 超过约 75% 时布线会失败（`RUN-8102 ... Incremental route failed`），需要先优化面积。

### 3.3 烧写

TD 下载对话框里：

| 目的 | Mode | 说明 |
|---|---|---|
| 临时调试 | `PROGRAM_SRAM` | 掉电丢失，最快 |
| 固化自启动 | `PROGRAM_FLASH` | 写 SPI 配置 Flash，Speed 用 5 MHz；写完断电重上电验证 |

## 4. 按键

键盘是 4×4 矩阵，丝印 KEY15…KEY0（KEY15 左上）。**KEY15…KEY10 是纯 RTL 实现的滤镜**（不经固件、无延迟），
其余按键走"AII 事件队列"到固件，数码管会回显按键码。

| 键 | 功能 | 数码管反馈 |
|---|---|---|
| KEY15…KEY10 | ISP 滤镜：原图 / 灰度 / 怀旧 / 冷色 / 高对比 / 反色 | 无（RTL 直连） |
| KEY9 | 切换角色资源包（`F:\CHARS\` 下的目录），并播一次该包语音 | `0C01`/`0C02`… |
| KEY8 | 主音量循环 | `F300`/`F301`/`F302` |
| KEY7 | 音乐开 / 关 | `F701`/`F700`，无 WAV 时 `E00E`，失败 `E0nn` |
| KEY6 | 纯音开启时切换测试音频率 500/1k/2k/4k/8k；关闭时切调制器（sigma-delta / PWM） | `F10x` / `F00x` |
| KEY5 | 1 kHz 硬件纯音开关（自检 DAC，不经过 TF 卡） | `F005`/`F0FF` |
| KEY4 | 高频补偿 shelf：0 / +6 / +12 / +18 dB | `F200`…`F203` |
| KEY3 | 转场效果循环：无 / 淡入 / 擦除 / 百叶窗 / 白闪 | `F500`…`F504` |
| KEY2 | 环境动效：关 / 圆形涟漪 / 光带扫过 | `F600`/`F601`/`F602` |
| KEY1 | 频谱柱信号源：TF 卡播放器 / 麦克风 | `F400`/`F401` |
| KEY0 | 数码管实时显示麦克风 ADC 原始码 | 实时数值 |

## 5. TF 卡结构

```
F:\
├─ CHARS\
│   ├─ chenhai\      01_chenhai.bmp  02_chenhai_pond.bmp  voice.wav  char.ini
│   └─ enterprise\   03_enterprise.bmp                    voice.wav  char.ini
└─ <任意音乐>.wav    卡根目录的 WAV 当背景音乐（可多首，按名排序取第一首）
```

- 分区必须是 **exFAT**（固件只认 exFAT；superfloppy 和带 MBR 的都能挂载）。
- `char.ini` 只解析一行 `dwell=<秒>`（1…60），例如 `dwell=3`；不写则用默认 3 s。
- BMP 必须 **640×480 / 24bit / 未压缩**（`tools/png2bmp.py` 生成的就是这个规格）。
- 卡上不要有超过 2 个角色目录（驱动上限）；目录名任意，按目录项出现顺序编号。
- 换卡：**支持热插拔**（拔卡后传输失败 → 看门狗复位 TF 卡状态机 → 插新卡自动重新挂载并重启轮播），
  但演示场合建议断电换卡更稳。
- 卡结构自检：`python tools/check_card.py`（直接读盘符，不需要管理员权限）。

素材转换：

```powershell
python tools\png2bmp.py <素材目录> <输出目录>        # 默认白底合成 + 16:9 面板适配
python tools\png2bmp.py --bg black --fit contain ...  # 需要黑底/留边时
```

## 6. 文档索引

| 文件 | 内容 |
|---|---|
| `doc/PROJECT_STATUS.md` | **总览**：P0–P8 各阶段状态、剩余工作、复盘踩坑 |
| `doc/P2_BRINGUP.md` | 上板验收清单与实测记录（含串口通道遗留问题） |
| `doc/P2_SD_DISPLAY.md` | P2 显示通路的硬件设计与寄存器手册 |
| `doc/P5_P6_P7_ACCEPT.md` | 滤镜 / 音频 / 角色资源包的验收表与按键总表 |
| `doc/P8_RELEASE.md` | 发布记录：版本表、固化流程、烤机结果 |
| `doc/DEMO_SCRIPT.md` | 2–3 分钟演示视频分镜与讲解词 |
| `doc/P0_PLAN.md`、`doc/P1_UART.md` | 早期阶段记录（显示通路、M0 软核与 UART） |
| `doc/PIN_PROVENANCE.md` | 每个引脚结论的来源（原理图页码/厂商例程） |
| `doc/IP_PRECHECK.md` | 厂商加密 IP 的可用性核查 |
| `DESIGN_DECISIONS.md` | 决策记录 D-001…D-013（含每个决策的理由） |
| `skills/fpga-eg4s20-bringup/SKILL.md` | **工程经验手册**：这类项目最容易踩的坑与调试方法 |

## 7. 已知限制

1. **TF 卡带宽 226 KB/s**（实测，6.25 MHz SPI + 每扇区一条 CMD17）。理论极限 781 KB/s，
   71% 的时间花在命令与寻址上；改 CMD18 多块读可到 600–750 KB/s，但**仍不足以放视频**
   （640×480@30fps 需要 27 MB/s，差 120 倍）。动态壁纸因此用"实时动效层"替代。
2. **音频模拟链路高频衰减**（底板 LMV358 低通为压 195 kHz 载波设计）：2 kHz −10 dB、8 kHz −37 dB，
   听感偏闷。已用可调 high-shelf（KEY4）做软件补偿，默认 0 dB 是实测最平衡的一档。
3. **串口通道未打通**：原理图上 T7/T8 到 CH340 的映射是从文档文字层推断的，实测对调仍收不到数据；
   替代证据通道是数码管（`au_disp`）+ HDMI 条带签名 + 全屏闪码。详见 `doc/P2_BRINGUP.md`。
4. **轮播与音乐不能同时跑**（带宽 402 KB/s > 320 KB/s 上限）：当前实现为播放音乐时定格当前画面。
   若需要同时，可把音乐降到 22.05 kHz 单声道（合计 270 KB/s）。
5. 帧缓冲只有一个读口，因此转场是"单图 + 遮罩"型（淡入/擦除/百叶窗/白闪），
   做不了交叉溶解；多图层真的 alpha 叠加需要第二个读流（见 D-012 替代方案）。
6. 每帧载入约 4.07 s（1801 个扇区 × 2.26 ms），若改 CMD18 预计能压到 ~1.3 s。

## 8. 许可与致谢

- 项目自写部分（`p2/`、`soc/`、`SD/`、`firmware/`、`tools/`、`doc/`）：随比赛提交使用。
- `p0b/`（HDMI TMDS 发送）与 `include/*.enc.v`（SDRAM 控制器）、`IP/*` 等为**厂商随板提供的加密 IP**，
  仅用于本工程构建，不可单独分发或反编译。
