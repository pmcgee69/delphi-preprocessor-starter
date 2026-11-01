unit DelphiPP.Rule.WithAndTry;

{ THE `with-try` RULE: a check of two kinds of node, to show how one rule
  handles more than one. It reports every `with` statement, as the `with` rule
  does, and every empty `except` or `finally`.

  WHY THE TRY PART: `try … except end;` swallows every exception, silently,
  and `try … finally end;` does nothing at all. A comment inside the empty
  part is taken as "meant": not reported.

  TWO KINDS. Kinds lists both, ['with', 'try'], and the engine calls Visit for
  every node of either kind. So Visit, unlike the `with` rule's, must ask which
  kind it was given (Node.Kind), and passes the node on to a procedure for
  that kind. Each procedure is then written as if it were a rule of its own.

  The tree of a try statement (bin\delphipp.exe --tree ..\tests\cases\with-try\basic.pas):
      try                              line 17
        kTry                           try
        statements                     line 18
          …
        kExcept                        except
        kEnd                           end
        ;                              ;
  An empty part is a kExcept or kFinally followed straight by kEnd.

  Run over the same files as the `with` rule, the two report each `with`
  twice, once for each rule: choose one (--rules with or --rules with-try). }

interface

uses
  DelphiPP.Engine;

type
  TWithAndTry = class(TRule)
  private
    procedure VisitWith(const Node: TNode; Ctx: TContext);
    procedure VisitTry(const Node: TNode; Ctx: TContext);
  public
    function Name: string; override;
    function Kinds: TArray<string>; override;
    function Description: string; override;
    procedure Visit(const Node: TNode; Ctx: TContext); override;
  end;

implementation

uses
  System.SysUtils,
  System.StrUtils;

// how users choose the rule (--rules with-try), and how its messages are signed: [with-try]
function TWithAndTry.Name: string;
begin
  Exit( 'with-try' );
end;

// both Kinds: the engine calls Visit for a node of either
function TWithAndTry.Kinds: TArray<string>;
begin
  Result := ['with', 'try'];
end;

// one line, for --list
function TWithAndTry.Description: string;
begin
  Exit( 'A check of two kinds: every `with`, and every empty `except` or `finally`.' );
end;

// called for each `with` and each `try` statement: hands the node on, by its Kind
procedure TWithAndTry.Visit(const Node: TNode; Ctx: TContext);
begin
  case IndexStr(Node.Kind, ['with', 'try']) of
    0: VisitWith(Node, Ctx);
    1: VisitTry(Node, Ctx);
  end;
end;

// a `with` statement: the same as the `with` rule's Visit
procedure TWithAndTry.VisitWith(const Node: TNode; Ctx: TContext);
var
  Objects: TArray<string>;
begin
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

// a `try` statement: an `except` or `finally` with nothing before its `end`
procedure TWithAndTry.VisitTry(const Node: TNode; Ctx: TContext);
begin
  for var I := 1 to Node.ChildCount - 2 do
  begin
    var C := Node.Child(I);
    if Node.Child(I + 1).Kind <> 'kEnd' then
      Continue;
    if C.Kind = 'kExcept' then
      Ctx.Report(C, 'an empty `except` swallows every exception: handle it, or leave out the try');
    if C.Kind = 'kFinally' then
      Ctx.Report(C, 'an empty `finally` does nothing: fill it, or leave out the try');
  end;
end;

end.
