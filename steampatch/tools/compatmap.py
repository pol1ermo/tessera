#!/usr/bin/env python3
"""compatmap.py - read or set Steam's per-game compatibility tool mappings (config/config.vdf, CompatToolMapping).

Steam must be closed: it rewrites config.vdf on exit. A backup is kept next to the file before the first change of
each day. Only the CompatToolMapping block is touched; nothing else in the file is printed or changed.

  compatmap.py list
  compatmap.py set APPID TOOL [PRIORITY]     (APPID 0 = "all other titles")
  compatmap.py remove APPID
"""
import os
import re
import shutil
import sys
import time

CFG = os.path.expanduser('~/Library/Application Support/Steam/config/config.vdf')


def find_block(s, name, start=0):
    """Returns (open_brace_index, close_brace_index) of the block "name" { ... } at or after start."""
    m = re.compile(r'"%s"\s*\{' % re.escape(name)).search(s, start)
    if not m:
        return None
    i = m.end() - 1
    depth = 0
    in_str = False
    j = i
    while j < len(s):
        c = s[j]
        if c == '"' and s[j - 1] != '\\':
            in_str = not in_str
        elif not in_str:
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    return i, j
        j += 1
    return None


def entries(s, blk):
    body = s[blk[0] + 1:blk[1]]
    out = {}
    for m in re.finditer(r'"(\d+)"\s*\{([^{}]*)\}', body):
        kv = dict(re.findall(r'"([^"]+)"\s*"([^"]*)"', m.group(2)))
        out[m.group(1)] = kv
    return out


def render(indent, mapping):
    t = '\t' * indent
    lines = []
    for appid in sorted(mapping, key=lambda a: int(a)):
        kv = mapping[appid]
        lines.append('%s"%s"\n%s{\n' % (t, appid, t))
        for k in ('name', 'config', 'priority'):
            lines.append('%s\t"%s"\t\t"%s"\n' % (t, k, kv.get(k, '')))
        lines.append('%s}\n' % t)
    return ''.join(lines)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    s = open(CFG, encoding='utf-8', errors='surrogateescape').read()
    blk = find_block(s, 'CompatToolMapping')
    cmd = sys.argv[1]
    if cmd == 'list':
        if not blk:
            print('no mappings')
            return 0
        for a, kv in sorted(entries(s, blk).items(), key=lambda x: int(x[0])):
            print('%-10s %-24s priority %s' % (a, kv.get('name', ''), kv.get('priority', '')))
        return 0
    if os.system('pgrep -f "[S]team.AppBundle/Steam/Contents/MacOS/steam_osx" >/dev/null') == 0:
        print('Steam is running - close it first')
        return 2
    if not blk:
        print('no CompatToolMapping block to edit')
        return 3
    mapping = entries(s, blk)
    if cmd == 'set':
        appid, tool = sys.argv[2], sys.argv[3]
        prio = sys.argv[4] if len(sys.argv) > 4 else ('75' if appid == '0' else '250')
        mapping[appid] = {'name': tool, 'config': '', 'priority': prio}
    elif cmd == 'remove':
        mapping.pop(sys.argv[2], None)
    else:
        print(__doc__)
        return 1
    backup = CFG + '.tessera-backup-' + time.strftime('%Y%m%d')
    if not os.path.exists(backup):
        shutil.copy2(CFG, backup)
    # indentation of the block's own line, entries go one level deeper
    line_start = s.rfind('\n', 0, blk[0]) + 1
    indent = len(s[line_start:blk[0]]) - len(s[line_start:blk[0]].lstrip('\t')) + 1
    new = s[:blk[0] + 1] + '\n' + render(indent, mapping) + '\t' * (indent - 1) + s[blk[1]:]
    tmp = CFG + '.tessera-tmp'
    open(tmp, 'w', encoding='utf-8', errors='surrogateescape').write(new)
    os.replace(tmp, CFG)
    print('saved:', cmd, ' '.join(sys.argv[2:]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
