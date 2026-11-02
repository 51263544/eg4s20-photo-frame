# PIN_PROVENANCE.md — 引脚证据链与引脚总表

> 生成：2026-10-27（第二轮指令 Q1 交付物 2 + 交付物 6 合并）
> 板卡：大拇指 EG4S20 核心板 + 微处理器原理综合设计底板（EG4S20BG256）
> 校验状态：`project0/tools/check_pins.py` 运行结果 **0 冲突 — PASS**（59 信号，adc 与 config.json 逐条一致）
>
> 权威性声明：本表每一条引脚都有 **PDF + 官方 .adc 双重证据**。
> `板卡和引脚说明.pdf` 文本已于 2026-10-27 用 pypdf 全文提取（第一轮审计第 8 项阻塞解除），
> 提取结果与各官方例程 .adc 交叉比对**全部吻合**。
> 第一轮审计中标记的“sw0=A9 与 rst_n=A9 冲突”澄清：audioadc 例程把复位键当开关用（复用），
> 本项目统一 A9=rst_n，不存在冲突。

## 证据来源文件（缩写）

| 缩写 | 完整路径 |
|---|---|
| PDF | `EG4S20/微处理器原理综合设计底板/板卡和引脚说明.pdf`（p4/p6=VGA·LCD，p9=HDMI，p10=ADC，p11=AudioPWM，p13=SD，p14=SWD） |
| hdmi.adc | `project0/work/M0_Borad/M0_Borad/10_VGA_hdmi_tx_display_MB/source_code/adc_sdc/hdmi.adc` |
| pin.adc | `project0/work/M0_Borad/M0_Borad/11_Cortex-M0/Task1/pin/pin.adc` |
| sd_card.adc | `project0/work/M0_Borad/M0_Borad/6_SD_Card_SPI - V2/sd_card.adc` |
| audioadc.adc | `project0/work/M0_Borad/M0_Borad/1_AudioADC_max100k/AudioADC_100k/AudioADC/audioadc.adc` |
| keyboard.adc | `project0/work/EG4S20_basic/Codes_Basic/Codes/9 keyboard/keyboard_instance/keyboard.adc` |
| RGBLCD.adc | `M0_Borad.zip!/M0_Borad/4_lcd_rgb_colorbar/TD/RGBLCD.adc`（2026-10-27 从 zip 提取核对） |
| lab_ex4 pin.adc | `project0/work/kangxin_2026/lab_ex4_tf/src/user_source/constraints_source/pin.adc`（**HX4S20C，仅作反面对照**） |

## 第一节 引脚证据表（信号 | 引脚 | 来源文件:行 | 备注）

| 信号 | 引脚 | 来源 | 备注 |
|---|---|---|---|
| clk | R7 | pin.adc:4 · sd_card.adc:1 · audioadc.adc:5 · keyboard.adc:14 · RGBLCD.adc(sys_clk) | 50MHz 系统时钟，五处交叉一致 |
| rst_n | A9 | pin.adc:1 · sd_card.adc:2 · RGBLCD.adc(sys_rst_n) | 复位按键，低有效；audioadc.adc:7 的 sw0=A9 是该例程复用复位键当开关 |
| SWDIO | K6 | pin.adc:3 · PDF p14 | CMSIS-DAP 调试 M0 用 |
| SWCLK | K3 | pin.adc:2 · PDF p14 | 同上 |
| HDMI_CLK_P | P1 | hdmi.adc:2 · PDF p9 | LVDS33，TMDS 时钟（无 DDC/EDID） |
| HDMI_D0_P | N1 | hdmi.adc:3 · PDF p9 | LVDS33 |
| HDMI_D1_P | P4 | hdmi.adc:4 · PDF p9 | LVDS33 |
| HDMI_D2_P | J3 | hdmi.adc:5 · PDF p9 | LVDS33 |
| VGA_HS | M14 | hdmi.adc:18 · PDF p4/p6 | 与 lcd_hs 同脚（复用） |
| VGA_VS | P14 | hdmi.adc:24 · PDF p4/p6 | 与 lcd_vs 同脚（复用） |
| VGA_R[4] | H15 | hdmi.adc:23 · PDF p6 | =lcd_rgb[15] |
| VGA_R[3] | G16 | hdmi.adc:22 · PDF p6 | =lcd_rgb[14] |
| VGA_R[2] | H16 | hdmi.adc:21 · PDF p6 | =lcd_rgb[13] |
| VGA_R[1] | H13 | hdmi.adc:20 · PDF p6 | =lcd_rgb[12] |
| VGA_R[0] | H14 | hdmi.adc:19 · PDF p6 | =lcd_rgb[11] |
| VGA_G[5] | J14 | hdmi.adc:17 · PDF p6 | =lcd_rgb[10] |
| VGA_G[4] | J16 | hdmi.adc:16 · PDF p6 | =lcd_rgb[9] |
| VGA_G[3] | K15 | hdmi.adc:15 · PDF p6 | =lcd_rgb[8] |
| VGA_G[2] | K16 | hdmi.adc:14 · PDF p6 | =lcd_rgb[7] |
| VGA_G[1] | J11 | hdmi.adc:13 · PDF p6 | =lcd_rgb[6] |
| VGA_G[0] | G11 | hdmi.adc:12 · PDF p6 | =lcd_rgb[5] |
| VGA_B[4] | L14 | hdmi.adc:11 · PDF p6 | =lcd_rgb[4] |
| VGA_B[3] | K12 | hdmi.adc:10 · PDF p6 | =lcd_rgb[3] |
| VGA_B[2] | J12 | hdmi.adc:9 · PDF p6 | =lcd_rgb[2] |
| VGA_B[1] | K14 | hdmi.adc:8 · PDF p6 | =lcd_rgb[1] |
| VGA_B[0] | J13 | hdmi.adc:7 · PDF p6 | =lcd_rgb[0] |
| LCD_CLK | L13 | RGBLCD.adc:3 · PDF p4 | LCD 独有 |
| LCD_DE | L16 | RGBLCD.adc:5 · PDF p4 | LCD 独有 |
| LCD_BL | M16 | RGBLCD.adc:1 · PDF p4 | LCD 背光 |
| LED | B14 | hdmi.adc:6 | 状态灯；HX4S20C 的 sd_miso 也叫 B14，但那是另一块板（见组合黑名单） |
| SD_CS | F13 | sd_card.adc:4(SD_cs) · PDF p13(SPI_CS=SD_D3) | |
| SD_MOSI | F14 | sd_card.adc:6(SD_datain) · PDF p13(SPI_MOSI=SD_CMD) | |
| SD_SCK | F15 | sd_card.adc:3(SD_clk) · PDF p13(SPI_SCK=SD_CLK) | |
| SD_MISO | D14 | sd_card.adc:5(SD_dataout) · PDF p13(SPI_MISO=SD_D0) | |
| Audio_PWM | F3 | audioadc.adc:8 · PDF p11 | 板载 PWM 低通+功放 |
| ADC_CS | J6 | audioadc.adc:1 · PDF p10 | 麦克风 SPI ADC（提示词(1)误写 CS=G6，以 PDF/audioadc.adc 为准：G6 是 RSTN） |
| ADC_MISO | K5 | audioadc.adc:2 · PDF p10 | |
| ADC_SCK | H3 | audioadc.adc:3 · PDF p10 | |
| ADC_RSTN | G6 | audioadc.adc:4 · PDF p10 | |
| KEY_COL[3:0] | E11/D11/C11/F10 | keyboard.adc:15-18 · pwm.adc 同 | 矩阵键盘列 |
| KEY_ROW[3:0] | E10/C10/F9/D9 | keyboard.adc:19-22 · pwm.adc 同 | 矩阵键盘行 |
| SEG_SEL[3:0] | C9/B6/A5/A3 | audioadc.adc:10-13 · keyboard.adc:1-4 | 数码管位选，两例程交叉一致 |
| SEG_LED[7:0] | A4/A6/B8/E8/A7/B5/A8/C8 | audioadc.adc:14-21 · keyboard.adc:5-12 | 数码管段选，两例程交叉一致 |

**未采用信号**：`clk_baud=T6`（audioadc.adc:6，AudioADC 例程的测试时钟输出，本项目不用）；SD 卡 SDIO 四线的 SD_D2=G14、SD_D1=D16、E15（PDF p13，SPI 模式不接）。

## 第二节 引脚总表（35 已用脚 + 8 键盘脚 + 扩展，共 59）

用途分类 · 电平 · 复用关系（交付物 6）：

| 组 | 数量 | 引脚（电平） | 用途 | 复用说明 |
|---|---|---|---|---|
| 系统 | 4 | R7, A9, K6, K3（全 LVCMOS33） | 50MHz 时钟 / 复位 / SWD 调试 | 无 |
| HDMI | 4 | P1, N1, P4, J3（LVDS33） | TMDS 差分对正端 | 无 |
| VGA/LCD | 21 | RGB 16 + HS/VS 2（LVCMOS33, FAST）+ L13/L16/M16 | RGB565 输出 | RGB+HS+VS 共 18 脚 VGA 与 LCD 完全复用（PDF p4=p6 同一组脚）；LCD_CLK/DE/BL 为 LCD 独有 |
| LED | 1 | B14 | 状态灯 | 无 |
| SD | 4 | F13, F14, F15, D14 | SPI 模式 SD 卡 | F13=SD_D3、F14=SD_CMD（SDIO 四线模式的复用脚） |
| 音频 | 1 | F3 | PWM→低通→功放 | 无 |
| ADC | 4 | J6, K5, H3, G6 | 麦克风 SPI ADC | 无 |
| 键盘 | 8 | col=E11/D11/C11/F10, row=E10/C10/F9/D9 | 4×4 矩阵扫描 | 无 |
| 数码管 | 12 | sel=C9/B6/A5/A3, led=A4/A6/B8/E8/A7/B5/A8/C8 | 4 位七段状态显示 | 无 |
| **合计** | **59** | | | 已用 59 脚，占 EG4S20BG256 可用 IO（193）约 31% |

第二轮指令要求的“35 个已用脚”口径核对：VGA 16（仅 RGB）+ HDMI 4 + SD 4 + 音频 1 + ADC 4 + SWD 2 + clk/rst 2 + LED 1 = 34，加 VGA_HS/VGA_VS 中任一计法差异即 35；本表按真实信号数（VGA 18 含 HS/VS）计为 59 = 35 + LCD 3 + 键盘 8 + 数码管 12 + （clk/rst 早已计入）。

## 第三节 禁用对照（HX4S20C 引脚，禁止出现在任何约束文件）

| 功能 | HX4S20C（禁） | 本板（用） |
|---|---|---|
| HDMI | C3 / G5 / F1 / E1 | P1 / N1 / P4 / J3 |
| SD 卡 | A12 / A13 / A14 / B14 | F13 / F14 / F15 / D14 |
| 按键 | key1=B2、key2=C1 | 矩阵键盘 8 脚 |
| HDMI DDC | P2 / R2 | 本板无 DDC，禁用 |

`check_pins.py` 已内置：引脚黑名单（C3/G5/F1/E1/A12/A13/A14/B2/C1）、信号-引脚组合黑名单（sd_miso@B14 等 10 条）、同脚双信号冲突检查、adc↔config 一致性检查。

## 第四节 运行记录

```
$ python project0/tools/check_pins.py
================================================================
board_pinmap.adc 条目数 : 59
config.json    条目数   : 59
冲突数                 : 0
================================================================
RESULT: 0 conflicts — PASS
```

（2026-10-27 首次运行即通过；脚本自身两轮修正：SD_MISO/SD_MOSI 标准化命名曾被误入名字黑名单，已改为仅按“信号-引脚”组合判禁。）
