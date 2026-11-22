// guard.c - the half of the games guard that runs inside Steam, before Steam has read anything.
// (tool/Sources/tessera-run/GamesGuard.swift tells the whole story.)
//
// A Steam without Tessera's library removes the files of installed Windows games within a minute or two of starting.
// So while no Steam with the library runs, those games' install records (appmanifest files) are parked in
// <library>/steamapps/tessera-parked, where Steam does not look. Here, at Steam's start with the library:
//   1. the records are put back - but only for games Steam has a compatibility tool chosen for (for all Windows
//      games, entry "0" of CompatToolMapping in config.vdf, or for that game). Without a chosen tool even a Steam
//      with the library would treat the game as not belonging on a Mac, so its record stays parked until Tessera is
//      set up for it again;
//   2. a marker for this process is left in <support>/steam/running/<pid>;
//   3. the guard (`run steam-guard <pid>`) is started: it parks the records again when this process ends, however
//      it ends.
// Both halves take the same lock file; this half gives up on the lock after three seconds rather than hold up Steam.
#include <crt_externs.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "guard.h"

// ---- Steam's tool choices: which app ids have a compatibility tool, and whether "0" (all Windows games) has one

typedef struct {
    int all;                 // entry "0" names a tool
    int count;
    char ids[2048][16];      // the games with a tool of their own
} choices_t;

static char *read_file(const char *path, size_t max) {
    FILE *f = fopen(path, "r");
    if (!f) return NULL;
    char *text = malloc(max + 1);
    if (!text) { fclose(f); return NULL; }
    size_t got = fread(text, 1, max, f);
    fclose(f);
    text[got] = 0;
    return text;
}

// the quoted string that starts at p (p points at the opening quote); returns the character after the closing quote
static const char *quoted(const char *p, char *out, size_t size) {
    size_t n = 0;
    for (p++; *p && *p != '"'; p++) {
        if (*p == '\\' && p[1]) p++;
        if (n + 1 < size) out[n++] = *p;
    }
    out[n] = 0;
    return *p ? p + 1 : p;
}

static void read_choices(const char *home, choices_t *c) {
    char path[1300];
    memset(c, 0, sizeof *c);
    snprintf(path, sizeof path, "%s/Library/Application Support/Steam/config/config.vdf", home);
    char *text = read_file(path, 8 * 1024 * 1024);
    if (!text) return;
    const char *p = strstr(text, "\"CompatToolMapping\"");
    if (p && (p = strchr(p, '{'))) {
        // "<id>" { "name" "<tool>" "config" "" "priority" "250" } ... until the block's closing brace
        char id[64], key[64], value[256];
        for (p++; *p && *p != '}'; ) {
            if (*p != '"') { p++; continue; }
            p = quoted(p, id, sizeof id);
            while (*p && *p != '{' && *p != '}' && *p != '"') p++;
            if (*p != '{') continue;
            int named = 0;
            for (p++; *p && *p != '}'; ) {
                if (*p != '"') { p++; continue; }
                p = quoted(p, key, sizeof key);
                while (*p && *p != '"' && *p != '}' && *p != '{') p++;
                if (*p != '"') break;
                p = quoted(p, value, sizeof value);
                if (!strcmp(key, "name") && value[0]) named = 1;
            }
            if (*p == '}') p++;
            if (!named) continue;
            if (!strcmp(id, "0")) c->all = 1;
            else if (strlen(id) < sizeof c->ids[0] && c->count < (int)(sizeof c->ids / sizeof c->ids[0])) strcpy(c->ids[c->count++], id);
        }
    }
    free(text);
}

static int has_choice(const choices_t *c, const char *id) {
    if (c->all) return 1;
    for (int i = 0; i < c->count; i++) if (!strcmp(c->ids[i], id)) return 1;
    return 0;
}

// ---- putting the records back

#define REDISTRIBUTABLES "228980"       // Steamworks Common Redistributables: goes with the games

static int is_manifest(const char *name, char *id, size_t size) {
    size_t len = strlen(name);
    if (strncmp(name, "appmanifest_", 12) || len < 17 || len >= 160 || strcmp(name + len - 4, ".acf")) return 0;
    snprintf(id, size, "%.*s", (int)(len - 16), name + 12);
    return 1;
}

static void put_back_folder(const char *apps, const choices_t *c, tessera_guard_log_t logf, int *back, int *kept) {
    char parked[2048], from[2400], to[2400], id[160];
    snprintf(parked, sizeof parked, "%s/tessera-parked", apps);
    DIR *d = opendir(parked);
    if (!d) return;
    char (*names)[160] = NULL;           // read the names first: entries are moved out of the folder afterwards
    int n = 0, cap = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!is_manifest(e->d_name, id, sizeof id)) continue;
        if (n == cap) {
            cap = cap ? cap * 2 : 64;
            void *grown = realloc(names, (size_t)cap * sizeof *names);
            if (!grown) break;
            names = grown;
        }
        strcpy(names[n++], e->d_name);
    }
    closedir(d);
    int here = 0;
    for (int pass = 0; pass < 2; pass++) {              // the games first, the redistributables with them
        for (int i = 0; i < n; i++) {
            is_manifest(names[i], id, sizeof id);
            int redistributables = !strcmp(id, REDISTRIBUTABLES);
            if (redistributables != pass) continue;
            if (redistributables ? !(c->all || here > 0) : !has_choice(c, id)) { (*kept)++; continue; }
            snprintf(from, sizeof from, "%s/%s", parked, names[i]);
            snprintf(to, sizeof to, "%s/%s", apps, names[i]);
            if (!access(to, F_OK)) {
                // Steam has made a record of its own in the meantime: Steam's stays, the parked one is kept aside
                char older[2100], aside[2600];
                snprintf(older, sizeof older, "%s/older", parked);
                mkdir(older, 0755);
                snprintf(aside, sizeof aside, "%s/%s.%ld", older, names[i], (long)time(NULL));
                rename(from, aside);
            } else if (!rename(from, to)) {
                (*back)++;
                here++;
            } else if (logf) {
                logf("guard: could not put back %s: %s", names[i], strerror(errno));
            }
        }
    }
    free(names);
}

void tessera_guard_put_back(const char *home, tessera_guard_log_t logf, int *back, int *kept) {
    choices_t *c = malloc(sizeof *c);
    if (!c) return;
    read_choices(home, c);
    char apps[1300], vdf[1300];
    snprintf(apps, sizeof apps, "%s/Library/Application Support/Steam/steamapps", home);
    put_back_folder(apps, c, logf, back, kept);
    // the extra library folders: "path" entries of libraryfolders.vdf
    const char *lists[] = {"%s/Library/Application Support/Steam/steamapps/libraryfolders.vdf",
                           "%s/Library/Application Support/Steam/config/libraryfolders.vdf"};
    for (int l = 0; l < 2; l++) {
        snprintf(vdf, sizeof vdf, lists[l], home);
        char *text = read_file(vdf, 1024 * 1024);
        if (!text) continue;
        for (const char *p = text; (p = strstr(p, "\"path\"")); ) {
            p += 6;
            while (*p && *p != '"' && *p != '\n') p++;
            if (*p != '"') continue;
            char value[1100], other[1300];
            p = quoted(p, value, sizeof value);
            snprintf(other, sizeof other, "%s/steamapps", value);
            if (value[0] && strcmp(other, apps)) put_back_folder(other, c, logf, back, kept);
        }
        free(text);
    }
    free(c);
}

// ---- at Steam's start

void tessera_guard_start(tessera_guard_log_t logf) {
    const char *home = getenv("HOME");
    if (!home) return;
    char dir[1100], path[1300], runner[1300], pidstr[16];
    snprintf(pidstr, sizeof pidstr, "%d", (int)getpid());
    snprintf(dir, sizeof dir, "%s/Library/Application Support/Tessera/steam", home);
    snprintf(path, sizeof path, "%s/guard.lock", dir);
    int lock = open(path, O_CREAT | O_RDWR, 0644), locked = 0;
    for (int tries = 0; lock >= 0 && !locked && tries < 30; tries++) {      // three seconds at most: Steam is waiting
        if (!flock(lock, LOCK_EX | LOCK_NB)) locked = 1; else usleep(100000);
    }
    if (lock >= 0 && !locked) logf("guard: the lock is held by another program; going on without it");
    int back = 0, kept = 0;
    tessera_guard_put_back(home, logf, &back, &kept);
    snprintf(path, sizeof path, "%s/running", dir);
    mkdir(path, 0755);
    snprintf(path, sizeof path, "%s/running/%s", dir, pidstr);
    int marker = open(path, O_CREAT | O_WRONLY, 0644);
    if (marker >= 0) close(marker);
    if (lock >= 0) { if (locked) flock(lock, LOCK_UN); close(lock); }
    if (back) logf("guard: %d install record%s of Windows games put back", back, back == 1 ? "" : "s");
    if (kept) logf("guard: %d install record%s stay%s parked: Steam has no compatibility tool chosen for %s (set up in Tessera)",
                   kept, kept == 1 ? "" : "s", kept == 1 ? "s" : "", kept == 1 ? "that game" : "those games");

    // Steam's launcher becomes the client in the same process (this runs again then): one guard per process
    const char *watched = getenv("TESSERA_GUARD_PID");
    if (watched && !strcmp(watched, pidstr)) return;
    snprintf(runner, sizeof runner, "%s/Library/Application Support/Tessera/compat/tessera/run", home);
    if (access(runner, X_OK)) {
        logf("guard: %s is missing, so the records stay visible when Steam ends", runner);
        return;
    }
    // through a shell that returns at once: the guard is then nobody's child, and Steam has nothing to wait for.
    // It does not need this library (DYLD_INSERT_LIBRARIES is left out of its environment).
    char **env = *_NSGetEnviron();
    int vars = 0;
    while (env[vars]) vars++;
    char **clean = calloc((size_t)vars + 1, sizeof *clean);
    if (!clean) return;
    for (int i = 0, j = 0; i < vars; i++)
        if (strncmp(env[i], "DYLD_INSERT_LIBRARIES=", 22)) clean[j++] = env[i];
    char *argv[] = {"/bin/sh", "-c", "\"$0\" steam-guard \"$1\" </dev/null >/dev/null 2>&1 &", runner, pidstr, NULL};
    pid_t shell;
    int err = posix_spawn(&shell, "/bin/sh", NULL, NULL, argv, clean);
    free(clean);
    if (err) {
        logf("guard: could not start (%s), so the records stay visible when Steam ends", strerror(err));
        return;
    }
    int status;
    waitpid(shell, &status, 0);
    setenv("TESSERA_GUARD_PID", pidstr, 1);
    logf("guard: watching this Steam; the install records of Windows games are parked when it ends");
}
