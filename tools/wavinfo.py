import struct, sys
p = r"F:\Untitled world.wav"
d = open(p, 'rb').read(4096)
print('riff', d[0:4], 'size', struct.unpack('<I', d[4:8])[0], 'wave', d[8:12])
pos = 12
while pos + 8 <= len(d):
    cid = d[pos:pos+4]; sz = struct.unpack('<I', d[pos+4:pos+8])[0]
    print('chunk', cid, 'size', sz, 'at', pos)
    if cid == b'fmt ':
        fmt, ch, rate, brate, align, bits = struct.unpack('<HHIIHH', d[pos+8:pos+8+16])
        print('   fmt=%d ch=%d rate=%d byterate=%d align=%d bits=%d' % (fmt, ch, rate, brate, align, bits))
        if sz > 16:
            print('   ext', d[pos+8+16:pos+8+sz].hex())
    if cid == b'data':
        print('   data offset', pos + 8)
        break
    pos += 8 + sz + (sz & 1)
