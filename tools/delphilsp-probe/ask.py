"""Ask a private DelphiLSP for definition / implementation / references at given places.
usage: ask.py <settings.delphilsp.json> <file.pas|dpr> line:col[:label] ...   (1-based)"""
import json, pathlib, subprocess, sys, threading, time, urllib.parse

EXE = r'C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\DelphiLSP.exe'


def uri(p):
    return 'file:///' + urllib.parse.quote(str(pathlib.Path(p).resolve()).replace(chr(92), '/'))


settings, src = sys.argv[1], sys.argv[2]
spots = sys.argv[3:]
p = subprocess.Popen([EXE], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
inbox, lock = [], threading.Lock()


def send(obj):
    b = json.dumps(obj).encode()
    p.stdin.write(b'Content-Length: %d\r\n\r\n' % len(b) + b)
    p.stdin.flush()


def reader():
    while True:
        n = 0
        while True:
            line = p.stdout.readline()
            if not line:
                return
            if line.lower().startswith(b'content-length:'):
                n = int(line.split(b':')[1])
            if line in (b'\r\n', b'\n'):
                break
        m = json.loads(p.stdout.read(n))
        if 'method' in m and 'id' in m:          # a request from the server: answer it
            send({'jsonrpc': '2.0', 'id': m['id'], 'result': None})
        with lock:
            inbox.append(m)


threading.Thread(target=reader, daemon=True).start()
nid = [10]


def ask(method, params, wait=60):
    nid[0] += 1
    i = nid[0]
    send({'jsonrpc': '2.0', 'id': i, 'method': method, 'params': params})
    t = time.time()
    while time.time() - t < wait:
        with lock:
            for m in inbox:
                if m.get('id') == i and 'method' not in m:
                    return m
        time.sleep(0.1)
    return {'timeout': wait}


def notes(since):
    with lock:
        return [m for m in inbox[since:] if 'method' in m and 'id' not in m]


root = pathlib.Path(src).resolve().parent
ask('initialize', {'processId': None, 'rootUri': uri(root), 'capabilities': {},
                   'workspaceFolders': [{'uri': uri(root), 'name': root.name}]})
send({'jsonrpc': '2.0', 'method': 'initialized', 'params': {}})
send({'jsonrpc': '2.0', 'method': 'workspace/didChangeConfiguration',
      'params': {'settings': {'settingsFile': uri(settings)}}})
text = pathlib.Path(src).read_text(encoding='utf-8-sig')
send({'jsonrpc': '2.0', 'method': 'textDocument/didOpen',
      'params': {'textDocument': {'uri': uri(src), 'languageId': 'delphi', 'version': 1, 'text': text}}})

# wait for the project to load: the first diagnostics, or 60 s
t = time.time()
while time.time() - t < 60 and not any(m.get('method') == 'textDocument/publishDiagnostics' for m in notes(0)):
    time.sleep(0.3)
print('loaded after %.1f s' % (time.time() - t))
for m in notes(0):
    print('  note', m['method'], json.dumps(m.get('params'))[:220])

lines = text.splitlines()
for spot in spots:
    parts = spot.split(':')
    ln, col = int(parts[0]), int(parts[1])
    label = parts[2] if len(parts) > 2 else ''
    print('\n== %s  line %d col %d: %s' % (label, ln, col, lines[ln - 1].strip()))
    pos = {'textDocument': {'uri': uri(src)}, 'position': {'line': ln - 1, 'character': col - 1}}
    for method in ('textDocument/definition', 'textDocument/implementation', 'textDocument/references'):
        params = dict(pos)
        if method.endswith('references'):
            params['context'] = {'includeDeclaration': False}
        r = ask(method, params, wait=30)
        res = r.get('result', r.get('error', r))
        if isinstance(res, dict) and 'uri' in res:
            res = [res]
        if isinstance(res, list):
            shown = []
            for loc in res:
                u = loc.get('uri') or loc.get('targetUri')
                rg = loc.get('range') or loc.get('targetSelectionRange')
                f = urllib.parse.unquote(u).rsplit('/', 1)[-1]
                l = rg['start']['line'] + 1
                src_line = lines[l - 1].strip() if f.lower() == pathlib.Path(src).name.lower() else ''
                shown.append('%s:%d %s' % (f, l, src_line))
            print('  %-11s %d: %s' % (method.split('/')[1], len(res), ' | '.join(shown)))
        else:
            print('  %-11s %s' % (method.split('/')[1], json.dumps(res)[:200]))

try:
    ask('shutdown', None, wait=5)
    send({'jsonrpc': '2.0', 'method': 'exit'})
except Exception:
    pass
time.sleep(1)
if p.poll() is None:
    p.kill()
