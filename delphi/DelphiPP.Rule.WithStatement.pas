unit DelphiPP.Rule.WithStatement;

{ THE `with` RULE: a check. It reports every `with` statement, naming its
  objects, and changes nothing.

  WHY: inside `with Form1, Edit1 do Text := Caption;` a reader can't tell whose
  Text and whose Caption are meant without knowing every member of both
  classes, and a member added to either later can silently change which one a
  name means.

  HOW A RULE WORKS. The engine (DelphiPP.Engine.pas) parses a file into a tree
  of nodes, one for each piece of the source: a statement, a name, a keyword.
  It walks the whole tree, and each time it meets a node whose Kind is in a
  rule's Kinds, it calls that rule's Visit with the node. Visit looks around the
  node and may report a message (Ctx.Report) or propose an edit (Ctx.Replace,
  InsertBefore, InsertAfter). That is all a rule is: four methods.

  HOW THIS ONE WAS MADE, in the order you'd make your own:

  1. Write a small sample with the thing in it (tests\cases\with\basic.pas).
  2. Look at its tree:   bin\delphipp.exe --tree ..\tests\cases\with\basic.pas
     The statement shows as a node of Kind 'with', with these children
     (each line: the Kind, then a leaf's text or a branch's line):
         with                           line 12
           kWith                        with
           identifier                   Form1
           ,                            ,
           identifier                   Edit1
           kDo                          do
           assignment                   line 13
             identifier                 Text
             kAssign                    :=
             identifier                 Caption
           ;                            ;
  3. So Kinds is ['with'], and the objects are the children between the
     keyword `with` (kWith) and `do` (kDo), leaving out the commas.
  4. Visit collects their text (Ctx.Text) and reports one message.
  5. Add the class to AllRules in DelphiPP.Rules.pas, and this unit to its uses.
  6. Build (build.cmd), run it (bin\delphipp.exe --rules with FILE), and give it
     a test: tests\cases\with\basic.pas, then bin\RunTests.exe --update writes
     basic.diag from what the rule says now. Read it, keep it, and from then on
     bin\RunTests.exe checks the rule still says exactly that. }

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

// how users choose the rule (--rules with), and how its messages are signed: [with]
function TWithStatement.Name: string;
begin
  Exit( 'with' );
end;

// the Kind of node the engine calls Visit for: as --tree prints it
function TWithStatement.Kinds: TArray<string>;
begin
  Result := ['with'];
end;

// one line, for --list
function TWithStatement.Description: string;
begin
  Exit( 'A check: every `with` statement, reported.' );
end;

// called once for each `with` statement in the file
procedure TWithStatement.Visit(const Node: TNode; Ctx: TContext);
var
  Objects: TArray<string>;
begin
  // the objects: the children after `with` (child 0) and before `do`, but the commas
  for var I := 1 to Node.ChildCount - 1 do
  begin
    var C := Node.Child(I);
    if C.Kind = 'kDo' then
      Break;
    if C.Kind <> ',' then
      Objects := Objects + [Ctx.Text(C)];      // the source text of that child
  end;
  // a warning at the statement's line and column, signed with Name
  Ctx.Report(Node, '`with ' + string.Join(', ', Objects) + '` makes each name inside it ' +
                   'ambiguous: give each object a local name and write it');
end;

end.
