"""The Delphi language server against the Python one, over the protocol: the same diagnostics and
the same code actions, file by file. Needs delphi\\bin\\delphipp.exe (delphi\\build.cmd).

    python python/tests/lsp_parity.py [path\\to\\delphipp.exe]

Every test case's input, the tour and the IDE example, sent as the editor would, CRLF and all.
Both run the same rules (with and with-try are switched off on both), so both must say the same.
"""
import json, pathlib, queue, subprocess, sys, threading

PY = pathlib.Path(__file__).resolve().parent.parent
ROOT = PY.parent
EXE = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'delphi' / 'bin' / 'delphipp.exe'


class Client:
    def __init__(self, command, cwd):
        self.p = subprocess.Popen(command, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL)
        self.got = queue.Queue()
        threading.Thread(target=self.reader, daemon=True).start()
        self.next_id = 0

    def reader(self):
        while True:
            length = None
            while True:
                line = self.p.stdout.readline()
                if not line:
                    return
                if not line.strip():
                    break
                if line.lower().startswith(b'content-length:'):
                    length = int(line.split(b':')[1])
            self.got.put(json.loads(self.p.stdout.read(length).decode('utf-8')))

    def send(self, **m):
        body = json.dumps({'jsonrpc': '2.0', **m}).encode('utf-8')
        self.p.stdin.write(b'Content-Length: %d\r\n\r\n' % len(body) + body)
        self.p.stdin.flush()

    def request(self, method, params):
        self.next_id += 1
        self.send(id=self.next_id, method=method, params=params)
        while True:
            m = self.got.get(timeout=60)
            if m.get('id') == self.next_id:
                return m

    def diagnostics(self, uri, text):
        self.send(method='textDocument/didOpen',
                  params={'textDocument': {'uri': uri, 'languageId': 'delphi', 'version': 1, 'text': text}})
        while True:
            m = self.got.get(timeout=60)
            if m.get('method') == 'window/showMessage':
                raise AssertionError(m['params']['message'])
            if m.get('method') == 'textDocument/publishDiagnostics' and m['params']['uri'] == uri:
                return m['params']['diagnostics']

    def close(self):
        assert self.request('shutdown', None).get('result', 'missing') is None
        self.send(method='exit')
        assert self.p.wait(timeout=10) == 0


def key(d):
    r = d['range']
    return (r['start']['line'], r['start']['character'], r['end']['line'], r['end']['character'],
            d['source'], d['message'], d['severity'])


assert EXE.exists(), f'no {EXE}: run delphi\\build.cmd'
python = Client([sys.executable, '-m', 'delphipp.lsp'], PY)
delphi = Client([str(EXE), '--lsp'], ROOT)
for c in (python, delphi):
    init = c.request('initialize', {'capabilities': {}})['result']
    assert init['capabilities'] == {'textDocumentSync': {'openClose': True, 'change': 1},
                                    'codeActionProvider': True}, init

files = [ROOT / 'tests' / 'tour' / 'Tour.dpr', ROOT / 'examples' / 'ide' / 'Greet.dpps']
files += sorted(f for f in (ROOT / 'tests' / 'cases').rglob('*')
                if f.suffix.lower() in ('.pas', '.dpr', '.dpps') and '.out.' not in f.name)
compared, failed = 0, []
for f in files:
    text = f.read_bytes().decode('utf-8', 'replace')
    uri = f.as_uri()
    want = python.diagnostics(uri, text)
    got = delphi.diagnostics(uri, text)
    if sorted(map(key, want)) != sorted(map(key, got)):
        failed.append(f)
        print('DIFFERENT diagnostics:', f.relative_to(ROOT))
        for d in sorted(set(map(key, want)) ^ set(map(key, got))):
            print('   ', 'python' if d in set(map(key, want)) else 'delphi', d)
    params = {'textDocument': {'uri': uri}, 'range': {'start': {'line': 0, 'character': 0},
              'end': {'line': 0, 'character': 0}}, 'context': {'diagnostics': []}}
    want = {a['title']: a for a in python.request('textDocument/codeAction', params)['result']}
    got = {a['title']: a for a in delphi.request('textDocument/codeAction', params)['result']}
    for t in want:
        if want[t] != got.get(t):
            failed.append(f)
            print('DIFFERENT action:', f.relative_to(ROOT), t)
    for t in got:
        if t not in want:
            failed.append(f)
            print('DELPHI ONLY action:', f.relative_to(ROOT), t)
    compared += 1
    python.send(method='textDocument/didClose', params={'textDocument': {'uri': uri}})
    delphi.send(method='textDocument/didClose', params={'textDocument': {'uri': uri}})

# a method the server doesn't have, with an id: an error, not silence
err = delphi.request('textDocument/hover', {'textDocument': {'uri': files[0].as_uri()},
                                             'position': {'line': 0, 'character': 0}})
assert err['error']['code'] == -32601, err
python.close()
delphi.close()
print(f'{compared} files compared')
assert not failed, f'{len(set(failed))} files differ'
print('ok')
