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

# 4j. a game's steamclient(64).dll is Valve's real file, mapped but never run (Steam's DRM wrapper checks it)
#     (a stand-in copy of the bridge in its place is the bridge itself: never linked to itself)
exact("dlls/ntdll/loader.c", [('static BOOL process_detaching = FALSE;  /* set on process detach to avoid deadlocks with thread detach */\n', 'static BOOL process_detaching = FALSE;  /* set on process detach to avoid deadlocks with thread detach */\nstatic HMODULE steamclient_shadow, steamclient_bridge;  /* Tessera: see load_steamclient_pair */\nstatic BOOL steamclient_loading;\n'),
    ('    if (!(buffer = RtlAllocateHeap( GetProcessHeap(), 0, sizeof(path) ))) return;\n    memcpy( buffer, path, sizeof(path) );\n    RtlInitUnicodeString( &wm->ldr.FullDllName, buffer );\n}\n', '    if (!(buffer = RtlAllocateHeap( GetProcessHeap(), 0, sizeof(path) ))) return;\n    memcpy( buffer, path, sizeof(path) );\n    RtlInitUnicodeString( &wm->ldr.FullDllName, buffer );\n}\n\n/* Tessera: Steam\'s DRM wrapper in older games loads steamclient.dll, reads that file from Steam\'s folder, compares it\n * with the module in memory and wants the game\'s Steam interfaces to lie inside it. So a game\'s steamclient(64).dll is\n * Valve\'s real file, mapped as an image whose code never runs (as with DONT_RESOLVE_DLL_REFERENCES), and every function\n * looked up in it comes from the bridge, lsteamclient.dll, loaded beside it; the bridge puts the interfaces into that\n * module\'s .data, as Valve\'s bridge code expects. Without Valve\'s file the bridge itself stands in, as before. */\nstatic NTSTATUS load_steamclient_pair( const WCHAR *load_path, const WCHAR *libname, DWORD flags,\n                                       WINE_MODREF **pwm, BOOL system )\n{\n#ifdef _WIN64\n    static const WCHAR steam_file[] = L"C:\\\\Program Files (x86)\\\\Steam\\\\steamclient64.dll";\n#else\n    static const WCHAR steam_file[] = L"C:\\\\Program Files (x86)\\\\Steam\\\\steamclient.dll";\n#endif\n    const WCHAR *file = (wcschr( libname, \'\\\\\' ) || wcschr( libname, \'/\' )) ? libname : steam_file;\n    WINE_MODREF *bridge = NULL, *shadow = NULL;\n    NTSTATUS nts;\n\n    steamclient_loading = TRUE;\n    nts = load_dll( load_path, L"lsteamclient.dll", 0, &bridge, system );\n    if (!nts) nts = process_attach( bridge->ldr.DdagNode, NULL );\n    if (!nts)\n    {\n        /* A Steam folder without the file from Valve holds the bridge itself as a stand-in. The loader then finds\n         * the bridge again: linking its functions to themselves made every Steam call loop forever (games stopped at\n         * start without a window), so that case is the bridge standing in, like a missing file. */\n        if (!load_dll( load_path, file, flags | DONT_RESOLVE_DLL_REFERENCES, &shadow, system ) && shadow != bridge)\n        {\n            steamclient_shadow = shadow->ldr.DllBase;\n            steamclient_bridge = bridge->ldr.DllBase;\n            TRACE( "%s mapped for its file, its functions come from the bridge\\n", debugstr_w(file) );\n            *pwm = shadow;\n        }\n        else\n        {\n            steamclient_report_steam_path( bridge );\n            *pwm = bridge;\n        }\n    }\n    steamclient_loading = FALSE;\n    return nts;\n}\n'),
    ('    TRACE( "looking for %s in %s\\n", debugstr_w(libname), debugstr_w(load_path) );\n    libname = steamclient_redirect( libname );\n', '    TRACE( "looking for %s in %s\\n", debugstr_w(libname), debugstr_w(load_path) );\n    if (!steamclient_loading && !steamclient_shadow && steamclient_redirect( libname ) != libname)\n    {\n        if (imports_fixup_done) return load_steamclient_pair( load_path, libname, flags, pwm, system );\n        libname = steamclient_redirect( libname );  /* a static import at start-up gets the bridge itself */\n    }\n'),
    ('    status = find_dll_file( load_path, steamclient_redirect( dllname ? dllname : name->Buffer ),\n', '    status = find_dll_file( load_path, steamclient_shadow ? (dllname ? dllname : name->Buffer)\n                                       : steamclient_redirect( dllname ? dllname : name->Buffer ),\n'),
    ('static void free_modref( WINE_MODREF *wm )\n{\n    SINGLE_LIST_ENTRY *entry;\n    LDR_DEPENDENCY *dep;\n\n', 'static void free_modref( WINE_MODREF *wm )\n{\n    SINGLE_LIST_ENTRY *entry;\n    LDR_DEPENDENCY *dep;\n\n    if (wm->ldr.DllBase == steamclient_shadow) steamclient_shadow = NULL;  /* Tessera */\n')])

# 4k. its exports and entry point jump to the bridge; 32-bit keeps the file's ImageBase (as in Valve's setup)
exact("dlls/ntdll/loader.c", [('NTSTATUS WINAPI LdrGetProcedureAddress(HMODULE module, const ANSI_STRING *name,\n', "/* Tessera: steamclient(64).dll is Valve's file, mapped but never run (see load_steamclient_pair), and each of its\n * exported functions and its entry point start with a jump to the bridge's function of the same name - the way Valve's\n * own setup does it - so GetProcAddress gives Valve's addresses and a call lands in the bridge. */\nstatic void *steamclient_export( HMODULE module, const char *name )\n{\n    const IMAGE_EXPORT_DIRECTORY *exp;\n    const DWORD *names, *funcs;\n    const WORD *ords;\n    DWORD size, i, start;\n\n    if (!(exp = RtlImageDirectoryEntryToData( module, TRUE, IMAGE_DIRECTORY_ENTRY_EXPORT, &size ))) return NULL;\n    names = get_rva( module, exp->AddressOfNames );\n    ords = get_rva( module, exp->AddressOfNameOrdinals );\n    funcs = get_rva( module, exp->AddressOfFunctions );\n    start = (const BYTE *)exp - (const BYTE *)module;\n    for (i = 0; i < exp->NumberOfNames; i++)\n    {\n        if (strcmp( get_rva( module, names[i] ), name )) continue;\n        if (ords[i] >= exp->NumberOfFunctions) return NULL;\n        if (funcs[ords[i]] >= start && funcs[ords[i]] < start + size) return NULL;  /* a forwarder */\n        return get_rva( module, funcs[ords[i]] );\n    }\n    return NULL;\n}\n\nstatic void steamclient_write_jump( BYTE *at, const void *to )\n{\n#ifdef _WIN64\n    BYTE code[14] = { 0xff, 0x25 };  /* jmp [rip+0], then the address */\n    memcpy( code + 6, &to, sizeof(to) );\n#else\n    BYTE code[5] = { 0xe9 };         /* jmp rel32 */\n    INT_PTR rel = (const BYTE *)to - (at + 5);\n    memcpy( code + 1, &rel, 4 );\n#endif\n    void *base = at;\n    SIZE_T size = sizeof(code);\n    ULONG old;\n\n    if (NtProtectVirtualMemory( NtCurrentProcess(), &base, &size, PAGE_EXECUTE_READWRITE, &old )) return;\n    memcpy( at, code, sizeof(code) );\n    NtProtectVirtualMemory( NtCurrentProcess(), &base, &size, old, &old );\n    NtFlushInstructionCache( NtCurrentProcess(), at, sizeof(code) );\n}\n\nstatic void steamclient_link_exports( HMODULE shadow, HMODULE bridge )\n{\n    const IMAGE_NT_HEADERS *snt = RtlImageNtHeader( shadow ), *bnt = RtlImageNtHeader( bridge );\n    const IMAGE_EXPORT_DIRECTORY *exp;\n    const DWORD *names;\n    DWORD size, i;\n    BYTE *at;\n    void *to;\n\n    if (!(exp = RtlImageDirectoryEntryToData( shadow, TRUE, IMAGE_DIRECTORY_ENTRY_EXPORT, &size ))) return;\n    names = get_rva( shadow, exp->AddressOfNames );\n    for (i = 0; i < exp->NumberOfNames; i++)\n    {\n        const char *name = get_rva( shadow, names[i] );\n        if ((at = steamclient_export( shadow, name )) && (to = steamclient_export( bridge, name )))\n            steamclient_write_jump( at, to );\n    }\n    if (snt->OptionalHeader.AddressOfEntryPoint && bnt->OptionalHeader.AddressOfEntryPoint)\n        steamclient_write_jump( (BYTE *)shadow + snt->OptionalHeader.AddressOfEntryPoint,\n                                (BYTE *)bridge + bnt->OptionalHeader.AddressOfEntryPoint );\n}\n\n/* Wine writes the load address into the header's ImageBase when it relocates a DLL; Steam's DRM wrapper compares the\n * 32-bit steamclient.dll in memory with its file, so the file's value goes back (as Valve's own setup does). */\nstatic void steamclient_restore_image_base( HMODULE module, const UNICODE_STRING *dos_path )\n{\n    IMAGE_NT_HEADERS *nt = RtlImageNtHeader( module );\n    UNICODE_STRING nt_name;\n    OBJECT_ATTRIBUTES attr;\n    IO_STATUS_BLOCK io;\n    LARGE_INTEGER offset;\n    HANDLE file;\n    void *addr = &nt->OptionalHeader.ImageBase;\n    SIZE_T size = sizeof(nt->OptionalHeader.ImageBase);\n    ULONG old;\n\n    if (!RtlDosPathNameToNtPathName_U( dos_path->Buffer, &nt_name, NULL, NULL )) return;\n    memset( &attr, 0, sizeof(attr) );\n    attr.Length = sizeof(attr);\n    attr.Attributes = OBJ_CASE_INSENSITIVE;\n    attr.ObjectName = &nt_name;\n    if (!NtOpenFile( &file, GENERIC_READ | SYNCHRONIZE, &attr, &io, FILE_SHARE_READ | FILE_SHARE_DELETE,\n                     FILE_SYNCHRONOUS_IO_NONALERT | FILE_NON_DIRECTORY_FILE ))\n    {\n        offset.QuadPart = (BYTE *)&nt->OptionalHeader.ImageBase - (BYTE *)module;\n        if (!NtProtectVirtualMemory( NtCurrentProcess(), &addr, &size, PAGE_READWRITE, &old ))\n        {\n            NtReadFile( file, 0, NULL, NULL, &io, &nt->OptionalHeader.ImageBase, sizeof(nt->OptionalHeader.ImageBase),\n                        &offset, NULL );\n            NtProtectVirtualMemory( NtCurrentProcess(), &addr, &size, old, &old );\n        }\n        NtClose( file );\n    }\n    RtlFreeUnicodeString( &nt_name );\n}\n\nNTSTATUS WINAPI LdrGetProcedureAddress(HMODULE module, const ANSI_STRING *name,\n"),
    ('            steamclient_bridge = bridge->ldr.DllBase;\n', '            steamclient_bridge = bridge->ldr.DllBase;\n            steamclient_link_exports( steamclient_shadow, steamclient_bridge );\n#ifndef _WIN64\n            steamclient_restore_image_base( steamclient_shadow, &shadow->ldr.FullDllName );\n#endif\n')])

# 4l. a game's Documents & co. are real folders inside its Windows folder, not links to the Mac's own
exact("dlls/shell32/shellpath.c", [('static void _SHCreateSymbolicLink(int nFolder, const WCHAR *path)\n{\n    DWORD folder = nFolder & CSIDL_FOLDER_MASK;\n\n', 'static void _SHCreateSymbolicLink(int nFolder, const WCHAR *path)\n{\n    DWORD folder = nFolder & CSIDL_FOLDER_MASK;\n\n    /* Tessera: a game\'s Documents, Downloads, Music, Pictures and Videos stay inside its Windows folder, as with\n     * Valve\'s Proton, instead of linking to the Mac\'s own (games would write into the user\'s real, often\n     * iCloud-synced, Documents). TESSERA_LINK_HOME_FOLDERS=1 brings the links back. The callers create a directory\n     * when no link is made. */\n    if (!getenv("TESSERA_LINK_HOME_FOLDERS")) return;\n\n'),
    ('    /* CrossOver Hack 12791:\n     * Create the Desktop folder and put a link to the native one inside.\n     */\n    CreateDirectoryW( path, NULL );\n', '    /* CrossOver Hack 12791:\n     * Create the Desktop folder and put a link to the native one inside.\n     */\n    CreateDirectoryW( path, NULL );\n    if (!getenv("TESSERA_LINK_HOME_FOLDERS")) return;  /* Tessera: no link to the Mac desktop, see _SHCreateSymbolicLink */\n')])

# 4m. Steam's overlay libraries reach the game (TESSERA_OVERLAY_DYLIBS -> DYLD_INSERT_LIBRARIES before each program)
exact("dlls/ntdll/unix/loader.c", [('static void preloader_exec( char **argv, const char *image_path )\n{\n#ifdef HAVE_WINE_PRELOADER\n', 'static void preloader_exec( char **argv, const char *image_path )\n{\n#ifdef __APPLE__\n    /* Tessera: Steam\'s overlay libraries for the game. Steam hands them over for DYLD_INSERT_LIBRARIES, but macOS drops\n     * DYLD_ variables on the way through Wine\'s signed starter, so the launcher passes them as TESSERA_OVERLAY_DYLIBS\n     * and every Windows program gets them here, right before it starts. */\n    const char *overlay = getenv( "TESSERA_OVERLAY_DYLIBS" );\n    if (overlay && *overlay) setenv( "DYLD_INSERT_LIBRARIES", overlay, 1 );\n#endif\n#ifdef HAVE_WINE_PRELOADER\n')])

# 4n. Windows Media samples report their size (INSSBuffer::GetLength was a stub: games reading video frames with it
#     got E_NOTIMPL)
exact("dlls/winegstreamer/wm_reader.c", [('static HRESULT WINAPI buffer_GetLength(INSSBuffer *iface, DWORD *size)\n{\n    FIXME("iface %p, size %p, stub!\\n", iface, size);\n    return E_NOTIMPL;\n}', 'static HRESULT WINAPI buffer_GetLength(INSSBuffer *iface, DWORD *size)\n{\n    struct buffer *buffer = impl_from_INSSBuffer(iface);\n\n    TRACE("buffer %p, size %p.\\n", buffer, size);\n\n    *size = buffer->size;\n    return S_OK;\n}')])

# 4o. mouse look: a game that hides and captures the cursor gets every mouse movement as movement (no events dropped
#     when it re-centres the cursor, no rounding to cursor positions), and re-centring does not make it wait
exact("dlls/winemac.drv/cocoa_app.m", [('            // If we recently warped the cursor (other than in our cursor-clipping\n            // event tap), discard mouse move events until we see an event which is\n            // later than that time.\n            if (lastSetCursorPositionTime)', '            // Tessera: a game that hides and captures the cursor steers with the mouse (mouse look). Then every\n            // movement reaches it as movement, as raw mouse input does on Windows: nothing is dropped when the game\n            // puts the cursor back in the middle, and nothing is rounded to a cursor position.\n            BOOL mouseLook = self.clippingCursor && clientWantsCursorHidden;\n            if (mouseLook)\n            {\n                lastSetCursorPositionTime = 0;\n                forceNextMouseMoveAbsolute = FALSE;\n            }\n            // If we recently warped the cursor (other than in our cursor-clipping\n            // event tap), discard mouse move events until we see an event which is\n            // later than that time.\n            if (lastSetCursorPositionTime)'),
    ('            if (absolute)\n            {\n                if (self.clippingCursor)\n                    [clipCursorHandler clipCursorLocation:&point];', '            if (mouseLook)\n                absolute = FALSE;\n            if (absolute)\n            {\n                if (self.clippingCursor)\n                    [clipCursorHandler clipCursorLocation:&point];'),
    ('            // Discard all pending mouse move events.\n            [eventQueuesLock lock];\n            for (queue in eventQueues)\n            {\n                [queue discardEventsMatchingMask:event_mask_for_type(MOUSE_MOVED_RELATIVE) |\n                                                 event_mask_for_type(MOUSE_MOVED_ABSOLUTE)\n                                       forWindow:nil];\n                [queue resetMouseEventPositions:pos];\n            }\n            [eventQueuesLock unlock];', '            // Discard all pending mouse move events (Tessera: in mouse look only positions; movement is kept).\n            BOOL mouseLook = self.clippingCursor && clientWantsCursorHidden;\n            [eventQueuesLock lock];\n            for (queue in eventQueues)\n            {\n                [queue discardEventsMatchingMask:(mouseLook ? 0 : event_mask_for_type(MOUSE_MOVED_RELATIVE)) |\n                                                 event_mask_for_type(MOUSE_MOVED_ABSOLUTE)\n                                       forWindow:nil];\n                if (!mouseLook)\n                    [queue resetMouseEventPositions:pos];\n            }\n            [eventQueuesLock unlock];'),
    ('int macdrv_set_cursor_position(CGPoint pos)\n{\n    __block int ret;\n\n    OnMainThread(^{', "int macdrv_set_cursor_position(CGPoint pos)\n{\n    __block int ret;\n    WineApplicationController* controller = [WineApplicationController sharedController];\n\n    /* Tessera: a game in mouse look puts the cursor back in the middle every frame; it does not wait for the warp\n       (Wine's own cursor position is already updated, and no movement depends on the warp any more) */\n    if (controller.clippingCursor && controller.cursorHiddenByClient)\n    {\n        OnMainThreadAsync(^{\n            [controller setCursorPosition:cgpoint_mac_from_win(pos)];\n        });\n        return TRUE;\n    }\n\n    OnMainThread(^{"),
    ('    - (void) hideCursor\n    {', '    - (BOOL) cursorHiddenByClient\n    {\n        return clientWantsCursorHidden;\n    }\n\n    - (void) hideCursor\n    {')])
exact("dlls/winemac.drv/cocoa_app.h", [('@property (readonly) BOOL clippingCursor;', '@property (readonly) BOOL clippingCursor;\n@property (readonly) BOOL cursorHiddenByClient;   /* Tessera: the Windows program asked to hide the cursor */')])

# 4p. mouse look gets every mouse move from macOS (no coalescing): even view steps with a 1000 Hz mouse
exact("dlls/winemac.drv/cocoa_app.m", [('            BOOL mouseLook = self.clippingCursor && clientWantsCursorHidden;\n            if (mouseLook)\n            {\n                lastSetCursorPositionTime = 0;\n                forceNextMouseMoveAbsolute = FALSE;\n            }', '            BOOL mouseLook = self.clippingCursor && clientWantsCursorHidden;\n            static BOOL mouseLookEventsUncoalesced;\n            if (mouseLook != mouseLookEventsUncoalesced)\n            {\n                // macOS merges mouse moves that arrive between two passes of the event loop; in mouse look the\n                // game gets each one (a 1000 Hz mouse moves the view in even steps instead of lumps)\n                [NSEvent setMouseCoalescingEnabled:!mouseLook];\n                mouseLookEventsUncoalesced = mouseLook;\n            }\n            if (mouseLook)\n            {\n                lastSetCursorPositionTime = 0;\n                forceNextMouseMoveAbsolute = FALSE;\n            }')])

# 4q. games may change the display mode: Mac displays have no 640x480/800x600/16-bit modes, so Wine emulates the
#     change (the game sees the mode, its window is scaled to the screen) - Wine's EmulateModeset, on by default
#     (the value is only added when missing, so a game's own choice stays)
exact("loader/wine.inf.in", [('[Misc]\nHKLM,Software\\Borland\\Database Engine\\Settings\\SYSTEM\\INIT,SHAREDMEMLOCATION,,9000', '[Misc]\nHKCU,Software\\Wine\\X11 Driver,"EmulateModeset",2,"y"\nHKLM,Software\\Borland\\Database Engine\\Settings\\SYSTEM\\INIT,SHAREDMEMLOCATION,,9000')])

# 4r. the Metal layer games draw into (winemac.drv d3dmetal_objc.m, used by D3DMetal, DXMT and MoltenVK):
#     - RGB10A2 frames (D3DMetal's format for 10-bit DXGI swap chains) always went through the window compositor;
#       BGR10A2 (same bits, red/blue swapped) goes directly to the display, so the layer uses it when the request
#       comes from D3DMetal or DXMT's winemetal (they copy into the drawable with their own pass; MoltenVK does not)
#     - TESSERA_PRESENT_LOG=file logs per frame when a drawable is asked for and when it reaches the screen
#     - TESSERA_METAL_DRAWABLES (2|3), TESSERA_METAL_VSYNC (0|1), TESSERA_METAL_DIRECT_FORMAT=0 override the layer
exact("dlls/winemac.drv/d3dmetal_objc.m", [('#import <objc/runtime.h>\n', '#import <objc/runtime.h>\n#include <dlfcn.h>\n#include <string.h>\n'),
    ('@implementation WineMetalLayer\n\n    /* Extend [CAMetalLayer nextDrawable] so client_surface_present() can be\n     * called for the corresponding client_surface.\n     */\n    - (id<CAMetalDrawable>) nextDrawable\n    {', '/* Tessera: frame timing log (TESSERA_PRESENT_LOG=file) and frame-queue settings. Games\' graphics layers (D3DMetal,\n * DXMT, MoltenVK) set the layer\'s drawable count and vsync themselves; TESSERA_METAL_DRAWABLES (2 or 3) and\n * TESSERA_METAL_VSYNC (0 or 1) replace what they ask for. */\nstatic FILE *tessera_present_log(void)\n{\n    static FILE *log;\n    static dispatch_once_t once;\n    dispatch_once(&once, ^{\n        const char *path = getenv("TESSERA_PRESENT_LOG");\n        if (path && *path && (log = fopen(path, "a"))) setvbuf(log, NULL, _IOLBF, 0);\n    });\n    return log;\n}\n\n@implementation WineMetalLayer\n\n    /* macOS shows only some formats directly on the display; frames in RGB10A2 (D3DMetal\'s format for 10-bit DXGI swap\n       chains, e.g. The Last of Us) always go through the window compositor: an extra copy, more lag, and frames land\n       on the compositor\'s refresh instead of the display\'s own (uneven pacing). BGR10A2 has the same bits with red and\n       blue swapped and goes directly to the display. Only for graphics layers that copy their picture into the drawable\n       with a pass of their own (D3DMetal, DXMT\'s winemetal): MoltenVK lets games draw straight into the drawable, so\n       there the swap would show red as blue. TESSERA_METAL_DIRECT_FORMAT=0 keeps the game\'s format everywhere. */\n    - (void) setPixelFormat:(MTLPixelFormat)format\n    {\n        const char *want = getenv("TESSERA_METAL_DIRECT_FORMAT");\n        MTLPixelFormat use = format;\n        const char *caller = "?";\n        Dl_info info;\n        if (dladdr(__builtin_return_address(0), &info) && info.dli_fname)\n        {\n            const char *slash = strrchr(info.dli_fname, \'/\');\n            caller = slash ? slash + 1 : info.dli_fname;\n        }\n        if (format == MTLPixelFormatRGB10A2Unorm && !(want && want[0] == \'0\') &&\n            (!strncmp(caller, "D3DMetal", 8) || !strncmp(caller, "libd3dshared", 12) || !strncmp(caller, "winemetal", 9)))\n            use = MTLPixelFormatBGR10A2Unorm;\n        FILE *log = tessera_present_log();\n        if (log) fprintf(log, "S format asked %lu used %lu by %s at %.6f\\n", (unsigned long)format, (unsigned long)use, caller, CACurrentMediaTime());\n        [super setPixelFormat:use];\n    }\n\n    - (void) setMaximumDrawableCount:(NSUInteger)count\n    {\n        const char *want = getenv("TESSERA_METAL_DRAWABLES");\n        NSUInteger use = (want && (atoi(want) == 2 || atoi(want) == 3)) ? (NSUInteger)atoi(want) : count;\n        FILE *log = tessera_present_log();\n        if (log) fprintf(log, "S drawables asked %lu used %lu at %.6f\\n", (unsigned long)count, (unsigned long)use, CACurrentMediaTime());\n        [super setMaximumDrawableCount:use];\n    }\n\n    - (void) setDisplaySyncEnabled:(BOOL)enabled\n    {\n        const char *want = getenv("TESSERA_METAL_VSYNC");\n        BOOL use = (want && (want[0] == \'0\' || want[0] == \'1\')) ? (want[0] == \'1\') : enabled;\n        FILE *log = tessera_present_log();\n        if (log) fprintf(log, "S vsync asked %d used %d at %.6f\\n", (int)enabled, (int)use, CACurrentMediaTime());\n        [super setDisplaySyncEnabled:use];\n    }\n\n    /* Extend [CAMetalLayer nextDrawable] so client_surface_present() can be\n     * called for the corresponding client_surface.\n     */\n    - (id<CAMetalDrawable>) nextDrawable\n    {'),
    ('        return [super nextDrawable];\n    }\n\n@end', '        FILE *log = tessera_present_log();\n        if (log)\n        {\n            static unsigned long frame;\n            unsigned long n = ++frame;\n            CFTimeInterval asked = CACurrentMediaTime();\n            id<CAMetalDrawable> drawable = [super nextDrawable];\n            CFTimeInterval got = CACurrentMediaTime();\n            CGSize size = self.drawableSize;\n            fprintf(log, "D %lu %.6f %.6f %.0fx%.0f %lu %d\\n", n, asked, got, size.width, size.height,\n                    (unsigned long)self.maximumDrawableCount, (int)self.displaySyncEnabled);\n            if (n == 1 || n % 600 == 0)\n            {\n                /* what decides direct-to-display vs. composited: format, colour space, opacity, layers around it */\n                NSView *view = [self.delegate isKindOfClass:[NSView class]] ? (NSView *)self.delegate : nil;\n                CGColorSpaceRef cs = self.colorspace;\n                CFStringRef csName = cs ? CGColorSpaceCopyName(cs) : NULL;\n                char csText[96] = "none";\n                if (csName) { CFStringGetCString(csName, csText, sizeof(csText), kCFStringEncodingUTF8); CFRelease(csName); }\n                fprintf(log, "L fmt %lu cs %s opaque %d edr %d scale %.1f frame %.0fx%.0f sublayers %lu superlayer_sublayers %lu "\n                        "view_subviews %lu superview_subviews %lu superview_layer %d window_opaque %d window_level %ld style %lu\\n",\n                        (unsigned long)self.pixelFormat, csText, (int)self.opaque, (int)self.wantsExtendedDynamicRangeContent,\n                        self.contentsScale, self.frame.size.width, self.frame.size.height,\n                        (unsigned long)self.sublayers.count, (unsigned long)self.superlayer.sublayers.count,\n                        (unsigned long)view.subviews.count, (unsigned long)view.superview.subviews.count,\n                        view.superview.layer != nil, (int)view.window.opaque, (long)view.window.level,\n                        (unsigned long)view.window.styleMask);\n            }\n            [drawable addPresentedHandler:^(id<MTLDrawable> d) {\n                fprintf(log, "P %lu %.6f\\n", n, d.presentedTime);\n            }];\n            return drawable;\n        }\n        return [super nextDrawable];\n    }\n\n@end')])

# 4s. System Restore: SRSetRestorePointA/W answer like Windows with System Restore off (FALSE, status
#     ERROR_SERVICE_DISABLED); Wine's FALSE + ERROR_SUCCESS made DirectX's DXSETUP /silent stop with error -9
exact("dlls/sfc_os/sfc_os.c", [('BOOL WINAPI SRSetRestorePointA(RESTOREPOINTINFOA *restorepoint, STATEMGRSTATUS *status)\n{\n    FIXME("%p %p\\n", restorepoint, status);\n    status->nStatus = ERROR_SUCCESS;\n    return FALSE;\n}', 'BOOL WINAPI SRSetRestorePointA(RESTOREPOINTINFOA *restorepoint, STATEMGRSTATUS *status)\n{\n    /* Tessera: answer like Windows with System Restore turned off. FALSE with status ERROR_SUCCESS is a combination\n       Windows never returns; installers such as DirectX\'s DXSETUP /silent then stop with an internal error. */\n    FIXME("%p %p\\n", restorepoint, status);\n    status->nStatus = ERROR_SERVICE_DISABLED;\n    status->llSequenceNumber = 0;\n    SetLastError(ERROR_SERVICE_DISABLED);\n    return FALSE;\n}'),
    ('BOOL WINAPI SRSetRestorePointW(RESTOREPOINTINFOW *restorepoint, STATEMGRSTATUS *status)\n{\n    FIXME("%p %p\\n", restorepoint, status);\n    status->nStatus = ERROR_SUCCESS;\n    return FALSE;\n}', 'BOOL WINAPI SRSetRestorePointW(RESTOREPOINTINFOW *restorepoint, STATEMGRSTATUS *status)\n{\n    /* Tessera: answer like Windows with System Restore turned off. FALSE with status ERROR_SUCCESS is a combination\n       Windows never returns; installers such as DirectX\'s DXSETUP /silent then stop with an internal error. */\n    FIXME("%p %p\\n", restorepoint, status);\n    status->nStatus = ERROR_SERVICE_DISABLED;\n    status->llSequenceNumber = 0;\n    SetLastError(ERROR_SERVICE_DISABLED);\n    return FALSE;\n}')])

# 4t. DirectMusic synth sink: a DirectSound buffer the application hands over (IDirectMusicPort::SetDirectSound)
#     may lack position notifications; the render thread then waited forever for one (and deactivating the port
#     waited for that thread: the game froze before its first frame). Without notifications it now polls the
#     play position every half chunk, and the end-of-play drain stops when the buffer is not playing.
exact("dlls/dmsynth/synthsink.c", [('static HRESULT synth_sink_wait_write(struct synth_sink *sink, HANDLE buffer_event)\n{\n    HANDLE handles[] = {sink->stop_event, buffer_event};\n    DWORD ret;\n\n    ret = WaitForMultipleObjects(ARRAY_SIZE(handles), handles, FALSE, INFINITE);', 'static HRESULT synth_sink_wait_write(struct synth_sink *sink, HANDLE buffer_event, DWORD timeout)\n{\n    HANDLE handles[] = {sink->stop_event, buffer_event};\n    DWORD ret;\n\n    ret = WaitForMultipleObjects(ARRAY_SIZE(handles), handles, FALSE, timeout);\n    if (ret == WAIT_TIMEOUT)\n        return S_OK;'),
    ('    IDirectSoundNotify *notify;\n    WAVEFORMATEX format;\n    HANDLE buffer_event;\n    DWORD samples_size;', '    IDirectSoundNotify *notify;\n    WAVEFORMATEX format;\n    HANDLE buffer_event;\n    DWORD samples_size, poll_ms = INFINITE;'),
    ('    else if (FAILED(hr = IDirectSoundBuffer_QueryInterface(buffer, &IID_IDirectSoundNotify,\n                (void **)&notify)))\n        ERR("Failed to query IDirectSoundNotify iface, hr %#lx.\\n", hr);', '    else if (FAILED(hr = IDirectSoundBuffer_QueryInterface(buffer, &IID_IDirectSoundNotify,\n                (void **)&notify)))\n    {\n        /* Tessera: a buffer the application created without DSBCAPS_CTRLPOSITIONNOTIFY and handed over with\n           IDirectMusicPort::SetDirectSound has no notifications; native DirectMusic still plays into it. Check the\n           play position on a timer instead (synth_sink_write_data only writes where there is room). */\n        WARN("No IDirectSoundNotify on the sound buffer, hr %#lx; polling its position.\\n", hr);\n        poll_ms = 0;\n    }'),
    ('    samples_size = caps.dwBufferBytes / BUFFER_SUBDIVISIONS;', '    samples_size = caps.dwBufferBytes / BUFFER_SUBDIVISIONS;\n    if (poll_ms == 0)\n        poll_ms = format.nAvgBytesPerSec ? max(1, samples_size * 500 / format.nAvgBytesPerSec) : 10;'),
    ('        if (S_OK != (wait_hr = synth_sink_wait_write(sink, buffer_event)))', '        if (S_OK != (wait_hr = synth_sink_wait_write(sink, buffer_event, poll_ms)))'),
    ('        if (FAILED(hr = IDirectSoundNotify_SetNotificationPositions(notify,\n                ARRAY_SIZE(positions), positions)))\n            ERR("Failed to set notification positions, hr %#lx\\n", hr);', '        if (FAILED(hr = IDirectSoundNotify_SetNotificationPositions(notify,\n                ARRAY_SIZE(positions), positions)))\n        {\n            ERR("Failed to set notification positions, hr %#lx\\n", hr);\n            poll_ms = 0;\n        }'),
    ('static HRESULT synth_sink_wait_play_end(struct synth_sink *sink, IDirectSoundBuffer *buffer,\n        DSBCAPS *caps, WAVEFORMATEX *format, HANDLE buffer_event)\n{', 'static HRESULT synth_sink_wait_play_end(struct synth_sink *sink, IDirectSoundBuffer *buffer,\n        DSBCAPS *caps, WAVEFORMATEX *format, HANDLE buffer_event, DWORD timeout)\n{'),
    ('        if ((ret = WaitForMultipleObjects(1, &buffer_event, FALSE, INFINITE)))\n        {', '        if ((ret = WaitForMultipleObjects(1, &buffer_event, FALSE, timeout)) && ret != WAIT_TIMEOUT)\n        {'),
    ('    synth_sink_wait_play_end(sink, buffer, &caps, &format, buffer_event);', '    synth_sink_wait_play_end(sink, buffer, &caps, &format, buffer_event, poll_ms);'),
    ('        played += play_pos - start_pos + (play_pos < start_pos ? caps->dwBufferBytes : 0);\n        if (played >= written) break;\n', '        played += play_pos - start_pos + (play_pos < start_pos ? caps->dwBufferBytes : 0);\n        if (played >= written) break;\n        if (timeout != INFINITE)\n        {\n            /* polling (no notifications): a buffer the application stopped never reaches the end */\n            DWORD status = 0;\n            if (FAILED(IDirectSoundBuffer_GetStatus(buffer, &status)) || !(status & DSBSTATUS_PLAYING)) break;\n        }\n')])

# 4u. Emulated display modes (EmulateModeset): macOS runs the desktop in a scaled mode ("looks like" 2056x1329 on a
#     3456x2234 panel), so the emulated list stopped at the desktop size. It now goes up to the largest real mode.
#     DXGI (D3DMetal's too) lists modes only up to the desktop size, so TESSERA_FULL_RESOLUTION=1 (a per-game
#     setting) makes that game's desktop the largest real mode; switching it off returns the prefix to the Mac size.
exact("dlls/win32u/sysparams.c", [('        if ((virtual_modes = get_virtual_modes( current, &physical, host_modes, host_modes_count, &virtual_count )))', '        DEVMODEW maximum = physical;\n\n        /* Tessera: macOS runs the desktop in a scaled mode (it "looks like" 2056x1329 on a 3456x2234 panel), so the\n           current mode is smaller than what the display can show and emulated modes stopped there. Offer them up to\n           the largest real mode (normally the panel\'s own resolution); the picture is scaled onto the screen as for\n           every emulated mode. The desktop mode itself and the physical mode stay as they are. */\n        if (emulate_modeset)\n        {\n            const DEVMODEW *mode;\n            UINT n;\n\n            for (mode = host_modes, n = host_modes_count; mode && n; mode = NEXT_DEVMODEW(mode), n--)\n            {\n                if (mode->dmPelsWidth < maximum.dmPelsWidth || mode->dmPelsHeight < maximum.dmPelsHeight) continue;\n                if ((UINT64)mode->dmPelsWidth * mode->dmPelsHeight <= (UINT64)maximum.dmPelsWidth * maximum.dmPelsHeight) continue;\n                maximum.dmPelsWidth = mode->dmPelsWidth;\n                maximum.dmPelsHeight = mode->dmPelsHeight;\n            }\n        }\n\n        if ((virtual_modes = get_virtual_modes( current, &maximum, host_modes, host_modes_count, &virtual_count )))'),
    ('        if ((virtual_modes = get_virtual_modes( current, &maximum, host_modes, host_modes_count, &virtual_count )))\n        {\n            modes_count = virtual_count;\n            modes = virtual_modes;\n            current = &virtual;\n\n            write_source_mode( source->key, WINE_ENUM_PHYSICAL_SETTINGS, &physical );\n        }\n    }\n', '        if ((virtual_modes = get_virtual_modes( current, &maximum, host_modes, host_modes_count, &virtual_count )))\n        {\n            modes_count = virtual_count;\n            modes = virtual_modes;\n            current = &virtual;\n\n            write_source_mode( source->key, WINE_ENUM_PHYSICAL_SETTINGS, &physical );\n\n            /* Tessera: DXGI (D3DMetal\'s included) only lists modes up to the desktop size, so with\n               TESSERA_FULL_RESOLUTION=1 a game\'s desktop is the largest real mode instead of the Mac\'s scaled one.\n               Each game has its own prefix, so the default mode ("Registry") is set to match; a desktop left at\n               the other default by an earlier start with the other setting follows. Modes a game set stay. */\n            if (emulate_modeset && (maximum.dmPelsWidth != physical.dmPelsWidth || maximum.dmPelsHeight != physical.dmPelsHeight))\n            {\n                const char *full_env = getenv( "TESSERA_FULL_RESOLUTION" );\n                BOOL full = full_env && full_env[0] == \'1\';\n                DEVMODEW desktop = full ? maximum : physical, other = full ? physical : maximum, saved;\n\n                if (!read_source_mode( source->key, ENUM_REGISTRY_SETTINGS, &saved ) ||\n                    saved.dmPelsWidth != desktop.dmPelsWidth || saved.dmPelsHeight != desktop.dmPelsHeight)\n                {\n                    BOOL was_other = !read_source_mode( source->key, ENUM_REGISTRY_SETTINGS, &saved ) ||\n                                     (saved.dmPelsWidth == other.dmPelsWidth && saved.dmPelsHeight == other.dmPelsHeight);\n                    saved = virtual;\n                    saved.dmPelsWidth = desktop.dmPelsWidth;\n                    saved.dmPelsHeight = desktop.dmPelsHeight;\n                    write_source_mode( source->key, ENUM_REGISTRY_SETTINGS, &saved );\n                    if (was_other && virtual.dmPelsWidth == other.dmPelsWidth && virtual.dmPelsHeight == other.dmPelsHeight)\n                    {\n                        virtual.dmPelsWidth = desktop.dmPelsWidth;\n                        virtual.dmPelsHeight = desktop.dmPelsHeight;\n                    }\n                }\n            }\n        }\n    }\n')])

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
# 4v. Vulkan swapchains whose size differs from the window's layer on screen: an emulated desktop or display mode larger
#     than the screen (Tessera's full-resolution desktop, resolutions above the desktop) or DPI scaling. MoltenVK then
#     calls every present "suboptimal" and games recreate the swapchain endlessly (black window). Wine's cure, swapchains
#     created as deliberately scaled (VkSwapchainPresentScalingCreateInfo), never applied: the host's
#     VK_EXT_surface_maintenance1 was enabled only if the app's win32_surface flag was set, checked one line after that
#     flag is cleared. Enabled before it is cleared; every swapchain is created deliberately scaled when the host supports
#     it (keeping the app's own pNext chain, and not when the app sets its own scaling). Whether a swapchain still fits
#     its window stays Wine's own check at acquire and present.
exact("dlls/win32u/vulkan.c", [
    ("    driver_funcs->p_map_instance_extensions( &instance->obj.extensions );\n"
     "    instance->obj.extensions.has_VK_KHR_win32_surface = 0;\n",
     "    driver_funcs->p_map_instance_extensions( &instance->obj.extensions );\n"
     "    /* Tessera: decide on the host's surface_maintenance1 while the app's win32_surface request is still known\n"
     "     * (it is cleared next; checked afterwards, the extension was never enabled and swapchains could not be created\n"
     "     * as deliberately scaled). */\n"
     "    if (instance->obj.extensions.has_VK_KHR_win32_surface && vulkan_funcs.host_extensions.has_VK_EXT_surface_maintenance1)\n"
     "        instance->obj.extensions.has_VK_EXT_surface_maintenance1 = 1;\n"
     "    instance->obj.extensions.has_VK_KHR_win32_surface = 0;\n"),
    ("    if (instance->obj.extensions.has_VK_KHR_win32_surface && vulkan_funcs.host_extensions.has_VK_EXT_surface_maintenance1)\n"
     "        instance->obj.extensions.has_VK_EXT_surface_maintenance1 = 1;\n"
     "    if (use_external_memory())\n",
     "    if (use_external_memory())\n"),
    ("    VkSwapchainKHR host_swapchain;\n"
     "    RECT client_rect;\n"
     "    VkResult res;\n",
     "    VkSwapchainKHR host_swapchain;\n"
     "    VkResult res;\n"),
    ("    if (get_surface_rect( surface->hwnd, &client_rect, NtUserGetWinMonitorDpi( surface->hwnd, MDT_RAW_DPI ) ) &&\n"
     "        !extents_equals( &create_info_host.imageExtent, &client_rect ) &&\n"
     "        instance->extensions.has_VK_EXT_surface_maintenance1 &&\n"
     "        physical_device->extensions.has_VK_KHR_swapchain_maintenance1)\n",
     "    /* Tessera: MoltenVK reports \"suboptimal\" whenever the swapchain differs from the layer's own size on screen,\n"
     "     * which it measures in screen pixels; a desktop emulated larger than the screen (or DPI scaling) always\n"
     "     * differs, and games then recreate the swapchain endlessly (black window). Every swapchain is created as\n"
     "     * deliberately scaled; whether it still matches its window is decided below, in Wine's own size check at\n"
     "     * acquire and present, which compares in the window's coordinates. */\n"
     "    if (instance->extensions.has_VK_EXT_surface_maintenance1 &&\n"
     "        (physical_device->extensions.has_VK_KHR_swapchain_maintenance1 ||\n"
     "         physical_device->extensions.has_VK_EXT_swapchain_maintenance1) &&\n"
     "        !find_next_struct( (const VkBaseInStructure *)create_info->pNext, VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_SCALING_CREATE_INFO_EXT ))\n"),
    ("        scaling.scalingBehavior = VK_PRESENT_SCALING_STRETCH_BIT_EXT;\n"
     "        create_info_host.pNext = &scaling;\n",
     "        scaling.scalingBehavior = VK_PRESENT_SCALING_STRETCH_BIT_EXT;\n"
     "        scaling.pNext = (void *)create_info_host.pNext;     /* the app's own structures stay in the chain */\n"
     "        create_info_host.pNext = &scaling;\n"),
])

# 4x. DXVK games load the MoltenVK made for DXVK (lib64/dxvk). Wine loads the Vulkan library named in
#     TESSERA_LIBVULKAN, but only for the WineD3D backend; macOS ignores DYLD_LIBRARY_PATH for Wine's signed loader,
#     so the variable is the only way to pick another MoltenVK. It now applies on the DXVK backend too.
exact("dlls/win32u/vulkan.c", [
    ('        strcmp( graphics_backend, "wined3d" ))\n'
     '        libvulkan = SONAME_LIBVULKAN;\n',
     '        (strcmp( graphics_backend, "wined3d" ) && strcmp( graphics_backend, "dxvk" )))  /* Tessera: DXVK too */\n'
     '        libvulkan = SONAME_LIBVULKAN;\n'),
])

# 4y. D3DMetal presents the Mac's GPU to most games as an AMD card and writes the driver version "30.0.15.1233" into
#     the GPU's driver key (Control\Video\{gpu}\0000 links to Control\Class\{display}\0000). Unreal Engine 5 compares
#     an AMD driver's version with its list of drivers known to have bugs ("<30.0.14011.2006") and stops every start
#     with "The installed version of the AMD graphics driver has known issues in D3D12" (Chained Together, BIGFOOT).
#     That value gets the AMD driver version Wine itself writes there (win32u/sysparams.c), the one games see under
#     Proton on AMD cards, unless D3DM_VENDOR_ID makes D3DMetal present another vendor.
exact("dlls/ntdll/unix/registry.c", [
    ("#include <stdarg.h>\n#include <string.h>\n", "#include <stdarg.h>\n#include <stdlib.h>\n#include <string.h>\n"),
    ("    if (name->Length > MAX_VALUE_LENGTH) return STATUS_INVALID_PARAMETER;\n"
     "\n"
     "    SERVER_START_REQ( set_key_value )\n",
     "    if (name->Length > MAX_VALUE_LENGTH) return STATUS_INVALID_PARAMETER;\n"
     "\n"
     "    if (type == REG_SZ && name->Length == 13 * sizeof(WCHAR))  /* Tessera: see patch-wine.py 4y */\n"
     "    {\n"
     "        static const WCHAR driver_versionW[] = {'D','r','i','v','e','r','V','e','r','s','i','o','n'};\n"
     "        static const WCHAR d3dmetal_versionW[] = {'3','0','.','0','.','1','5','.','1','2','3','3',0};\n"
     "        static const WCHAR amd_versionW[] = {'3','5','.','0','.','2','1','0','2','5','.','1','0','2','4',0};\n"
     "        const char *vendor = getenv( \"D3DM_VENDOR_ID\" );\n"
     "\n"
     "        if (!memcmp( name->Buffer, driver_versionW, sizeof(driver_versionW) ) &&\n"
     "            count >= sizeof(d3dmetal_versionW) - sizeof(WCHAR) && count <= sizeof(d3dmetal_versionW) &&\n"
     "            !memcmp( data, d3dmetal_versionW, sizeof(d3dmetal_versionW) - sizeof(WCHAR) ) &&\n"
     "            (!vendor || !vendor[0] || strtoul( vendor, NULL, 0 ) == 0x1002))\n"
     "        {\n"
     "            data = amd_versionW;\n"
     "            count = sizeof(amd_versionW);\n"
     "        }\n"
     "    }\n"
     "\n"
     "    SERVER_START_REQ( set_key_value )\n"),
])

# 4z. Chinese, Japanese and Korean text. Windows names its CJK fonts MS Gothic, SimSun, Microsoft YaHei, Malgun
#     Gothic...; a Mac has none of them, so Wine used Arial and every CJK character showed as a box - also in Tahoma,
#     MS Shell Dlg and the other UI fonts, whose fallback lists (FontLink\SystemLink) name those same fonts. Each name
#     now stands for the Mac font of that language (Hiragino Sans/Mincho, Heiti/Songti SC and TC, Apple SD Gothic Neo;
#     all part of macOS); the fallback lists then work too. wine.inf runs again in every Windows folder when it changes.
CJK_SUBSTITUTES = [
    ("MS Gothic", "Hiragino Sans W3"), ("MS PGothic", "Hiragino Sans W3"), ("MS UI Gothic", "Hiragino Sans W3"),
    ("MS Mincho", "Hiragino Mincho ProN W3"), ("MS PMincho", "Hiragino Mincho ProN W3"),
    ("Meiryo", "Hiragino Sans W3"), ("Meiryo UI", "Hiragino Sans W3"), ("Yu Gothic", "Hiragino Sans W3"),
    ("Yu Gothic UI", "Hiragino Sans W3"), ("Yu Mincho", "Hiragino Mincho ProN W3"),
    ("SimSun", "Songti SC"), ("NSimSun", "Songti SC"), ("SimHei", "Heiti SC"), ("KaiTi", "Songti SC"),
    ("FangSong", "Songti SC"), ("Microsoft YaHei", "Heiti SC"), ("Microsoft YaHei UI", "Heiti SC"),
    ("PMingLiU", "Songti TC"), ("MingLiU", "Songti TC"), ("Microsoft JhengHei", "Heiti TC"),
    ("Microsoft JhengHei UI", "Heiti TC"),
    ("Malgun Gothic", "Apple SD Gothic Neo"), ("Gulim", "Apple SD Gothic Neo"), ("GulimChe", "Apple SD Gothic Neo"),
    ("Dotum", "Apple SD Gothic Neo"), ("DotumChe", "Apple SD Gothic Neo"), ("Batang", "Apple SD Gothic Neo"),
    ("BatangChe", "Apple SD Gothic Neo"), ("Gungsuh", "Apple SD Gothic Neo"),
]
exact("loader/wine.inf.in", [
    ('[Fonts]\nHKLM,%FontSubStr%,"Arial Baltic,186",,"Arial,186"\n',
     "[Fonts]\n" + "".join(f'HKLM,%FontSubStr%,"{win}",,"{mac}"\n' for win, mac in CJK_SUBSTITUTES)
     + 'HKLM,%FontSubStr%,"Arial Baltic,186",,"Arial,186"\n'),
])

# 4aa. Decoded video from Wine's GStreamer media source came in plain memory buffers; Windows' decoders deliver 2D
#      buffers, and games that read a frame's lines through IMF2DBuffer / IMF2DBuffer2 got nothing (Capcom Arcade 2nd
#      Stadium: black movies and menus while the sound played). Raw video samples now go into a 2D buffer made from the
#      stream's media type (MFCreateMediaBufferFromMediaType); anything else keeps a plain buffer.
OLD_SEND_4AA = 'static HRESULT media_stream_send_sample(struct media_stream *stream, const struct wg_parser_buffer *wg_buffer, IUnknown *token)\n{\n    IMFSample *sample = NULL;\n    IMFMediaBuffer *buffer;\n    HRESULT hr;\n    BYTE *data;\n\n    if (FAILED(hr = MFCreateMemoryBuffer(wg_buffer->size, &buffer)))\n        return hr;\n'
NEW_SEND_4AA = "/* Tessera: decoded video goes into a 2D buffer, the way Windows' decoders deliver it. Games find a frame's lines through\n * IMF2DBuffer (Capcom Arcade 2nd Stadium: without it its movies and everything after them stay black while the sound\n * plays); compressed data, audio and frames whose size does not match the media type keep a plain buffer. */\nstatic HRESULT media_stream_create_buffer(struct media_stream *stream, DWORD size, IMFMediaBuffer **buffer)\n{\n    IMFMediaTypeHandler *handler;\n    IMFMediaType *type = NULL;\n    IMF2DBuffer *buffer_2d;\n    DWORD length = 0;\n    GUID major;\n\n    if (SUCCEEDED(IMFStreamDescriptor_GetMediaTypeHandler(stream->descriptor, &handler)))\n    {\n        IMFMediaTypeHandler_GetCurrentMediaType(handler, &type);\n        IMFMediaTypeHandler_Release(handler);\n    }\n    if (type)\n    {\n        if (SUCCEEDED(IMFMediaType_GetMajorType(type, &major)) && IsEqualGUID(&major, &MFMediaType_Video)\n                && SUCCEEDED(MFCreateMediaBufferFromMediaType(type, 0, 0, 0, buffer)))\n        {\n            if (SUCCEEDED(IMFMediaBuffer_QueryInterface(*buffer, &IID_IMF2DBuffer, (void **)&buffer_2d)))\n            {\n                IMF2DBuffer_GetContiguousLength(buffer_2d, &length);\n                IMF2DBuffer_Release(buffer_2d);\n            }\n            if (length == size)\n            {\n                IMFMediaType_Release(type);\n                return S_OK;\n            }\n            IMFMediaBuffer_Release(*buffer);\n        }\n        IMFMediaType_Release(type);\n    }\n    return MFCreateMemoryBuffer(size, buffer);\n}\n\nstatic HRESULT media_stream_send_sample(struct media_stream *stream, const struct wg_parser_buffer *wg_buffer, IUnknown *token)\n{\n    IMFSample *sample = NULL;\n    IMFMediaBuffer *buffer;\n    HRESULT hr;\n    BYTE *data;\n\n    if (FAILED(hr = media_stream_create_buffer(stream, wg_buffer->size, &buffer)))\n        return hr;\n"
exact("dlls/winegstreamer/media_source.c", [(OLD_SEND_4AA, NEW_SEND_4AA)])

# 4ab. macOS automount points (/home, /Network/Servers, /net): a Windows program that looked up a build path compiled
#      into it (VLC's gettext: /home/jenkins/.../locale.alias, Z:\home\jenkins\... on the Z: drive) made Wine read /home
#      to match the name case-insensitively, and macOS stopped the game behind "Steam.app would like to access files on
#      a network volume" (RUINER waited at its splash screen). Names that are not mounted in an automount point now
#      count as missing without touching the file system; mounted network homes and shares keep working.
AUTOMOUNT_4AB = r"""#ifdef __APPLE__
/* Tessera: macOS automount points (/home from auto_home; /Network/Servers and /net when /etc/auto_master sets them up).
 * Reading one, which Wine does to match a name case-insensitively, makes macOS ask "<app> would like to access files
 * on a network volume" and stops the thread until someone answers; looking up a name that is not mounted there makes
 * automountd ask the directory service too. Windows programs reach them through build paths compiled into them: the
 * gettext inside VLC's Windows build looks for /home/jenkins/.../share/locale/locale.alias, which is
 * Z:\home\jenkins\... on the Z: drive, and RUINER waited at its splash screen for that prompt. A path through an
 * automount point to a name that is not mounted there now counts as missing without touching the file system; homes
 * and shares that are mounted there keep working. */
struct automount_point
{
    const char *path;  /* how paths reach it: /home */
    size_t      len;
    const char *real;  /* the mount point: /System/Volumes/Data/home */
};
static struct automount_point *automount_points;
static int automount_count;
static pthread_once_t automount_once = PTHREAD_ONCE_INIT;

static struct statfs *get_mount_list( int *count )
{
    struct statfs *list = NULL;
    int n = getfsstat( NULL, 0, MNT_NOWAIT );

    *count = 0;
    if (n > 0 && (list = malloc( (n + 8) * sizeof(*list) )))
    {
        n = getfsstat( list, (n + 8) * sizeof(*list), MNT_NOWAIT );
        *count = n > 0 ? n : 0;
    }
    return list;
}

static void init_automount_points(void)
{
    static const char data_volume[] = "/System/Volumes/Data";
    const size_t data_len = sizeof(data_volume) - 1;
    struct statfs *list;
    int i, count;

    if (!(list = get_mount_list( &count ))) return;
    if ((automount_points = calloc( 2 * count + 1, sizeof(*automount_points) )))
    {
        for (i = 0; i < count; i++)
        {
            char *real;

            if (strcmp( list[i].f_fstypename, "autofs" ) || !(real = strdup( list[i].f_mntonname ))) continue;
            automount_points[automount_count].path = real;
            automount_points[automount_count].len = strlen( real );
            automount_points[automount_count++].real = real;
            /* the data volume's folders also show at /: /System/Volumes/Data/home is /home */
            if (!strncmp( real, data_volume, data_len ) && real[data_len] == '/')
            {
                automount_points[automount_count].path = real + data_len;
                automount_points[automount_count].len = strlen( real + data_len );
                automount_points[automount_count++].real = real;
            }
        }
    }
    free( list );
}

/* is something (a network home, a share) mounted at that name in the automount point? */
static BOOL automount_name_mounted( const struct automount_point *am, const char *name, size_t len )
{
    size_t real_len = strlen( am->real );
    struct statfs *list;
    int i, count;
    BOOL ret = FALSE;

    if (!(list = get_mount_list( &count ))) return TRUE;  /* can't tell: leave the path alone */
    for (i = 0; i < count && !ret; i++)
    {
        const char *m = list[i].f_mntonname;

        ret = !strncmp( m, am->real, real_len ) && m[real_len] == '/' &&
              !strncasecmp( m + real_len + 1, name, len ) && (!m[real_len + 1 + len] || m[real_len + 1 + len] == '/');
    }
    free( list );
    return ret;
}

static NTSTATUS check_automount_path( const char *unix_name, UINT disposition )
{
    static const char dosdevices[] = "/dosdevices/";
    size_t config_len = strlen( config_dir );
    int i;

    pthread_once( &automount_once, init_automount_points );
    for (i = 0; i < automount_count; i++)
    {
        const struct automount_point *am = &automount_points[i];
        const char *p, *name, *end;

        /* the system volume ignores case: Z:\HOME\Jenkins reaches /home as well */
        for (p = unix_name; (p = strcasestr( p, am->path )); p += am->len)
        {
            if (p[am->len] != '/' || !p[am->len + 1] || p[am->len + 1] == '/') continue;
            /* only the root leads there: a plain Unix path, or a drive mapped to / (dosdevices/z: -> /); a game's own
             * folder called home is not looked at further */
            if (p > unix_name)
            {
                char link[2], *drive;
                ssize_t len = -1;

                if (p - unix_name != config_len + sizeof(dosdevices) + 1 || p[-1] != ':' ||
                    strncmp( unix_name, config_dir, config_len ) ||
                    strncmp( unix_name + config_len, dosdevices, sizeof(dosdevices) - 1 )) continue;
                if ((drive = strndup( unix_name, p - unix_name )))
                {
                    len = readlink( drive, link, sizeof(link) );
                    free( drive );
                }
                if (len != 1 || link[0] != '/') continue;
            }
            name = p + am->len + 1;
            if (!(end = strchr( name, '/' ))) end = name + strlen( name );
            if (automount_name_mounted( am, name, end - name )) continue;  /* mounted: real, look further on */
            TRACE( "%s: %.*s is not mounted in the macOS automount point %s, not looked up\n",
                   debugstr_a(unix_name), (int)(end - name), name, am->real );
            if (*end) return STATUS_OBJECT_PATH_NOT_FOUND;
            if (disposition == FILE_OPEN || disposition == FILE_OVERWRITE) return STATUS_OBJECT_NAME_NOT_FOUND;
            return STATUS_ACCESS_DENIED;
        }
    }
    return STATUS_SUCCESS;
}
#endif

"""
OLD_LOOKUP_4AB = "static NTSTATUS lookup_unix_name( int root_fd, OBJECT_ATTRIBUTES *attr, UNICODE_STRING *nt_name,\n"
OLD_SHORTCUT_4AB = r"""        for (p = unix_name + pos ; *p; p++) if (*p == '\\') *p = '/';
        if (!fstatat( root_fd, unix_name, &st, 0 ))
"""
NEW_SHORTCUT_4AB = r"""        for (p = unix_name + pos ; *p; p++) if (*p == '\\') *p = '/';
#ifdef __APPLE__
        if (root_fd == AT_FDCWD && (status = check_automount_path( unix_name, disposition ))) return status;
#endif
        if (!fstatat( root_fd, unix_name, &st, 0 ))
"""
# \??\unix\ paths (Wine's name for a plain Unix path) go through find_drive_nt_root, which stat()s each part of them
OLD_DRIVE_ROOT_4AB = "    /* strip off trailing slashes */\n    while (len > 1 && unix_name[len - 1] == '/') len--;\n    unix_name[len] = 0;\n\n    for (pos = len; pos; pos = remove_last_component( unix_name, pos ))\n"
NEW_DRIVE_ROOT_4AB = "    /* strip off trailing slashes */\n    while (len > 1 && unix_name[len - 1] == '/') len--;\n    unix_name[len] = 0;\n#ifdef __APPLE__\n    if ((status = check_automount_path( unix_name, disposition ))) return status;\n#endif\n\n    for (pos = len; pos; pos = remove_last_component( unix_name, pos ))\n"
exact("dlls/ntdll/unix/file.c", [(OLD_LOOKUP_4AB, AUTOMOUNT_4AB + OLD_LOOKUP_4AB), (OLD_SHORTCUT_4AB, NEW_SHORTCUT_4AB),
                                 (OLD_DRIVE_ROOT_4AB, NEW_DRIVE_ROOT_4AB)])

# 4ad. Wine's GStreamer parser hands a program one buffer per stream at a time, so a stream the program is not reading
#      stops at the queue after the demuxer. When the program waits for a stream whose next data lies further on in the
#      file, the demuxer has to queue the other stream's data in between, and decodebin allowed 8 MB: Capcom Arcade 2nd
#      Stadium's WMV movies (45 Mbit/s VC-1; ASF sends video up to its 5 s preroll ahead of the audio) filled it with
#      1.5 s of video while the game waited for audio, the demuxer stopped, and the movie froze after a few frames
#      (with the game waiting for it, black). Now up to 128 MB. A queue grows past 5 buffers only while another
#      stream's queue is empty, so ordinary playback keeps the small queue.
OLD_DECODEBIN_4AD = '    if (!(element = create_element("decodebin", "base")))\n        return FALSE;\n\n    gst_bin_add(GST_BIN(parser->container), element);\n    parser->decodebin = element;\n'
NEW_DECODEBIN_4AD = '    if (!(element = create_element("decodebin", "base")))\n        return FALSE;\n\n    /* Tessera: the queue after the demuxer may hold up to 128 MB of compressed data (decodebin: 8 MB). A stream the\n     * program is not reading stops there, and when the program waits for a stream whose next data lies further on in\n     * the file (ASF sends video up to its preroll, seconds, ahead of the audio), the data in between must fit: at\n     * 8 MB, 1.5 s of 45 Mbit/s video filled it and the demuxer stopped for good (Capcom Arcade 2nd Stadium\'s movies).\n     * A queue grows past 5 buffers only while another stream\'s queue is empty. */\n    g_object_set(element, "max-size-bytes", 128 * 1024 * 1024, NULL);\n\n    gst_bin_add(GST_BIN(parser->container), element);\n    parser->decodebin = element;\n'
exact("dlls/winegstreamer/wg_parser.c", [(OLD_DECODEBIN_4AD, NEW_DECODEBIN_4AD)])

# 4ae. BERSERK and the Band of the Hawk minimizes its fullscreen window, asks "Start the game in Windows 7 compatibility
#      mode?" in a message box the window owns, and restores itself only when it is activated after the question. While
#      MessageBox runs, its handler answers every activation (EndDialog's included) by showing the box again and
#      minimizing itself; when the box is destroyed Wine activates nothing (can_activate_window skips minimized windows
#      since Wine 11, bug 59010), so the game ran on minimized and Steam stayed in front until the player switched to it.
#      Now, when destroying the foreground popup leaves its thread with nothing active and the popup's owner is visible,
#      enabled and minimized, the owner is activated from the program's own message loop: posted, so it arrives after
#      MessageBox has returned, as a switch from the Dock or Cmd-Tab would. Popups hidden with their minimized owner
#      (bug 59010's case) are not destroyed and keep the owner minimized.
OLD_DESTROY_4AE = "        if (hwnd == info.hwndCaret) NtUserDestroyCaret();\n        if (hwnd == info.hwndActive) activate_other_window( hwnd );\n"
NEW_DESTROY_4AE = "        if (hwnd == info.hwndCaret) NtUserDestroyCaret();\n        if (hwnd == info.hwndActive)\n        {\n            HWND foreground = NtUserGetForegroundWindow();\n\n            activate_other_window( hwnd );\n            if (foreground == hwnd) defer_owner_activation( hwnd );\n        }\n"
OLD_NOTIFY_4AE = "/*******************************************************************\n *           send_parent_notify\n */\n"
NEW_NOTIFY_4AE = """/*******************************************************************
 *         defer_owner_activation
 *
 * Tessera: the foreground popup hwnd was destroyed and nothing is active. If its owner is minimized (a fullscreen game
 * that minimized itself for a message box it owns: BERSERK and the Band of the Hawk), the owner is activated once the
 * thread is back in its own message loop, after MessageBox has returned, as a switch from the Dock would. Activating
 * it here, inside MessageBox, makes such a game show the box again and minimize itself again.
 */
static void defer_owner_activation( HWND hwnd )
{
    HWND owner;
    DWORD style;

    if (get_active_window()) return;
    if (!(get_window_long( hwnd, GWL_STYLE ) & WS_POPUP)) return;
    if (!(owner = get_window_relative( hwnd, GW_OWNER ))) return;
    owner = NtUserGetAncestor( owner, GA_ROOT );
    style = get_window_long( owner, GWL_STYLE );
    if ((style & (WS_VISIBLE | WS_MINIMIZE | WS_DISABLED)) != (WS_VISIBLE | WS_MINIMIZE)) return;
    if (get_window_thread( owner, NULL ) != GetCurrentThreadId()) return;
    TRACE( "%p destroyed with nothing active: activating its minimized owner %p from the message loop\\n", hwnd, owner );
    NtUserPostMessage( owner, WM_WINE_SETACTIVEWINDOW, (WPARAM)owner, DEFERRED_OWNER_ACTIVATION );
}

/*******************************************************************
 *           send_parent_notify
 */
"""
OLD_HANDLER_4AE = "    case WM_WINE_SETACTIVEWINDOW:\n    {\n        HWND prev;\n\n        if (!wparam && NtUserGetForegroundWindow() == hwnd) return 0;\n"
NEW_HANDLER_4AE = """    case WM_WINE_SETACTIVEWINDOW:
    {
        HWND prev;

        if (lparam == DEFERRED_OWNER_ACTIVATION)
        {
            /* Tessera (window.c, defer_owner_activation): only if nothing was activated meanwhile and the window is
             * still visible, enabled and minimized */
            DWORD style = get_window_long( hwnd, GWL_STYLE );

            if (get_active_window() || (style & (WS_VISIBLE | WS_MINIMIZE | WS_DISABLED)) != (WS_VISIBLE | WS_MINIMIZE))
                return 0;
            TRACE( "activating minimized %p, whose popup was destroyed\\n", hwnd );
            if (!set_foreground_window( hwnd, FALSE, FALSE )) set_active_window( hwnd, NULL, FALSE, TRUE, 0 );
            return 0;
        }
        if (!wparam && NtUserGetForegroundWindow() == hwnd) return 0;
"""
OLD_PRIVATE_4AE = "extern BOOL set_foreground_window( HWND hwnd, BOOL mouse, BOOL force );\n"
NEW_PRIVATE_4AE = ("extern BOOL set_foreground_window( HWND hwnd, BOOL mouse, BOOL force );\n"
                   "/* Tessera: lparam of a posted WM_WINE_SETACTIVEWINDOW that activates a minimized owner after its popup was\n"
                   " * destroyed (window.c, defer_owner_activation); the usual lparam is a thread id, a multiple of 4 */\n"
                   "#define DEFERRED_OWNER_ACTIVATION 1\n")
exact("dlls/win32u/window.c", [(OLD_DESTROY_4AE, NEW_DESTROY_4AE), (OLD_NOTIFY_4AE, NEW_NOTIFY_4AE)])
exact("dlls/win32u/message.c", [(OLD_HANDLER_4AE, NEW_HANDLER_4AE)])
exact("dlls/win32u/win32u_private.h", [(OLD_PRIVATE_4AE, NEW_PRIVATE_4AE)])

# 4af. Programs that draw text through DirectWrite (WPF and other .NET launchers, Chromium-based ones) find fonts in
#      Wine's DirectWrite, which reads HKCU\Software\Wine\Fonts\Replacements but not 4z's FontSubstitutes. A Mac has no
#      Segoe UI, Windows' UI font and WPF's fallback for Cyrillic, Greek and most other scripts, so text that a
#      program's own font lacks came out as empty boxes (Borderlands 2 RU's launcher: its Compacta font has no
#      Cyrillic), and 4z's Chinese, Japanese and Korean names never reached DirectWrite. Segoe UI (and its weights) now
#      stands for Tahoma, Wine's own UI font (Latin, Greek, Cyrillic, Hebrew, Arabic, Thai), Segoe UI Symbol for Apple
#      Symbols, and 4z's CJK names for the same Mac fonts. GDI reads the same key for names a Mac does not have.
DWRITE_REPLACEMENTS = [("Segoe UI", "Tahoma"), ("Segoe UI Semibold", "Tahoma"), ("Segoe UI Semilight", "Tahoma"),
                       ("Segoe UI Light", "Tahoma"), ("Segoe UI Black", "Tahoma"), ("Segoe", "Tahoma"),
                       ("Segoe UI Symbol", "Apple Symbols"), ("Segoe UI Emoji", "Apple Color Emoji")] + CJK_SUBSTITUTES
exact("loader/wine.inf.in", [
    ("[Fonts]\n", "[Fonts]\n" + "".join(f'HKCU,Software\\Wine\\Fonts\\Replacements,"{win}",,"{mac}"\n'
                                        for win, mac in DWRITE_REPLACEMENTS)),
])


# 4ag. Colour emoji in programs that draw text with Chromium's Skia or other DirectWrite clients (BeamNG's launcher
#      showed its news emoji as empty boxes). A Mac's emoji font, Apple Color Emoji, keeps every emoji as PNG pictures
#      in an 'sbix' table; Wine's DirectWrite saw that the font has them but could not hand them out
#      (IDWriteFontFace4::GetGlyphImageFormats per glyph and GetGlyphImageData were stubs), and its fallback table sent
#      emoji nowhere. Now a glyph's picture comes from the nearest strike (with its size and origin, as Windows gives
#      a COLR/PNG emoji), and emoji ranges fall back to "Segoe UI Emoji" as on Windows, which 4af makes Apple Color Emoji.
OPENTYPE_SBIX_4AG = r"""/* Tessera: one glyph's PNG picture in an 'sbix' table (Apple Color Emoji keeps every emoji as PNG pictures in strikes
 * of 20 to 160 pixels per em), for IDWriteFontFace4::GetGlyphImageFormats and GetGlyphImageData: Chromium and other
 * Skia programs draw colour emoji from it. The strike is the smallest one of at least ppem_first pixels per em, else
 * the biggest (up to ppem_last); a 'dupe' record (the picture of another glyph) is followed once. With png NULL it
 * only says whether there is one; otherwise *context is the table's, released by ReleaseGlyphImageData. */
HRESULT opentype_get_sbix_glyph_png(IDWriteFontFace5 *fontface, UINT16 glyph, UINT32 ppem_first, UINT32 ppem_last,
        struct sbix_glyph_png *png, void **context)
{
    unsigned int num_glyphs, num_strikes, i, best_ppem = 0, best_size = 0, best_offset = 0;
    const struct sbix_glyph_data *best = NULL;
    const struct sbix_header *header;
    struct dwrite_fonttable table;

    memset(&table, 0, sizeof(table));
    table.exists = TRUE;
    if (!get_fontface_table(fontface, MS_MAXP_TAG, &table))
        return DWRITE_E_NOCOLOR;
    num_glyphs = table_read_be_word(&table, FIELD_OFFSET(struct maxp, num_glyphs));
    IDWriteFontFace5_ReleaseFontTable(fontface, table.context);
    if (glyph >= num_glyphs)
        return DWRITE_E_NOCOLOR;

    memset(&table, 0, sizeof(table));
    table.exists = TRUE;
    if (!get_fontface_table(fontface, MS_SBIX_TAG, &table))
        return DWRITE_E_NOCOLOR;

    num_strikes = table_read_be_dword(&table, FIELD_OFFSET(struct sbix_header, num_strikes));
    header = table_read_ensure(&table, 0, FIELD_OFFSET(struct sbix_header, strike_offset[num_strikes]));
    for (i = 0; header && i < num_strikes; ++i)
    {
        unsigned int strike_offset = GET_BE_DWORD(header->strike_offset[i]), strike_ppem, offset = 0, next = 0, dupe;
        const struct sbix_glyph_data *data = NULL;
        const struct sbix_strike *strike;
        UINT16 id = glyph;

        if (!(strike = table_read_ensure(&table, strike_offset,
                FIELD_OFFSET(struct sbix_strike, glyphdata_offsets[num_glyphs + 1]))))
            continue;
        strike_ppem = GET_BE_WORD(strike->ppem);
        if (strike_ppem > ppem_last)
            continue;
        for (dupe = 0; dupe < 2; ++dupe)
        {
            offset = GET_BE_DWORD(strike->glyphdata_offsets[id]);
            next = GET_BE_DWORD(strike->glyphdata_offsets[id + 1]);
            data = NULL;
            if (next <= offset + FIELD_OFFSET(struct sbix_glyph_data, data))
                break;
            if (!(data = table_read_ensure(&table, strike_offset + offset, next - offset)))
                break;
            if (data->graphic_type != MS_DUPE_TAG || next - offset < FIELD_OFFSET(struct sbix_glyph_data, data) + 2)
                break;
            id = GET_BE_WORD(*(const UINT16 *)data->data);
            data = NULL;
            if (id >= num_glyphs)
                break;
        }
        if (!data || data->graphic_type != MS_PNG__TAG)
            continue;
        if (!best || (strike_ppem >= ppem_first ? (best_ppem < ppem_first || strike_ppem < best_ppem)
                                               : (best_ppem < ppem_first && strike_ppem > best_ppem)))
        {
            best = data;
            best_ppem = strike_ppem;
            best_size = next - offset - FIELD_OFFSET(struct sbix_glyph_data, data);
            best_offset = strike_offset + offset;
        }
    }

    /* a PNG starts with its 8-byte signature and the IHDR chunk: length, "IHDR", width, height */
    if (!best || best_size < 24 || memcmp(best->data + 12, "IHDR", 4))
    {
        IDWriteFontFace5_ReleaseFontTable(fontface, table.context);
        return DWRITE_E_NOCOLOR;
    }
    if (!png)
    {
        IDWriteFontFace5_ReleaseFontTable(fontface, table.context);
        return S_OK;
    }
    png->data = best->data;
    png->size = best_size;
    png->ppem = best_ppem;
    png->width = GET_BE_DWORD(*(const UINT32 *)(best->data + 16));
    png->height = GET_BE_DWORD(*(const UINT32 *)(best->data + 20));
    png->origin_x = (INT16)GET_BE_WORD((UINT16)best->originOffsetX);
    png->origin_y = (INT16)GET_BE_WORD((UINT16)best->originOffsetY);
    png->unique_id = best_offset;
    *context = table.context;
    return S_OK;
}

"""
OLD_FORMATS_ANCHOR_4AG = "UINT32 opentype_get_glyph_image_formats(IDWriteFontFace5 *fontface)\n{\n"
OLD_TAG_4AG = "#define MS_PNG__TAG DWRITE_MAKE_OPENTYPE_TAG('p','n','g',' ')\n"
NEW_TAG_4AG = OLD_TAG_4AG + "#define MS_DUPE_TAG DWRITE_MAKE_OPENTYPE_TAG('d','u','p','e')\n"
OLD_PRIVATE_4AG = "extern UINT32 opentype_get_glyph_image_formats(IDWriteFontFace5 *fontface);\n"
NEW_PRIVATE_4AG = OLD_PRIVATE_4AG + r"""/* Tessera: a glyph's PNG picture in an 'sbix' table (opentype.c) */
struct sbix_glyph_png
{
    const BYTE *data;
    UINT32 size, ppem, width, height, unique_id;
    INT32 origin_x, origin_y;
};
extern HRESULT opentype_get_sbix_glyph_png(IDWriteFontFace5 *fontface, UINT16 glyph, UINT32 ppem_first,
        UINT32 ppem_last, struct sbix_glyph_png *png, void **context);
"""
OLD_GETFORMATS_4AG = r"""static HRESULT WINAPI dwritefontface4_GetGlyphImageFormats_(IDWriteFontFace5 *iface, UINT16 glyph,
    UINT32 ppem_first, UINT32 ppem_last, DWRITE_GLYPH_IMAGE_FORMATS *formats)
{
    FIXME("%p, %u, %u, %u, %p: stub\n", iface, glyph, ppem_first, ppem_last, formats);

    return E_NOTIMPL;
}
"""
NEW_GETFORMATS_4AG = r"""static HRESULT WINAPI dwritefontface4_GetGlyphImageFormats_(IDWriteFontFace5 *iface, UINT16 glyph,
    UINT32 ppem_first, UINT32 ppem_last, DWRITE_GLYPH_IMAGE_FORMATS *formats)
{
    struct dwrite_fontface *fontface = impl_from_IDWriteFontFace5(iface);

    TRACE("%p, %u, %u, %u, %p.\n", iface, glyph, ppem_first, ppem_last, formats);

    /* Tessera: the face's outline formats, and PNG when an 'sbix' strike in the range has a picture of this glyph
     * (Apple Color Emoji); other formats are not looked up per glyph */
    *formats = fontface->glyph_image_formats & (DWRITE_GLYPH_IMAGE_FORMATS_TRUETYPE | DWRITE_GLYPH_IMAGE_FORMATS_CFF);
    if ((fontface->glyph_image_formats & DWRITE_GLYPH_IMAGE_FORMATS_PNG) &&
            opentype_get_sbix_glyph_png(iface, glyph, ppem_first, ppem_last, NULL, NULL) == S_OK)
        *formats |= DWRITE_GLYPH_IMAGE_FORMATS_PNG;
    return S_OK;
}
"""
OLD_IMAGEDATA_4AG = r"""static HRESULT WINAPI dwritefontface4_GetGlyphImageData(IDWriteFontFace5 *iface, UINT16 glyph,
    UINT32 ppem, DWRITE_GLYPH_IMAGE_FORMATS format, DWRITE_GLYPH_IMAGE_DATA *data, void **context)
{
    FIXME("%p, %u, %u, %d, %p, %p: stub\n", iface, glyph, ppem, format, data, context);

    return E_NOTIMPL;
}

static void WINAPI dwritefontface4_ReleaseGlyphImageData(IDWriteFontFace5 *iface, void *context)
{
    FIXME("%p, %p: stub\n", iface, context);
}
"""
NEW_IMAGEDATA_4AG = r"""static HRESULT WINAPI dwritefontface4_GetGlyphImageData(IDWriteFontFace5 *iface, UINT16 glyph,
    UINT32 ppem, DWRITE_GLYPH_IMAGE_FORMATS format, DWRITE_GLYPH_IMAGE_DATA *data, void **context)
{
    struct dwrite_fontface *fontface = impl_from_IDWriteFontFace5(iface);
    DWRITE_GLYPH_METRICS metrics;
    struct sbix_glyph_png png;
    UINT32 advance;
    HRESULT hr;

    TRACE("%p, %u, %u, %d, %p, %p.\n", iface, glyph, ppem, format, data, context);

    memset(data, 0, sizeof(*data));
    *context = NULL;

    /* Tessera: PNG pictures from 'sbix' tables (Apple Color Emoji, which "Segoe UI Emoji" stands for on a Mac) */
    if (format != DWRITE_GLYPH_IMAGE_FORMATS_PNG)
    {
        FIXME("%p, %u, %u, %d: only PNG pictures are supported\n", iface, glyph, ppem, format);
        return E_NOTIMPL;
    }
    if (FAILED(hr = opentype_get_sbix_glyph_png(iface, glyph, ppem, ~0u, &png, context)))
        return hr;

    if (!fontface->metrics.designUnitsPerEm || FAILED(IDWriteFontFace5_GetDesignGlyphMetrics(iface, &glyph, 1, &metrics, FALSE)))
        advance = png.width;
    else
        advance = MulDiv(metrics.advanceWidth, png.ppem, fontface->metrics.designUnitsPerEm);

    data->imageData = png.data;
    data->imageDataSize = png.size;
    data->uniqueDataId = png.unique_id;
    data->pixelsPerEm = png.ppem;
    data->pixelSize.width = png.width;
    data->pixelSize.height = png.height;
    /* sbix gives the picture's left and bottom edges relative to the glyph origin, y up; DirectWrite wants the
     * origin inside the picture, y down */
    data->horizontalLeftOrigin.x = -png.origin_x;
    data->horizontalLeftOrigin.y = png.height + png.origin_y;
    data->horizontalRightOrigin.x = data->horizontalLeftOrigin.x + advance;
    data->horizontalRightOrigin.y = data->horizontalLeftOrigin.y;
    data->verticalTopOrigin.x = data->horizontalLeftOrigin.x + advance / 2;
    data->verticalTopOrigin.y = 0;
    data->verticalBottomOrigin.x = data->verticalTopOrigin.x;
    data->verticalBottomOrigin.y = png.height;
    return S_OK;
}

static void WINAPI dwritefontface4_ReleaseGlyphImageData(IDWriteFontFace5 *iface, void *context)
{
    TRACE("%p, %p.\n", iface, context);

    if (context)
        IDWriteFontFace5_ReleaseFontTable(iface, context);
}
"""
OLD_DINGBATS_4AG = '    { "2700-27BF",              L"Noto Sans Symbols2, Noto Sans Symbols 2" },\n'
NEW_DINGBATS_4AG = '    { "2700-27BF",              L"Noto Sans Symbols2, Noto Sans Symbols 2, Segoe UI Emoji, Segoe UI Symbol" },\n'
OLD_SYMBOLS2_4AG = '    { "1F800-1F8FF",            L"Noto Sans Symbols2, Noto Sans Symbols 2" },\n'
NEW_SYMBOLS2_4AG = ('    /* Tessera: emoji and symbols, as Windows maps them ("Segoe UI Emoji" and "Segoe UI Symbol" stand for Apple\n'
                    '       Color Emoji and Apple Symbols on a Mac, rule 4af) */\n'
                    '    { "2600-26FF",              L"Segoe UI Symbol, Segoe UI Emoji" },\n'
                    '    { "1F000-1F02F, 1F0A0-1F0FF, 1F100-1F1FF, 1F200-1F2FF, 1F300-1F5FF, 1F600-1F64F, 1F680-1F6FF, "\n'
                    '      "1F900-1F9FF, 1FA70-1FAFF", L"Segoe UI Emoji, Segoe UI Symbol" },\n' + OLD_SYMBOLS2_4AG)
exact("dlls/dwrite/opentype.c", [(OLD_TAG_4AG, NEW_TAG_4AG), (OLD_FORMATS_ANCHOR_4AG, OPENTYPE_SBIX_4AG + OLD_FORMATS_ANCHOR_4AG)])
exact("dlls/dwrite/dwrite_private.h", [(OLD_PRIVATE_4AG, NEW_PRIVATE_4AG)])
exact("dlls/dwrite/font.c", [(OLD_GETFORMATS_4AG, NEW_GETFORMATS_4AG), (OLD_IMAGEDATA_4AG, NEW_IMAGEDATA_4AG)])
exact("dlls/dwrite/analyzer.c", [(OLD_DINGBATS_4AG, NEW_DINGBATS_4AG), (OLD_SYMBOLS2_4AG, NEW_SYMBOLS2_4AG)])
# Also: a font of pictures only (Apple Color Emoji: fixed sizes, no scalable outlines) has no size of upem pixels, and
# Wine gave up on its design metrics there (FT_Set_Pixel_Sizes fails), so emoji had an advance of 0; unscaled metrics
# need no size.
OLD_METRICS_SIZE_4AG = "    if (!(size = freetype_set_face_size(face, params->upem)))\n        return STATUS_UNSUCCESSFUL;\n\n    if (!pFT_Load_Glyph(face, params->glyph, FT_LOAD_NO_SCALE))\n"
NEW_METRICS_SIZE_4AG = ("    /* Tessera: a font of pictures only (Apple Color Emoji) has no size of upem pixels; unscaled metrics need none */\n"
                        "    if (!(size = freetype_set_face_size(face, params->upem)) && FT_IS_SCALABLE(face))\n        return STATUS_UNSUCCESSFUL;\n\n"
                        "    if (!pFT_Load_Glyph(face, params->glyph, FT_LOAD_NO_SCALE))\n")
OLD_METRICS_DONE_4AG = "    pFT_Done_Size(size);\n\n    return STATUS_SUCCESS;\n}\n\nstruct decompose_context"
NEW_METRICS_DONE_4AG = "    if (size) pFT_Done_Size(size);\n\n    return STATUS_SUCCESS;\n}\n\nstruct decompose_context"
exact("dlls/dwrite/freetype.c", [(OLD_METRICS_SIZE_4AG, NEW_METRICS_SIZE_4AG), (OLD_METRICS_DONE_4AG, NEW_METRICS_DONE_4AG)])


# 4ah. pipe2() is new in macOS 27. Wine's configure finds it in the macOS 27 SDK (HAVE_PIPE2) and ntdll calls it for
#      the pipes to the Wine server in every process and thread; the runtime is built to run on older macOS too, where
#      the function is not there, and calling it stopped every Windows program at start ("game exited with 11", a
#      call through a null pointer) on every macOS before 27. Up to 1.2.10 no game started on macOS 14, 15 or 26.
#      Wine on a Mac now always uses pipe() and FD_CLOEXEC, as it did before macOS 27 existed. (GLib had the same
#      call: build-gstreamer.sh takes it out there. check-release.py now lists every such function.)
NO_PIPE2_4AH = ('#include "config.h"\n\n'
                '#ifdef __APPLE__\n'
                '/* Tessera: pipe2() is new in macOS 27; this code also runs on older macOS, where calling it is a call through a\n'
                ' * null pointer (every Windows program stopped at start). pipe() and FD_CLOEXEC work everywhere. */\n'
                '#undef HAVE_PIPE2\n'
                '#endif\n')
exact("dlls/ntdll/unix/server.c", [('#include "config.h"\n', NO_PIPE2_4AH)])
exact("dlls/ntdll/unix/process.c", [('#include "config.h"\n', NO_PIPE2_4AH)])


# 4ai. Cursor positions a game sets come back exactly, and movement after it is measured from there. On a desktop
#      that is larger than the Mac's (an emulated display mode above the Mac's desktop size, the default for
#      D3DMetal games: 4u), several of the game's pixels share one position of the real desktop. SetCursorPos(1728,
#      1117) on a 3456x2234 desktop became real position (1028,665), and that was reported back as (1728,1118), by
#      GetCursorPos and by every mouse message in that row. A game that puts the cursor back in the middle and reads
#      how far it has moved (mouse look without raw input) saw one pixel of downward movement that never happened,
#      with every mouse event; a program that re-centres until the cursor is in the middle never stopped. win32u
#      now remembers the last position set and the real position it became, and reports cursor positions shifted
#      by that rounding difference (at most a pixel or two): the set position comes back as it was set, and movement
#      from it is exact in both directions. (perf/tools/mousetest measures it.)
exact("dlls/win32u/win32u_private.h", [
    ('extern RECT map_rect_virt_to_raw( RECT rect, UINT dpi_from );\n',
     'extern RECT map_rect_virt_to_raw( RECT rect, UINT dpi_from );\n'
     'extern POINT map_cursor_pos_raw_to_virt( POINT raw, UINT dpi );\n')])
exact("dlls/win32u/input.c", [
    ('#include "ntstatus.h"\n#define WIN32_NO_STATUS\n#include "win32u_private.h"\n#include "ntuser_private.h"\n'
     '#include "wine/server.h"\n#include "wine/debug.h"\n#include "kbd.h"\n',
     '#include <pthread.h>\n\n'
     '#include "ntstatus.h"\n#define WIN32_NO_STATUS\n#include "win32u_private.h"\n#include "ntuser_private.h"\n'
     '#include "wine/server.h"\n#include "wine/debug.h"\n#include "kbd.h"\n'),
    ('/***********************************************************************\n'
     ' *\t     NtUserSetCursorPos (win32u.@)\n'
     ' */\n',
     '/* Tessera: the last position a program set with SetCursorPos, in its own coordinates, and the raw desktop\n'
     ' * position it became. Several program pixels can share one raw position (a desktop mode larger than the real\n'
     ' * desktop), so mapping raw positions back gave a neighbouring pixel: for the position just set, and for every\n'
     ' * mouse movement measured from it. */\n'
     'static pthread_mutex_t set_cursor_lock = PTHREAD_MUTEX_INITIALIZER;\n'
     'static POINT set_cursor_virt, set_cursor_raw;\n'
     'static UINT set_cursor_dpi;\n'
     'static BOOL set_cursor_valid;\n'
     '\n'
     'static UINT cursor_effective_dpi( UINT dpi )\n'
     '{\n'
     '    return dpi ? dpi : get_system_dpi();\n'
     '}\n'
     '\n'
     '/* maps a raw cursor position to the coordinates programs see. While the cursor position a program set is\n'
     ' * remembered, positions are shifted by the rounding difference of that position, so that it comes back\n'
     ' * exactly as it was set and movement is measured from it. */\n'
     'POINT map_cursor_pos_raw_to_virt( POINT raw, UINT dpi )\n'
     '{\n'
     '    RECT rect = {raw.x, raw.y, raw.x, raw.y}, anchor, virtual_rect;\n'
     '    POINT pos, virt, anchor_raw, bias;\n'
     '    BOOL valid;\n'
     '\n'
     '    rect = map_rect_raw_to_virt( rect, dpi );\n'
     '    pos.x = rect.left;\n'
     '    pos.y = rect.top;\n'
     '\n'
     '    pthread_mutex_lock( &set_cursor_lock );\n'
     '    valid = set_cursor_valid && cursor_effective_dpi( dpi ) == set_cursor_dpi;\n'
     '    virt = set_cursor_virt;\n'
     '    anchor_raw = set_cursor_raw;\n'
     '    pthread_mutex_unlock( &set_cursor_lock );\n'
     '    if (!valid) return pos;\n'
     '\n'
     '    /* does the remembered pair still hold for the display mode of this moment? */\n'
     '    SetRect( &anchor, virt.x, virt.y, virt.x, virt.y );\n'
     '    anchor = map_rect_virt_to_raw( anchor, dpi );\n'
     '    if (anchor.left != anchor_raw.x || anchor.top != anchor_raw.y) return pos;\n'
     '\n'
     '    SetRect( &anchor, anchor_raw.x, anchor_raw.y, anchor_raw.x, anchor_raw.y );\n'
     '    anchor = map_rect_raw_to_virt( anchor, dpi );\n'
     '    bias.x = anchor.left - virt.x;\n'
     '    bias.y = anchor.top - virt.y;\n'
     '    if (!bias.x && !bias.y) return pos;\n'
     '    if (abs( bias.x ) > 4 || abs( bias.y ) > 4) return pos;\n'
     '\n'
     '    virtual_rect = get_virtual_screen_rect( dpi, MDT_DEFAULT );\n'
     '    pos.x = max( virtual_rect.left, min( virtual_rect.right - 1, pos.x - bias.x ));\n'
     '    pos.y = max( virtual_rect.top, min( virtual_rect.bottom - 1, pos.y - bias.y ));\n'
     '    return pos;\n'
     '}\n'
     '\n'
     '/***********************************************************************\n'
     ' *\t     NtUserSetCursorPos (win32u.@)\n'
     ' */\n'),
    ('    SERVER_END_REQ;\n'
     '    if (ret && (prev_x != new_x || prev_y != new_y)) user_driver->pSetCursorPos( new_x, new_y );\n'
     '    return ret;\n',
     '    SERVER_END_REQ;\n'
     '    if (ret)\n'
     '    {\n'
     '        /* Tessera: remembered only when the cursor went exactly there (not held back by a clip rectangle) */\n'
     '        pthread_mutex_lock( &set_cursor_lock );\n'
     '        set_cursor_valid = new_x == rect.left && new_y == rect.top;\n'
     '        set_cursor_virt.x = x;\n'
     '        set_cursor_virt.y = y;\n'
     '        set_cursor_raw.x = new_x;\n'
     '        set_cursor_raw.y = new_y;\n'
     '        set_cursor_dpi = cursor_effective_dpi( get_thread_dpi() );\n'
     '        pthread_mutex_unlock( &set_cursor_lock );\n'
     '    }\n'
     '    if (ret && (prev_x != new_x || prev_y != new_y)) user_driver->pSetCursorPos( new_x, new_y );\n'
     '    return ret;\n'),
    ('    if (!ret) return FALSE;\n'
     '\n'
     '    SetRect( &rect, pt->x, pt->y, pt->x, pt->y );\n'
     '    rect = map_rect_raw_to_virt( rect, get_thread_dpi() );\n'
     '    *pt = *(POINT *)&rect.left;\n'
     '    return ret;\n',
     '    if (!ret) return FALSE;\n'
     '\n'
     '    *pt = map_cursor_pos_raw_to_virt( *pt, get_thread_dpi() );   /* Tessera: see NtUserSetCursorPos */\n'
     '    return ret;\n')])
exact("dlls/win32u/message.c", [
    ('    rect = map_rect_raw_to_virt( rect, get_thread_dpi() );\n'
     '    msg->pt.x = rect.left;\n'
     '    msg->pt.y = rect.top;\n'
     '\n'
     '    if (msg->message == WM_INPUT || msg->message == WM_INPUT_DEVICE_CHANGE)\n',
     '    /* Tessera: measured from the position the program last set itself (see NtUserSetCursorPos) */\n'
     '    msg->pt = map_cursor_pos_raw_to_virt( msg->pt, get_thread_dpi() );\n'
     '\n'
     '    if (msg->message == WM_INPUT || msg->message == WM_INPUT_DEVICE_CHANGE)\n')])


# 4aj. Crackling sound. macOS collects sound from a program in chunks (512 frames at a time at 44.1 or 48 kHz: 10.7
#      ms). Wine's CoreAudio driver hands over what the game has queued and fills the rest of the chunk with silence.
#      A game that queues one 10 ms period at a time (480 frames) is regularly a few frames short of a 512-frame
#      chunk, and each of those gaps is a click: the crackle people cure by switching the Mac's output to 96 kHz in
#      Audio MIDI Setup (there one chunk is 5.3 ms, so the game always has enough). The driver now asks macOS for
#      chunks of that length itself, at any sample rate (256 frames up to 48 kHz), so no system setting has to
#      change. TESSERA_AUDIO_IO_FRAMES=0 leaves macOS's size, a number sets one; TESSERA_AUDIO_LOG=<file> writes how
#      many chunks came up short (start / every 5 s / end of each sound stream).
exact("dlls/winecoreaudio.drv/coreaudio.c", [
    ('#include <os/lock.h>\n', '#include <os/lock.h>\n#include <pthread.h>\n'),
    ('    WAVEFORMATEX *fmt;\n'
     '    BYTE *local_buffer, *cap_buffer, *wrap_buffer, *resamp_buffer, *tmp_buffer;\n'
     '};\n',
     '    WAVEFORMATEX *fmt;\n'
     '    BYTE *local_buffer, *cap_buffer, *wrap_buffer, *resamp_buffer, *tmp_buffer;\n'
     '\n'
     '    /* Tessera: the size of the chunks macOS collects, and how often the game had less than a chunk queued */\n'
     '    UINT32 io_frames, io_frames_before, max_pull_frames;\n'
     '    UINT64 pulls, short_pulls, short_frames, empty_pulls, writes;\n'
     '    double last_log;\n'
     '};\n'),
    ('/* CA is pulling data from us */\n'
     'static OSStatus ca_render_cb(',
     '/* Tessera: TESSERA_AUDIO_LOG=<file> */\n'
     'static FILE *tessera_audio_file;\n'
     '\n'
     'static void tessera_open_audio_log(void)\n'
     '{\n'
     '    const char *path = getenv("TESSERA_AUDIO_LOG");\n'
     '    if(path && *path) tessera_audio_file = fopen(path, "a");\n'
     '}\n'
     '\n'
     'static FILE *tessera_audio_log(void)\n'
     '{\n'
     '    static pthread_once_t once = PTHREAD_ONCE_INIT;\n'
     '\n'
     '    pthread_once(&once, tessera_open_audio_log);\n'
     '    return tessera_audio_file;\n'
     '}\n'
     '\n'
     'static double tessera_audio_now(void)\n'
     '{\n'
     '    struct timespec ts;\n'
     '    clock_gettime(CLOCK_UPTIME_RAW, &ts);\n'
     '    return ts.tv_sec + ts.tv_nsec / 1e9;\n'
     '}\n'
     '\n'
     'static void tessera_log_stream(struct coreaudio_stream *stream, const char *what)\n'
     '{\n'
     '    FILE *file = tessera_audio_log();\n'
     '\n'
     '    if(!file || stream->flow != eRender) return;\n'
     '    fprintf(file, "%s %.3f stream %p: game %u Hz %u ch, device %.0f Hz, chunk %u frames (macOS had %u, largest seen %u), "\n'
     '            "game period %u, buffer %u | chunks %llu, short %llu (%llu frames of silence), nothing queued %llu, writes %llu\\n",\n'
     '            what, tessera_audio_now(), stream, (unsigned)stream->fmt->nSamplesPerSec, (unsigned)stream->fmt->nChannels,\n'
     '            stream->dev_desc.mSampleRate, (unsigned)stream->io_frames, (unsigned)stream->io_frames_before,\n'
     '            (unsigned)stream->max_pull_frames, (unsigned)stream->period_frames, (unsigned)stream->bufsize_frames,\n'
     '            (unsigned long long)stream->pulls, (unsigned long long)stream->short_pulls,\n'
     '            (unsigned long long)stream->short_frames, (unsigned long long)stream->empty_pulls,\n'
     '            (unsigned long long)stream->writes);\n'
     '    fflush(file);\n'
     '}\n'
     '\n'
     '/* Tessera: asks macOS for chunks of about 5.3 ms (256 frames up to 48 kHz, 512 up to 96 kHz), the length that\n'
     ' * the 96 kHz setting gives. A game that queues 10 ms of sound at a time then always has a full chunk ready. */\n'
     'static void tessera_set_io_frames(struct coreaudio_stream *stream)\n'
     '{\n'
     '    const char *env = getenv("TESSERA_AUDIO_IO_FRAMES");\n'
     '    UInt32 frames = 256, current = 0, size = sizeof(current), range_size;\n'
     '    AudioValueRange range = {0, 0};\n'
     '    Float64 rate = stream->dev_desc.mSampleRate > 0 ? stream->dev_desc.mSampleRate : 48000;\n'
     '    OSStatus sc;\n'
     '\n'
     '    if(AudioUnitGetProperty(stream->unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,\n'
     '                            &current, &size) != noErr)\n'
     '        current = 0;\n'
     '    stream->io_frames = stream->io_frames_before = current;\n'
     '\n'
     '    if(env && atoi(env) <= 0) return;   /* macOS\'s own size */\n'
     '    if(env) frames = atoi(env);\n'
     '    else while(rate > 48000.5 * (frames / 256)) frames *= 2;\n'
     '\n'
     '    range_size = sizeof(range);\n'
     '    if(AudioUnitGetProperty(stream->unit, kAudioDevicePropertyBufferFrameSizeRange, kAudioUnitScope_Global, 0,\n'
     '                            &range, &range_size) == noErr && range.mMinimum > 0){\n'
     '        if(frames < range.mMinimum) frames = range.mMinimum;\n'
     '        if(frames > range.mMaximum) frames = range.mMaximum;\n'
     '    }\n'
     '    if(!env && current && current <= frames) return;   /* short enough already */\n'
     '\n'
     '    sc = AudioUnitSetProperty(stream->unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,\n'
     '                              &frames, sizeof(frames));\n'
     '    if(sc != noErr){\n'
     '        WARN("Couldn\'t set the device buffer to %u frames: %x\\n", (unsigned)frames, (int)sc);\n'
     '        return;\n'
     '    }\n'
     '    size = sizeof(current);\n'
     '    if(AudioUnitGetProperty(stream->unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,\n'
     '                            &current, &size) == noErr)\n'
     '        stream->io_frames = current;\n'
     '}\n'
     '\n'
     '/* CA is pulling data from us */\n'
     'static OSStatus ca_render_cb('),
    ('    if(stream->playing){\n'
     '        lcl_offs_bytes = stream->lcl_offs_frames * stream->fmt->nBlockAlign;\n'
     '        to_copy_frames = min(nframes, stream->held_frames);\n',
     '    if(stream->playing){\n'
     '        /* Tessera: counted for TESSERA_AUDIO_LOG; a chunk the game could only partly fill is a click */\n'
     '        stream->pulls++;\n'
     '        if(nframes > stream->max_pull_frames) stream->max_pull_frames = nframes;\n'
     '        if(!stream->held_frames) stream->empty_pulls++;\n'
     '        else if(nframes > stream->held_frames){\n'
     '            stream->short_pulls++;\n'
     '            stream->short_frames += nframes - stream->held_frames;\n'
     '        }\n'
     '\n'
     '        lcl_offs_bytes = stream->lcl_offs_frames * stream->fmt->nBlockAlign;\n'
     '        to_copy_frames = min(nframes, stream->held_frames);\n'),
    ('    sc = AudioUnitInitialize(stream->unit);\n',
     '    if(stream->flow == eRender) tessera_set_io_frames(stream);   /* Tessera: short chunks, no crackle */\n'
     '\n'
     '    sc = AudioUnitInitialize(stream->unit);\n'),
    ('        stream->cap_buffer = malloc(stream->cap_bufsize_frames * stream->fmt->nBlockAlign);\n'
     '    }\n'
     '    params->result = S_OK;\n',
     '        stream->cap_buffer = malloc(stream->cap_bufsize_frames * stream->fmt->nBlockAlign);\n'
     '    }\n'
     '    params->result = S_OK;\n'
     '    tessera_log_stream(stream, "start");\n'),
    ('    if(params->timer_thread){\n'
     '        stream->please_quit = TRUE;\n'
     '        NtWaitForSingleObject(params->timer_thread, FALSE, NULL);\n'
     '        NtClose(params->timer_thread);\n'
     '    }\n'
     '\n'
     '    if(stream->unit){\n'
     '        AudioOutputUnitStop(stream->unit);\n',
     '    if(params->timer_thread){\n'
     '        stream->please_quit = TRUE;\n'
     '        NtWaitForSingleObject(params->timer_thread, FALSE, NULL);\n'
     '        NtClose(params->timer_thread);\n'
     '    }\n'
     '    tessera_log_stream(stream, "end");\n'
     '\n'
     '    if(stream->unit){\n'
     '        AudioOutputUnitStop(stream->unit);\n'),
    ('        stream->held_frames += params->written_frames;\n'
     '        stream->written_frames += params->written_frames;\n'
     '        stream->getbuf_last = 0;\n'
     '\n'
     '        params->result = S_OK;\n'
     '    }\n'
     '\n'
     '    os_unfair_lock_unlock(&stream->lock);\n'
     '\n'
     '    return STATUS_SUCCESS;\n'
     '}\n',
     '        stream->held_frames += params->written_frames;\n'
     '        stream->written_frames += params->written_frames;\n'
     '        stream->getbuf_last = 0;\n'
     '        stream->writes++;\n'
     '\n'
     '        params->result = S_OK;\n'
     '    }\n'
     '\n'
     '    os_unfair_lock_unlock(&stream->lock);\n'
     '\n'
     '    if(tessera_audio_log()){\n'
     '        double now = tessera_audio_now();\n'
     '        if(now - stream->last_log >= 5.0){\n'
     '            stream->last_log = now;\n'
     '            tessera_log_stream(stream, "run");\n'
     '        }\n'
     '    }\n'
     '\n'
     '    return STATUS_SUCCESS;\n'
     '}\n')])


# 4ak. Mouse look also for games that only keep putting the cursor back. 4o/4p treat "cursor hidden and captured
#      (ClipCursor)" as mouse look. Many games never capture the cursor: they hide it and call SetCursorPos(middle)
#      after every mouse event or frame (The Last of Us Part I: 160 put-backs for 160 events). For those, Wine threw
#      away every mouse event that reached it before the put-back was done, and the put-back wiped that movement from
#      the cursor too: measured with perf/tools/mousetest, a game handling its messages at 90 fps got 64 % of the
#      movement of a 125 Hz mouse and 60 % of a 1000 Hz mouse (the view turns less than the hand moved, and unevenly).
#      Now a hidden cursor that is put back on the same spot three times counts as mouse look as long as the
#      put-backs keep coming (0.5 s): movement is delivered as movement, nothing is dropped, and the game does not wait
#      for the put-back. With a visible cursor, or once the put-backs stop (menus), positions are used as before.
exact("dlls/winemac.drv/cocoa_app.h", [
    ('@property (readonly) BOOL cursorHiddenByClient;   /* Tessera: the Windows program asked to hide the cursor */',
     '@property (readonly) BOOL cursorHiddenByClient;   /* Tessera: the Windows program asked to hide the cursor */\n'
     '@property (readonly) BOOL mouseLook;              /* Tessera: hidden cursor that is captured or kept on one spot */')])
exact("dlls/winemac.drv/cocoa_app.m", [
    ('    - (BOOL) cursorHiddenByClient\n    {\n        return clientWantsCursorHidden;\n    }\n',
     '    - (BOOL) cursorHiddenByClient\n    {\n        return clientWantsCursorHidden;\n    }\n'
     '\n'
     '    /* Tessera: the Windows program steers with the mouse. It hides the cursor and either captures it (ClipCursor)\n'
     '       or keeps putting it back on one spot: three put-backs on the same spot, and the last one no longer than\n'
     '       half a second ago (they come with every mouse event while the mouse moves; one event after a rest is\n'
     '       handled the old way and its put-back switches mouse look on again). */\n'
     '    - (BOOL) mouseLook\n'
     '    {\n'
     '        if (!clientWantsCursorHidden) return FALSE;\n'
     '        if (self.clippingCursor) return TRUE;\n'
     '        return tessera_put_backs_recent();\n'
     '    }\n'),
    ('            // Discard all pending mouse move events (Tessera: in mouse look only positions; movement is kept).\n'
     '            BOOL mouseLook = self.clippingCursor && clientWantsCursorHidden;\n',
     '            // Discard all pending mouse move events (Tessera: in mouse look only positions; movement is kept).\n'
     '            BOOL mouseLook = self.mouseLook;\n'),
    ('            BOOL mouseLook = self.clippingCursor && clientWantsCursorHidden;\n'
     '            static BOOL mouseLookEventsUncoalesced;\n',
     '            BOOL mouseLook = self.mouseLook;\n'
     '            static BOOL mouseLookEventsUncoalesced;\n'),
    ('    if (controller.clippingCursor && controller.cursorHiddenByClient)\n    {\n        OnMainThreadAsync(^{',
     '    tessera_note_put_back(cgpoint_mac_from_win(pos));\n'
     '    if (controller.mouseLook)\n    {\n        OnMainThreadAsync(^{'),
    ('#import "cocoa_app.h"\n', '#import <os/lock.h>\n#import "cocoa_app.h"\n'),
    ('@implementation WineApplicationController\n',
     '/* Tessera: the last spot the Windows program put the cursor on, when, and how often in a row (see -mouseLook).\n'
     '   Written by the program\'s thread that calls SetCursorPos, read by the main thread. */\n'
     'static os_unfair_lock tesseraPutBackLock = OS_UNFAIR_LOCK_INIT;\n'
     'static CGPoint tesseraPutBackPoint;\n'
     'static NSTimeInterval tesseraPutBackTime;\n'
     'static int tesseraPutBackStreak;\n'
     '\n'
     'static void tessera_note_put_back(CGPoint pos)\n'
     '{\n'
     '    os_unfair_lock_lock(&tesseraPutBackLock);\n'
     '    if (fabs(pos.x - tesseraPutBackPoint.x) <= 2 && fabs(pos.y - tesseraPutBackPoint.y) <= 2)\n'
     '    {\n'
     '        if (tesseraPutBackStreak < 1000) tesseraPutBackStreak++;\n'
     '    }\n'
     '    else\n'
     '        tesseraPutBackStreak = 1;\n'
     '    tesseraPutBackPoint = pos;\n'
     '    tesseraPutBackTime = [[NSProcessInfo processInfo] systemUptime];\n'
     '    os_unfair_lock_unlock(&tesseraPutBackLock);\n'
     '}\n'
     '\n'
     '/* three put-backs on one spot, the last one no longer than half a second ago */\n'
     'static BOOL tessera_put_backs_recent(void)\n'
     '{\n'
     '    BOOL ret;\n'
     '    os_unfair_lock_lock(&tesseraPutBackLock);\n'
     '    ret = tesseraPutBackStreak >= 3 &&\n'
     '          [[NSProcessInfo processInfo] systemUptime] - tesseraPutBackTime < 0.5;\n'
     '    os_unfair_lock_unlock(&tesseraPutBackLock);\n'
     '    return ret;\n'
     '}\n'
     '\n'
     '@implementation WineApplicationController\n')])

# 4al. Windows larger than the Mac's desktop can be drawn into completely. A window's drawing surface is cropped to
#      the screen ("some applications create huge windows"), but Wine compared the window, measured in the pixels of
#      the desktop the program sees, with the screen measured in real pixels. That is the same thing until the
#      desktop is an emulated mode LARGER than the real one - Tessera's default for D3DMetal games (4u: 3456x2234 over
#      the Mac's 2056x1329). There every window above 2056x1329 could only be drawn into its top-left part: a
#      maximized 3454x2116 window got 2176x1280, a whole-screen one 2176x1408 (perf/tools/metrics/winclip). Games
#      drawing through Direct3D were not affected, programs drawing through GDI were: Assetto Corsa's launcher showed
#      its page in the top-left corner with a white margin. The crop now uses whichever screen measure is larger.
exact("dlls/win32u/window.c", [
    ('static BOOL get_surface_rect( const RECT *visible_rect, RECT *surface_rect )\n'
     '{\n'
     '    RECT virtual_rect = get_virtual_screen_rect( 0, MDT_RAW_DPI );\n',
     'static BOOL get_surface_rect( const RECT *visible_rect, RECT *surface_rect )\n'
     '{\n'
     '    RECT virtual_rect = get_virtual_screen_rect( 0, MDT_RAW_DPI );\n'
     '    /* Tessera: the window is measured in the desktop the program sees; when that desktop is an emulated mode\n'
     '       larger than the real one, the real screen is the smaller measure and must not crop the window */\n'
     '    RECT seen_rect = get_virtual_screen_rect( get_thread_dpi(), MDT_DEFAULT );\n'
     '\n'
     '    virtual_rect.left   = min( virtual_rect.left, seen_rect.left );\n'
     '    virtual_rect.top    = min( virtual_rect.top, seen_rect.top );\n'
     '    virtual_rect.right  = max( virtual_rect.right, seen_rect.right );\n'
     '    virtual_rect.bottom = max( virtual_rect.bottom, seen_rect.bottom );\n')])

# 4am. A game may keep up to 20 ms of sound queued, not only 10. IAudioClient3 lets a game ask how long the sound
#      engine's period may be; Wine answered "10 ms at most" (its default period). Godot 4 asks for its own
#      setting (15 ms), is cut down to 10, and then never keeps more than that queued. Windows empties a stream
#      once per 10 ms, so a game has the whole period to refill; macOS pulls every 5.3 ms (4aj), so two pulls
#      without a refill between them left the second one 0.7 ms short: Buckshot Roulette lost 8 to 49 chunks at
#      each start, whenever its sound thread was more than 5 ms late while the game loaded. With 20 ms allowed
#      Godot gets the 15 ms it asks for and a late thread has 10.7 ms, as on Windows.
exact("dlls/mmdevapi/client.c", [
    ('    *max_period_frames     = *default_period_frames;\n',
     '    /* Tessera: twice the default period, so a game that asks for more than 10 ms (Godot 4: 15 ms) gets it;\n'
     '       the game keeps one period queued, and macOS pulls in smaller chunks than a Windows period */\n'
     '    *max_period_frames     = 2 * *default_period_frames;\n')])

# 4an. Dialogs are as large on the full-resolution desktop as on the Mac's own. A D3DMetal game's desktop is the
#      screen's largest real mode (4u: 3456x2234 where the Mac's desktop is 2056x1329 points), so the game is sharp,
#      but a plain Windows dialog, laid out for 96 dpi, was drawn 1:1 in those small pixels: the start window of
#      old Unity games (The Forest) was 276 points wide instead of 460, and message boxes were as small. Telling
#      the whole game "168 % scaling" (LogPixels) fixes the dialog and breaks games: Wine then shows programs that
#      are not DPI-aware a smaller desktop (RUINER, Satisfactory and Bunny Guys! drew at 2061x1332) and
#      Metamorphosis magnified its menu. A dialog takes its size from its font, so only that is enlarged, by the
#      monitor's effective dpi over its raw dpi (96 * real / emulated); on the Mac-size desktop the two are equal.
exact("dlls/user32/dialog.c", [
    ('static HWND DIALOG_CreateIndirect( HINSTANCE hInst, LPCVOID dlgTemplate,\n',
     "/* Tessera: a dialog takes its size from its font. On a desktop that is an emulated mode LARGER than the real one\n   (TESSERA_FULL_RESOLUTION: a D3DMetal game sees the screen's largest real mode, e.g. 3456x2234 over the Mac's\n   2056x1329 points) one desktop pixel is smaller than a point, and a dialog laid out for 96 dpi came out small.\n   There the monitor's raw dpi (96 * real / emulated) is below its effective dpi, and the font is enlarged by\n   that ratio, so the whole dialog is as large as on the Mac's own desktop. In every other case the two are equal\n   or the raw one is higher, and nothing changes. */\nstatic int tessera_scale_dialog_font( int pixels )\n{\n    POINT origin = {0, 0};\n    HMONITOR monitor = MonitorFromPoint( origin, MONITOR_DEFAULTTOPRIMARY );\n    UINT eff_x, eff_y, raw_x, raw_y;\n\n    if (monitor && NtUserGetDpiForMonitor( monitor, 0 /* MDT_EFFECTIVE_DPI */, &eff_x, &eff_y ) &&\n        NtUserGetDpiForMonitor( monitor, 2 /* MDT_RAW_DPI */, &raw_x, &raw_y ) && raw_y && raw_y < eff_y)\n        return MulDiv( pixels, eff_y, raw_y );\n    return pixels;\n}\n\nstatic HWND DIALOG_CreateIndirect( HINSTANCE hInst, LPCVOID dlgTemplate,\n"),
    ('                hUserFont = CreateFontIndirectW( &ncMetrics.lfMessageFont );\n',
     '                ncMetrics.lfMessageFont.lfHeight = tessera_scale_dialog_font( ncMetrics.lfMessageFont.lfHeight );\n                hUserFont = CreateFontIndirectW( &ncMetrics.lfMessageFont );\n'),
    ('            int pixels = MulDiv(template.pointSize, GetDeviceCaps(dc , LOGPIXELSY), 72);\n',
     '            int pixels = tessera_scale_dialog_font( MulDiv(template.pointSize, GetDeviceCaps(dc , LOGPIXELSY), 72) );\n')])


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
