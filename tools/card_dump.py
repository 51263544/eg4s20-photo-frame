import struct
import sys

DRV = r"\\.\F:"
SEC = 512

f = open(DRV, "rb")


def read_lba(lba, n=1):
    f.seek(lba * SEC)
    return f.read(SEC * n)


pbr = read_lba(0)
assert pbr[3:11] == b"EXFAT   ", pbr[3:11]
bps_shift = pbr[0x6C]
spc_shift = pbr[0x6D]
n_fats = pbr[0x6E]
fat_off = struct.unpack_from("<I", pbr, 0x50)[0]
fat_len = struct.unpack_from("<I", pbr, 0x54)[0]
heap_off = struct.unpack_from("<I", pbr, 0x58)[0]
nclus = struct.unpack_from("<I", pbr, 0x5C)[0]
root_cl = struct.unpack_from("<I", pbr, 0x60)[0]
print("bps_shift=%d spc_shift=%d nfats=%d fat_off=%d fat_len=%d heap=%d clusters=%d root_cl=%d"
      % (bps_shift, spc_shift, n_fats, fat_off, fat_len, heap_off, nclus, root_cl))

SPC = 1 << spc_shift
CLUS_BYTES = SPC * SEC
print("cluster = %d sectors = %d bytes" % (SPC, CLUS_BYTES))


def clus_lba(c):
    return heap_off + (c - 2) * SPC


def fat_next(c):
    o = c * 4
    b = read_lba(fat_off + (o // SEC))
    return struct.unpack_from("<I", b, o % SEC)[0]


def chain(c, limit=64):
    out = [c]
    for _ in range(limit):
        n = fat_next(c)
        if n < 2 or n >= 0xFFFFFFF7:
            return out, n
        out.append(n)
        c = n
    return out, None


# ---- walk the root directory cluster chain ----
ents = []
c = root_cl
seen = 0
while 2 <= c < 0xFFFFFFF7 and seen < 32:
    lba = clus_lba(c)
    raw = read_lba(lba, SPC)
    for off in range(0, len(raw), 32):
        e = raw[off:off + 32]
        t = e[0]
        if t == 0x00:
            seen = 999
            break
        if t in (0x05,):
            continue
        if t in (0x81, 0x82, 0x83, 0x85, 0xC0, 0xC1, 0x16, 0x00):
            ents.append((c, lba, off, e))
    n = fat_next(c)
    if n < 2 or n >= 0xFFFFFFF7:
        break
    c = n
    seen += 1

print("\n--- entry types in root (physical order) ---")
for (cl, lba, off, e) in ents:
    print("  lba=%d off=%3d type=0x%02X" % (lba, off, e[0]))

# ---- decode file entry sets ----
print("\n--- file entry sets ---")
i = 0
while i < len(ents):
    cl, lba, off, e = ents[i]
    if e[0] != 0x85:
        i += 1
        continue
    scnt = e[1]
    attr = struct.unpack_from("<H", e, 4)[0]
    name_units, name = 0, ""
    for k in range(1, scnt + 1):
        if i + k >= len(ents):
            break
        se = ents[i + k][3]
        if se[0] == 0xC0:
            flags = se[1]
            first = struct.unpack_from("<I", se, 20)[0]
            size = struct.unpack_from("<q", se, 24)[0]
            vdl = struct.unpack_from("<q", se, 8)[0]
        elif se[0] == 0xC1:
            for j in range(2, 32, 2):
                u = struct.unpack_from("<H", se, j)[0]
                if u == 0:
                    break
                name += chr(u)
    nofat = (flags >> 1) & 1
    print("\n  '%s'  scnt=%d attr=0x%04X first=%d size=%d vdl=%d nofat=%d"
          % (name, scnt, attr, first, size, vdl, nofat))
    if nofat:
        need = (size + CLUS_BYTES - 1) // CLUS_BYTES
        print("     contiguous: clusters %d..%d (%d needed)  last_lba=%d"
              % (first, first + need - 1, need, clus_lba(first) + need * SPC - 1))
        ch = list(range(first, first + need))
        tail = None
    else:
        ch, tail = chain(first)
        print("     fat chain len=%d tail=%s" % (len(ch), tail))
        print("     clusters:", ch[:16])
        need = (size + CLUS_BYTES - 1) // CLUS_BYTES
        print("     needed=%d  chain_ok=%s" % (need, len(ch) >= need))
    # header of the file, from its own first cluster
    head = read_lba(clus_lba(first))
    print("     hdr: %r  sig@510=%02X%02X  res=%dx%d bpp=%d off=%d"
          % (head[:8], head[510], head[511],
             struct.unpack_from("<i", head, 18)[0],
             struct.unpack_from("<i", head, 22)[0],
             struct.unpack_from("<H", head, 28)[0],
             struct.unpack_from("<I", head, 10)[0]))
    i += 1 + scnt

f.close()
