/*
 * main.c -- P2 firmware: SD card (exFAT) BMP slideshow player.
 * M0 commands the sd_ctrl hardware chain: exFAT walk via raw sector reads,
 * pixel streaming via per-sector STREAM commands, frame commit handled by
 * the SDRAM double-buffer logic in RTL.
 *
 * UART 115200-8N1:
 *   'N<sec>\n'  set dwell seconds (1..60)
 *   '?'         print status
 *
 * 25MHz SoC clock, 16KB code BRAM (RO 12KB + RW/ZI 4KB).
 */
#include <stdint.h>
#include "ahb_uart.h"
#include "sd_ctrl.h"
#include "exfat.h"
#include "audio.h"

#ifndef DEFAULT_DWELL_SEC
#define DEFAULT_DWELL_SEC 3u
#endif

#define PIX_BYTES   921600u              /* 640*480*3                      */
#define LOOPS_PER_MS 5000u               /* ~5 cycles/iter @ 25MHz         */

/* debug milestone register on AHB P3 (0x4002_0000), shown on HDMI bands */
#define DBG_REG    (*(volatile uint32_t *)0x40020000u)
static inline void dbg_mark(unsigned bit) { DBG_REG |= (1u << bit); }

static bmp_entry_t files[EXF_MAX_FILES];
static int         nfiles;
static int         cur_idx;
static uint32_t    dwell_sec = DEFAULT_DWELL_SEC;
static uint32_t    frame_no;
static uint32_t    stream_to;            /* per-sector stream timeouts     */
static uint8_t     hdr[512];             /* raw sector scratch (BMP header) */
static uint32_t    hb_en = 1u;           /* main-loop heartbeat on HDMI    */
static bmp_entry_t wavs[8];              /* P6: WAV files on the card      */
static int         nwav;
static uint32_t    srv_div;              /* music-mode display divider  */
static uint32_t    srv_ph;               /* music-mode display phase    */
static uint32_t    meas_seen;            /* last AU_ST_MEAS level seen  */
static uint32_t    mt_rate;              /* parsed WAV sample rate      */
static uint32_t    mt_ch;                /* parsed WAV channels         */
static uint32_t    mt_bits;              /* parsed WAV bits per sample  */

/* P7 resource pack.  The card may hold  CHARS/<character>/  with the pictures,
 * a voice and a char.ini inside instead of a flat root directory.  The first
 * cluster of each pack found at boot is kept so KEY9 can switch between them. */
static uint32_t    chardirs[2];
static int         nchar;                /* 0 = flat card (old layout)   */
static int         cur_char;
static uint8_t     reload;               /* main loop: restart the show  */
static uint8_t     voice_req;            /* main loop: play the voice    */
static uint8_t     mt_once;              /* WAV plays once, then stops   */
static uint8_t     remount;              /* SD card was swapped: re-read */
static uint32_t    fail_cnt;             /* consecutive frame failures   */
static bmp_entry_t voice_ent;            /* voice.wav of the current pack */
static uint8_t     has_voice;

/* sd_ctrl.h helpers ------------------------------------------------------ */

uint8_t sd_read_sector(uint32_t addr, uint8_t *dst)
{
    uint32_t t = 0;
    int      i;

    SD_SEC_ADDR = addr;
    SD_CTRL     = CT_RAW_READ;
    while (!(SD_STATUS & STS_RAW_DONE))
        if (++t > 4000000u)              /* ~160ms guard @ 25MHz           */
            return 1;
    for (i = 0; i < 512; i++)
        dst[i] = (uint8_t)(SD_RAW_DATA & 0xFFu);
    return 0;
}

void sd_stream_sector(uint32_t addr, uint32_t *tgl)
{
    uint32_t t = 0;

    SD_SEC_ADDR = addr;
    SD_CTRL     = CT_STREAM;
    while (SD_TGL_STREAM(SD_STATUS) == *tgl)
        if (++t > 4000000u) {            /* timeout: give up this sector   */
            ++stream_to;
            *tgl ^= 1u;
            return;
        }
    *tgl ^= 1u;
}

uint8_t sd_wait_commit(uint32_t *tgl)
{
    uint32_t t = 0;

    while (SD_TGL_COMMIT(SD_STATUS) == *tgl)
        if (++t > 80000000u)             /* ~3.2s, frame takes ~1.2s       */
            return 1;
    *tgl ^= 1u;
    return 0;
}

/* uart helpers ------------------------------------------------------------ */

static void uart_putdec(uint32_t v)
{
    char buf[11];
    int  i = 0;

    if (v == 0) {
        uart_putc_blocking('0');
        return;
    }
    while (v) {
        buf[i++] = (char)('0' + (v % 10u));
        v /= 10u;
    }
    while (i--)
        uart_putc_blocking(buf[i]);
}

static void uart_puthex(uint32_t v)
{
    static const char d[] = "0123456789ABCDEF";
    int i;
    for (i = 28; i >= 0; i -= 4)
        uart_putc_blocking(d[(v >> i) & 0xFu]);
}

/* hex dump of n (<64) bytes, space separated, no trailing newline */
static void uart_dump(const uint8_t *p, uint32_t n)
{
    uint32_t i;
    static const char d[] = "0123456789ABCDEF";

    for (i = 0; i < n; i++) {
        uart_putc_blocking(' ');
        uart_putc_blocking(d[(p[i] >> 4) & 0xFu]);
        uart_putc_blocking(d[p[i] & 0xFu]);
    }
}

/* poll one RX byte; handles 'N<sec>\n' and '?' */
static void poll_uart(void)
{
    int c = uart_getc();

    if (c < 0)
        return;
    if (c == '?') {
        uart_puts("init=1 files=");
        uart_putdec((uint32_t)nfiles);
        uart_puts(" cur=");
        uart_putdec((uint32_t)cur_idx);
        uart_puts(" dwell=");
        uart_putdec(dwell_sec);
        uart_puts("\r\n");
    } else if (c == 'N' || c == 'n') {
        uint32_t v = 0;
        int      got = 0;
        int      d;
        for (;;) {                       /* block until terminator         */
            d = uart_getc();
            if (d >= '0' && d <= '9') {
                v = v * 10u + (uint32_t)(d - '0');
                got = 1;
            } else if (d == '\n' || d == '\r') {
                break;
            }
        }
        if (got && v >= 1u && v <= 60u) {
            dwell_sec = v;
            uart_puts("dwell=");
            uart_putdec(dwell_sec);
            uart_puts("\r\n");
        } else {
            uart_puts("dwell range 1-60\r\n");
        }
    }
}

static void key_poll(void);              /* defined with the music player  */

/* KEY0: show the raw microphone ADC frame live on the 7-segment display, about
 * four times a second.  Whistle steadily and the digits must move - that is the
 * shortest path to "is the ADC delivering my voice or a constant?".           */
static uint32_t raw_disp;

static void delay_ms(uint32_t ms)
{
    volatile uint32_t n;
    while (ms--) {
        n = LOOPS_PER_MS;
        while (n--)
            ;
        poll_uart();
        key_poll();
        if (raw_disp) {
            static uint32_t raw_div;
            if (++raw_div >= 250u) {
                raw_div = 0u;
                au_disp(AU_MICDATA & 0xFFFFu, 1u);
            }
        }
        if (hb_en)
            DBG_REG ^= (1u << 7);        /* main-loop heartbeat            */
    }
}

/* playback ----------------------------------------------------------------- */

static uint16_t rd16(const uint8_t *p)
{
    return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* returns 0 = played, negative = skipped with reason.
 * Caller owns the BUF_TOGGLE (so it can undo it when we fail). */
static int play_frame(const bmp_entry_t *f)
{
    uint32_t tgl_s, tgl_c, pxoff, filelen, nsec, cl, sec0;
    uint32_t sic, i;

    SD_CTRL = CT_PACK_RESET;

    /* raw-read sector 0 of the file and sanity check the BMP header */
    sec0 = exf_cluster_base(f->first_cluster);
    if (sd_read_sector(sec0, hdr)) {
        uart_puts("    err1 raw read timeout, sec=");
        uart_putdec(sec0);
        uart_puts("\r\n");
        return -1;
    }
    if (hdr[0] != 'B' || hdr[1] != 'M') {
        uart_puts("    err2 not BM, hdr=");
        uart_dump(hdr, 8);
        uart_puts("\r\n");
        return -2;
    }
    if (rd32(hdr + 18) != 640u || rd32(hdr + 22) != 480u) {
        uart_puts("    err3 dims w=");
        uart_putdec(rd32(hdr + 18));
        uart_puts(" h=");
        uart_putdec(rd32(hdr + 22));
        uart_puts("\r\n");
        return -3;
    }
    if (rd16(hdr + 28) != 24u || rd32(hdr + 30) != 0u) {
        uart_puts("    err4 bpp=");
        uart_putdec(rd16(hdr + 28));
        uart_puts(" comp=");
        uart_putdec(rd32(hdr + 30));
        uart_puts("\r\n");
        return -4;
    }
    pxoff = rd32(hdr + 10);              /* pixel data offset (typ 54)     */
    if (pxoff < 54u || pxoff > 512u)
        pxoff = 54u;
    filelen = f->size;
    if (filelen < pxoff + PIX_BYTES) {
        uart_puts("    err5 pxoff=");
        uart_putdec(pxoff);
        uart_puts(" filelen=");
        uart_putdec(filelen);
        uart_puts("\r\n");
        return -5;
    }

    /* open the write session and stream the whole pixel window */
    SD_PIXEL_OFFSET = pxoff;
    SD_FILE_LEN     = filelen;
    SD_CTRL         = CT_FRAME_START;

    /* Sample the commit-toggle baseline HERE, before a single pixel byte has
     * been streamed.  It used to be sampled after the last sector, but the
     * hardware finishes writing the frame the instant the last packed pixel
     * lands -- microseconds after the last byte, while we are still polling
     * the last sector's stream toggle.  The baseline could therefore already
     * hold the NEW toggle value, and the wait below then blocked for 3.2s and
     * reported a phantom commit timeout ("frame written, disp_en never sets").
     */
    tgl_c = SD_TGL_COMMIT(SD_STATUS);

    nsec  = (pxoff + PIX_BYTES + 511u) >> 9;   /* sectors covering window */
    tgl_s = SD_TGL_STREAM(SD_STATUS);
    cl    = f->first_cluster;
    sic   = 0;
    stream_to = 0;
    for (i = 0; i < nsec; i++) {
        /* a stuck sector would cost ~1.3s each x 1801 -- bail out on the
         * first one instead of grinding through the whole frame          */
        sd_stream_sector(exf_cluster_base(cl) + sic, &tgl_s);
        if (stream_to) {
            uart_puts("    err8 stream timeout, i=");
            uart_putdec(i);
            uart_puts(" sec=");
            uart_putdec(exf_cluster_base(cl) + sic);
            uart_puts("\r\n");
            return -8;
        }
        if (++sic == exf_spc()) {
            sic = 0;
            if (f->nofat) {
                /* NoFatChain (contiguous): the next cluster is simply the
                 * next one on the volume.  The old code did NOTHING here, so
                 * cl stayed at first_cluster and the whole frame was streamed
                 * from the SAME cluster over and over -- every file came out
                 * as one cluster-worth of pixels stamped repeatedly down the
                 * screen (the "brick / torn" picture). */
                cl = cl + 1u;
            } else {
                cl = exf_fat_next(cl);
                if (cl < 2) {
                    uart_puts("    err6 fat chain end, i=");
                    uart_putdec(i);
                    uart_puts("\r\n");
                    return -6;
                }
            }
        }
    }

    /* the commit toggle was baselined before streaming -- see above */
    if (sd_wait_commit(&tgl_c)) {
        uart_puts("    err7 commit timeout, status=");
        uart_puthex(SD_STATUS);
        uart_puts("\r\n");
        return -7;
    }
    SD_CTRL = CT_COMMIT;
    return 0;
}

/* blink the whole panel N times, then keep going (play-error readout) */
static void flash_n(uint32_t n)
{
    uint32_t k;

    for (k = 0; k < n; k++) {
        DBG_REG = 0xFFu;
        delay_ms(200);
        DBG_REG = 0u;
        delay_ms(200);
    }
}

/* The panel is the only output confirmed to work, and a single lit band is
 * far too easy to misread (glare, moire, a rotated panel).  So the reason
 * code is now a COUNT: the whole panel flashes white N times, rests ~2 s,
 * then repeats.  Driving all eight bands (DBG_REG = 0xFF) turns the panel
 * into one solid white field, DBG_REG = 0 blows it out again. */
static void fail_show(uint32_t step)
{
    uint32_t k;

    hb_en = 0u;                          /* stop the heartbeat XOR         */
    uart_puts("flash code ");
    uart_putdec(step);
    uart_puts("\r\n");
    for (;;) {
        for (k = 0; k < step; k++) {
            DBG_REG = 0xFFu;             /* all bands -> whole screen white */
            delay_ms(280);
            DBG_REG = 0u;                /* all bands off -> black          */
            delay_ms(280);
        }
        delay_ms(1800);
    }
}


/*---------------------------------------------------------------------------
 * P6 music mode -- stream a PCM WAV from the SD card into the audio FIFO.
 *
 * Only the chunk headers have to live in sector 0 (that is where every
 * encoder puts them); the audio data itself is streamed sector by sector.
 * 16-bit and 8-bit PCM, mono or stereo, any sample rate (the FPGA divider is
 * programmed from the fmt chunk).
 *---------------------------------------------------------------------------*/
#define WAV_MAX 8

static int wav_header(const uint8_t *h, uint32_t *off, uint32_t *len,
                      uint32_t *ch, uint32_t *bits, uint32_t *rate)
{
    uint32_t p;

    if (h[0] != 'R' || h[1] != 'I' || h[2] != 'F' || h[3] != 'F' ||
        h[8] != 'W' || h[9] != 'A' || h[10] != 'V' || h[11] != 'E')
        return 0;

    p = 12u;
    for (;;) {
        uint32_t sz;
        if (p + 8u > 512u)
            return 0;
        sz = rd32(h + p + 4u);
        if (h[p] == 'f' && h[p + 1u] == 'm' && h[p + 2u] == 't' && h[p + 3u] == ' ') {
            if (p + 24u > 512u)
                return 0;
            *ch   = rd16(h + p + 10u);
            *rate = rd32(h + p + 12u);
            *bits = rd16(h + p + 22u);
        } else if (h[p] == 'd' && h[p + 1u] == 'a' && h[p + 2u] == 't' &&
                   h[p + 3u] == 'a') {
            *len = sz;
            *off = p + 8u;
            return (*off < 512u && *len != 0u) ? 1 : 0;
        }
        p += 8u + sz + (sz & 1u);
    }
}

/*---------------------------------------------------------------------------
 * Background music -- KEY7 (silk label) toggles it, the slideshow keeps
 * running otherwise.  While the music is on the slideshow is paused on the
 * current wallpaper, because both streams would have to share one 6.25 MHz
 * SPI link (921KB per frame + 176KB/s of 44.1kHz stereo does not fit: the
 * link tops out at ~320KB/s, measured).
 *
 * The SD sector reader is the same one sd_ctrl exposes, so a music sector read
 * must never be issued while a pixel STREAM command is in flight; that is why
 * music_service() is only called from the idle paths.
 *---------------------------------------------------------------------------*/
static uint32_t music_on;

/* Output stage selection: 1 = 195kHz noise shaped PWM (board default),
 * 0 = 50MHz 1-bit sigma-delta.  KEY6 flips it for an A/B listen.            */
static uint32_t out_pwm = 0u;         /* 0 = sigma-delta (quiet default) */

/* KEY5: 1kHz test tone generated on the FPGA, no SD card in the loop.       */
static uint32_t tone_on;
static uint32_t tone_idx;                   /* 0..4 = 500Hz..8kHz          */
static uint32_t sh_sel;                     /* shelf preset 0..3 = 0/+6/+12/+18dB */
static const uint32_t sh_tab[4] = { 256u, 512u, 1024u, 2048u };

/* KEY8: master gain selection (0 dB / -6 dB / -12 dB).                      */
static uint32_t vol_sel;

/* KEY1: 1 = the on screen bars follow the microphone ADC, 0 = the SD player. */
static uint32_t mic_on;

static struct {
    uint8_t  on;
    uint8_t  nofat;
    uint8_t  first;                  /* still have to skip the header    */
    uint8_t  pend;                   /* one mono sample waiting for a pair */
    uint16_t pendv;
    uint8_t  buf[512];
    uint32_t ch;
    uint32_t bits;
    uint32_t f_cl;                   /* first cluster                    */
    uint32_t f_off;                  /* data offset inside sector 0      */
    uint32_t total;                  /* audio bytes to play              */
    uint32_t cl;                     /* current cluster                  */
    uint32_t sic;                    /* sector index inside the cluster  */
    uint32_t pos;                    /* read index inside buf            */
    uint32_t end;                    /* one past the last valid byte     */
    uint32_t left;                   /* bytes not yet loaded into buf    */
} mt;

static void music_stop(void)
{
    mt.on = 0u;
    music_on = 0u;
    au_enable(0u);
    au_flush();
}

/* Load the next sector of the track; restarts the track at the end. */
static int music_fetch(void)
{
    uint32_t avail;
    uint32_t skip;

    if (mt.left == 0u) {                       /* end of the track       */
        if (mt_once)                           /* a voice plays only once */
            return -3;
        mt.cl    = mt.f_cl;
        mt.sic   = 0u;
        mt.left  = mt.total;
        mt.first = 1u;
        mt.pend  = 0u;
    }
    if (sd_read_sector(exf_cluster_base(mt.cl) + mt.sic, mt.buf))
        return -1;

    avail = (mt.left < 512u) ? mt.left : 512u;
    skip  = mt.first ? mt.f_off : 0u;
    mt.first = 0u;
    mt.left -= avail;
    mt.pos   = skip;
    mt.end   = avail;

    if (++mt.sic >= exf_spc()) {
        mt.sic = 0u;
        mt.cl  = mt.nofat ? (mt.cl + 1u) : exf_fat_next(mt.cl);
        if (mt.cl < 2u)
            return -2;
    }
    return 0;
}

/* Push one packed word from the buffer; 0 = nothing left in this sector.
 *
 * The board has a single PWM output, so everything is reduced to one mono
 * 16-bit stream first (stereo is folded to (L+R)/2) and then two consecutive
 * samples are packed into one FIFO word -- the DAC pops the low half and then
 * the high half, one per sample tick.  Packing two *consecutive* samples is
 * what makes the playback run at the WAV's own sample rate; duplicating a
 * sample (or pairing L with R) would play the file at half speed.
 */
static int music_word(void)
{
    int32_t s;

    if (mt.bits == 16u) {
        if (mt.ch == 2u) {
            if (mt.pos + 4u > mt.end)
                return 0;
            /* Left channel only.  Summing L+R was tried first, but a mix can
             * put the two channels out of phase -- then (L+R)/2 cancels the
             * very content it is supposed to keep and the song comes out thin
             * and unrecognisable.  Taking one channel cannot cancel. */
            s = (int32_t)(int16_t)(mt.buf[mt.pos] |
                                   ((uint32_t)mt.buf[mt.pos + 1u] << 8));
            mt.pos += 4u;
        } else {
            if (mt.pos + 2u > mt.end)
                return 0;
            s = (int32_t)(int16_t)(mt.buf[mt.pos] |
                                   ((uint32_t)mt.buf[mt.pos + 1u] << 8));
            mt.pos += 2u;
        }
    } else {
        if (mt.ch == 2u) {
            if (mt.pos + 2u > mt.end)
                return 0;
            s = ((((int32_t)mt.buf[mt.pos] - 128) +
                  ((int32_t)mt.buf[mt.pos + 1u] - 128)) / 2) << 8;
            mt.pos += 2u;
        } else {
            if (mt.pos + 1u > mt.end)
                return 0;
            s = ((int32_t)mt.buf[mt.pos] - 128) << 8;
            mt.pos += 1u;
        }
    }

    if (!mt.pend) {
        mt.pendv = (uint16_t)(int16_t)s;
        mt.pend  = 1u;
        return 1;
    }
    au_push((uint32_t)mt.pendv | ((uint32_t)(uint16_t)(int16_t)s << 16));
    mt.pend = 0u;
    return 1;
}

static void music_service(void)
{
    if (!mt.on)
        return;

    while (au_level() < (AU_FIFO_WORDS - 64u)) {
        if (mt.pos >= mt.end) {
            if (music_fetch()) {               /* read error / bad chain */
                music_stop();
                return;
            }
            continue;
        }
        if (!music_word())                     /* sector tail too short  */
            mt.pos = mt.end;
    }
}

static int music_start_ex(const bmp_entry_t *f, uint8_t once)
{
    uint32_t off = 0u, len = 0u, rate = 0u, ch = 0u, bits = 0u;

    if (sd_read_sector(exf_cluster_base(f->first_cluster), hdr))
        return -1;
    if (!wav_header(hdr, &off, &len, &ch, &bits, &rate))
        return -2;
    if (bits != 16u && bits != 8u)
        return -3;
    if (ch != 1u && ch != 2u)
        return -4;
    if (len + off > f->size)                   /* chunk lies past EOF      */
        len = (f->size > off) ? (f->size - off) : 0u;
    if (len < 4u)
        return -2;

    mt.nofat = f->nofat;
    mt.ch    = ch;
    mt.bits  = bits;
    mt.f_cl  = f->first_cluster;
    mt.f_off = off;
    mt.total = len;
    mt.cl    = mt.f_cl;
    mt.sic   = 0u;
    mt.left  = mt.total;
    mt.first = 1u;
    mt.pos   = 0u;
    mt.end   = 0u;
    mt.pend  = 0u;

    au_set_rate_hz(rate);
    au_flush();
    au_enable(1u);
    mt.on     = 1u;
    mt_once   = once;
    music_on  = 1u;
    /* Keep what we parsed: the 7-segment display shows these three values in
     * music mode, so a wrong header can be seen without the UART. */
    mt_rate   = rate;
    mt_ch     = ch;
    mt_bits   = bits;
    music_service();                           /* prime the FIFO         */
    return 0;
}

/* Looping playback (a song): KEY7 and the boot path use this one. */
static int music_start(const bmp_entry_t *f)
{
    return music_start_ex(f, 0u);
}

/* Show a value for `ms` milliseconds *while keeping the audio FIFO fed*.
 *
 * Every handler used to block in delay_ms() for up to 5.6s (KEY1's mic
 * diagnostics).  Nothing feeds the player during a plain delay and the FIFO
 * only holds 23ms, so the music went silent for the whole hold -- which is
 * exactly the "KEY1 breaks playback" report.  Hold through this instead. */
static void show_hold(uint32_t val, uint32_t ms)
{
    uint32_t t;

    au_disp(val, 1u);
    for (t = 0; t < ms; t++) {
        if (music_on)
            music_service();
        delay_ms(1u);
    }
}

/* KEY7 (silk) = key bit 7 = music on/off.  Called from every 1ms tick. */
static void key_poll(void)
{
    uint32_t v  = AU_KEY;                /* reading also clears the events */
    uint32_t ev = AU_KEY_EV(v);
    uint32_t dn = AU_KEY_DOWN(v);

    /* Live pressed-level display, independent of the event path: while a key is
     * held the display shows the raw 16-bit matrix mask, so the mapping can be
     * read off directly instead of guessed from which handler fired. */
    if (dn)
        au_disp(dn, 1u);

    if (!ev)
        return;

    /* Bring-up echo: show exactly which key bits arrived, then leave it on the
     * display (sticky) -- an auto-clearing echo was invisible in music mode,
     * where the loop's own diagnostic display kept overwriting it, which is
     * exactly why "pressing KEY3 does nothing" was reported.  Bit 7 = silk
     * KEY7, so a press of it reads 0080 here. */
    au_disp(ev, 1u);
    show_hold(ev, 150u);

    /* KEY1 = switch the spectrum bars between the SD player and the on board
     * microphone ADC (SPI, 100kSPS).  F401 = microphone, F400 = SD player.
     * Purely a display source: the microphone is never mixed into the speaker,
     * so holding it next to the speaker cannot howl. */
    if (ev & (1u << 0)) {
        raw_disp ^= 1u;
        if (!raw_disp)
            au_disp(0u, 0u);             /* back to the preset display */
        else
            show_hold(AU_MICDATA & 0xFFFFu, 150u);
    }

    /* KEY1 = switch the spectrum bars between the SD player and the on board
     * microphone ADC.  F401 = microphone, F400 = SD player.  The long
     * peak/trough playback used during bring-up is gone: it blocked the audio
     * for seconds.  Use KEY2 if the raw ADC numbers are needed again. */
    if (ev & (1u << 1)) {
        mic_on ^= 1u;
        au_mic_mode(mic_on);
        show_hold(0xF400u | mic_on, 250u);
    }

    /* KEY2 = cycle the music diagnostics on the display: sample rate, format,
     * FIFO level, starvations/s.  On demand instead of automatically, so the
     * key feedback above stays readable. */
    if (ev & (1u << 2)) {
        srv_ph = (srv_ph + 1u) & 3u;
        if (srv_ph == 0u)
            au_disp(mt_rate, 1u);                    /* expect AC44 = 44100 */
        else if (srv_ph == 1u)
            au_disp((mt_ch << 8) | mt_bits, 1u);     /* expect 0210 = 2ch/16 */
        else if (srv_ph == 2u)
            au_disp(au_level(), 1u);                 /* expect ~1C0 words */
        else
            au_disp(0xA000u | (au_under_1s() & 0x0FFFu), 1u); /* A0xx = starve/s */
    }

    /* KEY9 = P7 character pack: switch to the next pack found on the card
     * (two packs max) and play its voice once.  With a single pack it just
     * replays the voice.  The rescan itself happens in main(), because this
     * routine runs inside delay_ms() and must stay short. */
    if (ev & (1u << 9)) {
        if (music_on)
            music_stop();
        if (nchar > 1) {
            cur_char = (cur_char + 1) % nchar;
            reload = 1u;
            voice_req = 1u;
            show_hold(0x0C00u | (uint32_t)(cur_char + 1), 200u);
        } else {
            voice_req = 1u;
            show_hold(0x0C10u | (uint32_t)nchar, 200u);
        }
    }

    /* KEY6 = when the hardware tone is on, step its pitch through 500Hz,
     * 1k, 2k, 4k, 8k -- recording those five lets the analogue chain's real
     * frequency response be measured (a muffled top end is very audible on
     * music but invisible on a single 1kHz tone).  With the tone off it still
     * flips the output stage A/B: 195kHz noise shaped PWM vs the 50MHz 1-bit
     * sigma-delta (F001 = PWM, F000 = sigma-delta). */
    if (ev & (1u << 6)) {
        if (tone_on) {
            static const uint32_t tone_hz[5] = { 500u, 1000u, 2000u, 4000u, 8000u };
            tone_idx = (tone_idx + 1u) % 5u;
            au_tone_hz(tone_hz[tone_idx]);
            au_disp(0xF100u | tone_idx, 1u);
        } else {
            out_pwm ^= 1u;
            au_set_mode(out_pwm);
            show_hold(0xF000u | out_pwm, 400u);
        }
    }

    /* KEY4 = high shelf presets: 0 / +6 / +12 / +18 dB above ~880Hz (F200..F203).
     * The board's analogue low-pass costs about -10dB at 2kHz, -19dB at 4kHz
     * and -37dB at 8kHz, so music sounds muffled; the FPGA pre-emphasis puts
     * the top end back.  Pick the biggest value that still sounds clean.
     * Bit 3 is accepted as an alias: row 0 of the matrix (KEY3..KEY0) did not
     * produce any event at all on this board, so the primary key is KEY4. */
    if (ev & ((1u << 4) | (1u << 3))) {
        sh_sel = (sh_sel + 1u) % 4u;
        au_shelf(sh_tab[sh_sel]);
        au_disp(0xF200u | sh_sel, 1u);   /* stays until the next key press */
    }

    /* KEY8 = master gain 0dB / -6dB / -12dB (F300/F301/F302).  If the music
     * cleans up when attenuated, the analogue stage is clipping.  Bit 8 sits
     * in matrix row 2, the same row as the filter keys KEY11/KEY10, which are
     * known to work. */
    if (ev & (1u << 8)) {
        static const uint32_t vol_tab[3] = { 256u, 128u, 64u };
        vol_sel = (vol_sel + 1u) % 3u;
        au_set_vol(vol_tab[vol_sel]);
        au_disp(0xF300u | vol_sel, 1u);
    }

    /* KEY5 = 1kHz test tone (no SD involved, generated in the FPGA itself
     * after the FIFO), for recording the DAC/amp chain on its own.
     * F005 = on, F0FF = off. */
    if (ev & (1u << 5)) {
        tone_on ^= 1u;
        if (tone_on) {
            if (music_on)
                music_stop();
            au_shelf(256u);              /* flat EQ while measuring the chain */
            au_tone_hz(1000u);           /* start every test at 1kHz */
            tone_idx = 1u;
            au_tone_hw(16000u, 1u);
            show_hold(0xF005u, 400u);
        } else {
            au_tone_hw(0u, 0u);
            au_shelf(sh_tab[sh_sel]);    /* restore the chosen EQ */
            show_hold(0xF0FFu, 400u);
        }
    }

    /* KEY7 = music on/off.  Must answer instantly: this used to print nwav and
     * block for 800ms before doing anything, which felt like a dead key and
     * made the user press it repeatedly.  F701 = playing, F700 = stopped,
     * E00E = no WAV on the card, E0nn = start error. */
    if (ev & (1u << 7)) {
        if (music_on) {
            music_stop();
            au_disp(0xF700u, 1u);
        } else if (nwav == 0) {
            au_disp(0xE00Eu, 1u);
        } else {
            int r = music_start(&wavs[0]);

            au_disp(r ? (0xE000u | (uint32_t)(-r)) : 0xF701u, 1u);
            if (r)
                remount = 1u;    /* stale list after a card swap: re-read it */
        }
    }
}


/* char.ini is a tiny key=value text file; only "dwell=<seconds>" is used.
 * Parsed straight out of the first sector, no file system needed. */
static void ini_dwell(const uint8_t *b, uint32_t len)
{
    uint32_t i;

    for (i = 0; (i + 6u) <= len; i++) {
        uint32_t v = 0u;
        uint32_t j;

        if ((b[i] | 0x20) != 'd' || (b[i + 1] | 0x20) != 'w' ||
            (b[i + 2] | 0x20) != 'e' || (b[i + 3] | 0x20) != 'l' ||
            (b[i + 4] | 0x20) != 'l' || b[i + 5] != '=')
            continue;
        j = i + 6u;
        while (j < len && b[j] >= '0' && b[j] <= '9') {
            v = v * 10u + (uint32_t)(b[j] - '0');
            j++;
        }
        if (v >= 1u && v <= 60u)
            dwell_sec = v;
        return;
    }
}

static void add_char(uint32_t cl)
{
    if (nchar < 2)
        chardirs[nchar++] = cl;
}

/* Fill chardirs[] with the character packs found on the card.  A directory is
 * a pack when it holds at least one *.bmp.  Both layouts are accepted:
 *     <root>/<character>/...            (one level)
 *     <root>/CHARS/<character>/...      (two levels, as in the plan)
 * A flat card yields nchar == 0 and everything falls back to the old
 * root-directory behaviour, so existing cards keep working. */
static void find_char_dirs(void)
{
    uint32_t n1, n2, i, j;

    nchar = 0;
    exf_set_ext("bmp");
    n1 = (uint32_t)exf_scan_dirs_from(exf_root_cl(), files, 4);
    for (i = 0; i < n1; i++)
        if (exf_scan_from(files[i].first_cluster, wavs, 1) > 0)
            add_char(files[i].first_cluster);
    if (nchar == 0) {
        for (i = 0; i < n1; i++) {
            n2 = (uint32_t)exf_scan_dirs_from(files[i].first_cluster, wavs, 4);
            for (j = 0; j < n2; j++) {
                uint32_t c = wavs[j].first_cluster;
                if (exf_scan_from(c, wavs + 6, 1) > 0)
                    add_char(c);
            }
        }
    }
    exf_set_ext("bmp");
}

/* Load one character pack (or the card root when there is no pack).
 *
 * The music library deliberately stays in the card root: KEY7 still plays
 * root/*.wav, while the pack only contributes its pictures, its char.ini and
 * a one-shot voice.wav for KEY9. */
static void scan_char(int ci)
{
    uint32_t base = (ci >= 0 && ci < nchar) ? chardirs[ci] : exf_root_cl();

    has_voice = 0u;
    if (base != exf_root_cl()) {
        exf_set_ext("ini");
        if (exf_scan_from(base, &voice_ent, 1) > 0 &&
            !sd_read_sector(exf_cluster_base(voice_ent.first_cluster), hdr))
            ini_dwell(hdr, (voice_ent.size > 512u) ? 512u : voice_ent.size);

        exf_set_ext("wav");
        if (exf_scan_from(base, &voice_ent, 1) > 0)
            has_voice = 1u;
    }

    exf_set_ext("bmp");
    nfiles = exf_scan_from(base, files, EXF_MAX_FILES);

    exf_set_ext("wav");
    nwav = exf_scan_from(exf_root_cl(), wavs,
                         (int)(sizeof(wavs) / sizeof(wavs[0])));
}


int main(void)
{
    uint32_t dbg[5];
    uint32_t d3[3];

    int      i, r;

    dbg_mark(0);                         /* reached main()                 */
    uart_init(UART_BAUD_115200);
    dbg_mark(1);                         /* uart_init done                 */
    uart_puts("\r\nP2 BMP slideshow online\r\n");
    dbg_mark(2);                         /* banner printed                 */

    uart_puts("waiting SD init...");
    dbg_mark(3);                         /* entered SD wait loop           */
    while (!(SD_STATUS & STS_INIT_DONE)) {
        DBG_REG ^= (1u << 7);            /* heartbeat while polling        */
    }
    uart_puts("done\r\n");
    dbg_mark(4);                         /* SD card init observed done     */

    /* raw LBA0 forensics: the MBR signature lives at [510]/[511] and exFAT
     * puts "EXFAT " at [3..10] of the PBR -- a rotated sector shows up here */
    if (sd_read_sector(0u, hdr) == 0) {
        uart_puts("lba0[0..7]=");
        uart_dump(hdr, 8);
        uart_puts(" sig=");
        uart_dump(&hdr[510], 2);
        uart_puts("\r\n");
    } else {
        uart_puts("lba0 raw read timeout\r\n");
    }

    r = exf_mount();
    if (r) {
        uart_puts("mount failed, step ");
        uart_putdec((uint32_t)r);
        uart_puts("\r\n");
        fail_show((uint32_t)r);          /* never returns                  */
    }
    dbg_mark(5);                         /* exFAT mounted                  */

    /*---------------------------------------------------------------------
     * P6 audio bring-up.
     *
     * v25 proved the audio clock is exact: the hardware-measured value came
     * back as AABB.. which read B3CA on the 7-segment because the digit order
     * was reversed (0xAC3B = 44091 = 50MHz/1134).  Order is fixed now, so the
     * first thing shown after reset is 1234 -- if it reads 4321 the fix did
     * not take.
     *-------------------------------------------------------------------*/
    au_init(1134u, 256u);                /* 44.09kHz, unity volume         */
    au_mic_mode(0u);                     /* bars follow the SD player      */
    au_disp(0x1234u, 1u);                /* digit order check              */
    delay_ms(1200u);
    au_disp(0u, 0u);

    /* P7: look for character packs first.  nchar == 0 means the card uses the
     * old flat layout and scan_char(0) scans the root directory instead. */
    find_char_dirs();
    if (nchar > 0) {
        au_disp(0x0C00u | (uint32_t)nchar, 1u);   /* C1/C2 = packs found   */
        delay_ms(900u);
        au_disp(0u, 0u);
    }
    cur_char = 0;
    scan_char(cur_char);
    if (nwav > 0) {
        au_disp((uint32_t)nwav, 1u);     /* how many WAV files were found  */
        delay_ms(1200u);
        au_disp(0u, 0u);
    }

    exf_debug(dbg);
    uart_puts("pbr=");
    uart_puthex(dbg[0]);
    uart_puts(" fat=");
    uart_puthex(dbg[1]);
    uart_puts(" heap=");
    uart_puthex(dbg[2]);
    uart_puts(" spc=");
    uart_putdec(dbg[3]);
    uart_puts(" root=");
    uart_puthex(dbg[4]);
    uart_puts("\r\n");

    uart_puts("bmp files: ");
    uart_putdec((uint32_t)nfiles);
    uart_puts("\r\n");
    for (i = 0; i < nfiles; i++) {
        uart_puts("  [");
        uart_putdec((uint32_t)i);
        uart_puts("] ");
        uart_puts(files[i].name);
        uart_puts(" size=");
        uart_putdec(files[i].size);
        uart_puts(files[i].nofat ? " contig\r\n" : " fat-chain\r\n");
    }
    if (nfiles == 0) {
        if (nwav > 0) {                  /* no pictures: play music instead */
            music_start(&wavs[0]);
            for (;;) {
                music_service();
                delay_ms(2u);
            }
        }
        uart_puts("no BMP on card, halt\r\n");
        exf_scan_dbg(d3);
        /* 6 = root sector read error, 7 = no File entry at all,
         * 8 = File entries present but none passed the filters */
        fail_show(d3[0] ? 6u : (d3[1] ? 8u : 7u));
    }

    cur_idx = 0;
    for (;;) {
        /* SD card swapped while powered: re-read the file system, the packs and
         * the music list.  Triggered by repeated read failures; the card FSM
         * has already re-initialised itself in hardware by now. */
        if (remount) {
            remount = 0u;
            fail_cnt = 0u;
            if (exf_mount() == 0) {
                find_char_dirs();
                if (cur_char >= nchar)
                    cur_char = 0;
                scan_char(cur_char);
                cur_idx = 0;
                au_disp(0x0C00u | (uint32_t)(cur_char + 1), 1u);
            }
        }
        /* P7: KEY9 asked for another character pack -- rescan and restart. */
        if (reload) {
            reload = 0u;
            scan_char(cur_char);
            cur_idx = 0;
            au_disp(0x0C00u | (uint32_t)(cur_char + 1), 1u);
        }
        if (voice_req) {
            voice_req = 0u;
            if (has_voice)
                music_start_ex(&voice_ent, 1u);   /* one-shot, then back   */
        }
        /* KEY5 tone mode: the 1kHz sine comes from the FPGA itself (0x24), so
         * nothing here has to feed the FIFO -- we only keep the slideshow and
         * the SD card quiet so the recording contains the tone alone. */
        while (tone_on) {
            delay_ms(4u);
        }
        /* music mode: the wallpaper stays on screen, the slideshow idles.
         *
         * The feed loop used to end every pass in delay_ms(2), i.e. it only
         * topped the FIFO up a few hundred times a second while the 50MHz
         * player eats 22050 words/s (one word every 2.3ms of audio).  Any pass
         * that took longer than the ~23ms the 512-word FIFO holds -- a slow SD
         * sector, a cluster cross, a key poll -- drained it to empty, and the
         * DAC then repeats the previous sample: that is the crackle.  So the
         * loop now spins on the FIFO level itself (one AHB read per pass, no
         * timers), refilling the moment it drops, and only polls the keypad and
         * the display every few thousand passes (~1ms of real time). */
        if (music_on) {
            music_service();
            key_poll();
            srv_div = 0u;
            continue;
        }
        if (srv_div) {                   /* fresh slideshow: back to preset */
            srv_div = 0u;
            au_disp(0u, 0u);
        }
        for (i = 0; i < nfiles; i++) {
            if (music_on)
                break;
            if (reload)                  /* character changed: restart   */
                break;
            cur_idx = i;
            uart_puts("play [");
            uart_putdec((uint32_t)i);
            uart_puts("] ");
            uart_puts(files[i].name);
            uart_puts("\r\n");
            /* swap write buffer for every frame after the first */
            if (frame_no)
                SD_CTRL = CT_BUF_TOGGLE;
            r = play_frame(&files[i]);
            if (r) {
                /* undo the buffer swap: next frame must not clobber the
                 * buffer the display is currently reading */
                if (frame_no)
                    SD_CTRL = CT_BUF_TOGGLE;
                uart_puts("  skip, err ");
                uart_putdec((uint32_t)(-r));
                uart_puts("\r\n");
                /* bands: 7 (bit6) + band(-r) => play_frame error code */
                flash_n((uint32_t)(-r));   /* 1..8 blinks = err code */
                /* The card may have been pulled or swapped while powered
                 * (there is no card-detect pin).  Three failures in a row =
                 * re-mount and rescan the packs; the SD FSM re-inits itself
                 * in hardware after ~20ms of a stuck transfer. */
                if (++fail_cnt >= 3u) {
                    fail_cnt = 0u;
                    remount = 1u;
                }
                continue;
            }
            if (frame_no == 0u)
                uart_puts("first frame committed, display switched\r\n");
            frame_no++;
            dbg_mark(6);                 /* a frame played OK              */
            delay_ms(dwell_sec * 1000u);
        }
    }
}

/* keep IRQ vector satisfied (polling firmware, same as P1) */
void uart0_irq_handler(void)
{
    (void)UART_DATA;
}
