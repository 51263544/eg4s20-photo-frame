#ifndef EXFAT_H
#define EXFAT_H

#include <stdint.h>

#define EXF_MAX_FILES 16

typedef struct {
    uint32_t first_cluster;   /* file first cluster (>=2)              */
    uint32_t size;            /* valid data length in bytes            */
    uint8_t  nofat;           /* 1 = NoFatChain (contiguous clusters)  */
    char     name[28];        /* UTF-16LE folded to ASCII, truncated   */
} bmp_entry_t;

/* Read MBR/PBR, fill geometry. 0 = ok, nonzero = error step. */
int exf_mount(void);

/* Scan root directory for *.bmp; returns count (0..EXF_MAX_FILES). */
int exf_scan(bmp_entry_t *tab, int max);

/* Scan an arbitrary directory chain instead of the root -- used by the P7
 * resource pack, which keeps the pictures one level down
 * (CHARS, then the character name, then the BMP files).  Same entry type;
 * size holds the data length. */
int exf_scan_from(uint32_t start_cl, bmp_entry_t *tab, int max);

/* Scan an arbitrary directory chain for *subdirectories*.  Entries come back
 * in the same table; first_cluster is the subdirectory's first cluster. */
int exf_scan_dirs_from(uint32_t start_cl, bmp_entry_t *tab, int max);

/* First cluster of the root directory (0 before exf_mount succeeds). */
uint32_t exf_root_cl(void);

/* Choose which 3-letter extension exf_scan() keeps ("bmp", "wav", ...).     */
void exf_set_ext(const char *e);

/* First physical sector of cluster (cluster >= 2). */
uint32_t exf_cluster_base(uint32_t cluster);

/* Sectors per cluster (from PBR). */
uint32_t exf_spc(void);

/* Next cluster via FAT; 0 on EOC/error. */
uint32_t exf_fat_next(uint32_t cluster);

/* Fill mount debug values: {pbr_lba, fat_off, heap_off, spc, root_cl}. */
void exf_debug(uint32_t *out);

/* Fill the mount-failure forensics: {step, pbr_lba, part_type_byte}.
 * step is 0 when the mount succeeded. */
void exf_mount_dbg(uint32_t *out);

/* Fill the scan-failure forensics: {read_error, file_entries_seen, 0}. */
void exf_scan_dbg(uint32_t *out);

#endif /* EXFAT_H */
