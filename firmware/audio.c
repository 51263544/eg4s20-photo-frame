/*------------------------------------------------------------------------------
 * audio.c -- P6 audio output stage driver, see audio.h for the register map.
 *
 * Bring-up note: with no speaker attached the only observable is AU_TICK, the
 * free running sample counter in the 50MHz domain.  Reading it twice with a
 * known delay in between proves the audio clock divider and the whole AHB path
 * work (expected 44100/s at RATE = 1134).
 *------------------------------------------------------------------------------*/
#include "audio.h"

/* one full sine cycle, 64 entries, amplitude 12000 (about -8dBFS)            */
static const int16_t sin_tab[64] = {
         0,   1176,   2341,   3483,   4592,   5657,   6667,   7613,
      8485,   9276,   9978,  10583,  11087,  11483,  11769,  11942,
     12000,  11942,  11769,  11483,  11087,  10583,   9978,   9276,
      8485,   7613,   6667,   5657,   4592,   3483,   2341,   1176,
         0,  -1176,  -2341,  -3483,  -4592,  -5657,  -6667,  -7613,
     -8485,  -9276,  -9978, -10583, -11087, -11483, -11769, -11942,
    -12000, -11942, -11769, -11483, -11087, -10583,  -9978,  -9276,
     -8485,  -7613,  -6667,  -5657,  -4592,  -3483,  -2341,  -1176,
};

static uint16_t tone_phase;

/* 1 kHz test tone.  Step is chosen for the 44.09 kHz default sample rate:
 * 1000 * 65536 / 44091.7 = 1486.5 -> 1486 gives 999.9 Hz (0.01% low).      */
#define TONE_STEP   1486u
#define TONE_GAIN   16000    /* -6.2 dBFS: loud enough to be real, low
                              * enough that the analogue chain should not clip */

/* Shadow of AU_CTRL: the register is write-only, and every write has to carry
 * the output-mode bit as well, otherwise a plain enable/disable would silently
 * drop the chip back to the sigma-delta modulator.                          */
static uint32_t ctl_shadow = 0u;      /* 0 = 1-bit sigma-delta: measured ~20dB less noise floor than the 8-bit PWM */

void au_init(uint32_t rate_div, uint32_t vol_q8)
{
    if (rate_div < 16u)   rate_div = 16u;
    if (rate_div > 65535u) rate_div = 65535u;
    if (vol_q8 > 256u)    vol_q8 = 256u;
    ctl_shadow = 0u;                   /* default: 1-bit sigma-delta.  On the
                                        * board the 8-bit 195kHz PWM leaves a
                                        * fixed quantisation floor (~64dB SNR)
                                        * that is still audible with the volume
                                        * turned down, while the 50MHz
                                        * sigma-delta is ~20dB quieter.      */
    AU_CTRL   = ctl_shadow | AU_CTRL_FLUSH;  /* clear stale samples          */
    AU_RATE   = rate_div;
    AU_VOL    = vol_q8;
    AU_DISP   = 0u;                   /* display back to the P5 preset   */
    tone_phase = 0u;
}

void au_enable(uint32_t on)
{
    if (on) ctl_shadow |= AU_CTRL_EN;
    else    ctl_shadow &= ~AU_CTRL_EN;
    AU_CTRL = ctl_shadow;
}

void au_set_mode(uint32_t pwm)
{
    if (pwm) ctl_shadow |= AU_CTRL_PWM;
    else     ctl_shadow &= ~AU_CTRL_PWM;
    AU_CTRL = ctl_shadow;
}

/* Master gain, Q8 (256 = unity).  Also a clipping test: the analogue chain
 * after the PWM low-pass is only 3.3V, so a full scale signal can hit the
 * LMV358 rails.                                                             */
void au_set_vol(uint32_t q8)
{
    if (q8 > 256u) q8 = 256u;
    AU_VOL = q8;
}

void au_flush(void)
{
    /* AU_CTRL is write only -- reading it returns 0, so the old
     * "AU_CTRL = (AU_CTRL & AU_CTRL_EN) | FLUSH" actually *cleared* the
     * enable and the PWM-mode bits every time it ran.  Use the shadow.      */
    AU_CTRL = ctl_shadow | AU_CTRL_FLUSH;
}

void au_push(uint32_t word)
{
    AU_DATA = word;
}

void au_play(int16_t l, int16_t r)
{
    AU_DATA = ((uint32_t)(uint16_t)r << 16) | (uint32_t)(uint16_t)l;
}

uint32_t au_level(void)
{
    return AU_ST_USED(AU_STATUS);
}

uint32_t au_under_1s(void)
{
    return AU_UNDER;
}

uint32_t au_drop_1s(void)
{
    return AU_DROP;
}

uint32_t au_tick(void)
{
    return AU_TICK;
}

void au_disp(uint32_t value, uint32_t on)
{
    AU_DISP = (value & 0xFFFFu) | (on ? (1u << 16) : 0u);
}

/* Wait for a fresh 1s measurement window and return the samples counted in
 * it.  audio_ctrl latches this in the HCLK domain, so it measures the audio
 * divider independently of the firmware delay loop.  Returns whatever is in
 * the register if the window never toggles (guard expires after ~1s).       */
uint32_t au_measure(void)
{
    uint32_t t = AU_STATUS & AU_ST_MEAS;
    uint32_t guard = 0u;

    while (((AU_STATUS & AU_ST_MEAS) == t) && (guard < 5000000u))
        guard++;
    return AU_MEAS;
}

/* Read and clear the keypad event queue: bit n = key[n] pressed (silk KEYn). */
uint32_t au_key_take(void)
{
    static uint32_t seen_lvl;            /* sticky levels already reported */
    uint32_t v     = AU_KEY;             /* the read clears the events     */
    uint32_t ev    = AU_KEY_EV(v);
    uint32_t lvl   = AU_KEY_DOWN(v);
    uint32_t fresh = lvl & ~seen_lvl;

    /* The event bits are the primary source.  The level register is a sticky
     * "pressed at least once since reset" mask, so its rising edges are a
     * second, independent path for a press -- worth keeping because the event
     * queue once came up empty (the clear had been done in the address phase
     * of the read, one cycle before the CPU sampled the data).  Only the
     * first press of a given key can arrive this way; later ones are events. */
    seen_lvl |= lvl;
    return ev | fresh;
}

void au_set_rate_hz(uint32_t hz)
{
    uint32_t div;
    if (hz < 1000u)   hz = 1000u;
    if (hz > 200000u) hz = 200000u;
    div = (50000000u + (hz >> 1)) / hz;
    if (div < 16u)    div = 16u;
    if (div > 65535u) div = 65535u;
    AU_RATE = div;
}

/* Keep the FIFO topped up with the test tone.  Called from every blocking
 * loop (slideshow dwell, per-sector SD waits) so the tone never starves.
 *
 * One FIFO word carries two *consecutive* samples, exactly like the music
 * path -- duplicating a sample here would make the tone play at half speed
 * and would make the measured frequency meaningless.                        */
uint32_t au_tone_service(void)
{
    uint32_t lvl = au_level();
    uint32_t n = 0u;

    while ((lvl < (AU_FIFO_WORDS - 64u)) && (n < 64u)) {
        int16_t s0, s1;
        tone_phase = (uint16_t)(tone_phase + TONE_STEP);
        s0 = (int16_t)(sin_tab[tone_phase >> 10] * TONE_GAIN / 12000);
        tone_phase = (uint16_t)(tone_phase + TONE_STEP);
        s1 = (int16_t)(sin_tab[tone_phase >> 10] * TONE_GAIN / 12000);
        AU_DATA = ((uint32_t)(uint16_t)s0) | ((uint32_t)(uint16_t)s1 << 16);
        lvl++;
        n++;
    }
    return n;
}

/* Hardware tone: 0x24 = {enable in bit16, amplitude in [15:0]}.  The sine is
 * generated inside the FPGA after the FIFO, so this works even when nothing
 * feeds the stream -- that is the whole point of the test.                  */
void au_tone_hw(uint32_t amp, uint32_t on)
{
    if (amp > 32767u)
        amp = 32767u;
    AU_TONE = (amp & 0xFFFFu) | (on ? (1u << 16) : 0u);
}

/* Reset the tone phase so every test starts on the same sample. */
void au_tone_reset(void)
{
    tone_phase = 0u;
}

/* Hardware tone pitch: 16-bit phase accumulator advanced once per sample at
 * 44091.7Hz, so step = hz * 65536 / 44091.7.  Keep the top bit clear so the
 * 64-entry sine table (phase[15:10]) never jumps a whole table row per step. */
void au_tone_hz(uint32_t hz)
{
    uint32_t step = (hz * 65536u + 22045u) / 44092u;
    if (step > 65535u)
        step = 65535u;
    if (step < 1u)
        step = 1u;
    AU_TSTEP = step;
}

/* High shelf gain, Q8: 256 = flat, 512 = +6dB, 1024 = +12dB above ~880Hz. */
void au_shelf(uint32_t q8)
{
    if (q8 > 4095u)
        q8 = 4095u;
    AU_SHELF = q8;
}

/* 440.0 Hz at 44.1 kHz: phase step = 440 * 65536 / 44100 = 654 (0.03% low) */
void au_tone_seed(void)
{
    uint32_t n;
    for (n = 0u; n < (AU_FIFO_WORDS - 8u); n++) {
        int16_t s;
        tone_phase = (uint16_t)(tone_phase + 654u);
        s = sin_tab[tone_phase >> 10];        /* top 6 bits index the table */
        au_play(s, s);
    }
}

/* +0x38 bit0: bars source = microphone ADC (SPI, 100kSPS) instead of the SD
 * player.  Display only; the microphone never reaches the speaker.          */
void au_mic_mode(uint32_t on)
{
    AU_MIC = on ? 1u : 0u;
}