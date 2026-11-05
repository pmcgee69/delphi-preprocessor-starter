"""The command line.

    python -m delphipp FILE_OR_FOLDER...            report what the rules find
    python -m delphipp -o OUT FILE_OR_FOLDER...     also write each file, rewritten, under OUT
    python -m delphipp --rules with ...             only the rules named (comma-separated)
    python -m delphipp --list                       the rules there are
    python -m delphipp --tree FILE                  the file's tree: the node types a rule sees
    python -m delphipp X.dpps                       write X.pas beside it, rewritten
    python -m delphipp --msbuild ...                messages as MSBuild reads them, for the IDE

Run from the python folder (or put it on PYTHONPATH). Exit status 1 when a
rule reports an error.

A .dpps file is Delphi source the rules rewrite before dcc sees it: the .pas beside it is
written from it, every time, so a project's pre-build event can run this and the IDE builds the
.pas as usual (examples/ide/). With --msbuild, each message is `file(line,col): warning
DPPS-rule: text`, which MSBuild's Exec, and so the IDE's Messages pane, lists as a warning or
error; a hint is printed plain.
"""
import argparse
import pathlib
import sys

from . import engine, rules

DELPHI = ('.pas', '.dpr', '.dpk', '.inc', '.dpps')


def shown(f, m, msbuild: bool) -> str:
    """A message as a line: ours, or MSBuild's canonical form (its Exec reads `error` and
    `warning`; a hint has no category there, so it stays ours)."""
    if msbuild and m.level in ('error', 'warning'):
        return f"{f.resolve()}({m.line},{m.col}): {m.level} DPPS-{m.rule}: {m.text}"
    return f"{f}:{m}"


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
    ap.add_argument('--tree', metavar='FILE', help="print the file's tree and stop")
    ap.add_argument('--msbuild', action='store_true',
                    help="messages as MSBuild reads them: file(line,col): warning DPPS-rule: text")
    a = ap.parse_args(argv)
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    if a.tree:
        sys.stdout.write(engine.tree_text(pathlib.Path(a.tree).read_bytes()))
        return 0
    if a.list:
        for r in rules.ALL:
            # a rule's description is its file's docstring, first line
            doc = (r.__doc__ or sys.modules[r.__module__].__doc__ or '').strip()
            print(f"{r.name:16} {doc.splitlines()[0] if doc else ''}")
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
            print(shown(f, m, a.msbuild))
            errors += m.level == 'error'
        changed += out != raw
        if f.suffix.lower() == '.dpps':
            # its .pas, beside it or under OUT, written only when it differs, so the IDE
            # doesn't see a change on disk where there is none
            dest = (pathlib.Path(a.out) / f.name if a.out else f).with_suffix('.pas')
            dest.parent.mkdir(parents=True, exist_ok=True)
            if not dest.exists() or dest.read_bytes() != out:
                dest.write_bytes(out)
        elif a.out:
            root = next((r for r in roots if r.is_dir() and r in f.parents), f.parent)
            dest = pathlib.Path(a.out) / f.relative_to(root)
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(out)
    print(f"{n} files, {changed} changed, {errors} errors", file=sys.stderr)
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
