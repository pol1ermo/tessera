// vr_only_test.c - offline check of the "VR only" matcher: maps a thin arm64 steamui.dylib file and prints the site.
//   clang -arch arm64 -O1 -o /tmp/vr_only_test vr_only_test.c tessera_steam.c guard.c hook.c activation.m -framework Foundation -framework AppKit
//   /tmp/vr_only_test STEAMUI_THIN_ARM64
#include <fcntl.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
long tessera_find_vr_only_site(const uint32_t *w, size_t n, int *out_off, int *out_bit);
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    int fd = open(argv[1], O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st)) { perror(argv[1]); return 2; }
    const uint8_t *d = mmap(0, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    const struct mach_header_64 *mh = (const void *)d;
    if (mh->magic != MH_MAGIC_64) { fprintf(stderr, "not a thin 64-bit Mach-O\n"); return 2; }
    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const void *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const void *)lc;
            const struct section_64 *s = (const void *)(seg + 1);
            for (uint32_t j = 0; j < seg->nsects; j++, s++)
                if (!strcmp(s->segname, "__TEXT") && !strcmp(s->sectname, "__text")) {
                    const uint32_t *w = (const void *)(d + s->offset);
                    int off = 0, bit = 0;
                    long k = tessera_find_vr_only_site(w, s->size / 4, &off, &bit);
                    if (k < 0) { printf("NOT FOUND\n"); return 1; }
                    printf("site 0x%llx insn 0x%08x flag +0x%x bit %d\n", (unsigned long long)(s->addr + (uint64_t)k * 4), w[k], off, bit);
                    return 0;
                }
        }
        p += lc->cmdsize;
    }
    return 1;
}
