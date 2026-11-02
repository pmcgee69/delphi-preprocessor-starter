"""A rewrite: several uses clauses in a section merged into one.

    uses System.SysUtils, System.Classes;        uses System.SysUtils, System.Classes,
    uses System.Types;                     ->         System.Types;

Delphi allows one uses clause a section (dcc64: E2029 at the second). One
clause per need, each with its own comment, is easier to read and to change;
the merged file is what dcc compiles. The standard grammar already parses
several clauses, each a `declUses` node of its own beside the others, so no new
syntax is needed.

For each clause straight after another, the earlier one's `;` becomes `,` and
the later one's `uses` goes (a space in its place when a unit follows on its
line, for the indent). Nothing else changes.

Clauses with a compiler directive between them are left alone: they may be
alternatives, one per platform, which Delphi allows and its own RTL does; if
both can be on together, dcc says so. Only what the text proves is reported: a
unit named twice in clauses being merged, as an error.
"""


class UsesMerge:
    name = 'uses-merge'
    kinds = ('program', 'library', 'interface', 'implementation')

    def visit(self, node, ctx):
        prev = None                 # the clause before, while only comments follow it
        seen = set()                # the units of the clauses in this run
        for c in node.children:
            if c.type == 'declUses':
                for u in c.children:
                    if u.type == 'declUsesUnit':
                        name = ctx.text(u.children[0])
                        if name.lower() in seen:
                            ctx.report(u, f'{name} is used twice in this section', 'error')
                        else:
                            seen.add(name.lower())
                if prev is not None:
                    ctx.replace(prev.children[-1], ',')
                    uses = c.children[0]
                    same_line = c.children[1].start_point[0] == uses.start_point[0]
                    ctx.replace(uses, ' ' if same_line else '')
                prev = c
            elif c.type != 'comment':
                # a directive (maybe alternatives follow) or a declaration: the run is over
                prev = None
                seen.clear()
