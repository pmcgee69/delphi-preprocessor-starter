"""A check of two kinds of node: every `with`, and every empty `except` or `finally`.

It shows how one rule handles more than one kind: `kinds` lists both, the
engine calls `visit` for a node of either, and `visit` hands the node on to a
method for its type. Each method is then written as if it were a rule of its
own.

`try … except end;` swallows every exception, silently, and `try … finally
end;` does nothing at all. A comment inside the empty part is taken as
"meant": not reported. Run with the `with` rule, the two report each `with`
twice: choose one.
"""
from .with_statement import WithStatement


class WithAndTry:
    name = 'with-try'
    kinds = ('with', 'try')

    def visit(self, node, ctx):
        if node.type == 'with':
            self.visit_with(node, ctx)
        elif node.type == 'try':
            self.visit_try(node, ctx)

    def visit_with(self, node, ctx):
        WithStatement().visit(node, ctx)

    def visit_try(self, node, ctx):
        kids = node.children
        for c, after in zip(kids, kids[1:]):
            if after.type != 'kEnd':
                continue
            if c.type == 'kExcept':
                ctx.report(c, 'an empty `except` swallows every exception: handle it, or leave out the try')
            if c.type == 'kFinally':
                ctx.report(c, 'an empty `finally` does nothing: fill it, or leave out the try')
