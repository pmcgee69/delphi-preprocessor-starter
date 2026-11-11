"""A rewrite: `[Derive(ToString)]` on an enumeration writes it a ToString.

    type                                    type
      [Derive(ToString)]                      TSize = (Small, Large);
      TSize = (Small, Large);       ->        TSizeHelper = record helper for TSize
                                                function ToString: string;
                                              end;
    ...
                                            function TSizeHelper.ToString: string;
                                            begin
                                              case Self of
                                                TSize.Small: Result := 'Small';
                                                TSize.Large: Result := 'Large';
                                              else
                                                Result := '';
                                              end;
                                            end;

An attribute is Delphi already, so the grammar parses it (a declType's rttiAttributes); dcc
would only warn that it doesn't know the class Derive. The rule takes the attribute away and
writes a record helper after the type, and its method where a method's body can go: a unit's
interface type in the implementation, after its uses; any other after the type section. The
names are qualified (TSize.Small), so {$SCOPEDENUMS ON} changes nothing. A type has one helper
in scope at a time: one of its own would hide this one, and dcc says nothing.

What the text proves wrong is an error: Derive on a type that isn't an enumeration, a name
Derive doesn't know (ToString is the only one so far), Derive with other attributes in its
brackets, Derive on a type local to a routine (a local type can't have a helper).
"""
MODULES = ('unit', 'program', 'library')
KNOWN = ('tostring',)


def derive_attribute(ctx, decl_type):
    """The declType's attribute brackets that hold Derive, and the Derive call, or (None, None)."""
    for attrs in decl_type.children:
        if attrs.type != 'rttiAttributes':
            continue
        for c in attrs.children:
            if c.type == 'exprCall' and ctx.text(c.children[0]).lower() == 'derive':
                return attrs, c
            if c.type == 'identifier' and ctx.text(c).lower() == 'derive':
                return attrs, c                 # [Derive], with nothing to derive
    return None, None


class Derive:
    name = 'derive'
    kinds = MODULES

    def visit(self, node, ctx):
        nl = '\r\n' if b'\r\n' in ctx.source else '\n'
        implementation = [c for c in node.children if c.type == 'implementation']
        for section in [c for c in node.children if c.type in ('interface', 'implementation')] or [node]:
            for i, types in enumerate(section.children):
                if types.type == 'declTypes':
                    # where the methods go: after this type section, or, for the interface's,
                    # at the start of the implementation, after its uses
                    if section.type == 'interface':
                        impl = implementation[0] if implementation else None
                        anchor = impl.children[0] if impl else None
                        if impl and impl.child_count > 1 and impl.children[1].type == 'declUses':
                            anchor = impl.children[1]
                    else:
                        anchor = types
                    for t in types.children:
                        if t.type == 'declType':
                            self.derive(ctx, t, anchor, nl)
                elif types.type == 'defProc':
                    self.local(ctx, types)

    def local(self, ctx, proc):
        """A routine's own types: reported, as a local type can't have a helper."""
        stack = list(proc.children)
        while stack:
            n = stack.pop()
            if n.type == 'declType':
                attrs, _ = derive_attribute(ctx, n)
                if attrs is not None:
                    ctx.report(attrs, "Derive on a type local to a routine: a local type can't "
                                      'have a helper; declare it outside', 'error')
            stack.extend(n.children)

    def derive(self, ctx, decl_type, anchor, nl):
        attrs, call = derive_attribute(ctx, decl_type)
        if attrs is None:
            return
        if sum(1 for c in attrs.children if c.type not in ('[', ']', ',')) > 1:
            ctx.report(attrs, 'Derive with other attributes: give it brackets of its own', 'error')
            return
        args = [c for c in call.children if c.type == 'exprArgs']
        wanted = [c for c in args[0].children if c.type != ','] if args else []
        if not wanted:
            ctx.report(call, 'Derive with nothing to derive: write Derive(ToString)', 'error')
            return
        unknown = [ctx.text(w) for w in wanted if ctx.text(w).lower() not in KNOWN]
        if unknown:
            ctx.report(call, f"Derive doesn't know {', '.join(unknown)}: ToString is the only one "
                             'so far', 'error')
            return
        body = decl_type.child_by_field_name('type')
        enum = body.children[0] if body is not None and body.child_count else None
        if enum is None or enum.type != 'declEnum':
            ctx.report(call, 'Derive(ToString) is for enumerations', 'error')
            return
        if anchor is None:
            ctx.report(call, "Derive on a unit's interface type, with no implementation for its "
                             'method', 'error')
            return
        name = ctx.text(decl_type.child_by_field_name('name'))
        values = [ctx.text(v.child_by_field_name('name'))
                  for v in enum.children if v.type == 'declEnumValue']
        helper = name + 'Helper'
        indent = ' ' * decl_type.start_point[1]
        # the attribute goes, up to what follows it (the type's name, or another attribute)
        kids = decl_type.children
        after = kids[[k.start_byte for k in kids].index(attrs.start_byte) + 1]
        ctx.replace_span(attrs, after, ctx.text(after))
        ctx.insert_after(decl_type, nl + indent + f'{helper} = record helper for {name}' +
                         nl + indent + '  function ToString: string;' +
                         nl + indent + 'end;')
        width = max(len(v) for v in values)
        arms = ''.join(f"    {name}.{v}:{' ' * (width - len(v))} Result := '{v}';" + nl
                       for v in values)
        ctx.insert_after(anchor, nl + nl +
                         f'function {helper}.ToString: string;' + nl +
                         'begin' + nl +
                         '  case Self of' + nl +
                         arms +
                         '  else' + nl +
                         "    Result := '';" + nl +
                         '  end;' + nl +
                         'end;')
