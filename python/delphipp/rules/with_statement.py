"""A check: every `with` statement, reported.

Inside `with Form1, Edit1 do Text := Caption;` a reader can't tell whose Text
and whose Caption are meant without knowing every member of both, and a new
member in either class can silently change which one a name means. The
message names the objects, so the fix (a local name for each) is easy to see.

The simplest kind of rule: it looks at one kind of node and reports, and
changes nothing.
"""


class WithStatement:
    name = 'with'
    kinds = ('with',)

    def visit(self, node, ctx):
        objects = [ctx.text(c) for i, c in enumerate(node.children)
                   if node.field_name_for_child(i) == 'entity']
        ctx.report(node, f"`with {', '.join(objects)}` makes each name inside it ambiguous: "
                         f"give each object a local name and write it")
