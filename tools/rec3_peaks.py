"""Print the strongest spectral lines of selected slices of a recording."""
import sys
import wave
import numpy as np

SR = 44100.0


def load(path):
    with wave.open(path, 'rb') as w:
        n = w.getnframes()
        d = np.frombuffer(w.readframes(n), np.int16).astype(np.float64) / 32768.0
    return d


def peaks(seg, n=14):
    seg = seg - seg.mean()
    w = seg * np.hanning(len(seg))
    sp = np.abs(np.fft.rfft(w)) / len(seg)
    f = np.fft.rfftfreq(len(seg), 1.0 / SR)
    # local maxima only
    idx = [i for i in range(2, len(sp) - 2)
           if sp[i] > sp[i - 1] and sp[i] > sp[i + 1] and f[i] > 40]
    idx.sort(key=lambda i: -sp[i])
    out = []
    used = []
    for i in idx:
        if any(abs(f[i] - u) < 25 for u in used):
            continue
        used.append(f[i])
        db = 20 * np.log10(max(sp[i], 1e-9))
        out.append((f[i], db))
        if len(out) >= n:
            break
    return out, float(np.sqrt((seg ** 2).mean()))


def main():
    d = load(sys.argv[1])
    for tstr in sys.argv[2:]:
        t0 = float(tstr)
        a = int(t0 * SR)
        seg = d[a:a + int(0.5 * SR)]
        if len(seg) < 1000:
            continue
        pk, rms = peaks(seg)
        print('--- t=%.1fs  rms=%.4f (%.1f dBFS)' % (t0, rms, 20 * np.log10(max(rms, 1e-9))))
        for fr, db in pk:
            print('    %8.1f Hz  %7.1f dB' % (fr, db))


main()
