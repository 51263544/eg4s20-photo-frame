import os

import cv2
import numpy as np

VID = r"C:\Users\lihan\Desktop\微信视频2026-10-28_220625_218.mp4"
OUT = r"D:\project\project0\work\jit"
os.makedirs(OUT, exist_ok=True)

cap = cv2.VideoCapture(VID)
fps = cap.get(cv2.CAP_PROP_FPS)
n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
print("video %dx%d fps=%.2f frames=%d dur=%.2fs" % (w, h, fps, n, n / fps if fps else 0))

# --- find the panel rectangle on the first usable frame ---
cap.set(cv2.CAP_PROP_POS_FRAMES, int(n * 0.2))
ok, fr = cap.read()
if not ok:
    raise SystemExit("no frame")
g = cv2.cvtColor(fr, cv2.COLOR_BGR2GRAY)
# brightest large blob = the screen
_, th = cv2.threshold(cv2.GaussianBlur(g, (15, 15), 0), 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
cnts, _ = cv2.findContours(th, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
best = max(cnts, key=cv2.contourArea)
x, y, bw, bh = cv2.boundingRect(best)
print("panel bbox ~ x=%d..%d y=%d..%d (%.0f%%)" % (x, x + bw, y, y + bh, 100.0 * bw * bh / (w * h)))

# --- collect consecutive frames, measure vertical shift between them ---
cap.set(cv2.CAP_PROP_POS_FRAMES, int(n * 0.3))
prev = None
rows = []
k = 0
while k < 90:
    ok, f = cap.read()
    if not ok:
        break
    k += 1
    # central strip, avoids bezel/reflections at the edges
    cx0, cx1 = x + bw // 8, x + bw - bw // 8
    cy0, cy1 = y + bh // 8, y + bh - bh // 8
    g = cv2.cvtColor(f[cy0:cy1, cx0:cx1], cv2.COLOR_BGR2GRAY).astype(np.float32)
    if prev is not None:
        (dx, dy), resp = cv2.phaseCorrelate(prev, g)
        # sub-pixel -> panel rows: scale by panel/screen size
        rows.append((k, dx, dy, resp, float(g.mean())))
    prev = g

cap.release()
a = np.array([(r[1], r[2]) for r in rows])
print("\nframe-to-frame shift (video px): mean=(%.3f, %.3f)  std=(%.3f, %.3f)"
      % (a[:, 0].mean(), a[:, 1].mean(), a[:, 0].std(), a[:, 1].std()))
print("max |dy| = %.3f px   max |dx| = %.3f px" % (np.abs(a[:, 1]).max(), np.abs(a[:, 0]).max()))

# convert to source (640x480) rows: panel height in video px covers 480 rows
rows_per_px = 480.0 / bh
print("1 video px ~= %.2f source rows (panel %.0f px tall)" % (rows_per_px, bh))
dy_src = a[:, 1] * rows_per_px
print("vertical shift in source rows: std=%.2f  max|.|=%.2f" % (dy_src.std(), np.abs(dy_src).max()))

print("\n k    dx      dy    resp   luma")
for (k, dx, dy, resp, lum), s in zip(rows, dy_src):
    flag = " <<<" if abs(s) >= 0.8 else ""
    print("%3d %7.3f %7.3f %6.2f %6.1f  dy_src=%+.2f%s" % (k, dx, dy, resp, lum, s, flag))

np.save(os.path.join(OUT, "shift.npy"), a)
print("\nsaved work\\jit\\shift.npy")
