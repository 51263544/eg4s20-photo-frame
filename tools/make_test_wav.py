"""Generate a 16-bit PCM WAV test track for the P6 audio path.

The FPGA plays whatever WAV it finds on the card, so this is a known-good
reference: a simple arpeggio with a soft attack, 44.1 kHz stereo, ~24 s.

    python make_test_wav.py [outdir]
"""
import math
import os
import struct
import sys
import wave

SR = 44100
NOTES = {                       # Hz
    "C4": 261.63, "D4": 293.66, "E4": 329.63, "F4": 349.23,
    "G4": 392.00, "A4": 440.00, "B4": 493.88, "C5": 523.25,
    "D5": 587.33, "E5": 659.25, "G5": 783.99, "A5": 880.00,
}

MELODY = [
    ("C4", 0.30), ("E4", 0.30), ("G4", 0.30), ("C5", 0.60),
    ("G4", 0.30), ("E4", 0.30), ("G5", 0.45), ("E5", 0.45),
    ("D4", 0.30), ("F4", 0.30), ("A5", 0.30), ("D5", 0.60),
    ("A4", 0.30), ("F4", 0.30), ("D5", 0.45), ("C5", 0.45),
    ("B4", 0.30), ("D5", 0.30), ("G5", 0.60), ("B4", 0.30),
    ("G4", 0.30), ("B4", 0.30), ("E5", 0.60),
    ("C5", 0.45), ("A4", 0.45), ("C4", 0.90),
]


def tone(freq, dur, amp=0.30):
    """Sine with a soft 15 ms attack and release so the notes do not click."""
    n = int(SR * dur)
    out = [0.0] * n
    env_n = min(int(SR * 0.015), n // 2)
    for i in range(n):
        env = 1.0
        if i < env_n:
            env = i / env_n
        elif i > n - env_n:
            env = (n - i) / env_n
        out[i] = amp * env * math.sin(2 * math.pi * freq * i / SR)
    return out


def build():
    mono = []
    for name, dur in MELODY:
        mono += tone(NOTES[name], dur)
    mono += [0.0] * int(SR * 0.4)          # breath before the loop point

    # 12 ms cross-feed on the right channel widens the image a little and
    # makes it obvious which channel is which on a single speaker.
    left = mono
    d = int(SR * 0.012)
    right = [0.0] * len(mono)
    for i, s in enumerate(mono):
        right[i] = 0.72 * s + (0.35 * mono[i - d] if i >= d else 0.0)

    frames = bytearray()
    for i in range(len(left)):
        l = max(-32768, min(32767, int(left[i] * 32767)))
        r = max(-32768, min(32767, int(right[i] * 32767)))
        frames += struct.pack("<hh", l, r)
    return bytes(frames)


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(outdir, "test_music.wav")
    data = build()
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data)
    print("%s  %d bytes  %.2f s  %d frames" % (path, os.path.getsize(path),
                                               len(data) / 4 / SR, len(data) // 4))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
