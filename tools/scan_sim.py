"""Replay the firmware's exFAT root-directory scan byte-for-byte against the
real card, to prove which files the M0 actually discovers."""
import struct

DRV = r"\\.\F:"
SEC = 512
EXF_MAX_FILES = 16

f = open(DRV, "rb")


def read_lba(lba, n=1):
    f.seek(lba * SEC)
    return f.read(SEC * n)


pbr = read_lba(0)
spc = 1 << pbr[0x6D]
fat_off = struct.unpack_from("<I", pbr, 0x50)[0]
heap_off = struct.unpack_from("<I", pbr, 0x58)[0]
root_cl = struct.unpack_from("<I", pbr, 0x60)[0]


def clus_base(c):
    return heap_off + (c - 2) * spc


def rd16(b, o):
    return b[o] | (b[o + 1] << 8)


def rd32(b, o):
    return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)


def fat_next(c):
    o = c * 4
    b = read_lba(fat_off + (o >> 9))
    return rd32(b, o & 511)


def scan_cluster_orig(cl, tab, maxn):
    """faithful port of the current C scan_cluster()"""
    for s in range(spc):
        buf = read_lba(clus_base(cl) + s)
        p = 0
        while p < 512:
            t = buf[p]
            if t in (0x00, 0xFF):
                return 1, tab
            if t != 0x85:
                p += 32
                continue
            scnt = buf[p + 1]
            if scnt < 1 or p + 32 * (scnt + 1) > 512:
                print("      [s=%d p=%3d] 0x85 with scnt=%d SKIPPED (set spans sector)"
                      % (s, p, scnt))
                p += 32
                continue
            se = buf[p + 32:]
            attr = rd16(buf, p + 4)
            if se[0] != 0xC0 or (attr & 0x10):
                p += 32
                continue
            fc = rd32(se, 20)
            vdl = rd32(se, 24) or rd32(se, 8)
            nofat = (se[1] >> 1) & 1
            ni = 0
            nm = ""
            for k in range(1, scnt + 1):
                off = p + 32 * (k + 1)
                if off + 32 > 512 or buf[off] != 0xC1:
                    break
                hit = False
                for j in range(2, 32, 2):
                    if ni >= 27:
                        break
                    u = buf[off + j]
                    if u == 0:
                        hit = True
                        break
                    nm += chr(u) if u < 128 else "_"
                    ni += 1
                if hit:
                    break
            if ni < 4 or fc < 2 or vdl == 0 or len(tab) >= maxn:
                p += 32
                continue
            if nm[-4] != "." or nm[-3:].lower() != "bmp":
                print("      [s=%d p=%3d] name %r rejected (ni=%d)" % (s, p, nm, ni))
                p += 32
                continue
            tab.append((nm, fc, vdl, nofat))
            p += 32 * scnt
    return 0, tab


tab = []
cl = root_cl
for _ in range(64):
    done, tab = scan_cluster_orig(cl, tab, EXF_MAX_FILES)
    if done:
        break
    cl = fat_next(cl)
    if cl < 2:
        break

print("\nFILES THE M0 SEES (%d):" % len(tab))
for i, (nm, fc, vdl, nofat) in enumerate(tab):
    print("  [%d] %-24s first=%3d size=%d nofat=%d" % (i, nm, fc, vdl, nofat))
f.close()
