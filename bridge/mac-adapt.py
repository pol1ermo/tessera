#!/usr/bin/env python3
"""mac-adapt.py SRC - Tessera's changes to Valve's lsteamclient for the macOS Steam client.

The macOS steamclient.dylib exports everything the bridge needs except Steam_IsKnownInterface and
Steam_NotifyMissingInterface. Valve's loader treats every export as required and gives up when one is missing, so
on a Mac no game could reach Steam. Here both become optional:
  - Steam_IsKnownInterface: answers "known" when the client lacks the function; a version the client really does
    not have still fails cleanly at the later interface request, which every SDK version checks for.
  - Steam_NotifyMissingInterface: becomes a no-op (it only reports a missing version back to Steam).
"""
import sys

src = sys.argv[1]
p = src + '/unixlib.cpp'
s = open(p).read()

old = '    LOAD_FUNC( Steam_IsKnownInterface );\n    LOAD_FUNC( Steam_NotifyMissingInterface );\n'
new = ('    /* Tessera: the macOS steamclient.dylib does not export these two; they are optional there. */\n'
       '    p_Steam_IsKnownInterface = (decltype(p_Steam_IsKnownInterface))dlsym( steamclient, "Steam_IsKnownInterface" );\n'
       '    p_Steam_NotifyMissingInterface = (decltype(p_Steam_NotifyMissingInterface))dlsym( steamclient, "Steam_NotifyMissingInterface" );\n')
assert s.count(old) == 1, 'LOAD_FUNC block not found'
s = s.replace(old, new, 1)

old = '    params->_ret = p_Steam_IsKnownInterface( params->version );\n'
new = '    params->_ret = p_Steam_IsKnownInterface ? p_Steam_IsKnownInterface( params->version ) : 1;\n'
assert s.count(old) == 1
s = s.replace(old, new, 1)

old = '    p_Steam_NotifyMissingInterface( params->pipe, params->version );\n'
new = '    if (p_Steam_NotifyMissingInterface) p_Steam_NotifyMissingInterface( params->pipe, params->version );\n'
assert s.count(old) == 1
s = s.replace(old, new, 1)

open(p, 'w').write(s)
print('mac-adapt: unixlib.cpp adapted (2 optional exports)')

# Steam Input / HTML surface key codes: Valve converts Windows virtual keys to the platform's native codes and only
# ships an X11 table. On macOS the native codes are the HIToolbox virtual key codes (kVK_*), which is what Chromium
# inside the Steam client expects there. Unmapped keys return 0xFFFF (0 would be the A key on a Mac).
p = src + '/unix_steam_input_manual.cpp'
s = open(p).read()
mac = """#elif defined(__APPLE__)
/* Tessera: Windows virtual-key -> macOS virtual key code (HIToolbox kVK_*). */
uint32_t manual_convert_nNativeKeyCode( uint32_t win_vk )
{
    static const char letters[26] = { 0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
                                      0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06 };
    static const char digits[10] = { 0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19 };
    static const char keypad[10] = { 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C };
    static const char fkeys[20] = { 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F, 0x69,
                                    0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A };
    if (win_vk >= 'A' && win_vk <= 'Z') return (unsigned char)letters[win_vk - 'A'];
    if (win_vk >= '0' && win_vk <= '9') return (unsigned char)digits[win_vk - '0'];
    if (win_vk >= 0x60 && win_vk <= 0x69) return (unsigned char)keypad[win_vk - 0x60];   /* VK_NUMPAD0..9 */
    if (win_vk >= 0x70 && win_vk <= 0x83) return (unsigned char)fkeys[win_vk - 0x70];    /* VK_F1..F20 */
    switch (win_vk)
    {
    case 0x08: return 0x33;   /* VK_BACK -> Delete */
    case 0x09: return 0x30;   /* VK_TAB */
    case 0x0C: return 0x47;   /* VK_CLEAR -> keypad Clear */
    case 0x0D: return 0x24;   /* VK_RETURN */
    case 0x10: case 0xA0: return 0x38;   /* shift */
    case 0xA1: return 0x3C;
    case 0x11: case 0xA2: return 0x3B;   /* control */
    case 0xA3: return 0x3E;
    case 0x12: case 0xA4: return 0x3A;   /* alt -> option */
    case 0xA5: return 0x3D;
    case 0x5B: case 0x5C: return 0x37;   /* Windows keys -> command */
    case 0x14: return 0x39;   /* caps lock */
    case 0x1B: return 0x35;   /* escape */
    case 0x20: return 0x31;   /* space */
    case 0x21: return 0x74;   /* page up */
    case 0x22: return 0x79;   /* page down */
    case 0x23: return 0x77;   /* end */
    case 0x24: return 0x73;   /* home */
    case 0x25: return 0x7B;   /* left */
    case 0x26: return 0x7E;   /* up */
    case 0x27: return 0x7C;   /* right */
    case 0x28: return 0x7D;   /* down */
    case 0x2D: return 0x72;   /* insert -> help */
    case 0x2E: return 0x75;   /* delete -> forward delete */
    case 0x6A: return 0x43;   /* keypad * */
    case 0x6B: return 0x45;   /* keypad + */
    case 0x6D: return 0x4E;   /* keypad - */
    case 0x6E: return 0x41;   /* keypad . */
    case 0x6F: return 0x4B;   /* keypad / */
    case 0xBA: return 0x29;   /* ; */
    case 0xBB: return 0x18;   /* = */
    case 0xBC: return 0x2B;   /* , */
    case 0xBD: return 0x1B;   /* - */
    case 0xBE: return 0x2F;   /* . */
    case 0xBF: return 0x2C;   /* / */
    case 0xC0: return 0x32;   /* ` */
    case 0xDB: return 0x21;   /* [ */
    case 0xDC: return 0x2A;   /* \\ */
    case 0xDD: return 0x1E;   /* ] */
    case 0xDE: return 0x27;   /* ' */
    }
    return 0xFFFF;
}
#else
#error You must implement VK<->Native keysym conversion for this platform."""
old = '#else\n#error You must implement VK<->Native keysym conversion for this platform.'
assert s.count(old) == 1, 'keysym #error not found'
s = s.replace(old, mac, 1)
open(p, 'w').write(s)
print('mac-adapt: macOS key code table added')
