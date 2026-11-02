---
name: fpga-eg4s20-bringup
description: "Use when working on THIS EG4S20 (Anlogic) + Cortex-M0 FPGA project at D:\\project (P2 SD-card BMP slideshow or its P3/P4 successors): building firmware with Keil UV4, building the bitstream with Tang Dynasty (td_commands_prompt.exe + run_p2.tcl), debugging the AHB-Lite SoC / SD-SPI / exFAT firmware / HDMI output, asking the user to flash and report, or interpreting the HDMI 8-band debug display. Contains the project's non-obvious rules: which sandbox mode is required for each build tool, the exact TD clean sequence, the boot-signature and band-diagnostic protocol, the AHB read-data-phase trap that broke sd_ctrl, the correct on-device exFAT field offsets, and the known-benign SDRAM hard-IP timing violations."
---

# EG4S20 + Cortex-M0 project bring-up playbook

Board: Anlogic EG4S20BG256 core board + carrier. 50 MHz in (R7), internal PLLs give
25 MHz `sys_clk` (SoC/AHB, SD SPI 6.25 MHz), 125 MHz `mem_clk` (on-die 64 Mb SDRAM),
25.175 MHz `pxl_clk` + 125.875 MHz `pxl_5x` (HDMI TMDS).

Layout: RTL `project0\prj\p2_sd_display\user_source\hdl_source\`, firmware `project0\m0_p2\`,
build cwd `project0\prj\p2_sd_display\`.

## Hard rules

1. **The file sandbox must NOT be `workspace-write` for any build step.** Under it,
   `UV4.exe` exits 0 without compiling and without writing its log, and any
   `Copy-Item` into `prj\p2_sd_display\` fails with "access denied". Use
   `danger-full-access` for every Keil / Tang Dynasty / hex-copy call.
2. **No simulator exists on this machine** (no iverilog / verilator / yosys / gtkwave).
   RTL changes are verified by compiling + flashing only. Reason from the RTL, not from waveforms.
3. **`D:\project` is not a git repo.** Back up before overwriting: `Move-Item x.bit x_v<N>.bit`.
   Keep every firmware/bitstream pair labelled with a version (v5, v6, v7 ...).
4. **Never ask the user to flash a bitstream whose provenance you have not checked**
   (build log `P2_FLOW_DONE`, 0 ERROR, bit timestamp, hex MD5 in both places).
5. **One variable per board round.** Each flash round costs the user a manual step, so put a
   fresh boot signature in it and ask for the band pattern, not for prose.

## Firmware build (Keil, uv4 command line)

```powershell
$log='D:\project\project0\m0_p2\build_vN.log'
$p = Start-Process -FilePath 'D:\Keil_v5\UV4\UV4.exe' `
      -ArgumentList '-b','d:\project\project0\m0_p2\m0_p2.uvprojx','-j0','-o',$log `
      -Wait -PassThru
```
Exit 0 = clean, 1 = warnings only, >=2 = error. `-r` (rebuild all) also works.
Then **always** sync the image and compare hashes — the BRAM init `$readmemh` path is
relative to the RTL source dir:

```powershell
Copy-Item 'D:\project\project0\m0_p2\m0_code.hex' `
          'D:\project\project0\prj\p2_sd_display\m0_code.hex' -Force
Get-FileHash ...m0_p2\m0_code.hex -Algorithm MD5
Get-FileHash ...\prj\p2_sd_display\m0_code.hex -Algorithm MD5   # must match
```

Memory budget is tight and fixed by `m0_p2\code.sct`: `RW_IRAM1` at 0x3000, max 0xA00;
stack `ARM_LIB_STACK 0x3A00 0x600`; vector stack top 0x4000. MicroLIB is mandatory
(`<useUlib>1`) — the ARM standard library startup deadlocks on this silicon.
Do not add new static 512 B buffers; reuse `hdr[512]`.

## Bitstream build (Tang Dynasty 6.2.1)

cwd must be `D:\project\project0\prj\p2_sd_display`.

```powershell
Remove-Item -Recurse -Force .\p2_sd_display_Runs        # exact name, NOT .\runs
Remove-Item -Force .\p2_sd_display.al,.\p2_sd_display_inst.bid,`
                   .\p2_timing.rpt,.\p2_rtl.area,.\p2_final.area
& 'D:\FPGA\bin\td_commands_prompt.exe' run_p2.tcl *> p2_build_console.log
```
~98 s. The wrapper's exit code is meaningless — success = log tail contains
`P2_FLOW_DONE` and no `ERROR` line, and `p2_sd_display.bit` is 648258 B.
If you forget to delete `p2_sd_display_Runs` you get `PRJ-5301 Run syn_1 already existed`
then `PRJ-8805 Runs syn_1 need to be reset first` and no bitstream.
`run_p2.tcl` regenerates `.al` and re-adds all sources incl. `al_ip/tx_pll.v`,
`adc_sdc/p2_pin.adc`, `adc_sdc/p2.sdc`.

Known-benign timing: violations reported on the on-die SDRAM hard macro
(`EG_PHY_SDRAM_2M_32`, e.g. setup -2.692 ns / hold -0.126 ns, 100 % cell delay, 0 net,
0 logic level) and the FIFO cross-clock path inside `u_frame_rw/write_buf`
(-0.037 ns on `wr_to_rd_cross_inst -> frame_fifo_read`). User-logic domains close.
These were identical on builds that ran on the board; do not chase them.

## Board-side evidence channel (use this, not the UART)

The SoC has a debug slave at **P3 = 0x4002_0000**, write-only, low 8 bits latched
(`CortexM0_SoC.v`, `p3_wr_q`), driving 8 vertical bars on HDMI (`p2_sd_display.v`,
`DBG_BARS`): **band i (1-based, left to right) = bit i-1**.

Firmware: `#define DBG_REG (*(volatile uint32_t *)0x40020000u)`; `dbg_mark(b)` ORs bit b.
Bar rendering auto-hides after the first real frame commit
(`bars_mode = DBG_BARS & ~frame_seen`, `frame_seen` set by `frame_commit_tgl`), so
"bars on screen" is the unambiguous statement "not one frame has been committed".

Milestone bits used by `main.c`: 0 reached main, 1 uart_init, 2 banner printed,
3 SD init wait, 4 SD init done, 5 exFAT mount ok, 6 first frame played, 7 heartbeat.

Failure codes written instead of milestones (v7 protocol). From v8 on, `dbg_probe` forwards
all 8 bits (`else if (dbg_fw_state != 8'd0) dbg_probe <= dbg_fw_state;` — keep the `else`
chain well-formed or TD dies with `PRJ-8806 Run syn_1 has exited unexpectedly`).
Before v8 only `[6:0]` reached the screen, so bit 7 was invisible.

**Count flashes, do not read bands.** Band patterns are badly degraded by moire and screen
glare in phone photos (an eight-band code was mis-decoded once). From v9 on `fail_show(n)`
blinks the whole screen white `n` times (280 ms on / 280 ms off, then 1.8 s quiet) and the
user can just count. Use the same trick for any new code, and always ask "how many flashes",
never "which bars are white".

| Bands white | Meaning |
|---|---|
| one band, r = 1..4 | mount failed, step r (1 LBA0 read, 2 PBR read, 3 not "EXFAT ", 4 bad BPB) |
| one band, 5 | mount OK but zero `*.bmp` in root |
| 7 + N | `play_frame` returned -N (1 sector read, 2 not BM, 3 not 640x480, 4 not 24bpp, 5 file too short, 6 FAT chain broken, 7 frame-commit timeout) |
| bars gone, image shown | success |

A fresh bitstream should also change the **boot signature** (`dbg_probe <= 8'h..` in the
reset branch of `CortexM0_SoC.v`) so the user can confirm which bitstream is running:
v5 = 0xAA (bands 2,4,6,8), v6 = 0xCC (3,4,7,8), v7 = 0x99 (1,4,5,8),
v8 = 0xE1, v9 = 0xE3, v10 = 0xE5, v13 = 0xE7, v15 = 0xE9 (1,4,6,7,8),
v16 = 0xF2, v17 = 0xF4, v18 = 0xF6, v19 = 0xF8 (bands 4..8, P5 ISP build).

### Serial is not a trustworthy channel on this board
`doc\hw\P1_UART.md` line 106 states the UART was **never smoke-verified on hardware**;
T7/T8 came from a text-level schematic inference (CH340N on the core board's "UART2USB"
socket). A correct firmware can therefore produce zero bytes on the wire (observed).
Before spending rounds on it: confirm the USB cable is in the UART2USB socket, the
terminal is 115200-8-N-1 on the right COM port, then consider swapping the T7/T8
assignment in `adc_sdc\p2_pin.adc`. Prefer the band channel until serial is proven.

## AHB-Lite traps in this SoC (these are the real bug sources)

- All four slaves are **zero-wait** (`HREADYOUT = 1`); a read's data phase is exactly the
  cycle after its address phase. `AHBlite_SlaveMUX` latches `hsel_reg` on HREADY, and
  `Block_RAM` is a **registered** read, so the M0 can only be sampling `HRDATA` in the
  **data phase**. Any read-side counter or FIFO pointer must be advanced by a
  data-phase pulse (`sel_rd` delayed one cycle), never by the address phase — doing it in
  the address phase makes the data phase return the *next* byte/word.
  `sd_ctrl.v` had exactly this bug (`rd_rawdata = sel_rd & reg_sel==3` incremented
  `raw_rp` in the address phase), which rotated every 512 B sector by one byte and made
  the exFAT mount fail. `ahb_uart.v` uses an unlatched `HADDR[4:2]` read mux — same family
  of hazard, unproven on the board.
- `HWDATA` is only valid in the data phase: write strobes must be registered from the
  address phase and applied together with `HWDATA`.
- Address decoding is `HADDR[31:16]` only (0x0000 BRAM 16 KB, 0x4000 AHB UART,
  0x4001 sd_ctrl, 0x4002 debug; anything else lands on the default slave, which
  acknowledges and returns garbage — silent failure).

## exFAT on-device parsing (field offsets that matter)

Main boot sector: `0x50` FatOffset(4), `0x54` FatLength(4), `0x58` ClusterHeapOffset(4),
`0x5C` ClusterCount(4), `0x60` FirstClusterOfRootDirectory(4), `0x64`
VolumeSerialNumber(4), `0x6C` BytesPerSectorShift(1), **`0x6D` SectorsPerClusterShift(1)**,
`0x6E` NumberOfFats(1). So `spc = 1 << buf[0x6D]` (it is a *shift*, not a count) and
`fat_off = pbr_lba + rd32(0x50)`, `heap_off = pbr_lba + rd32(0x58)`,
`root_cl = rd32(0x60)`. `cluster_base(cl) = heap_off + (cl - 2) * spc`.
FAT entries are 32-bit: `byteofs = cl << 2`.

Directory entries (32 B each): type `0x85` = File (offset 1 SecondaryCount, offset 4
FileAttributes(2), bit 4 = directory), then `0xC0` = Stream extension
(offset 1 GeneralSecondaryFlags, bit 1 = NoFatChain; offset 3 NameLength(1);
offset 8 ValidDataLength(8); **offset 20 FirstCluster(4); offset 24 DataLength(8)**),
then `0xC1` = FileName (UTF-16LE from offset 2, **NUL-padded** — stop at the first zero
UTF-16 unit, and use `NameLength` if you trust it). Reading the file size at `se+3` or the
BPB through the FAT32 layout is the classic way to make this firmware report garbage sizes.

Two more traps that produced "0 files on card" and could be mistaken for a card problem:

- Copying the whole 32 B of every `0xC1` entry into the name buffer leaves `"1.bmp" + 10 NULs`,
  so the `nm[ni-4] == '.'` extension test reads a NUL and every file is skipped.
- A **superfloppy** exFAT card (no MBR partition table, LBA 0 is the boot sector) makes the
  MBR partition-entry read return 0xFF-filled garbage; check `"EXFAT "` at LBA 0 *before*
  following the partition entry, otherwise the mount dies reading a bogus LBA.

### Reading a card from the PC without admin rights

`open(r"\\.\F:", "rb")` works read-only without elevation (`Get-Disk` / `Get-Partition` /
`Win32_DiskDrive` all fail with access denied). Decode BMPs with numpy, not cv2 —
`cv2.imread` fails on the Chinese paths here:
`np.fromfile(p, dtype=np.uint8)[54:54+640*480*3].reshape(480,640,3)[::-1]`
(rows are bottom-up; convert with `[:, :, ::-1]` for BGR2RGB).

## Frame path facts

`sd_ctrl` streams a sector at a time (`CT_STREAM`, toggle in STATUS bit 3) into
`bmp_pack`, which windows `[pixel_offset, file_len)`, packs `{R,G,B,0}` and writes the
SDRAM frame buffer (`BUF0 = 0x00000`, `BUF1 = 0x4B000`, 307200 words) with vertical flip
enabled. 640x480x24 needs `(pixel_offset + 921600 + 511) >> 9` = 1801 sectors;
`CT_COMMIT` publishes the buffer and `frame_commit_tgl` returns to the firmware via
`sd_wait_commit`. Buffers are toggled with `CT_BUF_TOGGLE` on success only.

Local-IP gotchas: `afifo_16_32_256.v` instantiates a module named `wfifo_32_32_512`
and `afifo_32_16_256.v` a module named `rfifo_32_32_512` — file names and module names
differ. `WRITE_V_FLIP=1` handles bottom-up BMP rows.

### Three frame-path bugs that all looked like "the picture is broken"

1. **Contiguous (NoFatChain) files never advanced their cluster.** The streaming loop only
   called `exf_fat_next()` when `!f->nofat`; for `nofat == 1` the cluster stayed at the first
   one, so the same cluster was re-streamed again and again — the picture repeated every
   `cluster_bytes / 1920` rows (a 128 KB cluster on a 640x480 image = every 68.27 rows,
   about seven horizontal bands). Fix: for contiguous files the next cluster is physically
   `cl + 1`; only FAT-chained files call `exf_fat_next()`.
2. **Commit-toggle baselined too late.** `tgl_c = SD_TGL_COMMIT(SD_STATUS)` must be sampled
   *immediately after* `CT_FRAME_START`, before the first sector is streamed. The hardware
   toggles `frame_commit_tgl` a few microseconds after the last pixel word lands — i.e. while
   the firmware is still polling the last sector's stream toggle — so a late baseline is
   already the new value and `sd_wait_commit` times out after 3.2 s with err 7 forever.
3. **`disp_en` cleared by unrelated writes.** The original `sd_ctrl.v` had
   `if (HWDATA[6]==0 && HWDATA[5]==0) disp_en_q <= 0;`, so the per-frame `CT_PACK_RESET`
   blanked the display. `disp_en` must only change on an explicit CTRL command.
4. **A directory entry set straddling a sector boundary was dropped.** An exFAT file entry
   plus its `0xC1` name entries is `32 * (1 + secondary_count)` bytes; an 18-character name
   needs four entries = 128 bytes, and one of the four slides in this project landed at
   offset 480 of its sector. The old guard `if (p + 32*(scnt+1) > 512) continue;` silently
   discarded that whole file, so the slideshow skipped exactly one picture. Fix: if the set
   does not fit, copy the sector tail into a small staging buffer, read the next sector of the
   same cluster (`exf_cluster_base(cl) + s + 1`), append, and parse from the staging buffer.
   `work\scan_sim.py` (byte-exact Python replay of `scan_cluster()`) reproduces this in
   seconds without flashing anything — port the C scanner to Python whenever the file list
   looks wrong.

### FIFO used-word counters must be registered at 125 MHz

The frame FIFOs expose `wrusedw`/`rdusedw` straight from the gray-to-binary pointer
subtraction. At 125 MHz that is a 7.9 ns path (8 logic levels, six of them adder carry
stages) that then feeds the burst controller's threshold compare — a `mem_clk -> mem_clk`
slack of **-0.237 ns** in v16/v17. A single mis-decided compare moves the whole 256-word
burst, i.e. 640 pixels = 0.4 rows, which on screen is a high-frequency vertical jitter of
±0.5..1.25 rows (measured with `cv2.phaseCorrelate` on a phone video). Register the two
differences in the FIFO wrapper (`afifo_16_32_256.v`, `afifo_32_16_256.v`) and keep
`full`/`empty` on the live values; the one-cycle-late count is safe because both controllers
already demand a 257-element margin. This took the path to **+1.476 ns** and the jitter
disappeared. Lesson: "same RTL, different bitstream, new artifact" means *timing
marginality* — read `p2_timing.rpt`, fix the worst intra-clock path, and never chase it in
the firmware.

### Isolating "SD data vs memory vs video" with a synthetic frame

When the picture is wrong, first prove the SDRAM/HMDI side with a pattern generator instead
of guessing: gate a small FSM into `frame_read_write` (`DBG_PAT` in `p2_sd_display.v`)
that writes 307200 synthetic words (`x==0` white column, `y==0` blue row, `x==320` white,
`y==240` yellow, `x==639` red, else `{x[7:0],y[7:0],8'h00}`) at ~195k words/s (one word per
128 `sys_clk`) and forces `read_addr_index = 0`, `disp_en = 1`. If the gradient plus markers
appear at the right places the memory/HDMI path is proven and the bug is in the SD data.
Remember to set `DBG_PAT = 0` afterwards.

Progress probes that also work: count `pack_we` into a thermometer (`>=1/32768/131072/262144/
307200`), show `frame_commit_tgl`, `disp_en`, and a 0.75 Hz heartbeat bit — that is how the
commit race above was proven (the first six bands lit, the `disp_en` band never did).

## Debug order that works

1. Boot signature first: which bitstream is actually running?
2. Count the flashes → which error code?
3. `mount step N` → check the BPB offsets above (and the superfloppy case) before
   suspecting the SD card.
4. `files = 0` → directory entries (0x85/0xC0/0xC1, NUL padding, DataLength at se+24) and
   the root cluster chain.
5. `play err N` → 2/3/4/5 are header checks (dump the first sector via flashes if needed),
   1/7 are timeouts, 6 is the cluster chain — remember `NoFatChain` files must advance by
   `cl + 1`.
6. Wrong picture but no error → run the synthetic-frame oracle (`DBG_PAT = 1`) before
   touching the SD side; a repeating pattern every ~68 rows means the same cluster is being
   re-read.
7. Only then polish the video path. Finish with `doc\hw\P2_BRINGUP.md`'s checklist.

## Version log (bitstream / firmware pairs on disk)

`p2_sd_display.bit` is always the newest; older ones are kept as `p2_sd_display_v<N>.bit`.
v13 = first correct picture, v15 = 4 BMPs play correctly (contiguous-cluster fix).
v22 = ISP filters + keypad + 7-segment. v41 = audio unblocked. v42 = sigma-delta default.
v45/v47 = spectrum bars. v48 = microphone ADC. v52 = character packs (`/CHARS/`).
v53 = non-blocking key display, instant KEY7, SD hot-plug (current frozen build).

---

# Audio output (P6) — what actually bites

## The DAC is a delta-sigma modulator built in RTL, not an I2S codec

`audio_ctrl.v` owns it: AHB FIFO (512 x 32) -> sample tick -> optional high shelf ->
digital volume -> **sigma-delta (default, 50 MHz 1-bit)** or 8-bit noise-shaped PWM
(195 kHz carrier), selected by `CTRL[7]`, out on `audio_pwm` = board pin F3 ->
LMV358 low-pass -> FM8002A class-D -> 3.5 mm / speaker header.

## Five bugs that all sounded like "the music is broken"

1. **One AHB word = TWO consecutive 16-bit samples.** The player pops one half-word per
   `samp_tick`. Pushing `L | R<<16` (or `v | v<<16`) plays every sample twice = half speed,
   and interleaves L/R as a time series = mush. Fold to mono first, then pack two
   consecutive samples per word.
2. **`au_level()` read 0 forever** because the read mux decoded STATUS as `3'd1` while the
   register is at `+0x08` (`reg_sel = 4'd2`). The firmware then spun in
   `while (au_level() < 448)` pouring words at full CPU speed, the RTL dropped them
   (`we = wr_data & ~fifo_full`), so the accepted words came from wildly different file
   offsets -> "can't recognise the song at all". Any infinite-loop feeder is a decode bug.
3. **A write-only register must never be read-modified-written.** `AU_CTRL` reads back 0,
   so `AU_CTRL = (AU_CTRL & EN) | FLUSH` cleared enable *and* the mode bit. Keep a shadow
   register in the firmware instead.
4. **Blocking delays starve the FIFO.** 512 words is ~11-23 ms. Any `delay_ms(600)` inside
   a key handler mutes the music for that long; the user reports it as "KEY1 breaks
   playback" and "I have to press KEY7 several times". Every display hold must call the
   audio service.
5. **8-bit PWM leaves an audible fixed-level floor** (it is quantization noise; it does not
   follow the volume because the volume multiplier sits before the modulator). 1-bit
   sigma-delta at 50 MHz is ~20 dB better -- make it the default.

## The analogue chain is narrow-band: measure it, do not assume

Board reference, measured against the original WAV with a long-term spectrum:

| band | 250 Hz | 1 kHz | 2 kHz | 4 kHz | 8 kHz |
|---|---|---|---|---|---|
| FPGA path vs WAV | +8 dB | +1 dB | -10 dB | -19 dB | -37 dB |

Cause: `Audio_PWM -> LMV358 (10k/20k + 1uF; 10k+0.01uF ~ 1.6 kHz and 10k+0.033uF ~ 480 Hz)
-> FM8002A`. The vendor used a cheap RC to kill the 195 kHz carrier and lost everything
above 2 kHz. A software high shelf (single pole ~880 Hz, `G = shelf/256`, 0/+6/+12/+18 dB)
helps the level but cannot restore SNR -- 0 dB measured best by ear. Do not try to fix this
in RTL; say "hardware limitation" and move on.

## Test-signal methodology (no scope, no simulator)

- Put a **hardware tone generator inside the audio block** (phase accumulator + 64-entry
  sine ROM, register = amplitude and step). It bypasses SD, firmware and the FIFO entirely,
  so "tone clean, music dirty" immediately separates the DAC from the data supply.
- A firmware-fed tone is *not* trustworthy: it inherits any FIFO stall and the FFT will show
  a chopped spectrum (we measured 1032 Hz and a 32 Hz envelope for a nominal 1 kHz tone).
- Phone recordings have AGC: comparing levels across segments of one recording is invalid.
  Comparing *relative* band energies of the same music against the original file is valid.

---

# Spectrum bars (P6)

## Do not build a 512-point FFT here

It needs twiddle ROM, bit reversal, a data RAM and butterflies (4-6k LUT), and with no
simulator every bug costs a full 2-minute build + board test. A **log filter bank** looks
the same on screen and is made of shifts and adds only:

```
for each band g:  lp  += (x - lp ) >>> sh[g];      /* pole 1 */
                  lp2 += (lp - lp2) >>> sh[g];      /* pole 2 = 12 dB/oct */
band magnitude = lp2[g] - lp2[g+1]                  /* last band: lp2[15] */
```

- Corners must be **monotonic**: our first version alternated 1.5x/3x coefficients, so the
  "bands" came out as 7k/10.5k/3.5k/5.3k... every real tone lit half the display. Put the
  faster pole consistently on one phase.
- A one-pole bank smears a single tone over ~15 dB; only two poles per band give
  "one tone = 2-3 bars". Add a relative gate (`(mag<<2) < max` -> 0, i.e. -12 dB) for
  leakage.
- **Never index a register array with a variable** (`lp[i]` inside a for loop): TD builds a
  32:1 mux per element -> LUT 11.7k and -11.8 ns at 50 MHz. Unroll with `generate` +
  constant indices + a `function integer sh_of(input integer idx)` returning a literal.
- Register the analyser input (`xin_r <= xin_dc`) and compute magnitudes from the
  *registered* `lp2`, not from the combinational next value -- otherwise the timing path
  starts at the tone ROM/multiplier output and blows the 20 ns budget.
- DC block before the bank (`x -= lp; lp += x>>>10`): when the FIFO runs dry the last sample
  freezes into a DC offset that keeps the low bars permanently lit.

---

# Keypad and 7-segment (P5)

- 4x4 matrix: `key_col = E11/D11/C11/F10`, `key_row = E10/C10/F9/D9` (vendor `keyboard.adc`
  matches). Row scan is one-hot low, rotating; sample **mid-interval** so the column lines
  have settled.
- `row == 4'b1110` samples bits [3:0]; `1101` [7:4]; `1011` [11:8]; `0111` [15:12].
  That is silk KEY0..KEY15 in reading order; `key[15]` is the top-left key.
- **Edge detect, not level**: `press = (~key_stbl) & key_stbl_d` (delayed *stabilised*
  key). Comparing against `~key_stbl` makes the pulse permanent while the key is held.
- **A sticky level can only report the first press.** Our first AHB key path OR-ed the level
  into a sticky register: KEY7 started the music once and could never stop it. Ship 2-bit
  per-key counters instead (`ev_cnt[2*k +: 2]`), let the firmware compare against a shadow,
  and clear on **read in the data phase** (`rd_data_q & (reg_sel == N)`) -- clearing in the
  address phase wipes the event before HRDATA is sampled.
- 7-segment: `SEG_SEL = C9/B6/A5/A3`, `SEG_LED = A4/A6/B8/E8/A7/B5/A8/C8`, segments
  active-high, digit select active-low. Digit order on this board is reversed from the
  obvious guess (`sel=0111` is the leftmost), verify with a known constant like `0xAC3B`
  before trusting any reading. That single digit-order bug made us chase a "23x slow clock"
  that did not exist.

---

# Character packs (P7) and card swapping

Layout: `/CHARS/<name>/{*.bmp, voice.wav, char.ini(dwell=3)}` plus `/music*.wav` at the root
(shared music library). Detect directories two levels deep, fall back to the root-level flat
BMP layout so old cards keep working. `char.ini` only needs `dwell=`.

- exFAT directory entries for a long name (4 entries = 128 B) can **straddle a sector
  boundary**; the naive `if (p + 32*(n+1) > 512) continue;` silently drops that file.
  Read the next sector and splice.
- There is **no card-detect pin**. `sd_card_sec_read_write` only initialises once, and
  `S_CMD17` retries a bad R1 forever, so pulling the card kills the whole chain.
  Add a watchdog in `sd_ctrl` (~21 ms of stuck `hw_busy`): abort the transfer, pulse
  `sd_reinit` for ~1.3 ms so the card FSM re-runs CMD0/CMD8/CMD55/CMD41/CMD16, and have the
  firmware re-`exf_mount()` + rescan after 3 consecutive failures.

---

# Tooling traps (Windows / TD / Keil)

- **Never `Set-Content` a source file.** PowerShell 5 writes UTF-8 as GBK on this box; one
  `audio_ctrl.v` came back as `invalid UTF-8 text` with a single corrupted line. Use the
  editor tool, or `[System.IO.File]::WriteAllText($p, $s, [Text.UTF8Encoding]::new($false))`.
- New `.v` files must be added by hand to `run_p2.tcl`'s `add_files { ... }`.
- After adding/removing files, delete `p2_sd_display_Runs` **and** `p2_sd_display.al`,
  otherwise TD reports `PRJ-8806` / `PRJ-5301` and produces no bitstream.
- `HDL-7225` "already implicitly declared": a `wire` used in an instantiation before its
  declaration. Move declarations above the instance.
- A design at ~75 % LUT fails *placement*, not timing (`RUN-8102` in `phy_1`): the 8-band
  analyser had to shrink from 16 bands before it would route at all.
- Keil `UV4.exe` is a GUI app: use `Start-Process -Wait -PassThru` and check the exit code
  (0/1 = ok, >=2 = real error). Foreground `&` returns immediately and silently.
- Vendor sources under `M0_Borad` are **GBK**; read them with
  `[Text.Encoding]::GetEncoding(936).GetString([IO.File]::ReadAllBytes($p))`.
