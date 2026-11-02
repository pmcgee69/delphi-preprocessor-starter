"""A rewrite: `case` on strings, or on class types, written as an `if` chain.

    case s of                              if (s = 'hello') or (s = 'hi') then
      'hello', 'hi' : x := 1;                x := 1
      sWorld        : x := 3;      ->      else if s = sWorld then
    else                                     x := 3
      x := 0;                              else
    end;                                     x := 0;

    case x.ClassType of                    if x.ClassType = TBar then
      TBar : x := 1;               ->        x := 1;

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


def statement_text(node, ctx):
    """A statement's text without a `;` the grammar put at its end."""
    t = ctx.text(node).rstrip()
    return t[:-1].rstrip() if t.endswith(';') else t


class CaseOf:
    name = 'case-of'
    kinds = ('case',)

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
        indent = ' ' * node.start_point[1]
        nl = '\r\n' if '\r\n' in ctx.text(node) else '\n'     # the file's own line break
        code = ''
        first = True
        for i, c in enumerate(kids):
            if c.type == 'comment':
                # a // comment's node holds the CR of a CRLF file: left in, it makes a CR CR LF,
                # and dcc counts the lone CR as a line, so its messages' line numbers drift
                code += ctx.text(c).rstrip('\r') + nl + indent
            elif c.type == 'caseCase':
                tests = []
                for label in c.children[0].children:
                    if label.type in (',', ':', 'comment'):
                        continue
                    if label.type == 'range':
                        ctx.report(label, 'a range label in a case on strings or class types: '
                                          'write it as an if', 'error')
                        return
                    tests.append(f'{sel} = {ctx.text(label)}')
                test = tests[0] if len(tests) == 1 else '(' + ') or ('.join(tests) + ')'
                if not first:
                    code += nl + indent + 'else '
                code += f'if {test} then' + nl + indent + '  ' + statement_text(c.children[1], ctx)
                first = False
            elif c.type == 'kElse':
                statements = []
                k = i + 1
                while kids[k].type != 'kEnd':
                    if kids[k].type != ';':
                        statements.append(statement_text(kids[k], ctx))
                    k += 1
                text = statements[0] if len(statements) == 1 else (
                    'begin' + nl + indent + '    '
                    + (';' + nl + indent + '    ').join(statements)
                    + nl + indent + '  end') if statements else ''
                code += nl + indent + 'else' + nl + indent + '  ' + text
                break
        if kids[-1].type == ';':
            code += ';'
        ctx.replace(node, code)
