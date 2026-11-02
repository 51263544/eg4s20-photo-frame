# P1_UART.md — M0 最小系统 + AHB UART 外设 + 固件工程

> 2026-10-27 · 第二轮指令 Q3 交付物 4（P1 = 修订阶段表的第 4 行）
> 前提事实（均已核实）：官方 SoC 无 UART、Keil 固件是空循环、`code.sct` 的 RW_IRAM1 指向 0x2000_0000 无人区。

## 1. 现状与问题（文件:行）

| # | 事实 | 位置 | 对 P1 的影响 |
|---|---|---|---|
| 1 | SoC 只有 M0 核 + 1 片 16KB BRAM，无任何外设，`IRQ=32'b0` | `work/M0_Borad/M0_Borad/11_Cortex-M0/Task1/rtl/CortexM0_SoC.v:25` | 需挂 ahb_uart + 接 IRQ[0] |
| 2 | AHB 互连只有 4 个从口 P0~P3，P1/P2/P3 的 HSEL 硬接 0 | `AHBlite_Decoder.v:46/53/59`（`AHBlite_SlaveMUX.v:50` 4 选 1） | 需扩到 5 路（P1 给 UART），重写 Decoder 地址译码 |
| 3 | P0 窗口 64KB（代码+数据 BRAM） | `AHBlite_Decoder.v:38` | UART 放 0x4000_0700 窗口（新增 P1 口） |
| 4 | `Block_RAM.v:15` 的 `$readmemh` 硬编码 `E:/M0/Experiments/Task1/keil/code.hex` | `Block_RAM.v:15` | 复制进 project0 后改为相对路径，文件名 p1 固件 `m0_code.hex` |
| 5 | Keil 工程只有 `startup_CMSDK_CM0.s` + 预编译空循环（`code.txt` 4 条指令） | `Task1/keil/` | 新建 C 固件工程 |
| 6 | `code.sct:12`：`RW_IRAM1 0x20000000 0x00010000` | `Task1/keil/code.sct` | **HardFault 隐患**：0x2000_0000 当前无任何存储。P1 修正见 §5 |

## 2. ahb_uart 端口表（project0/rtl/ahb_uart.v，纯 Verilog，~180 行）

| 端口 | 位宽 | 方向 | 说明 |
|---|---|---|---|
| HCLK | 1 | in | AHB 时钟 = 系统时钟 50MHz |
| HRESETn | 1 | in | 复位，低有效 |
| HSEL | 1 | in | 从口选择（来自 Decoder P1） |
| HADDR | 32 | in | 字节地址（寄存器用 [7:2]） |
| HTRANS | 2 | in | 只响应 NONSEQ/SEQ |
| HSIZE | 3 | in | 仅 32bit（word） |
| HWRITE | 1 | in | 写标志 |
| HWDATA | 32 | in | 写数据 |
| HREADY | 1 | in | 主机就绪（流水尾） |
| HREADYOUT | 1 | out | 恒 1（单拍响应，0 等待态） |
| HRESP | 1 | out | 恒 OKAY |
| HRDATA | 32 | out | 读数据 |
| IRQ | 1 | out | RX 非空中断 → Cortex-M0 IRQ[0] |
| uart_txd | 1 | out | FPGA→CH340 RXD |
| uart_rxd | 1 | in | CH340 TXD→FPGA |

设计要点：标准 8N1；发送 16 深度、接收 8 深度硬件 FIFO（BRAM 实现，避免丢字节）；
波特率 = HCLK / DIV，寄存器可配（默认 50e6/434 ≈ 115200）；两级同步器采样 rxd（跨域规则 §6.3）。

## 3. 寄存器表（基址 0x4000_0700，对应方案文档地址映射）

| 偏移 | 名称 | 读 | 写 |
|---|---|---|---|
| 0x00 | DATA | RX FIFO 弹出一个字节 | 写 TX FIFO |
| 0x04 | STATUS | [0]RX_AVAIL [1]TX_FULL [2]TX_EMPTY [4]RX_OVERRUN | 写 1 清 RX_OVERRUN |
| 0x08 | BAUD | 读当前分频 | 写分频值（默认 434 = 115200bps） |
| 0x0C | CTRL | 读 [0]RX_IRQ_EN [1]TX_IRQ_EN | 使能/禁用中断 |
| 0x10 | FIFO_CLR | — | 写任意值清空两个 FIFO |

## 4. SoC 侧改动（全部在 project0/rtl/soc/ 下，改副本不改原件）

| 文件 | 改动 |
|---|---|
| `AHBlite_Decoder.v` | P0 窗口保持 0x0000_xxxx；新增 P1 → 0x4000_0xxx；HSEL_P1 = (HADDR[31:16]==16'h4000)（P2+ 后续再扩） |
| `AHBlite_SlaveMUX.v` | 4 路 → 5 路（P0 代码 RAM + P1 UART），返回 mux 逻辑同构扩展 |
| `AHBlite_Interconnect.v` | 默认从口路由加 P1 一组 13 根信号 |
| `CortexM0_SoC.v` | 端口加 `uart_rxd/uart_txd`；例化 ahb_uart；`IRQ[0] = uart_irq`（`:25` 的 IRQ=0 改为 IRQ = {31'b0, uart_irq}） |
| `Block_RAM.v` | `$readmemh` 路径改 `m0_code.hex`（与 .al 同目录） |

## 5. 固件工程（project0/m0/，Keil MDK + CMSIS 包 V2M-MPS2_CMx_BSP）

文件清单：

| 文件 | 说明 |
|---|---|
| `startup_CMSDK_CM0.s` | 复用官方启动文件（中断向量表，含 IRQ0=UART_Handler 占位） |
| `main.c` | 500ms 计数打印 + 串口回显（轮询 STATUS，不依赖中断即可过验收） |
| `ahb_uart.h` | 寄存器定义（`#define UART_BASE 0x40000700`）+ `uart_putc/uart_puts/uart_init` |
| `retarget_io.c`（可选） | `fputc` 重定向，支持 printf |
| `m0_uart.uvprojx` | 器件 CMSDK_CM0，Flash 算法无需（下载用 SWD 调试器 + .hex 转 Block_RAM 的 $readmemh） |

**code.sct 修正方案（必须改，否则全局变量 HardFault）**：

```
; 修正后 —— 方案 A（P1 默认）：代码与数据共享片内 16KB BRAM
LR_IROM1 0x00000000 0x00004000  {
  ER_IROM1 0x00000000 0x00003000  {      ; RO: 12KB 代码+常量
   *.o (RESET, +First)
   *(InRoot$$Sections)
   .ANY (+RO)
   .ANY (+XO)
  }
  RW_IRAM1 0x00003000 0x00001000  {      ; RW+ZI: 4KB 数据（原 0x20000000 无人区，必 HardFault）
   .ANY (+RW +ZI)
  }
}
```

方案 B（P2 起，同时启用 Decoder Port1 挂第二片 16KB BRAM @0x2000_0000）：
`RW_IRAM1 0x20000000 0x00004000`；仅当 BRAM 已例化并接上总线才允许，否则维持方案 A。

固件 → RTL 回灌流程：Keil 编译出 `code.hex`（bin 化十六进制文本）→ 重命名/复制为
`project0/prj/p1_m0_uart/m0_code.hex` → TD 重新综合（Block_RAM 初始化）→ 下载。

## 6. UART 引脚（已确认 — 2026-10-27 用户裁定）

> **结论：采用 T7 = FPGA 收（接 CH340 TXD）/ T8 = FPGA 发（接 CH340 RXD）。**
> 用户确认"UART 引脚就按原理图上来"，即以核心板 2023 原理图 p3 布局分析为准，
> `UNVERIFIED` 标记解除（证据级别：原理图文本层提取 + 用户裁定，非上板实测）。

| 候选 | 证据 | 状态 |
|---|---|---|
| **T7 = FPGA 收（接 CH340 TXD）/ T8 = FPGA 发（接 CH340 RXD）** | 核心板 2023 原理图 p3（"FPGA Jtag & Uart"页）布局分析：CH340N（UART2USB 座）TXD/RXD 经 0R75/0R80 接 NLUSART0RX/TX（GD32 PA10/PA9），再经 0R70/0R71 桥到 FPGA symbol 的 T7/T8 球；文本层提取，连接方向按网名+电阻位置推断 | **采用（用户裁定）** |
| F12/D12（入门 PDF 表 1.7） | 那是 DMZ_EG4S20 极简板；F12/D12 不在 2023 核心板 BANK1 球表内（已核对 p2 布局提取） | 已否决 |

**P1 上板首验保留**（不阻塞 P1 开工，仅作冒烟验证）：下载后串口助手 115200-8N1 接
"UART2USB"座，应收到周期性 `tick=N`；若无输出再按原判定法反向核对 T7/T8，
异常时更新 `board_pinmap.adc` 与 PIN_PROVENANCE.md 并重跑 check_pins。

## 7. P1 验收与失败判据

- 成功：串口每 500ms 打印一行计数（`tick=123`），Keil 可单步、可看变量；
  改 BAUD 寄存器换 9600bps 也正确。
- 失败：无输出（查引脚/查 hex 回灌）/ HardFault（查 .sct，查向量表偏移）。

## 8. 执行记录（2026-10-27 实施完毕，待上板验收）

**产物**：`project0/prj/p1_m0_uart/p1_m0_uart.bit`（648KB，2026-10-27 22:28）

### 8.1 与方案 §4 的偏差（详见 DESIGN_DECISIONS.md）

| # | 偏差 | 原因 |
|---|---|---|
| 1 | D-005：不扩第 5 从口，复用互连现有 P1 口（MUX/Interconnect 零改动，只改 Decoder） | 参考工程本就带 4 从口，P1 通路现成；方案 §4"5 路"系笔误级偏差 |
| 2 | D-006：SoC 时钟 50MHz→**25MHz**（新增 `soc_pll.v`，VCO=1000/CLKC0_DIV=40，与 P0b C0 配置一致） | M0 混淆核 EG4S20 实测 Fmax=40.2~41.6MHz，50MHz 无法收敛（694 违规端点）；40MHz 因 TD USR-8157（create_generated_clock 选项互斥）无法表达且裕度仅 0.2% |
| 3 | UART 分频 434→**217**（RTL 复位值 + 固件同步改） | 25e6/217=115207bps（+0.006%），方案 §3 默认值随 D-006 连锁修正 |
| 4 | `Block_RAM.v` readmemh 用 `../m0_code.hex` 而非裸文件名 | 裸文件名触发 HDL-5105（BRAM 未初始化，CPU 跑飞）；TD 搜索规则 (i) 相对源文件目录 |

### 8.2 sign-off 数据（TD 6.2 慢角，2445 端点，585 万路径）

| 项 | 结果 |
|---|---|
| Clock Summary | sys_clk **25.000**MHz（1151 fanout）/ clk 50.000MHz（PLL 输入）— D-004 口径全中 |
| 建立 | **SWNS +3.769ns，STNS 0.000，0 违规端点**（最差路径仍在 M0 核乘法器输入） |
| 保持 | **HWNS +0.030ns，HTNS 0.000** |
| 资源 | 5347 LUT（27%，M0 核 5016 + ahb_uart 297）、1458 reg、16 BRAM（代码 RAM）、3 DSP |
| BRAM 初始化 | `../m0_code.hex` 命中（HDL-5105 消除）；固件 Code=1064/RO=88/RW=0/ZI=96，栈顶 0x0000_4000 |

### 8.3 固件（project0/m0/，Keil MDK 命令行构建）

- `m0_uart.uvprojx`（复制官方改 4 处：OutputName、显式 `code.sct`（方案 A）、
  AfterMake `fromelf --vhx --32x1 -o m0_code.hex`、加 main.c）
- hex → `prj/p1_m0_uart/m0_code.hex`（288 行 = 1152B，前 288 字初始化 BRAM，
  ZI 区运行时由 `__main` 清零）
- 流程：改 main.c → `UV4 -b m0_uart.uvprojx -o build_log.txt` → 复制 hex → TD 重综合

### 8.4 上板验收步骤（P1 首验）

1. TD 下载器加载 `p1_m0_uart.bit`，S26 拨码复位（或按 RSTn）
2. USB 线接核心板 **UART2USB 座**，串口助手 **115200-8-N-1**
3. 预期：上电即见 `P1 M0 SoC online`，随后每 500ms 一行 `tick=N`（N 递增）
4. 键盘敲字符 → 回显
5. 若无输出：按 §6 反向核对 T7/T8；若乱码：核对波特率（115200）；
   若 HardFault（Keil 单步查）：查 .sct / 向量表（`m0_code.hex` 首字必须为 0x00004000）
6. 改 9600 验证（可选）：Keil 改 `uart_init(UART_BAUD_9600)` 重编回灌，串口改 9600
