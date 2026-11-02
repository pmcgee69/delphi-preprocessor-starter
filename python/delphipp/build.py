"""Apply the rules to a file and compile the result with dcc64: does a rewrite really compile?

    python -m delphipp.build FILE [--run] [--diff] [--rules with,case-of] [--out DIR]

The rewritten file goes in a folder of its own, and yours stays as it is. dcc64's messages are put
on your file's lines, through the edits. --diff shows what the rules changed. Exit status 1 on an
error.
"""
from __future__ import annotations

import argparse
import difflib
import hashlib
import pathlib
import re
import subprocess
import sys
import tempfile

from . import engine, rules

DCC_LOCATED = re.compile(r'^(.+?)\((\d+)\) (Hint|Warning|Error|Fatal): (.*)$')


def source_line(raw: bytes, edits, out_line: int) -> int:
    """The line (0-based) of the source that a line of the output came from. A line an edit
    wrote is the line where that edit begins."""
    delta = 0       # output's lines ahead of the source's, after the edits passed
    for e in edits:
        start = raw.count(b'\n', 0, e.start)
        written = e.text.count(b'\n')
        removed = raw.count(b'\n', e.start, e.end)
        if out_line < start + delta:
            break
        if out_line <= start + delta + written:
            return start
        delta += written - removed
    return out_line - delta


def out_folder(file: pathlib.Path) -> pathlib.Path:
    """Short, as past about 127 characters of path dcc64's messages lose their line numbers."""
    tag = hashlib.sha1(str(file.resolve().parent).lower().encode()).hexdigest()[:10]
    d = pathlib.Path(tempfile.gettempdir()) / f'dpp{tag}'
    d.mkdir(exist_ok=True)
    return d


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog='delphipp.build', description='Rules, then dcc64.')
    ap.add_argument('file', type=pathlib.Path)
    ap.add_argument('--run', action='store_true', help='run the program if it compiled')
    ap.add_argument('--diff', action='store_true', help='show what the rules changed')
    ap.add_argument('--rules', help='the rules to run, comma-separated (default: all)')
    ap.add_argument('--out', type=pathlib.Path, help='where the output goes; keep it short')
    a = ap.parse_args(argv)
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    raw = a.file.read_bytes()
    out, messages, edits = engine.run_with_edits(raw, rules.by_name(a.rules), str(a.file))
    failed = False
    for m in messages:
        print(f"{a.file}({m.line}) {m.level.capitalize()}: {m.text} [{m.rule}]")
        failed |= m.level == 'error'
    if a.diff:
        encoding, _ = engine.decode(raw)
        for line in difflib.unified_diff(raw.decode(encoding).splitlines(), out.decode(encoding).splitlines(),
                                         str(a.file), 'after the rules', lineterm=''):
            print(line)
    if failed:
        return 1
    folder = a.out or out_folder(a.file)
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / a.file.name
    target.write_bytes(out)
    run = subprocess.run(['dcc64', '-Q', f'-E{folder}', f'-NU{folder}', '-NSSystem;Winapi',
                          f'-U{a.file.resolve().parent}', f'-I{a.file.resolve().parent}', str(target)],
                         capture_output=True, text=True, errors='replace', timeout=600)
    for text in run.stdout.splitlines():
        m = DCC_LOCATED.match(text.strip())
        if m is None:
            if 'Fatal:' in text or 'Error:' in text:
                print(text)
            continue
        where, line, level, message = m.groups()
        if pathlib.Path(where).name.lower() == target.name.lower():
            print(f"{a.file}({source_line(raw, edits, int(line) - 1) + 1}) {level}: {message}")
        else:
            print(f"{where}({line}) {level}: {message}")
    if run.returncode != 0:
        print('dcc64 refused it', file=sys.stderr)
        return 1
    print(f'compiled: {target}')
    if a.run and a.file.suffix.lower() == '.dpr':
        return subprocess.run([str(folder / (a.file.stem + '.exe'))], stdin=subprocess.DEVNULL).returncode
    return 0


if __name__ == '__main__':
    sys.exit(main())
