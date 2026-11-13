"""The language server over its real protocol, and delphipp.build's line mapping. Needs dcc64.

    python python/tests/zed_check.py                            the Python server
    python python/tests/zed_check.py delphi\\bin\\delphipp.exe    the Delphi one, delphipp --lsp
"""
import json, pathlib, queue, subprocess, sys, threading

PY = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PY))
from delphipp import rules
from delphipp.build import source_line
from delphipp.engine import Edit

# the mapping: a two-line insertion before line 2 (0-based 1)
raw = b'a\nb\nc\n'
edits = [Edit(2, 2, b'x\ny\n', 'r')]
assert [source_line(raw, edits, i) for i in range(5)] == [0, 1, 1, 1, 2], 'an insertion'
# a three-line stretch replaced by one line: what follows moves up
raw = b'a\nb\nc\nd\ne\n'
edits = [Edit(2, 7, b'X', 'r')]     # b\nc\nd -> X
assert [source_line(raw, edits, i) for i in range(3)] == [0, 1, 4], 'a replacement'

# the Python server, or the one named: python python/tests/zed_check.py delphi\bin\delphipp.exe
SERVER = [sys.argv[1], '--lsp'] if len(sys.argv) > 1 else [sys.executable, '-m', 'delphipp.lsp']
p = subprocess.Popen(SERVER, cwd=PY, stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
got = queue.Queue()


def reader():
    while True:
        length = None
        while True:
            line = p.stdout.readline()
            if not line:
                return
            if not line.strip():
                break
            if line.lower().startswith(b'content-length:'):
                length = int(line.split(b':')[1])
        got.put(json.loads(p.stdout.read(length).decode('utf-8')))


threading.Thread(target=reader, daemon=True).start()


def send(**m):
    body = json.dumps({'jsonrpc': '2.0', **m}).encode('utf-8')
    p.stdin.write(b'Content-Length: %d\r\n\r\n' % len(body) + body)
    p.stdin.flush()


URI = 'file:///D:/nowhere/Tour.dpr'
TOUR = (PY.parent / 'tests' / 'tour' / 'Tour.dpr').read_text(encoding='utf-8')
send(id=1, method='initialize', params={'capabilities': {}})
assert got.get(timeout=30)['result']['capabilities']['codeActionProvider'] is True
send(method='textDocument/didOpen', params={'textDocument': {'uri': URI, 'languageId': 'delphi', 'version': 1, 'text': TOUR}})
m = got.get(timeout=30)
d = m['params']['diagnostics']
print('sources:', sorted({x['source'] for x in d}))
assert not [x for x in d if x['severity'] == 1], 'the tour parses'
# a case-of's edits, one an arm, are one rewrite of the case: its whole if chain, on each piece of
# its squiggle, which leaves out the comment after `case X of` (so two pieces, for each of the 2)
co = [x for x in d if x['source'] == 'case-of']
assert len({x['message'] for x in co}) == 2 and len(co) == 4, co
assert all(x['message'].count('else if') == 1 for x in co), co
assert not any(x['range']['start']['line'] == x['range']['end']['line'] and
               x['range']['end']['character'] > len(TOUR.split('\n')[x['range']['start']['line']].split('//')[0])
               for x in co), 'a squiggle on a comment'
# the IDE example has what the tour lacks (footnotes, derive): every rule switched on, between them
GREET = PY.parent / 'examples' / 'ide' / 'Greet.dpps'
send(method='textDocument/didOpen', params={'textDocument': {'uri': GREET.as_uri(), 'languageId': 'delphi', 'version': 1,
                                                             'text': GREET.read_text(encoding='utf-8')}})
g = got.get(timeout=30)['params']['diagnostics']
print('sources in Greet.dpps:', sorted({x['source'] for x in g}))
assert {r.name for r in rules.ALL} <= {x['source'] for x in d + g}, d + g     # every rule switched on
w = next((x for x in d if x['source'] == 'with'), None)
assert w is None or TOUR.split('\n')[w['range']['start']['line']].strip().startswith('with P do'), w
send(id=2, method='textDocument/codeAction', params={'textDocument': {'uri': URI},
     'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 0}}, 'context': {'diagnostics': []}})
r = got.get(timeout=30)['result']
print('actions:', [a['title'] for a in r])
assert any(a['title'].startswith('Apply case-of') for a in r) and r[-1]['title'].startswith('Apply every rule')

# applying "every rule" as an editor would gives what the engine writes
lines = TOUR.split('\n')
data = TOUR.encode('utf-8')
starts = [0]
for ln in lines:
    starts.append(starts[-1] + len(ln.encode('utf-8')) + 1)


def offset(pos):
    line = lines[pos['line']].encode('utf-16-le')[:pos['character'] * 2].decode('utf-16-le')
    return starts[pos['line']] + len(line.encode('utf-8'))


out = data
for e in sorted(r[-1]['edit']['changes'][URI], key=lambda e: offset(e['range']['start']), reverse=True):
    out = out[:offset(e['range']['start'])] + e['newText'].encode('utf-8') + out[offset(e['range']['end']):]
from delphipp import engine, lsp, rules
assert b'file:' not in out, 'a uri in the code'
assert out == engine.run(data, rules.by_name(), lsp.path_of(URI))[0], 'the code action differs from the engine'

send(id=3, method='shutdown')
assert got.get(timeout=30)['id'] == 3
send(method='exit')
assert p.wait(timeout=10) == 0

# build: the tour compiles and prints what its rewrites should
run = subprocess.run([sys.executable, '-m', 'delphipp.build', str(PY.parent / 'tests' / 'tour' / 'Tour.dpr'), '--run'],
                     cwd=PY, capture_output=True, text=True, encoding='utf-8', errors='replace')
print(run.stdout[-300:])
assert run.returncode == 0, run.stdout + run.stderr
assert 'Ada: a greeting, a farewell, something else' in run.stdout and 'strings' in run.stdout \
    and "and 'quoted'" in run.stdout

# build: an error on the file's own line, below rewrites that moved the output's
broken = TOUR.replace("    L.Free;\n", "    NoSuchRoutine(1);\n    L.Free;\n")
assert broken != TOUR
want = broken.split('\n').index('    NoSuchRoutine(1);') + 1
bad = PY.parent / 'build' / 'TourBroken.dpr'
bad.write_text(broken, encoding='utf-8')
run = subprocess.run([sys.executable, '-m', 'delphipp.build', str(bad)], cwd=PY, capture_output=True, text=True,
                     encoding='utf-8', errors='replace')
bad.unlink()
print([l[-70:] for l in run.stdout.splitlines() if 'E2003' in l])
assert run.returncode == 1 and f'TourBroken.dpr({want}) Error: E2003' in run.stdout, run.stdout
print('ok')
