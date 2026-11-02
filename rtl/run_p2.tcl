# P2: M0 SoC + SD BMP slideshow + SDRAM framebuffer + HDMI out, TD 6.2 run-system flow
import_device eagle_s20.db -package EG4S20BG256
create_project p2_sd_display ./ -family EG4 -device EG4S20BG256
top_module p2_sd_display

add_files {user_source/hdl_source/p2/p2_sd_display.v user_source/hdl_source/p2/sd_ctrl.v user_source/hdl_source/p2/bmp_pack.v user_source/hdl_source/p2/isp_filter.v user_source/hdl_source/p2/keypad_4x4.v user_source/hdl_source/p2/seg_display.v user_source/hdl_source/p2/spectrum_bank.v user_source/hdl_source/p2/mic_adc.v user_source/hdl_source/p2/audio_ctrl.v user_source/hdl_source/IP/sys_pll.v user_source/hdl_source/IP/afifo_16_32_256.v user_source/hdl_source/IP/afifo_32_16_256.v user_source/hdl_source/include/global_def.v user_source/hdl_source/include/sdr_as_ram.enc.v user_source/hdl_source/include/sdr_init_ref.enc.v user_source/hdl_source/include/sdr_wrrd.enc.v user_source/hdl_source/SD/sd_card_top.v user_source/hdl_source/SD/sd_card_sec_read_write.v user_source/hdl_source/SD/sd_card_cmd.v user_source/hdl_source/SD/spi_master.v user_source/hdl_source/SD/sdram.v user_source/hdl_source/SD/frame_read_write.v user_source/hdl_source/SD/frame_fifo_write.v user_source/hdl_source/SD/frame_fifo_read.v user_source/hdl_source/SD/color_bar.v user_source/hdl_source/SD/video_define.v user_source/hdl_source/SD/video_timing_data.v user_source/hdl_source/SD/video_delay.v user_source/hdl_source/soc/CortexM0_SoC.v user_source/hdl_source/soc/cortexm0ds_logic.v user_source/hdl_source/soc/AHBlite_Interconnect.v user_source/hdl_source/soc/AHBlite_Decoder.v user_source/hdl_source/soc/AHBlite_SlaveMUX.v user_source/hdl_source/soc/AHBlite_Block_RAM.v user_source/hdl_source/soc/Block_RAM.v user_source/hdl_source/soc/ahb_uart.v user_source/hdl_source/p0b/hdmi_tx.vhd user_source/hdl_source/p0b/DVITransmitter.enc.vhd user_source/hdl_source/p0b/SerializerN_1_lvds.enc.vhd user_source/hdl_source/p0b/SerializerN_1_lvds_dat.enc.vhd user_source/hdl_source/p0b/TMDSEncoder.enc.vhd al_ip/tx_pll.v adc_sdc/p2_pin.adc adc_sdc/p2.sdc}
add_include_dir ./user_source/hdl_source/include

catch { create_run -constrset constrain_1 syn_1 } msg_syn
catch { create_run -syn_run syn_1 -constrset constrain_1 phy_1 } msg_phy
puts "CREATE_RUN syn: $msg_syn"
puts "CREATE_RUN phy: $msg_phy"

catch { reset_run syn_1 } msg_r1
catch { reset_run phy_1 } msg_r2

launch_runs syn_1
wait_run syn_1 -quiet
open_run syn_1
report_area -file p2_rtl.area

launch_runs -step route phy_1
wait_run phy_1 -quiet
open_run phy_1
report_timing_summary -file p2_timing.rpt
report_area -file p2_final.area

bitgen -bit p2_sd_display.bit
puts "P2_FLOW_DONE"
close_project
exit
