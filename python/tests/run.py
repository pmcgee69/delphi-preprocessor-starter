"""The tests: tests/cases/<rule>/<name>.pas run through that rule alone.

    <name>.pas        the input
    <name>.out.pas    the output expected, when the rule changes the file
                      (none: the output must be the input, byte for byte)
    <name>.diag       the messages expected (none: no messages)
    <name>.edits      the edits expected, a line each: start-end [rule] new text, with
                      backslash, CR, LF and tab written \\ \r \n \t (none: no edits).
                      What an editor shows of a rule: both engines must agree on it
    <name>.lines      the output as a .dpps source's X.pas has it, with the $LINE directives
                      that put dcc's messages on the source's lines, the file named
                      <name>.dpps (none: the input with only the first line's directive)

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


def edit_line(e) -> str:
    """An edit as a .edits line (the tests are UTF-8, so its text is read as that)."""
    text = e.text.decode('utf-8', errors='replace')
    for a, b in (('\\', '\\\\'), ('\r', '\\r'), ('\n', '\\n'), ('\t', '\\t')):
        text = text.replace(a, b)
    return f"{e.start}-{e.end} [{e.rule}] {text}\n"


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
    out, messages, applied = engine.run_with_edits(raw, rule, str(case))
    diag = ''.join(f"{m}\n" for m in messages)
    edits = ''.join(edit_line(e) for e in applied)
    lined = engine.with_lines(raw, applied, case.stem + '.dpps')
    unlined = engine.with_lines(raw, [], case.stem + '.dpps')
    out_file = case.with_name(case.stem + '.out.pas')
    diag_file = case.with_suffix('.diag')
    edits_file = case.with_suffix('.edits')
    lines_file = case.with_suffix('.lines')
    if update:
        if out != raw:
            out_file.write_bytes(out)
        elif out_file.exists():
            out_file.unlink()
        if lined != unlined:
            lines_file.write_bytes(lined)
        elif lines_file.exists():
            lines_file.unlink()
        if diag:
            diag_file.write_text(diag, encoding='utf-8', newline='\n')
        elif diag_file.exists():
            diag_file.unlink()
        if edits:
            edits_file.write_text(edits, encoding='utf-8', newline='\n')
        elif edits_file.exists():
            edits_file.unlink()
    expected_out = out_file.read_bytes() if out_file.exists() else raw
    expected_diag = diag_file.read_text(encoding='utf-8') if diag_file.exists() else ''
    expected_edits = edits_file.read_text(encoding='utf-8') if edits_file.exists() else ''
    expected_lines = lines_file.read_bytes() if lines_file.exists() else unlined
    problems = []
    if out != expected_out:
        problems.append('the output differs from ' + (out_file.name if out_file.exists() else 'the input'))
    if diag != expected_diag:
        problems.append('the messages differ from ' + (diag_file.name if diag_file.exists() else 'none'))
    if edits != expected_edits:
        problems.append('the edits differ from ' + (edits_file.name if edits_file.exists() else 'none'))
    if lined != expected_lines:
        problems.append('the {$LINE}s differ from ' + (lines_file.name if lines_file.exists() else 'none'))
    failed += bool(problems)
    name = case.relative_to(ROOT / 'tests' / 'cases').as_posix()
    print(f"{'FAIL' if problems else 'ok':4}  {name}" + ''.join(f"\n      {p}" for p in problems))
print('all passed' if not failed else f'{failed} of {total} failed')
sys.exit(1 if failed else 0)
