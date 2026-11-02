import numpy as np, wave, subprocess
FF = r"C:\Users\lihan\AppData\Local\Programs\xiezuo\resources\ffmpeg\ffmpeg.exe"
def mono(p, secs, fs=44100):
    out = p + ".lt.wav"
    subprocess.run([FF,'-y','-hide_banner','-loglevel','error','-i',p,'-ac','1','-ar',str(fs),
                    '-sample_fmt','s16',out], check=True)
    w = wave.open(out,'rb'); n = min(w.getnframes(), int(secs*fs))
    return np.frombuffer(w.readframes(n), np.int16).astype(np.float32)/32768.0, fs
bands = [63,125,250,500,1000,2000,4000,8000,16000]
def lts(x, fs):
    n = 4096; acc = np.zeros(n//2+1); c=0
    for p in range(0, len(x)-n, n):
        acc += np.abs(np.fft.rfft(x[p:p+n]*np.hanning(n)))**2; c+=1
    acc /= max(c,1)
    f = np.fft.rfftfreq(n, 1.0/fs)
    out=[]
    for i in range(len(bands)-1):
        m = (f>=bands[i]) & (f<bands[i+1])
        out.append(10*np.log10(acc[m].sum()+1e-20))
    return np.array(out)
rec,fs = mono(r"录音机-20261101-1806.m4a", 20.0)
song,_ = mono(r"F:\Untitled world.wav", 20.0)
a = lts(rec, fs); b = lts(song, fs)
a -= a.max(); b -= b.max()
print("band(Hz)   FPGA   WAV    diff")
for i,hz in enumerate(bands[:-1]):
    print("%7d  %6.1f %6.1f  %+6.1f" % (hz, a[i], b[i], a[i]-b[i]))
