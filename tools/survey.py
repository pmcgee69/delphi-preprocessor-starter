"""Runs the rules over a whole folder of Delphi and says what happened: how
many files, how many the grammar can't parse, how many the rules changed, and
how many messages each rule gave. Before trusting a new rule, run it over a
lot of real code.

With --pass-through, runs no rules and checks the first promise: every file
comes out byte for byte as it went in.

    python tools/survey.py FOLDER [--rules name,name] [--pass-through]
"""
import argparse
import collections
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'python'))
from delphipp import engine, rules             # noqa: E402
from delphipp.__main__ import files            # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument('folder')
ap.add_argument('--rules')
ap.add_argument('--pass-through', action='store_true')
a = ap.parse_args()
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

chosen = [] if a.pass_through else rules.by_name(a.rules)
n = parse_fail = 0
reported = collections.Counter()
differ = []
for f in files([a.folder]):
    n += 1
    raw = f.read_bytes()
    out, messages = engine.run(raw, chosen, str(f))
    parse_fail += any(m.rule == 'parser' for m in messages)
    for m in messages:
        if m.rule != 'parser':
            reported[m.rule] += 1
    if out != raw:
        differ.append(f)
print(f"{n} files; the grammar can't parse {parse_fail}")
if a.pass_through:
    print(f"pass-through: {n - len(differ)} of {n} byte for byte the same")
    for f in differ[:20]:
        print('  differs:', f)
else:
    print(f"files changed: {len(differ)}")
    for name, c in reported.most_common():
        print(f"  {c:6} messages from {name}")
