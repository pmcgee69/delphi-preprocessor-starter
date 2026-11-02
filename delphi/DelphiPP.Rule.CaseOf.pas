unit DelphiPP.Rule.CaseOf;

{ THE `case-of` RULE: a rewrite. It lets `case` take strings, and class types,
  which Delphi's `case` doesn't (only ordinals), and writes each such `case` as
  the `if` chain Delphi compiles:

      case s of                              if (s = 'hello') or (s = 'hi') then
        'hello', 'hi' : x := 1;                x := 1
        sWorld        : x := 3;      ->      else if s = sWorld then
      else                                     x := 3
        x := 0;                              else
      end;                                     x := 0;

      case x.ClassType of                    if x.ClassType = TBar then
        TBar : x := 1;               ->        x := 1
        TFoo : x := 2;                       else if x.ClassType = TFoo then
      end;                                     x := 2;

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

// a statement's text without a `;` the grammar put at its end
function StatementText(const Node: TNode; Ctx: TContext): string;
begin
  Result := Ctx.Text(Node).TrimRight;
  if Result.EndsWith(';') then
    Result := Result.Substring(0, Result.Length - 1).TrimRight;
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

  const Sel    = Ctx.Text(Selector);
  const Indent = StringOfChar(' ', Node.Column - 1);
  // the file's own line break, as the case has it
  var LineBreak: string := #10;
  if Ctx.Text(Node).Contains(#13#10) then
    LineBreak := #13#10;
  var   Code   := '';
  var   First  := True;
  for var I := 0 to Node.ChildCount - 1 do
  begin
    const C = Node.Child(I);
    if C.Kind = 'comment' then
      // a // comment's node holds the CR of a CRLF file: left in, it makes a CR CR LF, and
      // dcc counts the lone CR as a line, so its messages' line numbers drift
      Code := Code + Ctx.Text(C).TrimRight([#13]) + LineBreak + Indent
    else if C.Kind = 'caseCase' then
    begin
      // the tests: one for each label, joined by `or`
      var Tests: TArray<string>;
      const Labels = C.Child(0);
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
        Tests := Tests + [Sel + ' = ' + Ctx.Text(L)];
      end;
      var Test := Tests[0];
      if Length(Tests) > 1 then
        Test := '(' + string.Join(') or (', Tests) + ')';
      if not First then
        Code := Code + LineBreak + Indent + 'else ';
      Code  := Code + 'if ' + Test + ' then' + LineBreak + Indent + '  ' +
               StatementText(C.Child(1), Ctx);
      First := False;
    end
    else if C.Kind = 'kElse' then
    begin
      // the else part: the statements up to `end`, each kept as written
      var Statements: TArray<string>;
      var K := I + 1;
      while Node.Child(K).Kind <> 'kEnd' do
      begin
        if Node.Child(K).Kind <> ';' then
          Statements := Statements + [StatementText(Node.Child(K), Ctx)];
        Inc(K);
      end;
      var Text := '';
      if Length(Statements) = 1 then
        Text := Statements[0]
      else if Length(Statements) > 1 then
        Text := 'begin' + LineBreak + Indent + '    ' +
                string.Join(';' + LineBreak + Indent + '    ', Statements) +
                LineBreak + Indent + '  end';
      Code := Code + LineBreak + Indent + 'else' + LineBreak + Indent + '  ' + Text;
      Break;
    end;
  end;
  // the case's own `;`, if the grammar put it inside the case
  if Node.Child(Node.ChildCount - 1).Kind = ';' then
    Code := Code + ';';
  Ctx.Replace(Node, Code);
end;

end.
