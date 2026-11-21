#!/usr/bin/env python3
"""check-release.py DMG_OR_APP - checks a Tessera release candidate before it is published.

  * no file or folder name mentions CrossOver, CodeWeavers or NotProton
  * no file content mentions them either - as plain text or as Windows (UTF-16) text - except where the law or a
    third party requires it: copyright and author credits (Wine's embedded scripts, a font, authors' e-mail addresses
    in element metadata), the licence texts, FFmpeg's audio "crossover" filter, GStreamer's ID3 music genre
    "Crossover" and an Entity Framework method name in Wine Mono, which are not names
  * no file names the build machine (its home folder)
  * Tessera.app's signature verifies, and the licences are there

Exit code 0 when everything passes.
"""
import os
import re
import subprocess
import sys
import tempfile

target = sys.argv[1]
mount = None
if target.endswith(".dmg"):
    mount = tempfile.mkdtemp(prefix="tessera-rc-")
    subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mount, target], check=True,
                   stdout=subprocess.DEVNULL)
    app = os.path.join(mount, "Tessera.app")
else:
    app = target

names = re.compile(r"crossover|codeweavers|notproton|not proton", re.I)
home = os.path.expanduser("~").encode()
words = [w.encode() for w in ("CrossOver", "Crossover", "crossover", "CROSSOVER", "CodeWeavers", "Codeweavers",
                               "codeweavers", "NotProton", "notproton", "NOTPROTON")]
patterns = [(w, w) for w in words] + [(w, w.decode().encode("utf-16-le")) for w in words]
allowed_context = re.compile(rb"copyright|\(c\)|\xc2\xa9|for codeweavers|author", re.I)
problems, notes = [], []


def context(data, pos, width=60):
    start = max(0, data.rfind(b"\n", 0, pos) + 1, pos - width)
    end = min(len(data), pos + width)
    return data[start:end]


for root, dirs, files in os.walk(app):
    for n in dirs + files:
        if names.search(n):
            problems.append(f"name: {os.path.relpath(os.path.join(root, n), app)}")
    for f in files:
        path = os.path.join(root, f)
        rel = os.path.relpath(path, app)
        if os.path.islink(path):
            continue
        with open(path, "rb") as fh:
            data = fh.read()
        if home in data:
            problems.append(f"build-machine path: {rel}")
        if "/Licenses/" in "/" + rel + "/" or rel.startswith("Contents/Resources/Licenses"):
            continue                                  # licence texts must stay as written
        for word, enc in patterns:
            i = data.find(enc)
            while i != -1:
                ctx = context(data, i).replace(b"\x00", b"")
                if word.lower() == b"crossover" and "/lib64/libav" in "/" + rel:
                    pass                              # FFmpeg: the audio "crossover" filter and its messages
                elif word.lower() == b"crossover" and "/share/wine/gecko/" in "/" + rel and rel.endswith(".dic"):
                    pass                              # Wine Gecko's spell-check word list: the English word
                elif word == b"Crossover" and rel.endswith("/libgsttag-1.0.0.dylib") and (b"Metal" in ctx or b"Christian" in ctx):
                    pass                              # GStreamer: "Crossover" is a music genre in the ID3 genre list
                elif word == b"Crossover" and "/share/wine/mono/" in "/" + rel and b"CrossoverHandle" in ctx:
                    pass                              # Wine Mono (Entity Framework): part of a method name
                elif word.lower() == b"codeweavers" and i > 0 and data[i - 1:i] == b"@":
                    notes.append(f"credit kept: {rel}: {ctx.decode('latin1').strip()[:90]}")   # an author's e-mail address
                elif allowed_context.search(ctx) or "/share/wine/fonts/" in "/" + rel:
                    notes.append(f"credit kept: {rel}: {ctx.decode('latin1').strip()[:90]}")
                else:
                    problems.append(f"text: {rel}: {ctx.decode('latin1').strip()[:110]}")
                i = data.find(enc, i + 1)

sig = subprocess.run(["codesign", "--verify", app], capture_output=True, text=True)
if sig.returncode:
    problems.append("signature: " + sig.stderr.strip()[:200])
lic = os.path.join(app, "Contents/Resources/Licenses")
if not os.path.isdir(lic) or len(os.listdir(lic)) < 10:
    problems.append("licences missing")

# Every program and library must run on the oldest macOS the app states (LSMinimumSystemVersion). 1.2.9 shipped Wine's
# loader and the Steam bridge marked for macOS 27.2 (built without a deployment target); on any older macOS every
# Windows program then died at start (exit code 11). Third parties' own minimums are listed and kept.
OWN_MINIMUM = {
    # Apple's D3DMetal (unmodified): its shader container library is made for macOS 26.4 (D3DMetal 4.0 beta 3) and for
    # macOS 15.4 (D3DMetal 3.0). The launcher picks the D3DMetal version by the Mac's macOS (tessera-run/main.swift).
    "Contents/Resources/Runtime/lib64/apple_gptk/external/D3DMetal.framework/Versions/A/Resources/libdxccontainer.dylib": "26.4",
    "Contents/Resources/Runtime/lib64/apple_gptk3/external/D3DMetal.framework/Versions/A/Resources/libdxccontainer.dylib": "15.4",
    # DXMT's Metal bridge is made for macOS 15 (the launcher chooses DXMT by itself only there)
    "Contents/Resources/Runtime/lib/dxmt/x86_64-unix/winemetal.so": "15.0",
}
plist = subprocess.run(["defaults", "read", os.path.join(app, "Contents/Info.plist"), "LSMinimumSystemVersion"],
                       capture_output=True, text=True).stdout.strip() or "11.0"
def version_tuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", v)[:3])
machos = []
for root, dirs, files in os.walk(app):
    for n in files:
        path = os.path.join(root, n)
        if os.path.islink(path) or not os.access(path, os.X_OK) and not n.endswith((".dylib", ".so")):
            continue
        with open(path, "rb") as f:
            magic = f.read(4)
        if magic not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xce\xfa\xed\xfe"):
            continue
        out = subprocess.run(["otool", "-arch", "all", "-l", path], capture_output=True, text=True).stdout
        mins = []
        for block in re.split(r"\nLoad command \d+\n", out):
            if re.search(r"cmd LC_BUILD_VERSION\n", block) and re.search(r"\n\s*platform (1|MACOS)\n", block):
                mins += re.findall(r"\n\s*minos (\d+\.\d+(?:\.\d+)?)", block)
            elif re.search(r"cmd LC_VERSION_MIN_MACOSX\n", block):
                mins += re.findall(r"\n\s*version (\d+\.\d+(?:\.\d+)?)", block)
        rel = os.path.relpath(path, app)
        if mins and max(version_tuple(m) for m in mins) > version_tuple(OWN_MINIMUM.get(rel, plist)):
            problems.append(f"needs macOS {max(mins, key=version_tuple)} (allowed: {OWN_MINIMUM.get(rel, plist)}): {rel}")
        machos.append((path, rel))

# No program or library may call a system function that an older macOS does not have. The runtime is built on the
# newest macOS for macOS 11 and later; a function newer than that is linked "weakly" and is a null pointer on an older
# macOS, so calling it without a version check ends the program (signal 11). Up to 1.2.10 Wine's ntdll and GLib called
# pipe2(), new in macOS 27: on macOS 14, 15 and 26 every Windows program stopped at start. Every weak import must be
# listed here, with the reason it is safe; anything else fails the check.
WEAK_OK = {
    # on every macOS Tessera supports (14.0 and later)
    "____chkstk_darwin", "___ulock_wait2", "_os_release", "_os_unfair_lock_lock", "_os_unfair_lock_trylock",
    "_os_unfair_lock_unlock", "_voucher_adopt",
    # the version check itself (what __builtin_available calls; the compiler's code tests it for null)
    "__availability_version_check",
    # ntdll.so (dlls/ntdll/unix/sync.c): only behind __builtin_available(macOS 14.4, *)
    "_os_sync_wait_on_address", "_os_sync_wait_on_address_with_timeout", "_os_sync_wake_by_address_any",
}
WEAK_OK_FILES = (
    # other makers' libraries, which check versions themselves: Apple's D3DMetal, MoltenVK, DXMT's Metal bridge
    "Contents/Resources/Runtime/lib64/apple_gptk/", "Contents/Resources/Runtime/lib64/apple_gptk3/",
    "Contents/Resources/Runtime/lib64/libMoltenVK.dylib",
    "Contents/Resources/Runtime/lib64/dxvk/libMoltenVK.dylib", "Contents/Resources/Runtime/lib/dxmt/x86_64-unix/winemetal.so",
    # Wine's OpenCL: OpenCL 1.0 functions Apple marks as deprecated, present in every macOS
    "Contents/Resources/Runtime/lib/wine/x86_64-unix/opencl.so",
)
runtime_noise = re.compile(r"__Z|___cxa|__Unwind|___gxx|_objc_|__dyld|___dynamic_cast|_swift_|_\$s|___swift|__swift")
for path, rel in machos:
    if rel.startswith(WEAK_OK_FILES):
        continue
    out = subprocess.run(["nm", "-arch", "all", "-um", path], capture_output=True, text=True).stdout
    for sym, lib in set(re.findall(r"weak external (\S+) \(from ([^)]+)\)", out)):
        if sym not in WEAK_OK and not runtime_noise.match(sym):
            problems.append(f"may be missing on an older macOS (weak import from {lib}): {sym} in {rel}")
if mount:
    subprocess.run(["hdiutil", "detach", mount], stdout=subprocess.DEVNULL)

for n in sorted(set(notes)):
    print("  note ", n)
for p in sorted(set(problems)):
    print("  FAIL ", p)
print(f"{'PASS' if not problems else 'FAIL'}: {len(set(problems))} problems, {len(set(notes))} kept credits")
sys.exit(1 if problems else 0)
