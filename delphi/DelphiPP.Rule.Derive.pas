unit DelphiPP.Rule.Derive;

{ THE `derive` RULE: a rewrite. [Derive(ToString)] on an enumeration writes it
  a ToString:

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

  WHY: an enumeration's names, as text, are wanted everywhere (messages, logs,
  a combo box), and written by hand they drift from the type.

  NO NEW GRAMMAR NEEDED. An attribute is Delphi already: dcc would only warn
  that it doesn't know the class Derive. The grammar gives it to the type
  (bin\delphipp.exe --tree ..\tests\cases\derive\basic.pas):
      declType                         line 6
        rttiAttributes                 line 6
          [                            [
          exprCall                     line 6
            identifier                 Derive
            (                          (
            exprArgs                   line 6
              identifier               ToString
            )                          )
          ]                            ]
        identifier                     TSize
        kEq                            line 7
        type                           line 7
          declEnum                     line 7

  THE EDITS: the attribute goes; a record helper is written after the type, and
  its method where a method's body can go: a unit's interface type in the
  implementation, after its uses; any other after the type section. The names
  are qualified (TSize.Small), so $SCOPEDENUMS changes nothing. A type has one
  helper in scope at a time: one of its own would hide this one, and dcc says
  nothing.

  WHAT IS REPORTED, as errors: Derive on a type that isn't an enumeration, a
  name Derive doesn't know (ToString is the only one so far), Derive with other
  attributes in its brackets, Derive on a type local to a routine (a local type
  can't have a helper). }

interface

uses
  DelphiPP.Engine;

type
  TDerive = class(TRule)
  public
    function Name: string; override;
    function Kinds: TArray<string>; override;
    function Description: string; override;
    procedure Visit(const Node: TNode; Ctx: TContext); override;
  end;

implementation

uses
  System.SysUtils, System.Generics.Collections;

// how users choose the rule (--rules derive), and how its messages are signed
function TDerive.Name: string;
begin
  Exit( 'derive' );
end;

// the modules: a type's method goes in another section than the type
function TDerive.Kinds: TArray<string>;
begin
  Result := ['unit', 'program', 'library'];
end;

// one line, for --list
function TDerive.Description: string;
begin
  Exit( 'A rewrite: [Derive(ToString)] on an enumeration writes it a ToString.' );
end;

// the declType's attribute brackets that hold Derive (their index), and the Derive call
function DeriveAttribute(const DeclType: TNode; Ctx: TContext; out Index: Integer;
                         out Call: TNode): Boolean;
begin
  for var I := 0 to DeclType.ChildCount - 1 do
  begin
    const Attrs = DeclType.Child(I);
    if Attrs.Kind <> 'rttiAttributes' then
      Continue;
    for var J := 0 to Attrs.ChildCount - 1 do
    begin
      const C = Attrs.Child(J);
      if ((C.Kind = 'exprCall') and (Ctx.Text(C.Child(0)).ToLower = 'derive')) or
         ((C.Kind = 'identifier') and (Ctx.Text(C).ToLower = 'derive')) then    // [Derive]
      begin
        Index := I;
        Call  := C;
        Exit( True );
      end;
    end;
  end;
  Exit( False );
end;

// a routine's own types: reported, as a local type can't have a helper
procedure Local(const Proc: TNode; Ctx: TContext);
begin
  var Stack := TStack<TNode>.Create;
  try
    for var I := 0 to Proc.ChildCount - 1 do
      Stack.Push(Proc.Child(I));
    while Stack.Count > 0 do
    begin
      const N = Stack.Pop;
      var Index: Integer;
      var Call: TNode;
      if (N.Kind = 'declType') and DeriveAttribute(N, Ctx, Index, Call) then
        Ctx.Report(N.Child(Index), 'Derive on a type local to a routine: a local type can''t ' +
                                   'have a helper; declare it outside', 'error');
      for var I := 0 to N.ChildCount - 1 do
        Stack.Push(N.Child(I));
    end;
  finally
    Stack.Free;
  end;
end;

procedure DeriveOne(const DeclType, Anchor: TNode; HasAnchor: Boolean; const LineBreak: string;
                    Ctx: TContext);
var
  Index : Integer;
  Call  : TNode;
begin
  if not DeriveAttribute(DeclType, Ctx, Index, Call) then
    Exit;
  const Attrs = DeclType.Child(Index);
  var Count := 0;
  for var I := 0 to Attrs.ChildCount - 1 do
    if (Attrs.Child(I).Kind <> '[') and (Attrs.Child(I).Kind <> ']') and (Attrs.Child(I).Kind <> ',') then
      Inc(Count);
  if Count > 1 then
  begin
    Ctx.Report(Attrs, 'Derive with other attributes: give it brackets of its own', 'error');
    Exit;
  end;
  var Wanted: TArray<TNode>;
  for var I := 0 to Call.ChildCount - 1 do
    if Call.Child(I).Kind = 'exprArgs' then
      for var J := 0 to Call.Child(I).ChildCount - 1 do
        if Call.Child(I).Child(J).Kind <> ',' then
          Wanted := Wanted + [Call.Child(I).Child(J)];
  if Length(Wanted) = 0 then
  begin
    Ctx.Report(Call, 'Derive with nothing to derive: write Derive(ToString)', 'error');
    Exit;
  end;
  var Unknown: TArray<string>;
  for var W in Wanted do
    if Ctx.Text(W).ToLower <> 'tostring' then
      Unknown := Unknown + [Ctx.Text(W)];
  if Length(Unknown) > 0 then
  begin
    Ctx.Report(Call, 'Derive doesn''t know ' + string.Join(', ', Unknown) +
                     ': ToString is the only one so far', 'error');
    Exit;
  end;
  const Body = DeclType.Field('type');
  if Body.IsNull or (Body.ChildCount = 0) or (Body.Child(0).Kind <> 'declEnum') then
  begin
    Ctx.Report(Call, 'Derive(ToString) is for enumerations', 'error');
    Exit;
  end;
  if not HasAnchor then
  begin
    Ctx.Report(Call, 'Derive on a unit''s interface type, with no implementation for its ' +
                     'method', 'error');
    Exit;
  end;
  const Enum     = Body.Child(0);
  const TypeName = Ctx.Text(DeclType.Field('name'));
  const Helper   = TypeName + 'Helper';
  const Indent   = StringOfChar(' ', DeclType.Column - 1);
  var Values: TArray<string>;
  var Width := 0;
  for var I := 0 to Enum.ChildCount - 1 do
    if Enum.Child(I).Kind = 'declEnumValue' then
    begin
      const V = Ctx.Text(Enum.Child(I).Field('name'));
      Values := Values + [V];
      if Length(V) > Width then
        Width := Length(V);
    end;
  // the attribute goes, up to what follows it (the type's name, or another attribute)
  const After = DeclType.Child(Index + 1);
  Ctx.ReplaceSpan(Attrs, After, Ctx.Text(After));
  // both insertions come from the attribute: in the {$LINE} output their lines name its
  Ctx.InsertAfter(DeclType, LineBreak + Indent + Helper + ' = record helper for ' + TypeName +
                            LineBreak + Indent + '  function ToString: string;' +
                            LineBreak + Indent + 'end;', Attrs);
  var Arms := '';
  for var V in Values do
    Arms := Arms + '    ' + TypeName + '.' + V + ':' + StringOfChar(' ', Width - Length(V)) +
            ' Result := ''' + V + ''';' + LineBreak;
  Ctx.InsertAfter(Anchor, LineBreak + LineBreak +
                          'function ' + Helper + '.ToString: string;' + LineBreak +
                          'begin' + LineBreak +
                          '  case Self of' + LineBreak +
                          Arms +
                          '  else' + LineBreak +
                          '    Result := '''';' + LineBreak +
                          '  end;' + LineBreak +
                          'end;', Attrs);
end;

// called once for each module: each type section's types, and the routines' own
procedure TDerive.Visit(const Node: TNode; Ctx: TContext);
var
  Impl    : TNode;
  HasImpl : Boolean;
begin
  // the file's own line break
  var LineBreak: string := #10;
  if Ctx.Text(Node).Contains(#13#10) then
    LineBreak := #13#10;
  HasImpl := False;
  var Sections: TArray<TNode>;
  for var I := 0 to Node.ChildCount - 1 do
  begin
    const K = Node.Child(I).Kind;
    if (K = 'interface') or (K = 'implementation') then
      Sections := Sections + [Node.Child(I)];
    if (K = 'implementation') and not HasImpl then
    begin
      Impl    := Node.Child(I);
      HasImpl := True;
    end;
  end;
  if Length(Sections) = 0 then
    Sections := [Node];
  for var Section in Sections do
    for var I := 0 to Section.ChildCount - 1 do
    begin
      const Types = Section.Child(I);
      if Types.Kind = 'declTypes' then
      begin
        // where the methods go: after this type section, or, for the interface's,
        // at the start of the implementation, after its uses
        var Anchor    := Types;
        var HasAnchor := True;
        if Section.Kind = 'interface' then
        begin
          HasAnchor := HasImpl;
          if HasImpl then
          begin
            Anchor := Impl.Child(0);
            if (Impl.ChildCount > 1) and (Impl.Child(1).Kind = 'declUses') then
              Anchor := Impl.Child(1);
          end;
        end;
        for var J := 0 to Types.ChildCount - 1 do
          if Types.Child(J).Kind = 'declType' then
            DeriveOne(Types.Child(J), Anchor, HasAnchor, LineBreak, Ctx);
      end
      else if Types.Kind = 'defProc' then
        Local(Types, Ctx);
    end;
end;

end.
