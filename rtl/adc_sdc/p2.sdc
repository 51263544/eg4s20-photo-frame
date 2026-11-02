// P2 SDC: 2 PLLs -> 5 clocks. sys 25M (SoC/SD), mem 125M pair, pixel 25M + 125M 5x.
// TD rule: -multiply_by/-divide_by >= 1 (USR-8105); 125M = 50M x 2.5 (P0b proven form).
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

// sys_pll outputs
create_generated_clock -name sys_clk     -source [get_ports {clk}] -master_clock clk -divide_by 2    [get_nets {sys_clk}]     ;# 25MHz SoC/SD domain
create_generated_clock -name mem_clk     -source [get_ports {clk}] -master_clock clk -multiply_by 2.5 [get_nets {mem_clk}]     ;# 125MHz SDRAM ctrl
create_generated_clock -name mem_clk_sft -source [get_ports {clk}] -master_clock clk -multiply_by 2.5 [get_nets {mem_clk_sft}] ;# 125MHz antiphase (coherent with mem_clk)

// tx_pll outputs (P0b proven)
create_generated_clock -name pxl_clk     -source [get_ports {clk}] -master_clock clk -divide_by 2    [get_nets {pxl_clk}]     ;# 25MHz pixel
create_generated_clock -name pxl_5x      -source [get_ports {clk}] -master_clock clk -multiply_by 2.5 [get_nets {pxl_5x}]     ;# 125MHz serializer

// async domains: SD/SoC vs SDRAM pair vs video pair
set_clock_groups -asynchronous -group {sys_clk} -group {mem_clk mem_clk_sft} -group {pxl_clk pxl_5x}

// async inputs (uart has internal sync; SD MISO sampled by SPI shift logic)
set_false_path -from [get_ports {uart_rxd}]
set_false_path -from [get_ports {SD_MISO}]

// global reset is generated in the 50M domain and consumed everywhere
set_false_path -from [get_nets {rst_all}]

// P6 audio: sys_clk (PLL 25M) <-> raw 50M input clk crossings are explicit 2FF
// synchronisers (see audio_ctrl.v control CDC).  sys_clk is a generated clock of
// clk, so TD files these as "same domain" and flags meaningless hold numbers;
// the false path documents that the 2FF pairs handle metastability themselves.
set_false_path -from [get_clocks {sys_clk}] -to [get_clocks {clk}]
set_false_path -from [get_clocks {clk}] -to [get_clocks {sys_clk}]
