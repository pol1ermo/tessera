#!/usr/bin/env python3
"""patch-wine.py SRC - applies Tessera's changes to a fresh copy of the Wine source tree.

The Wine source Tessera builds is CodeWeavers' LGPL release (it carries the hooks Apple's D3DMetal needs). This
script makes the result Tessera's own:

  * the Windows user is "steamuser" (the same name Valve's Proton uses, so save paths match Linux and Steam Deck)
  * the CX_* environment variables are called TESSERA_*
  * text a player can see (window titles, dialogs, registry names, the loader's app identity) names neither
    CrossOver nor CodeWeavers; copyright notices are left exactly as they are
  * TESSERA_BACKEND_DIR puts one folder of graphics DLLs (DXMT, WineD3D) ahead of the built-in ones

Exact replacements fail loudly when a new source version no longer matches, instead of silently doing nothing.
"""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve()
changed: dict[str, int] = {}


def read(rel):
    return (root / rel).read_text(encoding="utf-8", errors="surrogateescape")


def write(rel, text):
    (root / rel).write_text(text, encoding="utf-8", errors="surrogateescape")


def exact(rel, pairs):
    s = read(rel)
    for old, new in pairs:
        if old not in s:
            sys.exit(f"patch-wine: {rel}: expected text not found: {old[:70]!r}")
        changed[rel] = changed.get(rel, 0) + s.count(old)
        s = s.replace(old, new)
    write(rel, s)


def regex(rel, pattern, repl, flags=0):
    s = read(rel)
    s2, n = re.subn(pattern, repl, s, flags=flags)
    if n == 0:
        sys.exit(f"patch-wine: {rel}: pattern not found: {pattern[:70]!r}")
    changed[rel] = changed.get(rel, 0) + n
    write(rel, s2)


# 1. the Windows user name
exact("dlls/advapi32/advapi.c", [
    ('sizeof("crossover")', 'sizeof("steamuser")'),
    ('strcpy( name, "crossover" )', 'strcpy( name, "steamuser" )'),
    ('ARRAY_SIZE( L"crossover" )', 'ARRAY_SIZE( L"steamuser" )'),
    ('wcscpy( name, L"crossover" )', 'wcscpy( name, L"steamuser" )'),
])

# 2. the loader's app identity (embedded in the wine binary; macOS shows it in permission prompts)
regex("loader/wine_info.plist.in", r"\s*<!--[^>]*CrossOver[^>]*-->", "")
exact("loader/wine_info.plist.in", [
    ("com.codeweavers.CrossOver.wineloader", "com.polermo.tessera2.wineloader"),
    ("CrossOver-Hosted Application", "Tessera"),
])

# 2b. games are games to macOS: Game Mode (CPU/GPU priority, faster Bluetooth input) engages in full screen
exact("loader/wine_info.plist.in", [('    <key>LSUIElement</key>\n    <string>1</string>\n</dict>', '    <key>LSUIElement</key>\n    <string>1</string>\n    <key>LSApplicationCategoryType</key>\n    <string>public.app-category.games</string>\n    <key>LSSupportsGameMode</key>\n    <true/>\n</dict>')])

# 2c. room for long program names: the loader writes the running program's name over CFBundleName (menu bar, Dock)
#     and may use a padding comment after it; without it names were cut to len("Tessera") = 7 letters
exact("loader/wine_info.plist.in", [("    <string>Tessera</string>\n    <key>CFBundlePackageType</key>",
                                     "    <string>Tessera</string><!-- bundle name padding -->\n    <key>CFBundlePackageType</key>")])

# 3. the crash dialog points players at CodeWeavers' web site
regex("programs/winedbg/winedbg.rc",
      r'You may want to check <a href=\\"https://www\.codeweavers\.com/compatibility/\\">.*?</a> \\\n\s*'
      r'for tips about running this application\.',
      "The game's log in the Tessera app may show more.", re.S)
regex("programs/winedbg/winedbg.rc",
      r'then <a href=\\"https://www\.codeweavers\.com/support/tickets/enter/\\">file a bug report</a> \\\n\s*'
      r'and attach that file to the report\.',
      "then attach that file when you report the problem.", re.S)

# 4. TESSERA_BACKEND_DIR: one folder of graphics DLLs searched before the built-in ones (per game, set by Tessera)
exact("dlls/ntdll/unix/loader.c", [(
    "    init_files();\n    init_startup_info();\n",
    "    init_files();\n    init_startup_info();\n"
    "    /* Tessera: a game's graphics backend (DXMT, WineD3D) is found before the default DLLs */\n"
    "    {\n"
    "        const char *backend_dir = getenv( \"TESSERA_BACKEND_DIR\" );\n"
    "        if (backend_dir && backend_dir[0] == '/') prepend_dll_path( strdup( backend_dir ) );\n"
    "    }\n",
)])
exact("dlls/ntdll/unix/loader.c", [
    ('"%s/cxcompatdb.so"', '"%s/compatdb.so"'),
    ("error loading cxcompatdb.so", "error loading compatdb.so"),
])

# 4b. text that lands in the binaries outside string literals: a function name printed by trace messages, and
#     comments in an .inf file that is embedded as a resource
for f in sorted((root / "dlls/shell32").glob("*.[ch]")):
    t = f.read_text(encoding="utf-8", errors="surrogateescape")
    if "SHELL_CrossOverFallback" in t:
        changed[str(f.relative_to(root))] = changed.get(str(f.relative_to(root)), 0) + t.count("SHELL_CrossOverFallback")
        f.write_text(t.replace("SHELL_CrossOverFallback", "SHELL_TesseraFallback"), encoding="utf-8", errors="surrogateescape")
regex("dlls/mshtml/mshtml.inf", r"Cross[Oo]ver [Hh]ack", "compat hack")

# 4c. wide strings spelled as character arrays: the profile folder name in shell32 (%USERPROFILE%) and registry
#     key names in ntdll
exact("dlls/shell32/shellpath.c", [("{'c','r','o','s','s','o','v','e','r',0}", "{'s','t','e','a','m','u','s','e','r',0}")])
regex("dlls/ntdll/unix/process.c", r"'C',\s*'r',\s*'o',\s*'s',\s*'s',\s*'O',\s*'v',\s*'e',\s*'r'", "'T','e','s','s','e','r','a'")

# 4d. GetLogicalDrives asks per drive letter (Godot 4 games stall on the \\DosDevices directory listing)
exact("dlls/kernelbase/volume.c", [('DWORD WINAPI DECLSPEC_HOTPATCH GetLogicalDrives(void)\n{\n    OBJECT_ATTRIBUTES attr;\n    UNICODE_STRING nt_name = RTL_CONSTANT_STRING( L"\\\\DosDevices\\\\" );\n    DWORD bitmask = 0;\n    NTSTATUS status;\n    HANDLE handle;\n\n    nt_name.Length -= sizeof(WCHAR);  /* without trailing slash */\n    InitializeObjectAttributes( &attr, &nt_name, OBJ_CASE_INSENSITIVE, 0, NULL );\n    status = NtOpenDirectoryObject( &handle, FILE_LIST_DIRECTORY, &attr );\n    if (!status)\n    {\n        char data[1024];\n        DIRECTORY_BASIC_INFORMATION *info = (DIRECTORY_BASIC_INFORMATION *)data;\n        ULONG ctx = 0, len;\n\n        while (!NtQueryDirectoryObject( handle, info, sizeof(data), 1, 0, &ctx, &len ))\n            if(info->ObjectName.Length == 2*sizeof(WCHAR) && info->ObjectName.Buffer[1] == \':\')\n                bitmask |= 1 << (info->ObjectName.Buffer[0] - \'A\');\n\n        NtClose( handle );\n    }\n\n    return bitmask;\n}', 'DWORD WINAPI DECLSPEC_HOTPATCH GetLogicalDrives(void)\n{\n    /* Tessera: ask for each drive letter\'s link (\\??\\A: .. \\??\\Z:) instead of listing \\DosDevices.\n     * Games built with Godot 4 stall at start-up with the directory listing; asking per letter is also\n     * independent of how the links are spelled (c: or C:). */\n    WCHAR name[] = L"\\\\??\\\\A:";\n    OBJECT_ATTRIBUTES attr;\n    UNICODE_STRING nt_name;\n    DWORD bitmask = 0;\n    HANDLE handle;\n    int i;\n\n    for (i = 0; i < 26; i++)\n    {\n        name[4] = \'A\' + i;\n        RtlInitUnicodeString( &nt_name, name );\n        InitializeObjectAttributes( &attr, &nt_name, OBJ_CASE_INSENSITIVE, 0, NULL );\n        if (!NtOpenSymbolicLinkObject( &handle, SYMBOLIC_LINK_QUERY, &attr ))\n        {\n            bitmask |= 1u << i;\n            NtClose( handle );\n        }\n    }\n    return bitmask;\n}')])

# 4e. steamclient(64).dll loads go to Tessera's Steam bridge (the real, signed file stays in the Steam folder)
exact("dlls/ntdll/loader.c", [('static NTSTATUS find_dll_file( const WCHAR *load_path, const WCHAR *libname, UNICODE_STRING *nt_name,', '/* Tessera: games load Valve\'s steamclient(64).dll from the Steam folder, and some (Source engine titles) first check\n * that the file on disk carries Valve\'s signature, so the real file stays there. What talks to the Mac Steam client\n * is Tessera\'s bridge, lsteamclient.dll, which is loaded in its place. */\nstatic const WCHAR *steamclient_redirect( const WCHAR *name )\n{\n    const WCHAR *base = name, *p;\n\n    if (!name) return name;\n    for (p = name; *p; p++) if (*p == \'\\\\\' || *p == \'/\') base = p + 1;\n    /* only this architecture\'s name: the bridge itself looks up "steamclient.dll" and must find itself only in\n       32-bit processes, as with Valve\'s own setup */\n#ifdef _WIN64\n    if (!wcsicmp( base, L"steamclient64.dll" ) || !wcsicmp( base, L"steamclient64" ))\n#else\n    if (!wcsicmp( base, L"steamclient.dll" ) || !wcsicmp( base, L"steamclient" ))\n#endif\n        return L"lsteamclient.dll";\n    return name;\n}\n\nstatic NTSTATUS find_dll_file( const WCHAR *load_path, const WCHAR *libname, UNICODE_STRING *nt_name,'), ('    TRACE( "looking for %s in %s\\n", debugstr_w(libname), debugstr_w(load_path) );\n\n    if (system && system_dll_path.Buffer)', '    TRACE( "looking for %s in %s\\n", debugstr_w(libname), debugstr_w(load_path) );\n    libname = steamclient_redirect( libname );\n\n    if (system && system_dll_path.Buffer)'), ('    status = find_dll_file( load_path, dllname ? dllname : name->Buffer,\n                            &nt_name, &wm, &mapping, &image_info, &id, &redirected, TRUE );', '    status = find_dll_file( load_path, steamclient_redirect( dllname ? dllname : name->Buffer ),\n                            &nt_name, &wm, &mapping, &image_info, &id, &redirected, TRUE );')])

# 4f. a Steam folder's steam.exe runs Tessera's built-in when steam.exe=b (the signed file stays on disk)
exact("dlls/ntdll/unix/loader.c", [('NTSTATUS load_main_exe( UNICODE_STRING *nt_name, USHORT load_machine, void **module )\n{\n    enum loadorder loadorder = get_load_order( nt_name );\n    unsigned int status;\n    SIZE_T size;\n    USHORT search_machine;\n\n    status = open_main_image( nt_name, module, &main_image_info, loadorder, load_machine );', "/* Tessera: is this the steam.exe of a Steam folder? */\nstatic BOOL is_steam_folder_exe( const UNICODE_STRING *nt_name )\n{\n    static const WCHAR exeW[] = {'\\\\','s','t','e','a','m','\\\\','s','t','e','a','m','.','e','x','e'};\n    USHORT len = nt_name->Length / sizeof(WCHAR), n = ARRAY_SIZE(exeW), i;\n\n    if (len < n) return FALSE;\n    for (i = 0; i < n; i++)\n    {\n        WCHAR c = nt_name->Buffer[len - n + i];\n        if (c >= 'A' && c <= 'Z') c += 'a' - 'A';\n        if (c != exeW[i]) return FALSE;\n    }\n    return TRUE;\n}\n\nNTSTATUS load_main_exe( UNICODE_STRING *nt_name, USHORT load_machine, void **module )\n{\n    enum loadorder loadorder = get_load_order( nt_name );\n    unsigned int status;\n    SIZE_T size;\n    USHORT search_machine;\n\n    /* Tessera: a Steam folder's steam.exe is Valve's signed file, which games inspect; when the load order asks\n       for builtin (steam.exe=b), the process runs Tessera's built-in steam.exe instead of that file */\n    if ((loadorder == LO_BUILTIN || loadorder == LO_BUILTIN_NATIVE) && is_steam_folder_exe( nt_name ) &&\n        !find_builtin_dll( nt_name, NULL, module, &size, &main_image_info, 0, 0, current_machine, load_machine, FALSE, 0 ))\n        return STATUS_SUCCESS;\n\n    status = open_main_image( nt_name, module, &main_image_info, loadorder, load_machine );")])

# 4g. each Windows program starts from a small app bundle that tells macOS it is a game (Game Mode)
exact("dlls/ntdll/unix/loader.c", [('static char *create_preloader_link(const char *wineloader_path, const char *exe_name)\n{\n    struct stat st;\n    char *linkpath = create_tempdir(wineloader_path);\n\n    if (!linkpath)\n        return NULL;\n\n    if (strlcat(linkpath, exe_name, MAX_PATH) >= MAX_PATH)\n        goto fail;\n\n    /* If the link already exists, use it (if it\'s in this dir, it points to the right place). */\n    if (!stat(linkpath, &st))\n        return linkpath;\n\n    /* Try a hard link first, to avoid the little "alias" arrow that the Dock puts on the icon.\n     * But if that fails, fall back to a symlink.\n     */\n    if (!link(wineloader_path, linkpath) || !symlink(wineloader_path, linkpath))\n        return linkpath;\n\nfail:\n    free(linkpath);\n    return NULL;\n}',
    '/* Tessera: the link sits in a small app bundle, <tempdir>/<name>.app/Contents/MacOS/<name>, whose Info.plist names\n * the program and marks it as a game. macOS takes an app\'s category only from a bundle\'s Info.plist, and Game Mode\n * (CPU and GPU priority, faster Bluetooth input) engages only for programs it knows are games. */\n#include <copyfile.h>\n\nstatic int clone_loader(const char *src, const char *dst)\n{\n    char *tmp;\n    int ret = -1;\n\n    if (asprintf(&tmp, "%s.%d", dst, (int)getpid()) < 0)\n        return -1;\n    if (!copyfile(src, tmp, NULL, COPYFILE_CLONE) && !rename(tmp, dst))\n        ret = 0;\n    else\n        unlink(tmp);\n    free(tmp);\n    return ret;\n}\n\nstatic void write_game_plist(const char *plist, const char *exe_name)\n{\n    char *name, *tmp, *q;\n    const char *p;\n    FILE *f;\n\n    if (!access(plist, F_OK) || !(name = malloc(strlen(exe_name) * 5 + 1)))\n        return;\n    for (p = exe_name, q = name; *p; p++)\n    {\n        if (*p == \'&\') { memcpy(q, "&amp;", 5); q += 5; }\n        else if (*p == \'<\') { memcpy(q, "&lt;", 4); q += 4; }\n        else if (*p == \'>\') { memcpy(q, "&gt;", 4); q += 4; }\n        else *q++ = *p;\n    }\n    *q = 0;\n    if (asprintf(&tmp, "%s.%d", plist, (int)getpid()) >= 0)\n    {\n        if ((f = fopen(tmp, "w")))\n        {\n            fprintf(f, "<?xml version=\\"1.0\\" encoding=\\"UTF-8\\"?>\\n"\n                    "<!DOCTYPE plist PUBLIC \\"-//Apple//DTD PLIST 1.0//EN\\" \\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\\">\\n"\n                    "<plist version=\\"1.0\\">\\n<dict>\\n"\n                    "    <key>CFBundleAllowMixedLocalizations</key>\\n    <true/>\\n"\n                    "    <key>CFBundleDevelopmentRegion</key>\\n    <string>English</string>\\n"\n                    "    <key>CFBundleExecutable</key>\\n    <string>%s</string>\\n"\n                    "    <key>CFBundleIdentifier</key>\\n    <string>com.polermo.tessera2.wineloader</string>\\n"\n                    "    <key>CFBundleInfoDictionaryVersion</key>\\n    <string>6.0</string>\\n"\n                    "    <key>CFBundleName</key>\\n    <string>%s</string>\\n"\n                    "    <key>CFBundlePackageType</key>\\n    <string>APPL</string>\\n"\n                    "    <key>CFBundleShortVersionString</key>\\n    <string>" PACKAGE_VERSION "</string>\\n"\n                    "    <key>CFBundleSignature</key>\\n    <string>\\?\\?\\?\\?</string>\\n"\n                    "    <key>CFBundleVersion</key>\\n    <string>" PACKAGE_VERSION "</string>\\n"\n                    "    <key>NSPrincipalClass</key>\\n    <string>WineApplication</string>\\n"\n                    "    <key>LSUIElement</key>\\n    <string>1</string>\\n"\n                    "    <key>LSApplicationCategoryType</key>\\n    <string>public.app-category.games</string>\\n"\n                    "    <key>LSSupportsGameMode</key>\\n    <true/>\\n"\n                    "</dict>\\n</plist>\\n", name, name);\n            if (fclose(f) || rename(tmp, plist)) unlink(tmp);\n        }\n        free(tmp);\n    }\n    free(name);\n}\n\nstatic char *create_preloader_link(const char *wineloader_path, const char *exe_name)\n{\n    struct stat st;\n    char *tempdir = create_tempdir(wineloader_path);\n    char *bundle = NULL, *path = NULL, *target = NULL, *linkpath = NULL, *p;\n\n    if (!tempdir)\n        return NULL;\n    if (asprintf(&bundle, "%s%s.app", tempdir, exe_name) < 0 ||\n        strlen(bundle) + strlen(exe_name) + sizeof("/Contents/MacOS/ntdll.so") >= PATH_MAX)\n        goto fail;\n\n    mkdir(bundle, 0700);\n    if (asprintf(&path, "%s/Contents", bundle) < 0) goto fail;\n    mkdir(path, 0700);\n    free(path);\n    if (asprintf(&path, "%s/Contents/MacOS", bundle) < 0) goto fail;\n    mkdir(path, 0700);\n    free(path);\n    if (asprintf(&path, "%s/Contents/Info.plist", bundle) < 0) goto fail;\n    write_game_plist(path, exe_name);\n    free(path);\n\n    /* the loader opens the ntdll.so next to itself */\n    if (!(target = strdup(wineloader_path))) goto fail;\n    if ((p = strrchr(target, \'/\'))) *p = 0;\n    if (asprintf(&path, "%s/Contents/MacOS/ntdll.so", bundle) < 0) goto fail;\n    if (asprintf(&p, "%s/ntdll.so", target) >= 0)\n    {\n        symlink(p, path);\n        free(p);\n    }\n    free(path);\n    path = NULL;\n\n    if (asprintf(&linkpath, "%s/Contents/MacOS/%s", bundle, exe_name) < 0) goto fail;\n\n    /* The program file is a copy (an APFS clone: no extra space). macOS names a running process after its file, and\n     * hard links to one file all report the name the file was first opened by. An existing copy is used as it is;\n     * a hard link (no "alias" arrow on the Dock icon) and then a symlink are the fallbacks. */\n    if (!stat(linkpath, &st) || !clone_loader(wineloader_path, linkpath) ||\n        !link(wineloader_path, linkpath) || !symlink(wineloader_path, linkpath))\n    {\n        free(target);\n        free(bundle);\n        free(tempdir);\n        return linkpath;\n    }\n\nfail:\n    free(linkpath);\n    free(target);\n    free(bundle);\n    free(tempdir);\n    return NULL;\n}')])

# 4h. WineD3D (DirectX 9, 32-bit DirectX 10/11) reports an Intel GPU on Apple silicon instead of an NVIDIA 8800 GTX
exact("dlls/wined3d/adapter_gl.c", [('        if (!(caps_gl_ctx->gpu_description = wined3d_get_gpu_description(vendor, device)))\n        {\n            ERR("Card %04x:%04x not found in driver DB.\\n", vendor, device);',
    '        /* Tessera: other Apple GPUs would be an NVIDIA GeForce 8800 GTX. Games then require NVIDIA\'s NVAPI library\n         * (CS:GO: "Failed to initialize NVAPI"), and as an AMD card Source games want AMD-only depth formats WineD3D\n         * lacks ("hardware does not support all features (CSM)"). An Intel card needs neither. */\n        if (strstr(gl_vendor_str, "Apple") && !(vendor == HW_VENDOR_AMD && device == CARD_AMD_RADEON_RX_480))\n        {\n            vendor = HW_VENDOR_INTEL;\n            device = CARD_INTEL_UHD630_1;\n        }\n\n        if (!(caps_gl_ctx->gpu_description = wined3d_get_gpu_description(vendor, device)))\n        {\n            ERR("Card %04x:%04x not found in driver DB.\\n", vendor, device);')])

# 4i. the bridge loaded as steamclient(64).dll reports Steam's own file as its path (Steam DRM checks it)
exact("dlls/ntdll/loader.c", [('        return L"lsteamclient.dll";\n    return name;\n}\n', '        return L"lsteamclient.dll";\n    return name;\n}\n\n/* Tessera: the bridge loaded in place of steamclient(64).dll reports Steam\'s own file as its path\n * (GetModuleFileName); Steam\'s DRM wrapper in older games checks that steamclient.dll comes from Steam\'s folder,\n * where Valve\'s signed file is (Fallout: New Vegas: "Application load error 3:0000065432"). Its name stays\n * lsteamclient.dll, so lookups by name keep finding it; the old path buffer holds that name and stays allocated. */\nstatic void steamclient_report_steam_path( WINE_MODREF *wm )\n{\n#ifdef _WIN64\n    static const WCHAR path[] = L"C:\\\\Program Files (x86)\\\\Steam\\\\steamclient64.dll";\n#else\n    static const WCHAR path[] = L"C:\\\\Program Files (x86)\\\\Steam\\\\steamclient.dll";\n#endif\n    WCHAR *buffer;\n\n    if (!(buffer = RtlAllocateHeap( GetProcessHeap(), 0, sizeof(path) ))) return;\n    memcpy( buffer, path, sizeof(path) );\n    RtlInitUnicodeString( &wm->ldr.FullDllName, buffer );\n}\n'),
    ('    BOOL redirected;\n    void *prev;\n\n    TRACE( "looking for %s in %s\\n", debugstr_w(libname), debugstr_w(load_path) );\n    libname = steamclient_redirect( libname );\n', '    BOOL redirected;\n    void *prev;\n    const WCHAR *requested = libname;\n\n    TRACE( "looking for %s in %s\\n", debugstr_w(libname), debugstr_w(load_path) );\n    libname = steamclient_redirect( libname );\n'),
    ('done:\n    if (nts == STATUS_SUCCESS)\n        TRACE("Loaded module %s at %p\\n", debugstr_us(&nt_name), (*pwm)->ldr.DllBase);\n', 'done:\n    if (nts == STATUS_SUCCESS && libname != requested) steamclient_report_steam_path( *pwm );\n    if (nts == STATUS_SUCCESS)\n        TRACE("Loaded module %s at %p\\n", debugstr_us(&nt_name), (*pwm)->ldr.DllBase);\n')])

# 5. every remaining string literal: CX_* variables become TESSERA_*, CrossOver/CodeWeavers text becomes neutral
SOURCE_DIRS = ["dlls", "programs", "loader", "server", "libs", "fonts", "nls"]
SUFFIXES = {".c", ".m", ".h", ".rc", ".inf", ".in", ".idl", ".y", ".l", ".spec", ".reg"}
literal = re.compile(r'L?"(?:[^"\\\n]|\\.)*"')
brand = [
    (re.compile(r"\bCX_([A-Z0-9_]+)"), r"TESSERA_\1"),
    (re.compile(r"CrossOver Web Browser"), "Web Browser"),
    (re.compile(r"CrossOver HTML engine"), "HTML engine"),
    (re.compile(r"\bCXHTML\b"), "TesseraHTML"),
    (re.compile(r"NOCROSSOVERFALLBACK"), "NOTESSERAFALLBACK"),
    (re.compile(r"CrossOverFallback"), "TesseraFallback"),
    (re.compile(r"Cross[Oo]ver hack", re.I), "compat hack"),
    (re.compile(r"CrossOver|Crossover"), "Tessera"),
    (re.compile(r"\bcrossover\b"), "tessera"),
]
keep = re.compile(r"copyright|\(c\)|©|codeweavers\.com/compatibility|license", re.I)
def neutralize(path):
    text = path.read_text(encoding="utf-8", errors="surrogateescape")
    if not re.search(r"CX_|[Cc]ross[Oo]ver|CROSSOVER|CXHTML", text):
        return
    count = [0]

    def fix(m):
        s = m.group(0)
        for pat, rep in brand:
            s, n = pat.subn(rep, s)
            count[0] += n
        return s

    lines = [line if keep.search(line) else literal.sub(fix, line) for line in text.split("\n")]
    if count[0]:
        rel = str(path.relative_to(root))
        changed[rel] = changed.get(rel, 0) + count[0]
        path.write_text("\n".join(lines), encoding="utf-8", errors="surrogateescape")


for d in SOURCE_DIRS:
    for path in (root / d).rglob("*"):
        if path.suffix in SUFFIXES and path.is_file():
            neutralize(path)

# what is left inside string literals (comments and copyright lines are fine)
left = []
for d in SOURCE_DIRS:
    for path in (root / d).rglob("*"):
        if path.suffix not in SUFFIXES or not path.is_file():
            continue
        for i, line in enumerate(path.read_text(encoding="utf-8", errors="surrogateescape").split("\n"), 1):
            if keep.search(line):
                continue
            for m in literal.finditer(line):
                if re.search(r"crossover|codeweavers|\bCX_", m.group(0), re.I):
                    left.append(f"{path.relative_to(root)}:{i}: {m.group(0)[:80]}")

print(f"patch-wine: {sum(changed.values())} changes in {len(changed)} files")
for rel in sorted(changed):
    print(f"  {changed[rel]:3d}  {rel}")
if left:
    print("still inside string literals:")
    print("\n".join("  " + x for x in left[:40]))
