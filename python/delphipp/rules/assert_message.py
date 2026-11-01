"""A rewrite: `Assert(Cond)` gains a message saying where it is and what failed.

    Assert(Count > 0);
becomes
    Assert(Count > 0, 'Orders.pas:41: Count > 0');

Delphi's own message for a failed Assert names the unit and line too, but only
with assertions on and debug information, and never the condition. An Assert
that already has a message is left alone, and so is anything not Delphi's
Assert: a call written `System.Assert(…)` is taken too, a method named Assert
on some object is not.

A rewrite rule proposes an edit and the engine applies it: here, text
inserted after the condition.
"""
import pathlib


class AssertMessage:
    name = 'assert-message'
    kinds = ('exprCall',)

    def visit(self, node, ctx):
        callee = node.child_by_field_name('entity')
        args = node.child_by_field_name('args')
        if callee is None or args is None or not self.is_assert(callee, ctx):
            return
        parts = [c for c in args.named_children if c.type != 'comment']
        if len(parts) != 1:
            return                              # already has a message
        cond = parts[0]
        where = f"{pathlib.Path(ctx.filename).name}:{ctx.line(node)}"
        text = ' '.join(ctx.text(cond).split())  # one line, however it was written
        message = f"{where}: {text}".replace("'", "''")
        ctx.insert_after(cond, f", '{message}'")

    @staticmethod
    def is_assert(callee, ctx) -> bool:
        if callee.type == 'identifier':
            return ctx.text(callee).lower() == 'assert'
        if callee.type == 'exprDot':
            return ctx.text(callee).replace(' ', '').lower() == 'system.assert'
        return False
