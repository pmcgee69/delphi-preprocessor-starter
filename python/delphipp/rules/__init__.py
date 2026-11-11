"""The rules. A rule is a class with:

    name     how it is chosen on the command line and named in its messages
    kinds    the node types it wants to see (as the grammar names them)
    visit(node, ctx)
             called for each such node, in source order; it may call
             ctx.report(...) and ctx.replace / insert_before / insert_after

Add yours to ALL. Each is in a file of its own, with a test folder of its
own in tests/cases/<name>/.
"""
from .with_statement import WithStatement
from .with_and_try   import WithAndTry
from .assert_message   import AssertMessage
from .uses_merge       import UsesMerge
from .case_of          import CaseOf
from .auto_property    import AutoProperty
from .double_quotes    import DoubleQuotes
from .footnotes        import Footnotes
from .derive           import Derive

ALL = [AssertMessage, UsesMerge, CaseOf, AutoProperty, DoubleQuotes, Footnotes, Derive]


def by_name(names=None):
    """The rules named (a comma-separated string or a list), or all of them."""
    if not names:
        return [r() for r in ALL]
    if isinstance(names, str):
        names = [n.strip() for n in names.split(',') if n.strip()]
    known = {r.name: r for r in ALL}
    unknown = [n for n in names if n not in known]
    if unknown:
        raise SystemExit(f"no rule {', '.join(unknown)}; the rules are {', '.join(known)}")
    return [known[n]() for n in names]
