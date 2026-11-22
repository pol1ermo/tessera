// tessera_steam.dylib - Tessera's integration with the native macOS Steam client.
//
// Steam's macOS client contains the same compatibility-tool system the Linux client uses for Proton (tool folders,
// per-game mappings, launch command lines), but switches it off at start-up: the compatibility manager is enabled
// only when the client's own platform name equals "linux". This library is loaded into Steam (DYLD_INSERT_LIBRARIES),
// waits for steamclient.dylib, finds the code sites by instruction pattern (never by fixed address, so it survives
// Steam updates as long as the code shape stays the same) and patches them.
//
// Every action is logged to ~/Library/Logs/Tessera/steam.log.
#include <crt_externs.h>
#include <dlfcn.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <libkern/OSCacheControl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "guard.h"
#include "hook.h"

#if defined(__arm64__)

static FILE *logf_;

static void tlog(const char *fmt, ...) {
    if (!logf_) {
        const char *home = getenv("HOME");
        char dir[1024], path[1100];
        snprintf(dir, sizeof dir, "%s/Library/Logs/Tessera", home ? home : "/tmp");
        mkdir(dir, 0755);
        snprintf(path, sizeof path, "%s/steam.log", dir);
        logf_ = fopen(path, "a");
        if (!logf_) logf_ = stderr;
    }
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    fprintf(logf_, "[%04d-%02d-%02d %02d:%02d:%02d] [%d] ", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour,
            tm.tm_min, tm.tm_sec, getpid());
    va_list ap;
    va_start(ap, fmt);
    vfprintf(logf_, fmt, ap);
    va_end(ap);
    fputc('\n', logf_);
    fflush(logf_);
}

// ---- in-memory Mach-O view of a loaded image

typedef struct {
    const struct mach_header_64 *mh;
    intptr_t slide;
    uintptr_t text, text_size;          // __TEXT,__text
    uintptr_t cstr, cstr_size;          // __TEXT,__cstring
} image_t;

static int image_open(image_t *im, const struct mach_header *mh, intptr_t slide) {
    memset(im, 0, sizeof *im);
    if (mh->magic != MH_MAGIC_64) return 0;
    im->mh = (const struct mach_header_64 *)mh;
    im->slide = slide;
    const uint8_t *p = (const uint8_t *)(im->mh + 1);
    for (uint32_t i = 0; i < im->mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            const struct section_64 *s = (const struct section_64 *)(seg + 1);
            for (uint32_t j = 0; j < seg->nsects; j++, s++) {
                if (!strcmp(s->segname, "__TEXT") && !strcmp(s->sectname, "__text")) {
                    im->text = s->addr + slide;
                    im->text_size = s->size;
                } else if (!strcmp(s->segname, "__TEXT") && !strcmp(s->sectname, "__cstring")) {
                    im->cstr = s->addr + slide;
                    im->cstr_size = s->size;
                }
            }
        }
        p += lc->cmdsize;
    }
    return im->text && im->cstr;
}

// ---- arm64 decoding helpers

static int is_adrp(uint32_t w) { return (w & 0x9F000000u) == 0x90000000u; }
static uintptr_t adrp_target(uintptr_t pc, uint32_t w) {
    int64_t imm = (int64_t)((((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3));
    if (imm & (1 << 20)) imm -= (1 << 21);
    return (pc & ~(uintptr_t)0xFFF) + (uintptr_t)(imm << 12);
}
static int is_add_imm64(uint32_t w) { return (w & 0xFF800000u) == 0x91000000u; }
static uintptr_t add_imm(uint32_t w) {
    uintptr_t imm = (w >> 10) & 0xFFF;
    return ((w >> 22) & 1) ? imm << 12 : imm;
}

// ---- code patching

static int patch_insn(uintptr_t addr, uint32_t insn) {
    mach_port_t task = mach_task_self();
    vm_size_t page = (vm_size_t)getpagesize();
    vm_address_t pstart = addr & ~(page - 1);
    kern_return_t kr = vm_protect(task, pstart, page, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        tlog("patch at %p: vm_protect(rw) failed %d", (void *)addr, kr);
        return 0;
    }
    *(volatile uint32_t *)addr = insn;
    kr = vm_protect(task, pstart, page, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate((void *)addr, 4);
    if (kr != KERN_SUCCESS) {
        tlog("patch at %p: vm_protect(rx) failed %d", (void *)addr, kr);
        return 0;
    }
    return 1;
}

// ---- patch 1: the compatibility manager's platform gate
//
//   adrp x1, "linux"@PAGE ; add x1, x1, "linux"@PAGEOFF
//   mov  w2, #0x7fffffff
//   bl   <string compare>
//   cmp  w0, #0
//   cset wN, eq              <- replaced by: mov wN, #1
//   strb wN, [xM, #imm]      (the manager's "enabled" byte)
static int is_cstring_at(const image_t *im, uintptr_t addr, const char *s) {
    size_t n = strlen(s) + 1;
    if (addr < im->cstr || addr + n > im->cstr + im->cstr_size) return 0;
    return !memcmp((const void *)addr, s, n);          // also matches a tail-merged copy inside a longer string
}

static int patch_compat_gate(const image_t *im) {
    const uint32_t *w = (const uint32_t *)im->text;
    size_t n = im->text_size / 4;
    int found = 0;
    for (size_t i = 1; i + 6 < n; i++) {
        if (!is_add_imm64(w[i]) || (w[i] & 31) != 1) continue;              // add x1, xN, #imm
        if (w[i + 1] != 0x12B00002u) continue;                               // mov w2, #0x7fffffff
        if ((w[i + 2] & 0xFC000000u) != 0x94000000u) continue;               // bl
        if (w[i + 3] != 0x7100001Fu) continue;                               // cmp w0, #0
        if ((w[i + 4] & 0xFFFFFFE0u) != 0x1A9F17E0u) continue;               // cset wN, eq
        if ((w[i + 5] & 0xFFC00000u) != 0x39000000u) continue;               // strb wN, [xM, #imm]
        if ((w[i + 5] & 31) != (w[i + 4] & 31)) continue;
        // the ADRP that pairs with the ADD may be a few instructions earlier
        uintptr_t target = 0;
        for (size_t k = 1; k <= 8 && k <= i; k++) {
            uint32_t a = w[i - k];
            if (is_adrp(a) && (a & 31) == ((w[i] >> 5) & 31)) {
                target = adrp_target(im->text + (i - k) * 4, a) + add_imm(w[i]);
                break;
            }
        }
        if (!target || !is_cstring_at(im, target, "linux")) continue;
        uintptr_t site = im->text + (i + 4) * 4;
        uint32_t rd = w[i + 4] & 31;
        uint32_t off = ((w[i + 5] >> 10) & 0xFFF);
        if (patch_insn(site, 0x52800020u | rd)) {                            // mov wN, #1
            tlog("compat gate: enabled (patched %p, manager flag at +0x%x)", (void *)site, off);
            found++;
        }
    }
    if (!found) tlog("compat gate: pattern not found - Steam's code changed, Tessera needs an update");
    return found;
}


// ---- probes (TESSERA_PROBE=1): fixed offsets for client build 1794536281, for investigating Steam's behaviour only
static int probe_calls;
static void *o_scan, *o_enabled, *o_ctor;
static void p_scan(void *job) {
    tlog("probe: local tool scan job running (job %p)", job);
    ((void (*)(void *))o_scan)(job);
    tlog("probe: local tool scan job returned");
}
static int p_enabled(void *mgr, uint32_t appid) {
    int r = ((int (*)(void *, uint32_t))o_enabled)(mgr, appid);
    if (appid > 10 && probe_calls++ < 40)
        tlog("probe: BIsCompatibilityToolEnabled(mgr %p, app %u) = %d, flag+0x810 = %d", mgr, appid, r, ((uint8_t *)mgr)[0x810]);
    return r;
}
static void *p_ctor(void *mgr, void *a1, void *a2, void *a3) {
    tlog("probe: compat manager constructor (mgr %p)", mgr);
    void *r = ((void *(*)(void *, void *, void *, void *))o_ctor)(mgr, a1, a2, a3);
    tlog("probe: constructor done, flag+0x810 = %d", ((uint8_t *)mgr)[0x810]);
    return r;
}
static void *o_find, *o_decide;
static const char *safe_str(const void *p) {
    if (!p || (uintptr_t)p < 0x100000000ull) return "(null)";
    return (const char *)p;
}
static int p_find(void *mgr, void *a1, uint32_t a2, uint32_t appid, char **name, void *a5, void **ptool) {
    int r = ((int (*)(void *, void *, uint32_t, uint32_t, char **, void *, void **))o_find)(mgr, a1, a2, appid, name, a5, ptool);
    if (appid > 10) {
        void *t = ptool ? *ptool : NULL;
        tlog("probe: FindTool(app %u) = %d, name %s, tool %p, tool+0x78 %s, tool+0x80 %s", appid, r,
             safe_str(name ? *name : NULL), t, t ? safe_str(*(void **)((char *)t + 0x78)) : "-",
             t ? safe_str(*(void **)((char *)t + 0x80)) : "-");
    }
    return r;
}
static int p_decide(void *mgr, uint32_t appid, const char *platform, void *a3, int a4, void *a5) {
    int r = ((int (*)(void *, uint32_t, const char *, void *, int, void *))o_decide)(mgr, appid, platform, a3, a4, a5);
    if (appid > 10) tlog("probe: decide(app %u, platform \"%s\") = %d", appid, safe_str(platform), r);
    return r;
}
static void install_probes(const image_t *im) {
    uintptr_t b = (uintptr_t)im->mh;
    struct { const char *n; uintptr_t off; void *rep; void **orig; } P[] = {
        {"scan job", 0x6c6c5c, (void *)p_scan, &o_scan},
        {"BIsCompatibilityToolEnabled", 0x6bec4c, (void *)p_enabled, &o_enabled},
        {"constructor", 0x6ba6f0, (void *)p_ctor, &o_ctor},
        {"FindTool", 0x6be918, (void *)p_find, &o_find},
        {"decide", 0x6be798, (void *)p_decide, &o_decide},
    };
    for (unsigned i = 0; i < sizeof P / sizeof P[0]; i++) {
        int r = th_hook((void *)(b + P[i].off), P[i].rep, P[i].orig);
        tlog("probe: hook %s at %p -> %d", P[i].n, (void *)(b + P[i].off), r);
    }
}

static void install_ws_probe(void);

static void on_image(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (!dladdr(mh, &info) || !info.dli_fname) return;
    const char *name = strrchr(info.dli_fname, '/');
    name = name ? name + 1 : info.dli_fname;
    if (strcmp(name, "steamclient.dylib")) return;
    image_t im;
    if (!image_open(&im, mh, slide)) {
        tlog("steamclient.dylib: unexpected image layout");
        return;
    }
    tlog("steamclient.dylib loaded at %p (text %p, %lu bytes)", (void *)mh, (void *)im.text, (unsigned long)im.text_size);
    patch_compat_gate(&im);
    const char *pr = getenv("TESSERA_PROBE");
    if (pr && *pr == '1') { install_probes(&im); install_ws_probe(); }
}


// ---- Linux-style launch options ("NAME=value %command% ...").
// Mac Steam splits a game's launch command and runs the first word. Linux Steam treats leading NAME=value words as
// environment for the command; Mac Steam instead checks the first word with stat() ("an executable file?"), finds
// none and tries to open it as an app ("OS Error 260"). Tessera reports such words as executable so Steam takes its
// normal posix_spawn route, then moves them into the environment of the real program at spawn time.
#include <spawn.h>
#include <sys/stat.h>
extern char **environ;
static int is_assignment(const char *s) {
    if (!s || !((*s >= 'A' && *s <= 'Z') || (*s >= 'a' && *s <= 'z') || *s == '_')) return 0;
    for (const char *p = s; *p; p++) {
        if (*p == '=') return 1;
        if (!((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') || *p == '_')) return 0;
    }
    return 0;
}
// Steam may turn the word into a path first ("<dir>/NAME=value", or "<dir>/NAME=/some/path" when the value holds a
// slash), so find the path component where an assignment starts. Never applies to a file that really exists.
static const char *assignment_in(const char *path) {
    if (!path) return NULL;
    struct stat st;
    if (!stat(path, &st)) return NULL;
    for (const char *p = path; *p; p++) {
        if ((p == path || p[-1] == '/') && is_assignment(p)) return p;
    }
    return NULL;
}
static int verbose_launch(void) {
    static int v = -1;
    if (v < 0) { const char *e = getenv("TESSERA_PROBE"); v = e && *e == '1'; }
    return v;
}
static int tessera_stat(const char *path, struct stat *st) {
    if (assignment_in(path)) {
        memset(st, 0, sizeof *st);
        st->st_mode = S_IFREG | 0755;
        return 0;
    }
    return stat(path, st);
}
static int tessera_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa,
                               const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    if (argv && assignment_in(argv[0])) {
        int nassign = 0, nenv = 0;
        while (argv[nassign] && assignment_in(argv[nassign])) nassign++;
        if (!argv[nassign]) { tlog("launch options: only variables, no program"); return ENOENT; }
        while (envp && envp[nenv]) nenv++;
        char **env2 = calloc((size_t)(nenv + nassign + 1), sizeof(char *));
        int k = 0;
        for (int i = 0; i < nenv; i++) {                      // keep everything the launch options don't override
            const char *eq = strchr(envp[i], '=');
            size_t len = eq ? (size_t)(eq - envp[i] + 1) : strlen(envp[i]);
            int overridden = 0;
            for (int j = 0; j < nassign; j++) if (!strncmp(assignment_in(argv[j]), envp[i], len)) overridden = 1;
            if (!overridden) env2[k++] = envp[i];
        }
        for (int j = 0; j < nassign; j++) env2[k++] = (char *)assignment_in(argv[j]);
        env2[k] = NULL;
        tlog("launch options: %d variable(s) moved into the environment of %s", nassign, argv[nassign]);
        for (int j = 0; j < nassign; j++) tlog("    %s", assignment_in(argv[j]));
        int r = posix_spawn(pid, argv[nassign], fa, attr, argv + nassign, env2);
        free(env2);
        return r;
    }
    int r = posix_spawn(pid, path, fa, attr, argv, envp);
    if (verbose_launch() || r) {
        tlog("spawn %s -> %d (pid %d)", path ? path : "(null)", r, (r == 0 && pid) ? *pid : -1);
        for (int i = 0; verbose_launch() && argv && argv[i] && i < 24; i++) tlog("    argv[%d] = %s", i, argv[i]);
    }
    return r;
}
__attribute__((used, section("__DATA,__interpose"))) static struct { const void *rep, *orig; } interpose_spawn[] = {
    {(const void *)tessera_posix_spawn, (const void *)posix_spawn},
    {(const void *)tessera_stat, (const void *)stat},
};


// ---- probe: Steam also launches through -[NSWorkspace launchApplicationAtURL:options:configuration:error:]
#include <objc/message.h>
#include <objc/runtime.h>
static IMP o_ws_launch;
static const char *objc_desc(id o) {
    if (!o) return "(nil)";
    id d = ((id (*)(id, SEL))objc_msgSend)(o, sel_registerName("description"));
    return d ? ((const char *(*)(id, SEL))objc_msgSend)(d, sel_registerName("UTF8String")) : "?";
}
static id p_ws_launch(id self, SEL cmd, id url, unsigned long options, id config, id *error) {
    tlog("NSWorkspace launch %s", objc_desc(url));
    tlog("    configuration %s", objc_desc(config));
    id r = ((id (*)(id, SEL, id, unsigned long, id, id *))o_ws_launch)(self, cmd, url, options, config, error);
    tlog("    -> %s, error %s", r ? "launched" : "failed", (error && *error) ? objc_desc(*error) : "-");
    return r;
}
static void install_ws_probe(void) {
    Class c = objc_getClass("NSWorkspace");
    Method m = c ? class_getInstanceMethod(c, sel_registerName("launchApplicationAtURL:options:configuration:error:")) : NULL;
    if (m) {
        o_ws_launch = method_setImplementation(m, (IMP)p_ws_launch);
        tlog("probe: NSWorkspace launch hooked");
    }
}


static int tessera_execvp(const char *file, char *const argv[]) {
    if (verbose_launch()) tlog("execvp %s", file ? file : "(null)");
    for (int i = 0; verbose_launch() && argv && argv[i] && i < 24; i++) tlog("    argv[%d] = %s", i, argv[i]);
    return execvp(file, argv);
}
static int tessera_execve(const char *path, char *const argv[], char *const envp[]) {
    if (verbose_launch()) tlog("execve %s", path ? path : "(null)");
    for (int i = 0; verbose_launch() && argv && argv[i] && i < 24; i++) tlog("    argv[%d] = %s", i, argv[i]);
    return execve(path, argv, envp);
}
static int tessera_execv(const char *path, char *const argv[]) {
    if (verbose_launch()) tlog("execv %s", path ? path : "(null)");
    for (int i = 0; verbose_launch() && argv && argv[i] && i < 24; i++) tlog("    argv[%d] = %s", i, argv[i]);
    return execv(path, argv);
}
__attribute__((used, section("__DATA,__interpose"))) static struct { const void *rep, *orig; } interpose_exec[] = {
    {(const void *)tessera_execvp, (const void *)execvp},
    {(const void *)tessera_execve, (const void *)execve},
    {(const void *)tessera_execv, (const void *)execv},
};

void tessera_activation_init(void);
/// For activation.m: a line in Tessera's steam.log (Steam's processes do not reach the system log)
void tessera_steam_log(const char *line) { tlog("%s", line); }

__attribute__((constructor)) static void tessera_steam_init(void) {
    char exe[1024] = "";
    uint32_t sz = sizeof exe;
    _NSGetExecutablePath(exe, &sz);
    const char *base = strrchr(exe, '/');
    base = base ? base + 1 : exe;
    if (!strcmp(base, "Steam Helper")) {
        // Steam's windows belong to the main process of its web helper (the one without a --type= argument): that
        // is the app macOS has in front while Steam is, so the hand-over to a starting game comes from there
        int argc = *_NSGetArgc();
        char **argv = *_NSGetArgv();
        for (int i = 1; i < argc; i++) if (!strncmp(argv[i], "--type=", 7)) return;
        tessera_activation_init();                  // games come to the front when they open (activation.m)
        return;
    }
    if (strcmp(base, "steam_osx")) return;          // only the Steam client itself; other helpers inherit the variable
    tlog("loaded into %s", exe);
    tessera_guard_start(tlog);                   // the games guard, before Steam reads its library (guard.c)
    // Mac Steam does not know its own folder yet when it scans for compatibility tools, so tell it where to look:
    // Tessera's own tool folder (next to this library inside Tessera.app) and Steam's compatibilitytools.d.
    if (!getenv("STEAM_EXTRA_COMPAT_TOOLS_PATHS")) {
        char paths[4096] = "", own[2048];
        Dl_info me;
        if (dladdr((const void *)tessera_steam_init, &me) && me.dli_fname) {
            snprintf(own, sizeof own, "%s", me.dli_fname);
            char *slash = strrchr(own, '/');
            if (slash) {
                snprintf(slash, sizeof own - (size_t)(slash - own), "/../compat");
                struct stat st;
                if (!stat(own, &st) && S_ISDIR(st.st_mode)) snprintf(paths, sizeof paths, "%s:", own);
            }
        }
        const char *home = getenv("HOME");
        size_t used = strlen(paths);
        snprintf(paths + used, sizeof paths - used, "%s/Library/Application Support/Steam/compatibilitytools.d", home ? home : "");
        setenv("STEAM_EXTRA_COMPAT_TOOLS_PATHS", paths, 1);
        tlog("compatibility tool folders: %s", paths);
    }
    _dyld_register_func_for_add_image(on_image);
}

#endif // __arm64__

#ifndef __arm64__
void tessera_steam_log(const char *line) { (void)line; }   // Intel Macs: Steam runs without this library's hooks
#endif
