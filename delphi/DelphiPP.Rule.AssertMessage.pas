unit DelphiPP.Rule.AssertMessage;

{ A rewrite: `Assert(Cond)` gains a message saying where it is and what failed.
  As the Python side's assert_message.py.

      Assert(Count > 0);
  becomes
      Assert(Count > 0, 'Orders.pas:41: Count > 0');

  An Assert that already has a message is left alone, and so is anything not
  Delphi's Assert: a call written `System.Assert(…)` is taken too, a method named
  Assert on some object is not. The rule proposes text inserted after the
  condition, and the engine applies it. }

interface

uses
  DelphiPP.Engine;

type
  TAssertMessage = class(TRule)
  private
    function IsAssert(const Callee: TNode; Ctx: TContext): Boolean;
  public
    function Name: string; override;
    function Kinds: TArray<string>; override;
    function Description: string; override;
    procedure Visit(const Node: TNode; Ctx: TContext); override;
  end;

implementation

uses
  System.SysUtils;

function TAssertMessage.Name: string;
begin
  Exit( 'assert-message' );
end;

function TAssertMessage.Kinds: TArray<string>;
begin
  Result := ['exprCall'];
end;

function TAssertMessage.Description: string;
begin
  Exit( 'A rewrite: `Assert(Cond)` gains a message saying where it is and what failed.' );
end;

function TAssertMessage.IsAssert(const Callee: TNode; Ctx: TContext): Boolean;
begin
  if Callee.Kind = 'identifier' then
    Exit( SameText(Ctx.Text(Callee), 'Assert') );
  if Callee.Kind = 'exprDot' then
    Exit( SameText(Ctx.Text(Callee).Replace(' ', ''), 'System.Assert') );
  Exit( False );
end;

// the text on one line, however it was written: each run of white space one space
function OneLine(const S: string): string;
begin
  Exit( string.Join(' ', S.Split([' ', #9, #13, #10], TStringSplitOptions.ExcludeEmpty)) );
end;

procedure TAssertMessage.Visit(const Node: TNode; Ctx: TContext);
begin
  var Callee := Node.Field('entity');
  var Args   := Node.Field('args');
  if Callee.IsNull or Args.IsNull or not IsAssert(Callee, Ctx) then
    Exit;
  // the arguments: what isn't a comma or a comment
  var Parts: TArray<TNode>;
  for var I := 0 to Args.ChildCount - 1 do
    if (Args.Child(I).Kind <> ',') and (Args.Child(I).Kind <> 'comment') then
      Parts := Parts + [Args.Child(I)];
  if Length(Parts) <> 1 then
    Exit;                                   // already has a message
  const Cond    = Parts[0];
  const Where   = ExtractFileName(Ctx.FileName) + ':' + IntToStr(Node.Line);
  const Message = (Where + ': ' + OneLine(Ctx.Text(Cond))).Replace('''', '''''');
  Ctx.InsertAfter(Cond, ', ''' + Message + '''');
end;

end.
