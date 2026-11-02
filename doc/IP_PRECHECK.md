# IP_PRECHECK.md — 交付物 2：片上 IP 预检报告（P-1）

> 项目：同人角色展示机（安路 EG4S20BG256 / TD 6.2.168116）
> 状态：**TD 实测通过，P0a 放行**
> 日期：2026-10-27
> 工程位置：`project0/test/ip_check/`（目录树见 `project0/doc/spec/PROJECT_TREE.md`）

---

## 1. 目的与范围

P0a/P0b 依赖两块"黑盒风险"最高的片上资源，须在改动任何官方代码之前，先在**本板卡的 TD 命令行全流程**中验证其可综合、可布局布线、时序可过：

| 链路 | 内容 | 风险点 |
|---|---|---|
| HDMI 链 | `tx_pll`（EG_PHY_PLL，107.5/537.5MHz）+ `hdmi_top`（官方 TPG 1280×1024 + hdmi_tx VHD 串化链） | 加密 IP、537.5MHz 高速域、PLL 参数 |
| SDRAM 链 | `sys_pll`（100/125/125MHz@180°）+ `sdram.v` 封装 + `sdr_as_ram/sdr_init_ref/sdr_wrrd` 加密控制器 + 片内硬核 `EG_PHY_SDRAM_2M_32` | 硬核绑定、加密控制器文件完整性、include 路径 |

验证方式：搭建最小顶层 `ip_check_top`（仅时钟 + 上述两链路 + `LED = sdr_init_done`），在 TD 6.2.168116 CLI（run 系统模式）执行 综合→布局→布线→时序分析 全流程。**不下载**（纯离线验证）。

## 2. SDRAM 控制器候选方案对比（三选一）

对仓库内三套 SDRAM 参考实现做了核查，核心加密 IP（`sdr_as_ram/sdr_init_ref/sdr_wrrd.enc.*`）三处**完全同源**，差异在外层封装与时钟配置：

| | 候选 A：`M0_Borad/7_SDRAM_as_BRAM` | 候选 B：`M0_Borad/8_SDRAM_FIFO` | **候选 C：`kangxin_2026/lab_ex4_tf`（选定）** |
|---|---|---|---|
| 控制器时钟 | 150MHz（clk_pll：REFCLK_DIV=4、FBCLK_DIV=1、CLKC0_DIV=84 → VCO=1050，clk1=1050/7=150） | 与 A 同源 | **125MHz**（sys_pll：clk0=100、clk1=125、clk2=125@180°，VCO=1000） |
| 应用接口 | BRAM 式读写（app_wrrd 封装） | FIFO 式（SDRAM_RW_Test） | BRAM 式 + `self_refresh_open`，外层 `frame_read_write` 双缓冲已对接视频链 |
| 时序余量 | 150MHz（6.67ns）对 EG4S20 -NA 器件偏紧 | 中 | **125MHz（8ns）余量充足**（本次实测最差数据路径 6.7ns，见 §5） |
| 与本项目匹配度 | 仅孤立读写例程 | FIFO 接口不合帧缓存模型 | **640×480 帧缓存读写 + HDMI 显示的完整参考路径**，正是 P0b 所需 |
| 额外收益 | — | — | 同一套 `sys_pll` 同时给出 100MHz（供后续 SD/UART 逻辑）与 125MHz 相移时钟（硬核 SDRAM 用） |

**决策（已批准）：采用候选 C**。理由：控制器 IP 同源、带宽够用（640×480@60 RGB888 读带宽 ≈ 17.6MB/s，远低于 125MHz×16bit≈250MB/s 上限）、时序余量最大、且是唯一带完整视频帧缓存集成路径的参考。

## 3. 预检工程构成

```
ip_check_top (rtl/ip_check_top.v)
├── u_txpll  tx_pll        # 50M → clk0=25M(未用) clk1=107.5M(PXLCLK) clk2=537.5M(PCLK_X5)
├── u_hdmi   hdmi_top      # 官方 TPG 1280×1024 加密时序 + hdmi_tx.vhd → DVITransmitter →
│                          #   TMDSEncoder ×3 + SerializerN_1_lvds(_dat) + ODDR
├── u_spll   sys_pll       # 50M → clk0=100M(未用) clk1=125M(控制器) clk2=125M@180°(SDRAM_CLK)
└── u_sdr    sdram.v       # sdr_as_ram(self_refresh_open=1) → sdr_init_ref + sdr_wrrd
                           #   + EG_PHY_SDRAM_2M_32 硬核（片内 2M×32，无外部引脚）
LED ← sdr_init_done        # 硬核初始化完成的可观测信号（上板验证位）
```

约束：`constraints/ip_check.adc`（clk=R7、rst_n=A9 + HDMI/VGA/LED 引脚，出处见 `PIN_PROVENANCE.md`）；`constraints/ip_check.sdc`（`create_clock -period 20.000` 50MHz 输入）。

## 4. TD 实测记录

### 4.1 环境与命令

- TD 6.2.168116（`D:\FPGA`，license 已装），CLI：`td_commands_prompt.exe run_ip_check.tcl`
- 脚本采用 SWUG105 官方 run 系统模式：`import_device → create_project → add_files → create_run(syn_1/phy_1) → launch_runs → wait_run → open_run`
- 器件：`EG4S20BG256`，速度等级 NA

### 4.2 排障记录（对后续 P0a 自动化有复用价值）

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | `HDL-8007: cannot open include file '../user_source/hdl_source/include/global_def.v'`，模块被丢弃 | 加密文件 `sdr_init_ref.enc.v(11)` 按相对路径 include，要求工程内复现原始目录层级 | 在 `rtl/user_source/hdl_source/include/` 补放 `global_def.v` |
| 2 | `HDL-7144 CRITICAL-WARNING: instantiate unknown module`（sdr_as_ram.enc.v(40)）→ `HDL-8007: encrypted module is a black box` | **缺第三份加密文件 `sdr_wrrd.enc.v`**（SDRAM 读写数据通路；三份 enc 文件必须成套） | 从 lab_ex4 补拷至 `rtl/enc/` 并加入 `add_files` |
| 3 | `PRJ-8805: Runs syn_1 need to be reset first` | `ip_check_Runs/` 残留失败 run 状态 | 重跑前删除 `ip_check.al` 与 `ip_check_Runs/`；脚本内加 `catch { reset_run ... }` 兜底 |
| 4 | `PRJ-8646: already exists` | create_project 不覆盖已有 .al | 同上，先删后建 |

> 经验：**凡引用 lab_ex4 的 SDRAM 控制器，三个加密文件必须同套引入，且 include 目录结构 `user_source/hdl_source/include/` 必须复现。** 已固化进 `run_ip_check.tcl`。

### 4.3 实测结果

**全流程通过**：syn_1 综合 ✓ → phy_1 place(1s)+route(4s) ✓ → `IP_CHECK_FLOW_DONE`。

**资源（route 后，`ip_check_final.area`）**：

| 资源 | 用量 | 占比 |
|---|---|---|
| LUT | 166 / 19600 | 0.85% |
| REG | 194 / 19600 | 0.99% |
| BRAM / DSP | 0 / 0 | — |
| PLL | 2 / 4 | 50% |
| IO | 25 / 188 | 13.3% |

分级面积：`sdr_init_ref` 90 LUT、`sdr_wrrd` 31 LUT（SDR 控制器合计约 121 LUT），HDMI 链其余为 TPG 与编码器。EG4S20 资源余量巨大。

**时钟树（phy 后自动时钟报告）**：

| 时钟 | 来源 | 频率 | 扇出 | 用途 |
|---|---|---|---|---|
| u_spll clkc1 | sys_pll | 125MHz | 114 | SDR 控制器主时钟 ✓ |
| u_spll clkc2 | sys_pll | 125MHz@180° | →硬核 | SDRAM_CLK ✓ |
| u_txpll clkc1 | tx_pll | 107.5MHz | 29 | PXLCLK（TPG/DE 域）✓ |
| u_txpll clkc2 | tx_pll | 537.5MHz | 32 | PCLK_X5（串化器）✓ |

**时序（route 后，Slow+Fast 双 corner）**：

| 指标 | 数值 | 判定 |
|---|---|---|
| Setup WNS / TNS | **+9.435ns / 0ps** | ✓ 0 违例端点（237 端点 / 483 路径） |
| Hold WNS / TNS | **+1ps / 0ps** | ✓ 0 违例（偏紧，属 PLL 透明分析的悲观项，见 §6） |

**两条 CRITICAL-WARNING 及判定（均不阻塞）**：

| 告警 | 判定 |
|---|---|
| `PHY-7002`：u_sdr/sdram 初始位置 (12,12) 不合法，布局期自动迁移 | 硬核 SDRAM 无用户位置约束时由 TD 自行摆放，参考工程同款行为，**接受** |
| `PHY-5079`：1 条时钟网走局部布线（`u_sdr/u2_ram/SDRAM_CLK`，AL_PHY_PLL 驱动，**扇出仅 1**=硬核 clk 引脚） | 相移时钟直驱硬核正是设计意图（lab_ex4 同款），**接受** |

## 5. 结论

1. **HDMI 官方加密链（tx_pll + TPG + hdmi_tx 串化）与片内 SDRAM 硬核链在本板 TD 6.2 CLI 全流程可编译、可布线、时序通过** → P0a"官方彩条 1280×1024 原样编译"无阻断项，放行。
2. SDRAM 控制器选定候选 C（lab_ex4，125MHz），实测 121 LUT 级开销、时序余量大。
3. `sdr_init_done` 已引至 LED，上板第一步即可观测硬核初始化是否完成。
4. 工具链自动化脚本（`run_ip_check.tcl` + `tools/gen_run_tcl.py`）已可复用于 P0a 正式工程。

## 6. 风险与遗留

| 风险 | 说明 | 处置 |
|---|---|---|
| **TD STA 将 EG_PHY_PLL 视为时钟透明**（本次重要发现） | 时序报告仅按输入 50MHz（20ns）周期分析所有 PLL 输出域；107.5/125/537.5MHz 域的真实周期未被用于 sign-off（报告 Clock Summary 仅含 clk0） | P0a 可接受（与全部参考工程一致，实测最差数据路径 6.7ns，对 125MHz 域仍有 1.3ns 余量）；**P0b 若需严格 sign-off，在 SDC 中为 PLL 各输出补 `create_generated_clock`** |
| Hold WNS +1ps | PLL 透明分析下的悲观裕量 | 同上，随 generated clock 一并复核 |
| 精确 25.175MHz 像素时钟无整数分频解 | 25.175×40=1007=19×53，VCO 无法落在合法范围 | 已决策采用 lab_ex4 同款 25.000/125.000MHz（见 `P0_PLAN.md` §P0b） |
| UART 引脚 T7/T8 未上板验证 | 原理图 p3 布局分析，置信度 ~70% | 见 `P1_UART.md` §6，5 分钟上板判定法，P1 前确认 |

## 7. 产物清单

| 文件 | 说明 |
|---|---|
| `project0/test/ip_check/run_ip_check.tcl` | 全流程脚本（run 系统模式） |
| `project0/test/ip_check/ip_check_timing.rpt` | route 后时序报告（253KB 完整路径） |
| `project0/test/ip_check/ip_check_rtl.area` / `ip_check_final.area` | RTL 级 / route 后面积报告 |
| `project0/test/ip_check/ip_check_Runs/syn_1/run.log` | 综合日志（含 elaborate 全部 PLL 参数，可复核频率推导） |
| `project0/test/ip_check/ip_check_Runs/phy_1/route.qor` 等 | 布局布线 QoR 与状态文件 |
