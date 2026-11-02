unit DelphiPP.Rule.AutoProperty;

{ THE `auto-property` RULE: a rewrite. It lets a class declare a property with
  no field and no read or write, and writes the field and both for it:

      TPerson = class                        TPerson = class
      public                                 private
        property Name: string;      ->         FName: string;
      end;                                   public
                                               property Name: string read FName write FName;
                                             end;

  WHY: Vincent Parrett's "Delphi language enhancements" (VSoft, 2016) asked for
  shortcut properties: the field and the read and write add nothing a reader
  needs, but every simple property has to say them.

  NO NEW GRAMMAR NEEDED. The standard grammar parses such a property already
  (bin\delphipp.exe --tree ..\tests\cases\auto-property\basic.pas):
      declSection                      line 10
        kPublic                        public
        declProp                       line 11
          kProperty                    property
          identifier                   Name
          :                            :
          type                         line 11
          ;                            ;
  (the type's own nodes left out here). A property with anything more, such as
  read, write, an index or array parameters, has more children: left alone.

  THE FIELDS go in a private section of their own, inserted just before the
  property's section, so they are declared before the property uses them and
  the section's own keyword (public here) follows them: nothing else changes
  visibility. A property before any keyword (the tree puts those members
  straight in the class, with no section around them) is reported instead:
  whether it is public or published can't be told from the text. A field of the same name already in the class isn't checked:
  dcc reports it. }

interface

uses
  DelphiPP.Engine;

type
  TAutoProperty = class(TRule)
  public
    function Name: string; override;
    function Kinds: TArray<string>; override;
    function Description: string; override;
    procedure Visit(const Node: TNode; Ctx: TContext); override;
  end;

implementation

uses
  System.SysUtils;

// how users choose the rule (--rules auto-property), and how its messages are signed
function TAutoProperty.Name: string;
begin
  Exit( 'auto-property' );
end;

// the Kind of node the engine calls Visit for: as --tree prints it
function TAutoProperty.Kinds: TArray<string>;
begin
  Result := ['declClass'];
end;

// one line, for --list
function TAutoProperty.Description: string;
begin
  Exit( 'A rewrite: a property with no read or write gains a field and both.' );
end;

// property Name: Type; and nothing more
function IsShortcut(const Prop: TNode): Boolean;
const
  Shape: array[0..4] of string = ('kProperty', 'identifier', ':', 'type', ';');
begin
  if Prop.ChildCount <> Length(Shape) then
    Exit( False );
  for var I := 0 to High(Shape) do
    if Prop.Child(I).Kind <> Shape[I] then
      Exit( False );
  Exit( True );
end;

// the section starts with a visibility: private, protected, public, published, strict
function HasVisibility(const Section: TNode): Boolean;
begin
  const K = Section.Child(0).Kind;
  Exit( (K = 'kPrivate') or (K = 'kProtected') or (K = 'kPublic') or
        (K = 'kPublished') or (K = 'kStrict') );
end;

// called once for each class: each section's shortcut properties
procedure TAutoProperty.Visit(const Node: TNode; Ctx: TContext);
begin
  for var I := 0 to Node.ChildCount - 1 do
  begin
    const Section = Node.Child(I);
    // a member before any visibility keyword sits straight in the class
    if (Section.Kind = 'declProp') and IsShortcut(Section) then
      Ctx.Report(Section, 'a property with no read or write before any visibility: ' +
                          'write public or published before it', 'error');
    if Section.Kind <> 'declSection' then
      Continue;
    var Fields: TArray<string>;
    for var J := 0 to Section.ChildCount - 1 do
    begin
      const Prop = Section.Child(J);
      if (Prop.Kind <> 'declProp') or not IsShortcut(Prop) then
        Continue;
      if not HasVisibility(Section) then
      begin
        Ctx.Report(Prop, 'a property with no read or write in a section with no visibility: ' +
                         'write public or published before it', 'error');
        Continue;
      end;
      const PropName = Ctx.Text(Prop.Child(1));
      const Field    = 'F' + PropName;
      Fields := Fields + [Field + ': ' + Ctx.Text(Prop.Child(3)) + ';'];
      Ctx.InsertBefore(Prop.Child(4), ' read ' + Field + ' write ' + Field);
    end;
    if Length(Fields) > 0 then
    begin
      // a private section of the fields, before this one: its keyword follows them
      const Indent = StringOfChar(' ', Section.Column - 1);
      // the file's own line break, as the class has it
      var LineBreak: string := #10;
      if Ctx.Text(Node).Contains(#13#10) then
        LineBreak := #13#10;
      Ctx.InsertBefore(Section, 'private' + LineBreak + Indent + '  ' +
                                string.Join(LineBreak + Indent + '  ', Fields) +
                                LineBreak + Indent);
    end;
  end;
end;

end.
