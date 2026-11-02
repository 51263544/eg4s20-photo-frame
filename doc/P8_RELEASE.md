# P8 发布与固化（Release / Configuration Flash）

本文件记录**已冻结的可交付版本**、**配置 Flash 固化流程**和**上板验收结论**。
P0–P7 的功能实现见 `PROJECT_TREE.md`、`P2_BRINGUP.md` 与设计文档。

---

## 1. 已冻结版本（2026-11-02，**v53**）

| 产物 | 路径 | 大小 | MD5 |
|---|---|---|---|
| 比特流 | `project0/prj/p2_sd_display/p2_sd_display.bit` | 648258 B | `1F4BFAC58E9612AFD868D0C73FFD55E2` |
| 固件镜像 | `project0/m0_p2/m0_code.hex` | 19540 B | `FAD1C79C10CD1F09AC063E44E8578D27` |
| 固件镜像（综合用副本） | `project0/prj/p2_sd_display/m0_code.hex` | 19540 B | 同上（必须与上一行一致） |

- 固件镜像由 `Block_RAM.v` 的 `$readmemh("../../../m0_code.hex", mem)` 在**综合时**读入，
  因此比特流本身已包含固件；固化只需烧比特流。
- 版本代号 **v53**，开机签名 `0x3D`（条带模式时第 1/3/4/5/6 条为白；正常启动后条带被画面取代）。
- v53 新增：按键显示保持不再阻塞音频（KEY1 不再打断音乐）、KEY7 零延迟切换、SD 热插拔
  （看门狗 + 卡 FSM 重新初始化 + 固件重挂载）。
- 资源与时序（v53 综合结果）：LUT 8 211；时钟汇总（`p2_timing.rpt`）——
  `sys_clk` 25 MHz setup **+0.524** / hold **+0.046**、`clk`(50 MHz 音频) **+5.477** / +0.102、
  `pxl_clk` 25 MHz **+16.301** / +0.214、`pxl_5x` 与 50 MHz 复位域均为正；
  唯一负值是 `mem_clk` 的 **−2.692 ns**，即片内 SDRAM 硬核（`EG_PHY_SDRAM_2M_32`）接口的固有路径
  （100 % cell 固有延迟、0 网线、0 逻辑级），同构设计历来上板验证通过，见 `P2_BRINGUP.md` §4。
- 历史冻结版：v51 `2D0AD224…`（2026-11-01，首个固化成功版）、v52 `5869F884…`（P7 角色包）。
  每版 bit 都在同目录留了 `p2_sd_display_v*.bit` 备份，回退时直接烧对应文件。

## 2. 配置 Flash 固化流程（已验证）

TD 的烧写模式表来自 `D:\FPGA\doc\config\config.json`：

| 模式 | TD 内部命令 | 用途 |
|---|---|---|
| `PROGRAM_SRAM` | `jtag` | 下载到 SRAM，掉电即失（调试用） |
| `PROGRAM_FLASH` | `program_spi -v` | **写入配置 Flash，掉电保留（发布用）** |
| `VERIFY_FLASH` | `verify_spi` | 校验 Flash 内容 |
| `ERASE_FLASH` | `erase_spi` | 擦除配置 Flash |

**操作步骤**（2026-11-01 实测一次成功）：

1. USB 下载线保持连接；
2. TD 打开 `project0/prj/p2_sd_display` 工程，打开下载 / Programmer 对话框；
3. 设备扫描确认 `EG4S20BG256`；
4. **Mode 选 `PROGRAM_FLASH`**（关键的这一步，平时调试用的是 `PROGRAM_SRAM`）；
5. Speed 5 MHz，MemorySize 用默认，比特流选 `p2_sd_display.bit`；
6. Program → 等待写+校验完成（1~3 分钟，期间不要断电）；
7. **拔掉 USB 线**，断电再上电。

**板上配置器件**：核心板有独立 SPI 配置 Flash（原理图网络 `FPGA_CCLK` / `SPI_CSN` / `FPGA_MOSI` / `FPGA_D0`），
由 `MSEL0/MSEL1` 决定启动方式；TD 自带 128 款 SPI NOR 识别表（`flash.json`）。

## 3. 验收结论

| 项目 | 结果 |
|---|---|
| 固化后**拔掉下载线、断电重上电自启动** | ✅ 2026-11-01 一次成功，完全正常（v51 验证；v53 同一流程） |
| 断电恢复（掉电再上电仍运行） | ✅ 同上 |
| 连续运行 2 小时 | ✅ 2026-11-02 13:57–15:57（v53 固化版），见 §3.1 |
| 演示脚本 / README | 🔶 脚本已写：`doc/hw/DEMO_SCRIPT.md`；视频待拍 |

### 3.1 2 小时烤机记录（2026-11-02，v53）

- 条件：v53 固化版 + 第二张（碧蓝航线）卡 + 3.5 mm 外放音箱，连续运行 120 分钟，中途多次按键操作。
- 结果：画面持续轮播无花屏/卡死、按键全部响应、数码管显示正常、复位后自启动正常。
- **唯一异常：音响出现过一阵杂音，重插 3.5 mm 插头后恢复**。判定为**机械接触问题**，
  不是固件/逻辑问题（同一块板此前麦克风也出现过完全同类的现象——插头没插到底，
  见 `P5_P6_P7_ACCEPT.md` 麦克风小节）。软件侧无异常计数器、无闪码、无卡死。
- 演示建议：3.5 mm 插头务必**插到底**；若条件允许，改用板上 `扬声器` XH2.54-2P 座
  （与 3.5 mm 同一路功放输出，接触更可靠）。

## 4. 待办

- **演示视频**：按 `DEMO_SCRIPT.md` 拍摄。
- **报告素材**：资源占用、时序报告、架构图、踩坑清单（见 `方案/skills/fpga-eg4s20-bringup/SKILL.md`
  与 `doc/hw/PROJECT_STATUS.md` §4）。
- **恢复手段**：若将来固化版本出问题，只要 JTAG 能连上，改用 `PROGRAM_SRAM` 重新下载即可救回，
  或再次 `PROGRAM_FLASH` 覆盖；也可回退烧 `p2_sd_display_v*.bit` 里任一历史版本。
