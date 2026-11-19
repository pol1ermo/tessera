/*
 * steam.exe - Tessera's stand-in for the Windows Steam client inside a game's prefix.
 *
 * Windows games find Steam through the registry: steam_api(64).dll reads HKCU\Software\Valve\Steam (SteamPath) and
 * HKCU\Software\Valve\Steam\ActiveProcess (pid of a running Steam, and where steamclient(64).dll is), checks that
 * the pid is alive, and loads that DLL. In Tessera that DLL is the Steam bridge, which talks to the macOS Steam
 * client. This program registers itself as the running Steam, starts the game with the rest of its command line,
 * waits for it and returns its exit code. It also creates the objects older games use to see that Steam runs.
 *
 * Usage (from the Tessera launcher): steam.exe <game.exe> [game arguments...]
 */
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

static const WCHAR steam_dir[] = L"C:\\Program Files (x86)\\Steam";

static void set_str(HKEY key, const WCHAR *name, const WCHAR *value)
{
    RegSetValueExW(key, name, 0, REG_SZ, (const BYTE *)value, (DWORD)((wcslen(value) + 1) * sizeof(WCHAR)));
}

static void set_dword(HKEY key, const WCHAR *name, DWORD value)
{
    RegSetValueExW(key, name, 0, REG_DWORD, (const BYTE *)&value, sizeof(value));
}

static void register_steam(void)
{
    HKEY steam, active;
    WCHAR path[MAX_PATH];
    if (!RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam", 0, NULL, 0, KEY_ALL_ACCESS, NULL, &steam, NULL))
    {
        set_str(steam, L"SteamPath", L"C:/Program Files (x86)/Steam");
        swprintf(path, MAX_PATH, L"%ls\\steam.exe", steam_dir);
        set_str(steam, L"SteamExe", path);
        set_str(steam, L"Language", L"english");
        if (!RegCreateKeyExW(steam, L"ActiveProcess", 0, NULL, 0, KEY_ALL_ACCESS, NULL, &active, NULL))
        {
            set_dword(active, L"pid", GetCurrentProcessId());
            swprintf(path, MAX_PATH, L"%ls\\steamclient.dll", steam_dir);
            set_str(active, L"SteamClientDll", path);
            swprintf(path, MAX_PATH, L"%ls\\steamclient64.dll", steam_dir);
            set_str(active, L"SteamClientDll64", path);
            RegCloseKey(active);
        }
        RegCloseKey(steam);
    }
    if (!RegCreateKeyExW(HKEY_LOCAL_MACHINE, L"Software\\Valve\\Steam", 0, NULL, 0, KEY_ALL_ACCESS | KEY_WOW64_32KEY, NULL, &steam, NULL))
    {
        set_str(steam, L"InstallPath", steam_dir);
        RegCloseKey(steam);
    }
}

/* Older games (Source engine titles, some launchers) do not ask the registry: they look for objects the Windows
 * Steam client creates - two named events and a hidden window titled "Steam". Without them CS:GO-era games stop
 * with "Failed to connect with local Steam Client process". */
static HANDLE presence_events[2];

static DWORD WINAPI presence_window_thread(void *unused)
{
    WNDCLASSEXW cls = { sizeof(cls) };
    MSG msg;
    cls.lpfnWndProc = DefWindowProcW;
    cls.hInstance = GetModuleHandleW(NULL);
    cls.lpszClassName = L"vguiPopupWindow";        /* the class Steam's own windows use */
    RegisterClassExW(&cls);
    CreateWindowExW(0, cls.lpszClassName, L"Steam", WS_POPUP, 0, 0, 1, 1, NULL, NULL, cls.hInstance, NULL);
    while (GetMessageW(&msg, NULL, 0, 0) > 0)
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}

static void announce_steam(void)
{
    presence_events[0] = CreateEventW(NULL, FALSE, FALSE, L"Steam3Master_SharedMemLock");
    presence_events[1] = CreateEventW(NULL, FALSE, FALSE, L"Global\\Valve_SteamIPC_Class");
    GetDesktopWindow();                             /* make the desktop before the window thread races for it */
    CloseHandle(CreateThread(NULL, 0, presence_window_thread, NULL, 0, NULL));
}

/* Xbox Game Studios titles run GamingRepair.exe at every start unless Steam's app key says it succeeded once;
 * under Wine it never does, which costs about 20 seconds per start. */
static void mark_gaming_repair_done(void)
{
    WCHAR key[64];
    const WCHAR *id = _wgetenv(L"SteamGameId");
    HKEY app;
    if (!id || !*id) id = _wgetenv(L"SteamAppId");
    if (!id || !*id) return;
    swprintf(key, 64, L"Software\\Valve\\Steam\\Apps\\%ls", id);
    if (!RegCreateKeyExW(HKEY_LOCAL_MACHINE, key, 0, NULL, 0, KEY_ALL_ACCESS | KEY_WOW64_32KEY, NULL, &app, NULL))
    {
        set_dword(app, L"GamingRepair", 1);
        RegCloseKey(app);
    }
}

/* Everything after our own program name, exactly as it was quoted. */
static WCHAR *rest_of_command_line(void)
{
    WCHAR *cmd = GetCommandLineW();
    BOOL quoted = FALSE;
    while (*cmd && (quoted || (*cmd != ' ' && *cmd != '\t')))
    {
        if (*cmd == '"') quoted = !quoted;
        cmd++;
    }
    while (*cmd == ' ' || *cmd == '\t') cmd++;
    return cmd;
}

/* The directory of the first argument, used as the game's working directory. */
static void game_directory(const WCHAR *cmdline, WCHAR *dir, DWORD size)
{
    const WCHAR *start = cmdline, *end;
    if (*start == '"') { start++; end = wcschr(start, '"'); }
    else end = wcspbrk(start, L" \t");
    if (!end) end = start + wcslen(start);
    DWORD n = (DWORD)(end - start);
    if (n >= size) n = size - 1;
    wcsncpy(dir, start, n);
    dir[n] = 0;
    WCHAR *slash = wcsrchr(dir, '\\');
    if (!slash) slash = wcsrchr(dir, '/');
    if (slash) *slash = 0; else dir[0] = 0;
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, WCHAR *unused, int show)
{
    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    WCHAR dir[MAX_PATH];
    DWORD code = 0;
    WCHAR *cmdline = rest_of_command_line();

    register_steam();
    if (!*cmdline) return 0;
    announce_steam();
    mark_gaming_repair_done();
    /* the game starts in the folder Steam chose for it (a game's install folder, or Steam's own folder for install
       scripts); Tessera's launcher passes it in TESSERA_WORKDIR because start.exe moves us into our own folder.
       Without it, the game's own folder is used. */
    if (!GetEnvironmentVariableW(L"TESSERA_WORKDIR", dir, MAX_PATH) || !dir[0])
        game_directory(cmdline, dir, MAX_PATH);
    if (!CreateProcessW(NULL, cmdline, NULL, NULL, FALSE, 0, NULL, dir[0] ? dir : NULL, &si, &pi))
    {
        fprintf(stderr, "steam.exe: could not start %ls (error %lu)\n", cmdline, GetLastError());
        return 1;
    }
    CloseHandle(pi.hThread);
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    return (int)code;
}
