unit DelphiPP.Rule.AssertMessage;

{ THE `assert-message` RULE: a rewrite. Each `Assert(Cond)` gains a message
  saying where it is and what failed:

      Assert(Count > 0);
  becomes
      Assert(Count > 0, 'Orders.pas:41: Count > 0');

  An Assert that has a message already is left alone, and so is a method that
  happens to be called Assert (C.Assert(Ok)). `System.Assert(Ok)` is taken.

  Read the `with` rule (DelphiPP.Rule.WithStatement.pas) first: it says how a
  rule works. A rewrite is the same, but instead of only reporting, Visit
  proposes an edit, and the engine applies it. Rules never change the text
  themselves: the engine applies every rule's edits at once, and refuses two
  that overlap, so a file no rule changes comes out byte for byte as it went in.

  HOW THIS ONE WAS MADE:

  1. A sample: tests\cases\assert-message\basic.pas.
  2. Its tree (bin\delphipp.exe --tree ...): a call is a node of Kind
     'exprCall', with the callee first and its arguments in an 'exprArgs' child:
         exprCall                     line 20
           identifier                 Assert
           (                          (
           exprArgs                   line 20
             exprBinary               line 20
               identifier             Count
               kGt                    >
               literalNumber          0
           )                          )
     `System.Assert(Ok)` has an 'exprDot' as its callee instead, and a second
     argument shows as a ',' and another child in exprArgs.
  3. So Kinds is ['exprCall']; Visit checks the callee is Assert, that exprArgs
     holds one argument, and proposes text inserted after it (Ctx.InsertAfter).
  4. Register, build, run and test, as the `with` rule says. The test's
     expected output is basic.out.pas: the file as the rule rewrites it. }

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

// Assert, or System.Assert; not some object's method called Assert
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

// called once for each call in the file
procedure TAssertMessage.Visit(const Node: TNode; Ctx: TContext);
begin
  // the callee is the first child; the arguments are the child of Kind 'exprArgs'
  var Args := Default(TNode);                 // a null node, until one is found
  for var I := 0 to Node.ChildCount - 1 do
    if Node.Child(I).Kind = 'exprArgs' then
      Args := Node.Child(I);
  if (Node.ChildCount = 0) or Args.IsNull or not IsAssert(Node.Child(0), Ctx) then
    Exit;
  // the arguments: what isn't a comma or a comment
  var Parts: TArray<TNode>;
  for var I := 0 to Args.ChildCount - 1 do
    if (Args.Child(I).Kind <> ',') and (Args.Child(I).Kind <> 'comment') then
      Parts := Parts + [Args.Child(I)];
  if Length(Parts) <> 1 then
    Exit;                                   // already has a message
  // the message: file and line, then the condition as written, on one line,
  // with each ' doubled, as a Delphi string needs
  const Cond    = Parts[0];
  const Where   = ExtractFileName(Ctx.FileName) + ':' + IntToStr(Node.Line);
  const Message = (Where + ': ' + OneLine(Ctx.Text(Cond))).Replace('''', '''''');
  // the edit: text inserted after the condition; the engine applies it
  Ctx.InsertAfter(Cond, ', ''' + Message + '''');
end;

end.
