"""Segment a phone recording of the P2 audio test and characterise every part.

For every 0.5 s window it reports level, dominant frequency, the fraction of
energy that belongs to the harmonic series of that dominant, and the energy
above 8 kHz.  A clean 1 kHz tone shows up as a flat plateau of windows with
f0 ~= 1000 Hz and a high harmonic fraction; crackle shows up as a low
harmonic fraction (broadband) and/or a wandering f0.
"""
import sys
import wave
import numpy as np

SR = 44100.0
WIN = int(SR * 0.5)


def load(path):
    with wave.open(path, 'rb') as w:
        n = w.getnframes()
        d = np.frombuffer(w.readframes(n), np.int16).astype(np.float64) / 32768.0
    return d


def analyse(d):
    rows = []
    for i in range(0, len(d) - WIN, WIN):
        seg = d[i:i + WIN]
        seg = seg - seg.mean()
        rms = float(np.sqrt((seg ** 2).mean()))
        w = seg * np.hanning(WIN)
        sp = np.abs(np.fft.rfft(w))
        f = np.fft.rfftfreq(WIN, 1.0 / SR)
        # dominant peak between 60 Hz and 8 kHz
        band = (f > 60) & (f < 8000)
        k = np.argmax(sp * band)
        f0 = f[k]
        p = sp ** 2
        tot = p[band].sum() + 1e-20
        # energy in harmonics 1..12 of f0 (within +-15 Hz)
        harm = 0.0
        for h in range(1, 13):
            fh = f0 * h
            if fh > 20000:
                break
            m = np.abs(f - fh) < 15
            harm += p[m].sum()
        hf = 1e-20 + p[f > 8000].sum()
        rows.append((i / SR, rms, f0, harm / tot, hf / tot))
    return rows


def main():
    d = load(sys.argv[1])
    print('samples=%d  dur=%.2fs' % (len(d), len(d) / SR))
    print(' t(s)    rms    f0(Hz)  harm%   >8k%')
    for t, rms, f0, h, hf in analyse(d):
        if rms < 1e-4:
            tag = '   silence'
        elif h > 0.5:
            tag = '   TONE'
        else:
            tag = '   noisy/music'
        print('%6.2f %7.4f %8.1f %6.1f %6.2f   %s' %
              (t, rms, f0, 100 * h, 100 * hf, tag))


main()
