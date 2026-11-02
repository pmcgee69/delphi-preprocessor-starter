"""A rewrite: a property with no field and no read or write gains both.

    TPerson = class                        TPerson = class
    public                                 private
      property Name: string;      ->         FName: string;
    end;                                   public
                                             property Name: string read FName write FName;
                                           end;

Vincent Parrett's "Delphi language enhancements" (VSoft, 2016) asked for
shortcut properties. The standard grammar parses such a property already: a
declProp of `property`, its name, `:`, its type and `;`, and nothing more.

The fields go in a private section of their own, inserted just before the
property's section, so they are declared before the property uses them and the
section's own keyword follows them: nothing else changes visibility. A property
before any keyword (straight in the class, with no section around it) is
reported instead: whether it is public or published can't be told from the text.
"""

SHAPE = ('kProperty', 'identifier', ':', 'type', ';')
VISIBILITY = ('kPrivate', 'kProtected', 'kPublic', 'kPublished', 'kStrict')


def is_shortcut(prop):
    return tuple(c.type for c in prop.children) == SHAPE


class AutoProperty:
    name = 'auto-property'
    kinds = ('declClass',)

    def visit(self, node, ctx):
        nl = '\r\n' if '\r\n' in ctx.text(node) else '\n'     # the file's own line break
        for section in node.children:
            # a member before any visibility keyword sits straight in the class
            if section.type == 'declProp' and is_shortcut(section):
                ctx.report(section, 'a property with no read or write before any visibility: '
                                    'write public or published before it', 'error')
            if section.type != 'declSection':
                continue
            fields = []
            for prop in section.children:
                if prop.type != 'declProp' or not is_shortcut(prop):
                    continue
                if section.children[0].type not in VISIBILITY:
                    ctx.report(prop, 'a property with no read or write in a section with no '
                                     'visibility: write public or published before it', 'error')
                    continue
                field = 'F' + ctx.text(prop.children[1])
                fields.append(f'{field}: {ctx.text(prop.children[3])};')
                ctx.insert_before(prop.children[4], f' read {field} write {field}')
            if fields:
                # a private section of the fields, before this one: its keyword follows them
                indent = ' ' * section.start_point[1]
                ctx.insert_before(section, 'private' + nl + indent + '  '
                                  + (nl + indent + '  ').join(fields) + nl + indent)
