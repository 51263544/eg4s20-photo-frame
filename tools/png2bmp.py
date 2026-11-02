#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
png2bmp.py -- batch-convert images to 640x480 24bit BMP for the EG4S20 P2
SD-card slideshow (SD_CTRL spec D-202).

Usage:
    python png2bmp.py <input_dir> <output_dir> [--bg white|black|#RRGGBB]
                      [--fit contain|cover|panel]

--fit panel (default) is what the 7" 16:9 panel needs: the 640x480 signal is
stretched to 16:9 by the monitor, so the picture must already be 16:9 and must
*fill* the frame.  Wider sources are cropped at the sides, taller ones get the
background colour added at the sides, then everything is resized to 640x480.
contain = keep the whole picture, letterbox in a 4:3 frame (wrong aspect on a
16:9 panel).  cover = fill the 4:3 frame and crop (also wrong aspect there).

- accepts PNG / JPG / JPEG / BMP / GIF / WEBP (anything Pillow opens)
- output: 640x480, 24-bit uncompressed BMP, bottom-up rows (BMP standard),
  no palette -> directly streamable by the M0+hardware chain
- filename kept, extension forced to .bmp; sorted order of input dir is the
  playback order (exFAT directory physical order on copy)

ALPHA IS COMPOSITED, NOT DROPPED
--------------------------------
Character art (Arknights 立绘 etc.) is usually RGBA with a transparent
background.  A plain `im.convert("RGB")` keeps the *stored* RGB values under
alpha=0, which are arbitrary leftovers from the encoder -- on the board they
show up as a ring of saturated colour blocks around the character.
Every fully/partly transparent pixel is therefore alpha-blended onto the
background colour `--bg` (default white) before scaling.
"""
import sys
from pathlib import Path

from PIL import Image

W, H = 640, 480
PANEL_AR = 16.0 / 9.0          # the 7" monitor stretches 640x480 to this

NAMED = {
    "white": (255, 255, 255),
    "black": (0, 0, 0),
    "gray": (128, 128, 128),
    "grey": (128, 128, 128),
}


def parse_color(s: str):
    s = s.strip().lower()
    if s in NAMED:
        return NAMED[s]
    if s.startswith("#") and len(s) == 7:
        return tuple(int(s[i:i + 2], 16) for i in (1, 3, 5))
    raise SystemExit(f"bad --bg value: {s!r} (use white/black/gray/#RRGGBB)")


def load_on_bg(path: Path, bg) -> Image.Image:
    """Open an image and flatten any alpha onto a solid background."""
    im = Image.open(path)
    has_alpha = (im.mode in ("RGBA", "LA", "PA", "P")
                 or "transparency" in im.info)
    if has_alpha:
        im = im.convert("RGBA")
        base = Image.new("RGBA", im.size, bg + (255,))
        im = Image.alpha_composite(base, im)
    return im.convert("RGB")


def to_frame(im: Image.Image, bg, fit: str) -> Image.Image:
    """Scale into 640x480 and centre on a bg-coloured canvas."""
    if fit == "panel":
        # make the picture 16:9 without distorting it, then fill the frame:
        # the monitor turns 640x480 back into 16:9, so pixels end up square.
        w, h = im.size
        if w / h > PANEL_AR:                       # too wide -> cut the sides
            nw = max(1, round(h * PANEL_AR))
            left = (w - nw) // 2
            im = im.crop((left, 0, left + nw, h))
        elif w / h < PANEL_AR:                     # too tall -> pad the sides
            nw = max(w, round(h * PANEL_AR))
            canvas = Image.new("RGB", (nw, h), bg)
            canvas.paste(im, ((nw - w) // 2, 0))
            im = canvas
        return im.resize((W, H), Image.LANCZOS)

    if fit == "cover":
        # fill the frame, crop the overflow
        scale = max(W / im.width, H / im.height)
        nw, nh = max(W, round(im.width * scale)), max(H, round(im.height * scale))
        im = im.resize((nw, nh), Image.LANCZOS)
        left, top = (nw - W) // 2, (nh - H) // 2
        im = im.crop((left, top, left + W, top + H))
        return im
    im = im.copy()
    im.thumbnail((W, H), Image.LANCZOS)
    canvas = Image.new("RGB", (W, H), bg)
    canvas.paste(im, ((W - im.width) // 2, (H - im.height) // 2))
    return canvas


def main():
    args = [a for a in sys.argv[1:]]
    bg = (255, 255, 255)
    fit = "panel"
    pos = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--bg" and i + 1 < len(args):
            bg = parse_color(args[i + 1]); i += 2; continue
        if a == "--fit" and i + 1 < len(args):
            fit = args[i + 1].lower()
            if fit not in ("contain", "cover", "panel"):
                raise SystemExit("--fit must be contain, cover or panel")
            i += 2; continue
        if a.startswith("--bg="):
            bg = parse_color(a.split("=", 1)[1]); i += 1; continue
        if a.startswith("--fit="):
            fit = a.split("=", 1)[1].lower(); i += 1; continue
        pos.append(a); i += 1

    if len(pos) != 2:
        print(__doc__)
        sys.exit(1)

    src, dst = Path(pos[0]), Path(pos[1])
    dst.mkdir(parents=True, exist_ok=True)

    exts = {".png", ".jpg", ".jpeg", ".bmp", ".gif", ".webp", ".tif", ".tiff"}
    files = sorted(p for p in src.iterdir()
                   if p.is_file() and p.suffix.lower() in exts)
    if not files:
        print(f"no images found in {src}")
        sys.exit(2)

    n = 0
    for p in files:
        try:
            im = to_frame(load_on_bg(p, bg), bg, fit)
        except Exception as e:
            print(f"SKIP {p.name}: {e}")
            continue
        out = dst / (p.stem + ".bmp")
        im.save(out, "BMP")                # Pillow writes 24bit BGR bottom-up
        n += 1
        print(f"{p.name} -> {out.name}")

    print(f"\n{n} BMP written to {dst}")
    print("Copy the .bmp files to the SD card root (exFAT), then power the board.")


if __name__ == "__main__":
    main()
