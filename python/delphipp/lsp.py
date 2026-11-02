"""A language server: the rules' findings in your editor as you type.

    python -m delphipp.lsp        (from the python folder, or with it on PYTHONPATH)

What a rule reports shows as a diagnostic. What a rule would rewrite shows too, with the new text
in the message, and a code action applies a rule's rewrites to the file. Nothing is changed until
you ask. JSON-RPC over stdin and stdout, standard library only besides the engine.
"""
from __future__ import annotations

import json
import sys
import threading
import time
import urllib.parse
import urllib.request

from . import engine, rules

PAUSE = 0.2     # seconds after the last edit before running the rules
SEVERITY = {'error': 1, 'warning': 2, 'hint': 4}


class Positions:
    """LSP positions, in lines and UTF-16 units, from byte offsets."""

    def __init__(self, raw: bytes):
        self.raw = raw
        self.starts = [0]
        at = raw.find(b'\n')
        while at >= 0:
            self.starts.append(at + 1)
            at = raw.find(b'\n', at + 1)

    def of_line_col(self, line: int, col: int) -> dict:
        start = self.starts[min(line, len(self.starts) - 1)]
        text = self.raw[start:start + col].decode('utf-8', 'ignore')
        return {'line': line, 'character': len(text.encode('utf-16-le')) // 2}

    def of_byte(self, offset: int) -> dict:
        lo, hi = 0, len(self.starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if self.starts[mid] <= offset:
                lo = mid
            else:
                hi = mid - 1
        return self.of_line_col(lo, offset - self.starts[lo])


def line_end_byte(raw: bytes, offset: int) -> int:
    end = raw.find(b'\n', offset)
    return (end if end >= 0 else len(raw))


def word_end(raw: bytes, offset: int) -> int:
    """A squiggle needs some width: the word at a message's or an insertion's place."""
    stop = line_end_byte(raw, offset)
    i = offset
    while i < stop and (chr(raw[i]).isalnum() or raw[i] in b'_'):
        i += 1
    return i if i > offset else min(offset + 1, stop)


def path_of(uri: str) -> str:
    return urllib.request.url2pathname(urllib.parse.urlparse(uri).path)


def analyse(text: str, filename: str) -> tuple[list[dict], dict]:
    """(diagnostics, {rule: [LSP text edits]})."""
    raw = text.encode('utf-8')
    pos = Positions(raw)
    _, messages, edits = engine.run_with_edits(raw, rules.by_name(), filename)
    found = []
    for m in messages:
        row, col = m.line - 1, m.col - 1
        start = pos.starts[min(row, len(pos.starts) - 1)] + col
        found.append({'range': {'start': pos.of_line_col(row, col), 'end': pos.of_byte(word_end(raw, start))},
                      'severity': SEVERITY.get(m.level, 3), 'source': m.rule, 'message': m.text})
    actions: dict[str, list[dict]] = {}
    for e in edits:
        new = e.text.decode('utf-8', 'replace')
        actions.setdefault(e.rule, []).append({'range': {'start': pos.of_byte(e.start), 'end': pos.of_byte(e.end)},
                                               'newText': new})
        end = e.end if e.end > e.start else word_end(raw, e.start)
        found.append({'range': {'start': pos.of_byte(e.start), 'end': pos.of_byte(end)}, 'severity': 3,
                      'source': e.rule, 'message': f'{e.rule} would write:\n{new.strip() or "(remove this)"}'})
    return found, actions


class Server:
    def __init__(self, stdin, stdout):
        self.stdin, self.stdout = stdin, stdout
        self.write_lock = threading.Lock()
        self.changed = threading.Condition()
        self.pending: dict[str, tuple[str, float]] = {}
        self.actions: dict[str, dict] = {}
        self.exiting = False

    def send(self, obj: dict):
        body = json.dumps({'jsonrpc': '2.0', **obj}, ensure_ascii=False).encode('utf-8')
        with self.write_lock:
            self.stdout.write(b'Content-Length: %d\r\n\r\n' % len(body) + body)
            self.stdout.flush()

    def read(self) -> dict | None:
        length = None
        while True:
            line = self.stdin.readline()
            if not line:
                return None
            line = line.strip()
            if not line:
                break
            name, _, value = line.partition(b':')
            if name.lower() == b'content-length':
                length = int(value)
        return json.loads(self.stdin.read(length).decode('utf-8'))

    def want(self, uri: str, text: str):
        with self.changed:
            self.pending[uri] = (text, time.monotonic())
            self.changed.notify_all()

    def worker(self):
        while True:
            with self.changed:
                while not self.pending and not self.exiting:
                    self.changed.wait()
                if self.exiting:
                    return
                uri = min(self.pending, key=lambda u: self.pending[u][1])
                text, when = self.pending[uri]
                wait = when + PAUSE - time.monotonic()
                if wait > 0:
                    self.changed.wait(wait)
                    continue
                del self.pending[uri]
            try:
                # the path, not the uri: assert-message writes the file's name into the code
                found, actions = analyse(text.replace('\r\n', '\n'), path_of(uri))
            except Exception as e:      # a rule being written may well fail: the editor stays up
                self.send({'method': 'window/logMessage', 'params': {
                    'type': 1, 'message': f'the rules failed on {uri}: {type(e).__name__}: {e}'}})
                continue
            with self.changed:
                stale = uri in self.pending
                if not stale:
                    self.actions[uri] = actions
            if not stale:
                self.send({'method': 'textDocument/publishDiagnostics',
                           'params': {'uri': uri, 'diagnostics': found}})

    def code_actions(self, uri: str) -> list[dict]:
        by_rule = self.actions.get(uri, {})
        out = []
        for rule, edits in sorted(by_rule.items()):
            out.append({'title': f'Apply {rule} to this file ({len(edits)} edit{"s" if len(edits) != 1 else ""})',
                        'kind': 'quickfix', 'edit': {'changes': {uri: edits}}})
        if len(by_rule) > 1:
            every = [e for edits in by_rule.values() for e in edits]
            out.append({'title': f'Apply every rule to this file ({len(every)} edits)', 'kind': 'source',
                        'edit': {'changes': {uri: every}}})
        return out

    def serve(self):
        threading.Thread(target=self.worker, daemon=True).start()
        while True:
            m = self.read()
            if m is None or m.get('method') == 'exit':
                break
            method, params, id_ = m.get('method'), m.get('params') or {}, m.get('id')
            if method is None:
                continue
            if method == 'initialize':
                self.send({'id': id_, 'result': {
                    'capabilities': {'textDocumentSync': {'openClose': True, 'change': 1},
                                     'codeActionProvider': True},
                    'serverInfo': {'name': 'delphipp'}}})
            elif method == 'shutdown':
                self.send({'id': id_, 'result': None})
            elif method == 'textDocument/didOpen':
                self.want(params['textDocument']['uri'], params['textDocument']['text'])
            elif method == 'textDocument/didChange':
                self.want(params['textDocument']['uri'], params['contentChanges'][-1]['text'])
            elif method == 'textDocument/didClose':
                uri = params['textDocument']['uri']
                with self.changed:
                    self.pending.pop(uri, None)
                    self.actions.pop(uri, None)
                self.send({'method': 'textDocument/publishDiagnostics',
                           'params': {'uri': uri, 'diagnostics': []}})
            elif method == 'textDocument/codeAction':
                self.send({'id': id_, 'result': self.code_actions(params['textDocument']['uri'])})
            elif id_ is not None:
                self.send({'id': id_, 'error': {'code': -32601, 'message': f'no {method}'}})
        with self.changed:
            self.exiting = True
            self.changed.notify_all()


def main():
    stdin, stdout = sys.stdin.buffer, sys.stdout.buffer
    sys.stdout = sys.stderr     # stdout is the protocol's: a rule's print goes to the log
    Server(stdin, stdout).serve()


if __name__ == '__main__':
    main()
