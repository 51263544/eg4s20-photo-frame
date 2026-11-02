/*
 * exfat.c -- read-only exFAT parser for the P2 BMP slideshow.
 * Whitelist-style: only accepts complete {0x85 File, 0xC0 Stream, 0xC1 Name}
 * entry sets in the root directory. Root chain is walked via the FAT; file
 * clusters follow the stream entry NoFatChain flag.
 */
#include <stdint.h>
#include "exfat.h"
#include "sd_ctrl.h"

/* BPB geometry filled by exf_mount */
static uint32_t pbr_lba;      /* partition start (added to PBR-relative fields) */
static uint32_t fat_off;      /* absolute first FAT sector */
static uint32_t heap_off;     /* absolute cluster heap first sector */
static uint32_t spc;          /* sectors per cluster */
static uint32_t root_cl;      /* first cluster of root directory */

static uint16_t rd16(const uint8_t *p)
{
    return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* shared 512B sector scratch (MBR / PBR / dir / FAT) */
static uint8_t buf[512];

/* mount-failure forensics, see exf_mount_dbg() */
static uint32_t mk_step, mk_plba, mk_type;

/* scan-failure forensics, see exf_scan_dbg() */
static uint32_t sc_rderr, sc_ent;

/* 0 = collect files with the extension set by exf_set_ext(), 1 = collect
 * subdirectories (P7 resource pack: CHARS/<character>/). */
static int scan_dirs;

void exf_scan_dbg(uint32_t *out)
{
    out[0] = sc_rderr;
    out[1] = sc_ent;
    out[2] = 0u;
}

void exf_mount_dbg(uint32_t *out)
{
    out[0] = mk_step;
    out[1] = mk_plba;
    out[2] = mk_type;
}

static int is_exfat_pbr(const uint8_t *p)
{
    return p[3] == 'E' && p[4] == 'X' && p[5] == 'F' &&
           p[6] == 'A' && p[7] == 'T' && p[8] == ' ';
}

int exf_mount(void)
{
    uint32_t sig;

    pbr_lba = 0;
    mk_step = 0;
    mk_plba = 0;
    mk_type = 0;

    if (sd_read_sector(0, buf))
    {
        mk_step = 1;
        return 1;
    }

    /* LBA 0 is either an MBR (partition table) or -- "superfloppy" -- the PBR
     * itself.  Test for a PBR *first*: an exFAT volume written without a
     * partition table has its boot sector at LBA 0, and then offsets 446..510
     * hold boot code, so the old "MBR signature at 510" test picked up garbage
     * from there and then asked the card for a sector that does not exist. */
    if (is_exfat_pbr(buf))
    {
        pbr_lba = 0;                          /* no second read needed */
    }
    else
    {
        mk_type = buf[450];                   /* partition 1 type byte */
        sig = (buf[510] == 0x55 && buf[511] == 0xAA) ? rd32(buf + 454) : 0u;
        mk_plba = sig;
        /* accept only a plausible partition start: past the MBR, and inside a
         * card (a bogus value makes the card reject CMD17 and, worse, the SD
         * controller retries that forever with hw_busy stuck) */
        if (sig < 2u || sig > 0x00FFFFFFu)
        {
            mk_step = 3;
            return 3;                         /* no usable MBR entry */
        }
        pbr_lba = sig;
        if (sd_read_sector(pbr_lba, buf))
        {
            mk_step = 2;
            return 2;
        }
        if (!is_exfat_pbr(buf))
        {
            mk_step = 3;
            return 3;
        }
    }

    /* exFAT main boot sector field offsets (Microsoft exFAT spec):
     *   0x50 FatOffset(4)  0x54 FatLength(4)  0x58 ClusterHeapOffset(4)
     *   0x5C ClusterCount(4)  0x60 FirstClusterOfRootDirectory(4)
     *   0x64 VolumeSerialNumber(4)  0x6C BytesPerSectorShift(1)
     *   0x6D SectorsPerClusterShift(1)  0x6E NumberOfFats(1)
     * NOTE: spc is the *shift*, not a sector count -- the old code took
     * rd32(0x50) (FatOffset) as spc and rd32(0x64) (serial number) as the
     * root cluster, which fails the sanity check below on every real card. */
    if (buf[0x6C] != 9)                       /* 512-byte sectors only      */
    {
        mk_step = 4;
        return 4;
    }
    spc      = 1ul << buf[0x6D];              /* sectors per cluster        */
    fat_off  = pbr_lba + rd32(buf + 0x50);    /* FAT offset in sectors      */
    heap_off = pbr_lba + rd32(buf + 0x58);    /* cluster heap offset        */
    root_cl  = rd32(buf + 0x60);              /* first cluster of root dir  */

    if (spc == 0u || spc > 65536u || root_cl < 2u || root_cl >= 0xFFFFFFF7u)
    {
        mk_step = 4;
        return 4;
    }
    if (fat_off <= pbr_lba || heap_off <= pbr_lba)  /* must be past the volume */
    {
        mk_step = 4;
        return 4;
    }
    return 0;
}

uint32_t exf_cluster_base(uint32_t cluster)
{
    return heap_off + (cluster - 2u) * spc;
}

uint32_t exf_spc(void)
{
    return spc;
}

uint32_t exf_fat_next(uint32_t cluster)
{
    uint32_t byteofs = cluster << 2;          /* 4-byte FAT32-style entries */
    uint32_t v;

    if (sd_read_sector(fat_off + (byteofs >> 9), buf))
        return 0;
    v = rd32(buf + (byteofs & 511u));
    if (v < 2u || v >= 0xFFFFFFF7u)           /* free / EOC / bad marker    */
        return 0;
    return v;
}

/* mount debug values, for UART bring-up printout */
void exf_debug(uint32_t *out)
{
    out[0] = pbr_lba;
    out[1] = fat_off;
    out[2] = heap_off;
    out[3] = spc;
    out[4] = root_cl;
}

/* An entry set is *not* aligned to the 512-byte sector grid: a 4-entry set
 * (0x85 + 0xC0 + two 0xC1 name chunks, i.e. an 18..27 character name) sitting
 * at byte 480 of a sector runs into the next one.  The old code dropped every
 * such set ("set spans sector"), which silently hid one file out of the four
 * on the test card.  Stitch the head of the next sector onto the set. */
#define SC_ST_MAX 192                          /* <= 6 entries (scnt <= 5)  */

static uint8_t sc_st[SC_ST_MAX];

static void sc_copy(uint8_t *d, const uint8_t *s, int n)
{
    while (n-- > 0)
        *d++ = *s++;
}

/* parse one root cluster; returns 1 on end-of-directory, 0 otherwise */
/* extension that exf_scan() keeps; 'bmp' unless exf_set_ext() says otherwise */
static char scan_ext[3] = { 'b', 'm', 'p' };

void exf_set_ext(const char *e)
{
    int i;
    for (i = 0; i < 3; i++)
        scan_ext[i] = (char)(e[i] | 0x20);
}

static int scan_cluster(uint32_t cl, bmp_entry_t *tab, int max, int *n)
{
    uint32_t s;
    int p;

    for (s = 0; s < spc; s++) {
        if (sd_read_sector(exf_cluster_base(cl) + s, buf))
        {
            sc_rderr = 1u;
            return 1;                          /* read error: stop scan     */
        }
        p = 0;
        while (p + 32 <= 512) {
            uint8_t  t     = buf[p];
            uint8_t  scnt;
            uint8_t *base;
            uint8_t *se;
            uint32_t fc, vdl;
            uint8_t  nofat;
            char     nm[28];
            int      ni, k, j;
            uint16_t attr;

            if (t == 0x00 || t == 0xFF)
                return 1;                      /* end of directory          */
            if (t != 0x85) {
                p += 32;
                continue;                      /* not a File entry          */
            }
            sc_ent++;
            scnt = buf[p + 1];                 /* SecondaryCount            */
            if (scnt < 1 || scnt > 5) {        /* name would not fit nm[]   */
                p += 32;
                continue;
            }

            if (p + 32 * (scnt + 1) <= 512) {  /* whole set in this sector  */
                base  = buf + p;
                p    += 32 * (scnt + 1);
            } else {                           /* straddles: stitch it      */
                int have = 512 - p;
                int need = 32 * (scnt + 1);

                if (need > SC_ST_MAX || s + 1u >= spc) {
                    p += 32;
                    continue;
                }
                sc_copy(sc_st, buf + p, have);
                if (sd_read_sector(exf_cluster_base(cl) + s + 1u, buf))
                {
                    sc_rderr = 1u;
                    return 1;
                }
                sc_copy(sc_st + have, buf, need - have);
                base  = sc_st;
                p     = need - have;           /* keep scanning this sector */
                s++;                           /* ...it is already loaded   */
            }

            se   = base + 32;
            attr = rd16(base + 4);
            if (se[0] != 0xC0)
                continue;                      /* no stream entry           */
            if (scan_dirs ? !(attr & 0x10) : (attr & 0x10))
                continue;                      /* files *or* dirs, not both */

            fc   = rd32(se + 20);              /* FirstCluster              */
            vdl  = rd32(se + 24);              /* DataLength (low 32 bits)  */
            if (vdl == 0)
                vdl = rd32(se + 8);            /* fall back to ValidDataLen  */
            nofat = (se[1] >> 1) & 1u;         /* GeneralSecondaryFlags.1   */

            /* name from 0xC1 entries: UTF-16LE, fold to ASCII */
            ni = 0;
            for (k = 1; k <= scnt; k++) {
                uint8_t *ne = base + 32 * (k + 1);
                if (ne[0] != 0xC1)
                    break;
                /* UTF-16LE name, 0x0000 padded.  Stop at the first NUL:
                 * otherwise the padding pushes the ".bmp" test off the
                 * end of the buffer and EVERY file is rejected. */
                for (j = 2; j < 32 && ni < 27; j += 2) {
                    if (ne[j] == 0)
                        break;
                    nm[ni++] = (ne[j] < 128) ? (char)ne[j] : '_';
                }
                if (j < 32)                /* hit the NUL: name done   */
                    break;
            }
            nm[ni] = '\0';

            if (ni < 1 || fc < 2 || *n >= max)
                continue;

            if (scan_dirs) {
                /* keep volume-system folders out of the character list */
                if (nm[0] == '$')
                    continue;
                if (ni >= 4 &&
                    (nm[0] | 0x20) == 's' && (nm[1] | 0x20) == 'y' &&
                    (nm[2] | 0x20) == 's' && (nm[3] | 0x20) == 't')
                    continue;
            } else {
                if (vdl == 0 || ni < 4)
                    continue;
                if (nm[ni - 4] != '.')         /* extension selected by caller */
                    continue;
                if ((nm[ni - 3] | 0x20) != scan_ext[0] ||
                    (nm[ni - 2] | 0x20) != scan_ext[1] ||
                    (nm[ni - 1] | 0x20) != scan_ext[2])
                    continue;
            }

            {
                bmp_entry_t *e = &tab[(*n)++];
                e->first_cluster = fc;
                e->size          = vdl;
                e->nofat         = nofat;
                for (j = 0; j < 28; j++)
                    e->name[j] = 0;
                for (j = 0; j <= ni && j < 27; j++)
                    e->name[j] = nm[j];
            }
            /* p already points past this set (see the bounds code above) */
        }
    }
    return 0;
}

int exf_scan_from(uint32_t start_cl, bmp_entry_t *tab, int max)
{
    int      n  = 0;
    uint32_t cl = start_cl;
    int      guard;

    sc_rderr = 0u;
    sc_ent   = 0u;
    if (cl < 2u)
        return 0;

    for (guard = 0; guard < 4096; guard++) {
        if (scan_cluster(cl, tab, max, &n))
            break;                             /* end of dir / read error   */
        if (n >= max)
            break;
        cl = exf_fat_next(cl);
        if (cl < 2)
            break;                             /* EOC / chain end           */
    }
    return n;
}

int exf_scan(bmp_entry_t *tab, int max)
{
    return exf_scan_from(root_cl, tab, max);
}

int exf_scan_dirs_from(uint32_t start_cl, bmp_entry_t *tab, int max)
{
    int n;
    int saved = scan_dirs;

    scan_dirs = 1;
    n = exf_scan_from(start_cl, tab, max);
    scan_dirs = saved;
    return n;
}

uint32_t exf_root_cl(void)
{
    return root_cl;
}
