/*------------------------------------------------------------------------------
 * audio.h -- P6 audio output stage driver (AHB slave P4 @ 0x4003_0000)
 *
 * The FPGA side (rtl: p2/audio_ctrl.v) is a 512 x 32 async FIFO feeding a
 * first-order sigma-delta modulator on the raw 50MHz board clock.  The board
 * low-passes AUDIO_PWM (pin F3) and drives the speaker amplifier.
 *
 * Sample format: two signed 16-bit PCM samples packed in one 32-bit word,
 * LOW half = first sample, HIGH half = second sample.  So one word = 2/fs
 * of time, i.e. ~45us at 44.1kHz -- the FIFO holds ~23ms of audio.
 *------------------------------------------------------------------------------*/
#ifndef AUDIO_H
#define AUDIO_H

#include <stdint.h>

#define AUDIO_BASE   0x40030000UL

#define AU_DATA      (*(volatile uint32_t *)(AUDIO_BASE + 0x00u))
#define AU_CTRL      (*(volatile uint32_t *)(AUDIO_BASE + 0x04u))
#define AU_STATUS    (*(volatile uint32_t *)(AUDIO_BASE + 0x08u))
#define AU_RATE      (*(volatile uint32_t *)(AUDIO_BASE + 0x0Cu))
#define AU_VOL       (*(volatile uint32_t *)(AUDIO_BASE + 0x10u))
#define AU_TICK      (*(volatile uint32_t *)(AUDIO_BASE + 0x14u))
#define AU_DISP      (*(volatile uint32_t *)(AUDIO_BASE + 0x18u))
#define AU_MEAS      (*(volatile uint32_t *)(AUDIO_BASE + 0x1Cu)) /* samples/s */
#define AU_KEY       (*(volatile uint32_t *)(AUDIO_BASE + 0x20u)) /* key queue */
#define AU_TONE      (*(volatile uint32_t *)(AUDIO_BASE + 0x24u)) /* hw tone   */
#define AU_UNDER     (*(volatile uint32_t *)(AUDIO_BASE + 0x28u)) /* starv./s  */
#define AU_DROP      (*(volatile uint32_t *)(AUDIO_BASE + 0x2Cu)) /* lost/s    */
#define AU_TSTEP     (*(volatile uint32_t *)(AUDIO_BASE + 0x30u)) /* tone step */
#define AU_SHELF     (*(volatile uint32_t *)(AUDIO_BASE + 0x34u)) /* HF shelf  */

/* AU_CTRL bits */
#define AU_CTRL_EN      (1u << 0)
#define AU_CTRL_FLUSH   (1u << 1)      /* self clearing                   */
#define AU_CTRL_MUTE    (1u << 2)
#define AU_CTRL_PWM     (1u << 7)      /* 1 = 195kHz PWM, 0 = 50MHz sigma-delta */

/* AU_STATUS bits ([8:0] = FIFO words queued) */
#define AU_ST_USED(s)   ((s) & 0x1FFu)
#define AU_ST_EN        (1u << 9)
#define AU_ST_MUTE      (1u << 10)
#define AU_ST_EMPTY     (1u << 11)
#define AU_ST_FULL      (1u << 12)
#define AU_ST_AFULL     (1u << 13)
#define AU_ST_MEAS      (1u << 14)     /* toggles once per 1s measurement window */

#define AU_FIFO_WORDS   512u

/* AU_KEY layout -- reading the register clears the event half */
#define AU_KEY_EV(s)    ((s) & 0xFFFFu)     /* 1 bit per key pressed since   */
#define AU_KEY_DOWN(s)  (((s) >> 16) & 0xFFFFu) /* debounced pressed level   */

void     au_init(uint32_t rate_div, uint32_t vol_q8);
void     au_enable(uint32_t on);
void     au_set_mode(uint32_t pwm);         /* 1 = 195kHz PWM, 0 = sigma-delta */
void     au_set_vol(uint32_t q8);           /* master gain, 256 = unity        */
void     au_flush(void);
void     au_push(uint32_t word);            /* two packed 16-bit samples   */
void     au_play(int16_t l, int16_t r);     /* push one L/R sample pair    */
uint32_t au_level(void);                    /* words queued                */
uint32_t au_tick(void);                     /* free running sample counter */
uint32_t au_measure(void);                  /* samples counted in 1s (hw)  */
void     au_disp(uint32_t value, uint32_t on); /* 4 hex digits on 7-segment */
uint32_t au_key_take(void);                 /* pending key events, clears  */
uint32_t au_under_1s(void);                 /* FIFO starvations in last 1s */
uint32_t au_drop_1s(void);                  /* sample words lost in last 1s*/

/* 440Hz test tone, called in a loop to keep the FIFO fed (no SD needed).   */
void     au_tone_seed(void);

/* Top the FIFO up with the test tone; returns how many words it pushed.    */
uint32_t au_tone_service(void);

/* Hardware test tone (0x24): a 1kHz sine generated in the FPGA, after the
 * FIFO.  amp is 0..32767, on = 1 enables it.  Bypasses SD, firmware and the
 * async FIFO completely, so it isolates the modulator/analogue chain.      */
void     au_tone_hw(uint32_t amp, uint32_t on);

/* Set the hardware tone frequency (0x30 phase step, 16 bit accumulator at
 * 44.0917kHz, so step = hz * 65536 / 44091.7).  Lets the analogue chain be
 * swept 500Hz..8kHz to measure its frequency response.                     */
void     au_tone_hz(uint32_t hz);

/* High shelf gain in Q8 (256 = flat, 512 = +6dB above ~880Hz, 1024 = +12dB).
 * Compensates the board's analogue low-pass so music stops sounding muffled. */
void     au_shelf(uint32_t q8);

/* Restart the test tone phase (every test then starts on sample 0).        */
void     au_tone_reset(void);

/* Program the sample rate from a real sample frequency in Hz.              */
void     au_set_rate_hz(uint32_t hz);

/* +0x38 bit0: 1 = the on screen bars follow the microphone ADC (SPI, 100kSPS)
 * instead of the SD player.  This is only a display source switch - the
 * microphone is never mixed into the speaker, so it cannot feed back.      */
#define AU_MIC      (*(volatile uint32_t *)(AUDIO_BASE + 0x38u))
/* +0x3C read: last raw 16 bit ADC frame, for bring-up inspection.          */
#define AU_MICDATA  (*(volatile uint32_t *)(AUDIO_BASE + 0x3Cu))
/* +0x04 read: microphone bring-up window statistics over the last 1s.
 * [31:16] = peak ADC code, [15:0] = trough ADC code.  peak-trough is the
 * decisive number: a live microphone shows a spread that grows with speech,
 * a dead constant bus shows 0, and pure noise saturates. */
#define AU_MICDBG   (*(volatile uint32_t *)(AUDIO_BASE + 0x04u))
#define AU_MIC_PEAK(v)   (((v) >> 16) & 0xFFFFu)
#define AU_MIC_TRGH(v)   ((v) & 0xFFFFu)
void     au_mic_mode(uint32_t on);

#endif /* AUDIO_H */
