"""A rewrite, the simplest there is: each " inside a string becomes ''.

    S := 'say "hi"';
becomes
    S := 'say ''hi''';

Not useful in itself: a first rewrite to learn from. It looks at one kind of
node, a string, and replaces its whole text. Delphi 12's multi-line strings
('''...''') are left alone, since a quote inside them isn't doubled.

A rewrite rule proposes an edit and the engine applies it: here, the string
replaced by its new text.
"""


class DoubleQuotes:
    name = 'double-quotes'
    kinds = ('literalString',)

    def visit(self, node, ctx):
        text = ctx.text(node)
        if '"' not in text or text.startswith("'''"):
            return
        ctx.replace(node, text.replace('"', "''"))
