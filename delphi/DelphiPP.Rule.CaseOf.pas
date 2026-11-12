unit DelphiPP.Rule.CaseOf;

{ THE `case-of` RULE: a rewrite. It lets `case` take strings, and class types,
  which Delphi's `case` doesn't (only ordinals), and writes each such `case` as
  the `if` chain Delphi compiles:

      case s of                      begin
        'hello', 'hi' : x := 1;        if (s = 'hello') or (s = 'hi') then x := 1
        sWorld        : x := 3;  ->    else if s = sWorld then x := 3
      else                           else
        x := 0;                        x := 0;
      end;                           end;

      case x.ClassType of            begin
        TBar : x := 1;           ->    if x.ClassType = TBar then x := 1
        TFoo : x := 2;                 else if x.ClassType = TFoo then x := 2
      end;                           end;

  EVERY LINE STAYS WHERE IT WAS (user, 12 Nov: the if chain's lines didn't match the case's
  arms, so dcc's messages and the debugger named the wrong arm): `case … of` becomes
  `begin`, which the case's own `end` closes; each label becomes its `if … then`, the arm's
  statement after it on its line; the `;` ending an arm goes. An arm holding an `if` with no
  `else` is put in `begin … end`, or the next arm's `else` would be that `if`'s (the rule
  before this wrote such an arm as it stood, and a case on 'one' with `if Flag then …` never
  tested the next arm when Flag was false). An `else` part of several statements becomes
  `else begin … end`, closed by a second `end`.

  WHY: Vincent Parrett's "Delphi language enhancements" (VSoft, 2016) called
  strings in case statements the most requested feature of all.

  NO NEW GRAMMAR NEEDED. The standard grammar parses both already: labels are
  expressions to it, whatever their type
  (bin\delphipp.exe --tree ..\tests\cases\case-of\basic.pas):
      case                             line 12
        kCase                          case
        identifier                     s
        kOf                            of
        caseCase                       line 13
          caseLabel                    line 13
            literalString              'hello'
            ,                          ,
            literalString              'hi'
            :                          :
          assignment                   line 13
          ;                            ;
        kElse                          else
        assignment                     line 16
        ;                              ;
        kEnd                           end
        ;                              ;
  (each assignment's own nodes left out here).

  WHICH CASES: one with a string literal of other than one character among its
  labels (a string case: its other labels, such as the constant sWorld, are
  strings too), or one whose selector ends in .ClassType (an object case). Any
  other case is ordinal, and ordinary Delphi: left alone. That includes a case
  on a Char, whose labels are one-character literals: 'a', '''' (a quote), or
  a character code such as #10 or #$0D. Characters are counted as Delphi reads
  the literal, so #13#10 is two, and a case with it is a string case. A case on
  a string whose labels are all one character is left alone too, as nothing in
  the text tells it from a Char case, and dcc reports it.

  THE SELECTOR is written again in each test, so it must be a name or a dotted
  name, such as s, Rec.Name or x.ClassType (a property or a method without
  brackets is then read again in each test). Anything else, such as Trim(s),
  would be evaluated once per test: reported as an error, and the case left
  alone; put it in a variable first. A range label (a..b) in a string case is
  reported the same way. }

interface

uses
  DelphiPP.Engine;

type
  TCaseOf = class(TRule)
  public
    function Name: string; override;
    function Kinds: TArray<string>; override;
    function Description: string; override;
    procedure Visit(const Node: TNode; Ctx: TContext); override;
  end;

implementation

uses
  System.SysUtils;

// how users choose the rule (--rules case-of), and how its messages are signed
function TCaseOf.Name: string;
begin
  Exit( 'case-of' );
end;

// the Kind of node the engine calls Visit for: as --tree prints it
function TCaseOf.Kinds: TArray<string>;
begin
  Result := ['case'];
end;

// one line, for --list
function TCaseOf.Description: string;
begin
  Exit( 'A rewrite: case on strings or on class types, written as an if chain.' );
end;

// a name, or names joined by dots: safe to write again in each test
function IsPlainName(const Node: TNode): Boolean;
begin
  if Node.Kind = 'identifier' then
    Exit( True );
  if Node.Kind <> 'exprDot' then
    Exit( False );
  for var I := 0 to Node.ChildCount - 1 do
    if not ((Node.Child(I).Kind = 'kDot') or IsPlainName(Node.Child(I))) then
      Exit( False );
  Exit( True );
end;

// the selector is X.ClassType
function IsClassType(const Node: TNode; Ctx: TContext): Boolean;
begin
  Exit( (Node.Kind = 'exprDot') and
        SameText(Ctx.Text(Node.Child(Node.ChildCount - 1)), 'ClassType') );
end;

// the characters a literal stands for: quoted parts ('ab', '''' is one) and
// character codes (#10, #$0A), as in 'ab'#13#10
function CharCount(const Literal: string): Integer;
begin
  Result := 0;
  var I := 1;
  while I <= Literal.Length do
    case Literal[I] of
      '''' : begin
               Inc(I);
               while I <= Literal.Length do
               begin
                 if Literal[I] = '''' then
                 begin
                   if (I < Literal.Length) and (Literal[I + 1] = '''') then
                     Inc(I)                     // '' inside: one quote
                   else
                     Break;                     // the closing quote
                 end;
                 Inc(Result);
                 Inc(I);
               end;
               Inc(I);
             end;
      '#'  : begin
               Inc(Result);
               Inc(I);
               while (I <= Literal.Length) and CharInSet(Literal[I], ['$', '0'..'9', 'a'..'f', 'A'..'F']) do
                 Inc(I);
             end;
    else
      Inc(I);
    end;
end;

// a string literal that isn't one character: 'hello', '' or #13#10 (a Char case
// has only one-character literals, 'a', '''' or #10, and is Delphi's own)
function IsString(const Node: TNode; Ctx: TContext): Boolean;
begin
  Exit( (Node.Kind = 'literalString') and (CharCount(Ctx.Text(Node)) <> 1) );
end;

// the node's last token: an arm's `;` can be deep inside it (`if A then x := 1;`)
function LastToken(const Node: TNode): TNode;
begin
  Result := Node;
  while Result.ChildCount > 0 do
    Result := Result.Child(Result.ChildCount - 1);
end;

// an `if` with no `else` that an `else` after the statement would belong to; statements that
// close themselves (begin … end, try, case, repeat, asm) keep theirs inside
function Dangles(const Node: TNode): Boolean;
begin
  const K = Node.Kind;
  if (K = 'block') or (K = 'try') or (K = 'case') or (K = 'repeat') or (K = 'asm') then
    Exit( False );
  if K = 'if' then
  begin
    var HasElse := False;
    for var I := 0 to Node.ChildCount - 1 do
      if Node.Child(I).Kind = 'kElse' then
        HasElse := True;
    if not HasElse then
      Exit( True );
  end;
  for var I := 0 to Node.ChildCount - 1 do
    if Dangles(Node.Child(I)) then
      Exit( True );
  Exit( False );
end;

// the line breaks in a text: how many lines a node runs on past its first
function LineBreaks(const Text: string): Integer;
begin
  Result := 0;
  for var Ch in Text do
    if Ch = #10 then
      Inc(Result);
end;

// called once for each case statement
procedure TCaseOf.Visit(const Node: TNode; Ctx: TContext);
begin
  const Selector = Node.Child(1);
  // a string case: a string literal among the labels that isn't one character
  var Strings := False;
  for var I := 0 to Node.ChildCount - 1 do
    if Node.Child(I).Kind = 'caseCase' then
    begin
      const Labels = Node.Child(I).Child(0);
      for var J := 0 to Labels.ChildCount - 1 do
        if IsString(Labels.Child(J), Ctx) then
          Strings := True;
    end;
  if not (Strings or IsClassType(Selector, Ctx)) then
    Exit;                                       // an ordinal case: Delphi's own

  if not IsPlainName(Selector) then
  begin
    Ctx.Report(Selector, 'the selector would be evaluated once for each test: ' +
                         'put it in a variable, then case on that', 'error');
    Exit;
  end;

  const Sel = Ctx.Text(Selector);
  // the file's own line break, as the case has it
  var LineBreak: string := #10;
  if Ctx.Text(Node).Contains(#13#10) then
    LineBreak := #13#10;
  var Arms: TArray<TNode>;
  var HasElse := False;
  for var I := 0 to Node.ChildCount - 1 do
    if Node.Child(I).Kind = 'caseCase' then
      Arms := Arms + [Node.Child(I)]
    else if Node.Child(I).Kind = 'kElse' then
      HasElse := True;

  // each arm's test, before any edit: a range label leaves the case as it is
  var Tests: TArray<string>;
  for var Arm in Arms do
  begin
    const Labels = Arm.Child(0);
    var Test     := '';
    var Count    := 0;
    var PrevLine := 0;
    for var J := 0 to Labels.ChildCount - 1 do
    begin
      const L = Labels.Child(J);
      if (L.Kind = ',') or (L.Kind = ':') or (L.Kind = 'comment') then
        Continue;
      if L.Kind = 'range' then
      begin
        Ctx.Report(L, 'a range label in a case on strings or class types: ' +
                      'write it as an if', 'error');
        Exit;
      end;
      const One = '(' + Sel + ' = ' + Ctx.Text(L) + ')';
      if Count = 0 then
        Test := One
      else if L.Line <> PrevLine then
        // labels on several lines keep their line breaks, so no line moves
        Test := Test + ' or' + LineBreak + StringOfChar(' ', L.Column - 1) + One
      else
        Test := Test + ' or ' + One;
      PrevLine := L.Line;
      Inc(Count);
    end;
    if Count = 1 then
      Test := Test.Substring(1, Test.Length - 2);      // one test: no brackets
    Test := 'if ' + Test + ' then';
    for var S := 1 to LineBreaks(Ctx.Text(Labels)) - LineBreaks(Test) do
      Test := Test + LineBreak;
    Tests := Tests + [Test];
  end;

  Ctx.ReplaceSpan(Node.Child(0), Node.Child(2), 'begin');     // case X of
  for var N := 0 to High(Arms) do
  begin
    const Arm = Arms[N];
    if N = 0 then
      Ctx.Replace(Arm.Child(0), Tests[N])
    else
      Ctx.Replace(Arm.Child(0), 'else ' + Tests[N]);
    // an arm with no statement (`'x' :`, which Delphi allows) has an empty then
    const HasStatement = (Arm.ChildCount > 1) and (Arm.Child(1).Kind <> ';');
    const Last         = LastToken(Arm);
    const Later        = (N < High(Arms)) or HasElse;
    if HasStatement and Later and Dangles(Arm.Child(1)) then
    begin
      Ctx.InsertBefore(Arm.Child(1), 'begin ');
      if Last.Kind = ';' then
        Ctx.Replace(Last, ' end')
      else
        Ctx.InsertAfter(Arm.Child(1), ' end');
    end
    else if Last.Kind = ';' then
      Ctx.Replace(Last, '');
  end;

  // the else part: several statements go in begin … end, closed by a second end
  if HasElse then
  begin
    var K := 0;
    while Node.Child(K).Kind <> 'kElse' do
      Inc(K);
    var E := K;
    while Node.Child(E).Kind <> 'kEnd' do
      Inc(E);
    var Statements := 0;
    for var I := K + 1 to E - 1 do
      if (Node.Child(I).Kind <> ';') and (Node.Child(I).Kind <> 'comment') then
        Inc(Statements);
    if Statements > 1 then
    begin
      Ctx.Replace(Node.Child(K), 'else begin');
      Ctx.Replace(Node.Child(E), 'end end');
    end;
  end;
end;

end.
