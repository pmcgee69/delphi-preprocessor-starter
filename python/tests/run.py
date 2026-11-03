"""The tests: tests/cases/<rule>/<name>.pas run through that rule alone.

    <name>.pas        the input
    <name>.out.pas    the output expected, when the rule changes the file
                      (none: the output must be the input, byte for byte)
    <name>.diag       the messages expected (none: no messages)

    python python/tests/run.py            run them
    python python/tests/run.py --update   write the expected files from what the
                                          rules do now (then read the diff!)
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'python'))
from delphipp import engine, rules             # noqa: E402

update = '--update' in sys.argv
failed = total = 0
# a rule written in Python but left out of ALL is switched off, not missing
written = {line.split("'")[1]
           for f in (ROOT / 'python' / 'delphipp' / 'rules').glob('*.py')
           for line in f.read_text(encoding='utf-8').splitlines()
           if line.startswith("    name = '")}
for case in sorted((ROOT / 'tests' / 'cases').glob('*/*.pas')):
    if case.name.endswith('.out.pas'):
        continue
    if case.parent.name not in {r.name for r in rules.ALL}:
        why = ('left out of ALL in rules/__init__.py' if case.parent.name in written
               else 'a Delphi-only rule')
        print(f"skip  {case.parent.name}/{case.name}: {why}")
        continue
    total += 1
    rule = rules.by_name(case.parent.name)
    raw = case.read_bytes()
    out, messages = engine.run(raw, rule, str(case))
    diag = ''.join(f"{m}\n" for m in messages)
    out_file = case.with_name(case.stem + '.out.pas')
    diag_file = case.with_suffix('.diag')
    if update:
        if out != raw:
            out_file.write_bytes(out)
        elif out_file.exists():
            out_file.unlink()
        if diag:
            diag_file.write_text(diag, encoding='utf-8', newline='\n')
        elif diag_file.exists():
            diag_file.unlink()
    expected_out = out_file.read_bytes() if out_file.exists() else raw
    expected_diag = diag_file.read_text(encoding='utf-8') if diag_file.exists() else ''
    problems = []
    if out != expected_out:
        problems.append('the output differs from ' + (out_file.name if out_file.exists() else 'the input'))
    if diag != expected_diag:
        problems.append('the messages differ from ' + (diag_file.name if diag_file.exists() else 'none'))
    failed += bool(problems)
    name = case.relative_to(ROOT / 'tests' / 'cases').as_posix()
    print(f"{'FAIL' if problems else 'ok':4}  {name}" + ''.join(f"\n      {p}" for p in problems))
print('all passed' if not failed else f'{failed} of {total} failed')
sys.exit(1 if failed else 0)
