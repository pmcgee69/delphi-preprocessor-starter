"""delphipp.exe's --diff and --build, Zed's tasks, against the Python side's delphipp.build.
Needs delphi\\bin\\delphipp.exe (delphi\\build.cmd), and dcc64 for the build.

    python python/tests/build_parity.py [path\\to\\delphipp.exe]

--diff: the rules' messages and the same unified diff as difflib's, for every test case's input,
the tour and the IDE examples. --build: a dcc error is on the file's own line, below rewrites that
moved the output's lines, and the tour compiles and runs as Python's build runs it.
"""
import difflib, pathlib, subprocess, sys

PY = pathlib.Path(__file__).resolve().parent.parent
ROOT = PY.parent
EXE = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'delphi' / 'bin' / 'delphipp.exe'
sys.path.insert(0, str(PY))
from delphipp import engine, rules

assert EXE.exists(), f'no {EXE}: run delphi\\build.cmd'
files = [ROOT / 'tests' / 'tour' / 'Tour.dpr'] + sorted((ROOT / 'examples' / 'ide').glob('*.dpps'))
files += sorted(f for f in (ROOT / 'tests' / 'cases').rglob('*')
                if f.suffix.lower() in ('.pas', '.dpr', '.dpps') and '.out.' not in f.name)
failed = []
for f in files:
    rel = str(f.relative_to(ROOT))
    raw = f.read_bytes()
    out, messages, _ = engine.run_with_edits(raw, rules.by_name(), rel)
    want = [f'{rel}({m.line}) {m.level.capitalize()}: {m.text} [{m.rule}]' for m in messages]
    encoding, _ = engine.decode(raw)
    want += difflib.unified_diff(raw.decode(encoding).splitlines(), out.decode(encoding).splitlines(),
                                 rel, 'after the rules', lineterm='')
    got = subprocess.run([str(EXE), '--diff', rel], cwd=ROOT, capture_output=True).stdout
    got = got.decode('utf-8').splitlines()
    if want != got:
        failed.append(rel)
        print('DIFFERENT --diff:', rel)
        for line in list(difflib.unified_diff(want, got, 'python', 'delphi', lineterm=''))[:20]:
            print('   ', line)
print(f'--diff: {len(files)} files compared')

# --build: the tour compiles and runs
run = subprocess.run([str(EXE), '--build', str(ROOT / 'tests' / 'tour' / 'Tour.dpr'), '--run'],
                     capture_output=True, text=True, encoding='utf-8', errors='replace')
assert run.returncode == 0 and 'Ada: a greeting, a farewell, something else' in run.stdout, run.stdout

# --build: an error on the file's own line (as zed_check.py's, for the Python side)
tour = (ROOT / 'tests' / 'tour' / 'Tour.dpr').read_text(encoding='utf-8')
broken = tour.replace('    L.Free;\n', '    NoSuchRoutine(1);\n    L.Free;\n')
assert broken != tour
line = broken.split('\n').index('    NoSuchRoutine(1);') + 1
bad = ROOT / 'tests' / 'tour' / 'TourBroken.dpr'
bad.write_text(broken, encoding='utf-8')
try:
    run = subprocess.run([str(EXE), '--build', str(bad)], capture_output=True, text=True,
                         encoding='utf-8', errors='replace')
finally:
    bad.unlink()
assert run.returncode == 1 and f'TourBroken.dpr({line}) Error: E2003' in run.stdout, run.stdout
print('--build: the tour runs, and an error is on its line')
assert not failed, f'{len(failed)} files differ'
print('ok')
