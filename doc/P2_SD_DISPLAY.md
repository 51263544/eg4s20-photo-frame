# P2 方案 — SD 卡图片读取与循环播放（p2_sd_display）

> 生成：2026-10-27
> 前置：P0（显示链/SDRAM IP 验证）、P1（M0 SoC + UART）均已上板通过
> 需求：SD 卡（exFAT）存放 640×480 24bit BMP，上电后自动循环播放，每张停留 N 秒（可配）

## 0. 已确认决策（2026-10-27 用户选定）

| # | 决策项 | 结论 |
|---|---|---|
| D-201 | 文件系统 | **exFAT**（64G 卡原生格式，不改格式） |
| D-202 | 图片格式 | **640×480 24bit BMP** 存卡（PNG 设备端解码不可行：32KB 解压窗口 vs 16KB 总内存；PC 侧提供 PNG→BMP 转换脚本） |
| D-203 | 播放节奏 | **固定停留 N 秒**（编译宏默认值 + UART 命令在线修改） |
| D-204 | 架构 | **M0 发令 + 硬件搬运**：M0 只做 exFAT 解析并下发扇区读命令，像素流由 RTL 直写 SDRAM 帧缓冲 |

## 1. 参考工程结论（已核实）

| 来源 | 可复用资产 | 关键结论 |
|---|---|---|
| `work/kangxin_2026/lab_ex4_tf/` | sd_card_top 及其子层（SD/spi_master/sd_card_cmd/sd_card_sec_read_write）、wfifo/rfifo、frame_read_write、color_bar、video_timing_data、video_delay、sdram 控制器 | FIFO IP 为**纯可综合 RTL**（灰码指针 + infer BRAM），无加密依赖，可直接复制；注意文件名与模块名不一致：`afifo_16_32_256.v` 内是 `wfifo_32_32_512`，`afifo_32_16_256.v` 内是 `rfifo_32_32_512` |
| 同上 | `IP/sdram.v` | EG4S20 **片内硬核 SDRAM**（`EG_PHY_SDRAM_2M_32`，2M×32bit=8MB，无外部引脚）；ADDR_BITS=21（字地址）与硬核容量精确对应 |
| 同上 | `IP/sys_pll.v` | EG_PHY_PLL 纯参数化包装，**可手改频率**。现配置 VCO=1GHz（C0_DIV=10→100M，C1/C2_DIV=8→125M）。反推公式 VCO = FIN×C0_DIV×FBCLK_DIV/REFCLK_DIV = 50×10×2 = 1000MHz，与 C0=100M/C1=125M 自洽 |
| 同上 | `SD/sdram.v` | SDRAM 控制器（App_wr_*/App_rd_* 用户接口 → PHY 原语），Clk_sft 为反相时钟（C1_CPHASE=7 与 C2_CPHASE=3 相差 DIV/2 = 180°） |
| P0b `prj/p0b_640480/` | tx_pll（25.175M + 5x）、hdmi_tx 全链（hdmi_tx.vhd + enc_file 三件套） | 已上板验证的 640×480@60 输出链，原样复用 |
| P1 `prj/p1_m0_uart/` | CortexM0_SoC + Interconnect（P2/P3 口空闲）+ ahb_uart + Block_RAM 16KB | Decoder 直接启用 Port2 挂 sd_ctrl |

## 2. 系统架构

```
                     50MHz clk ─┬─→ sys_pll(改频) ─┬─ C0: 25MHz  sys_clk ──→ M0 SoC + sd_ctrl + sd_card_top + packer
                                │                  ├─ C1: 100MHz mem_clk ─→ sdram 控制器
                                │                  └─ C2: 100MHz 反相 mem_clk_sft
                                └─→ tx_pll(P0b原样) ─┬─ 25.175MHz pxl_clk ─→ 显示时序 + hdmi_tx
                                                     └─ 125.875MHz 5x ─→ hdmi_tx 串化
                                                （EG4S20 共 2 个 PLL，soc_pll 退役，SoC 改用 sys_pll C0）

 M0(25M) ──AHB P2──→ sd_ctrl 寄存器 ──发令──→ sd_card_top(SPI 6.25M) ──512B/扇区流──→ packer(24bit组包) 
                                                                        │ {R,G,B,0}
                                          wfifo_32_32_512(25M→100M CDC) ↓
                                          frame_read_write(双缓冲写侧) → sdram 控制器 → 片内 SDRAM
                                                                        │
 显示侧：color_bar时序(25.175M) → read_req/ack → frame_read_write(读侧) → rfifo(100M→25.175M CDC)
         → video_delay(2拍对齐) → hs/vs/de + RGB888 → hdmi_tx(P0b链) → HDMI
```

- 帧缓冲双缓冲：BUF0=0x00000、BUF1=0x4B000（307200 字地址，21bit 内）。写"非显示缓冲"，写完经 `write_finish_toggle` 提交切换。
- **SD 域 = 25MHz = AHB 域，控制路径零 CDC**；仅数据面经 wfifo/rfifo 跨域（lab 验证过的结构）。
- SPI 时钟 25M/4 = 6.25MHz → 每帧 921.6KB ≈ **1.2s**；停留 N 秒默认 3s（≥2s 时体验自然）。
- `WRITE_V_FLIP=1` 处理 BMP 自下而上存储；显示首图提交前黑屏（display_valid 门控）。

## 3. RTL 模块清单

新增（`project0/rtl/p2/`）：

| 模块 | 职责 | 来源 |
|---|---|---|
| `p2_sd_display.v` | 顶层：PLL 例化 + SoC + SDRAM 显示链 + SD 链互连 | 新写（P1 SoC + lab 拓扑拼装） |
| `sd_ctrl.v` | AHB-P2 从设备：寄存器堆 + raw 扇区读路径（512B 缓冲供 M0 解析 exFAT）+ 流路径仲裁 | 新写 |
| `bmp_pack.v` | 字节流→BMP 像素组包（24bit 拼装、pixel_offset/file_len 裁剪、{R,G,B,0} 输出） | 改造自 lab `bmp_read.v` 打包逻辑 |
| `sys_pll.v` | C0=25M/C1=100M/C2=100M 反相 | 复制 lab 版改 4 个参数 |

复制（原样）：`sd_card_top.v`（kangxin 版，含 spi_master/sd_card_cmd/sd_card_sec_read_write）、`wfifo_32_32_512`、`rfifo_32_32_512`、`frame_read_write.v`、`frame_fifo_write.v`、`frame_fifo_read.v`、`SD/sdram.v`、`IP/sdram.v`、`include/sdr_*.enc.v` 三件套（**成套引入，include 目录结构与 lab_ex4_tf 一致**）、`color_bar.v`+`video_define.v`、`video_timing_data.v`、`video_delay.v`、P0b `tx_pll`（al_ip + ipc）、P0b `hdmi_tx` 全链、P1 SoC 全套。

### 3.1 sd_ctrl 寄存器（AHB @ 0x4000_0800，Decoder Port2）

| 偏移 | 名称 | 读/写 | 说明 |
|---|---|---|---|
| 0x00 | CTRL | W | bit0: RAW_READ 脉冲（读 SEC_ADDR 到缓冲）；bit1: STREAM 脉冲（读 SEC_ADDR 流入 packer）；bit2: PACK_RESET 脉冲（复位组包计数） |
| 0x04 | STATUS | R | bit0: sd_init_done；bit1: hw_busy（扇区读进行中）；bit2: stream_done_toggle；bit3: raw_done；[7:4]: sd 卡状态码 |
| 0x08 | SEC_ADDR | W | 32bit 扇区地址（先写值再发命令） |
| 0x0C | RAW_DATA | R | raw 路径数据口（顺序读 512B，内部地址自增；RAW_READ 时复位） |
| 0x10 | PIXEL_OFFSET | W | 组包起始字节（典型 54） |
| 0x14 | FILE_LEN | W | 文件总字节数（组包停止条件） |

命令协议：`PACK_RESET → 写 PIXEL_OFFSET/FILE_LEN → 逐扇区 [写 SEC_ADDR → CTRL.STREAM]`；扇区间隙硬件等待（sd_card_top 空闲），字节计数跨扇区连续。M0 端 raw 读法：`写 SEC_ADDR → CTRL.RAW_READ → 轮询 STATUS.raw_done → 循环读 RAW_DATA×512`。

### 3.2 显示读出侧（全部 25.175M 域）

`video_timing_data`（内含 color_bar 时序，VS 沿发 read_req）→ `frame_read_write` 读侧 → `video_delay`（read_en 提前 2 拍对齐）→ hdmi_tx。时序参数 640×480@60（800×525，HS/VS 低有效），与 P0b tx_pll 25.175M 精确匹配。`color_bar.v` 的 rgb 输出悬空（只当时序发生器，lab 同款用法）。

## 4. M0 固件（Keil，16KB 代码空间）

```
startup + main + exfat.c + sd_ctrl 驱动 + uart 命令 ≈ 6~9KB（预算内）
```

- **只读 exFAT 解析**：MBR→PBR（校验 "EXFAT "，取 FAT 起点/簇数/根目录簇）→ 根目录簇链扫描目录项集合（0x85 File + 0xC0 Stream + 0xC1×n Name，UTF-16LE 文件名）→ 过滤 `.BMP` → first_cluster + valid_data_length → FAT32 位项链走簇（NoFatChain=1 时直接连续读）。
- **播放主循环**：对每个文件：PACK_RESET → raw 读第 1 扇区校验 "BM"/640/480/24bit/0 压缩（防呆）→ 写 PIXEL_OFFSET/FILE_LEN → 按簇链逐扇区 STREAM → 等全部字节流完 → 等 write_finish 提交切换 → 停留 N 秒（软件延时）→ 下一张；播放表循环。
- **UART 控制**（115200-8N1，复用 P1）：`N<秒>\n` 修改停留时长（1~60s），`?` 打印状态（init/文件数/当前文件序号）。默认停留 = 编译宏 `DEFAULT_DWELL_SEC`（3s）。
- 分散加载沿用 P1 方案 A（RW_IRAM1 0x00000000 16KB），文件名排序首版按目录物理序（循环播放足够），排序功能留 P3。

## 5. 约束与工程构建（prj/p2_sd_display/）

- `p2_pin.adc`：P1 全部引脚 + SD 四线（F13/F14/F15/D14，LVCMOS33）+ LED B14；HDMI/VGA 同 P0b。
- `p2.sdc`：sys_clk 25M（create_clock 于 PLL 输出，C0/C1/C2 + tx_pll 两输出 create_generated_clock）；片内 SDRAM 无引脚约束；注意 TD 对 EG_PHY_PLL 时钟透明的既有经验（P0b SDC 修正先例）。
- `run_p2.tcl`：以 run_p1.tcl 为模板，readmemh 相对路径 `../`、双重执行现象照旧。
- SDRAM IP 三件套 include 结构与 lab_ex4_tf 一致；**实施首步先单独验证 sdram 控制器综合通过**（P-1 教训：成套文件缺一即失败）。

## 6. PC 侧工具

`project0/tools/png2bmp.py`：文件夹内 PNG/JPG → 640×480 24bit BMP（Pillow 缩放居中，输出到指定目录，文件名保留排序序号）。工作流：素材 → 跑脚本 → 产物整批拷入 exFAT 卡根目录。

## 7. 风险与对策

| 风险 | 对策 |
|---|---|
| sys_pll 改频后 PLL 模拟参数（KVCO/ICP/LPF）不匹配 | VCO 仍 1GHz 与原版一致，模拟参数全部沿用；extlock 信号进复位门控，上板看 LED |
| exFAT 细节（entry 校验和、NoFatChain 位、ValidDataLength）解析偏差 | 首版白名单式解析：只认 0x85/0xC0/0xC1 完整集合；UART 打印解析中间值辅助定位 |
| 扇区间 M0 发令延迟导致 packer 断流 | 每扇区 512B@6.25M 传输 655 周期，M0 轮询+发令 <20 周期，余量 30 倍+；packer 字节计数跨扇区连续设计 |
| SPI 6.25MHz 兼容性 | 远低于 SD 高速上限 25MHz，init 后即可切高速分频 |
| 片内 SDRAM 时序 | 控制器/PYH 组合为 lab 上板验证过的原样组合，仅时钟域 25M 侧换源，mem 100M 不变 |

## 8. 实施顺序

1. RTL 骨架：复制参考模块 → sys_pll 改频 → sdram 控制器单独综合验证
2. sd_ctrl + bmp_pack + 顶层互连 → TD 综合过 → 时序 sign-off
3. Keil 固件：exFAT + 播放循环 → hex 回灌验证（防 BRAM 空）
4. PNG→BMP 脚本 + 测试图准备
5. 全流程出 bit → 上板验收
