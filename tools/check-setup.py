"""Is everything in place to explore the rules in Zed? Says what's missing, and how to fix it.

    python tools\\check-setup.py
"""
import importlib.util
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
problems = 0


def report(ok, what, fix=''):
    global problems
    print(f"  {'ok  ' if ok else 'MISSING'}  {what}")
    if not ok:
        problems += 1
        print(f"           -> {fix}")


print('For the rules:')
report(sys.version_info >= (3, 10), f'Python 3.10 or later (this is {sys.version.split()[0]})',
       'install a newer Python from https://www.python.org/downloads/')
have_ts = importlib.util.find_spec('tree_sitter') is not None
report(have_ts, 'the tree-sitter package', 'run:  pip install -r python\\requirements.txt')
sys.path.insert(0, str(ROOT / 'python'))
if have_ts:
    from delphipp import engine, rules
    from delphipp.grammar import grammar_path
    have_grammar = grammar_path().exists()
    report(have_grammar, 'the Delphi grammar', 'run:  python tools\\get-grammar.py')
    if have_grammar:
        tour = ROOT / 'tests' / 'tour' / 'Tour.dpr'
        _, messages, edits = engine.run_with_edits(tour.read_bytes(), rules.by_name(), str(tour))
        report(bool(messages or edits), f'the rules run: {len(messages)} messages and {len(edits)} edits on the tour',
               'something is wrong with the rules: see the error above')

print('For Zed (no Rust needed: the extension comes built, as zed\\extension.wasm):')
report(shutil.which('git') is not None, 'git, which Zed uses to fetch the grammar',
       'install it from https://git-scm.com/download/win , then close and reopen Zed')
report((ROOT / 'delphi' / 'bin' / 'delphipp.exe').exists(), 'delphi\\bin\\delphipp.exe, the language server',
       'run delphi\\get-treesitter4d.cmd once, then delphi\\build.cmd')

print('For compiling (the rules and highlighting work without these):')
for name, what in (('dcc64', 'Delphi Win64'), ('dcc32', 'Delphi Win32')):
    found = shutil.which(name) is not None
    if found:
        found = subprocess.run([name, '--version'], capture_output=True).returncode in (0, 1)
    report(found, f'{name}, the {what} compiler',
           "it comes with RAD Studio, whose bin folders must be on your PATH; not every edition has it")

print()
print('All set: see zed\\README.md for what to do in Zed.' if not problems else
      f'{problems} to fix. Then run this again.')
sys.exit(1 if problems else 0)
