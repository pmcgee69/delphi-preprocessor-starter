unit DelphiPP.Rule.Footnotes;

{ THE `footnotes` RULE: a rewrite. Footnotes after `end.` become XMLDoc on what
  they name, and leave the .pas:

      function Greeting(const Name: string): string;     /// <summary>Says hello.</summary>
      ...                                                 /// <param name="Name">who to greet.</param>
      end.                                       ->       function Greeting(const Name: string): string;
                                                          ...
      [Greeting] Says hello.                              end.
        Name: who to greet.

  WHY: the code stays clear of documentation, which is in one place at the end
  and still reaches Help Insight.

  NO NEW GRAMMAR NEEDED. dcc reads nothing after `end.`, and the grammar keeps
  it as one node (bin\delphipp.exe --tree ..\tests\cases\footnotes\basic.pas):
      root                             line 1
        unit                           line 1
          ...
          kEndDot                      line 33
            .                          .
        trailingText                   [Greeting] Says hello to Name, ...
  so the rule reads that node's lines itself. A footnote starts at the line's
  first column with [Name], [Type.Member] or [Type], and the summary after it;
  an indented line `Param: text` describes a parameter, `Result: text` a
  function's result; any other line goes on with the line before it.

  THE EDITS: the XMLDoc goes above the declaration Help Insight reads: a unit's
  interface first, else its implementation (a routine or type of its own); in a
  program, its own declarations. Then the footnotes are deleted: the .pas ends
  at `end.`. Text after `end.` that doesn't start with a footnote is left alone,
  as prose.

  WHAT IS REPORTED, as errors: a name declared nowhere, or more than once (an
  overload: a footnote can't tell which), a parameter the routine doesn't have,
  a Result for a procedure, a second footnote for one name, a declaration with
  XMLDoc (///) above it already. }

interface

uses
  DelphiPP.Engine;

type
  TFootnotes = class(TRule)
  public
    function Name: string; override;
    function Kinds: TArray<string>; override;
    function Description: string; override;
    procedure Visit(const Node: TNode; Ctx: TContext); override;
  end;

implementation

uses
  System.SysUtils, System.Generics.Collections, System.RegularExpressions;

const
  Header = '^\[([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?)\]\s*(.*)$';
  Item   = '^\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$';

type
  TItem = record
    Name : string;
    Line : Integer;
    Col  : Integer;
    Text : TArray<string>;
  end;

  // one footnote: its target, the line it starts on, its summary and its items
  TNote = record
    Target  : string;
    Line    : Integer;
    Summary : TArray<string>;
    Items   : TArray<TItem>;
  end;

  // what a name can be: the node the XMLDoc goes above, the node before it, the declaration
  TFound = record
    Above   : TNode;
    Prev    : TNode;
    HasPrev : Boolean;
    Decl    : TNode;
  end;

// how users choose the rule (--rules footnotes), and how its messages are signed
function TFootnotes.Name: string;
begin
  Exit( 'footnotes' );
end;

// the tree's root: the module and the text after it are its children
function TFootnotes.Kinds: TArray<string>;
begin
  Result := ['root'];
end;

// one line, for --list
function TFootnotes.Description: string;
begin
  Exit( 'A rewrite: footnotes after end. become XMLDoc on what they name.' );
end;

// as XML; and '' is ', as in a string: the IDE highlights the text after end. as code, so a
// lone ' would start a string to the end of the line (user, 12 Nov: G'day written G''day)
function Xml(const Text: string): string;
begin
  Exit( Text.Replace('''''', '''').Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;') );
end;

// the footnotes in the text after `end.`; False when it doesn't start with one
function Parse(const Text: string; FirstLine: Integer; out Notes: TArray<TNote>): Boolean;
begin
  Notes := nil;
  const Lines = Text.Replace(#13, '').Split([#10]);
  for var I := 0 to High(Lines) do
  begin
    const Line = Lines[I];
    if (Length(Notes) = 0) and (Line.Trim = '') then
      Continue;
    var M := TRegEx.Match(Line, Header);
    if M.Success then
    begin
      var Note: TNote;
      Note.Target  := M.Groups[1].Value;
      Note.Line    := FirstLine + I;
      Note.Summary := nil;
      Note.Items   := nil;
      if M.Groups[2].Value.Trim <> '' then
        Note.Summary := [M.Groups[2].Value.Trim];
      Notes := Notes + [Note];
      Continue;
    end;
    if Length(Notes) = 0 then
      Exit( False );                    // prose after end., not footnotes
    if Line.Trim = '' then
      Continue;
    var Last := High(Notes);
    M := TRegEx.Match(Line, Item);
    if M.Success then
    begin
      var It: TItem;
      It.Name := M.Groups[1].Value;
      It.Line := FirstLine + I;
      It.Col  := Length(Line) - Length(Line.TrimLeft) + 1;
      It.Text := [M.Groups[2].Value.Trim];
      Notes[Last].Items := Notes[Last].Items + [It];
    end
    else if Length(Notes[Last].Items) > 0 then
    begin
      var K := High(Notes[Last].Items);
      Notes[Last].Items[K].Text := Notes[Last].Items[K].Text + [Line.Trim];
    end
    else
      Notes[Last].Summary := Notes[Last].Summary + [Line.Trim];
  end;
  Exit( Length(Notes) > 0 );
end;

// a declaration's simple name, lower case, or '' (a method's body has Type.Name)
function NameOf(const Node: TNode; Ctx: TContext): string;
begin
  for var I := 0 to Node.ChildCount - 1 do
  begin
    const K = Node.Child(I).Kind;
    if K = 'identifier' then
      Exit( Ctx.Text(Node.Child(I)).ToLower );
    if (K = 'genericDot') or (K = 'declArgs') or (K = ';') or (K = ':') or (K = '=') then
      Exit( '' );
  end;
  Exit( '' );
end;

function Found(const Above, Prev: TNode; HasPrev: Boolean; const Decl: TNode): TFound;
begin
  Result.Above   := Above;
  Result.Prev    := Prev;
  Result.HasPrev := HasPrev;
  Result.Decl    := Decl;
end;

// in a section, what Name (no dot) can be
function Candidates(const Section: TNode; const Name: string; Ctx: TContext): TArray<TFound>;
begin
  Result := nil;
  var Prev: TNode;
  var HasPrev := False;
  for var I := 0 to Section.ChildCount - 1 do
  begin
    const C = Section.Child(I);
    if (C.Kind = 'declProc') and (NameOf(C, Ctx) = Name) then
      Result := Result + [Found(C, Prev, HasPrev, C)]
    else if (C.Kind = 'defProc') and (NameOf(C.Child(0), Ctx) = Name) then
      Result := Result + [Found(C, Prev, HasPrev, C.Child(0))]
    else if C.Kind = 'declTypes' then
    begin
      var TPrev    := Prev;
      var THasPrev := HasPrev;
      for var J := 0 to C.ChildCount - 1 do
      begin
        const T = C.Child(J);
        if (T.Kind = 'declType') and (NameOf(T, Ctx) = Name) then
          Result := Result + [Found(T, TPrev, THasPrev, T)];
        TPrev    := T;
        THasPrev := True;
      end;
    end;
    Prev    := C;
    HasPrev := True;
  end;
end;

// a class's, record's or interface's members called Name, sections and all
function Members(const DeclType: TNode; const Name: string; Ctx: TContext): TArray<TFound>;
var
  Acc: TArray<TFound>;

  procedure Scan(const Holder: TNode);
  begin
    var Prev: TNode;
    var HasPrev := False;
    for var I := 0 to Holder.ChildCount - 1 do
    begin
      const C = Holder.Child(I);
      if C.Kind = 'declSection' then
        Scan(C)
      else if ((C.Kind = 'declProc') or (C.Kind = 'declProp')) and (NameOf(C, Ctx) = Name) then
        Acc := Acc + [Found(C, Prev, HasPrev, C)];
      Prev    := C;
      HasPrev := True;
    end;
  end;

begin
  Acc := nil;
  const Body = DeclType.Field('type');
  if Body.IsNull or (Body.ChildCount = 0) then
    Exit( nil );
  Scan(Body.Child(0));
  Exit( Acc );
end;

// a routine's parameter names, lower case to as written: `A, B: Integer` gives both
function Params(const Proc: TNode; Ctx: TContext): TDictionary<string, string>;
begin
  Result := TDictionary<string, string>.Create;
  const Args = Proc.Field('args');
  if Args.IsNull then
    Exit;
  for var I := 0 to Args.ChildCount - 1 do
  begin
    const Arg = Args.Child(I);
    if Arg.Kind <> 'declArg' then
      Continue;
    for var J := 0 to Arg.ChildCount - 1 do
    begin
      const C = Arg.Child(J);
      if C.Kind = ':' then
        Break;
      if C.Kind = 'identifier' then
        Result.AddOrSetValue(Ctx.Text(C).ToLower, Ctx.Text(C));
    end;
  end;
end;

function Find(const Sections: TArray<TNode>; const Target: string; Ctx: TContext): TArray<TFound>;
begin
  const Dot      = Target.LastIndexOf('.');
  const TypeName = if Dot < 0 then '' else Target.Substring(0, Dot);
  const Member   = Target.Substring(Dot + 1);
  for var Section in Sections do
  begin
    var Hits: TArray<TFound>;
    if TypeName = '' then
      Hits := Candidates(Section, Target, Ctx)
    else
    begin
      Hits := nil;
      for var T in Candidates(Section, TypeName, Ctx) do
        if T.Above.Kind = 'declType' then
          Hits := Hits + Members(T.Above, Member, Ctx);
    end;
    if Length(Hits) > 0 then
      Exit( Hits );
  end;
  Exit( nil );
end;

// the XMLDoc lines, after checking each item against the declaration; none on an error
function Doc(const Note: TNote; const Decl: TNode; const Where: string; Ctx: TContext): TArray<string>;
begin
  Result := nil;
  if Length(Note.Summary) > 0 then
    Result := Result + ['/// <summary>' + Xml(string.Join(' ', Note.Summary)) + '</summary>'];
  const IsProc     = Decl.Kind = 'declProc';
  const IsFunction = IsProc and (Decl.Child(0).Kind = 'kFunction');
  var Names: TDictionary<string, string>;
  if IsProc then
    Names := Params(Decl, Ctx)
  else
    Names := TDictionary<string, string>.Create;
  try
    var Ok := True;
    for var It in Note.Items do
    begin
      const Text = Xml(string.Join(' ', It.Text));
      var Written: string;
      if It.Name.ToLower = 'result' then
      begin
        if not IsFunction then
        begin
          Ctx.ReportAt(It.Line, It.Col, Where + ': ' + Note.Target + ' isn''t a function: ' +
                                        'Result has nothing to describe', 'error');
          Ok := False;
          Continue;
        end;
        Result := Result + ['/// <returns>' + Text + '</returns>'];
      end
      else if Names.TryGetValue(It.Name.ToLower, Written) then
        Result := Result + ['/// <param name="' + Written + '">' + Text + '</param>']
      else
      begin
        Ctx.ReportAt(It.Line, It.Col, Where + ': ' + Note.Target + ' has no parameter ' + It.Name,
                     'error');
        Ok := False;
      end;
    end;
    if not Ok then
      Result := nil;
  finally
    Names.Free;
  end;
end;

// called once, for the root: the footnotes in the text after the module
procedure TFootnotes.Visit(const Node: TNode; Ctx: TContext);
var
  Trailing, Module : TNode;
  HasTrailing      : Boolean;
  HasModule        : Boolean;
  Notes            : TArray<TNote>;
begin
  HasTrailing := False;
  HasModule   := False;
  for var I := 0 to Node.ChildCount - 1 do
  begin
    const K = Node.Child(I).Kind;
    if (K = 'trailingText') and not HasTrailing then
    begin
      Trailing    := Node.Child(I);
      HasTrailing := True;
    end
    else if ((K = 'unit') or (K = 'program') or (K = 'library')) and not HasModule then
    begin
      Module    := Node.Child(I);
      HasModule := True;
    end;
  end;
  if not (HasTrailing and HasModule) then
    Exit;
  if not Parse(Ctx.Text(Trailing), Trailing.Line, Notes) then
    Exit;
  // the file's own line break
  var LineBreak: string := #10;
  if Ctx.Text(Node).Contains(#13#10) then
    LineBreak := #13#10;
  var Sections: TArray<TNode>;
  for var I := 0 to Module.ChildCount - 1 do
    if (Module.Child(I).Kind = 'interface') or (Module.Child(I).Kind = 'implementation') then
      Sections := Sections + [Module.Child(I)];
  if Length(Sections) = 0 then
    Sections := [Module];
  var Seen := TDictionary<string, Boolean>.Create;
  try
    for var Note in Notes do
    begin
      const Where = 'footnote [' + Note.Target + ']';
      if Seen.ContainsKey(Note.Target.ToLower) then
      begin
        Ctx.ReportAt(Note.Line, 2, Where + ': a second footnote for ' + Note.Target, 'error');
        Continue;
      end;
      Seen.Add(Note.Target.ToLower, True);
      const Hits = Find(Sections, Note.Target.ToLower, Ctx);
      if Length(Hits) = 0 then
      begin
        Ctx.ReportAt(Note.Line, 2, Where + ': no routine, method or type ' + Note.Target +
                                   ' is declared in this file', 'error');
        Continue;
      end;
      if Length(Hits) > 1 then
      begin
        Ctx.ReportAt(Note.Line, 2, Format('%s: %s is declared %d times (an overload?): ' +
                                          'a footnote can''t tell which',
                                          [Where, Note.Target, Length(Hits)]), 'error');
        Continue;
      end;
      const Hit = Hits[0];
      if Hit.HasPrev and (Hit.Prev.Kind = 'comment') and Ctx.Text(Hit.Prev).StartsWith('///') then
      begin
        Ctx.ReportAt(Note.Line, 2, Where + ': ' + Note.Target + ' has XMLDoc (///) above it ' +
                                   'already', 'error');
        Continue;
      end;
      const Lines = Doc(Note, Hit.Decl, Where, Ctx);
      if Length(Lines) > 0 then
      begin
        const Indent = StringOfChar(' ', Hit.Above.Column - 1);
        var Text := '';
        for var L in Lines do
          Text := Text + L + LineBreak + Indent;
        Ctx.InsertBefore(Hit.Above, Text);
      end;
    end;
  finally
    Seen.Free;
  end;
  // the footnotes go: the .pas ends at end.
  for var I := 0 to Module.ChildCount - 1 do
    if Module.Child(I).Kind = 'kEndDot' then
    begin
      const Ending = if Ctx.Text(Trailing).EndsWith(#10) then LineBreak else '';
      Ctx.ReplaceSpan(Module.Child(I), Trailing, '.' + Ending);
      Break;
    end;
end;

end.
