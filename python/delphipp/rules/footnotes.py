"""A rewrite: footnotes after `end.` become XMLDoc on what they name, and leave the .pas.

    function Greeting(const Name: string): string;     /// <summary>Says hello.</summary>
    ...                                                 /// <param name="Name">who to greet.</param>
    end.                                       ->       function Greeting(const Name: string): string;
                                                        ...
    [Greeting] Says hello.                              end.
      Name: who to greet.

dcc reads nothing after `end.`, and the grammar keeps it as one node, trailingText, so the
footnotes need no new grammar: the rule reads that node's lines itself. A footnote starts at
the line's first column with `[Name]`, `[Type.Member]` or `[Type]`, and the summary after it;
an indented line `Param: text` describes a parameter, `Result: text` a function's result; any
other line goes on with the line before it, and so does a line indented deeper than the
`Param:` line before it, even with a colon in it:

    [Greeting] A greeting.
      G: the name,
         the mood: Calm or Excited,         (G's, not a parameter `the`)
         and the count.

The XMLDoc goes above the declaration Help Insight reads: a unit's interface first, else its
implementation (a routine or type of its own); in a program, its own declarations. Then the
footnotes are deleted: the .pas ends at `end.`. Text after `end.` that doesn't start with a
footnote is left alone, as prose. What the text proves wrong is an error: a name declared
nowhere, or more than once (an overload: a footnote can't tell which), a parameter the
routine doesn't have, a Result for a procedure, a second footnote for one name, a declaration
with XMLDoc (`///`) above it already.
"""
import re

HEADER = re.compile(r'\[([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?)\]\s*(.*)$')
ITEM = re.compile(r'\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$')
MODULES = ('unit', 'program', 'library')


def xml(text):
    """As XML; and '' is ', as in a string: the IDE highlights the text after end. as code, so a
    lone ' would start a string to the end of the line (user, 12 Nov: G'day written G''day)."""
    return text.replace("''", "'").replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


class Note:
    """One footnote: its target, the line it starts on, its summary and its items."""

    def __init__(self, target, line, summary):
        self.target = target
        self.line = line
        self.summary = [summary] if summary else []
        self.items = []                 # [name, line, col, [text...]]


def parse(text, first_line):
    """The footnotes in the text after `end.`, or None when it doesn't start with one."""
    lines = text.replace('\r', '').split('\n')
    notes = []
    for i, line in enumerate(lines):
        if not notes and not line.strip():
            continue
        m = HEADER.match(line)
        if m:
            notes.append(Note(m.group(1), first_line + i, m.group(2).strip()))
            continue
        if not notes:
            return None                 # prose after end., not footnotes
        if not line.strip():
            continue
        m = ITEM.match(line)
        col = len(line) - len(line.lstrip()) + 1
        # a line indented deeper than the item before it goes on with it, a colon in it or not
        # (user, 12 Nov: `G: the name,` with its next lines under it)
        hangs = bool(notes[-1].items) and col > notes[-1].items[-1][2]
        if m and not hangs:
            notes[-1].items.append([m.group(1), first_line + i, col, [m.group(2).strip()]])
        elif notes[-1].items:
            notes[-1].items[-1][3].append(line.strip())
        else:
            notes[-1].summary.append(line.strip())
    return notes


def name_of(ctx, node):
    """A declaration's simple name, lower case, or '' (a method's body has Type.Name)."""
    for c in node.children:
        if c.type == 'identifier':
            return ctx.text(c).lower()
        if c.type in ('genericDot', 'declArgs', ';', ':', '='):
            return ''
    return ''


def candidates(ctx, section, name):
    """In a section, what `name` (no dot) can be: (node the XMLDoc goes above, the node
    before it, the declaration)."""
    found = []
    prev = None
    for c in section.children:
        if c.type == 'declProc' and name_of(ctx, c) == name:
            found.append((c, prev, c))
        elif c.type == 'defProc' and name_of(ctx, c.children[0]) == name:
            found.append((c, prev, c.children[0]))
        elif c.type == 'declTypes':
            tprev = prev
            for t in c.children:
                if t.type == 'declType' and name_of(ctx, t) == name:
                    found.append((t, tprev, t))
                tprev = t
        prev = c
    return found


def members(ctx, decl_type, name):
    """A class's, record's or interface's members called `name`, sections and all."""
    found = []
    body = decl_type.child_by_field_name('type')
    if body is None or body.child_count == 0:
        return found
    body = body.children[0]

    def scan(holder):
        prev = None
        for c in holder.children:
            if c.type == 'declSection':
                scan(c)
            elif c.type in ('declProc', 'declProp') and name_of(ctx, c) == name:
                found.append((c, prev, c))
            prev = c
    scan(body)
    return found


def params(ctx, proc):
    """A routine's parameter names, lower case, as written: `A, B: Integer` gives both."""
    names = {}
    args = proc.child_by_field_name('args')
    if args is None:
        return names
    for arg in args.children:
        if arg.type != 'declArg':
            continue
        for c in arg.children:
            if c.type == ':':
                break
            if c.type == 'identifier':
                names[ctx.text(c).lower()] = ctx.text(c)
    return names


class Footnotes:
    name = 'footnotes'
    kinds = ('root',)

    def visit(self, node, ctx):
        trailing = [c for c in node.children if c.type == 'trailingText']
        modules = [c for c in node.children if c.type in MODULES]
        if not trailing or not modules:
            return
        trailing, module = trailing[0], modules[0]
        notes = parse(ctx.text(trailing), ctx.line(trailing))
        if notes is None:
            return
        nl = '\r\n' if b'\r\n' in ctx.source else '\n'
        sections = [c for c in module.children if c.type in ('interface', 'implementation')] or [module]
        seen = set()
        for note in notes:
            where = f'footnote [{note.target}]'
            if note.target.lower() in seen:
                ctx.report_at(note.line, 2, f'{where}: a second footnote for {note.target}', 'error')
                continue
            seen.add(note.target.lower())
            found = self.find(ctx, sections, note.target.lower())
            if not found:
                ctx.report_at(note.line, 2, f'{where}: no routine, method or type {note.target} '
                                            'is declared in this file', 'error')
                continue
            if len(found) > 1:
                ctx.report_at(note.line, 2, f'{where}: {note.target} is declared {len(found)} '
                                            "times (an overload?): a footnote can't tell which", 'error')
                continue
            above, prev, decl = found[0]
            if prev is not None and prev.type == 'comment' and ctx.text(prev).startswith('///'):
                ctx.report_at(note.line, 2, f'{where}: {note.target} has XMLDoc (///) above it '
                                            'already', 'error')
                continue
            doc = self.doc(ctx, note, decl, where)
            if doc:
                indent = ' ' * above.start_point[1]
                ctx.insert_before(above, ''.join(d + nl + indent for d in doc))
        # the footnotes go: the .pas ends at end.
        end_dot = [c for c in module.children if c.type == 'kEndDot']
        if end_dot:
            ending = nl if ctx.text(trailing).endswith('\n') else ''
            ctx.replace_span(end_dot[0], trailing, '.' + ending)

    @staticmethod
    def find(ctx, sections, target):
        type_name, _, member = target.rpartition('.')
        for section in sections:
            if not type_name:
                found = candidates(ctx, section, target)
            else:
                found = []
                for t, _, _ in candidates(ctx, section, type_name):
                    if t.type == 'declType':
                        found += members(ctx, t, member)
            if found:
                return found
        return []

    @staticmethod
    def doc(ctx, note, decl, where):
        """The XMLDoc lines, after checking each item against the declaration."""
        lines = []
        if note.summary:
            lines.append(f"/// <summary>{xml(' '.join(note.summary))}</summary>")
        names = params(ctx, decl) if decl.type == 'declProc' else {}
        is_function = decl.type == 'declProc' and decl.children[0].type == 'kFunction'
        ok = True
        for name, line, col, text in note.items:
            text = xml(' '.join(text))
            if name.lower() == 'result':
                if not is_function:
                    ctx.report_at(line, col, f"{where}: {note.target} isn't a function: Result has "
                                             'nothing to describe', 'error')
                    ok = False
                    continue
                lines.append(f'/// <returns>{text}</returns>')
            elif name.lower() in names:
                lines.append(f'/// <param name="{names[name.lower()]}">{text}</param>')
            else:
                ctx.report_at(line, col, f'{where}: {note.target} has no parameter {name}', 'error')
                ok = False
        return lines if ok else []
