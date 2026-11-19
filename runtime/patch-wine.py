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
