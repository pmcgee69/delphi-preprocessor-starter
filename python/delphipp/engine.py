"""The engine: parse a Delphi file, show every node to the rules that asked
for its kind, collect what they report and the edits they propose, and apply
the edits. A file no rule changes comes out byte for byte as it went in.

A rule never edits text itself. It proposes a replacement of a byte range;
the engine checks that no two proposals overlap and applies them all at once,
from the end of the file back, so one rule's edit can't shift another's.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from .grammar import parser


@dataclass
class Message:
    level: str          # 'error', 'warning' or 'hint'
    line: int           # 1-based
    col: int            # 1-based, in bytes
    text: str
    rule: str

    def __str__(self) -> str:
        return f"{self.line}:{self.col}: {self.level}: {self.text} [{self.rule}]"


@dataclass
class Edit:
    start: int          # byte offsets into the source
    end: int
    text: bytes
    rule: str


class Context:
    """What a rule sees while it runs on one file."""

    def __init__(self, source: bytes, filename: str, encoding: str):
        self.source = source
        self.filename = filename
        self.encoding = encoding        # the file's own, for text a rule inserts
        self.messages: list[Message] = []
        self.edits: list[Edit] = []
        self.rule = ''                  # the rule now running, for its messages and edits

    # --- reading ---------------------------------------------------------
    def text(self, node) -> str:
        return self.source[node.start_byte:node.end_byte].decode(self.encoding)

    @staticmethod
    def line(node) -> int:
        return node.start_point[0] + 1

    # --- reporting -------------------------------------------------------
    def report(self, node, text: str, level: str = 'warning'):
        r, c = node.start_point
        self.messages.append(Message(level, r + 1, c + 1, text, self.rule))

    # --- proposing edits -------------------------------------------------
    def replace(self, node, text: str):
        self._edit(node.start_byte, node.end_byte, text)

    def insert_before(self, node, text: str):
        self._edit(node.start_byte, node.start_byte, text)

    def insert_after(self, node, text: str):
        self._edit(node.end_byte, node.end_byte, text)

    def _edit(self, start, end, text):
        self.edits.append(Edit(start, end, text.encode(self.encoding), self.rule))


def decode(raw: bytes) -> tuple[str, str]:
    """UTF-8 (with or without a BOM), else Windows-1252: what Delphi sources are."""
    for enc in ('utf-8-sig', 'cp1252', 'latin-1'):
        try:
            raw.decode(enc)
            return ('utf-8' if enc == 'utf-8-sig' else enc), enc
        except UnicodeDecodeError:
            continue
    return 'latin-1', 'latin-1'


def run(raw: bytes, rules, filename: str = '<input>') -> tuple[bytes, list[Message]]:
    """Run the rules over one file's bytes: (the output's bytes, the messages)."""
    out, messages, _ = run_with_edits(raw, rules, filename)
    return out, messages


def run_with_edits(raw: bytes, rules, filename: str = '<input>') -> tuple[bytes, list[Message], list[Edit]]:
    """As run, and the edits applied, in source order, for a tool to show or map lines through:
    none if they overlapped."""
    encoding, _ = decode(raw)
    tree = parser().parse(raw)
    ctx = Context(raw, filename, encoding)
    if tree.root_node.has_error:
        first = _first_error(tree.root_node)
        r, c = first.start_point
        ctx.messages.append(Message('error', r + 1, c + 1,
                                    'the Delphi grammar cannot parse this; the rules '
                                    'still run on the parts it can', 'parser'))
    wanted: dict[str, list] = {}
    for rule in rules:
        for kind in rule.kinds:
            wanted.setdefault(kind, []).append(rule)
    # every node, in source order, by a loop: deep trees (a long a + b + c + …)
    # would pass Python's recursion limit
    stack = [tree.root_node]
    while stack:
        node = stack.pop()
        for rule in wanted.get(node.type, ()):
            ctx.rule = rule.name
            rule.visit(node, ctx)
        stack.extend(reversed(node.children))
    out = _apply(raw, ctx)
    applied = [] if any(m.rule == 'engine' for m in ctx.messages) else \
        sorted(ctx.edits, key=lambda e: (e.start, e.end))
    return out, sorted(ctx.messages, key=lambda m: (m.line, m.col)), applied


def _first_error(root):
    """The error the parser found: the innermost node holding one, first in
    the file. Down from the root, which is itself an ERROR node when the
    grammar can't read the file's top level (as the Delphi side does it)."""
    n = root
    while True:
        for c in n.children:
            if c.has_error or c.type == 'ERROR':
                n = c
                break
        else:
            return n


def _apply(raw: bytes, ctx: Context) -> bytes:
    edits = sorted(ctx.edits, key=lambda e: (e.start, e.end))
    for a, b in zip(edits, edits[1:]):
        if b.start < a.end:
            r = raw.count(b'\n', 0, b.start) + 1
            ctx.messages.append(Message('error', r, 1,
                                        f"two edits overlap ({a.rule}, {b.rule}): neither applied "
                                        f"to this file", 'engine'))
            return raw
    out = raw
    for e in reversed(edits):
        out = out[:e.start] + e.text + out[e.end:]
    return out
