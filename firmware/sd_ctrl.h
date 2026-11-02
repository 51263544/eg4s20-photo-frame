#ifndef SD_CTRL_H
#define SD_CTRL_H

#include <stdint.h>

/* sd_ctrl AHB slave @ 0x4001_0000 (Decoder Port2), 25MHz domain */
#define SD_BASE         0x40010000UL

#define SD_CTRL         (*(volatile uint32_t *)(SD_BASE + 0x00))
#define SD_STATUS       (*(volatile uint32_t *)(SD_BASE + 0x04))
#define SD_SEC_ADDR     (*(volatile uint32_t *)(SD_BASE + 0x08))
#define SD_RAW_DATA     (*(volatile uint32_t *)(SD_BASE + 0x0C))
#define SD_PIXEL_OFFSET (*(volatile uint32_t *)(SD_BASE + 0x10))
#define SD_FILE_LEN     (*(volatile uint32_t *)(SD_BASE + 0x14))

/* Transition effect control (write-only, read back [3:0] for verification).
 *   [2:0] mode  0 none / 1 dip to black / 2 wipe / 3 blinds / 4 white flash
 *   [3]   dark  1 = cover the screen, 0 = uncover
 * The pixel stage ramps k by 16 per video frame (~0.27 s end to end), so the
 * firmware only raises `dark`, waits ~0.3 s, commits, then lowers it. */
#define SD_XFX          (*(volatile uint32_t *)(SD_BASE + 0x18))
#define FX_NONE         0u
#define FX_DIP          1u
#define FX_WIPE         2u
#define FX_BLIND        3u
#define FX_FLASH        4u
#define FX_MODE_MASK    7u
#define FX_DARK         (1u << 3)
#define FX_AMB          (1u << 4)

/* CTRL write bits (pulse semantics: one register write per command) */
#define CT_RAW_READ     (1u << 0)   /* read SEC_ADDR into raw buffer (512B)   */
#define CT_STREAM       (1u << 1)   /* read SEC_ADDR into bmp_pack stream     */
#define CT_PACK_RESET   (1u << 2)   /* reset packer byte counter (new file)   */
#define CT_FRAME_START  (1u << 3)   /* open frame write session               */
#define CT_BUF_TOGGLE   (1u << 4)   /* swap write buffer target               */
#define CT_COMMIT       (1u << 5)   /* disp <- written buffer, disp_en = 1    */
#define CT_DISP_EN      (1u << 6)   /* 0 in this bit position hides picture   */

/* STATUS read bits */
#define STS_INIT_DONE   (1u << 0)
#define STS_HW_BUSY     (1u << 1)
#define STS_RAW_DONE    (1u << 2)
#define STS_STREAM_TGL  (1u << 3)
#define STS_COMMIT_TGL  (1u << 4)
#define STS_WR_PENDING  (1u << 5)

#define SD_TGL_STREAM(status)  (((status) >> 3) & 1u)
#define SD_TGL_COMMIT(status)  (((status) >> 4) & 1u)

/* raw sector read into dst[512]; 0 = ok, 1 = timeout */
uint8_t sd_read_sector(uint32_t addr, uint8_t *dst);

/* stream one sector into the packer; *tgl tracks STATUS bit3, updated on done */
void sd_stream_sector(uint32_t addr, uint32_t *tgl);

/* wait for frame write finish (commit toggle flip); 0 = ok, 1 = timeout */
uint8_t sd_wait_commit(uint32_t *tgl);

#endif /* SD_CTRL_H */
