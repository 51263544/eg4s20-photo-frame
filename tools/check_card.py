"""Model the firmware's P7 directory scan against a physical exFAT card.

Reads \\\\.\\F: raw (no admin needed), mounts exFAT the same way exfat.c does,
then replays find_char_dirs() / scan_char() so a card can be validated before
the board ever sees it.

Usage: python p7_check.py [F]
"""
import struct
import sys

DEV = (sys.argv[1] if len(sys.argv) > 1 else "F").rstrip(":")


def rd32(b, o):
    return struct.unpack_from("<I", b, o)[0]


class Card:
    def __init__(self, dev):
        self.f = open("\\\\.\\" + dev + ":", "rb")

    def sec(self, lba, n=1):
        self.f.seek(lba * 512)
        d = self.f.read(512 * n)
        if len(d) < 512 * n:
            raise IOError("short read at lba %d" % lba)
        return d

    # ---- exFAT mount, same steps as exf_mount() -------------------------
    def mount(self):
        b = self.sec(0)
        pbr = 0
        if b[3:11] != b"EXFAT   ":
            if b[510] == 0x55 and b[511] == 0xAA and rd32(b, 454):
                pbr = rd32(b, 454)
            b = self.sec(pbr)
            if b[3:11] != b"EXFAT   ":
                raise SystemExit("not exFAT (oem=%r)" % b[3:11])
        self.pbr = pbr
        self.spc = 1 << b[0x6D]                  # sectors per cluster
        self.fat_off = pbr + rd32(b, 0x50)
        self.heap_off = pbr + rd32(b, 0x58)
        self.root_cl = rd32(b, 0x60)
        print("exFAT  pbr=%d spc=%d(=%dK) fat=%d heap=%d root_cl=%d"
              % (pbr, self.spc, self.spc * 512 // 1024, self.fat_off,
                 self.heap_off, self.root_cl))

    def cb(self, cl):
        return self.heap_off + (cl - 2) * self.spc

    def fat_next(self, cl):
        off = cl * 4
        b = self.sec(self.fat_off + (off >> 9))
        v = rd32(b, off & 511)
        return 0 if (v < 2 or v >= 0xFFFFFFF7) else v

    # ---- directory scan, same filters as scan_cluster() -----------------
    def scan(self, start_cl, want_dir, ext=None):
        out = []
        cl = start_cl
        for _ in range(4096):
            base = self.cb(cl)
            for s in range(self.spc):
                b = self.sec(base + s)
                p = 0
                while p + 32 <= 512:
                    t = b[p]
                    if t in (0x00, 0xFF):
                        return out
                    if t != 0x85:
                        p += 32
                        continue
                    attr = struct.unpack_from("<H", b, p + 4)[0]
                    scnt = b[p + 1]
                    if p + 32 * (scnt + 1) > 512:
                        p += 32
                        continue
                    se = p + 32
                    if b[se] != 0xC0:
                        p += 32 * (scnt + 1)
                        continue
                    if want_dir and not (attr & 0x10):
                        p += 32 * (scnt + 1)
                        continue
                    if not want_dir and (attr & 0x10):
                        p += 32 * (scnt + 1)
                        continue
                    fc = rd32(b, se + 20)
                    size = rd32(b, se + 24) or rd32(b, se + 8)
                    nofat = (b[se + 1] >> 1) & 1
                    ni = 0
                    nm = []
                    for k in range(1, scnt + 1):
                        ne = p + 32 * (k + 1)
                        if b[ne] != 0xC1:
                            break
                        done = False
                        for j in range(2, 32, 2):
                            if b[ne + j] == 0:
                                done = True
                                break
                            nm.append(chr(b[ne + j]) if b[ne + j] < 128 else "_")
                        if done:
                            break
                    name = "".join(nm)
                    p += 32 * (scnt + 1)
                    if fc < 2:
                        continue
                    if want_dir:
                        if name.startswith("$") or name.lower().startswith("syst"):
                            continue
                        out.append((name, fc, size, nofat))
                    else:
                        if size == 0 or len(name) < 4 or name[-4] != ".":
                            continue
                        if ext and name[-3:].lower() != ext:
                            continue
                        out.append((name, fc, size, nofat))
            cl = self.fat_next(cl)
            if cl < 2:
                return out
        return out


def main():
    c = Card(DEV)
    c.mount()

    root = c.scan(c.root_cl, False, ext=None)
    print("\nroot entries (%d):" % len(root))
    for n, fc, sz, nf in root:
        print("   %-44s cl=%-6d size=%-10d %s" % (n, fc, sz, "contig" if nf else "chain"))

    dirs = c.scan(c.root_cl, True)
    print("\nroot dirs (%d):" % len(dirs))
    for n, fc, sz, nf in dirs:
        print("   %-20s cl=%d" % (n, fc))

    packs = []
    for n, fc, _, _ in dirs:
        if c.scan(fc, False, "bmp"):
            packs.append((n, fc))
    if not packs:
        for n, fc, _, _ in dirs:
            for n2, fc2, _, _ in c.scan(fc, True):
                if c.scan(fc2, False, "bmp"):
                    packs.append((n + "/" + n2, fc2))

    print("\ncharacter packs (%d):" % len(packs))
    for n, fc in packs[:2]:
        bmps = c.scan(fc, False, "bmp")
        inis = c.scan(fc, False, "ini")
        wavs = c.scan(fc, False, "wav")
        print("  [%s] cl=%d  bmp=%d wav=%d ini=%d" % (n, fc, len(bmps), len(wavs), len(inis)))
        for b in bmps:
            print("      bmp  %-34s size=%d %s" % (b[0], b[2], "contig" if b[3] else "chain"))
        for w in wavs:
            print("      wav  %-34s size=%d" % (w[0], w[2]))
        if inis:
            n2, fc2, sz2, _ = inis[0]
            raw = c.sec(c.cb(fc2))
            print("      ini  %r" % raw[:sz2].decode("ascii", "replace"))

    music = c.scan(c.root_cl, False, "wav")
    print("\nmusic at root (%d):" % len(music))
    for m in music:
        print("   %-44s size=%d" % (m[0], m[2]))


if __name__ == "__main__":
    main()
