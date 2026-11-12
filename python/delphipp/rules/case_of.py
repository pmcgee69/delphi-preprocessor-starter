"""A rewrite: `case` on strings, or on class types, written as an `if` chain.

    case s of                      begin
      'hello', 'hi' : x := 1;        if (s = 'hello') or (s = 'hi') then x := 1
      sWorld        : x := 3;  ->    else if s = sWorld then x := 3
    else                           else
      x := 0;                        x := 0;
    end;                           end;

    case x.ClassType of            begin
      TBar : x := 1;           ->    if x.ClassType = TBar then x := 1
    end;                           end;

Every line stays where it was (user, 12 Nov: the if chain's lines didn't match the case's arms,
so dcc's messages and the debugger named the wrong arm): `case … of` becomes `begin`, which the
case's own `end` closes; each label becomes its `if … then`, the arm's statement after it on
its line; the `;` ending an arm goes. An arm holding an `if` with no `else` is put in
`begin … end`, or the next arm's `else` would be that `if`'s. An `else` part of several
statements becomes `else begin … end`, closed by a second `end`.

Delphi's `case` takes only ordinals; Vincent Parrett's "Delphi language
enhancements" (VSoft, 2016) called strings in case statements the most requested
feature of all. The standard grammar parses both already: labels are
expressions to it, whatever their type.

Which cases: one with a string literal of other than one character among its
labels (a string case), or one whose selector ends in .ClassType (an object
case). Any other case is ordinal, and Delphi's own: left alone, a case on a Char
('a', '''', #10, #$0D) among them. Characters are counted as Delphi reads the
literal, so #13#10 is two, and a case with it is a string case.

The selector is written again in each test, so it must be a name or a dotted
name (s, Rec.Name, x.ClassType). Anything else, such as Trim(s), is reported as
an error and the case left alone, as is a range label in a string case.
"""


def is_plain_name(node):
    if node.type == 'identifier':
        return True
    return node.type == 'exprDot' and all(
        c.type == 'kDot' or is_plain_name(c) for c in node.children)


def char_count(literal):
    """The characters a literal stands for: quoted parts ('ab', '''' is one) and
    character codes (#10, #$0A), as in 'ab'#13#10."""
    count = 0
    i = 0
    while i < len(literal):
        if literal[i] == "'":
            i += 1
            while i < len(literal):
                if literal[i] == "'":
                    if i + 1 < len(literal) and literal[i + 1] == "'":
                        i += 1                  # '' inside: one quote
                    else:
                        break                   # the closing quote
                count += 1
                i += 1
            i += 1
        elif literal[i] == '#':
            count += 1
            i += 1
            while i < len(literal) and literal[i] in '$0123456789abcdefABCDEF':
                i += 1
        else:
            i += 1
    return count


def is_string(node, ctx):
    """A string literal that isn't one character: 'hello', '' or #13#10 (a Char
    case has only one-character literals, 'a', '''' or #10, and is Delphi's own)."""
    return node.type == 'literalString' and char_count(ctx.text(node)) != 1


def last_token(node):
    """The node's last token: an arm's `;` can be deep inside it (`if A then x := 1;`)."""
    while node.children:
        node = node.children[-1]
    return node


# statements that close themselves: an `if` inside one can't take an `else` after it
CLOSED = ('block', 'try', 'case', 'repeat', 'asm')


def dangles(node):
    """An `if` with no `else` that an `else` after the statement would belong to."""
    if node.type in CLOSED:
        return False
    if node.type == 'if' and not any(c.type == 'kElse' for c in node.children):
        return True
    return any(dangles(c) for c in node.children)


class CaseOf:
    name = 'case-of'
    kinds = ('case',)
    groups_edits = True     # one edit an arm, shown in an editor as the whole if chain

    def visit(self, node, ctx):
        kids = node.children
        selector = kids[1]
        strings = any(is_string(label, ctx)
                      for c in kids if c.type == 'caseCase'
                      for label in c.children[0].children)
        object_case = (selector.type == 'exprDot'
                       and ctx.text(selector.children[-1]).lower() == 'classtype')
        if not (strings or object_case):
            return                                  # an ordinal case: Delphi's own
        if not is_plain_name(selector):
            ctx.report(selector, 'the selector would be evaluated once for each test: '
                                 'put it in a variable, then case on that', 'error')
            return

        sel = ctx.text(selector)
        nl = '\r\n' if '\r\n' in ctx.text(node) else '\n'     # the file's own line break
        arms = [c for c in kids if c.type == 'caseCase']
        has_else = any(c.type == 'kElse' for c in kids)
        # each arm's test, before any edit: a range label leaves the case as it is
        tests = []
        for c in arms:
            labels = c.children[0]
            parts = []                                  # (row, column, test)
            for label in labels.children:
                if label.type in (',', ':', 'comment'):
                    continue
                if label.type == 'range':
                    ctx.report(label, 'a range label in a case on strings or class types: '
                                      'write it as an if', 'error')
                    return
                parts.append((label.start_point[0], label.start_point[1], f'{sel} = {ctx.text(label)}'))
            if len(parts) == 1:
                test = parts[0][2]
            else:
                # labels on several lines keep their line breaks, so no line moves
                test = f'({parts[0][2]})'
                for (row0, _, _), (row, col, t) in zip(parts, parts[1:]):
                    test += (' or' + nl + ' ' * col if row != row0 else ' or ') + f'({t})'
            spare = labels.end_point[0] - labels.start_point[0] - test.count('\n')
            tests.append(f'if {test} then' + (nl * spare if spare > 0 else ''))

        ctx.replace_span(kids[0], kids[2], 'begin')    # case X of
        for n, (c, test) in enumerate(zip(arms, tests)):
            ctx.replace(c.children[0], test if n == 0 else 'else ' + test)
            # an arm with no statement (`'x' :`, which Delphi allows) has an empty then
            statement = c.children[1] if len(c.children) > 1 and c.children[1].type != ';' else None
            semicolon = last_token(c) if last_token(c).type == ';' else None
            later = n + 1 < len(arms) or has_else
            if statement is not None and later and dangles(statement):
                ctx.insert_before(statement, 'begin ')
                if semicolon is not None:
                    ctx.replace(semicolon, ' end')
                else:
                    ctx.insert_after(statement, ' end')
            elif semicolon is not None:
                ctx.replace(semicolon, '')
        if has_else:
            k = next(i for i, c in enumerate(kids) if c.type == 'kElse')
            end = next(i for i in range(k, len(kids)) if kids[i].type == 'kEnd')
            statements = [c for c in kids[k + 1:end] if c.type not in (';', 'comment')]
            if len(statements) > 1:
                ctx.replace(kids[k], 'else begin')
                ctx.replace(kids[end], 'end end')
