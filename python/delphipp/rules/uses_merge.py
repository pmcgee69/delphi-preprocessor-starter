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
line, for the indent). When the `uses` is alone on its line and no comment
lies between the clauses, everything from the `;` to the `uses` becomes `,`,
so no empty line is left between the units. Nothing else changes.

Clauses with a compiler directive between them are left alone: they may be
alternatives, one per platform, which Delphi allows and its own RTL does; if
both can be on together, dcc says so. Only what the text proves is reported: a
unit named twice in clauses being merged, as an error.
"""


class UsesMerge:
    name = 'uses-merge'
    kinds = ('program', 'library', 'interface', 'implementation')

    def visit(self, node, ctx):
        run = []                    # the run's clauses, each with: a comment since the one before
        seen = set()                # the units of the clauses in this run
        commented = False           # a comment since the clause before
        for c in node.children:
            if c.type == 'declUses':
                for u in c.children:
                    if u.type == 'declUsesUnit':
                        name = ctx.text(u.children[0])
                        if name.lower() in seen:
                            ctx.report(u, f'{name} is used twice in this section', 'error')
                        else:
                            seen.add(name.lower())
                run.append((c, commented))
                commented = False
            elif c.type == 'comment':
                commented = True
            else:
                # a directive (maybe alternatives follow) or a declaration: the run is over
                self.merge(run, ctx)
                run = []
                seen.clear()
        self.merge(run, ctx)

    def merge(self, run, ctx):
        """One run's clauses merged: each into the one before."""
        if len(run) < 2:
            return
        # the run's edits are one rewrite, from its first clause to its last, so an editor's hover
        # shows the clauses merged, not a `,` alone (user, 13 Nov: "the uses hover is saying
        # almost nothing")
        saved = ctx.group
        ctx.group = (run[0][0].start_byte, run[-1][0].end_byte)
        try:
            for (prev, _), (c, commented) in zip(run, run[1:]):
                uses = c.children[0]
                same_line = c.children[1].start_point[0] == uses.start_point[0]
                if same_line or commented:
                    ctx.replace(prev.children[-1], ',')
                    ctx.replace(uses, ' ' if same_line else '')
                else:
                    # only blanks between: the `uses` line goes with them
                    ctx.replace_span(prev.children[-1], uses, ',')
        finally:
            ctx.group = saved
