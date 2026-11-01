"""The command line.

    python -m delphipp FILE_OR_FOLDER...            report what the rules find
    python -m delphipp -o OUT FILE_OR_FOLDER...     also write each file, rewritten, under OUT
    python -m delphipp --rules with ...             only the rules named (comma-separated)
    python -m delphipp --list                       the rules there are

Run from the python folder (or put it on PYTHONPATH). Exit status 1 when a
rule reports an error.
"""
import argparse
import pathlib
import sys

from . import engine, rules

DELPHI = ('.pas', '.dpr', '.dpk', '.inc')


def files(paths):
    for p in map(pathlib.Path, paths):
        if p.is_dir():
            yield from (f for f in sorted(p.rglob('*')) if f.suffix.lower() in DELPHI and f.is_file())
        else:
            yield p


def main(argv=None):
    ap = argparse.ArgumentParser(prog='delphipp', description='Rules over Delphi source.')
    ap.add_argument('paths', nargs='*')
    ap.add_argument('-o', '--out', help='write each file under this folder, rewritten')
    ap.add_argument('--rules', help='the rules to run, comma-separated (default: all)')
    ap.add_argument('--list', action='store_true', help='list the rules and stop')
    a = ap.parse_args(argv)
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    if a.list:
        for r in rules.ALL:
            print(f"{r.name:16} {(r.__doc__ or '').strip().splitlines()[0]}")
        return 0
    if not a.paths:
        ap.error('give a file or a folder')
    chosen = rules.by_name(a.rules)
    errors = changed = n = 0
    roots = [pathlib.Path(p) for p in a.paths]
    for f in files(a.paths):
        n += 1
        raw = f.read_bytes()
        out, messages = engine.run(raw, chosen, str(f))
        for m in messages:
            print(f"{f}:{m}")
            errors += m.level == 'error'
        changed += out != raw
        if a.out:
            root = next((r for r in roots if r.is_dir() and r in f.parents), f.parent)
            dest = pathlib.Path(a.out) / f.relative_to(root)
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(out)
    print(f"{n} files, {changed} changed, {errors} errors", file=sys.stderr)
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
