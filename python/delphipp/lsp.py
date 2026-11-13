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


def is_word(b: int) -> bool:
    return chr(b).isalnum() or b == ord('_')


def first_non_blank(raw: bytes, start: int, end: int) -> int:
    while start < end and raw[start] in b' \t\r\n\f\v':
        start += 1
    return start


# words before a declaration's name: `function Greeting`, `class procedure P`, `const C`
BEFORE_NAME = {b'class', b'function', b'procedure', b'constructor', b'destructor', b'operator',
               b'property', b'type', b'const', b'var', b'threadvar', b'resourcestring'}


def insertion_range(raw: bytes, start: int, text: bytes) -> tuple[int, int]:
    """An insertion's squiggle. A line of its own, put above a declaration (footnotes' ///): the
    name it declares, past attribute lines and `function` and the like, so hovering TMood shows
    TMood's /// though it goes above [Derive(ToString)] (user, 13 Nov: "i'd actually prefer if
    just tmood, tgreeting and greeting were the underlines"). Else the word at its place."""
    line_start = raw.rfind(b'\n', 0, start) + 1
    last_break = text.rfind(b'\n')
    if last_break >= 0 and not raw[line_start:start].strip() and not text[last_break + 1:].strip():
        end = line_end_byte(raw, start)
        first = first_non_blank(raw, start, end)
        while first < end and raw[first] == ord('[') and end < len(raw):
            end = line_end_byte(raw, end + 1)
            first = first_non_blank(raw, raw.rfind(b'\n', 0, end) + 1, end)
        at = first
        while at < end:
            stop = at
            while stop < end and is_word(raw[stop]):
                stop += 1
            if stop == at:
                break
            if raw[at:stop].lower() not in BEFORE_NAME:
                return at, stop
            at = first_non_blank(raw, stop, end)
    # lines of its own after a line's end (derive's helper after `TMood = (...);`, its ToString
    # after `implementation`): that line's last word, or its last character, not a zero-width
    # squiggle that an editor shows on the last letter (user, 13 Nov: "TMoodHelper.ToString only
    # hovers on the last letter 'n' of 'implementation'")
    if text[:1] in (b'\r', b'\n') and not raw[start:line_end_byte(raw, start)].strip():
        b = start
        while b > line_start and raw[b - 1] in b' \t\r':
            b -= 1
        a = b
        while a > line_start and is_word(raw[a - 1]):
            a -= 1
        if a == b and b > line_start:
            a = b - 1
        if a < b:
            return a, b
    return start, word_end(raw, start)


def changed_part(raw: bytes, e) -> tuple[int, int, bytes]:
    """An edit less what it leaves as it was, at both ends: derive's replacing of
    `[Derive(ToString)]   // comment` with `// comment` is the attribute's removal. Whole UTF-8
    characters only."""
    old, new = raw[e.start:e.end], e.text
    p = 0
    while p < len(old) and p < len(new) and old[p] == new[p]:
        p += 1
    while 0 < p < len(new) and new[p] & 0xC0 == 0x80:
        p -= 1
    q = 0
    while q < len(old) - p and q < len(new) - p and old[-1 - q] == new[-1 - q]:
        q += 1
    while q > 0 and new[len(new) - q] & 0xC0 == 0x80:
        q -= 1
    return e.start + p, e.end - q, new[p:len(new) - q]


def code_pieces(raw: bytes, start: int, end: int) -> list[tuple[int, int]]:
    """[start, end) less its comments: the stretches of code between them, each without the blanks
    after it. A squiggle is one stretch, so a rewritten case's is two, `case X of` and the arms,
    not one over the comment between (user, 13 Nov: "it would be good if case underline excluded
    the comment on that line")."""
    pieces, at, i = [], None, start

    def close(j):
        nonlocal at
        if at is not None:
            while j > at and raw[j - 1] in b' \t\r\n':
                j -= 1
            pieces.append((at, j))
            at = None

    while i < end:
        c = raw[i]
        if raw.startswith(b'//', i):
            close(i)
            i = min(line_end_byte(raw, i), end)
        elif c == ord('{') or raw.startswith(b'(*', i):
            close(i)
            stop = raw.find(b'}' if c == ord('{') else b'*)', i)
            i = end if stop < 0 else min(stop + (1 if c == ord('{') else 2), end)
        elif c == ord("'"):
            if at is None:
                at = i
            i += 1
            while i < end and raw[i] != 10:     # to its closing quote; '' is a quote in it
                if raw[i] == ord("'"):
                    if i + 1 < end and raw[i + 1] == ord("'"):
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
        else:
            if at is None and c not in b' \t\r\n':
                at = i
            i += 1
    close(end)
    return pieces or [(start, end)]


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
    groups: dict[tuple[str, tuple[int, int]], list] = {}
    for e in edits:
        new = e.text.decode('utf-8', 'replace')
        actions.setdefault(e.rule, []).append({'range': {'start': pos.of_byte(e.start), 'end': pos.of_byte(e.end)},
                                               'newText': new})
        if e.group is not None:
            groups.setdefault((e.rule, e.group), []).append(e)
            continue
        start, end, written = changed_part(raw, e)
        if end > start:
            if not written.strip():
                while end > start and raw[end - 1] in b' \t':     # the blanks it takes after it
                    end -= 1
        else:
            start, end = insertion_range(raw, start, written)
        body = written.decode('utf-8', 'replace').strip()
        # what the rule writes next from here: derive's helper declaration, from the attribute it
        # removes; its ToString has a squiggle of its own where it goes (user, 13 Nov: "[Derive]
        # hover ... nothing shows TMoodHelper", "derive is still not showing just the declaration")
        more = [o.text.decode('utf-8', 'replace').strip() for o in edits
                if o is not e and o.rule == e.rule and o.origin is not None and o.origin == e.start][:1]
        if more and not body:
            message = f'{e.rule} would remove this, and write:\n' + '\n\n'.join(more)
        elif more:
            message = f'{e.rule} would write:\n{body}\n\nand:\n' + '\n\n'.join(more)
        else:
            message = f'{e.rule} would write:\n{body or "(remove this)"}'
        found.append({'range': {'start': pos.of_byte(start), 'end': pos.of_byte(end)}, 'severity': 3,
                      'source': e.rule, 'message': message})
    # a rule's edits from one visit (a case-of's, one an arm) as one diagnostic over the node,
    # whose message is the node as rewritten: the whole if chain, as the IDE's hover shows it
    for (rule, (start, end)), group in groups.items():
        whole, at = [], start
        for e in group:     # in source order, as run_with_edits gives them
            whole.append(raw[at:e.start])
            whole.append(e.text)
            at = e.end
        whole.append(raw[at:end])
        new = b''.join(whole).decode('utf-8', 'replace')
        for a, b in code_pieces(raw, start, end):
            found.append({'range': {'start': pos.of_byte(a), 'end': pos.of_byte(b)}, 'severity': 3,
                          'source': rule, 'message': f'{rule} would write:\n{new.strip() or "(remove this)"}'})
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
            # a rule being written may well fail, and the grammar may not be downloaded yet (a
            # SystemExit, which would end this thread in silence): the editor hears why
            except (Exception, SystemExit) as e:
                text = f'the rules failed on {uri}: {type(e).__name__}: {e}'
                self.send({'method': 'window/showMessage', 'params': {'type': 1, 'message': text}})
                self.send({'method': 'window/logMessage', 'params': {'type': 1, 'message': text}})
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
