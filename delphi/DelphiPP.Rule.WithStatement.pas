unit DelphiPP.Rule.WithStatement;

{ A check: every `with` statement, reported. As the Python side's
  with_statement.py, word for word in its message.

  Inside `with Form1, Edit1 do Text := Caption;` a reader can't tell whose Text
  and whose Caption are meant without knowing every member of both, and a new
  member in either class can silently change which one a name means. The
  message names the objects, so the fix (a local name for each) is easy to see. }

interface

uses
  DelphiPP.Engine;

type
  TWithStatement = class(TRule)
  public
    function Name: string; override;
    function Kinds: TArray<string>; override;
    function Description: string; override;
    procedure Visit(const Node: TNode; Ctx: TContext); override;
  end;

implementation

uses
  System.SysUtils;

function TWithStatement.Name: string;
begin
  Exit( 'with' );
end;

function TWithStatement.Kinds: TArray<string>;
begin
  Result := ['with'];
end;

function TWithStatement.Description: string;
begin
  Exit( 'A check: every `with` statement, reported.' );
end;

procedure TWithStatement.Visit(const Node: TNode; Ctx: TContext);
var
  Objects: TArray<string>;
begin
  // the objects: what stands between `with` and `do`, but the commas
  for var I := 1 to Node.ChildCount - 1 do
  begin
    var C := Node.Child(I);
    if C.Kind = 'kDo' then
      Break;
    if C.Kind <> ',' then
      Objects := Objects + [Ctx.Text(C)];
  end;
  Ctx.Report(Node, '`with ' + string.Join(', ', Objects) + '` makes each name inside it ' +
                   'ambiguous: give each object a local name and write it');
end;

end.
