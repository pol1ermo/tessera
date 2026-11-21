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
OWN_MINIMUM_EXCEPTIONS = {
    # Apple's D3DMetal (unmodified): Apple's shader container library needs macOS 15.4
    "Contents/Resources/Runtime/lib64/apple_gptk/external/D3DMetal.framework/Versions/A/Resources/libdxccontainer.dylib",
    # DXMT's Metal bridge is made for macOS 15
    "Contents/Resources/Runtime/lib/dxmt/x86_64-unix/winemetal.so",
}
plist = subprocess.run(["defaults", "read", os.path.join(app, "Contents/Info.plist"), "LSMinimumSystemVersion"],
                       capture_output=True, text=True).stdout.strip() or "11.0"
def version_tuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", v)[:3])
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
        if mins and max(version_tuple(m) for m in mins) > version_tuple(plist) and rel not in OWN_MINIMUM_EXCEPTIONS:
            problems.append(f"needs macOS {max(mins, key=version_tuple)} (the app states {plist}): {rel}")
if mount:
    subprocess.run(["hdiutil", "detach", mount], stdout=subprocess.DEVNULL)

for n in sorted(set(notes)):
    print("  note ", n)
for p in sorted(set(problems)):
    print("  FAIL ", p)
print(f"{'PASS' if not problems else 'FAIL'}: {len(set(problems))} problems, {len(set(notes))} kept credits")
sys.exit(1 if problems else 0)
