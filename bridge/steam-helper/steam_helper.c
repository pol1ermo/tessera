/*
 * steam.exe - Tessera's stand-in for the Windows Steam client inside a game's prefix.
 *
 * Windows games find Steam through the registry: steam_api(64).dll reads HKCU\Software\Valve\Steam (SteamPath) and
 * HKCU\Software\Valve\Steam\ActiveProcess (pid of a running Steam, and where steamclient(64).dll is), checks that
 * the pid is alive, and loads that DLL. In Tessera that DLL is the Steam bridge, which talks to the macOS Steam
 * client. This program registers itself as the running Steam, starts the game with the rest of its command line,
 * waits until the game and every program started from it have ended (as the Windows Steam client does: a launcher
 * often starts the game and quits) and returns the first program's exit code. It also creates the objects older
 * games use to see that Steam runs, and answers the start request of Steam's older DRM as Valve's Proton does.
 *
 * Usage (from the Tessera launcher): steam.exe <game.exe> [game arguments...]
 */
#include <windows.h>
#include <winternl.h>
#include <tlhelp32.h>
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

/* Steam's older DRM (CEG, Steam's custom executables of 2009-2013) hands a game's start to the Steam client: the game
 * signals the semaphore STEAM_DIPC_CONSUME and waits up to 30 s for the client to set its STEAM_START_ACK_EVENT_<pid>_
 * <n> event, then releases SREAM_DIPC_PRODUCE (Steam's own spelling). This thread answers the way Valve's Proton
 * (steam_helper/steam.c) does. Most games then go on; a game whose executable needs the Windows Steam client's own
 * DRM answer (Borderlands 2 RU edition, XCOM: Enemy Unknown) ends instead - which the macOS Steam client cannot give,
 * and which Tessera does not imitate. The log line says so, so a game that quits at once has its reason in the log. */
typedef LONG (WINAPI *open_directory_fn)(HANDLE *, ACCESS_MASK, OBJECT_ATTRIBUTES *);
typedef LONG (WINAPI *query_directory_fn)(HANDLE, void *, ULONG, BOOLEAN, BOOLEAN, ULONG *, ULONG *);

static HANDLE find_start_ack_event(void)
{
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    open_directory_fn open_directory = (open_directory_fn)(void *)GetProcAddress(ntdll, "NtOpenDirectoryObject");
    query_directory_fn query_directory = (query_directory_fn)(void *)GetProcAddress(ntdll, "NtQueryDirectoryObject");
    WCHAR path[64], name[MAX_PATH];
    UNICODE_STRING dir_name;
    OBJECT_ATTRIBUTES attr = { sizeof(attr) };
    DWORD session = 0;
    HANDLE dir, event = NULL;
    ULONG context = 0, size;
    BYTE buffer[1024];
    BOOLEAN restart = TRUE;

    if (!open_directory || !query_directory) return NULL;
    ProcessIdToSessionId(GetCurrentProcessId(), &session);
    swprintf(path, 64, L"\\Sessions\\%lu\\BaseNamedObjects", session);   /* where this Wine keeps named objects */
    dir_name.Buffer = path;
    dir_name.Length = (USHORT)(wcslen(path) * sizeof(WCHAR));
    dir_name.MaximumLength = dir_name.Length + sizeof(WCHAR);
    attr.ObjectName = &dir_name;
    if (open_directory(&dir, 0x0001 /* DIRECTORY_QUERY */, &attr)) return NULL;
    /* each entry starts with its name (DIRECTORY_BASIC_INFORMATION) */
    while (!query_directory(dir, buffer, sizeof(buffer), TRUE, restart, &context, &size))
    {
        const UNICODE_STRING *entry = (const UNICODE_STRING *)buffer;
        size_t len = entry->Length / sizeof(WCHAR);
        restart = FALSE;
        if (len >= 21 && len < MAX_PATH && !wcsncmp(entry->Buffer, L"STEAM_START_ACK_EVENT", 21))
        {
            wcsncpy(name, entry->Buffer, len);
            name[len] = 0;
            /* SetEvent needs EVENT_MODIFY_STATE: with SYNCHRONIZE alone the answer is refused and the game times out */
            event = OpenEventW(SYNCHRONIZE | EVENT_MODIFY_STATE, FALSE, name);
            break;
        }
    }
    CloseHandle(dir);
    return event;
}

static DWORD WINAPI steam_drm_thread(void *unused)
{
    HANDLE consume = CreateSemaphoreW(NULL, 0, 512, L"STEAM_DIPC_CONSUME");
    HANDLE produce = CreateSemaphoreW(NULL, 1, 512, L"SREAM_DIPC_PRODUCE");
    if (!consume || !produce) return 1;
    while (WaitForSingleObject(consume, INFINITE) == WAIT_OBJECT_0)
    {
        HANDLE ack = find_start_ack_event();
        BOOL answered = ack && SetEvent(ack);
        if (ack) CloseHandle(ack);
        ReleaseSemaphore(produce, 1, NULL);
        fprintf(stderr, "steam.exe: start request of Steam's older DRM (CEG) %s; a game that needs the Windows Steam "
                "client's own answer ends here\n", answered ? "answered" : "found no event to answer");
    }
    return 0;
}

/* Programs started from the game, followed through their parent's process id. Wine gives the id of a program that
 * has ended to a later one, so each is kept with the time it started: a process is ours only with the same start
 * time, and a child only when it started after its parent (and before the parent's id went to another program). */
struct tracked { DWORD pid; ULONGLONG started; };

static ULONGLONG start_time(DWORD pid)
{
    FILETIME created, exited, kernel, user;
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    ULONGLONG t = 0;
    if (!process) return 0;
    if (GetProcessTimes(process, &created, &exited, &kernel, &user))
        t = ((ULONGLONG)created.dwHighDateTime << 32) | created.dwLowDateTime;
    CloseHandle(process);
    return t;
}

static void wait_for_descendants(DWORD first, ULONGLONG first_started)
{
    static struct tracked ours[512];
    static PROCESSENTRY32W list[2048];
    static ULONGLONG started[2048];
    int count = 1;
    ours[0].pid = first;
    ours[0].started = first_started;
    for (;;)
    {
        HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        PROCESSENTRY32W entry = { sizeof(entry) };
        int n = 0;
        BOOL running = FALSE, grew = TRUE;
        if (snap == INVALID_HANDLE_VALUE) return;
        for (BOOL ok = Process32FirstW(snap, &entry); ok && n < 2048; ok = Process32NextW(snap, &entry))
        {
            list[n] = entry;
            started[n++] = start_time(entry.th32ProcessID);
        }
        CloseHandle(snap);
        /* a child can be listed before its parent, so go over the list until it gives no new one */
        while (grew)
        {
            grew = FALSE;
            for (int i = 0; i < n; i++)
            {
                int known = -1, parent = -1;
                for (int k = 0; k < count; k++)
                {
                    if (ours[k].pid == list[i].th32ProcessID && ours[k].started == started[i]) known = k;
                    if (ours[k].pid == list[i].th32ParentProcessID) parent = k;
                }
                if (known >= 0) { if (known > 0) running = TRUE; continue; }
                if (parent < 0 || !started[i] || started[i] < ours[parent].started || count >= 512) continue;
                /* the parent's id now belongs to another program: only children started before that one are ours */
                BOOL reused = FALSE;
                for (int j = 0; j < n && !reused; j++)
                    reused = list[j].th32ProcessID == ours[parent].pid && started[j] != ours[parent].started &&
                             started[j] <= started[i];
                if (reused) continue;
                ours[count].pid = list[i].th32ProcessID;
                ours[count].started = started[i];
                count++;
                running = grew = TRUE;
            }
        }
        if (!running) return;
        Sleep(500);
    }
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
    /* The Windows Steam client also marks the game it runs as installed and running under the user's key; Steam's
     * DRM wrapper in older games checks it (Fallout: New Vegas: "Application load error 3:0000065432"). */
    if (!RegCreateKeyExW(HKEY_CURRENT_USER, key, 0, NULL, 0, KEY_ALL_ACCESS, NULL, &app, NULL))
    {
        set_dword(app, L"Installed", 1);
        set_dword(app, L"Running", 1);
        set_dword(app, L"Updating", 0);
        RegCloseKey(app);
    }
}

/* The Windows Steam client gives the games it starts two more variables. Some launchers check them before they
   load any Steam library: CS:GO legacy (32-bit) stops with "Failed to connect with local Steam Client process"
   when SteamPath is missing. ValvePlatformMutex is the Steam program's path with forward slashes. */
static void set_steam_environment(void)
{
    WCHAR path[MAX_PATH];
    SetEnvironmentVariableW(L"SteamPath", L"C:\\Program Files (x86)\\Steam");
    if (GetModuleFileNameW(NULL, path, MAX_PATH))
    {
        for (WCHAR *p = path; *p; p++) if (*p == '\\') *p = '/';
        SetEnvironmentVariableW(L"ValvePlatformMutex", path);
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
    set_steam_environment();
    /* the game starts in the folder Steam chose for it (a game's install folder, or Steam's own folder for install
       scripts); Tessera's launcher passes it in TESSERA_WORKDIR because start.exe moves us into our own folder.
       Without it, the game's own folder is used. */
    if (!GetEnvironmentVariableW(L"TESSERA_WORKDIR", dir, MAX_PATH) || !dir[0])
        game_directory(cmdline, dir, MAX_PATH);
    /* Steam's install-script runner is not a game: no DRM to answer, and an installer service it leaves running must
       not hold its run open */
    BOOL game = !wcsstr(cmdline, L"iscriptevaluator") && !wcsstr(cmdline, L"ISCRIPTEVALUATOR");
    if (game) CloseHandle(CreateThread(NULL, 0, steam_drm_thread, NULL, 0, NULL));
    if (!CreateProcessW(NULL, cmdline, NULL, NULL, FALSE, 0, NULL, dir[0] ? dir : NULL, &si, &pi))
    {
        fprintf(stderr, "steam.exe: could not start %ls (error %lu)\n", cmdline, GetLastError());
        return 1;
    }
    CloseHandle(pi.hThread);
    ULONGLONG first_started = start_time(pi.dwProcessId);
    WaitForSingleObject(pi.hProcess, INFINITE);
    /* A launcher (Borderlands 2's) starts the game and quits; the game still needs a running Steam (its id in the
       registry must be alive - "Steam must be running in order to launch Borderlands 2" otherwise). Like the Windows
       Steam client, stay while the programs started from it run. (Not "until every other program has ended":
       start.exe, which started this one, waits for it.) */
    if (game) wait_for_descendants(pi.dwProcessId, first_started);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    return (int)code;
}
