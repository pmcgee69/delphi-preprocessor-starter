unit DelphiPP.Engine;

{ The engine, as the Python side's engine.py: parse a Delphi file, show every
  node to the rules that asked for its kind, collect what they report and the
  edits they propose, and apply the edits. A file no rule changes comes out
  byte for byte as it went in.

  A rule never edits text itself. It proposes a replacement of a byte range;
  the engine checks that no two proposals overlap and applies them all at once,
  from the end of the file back, so one rule's edit can't shift another's.

  The file's own bytes are parsed, whatever its encoding (tree-sitter reads
  them as UTF-8, and Windows-1252 text in strings and comments does no harm),
  so offsets are the file's own and nothing is converted that isn't changed. }

interface

uses
  System.SysUtils, System.Generics.Collections, TreeSitter.Api;

type
  // a node of the tree, with the little a rule needs
  TNode = record
  private
    FNode: TSNode;
  public
    function Kind: string;
    function IsNull: Boolean;
    function HasError: Boolean;
    function ChildCount: Integer;
    function Child(Index: Integer): TNode;
    function Field(const Name: string): TNode;    // IsNull when it isn't there
    function StartByte: Integer;
    function EndByte: Integer;
    function Line: Integer;                       // from 1
    function Column: Integer;                     // from 1, in bytes
  end;

  TMessage = record
    Level : string;     // 'error', 'warning' or 'hint'
    Line  : Integer;
    Col   : Integer;
    Text  : string;
    Rule  : string;
    function ToString: string;                    // 12:3: warning: text [rule]
  end;

  TEdit = record
    StartByte : Integer;
    EndByte   : Integer;
    Bytes     : TBytes;
    Rule      : string;
    Origin    : Integer;      // where the lines it adds come from (a byte offset; -1: the edit's own)
    // the node the rule was visiting when it made the edit, by byte: a hover can show all of
    // what one visit changed in it, the whole case-of `if` chain (user, 12 Nov)
    GroupStart: Integer;
    GroupEnd  : Integer;
  end;

  // what a rule sees while it runs on one file
  TContext = class
  private
    FSource   : TBytes;
    FFileName : string;
    FEncoding : TEncoding;    // the file's own: for text read, and text a rule inserts
    FMessages : TList<TMessage>;
    FEdits    : TList<TEdit>;
    procedure AddEdit(StartByte, EndByte: Integer; const Text: string; Origin: Integer = -1);
  public
    Rule: string;             // the rule now running, for its messages and edits
    VisitStart, VisitEnd: Integer;   // the node it is visiting, for its edits' Group
    constructor Create(const Source: TBytes; const FileName: string; Encoding: TEncoding);
    destructor Destroy; override;
    function Text(const Node: TNode): string;
    procedure Report(const Node: TNode; const Text: string; const Level: string = 'warning');
    // at a line and column (from 1) inside a node's text, where no node of its own is:
    // a line of the footnotes after `end.`
    procedure ReportAt(Line, Col: Integer; const Text: string; const Level: string = 'warning');
    procedure Replace(const Node: TNode; const Text: string); overload;
    // from the start of one node to the end of a later one, with what lies between
    procedure ReplaceSpan(const First, Last: TNode; const Text: string); overload;
    procedure InsertBefore(const Node: TNode; const Text: string); overload;
    procedure InsertAfter(const Node: TNode; const Text: string); overload;
    // with Origin: the node the text comes from, when it isn't where the text goes. The lines
    // an edit adds are numbered with its line in the {$LINE} output (WithLines): a derived
    // ToString, written after the implementation's uses, names its [Derive(ToString)] line
    procedure Replace(const Node: TNode; const Text: string; const Origin: TNode); overload;
    procedure ReplaceSpan(const First, Last: TNode; const Text: string; const Origin: TNode); overload;
    procedure InsertBefore(const Node: TNode; const Text: string; const Origin: TNode); overload;
    procedure InsertAfter(const Node: TNode; const Text: string; const Origin: TNode); overload;
    property FileName: string read FFileName;
  end;

  TRule = class
  public
    function Name: string; virtual; abstract;
    function Kinds: TArray<string>; virtual; abstract;
    function Description: string; virtual; abstract;
    procedure Visit(const Node: TNode; Ctx: TContext); virtual; abstract;
    // True: its edits in one visit are one rewrite of the node, so an editor's hover shows
    // the node rewritten whole (case-of). False, the default: each edit shows alone, for a
    // rule that visits a whole unit and makes unrelated edits in it (derive, footnotes)
    function GroupsEdits: Boolean; virtual;
  end;

// run the rules over one file's bytes: its messages, and the output in Output
function Run(const Source: TBytes; const Rules: TArray<TRule>; const FileName: string;
             out Output: TBytes): TArray<TMessage>;

// as Run, and the edits applied, in source order, for a tool to show or map lines
// through (an editor underlining what the rules change): none if they overlapped
function RunWithEdits(const Source: TBytes; const Rules: TArray<TRule>; const FileName: string;
                      out Output: TBytes; out Edits: TArray<TEdit>): TArray<TMessage>;

// the output again (Edits as RunWithEdits gives them), with dcc's {$LINE N 'file'}, so dcc's
// messages, Assert's text and the debugger name FileName and its lines, not the output's:
// one at the top, naming it, and one after each edit that changes the number of lines.
// {$LINE N} makes the next line N and the rest of its own line N - 1, so none adds a line.
// FileName is left out ('' or a name the directive can't hold): the lines are still right
function WithLines(const Source: TBytes; const Edits: TArray<TEdit>; const FileName: string): TBytes;

// the file's tree as text, a node a line, indented by depth: each node's Kind
// (what a rule's Kinds lists), its line, and a leaf's text. The first step of
// writing a rule: find the kind of node it is about (delphipp --tree FILE)
function TreeText(const Source: TBytes): string;

// UTF-8 when every byte sequence is UTF-8 (a BOM or not), else Windows-1252: the caller
// frees one that isn't TEncoding.IsStandardEncoding
function SourceEncoding(const Source: TBytes): TEncoding;

implementation

uses
  System.Generics.Defaults;

{ TNode }

function TNode.Kind: string;
begin
  Exit( UTF8ToString(ts_node_type(FNode)) );
end;

function TNode.IsNull: Boolean;
begin
  Exit( ts_node_is_null(FNode) );
end;

function TNode.HasError: Boolean;
begin
  Exit( ts_node_has_error(FNode) );
end;

function TNode.ChildCount: Integer;
begin
  Exit( ts_node_child_count(FNode) );
end;

function TNode.Child(Index: Integer): TNode;
begin
  Result.FNode := ts_node_child(FNode, Index);
end;

function TNode.Field(const Name: string): TNode;
begin
  var Utf8 := UTF8String(Name);
  Result.FNode := ts_node_child_by_field_name(FNode, PByte(Utf8), Length(Utf8));
end;

function TNode.StartByte: Integer;
begin
  Exit( ts_node_start_byte(FNode) );
end;

function TNode.EndByte: Integer;
begin
  Exit( ts_node_end_byte(FNode) );
end;

function TNode.Line: Integer;
begin
  Exit( ts_node_start_point(FNode).Row + 1 );
end;

function TNode.Column: Integer;
begin
  Exit( ts_node_start_point(FNode).Column + 1 );
end;

{ TMessage }

function TMessage.ToString: string;
begin
  Exit( Format('%d:%d: %s: %s [%s]', [Line, Col, Level, Text, Rule]) );
end;

{ TContext }

constructor TContext.Create(const Source: TBytes; const FileName: string; Encoding: TEncoding);
begin
  inherited Create;
  FSource   := Source;
  FFileName := FileName;
  FEncoding := Encoding;
  FMessages := TList<TMessage>.Create;
  FEdits    := TList<TEdit>.Create;
end;

destructor TContext.Destroy;
begin
  FEdits.Free;
  FMessages.Free;
  inherited;
end;

function TContext.Text(const Node: TNode): string;
begin
  Exit( FEncoding.GetString(FSource, Node.StartByte, Node.EndByte - Node.StartByte) );
end;

procedure TContext.Report(const Node: TNode; const Text: string; const Level: string);
var
  M: TMessage;
begin
  M.Level := Level;
  M.Line  := Node.Line;
  M.Col   := Node.Column;
  M.Text  := Text;
  M.Rule  := Rule;
  FMessages.Add(M);
end;

procedure TContext.ReportAt(Line, Col: Integer; const Text: string; const Level: string);
var
  M: TMessage;
begin
  M.Level := Level;
  M.Line  := Line;
  M.Col   := Col;
  M.Text  := Text;
  M.Rule  := Rule;
  FMessages.Add(M);
end;

function TRule.GroupsEdits: Boolean;
begin
  Exit( False );
end;

procedure TContext.AddEdit(StartByte, EndByte: Integer; const Text: string; Origin: Integer);
var
  E: TEdit;
begin
  E.StartByte := StartByte;
  E.EndByte   := EndByte;
  E.Bytes     := FEncoding.GetBytes(Text);
  E.Rule      := Rule;
  E.Origin    := Origin;
  E.GroupStart := VisitStart;
  E.GroupEnd   := VisitEnd;
  FEdits.Add(E);
end;

procedure TContext.Replace(const Node: TNode; const Text: string; const Origin: TNode);
begin
  AddEdit(Node.StartByte, Node.EndByte, Text, Origin.StartByte);
end;

procedure TContext.ReplaceSpan(const First, Last: TNode; const Text: string; const Origin: TNode);
begin
  AddEdit(First.StartByte, Last.EndByte, Text, Origin.StartByte);
end;

procedure TContext.InsertBefore(const Node: TNode; const Text: string; const Origin: TNode);
begin
  AddEdit(Node.StartByte, Node.StartByte, Text, Origin.StartByte);
end;

procedure TContext.InsertAfter(const Node: TNode; const Text: string; const Origin: TNode);
begin
  AddEdit(Node.EndByte, Node.EndByte, Text, Origin.StartByte);
end;

procedure TContext.Replace(const Node: TNode; const Text: string);
begin
  AddEdit(Node.StartByte, Node.EndByte, Text);
end;

procedure TContext.ReplaceSpan(const First, Last: TNode; const Text: string);
begin
  AddEdit(First.StartByte, Last.EndByte, Text);
end;

procedure TContext.InsertBefore(const Node: TNode; const Text: string);
begin
  AddEdit(Node.StartByte, Node.StartByte, Text);
end;

procedure TContext.InsertAfter(const Node: TNode; const Text: string);
begin
  AddEdit(Node.EndByte, Node.EndByte, Text);
end;

{ Run }

// UTF-8 when every byte sequence is UTF-8 (a BOM or not), else Windows-1252:
// what Delphi sources are
function SourceEncoding(const Source: TBytes): TEncoding;
begin
  var I    := 0;
  var N    := Length(Source);
  while I < N do
  begin
    var B    := Source[I];
    var More: Integer;
    if B < $80 then More := 0
    else if (B and $E0) = $C0 then More := 1
    else if (B and $F0) = $E0 then More := 2
    else if (B and $F8) = $F0 then More := 3
    else Exit( TEncoding.GetEncoding(1252) );
    if I + More > N - 1 then
      Exit( TEncoding.GetEncoding(1252) );          // cut short at the end
    for var K := 1 to More do
      if (Source[I + K] and $C0) <> $80 then
        Exit( TEncoding.GetEncoding(1252) );
    Inc(I, More + 1);
  end;
  Exit( TEncoding.UTF8 );
end;

// the error the parser found: the innermost node holding one, first in the file
function FirstError(const Root: TNode): TNode;
begin
  Result := Root;
  var Found := True;
  while Found do
  begin
    Found := False;
    for var I := 0 to Result.ChildCount - 1 do
      if Result.Child(I).HasError or (Result.Child(I).Kind = 'ERROR') then
      begin
        Result := Result.Child(I);
        Found  := True;
        Break;
      end;
  end;
end;

function TreeText(const Source: TBytes): string;
type
  TAt = record Node: TNode; Depth: Integer; end;
begin
  var Encoding := SourceEncoding(Source);
  var Parser   := ts_parser_new;
  var Stack    := TStack<TAt>.Create;
  var Lines    := TStringBuilder.Create;
  try
    ts_parser_set_language(Parser, tree_sitter_delphi13);
    var Tree := ts_parser_parse_string(Parser, nil, PByte(Source), Length(Source));
    try
      var At: TAt;
      At.Node.FNode := ts_tree_root_node(Tree);
      At.Depth      := 0;
      Stack.Push(At);
      while Stack.Count > 0 do
      begin
        At := Stack.Pop;
        var Line := StringOfChar(' ', 2 * At.Depth) + At.Node.Kind;
        if At.Node.ChildCount = 0 then
          Line := Line.PadRight(40) + ' ' +
                  Encoding.GetString(Source, At.Node.StartByte, At.Node.EndByte - At.Node.StartByte)
                          .Replace(#13, '').Replace(#10, ' ')
        else
          Line := Line.PadRight(40) + ' line ' + IntToStr(At.Node.Line);
        Lines.AppendLine(Line.TrimRight);
        for var I := At.Node.ChildCount - 1 downto 0 do
        begin
          var C: TAt;
          C.Node  := At.Node.Child(I);
          C.Depth := At.Depth + 1;
          Stack.Push(C);
        end;
      end;
    finally
      ts_tree_delete(Tree);
    end;
    Exit( Lines.ToString );
  finally
    Lines.Free;
    Stack.Free;
    ts_parser_delete(Parser);
    if not TEncoding.IsStandardEncoding(Encoding) then
      Encoding.Free;
  end;
end;

function Run(const Source: TBytes; const Rules: TArray<TRule>; const FileName: string;
             out Output: TBytes): TArray<TMessage>;
var
  Edits: TArray<TEdit>;
begin
  Exit( RunWithEdits(Source, Rules, FileName, Output, Edits) );
end;

function RunWithEdits(const Source: TBytes; const Rules: TArray<TRule>; const FileName: string;
                      out Output: TBytes; out Edits: TArray<TEdit>): TArray<TMessage>;
begin
  var Encoding := SourceEncoding(Source);
  var Parser   := ts_parser_new;
  var Ctx      := TContext.Create(Source, FileName, Encoding);
  var Wanted   := TObjectDictionary<string, TList<TRule>>.Create([doOwnsValues]);
  var Stack    := TStack<TNode>.Create;
  try
    ts_parser_set_language(Parser, tree_sitter_delphi13);
    var Tree := ts_parser_parse_string(Parser, nil, PByte(Source), Length(Source));
    try
      var Root: TNode;
      Root.FNode := ts_tree_root_node(Tree);
      if Root.HasError then
      begin
        Ctx.Rule := 'parser';
        Ctx.Report(FirstError(Root),
                   'the Delphi grammar cannot parse this; the rules still run on the parts it can',
                   'error');
      end;
      for var R in Rules do
        for var K in R.Kinds do
        begin
          if not Wanted.ContainsKey(K) then
            Wanted.Add(K, TList<TRule>.Create);
          Wanted[K].Add(R);
        end;
      // every node, in source order, by a loop: deep trees (a long a + b + c + …)
      // would be one call deep per node otherwise
      Stack.Push(Root);
      while Stack.Count > 0 do
      begin
        var Node := Stack.Pop;
        var List: TList<TRule>;
        if Wanted.TryGetValue(Node.Kind, List) then
          for var R in List do
          begin
            Ctx.Rule       := R.Name;
            Ctx.VisitStart := if R.GroupsEdits then Node.StartByte else -1;
            Ctx.VisitEnd   := if R.GroupsEdits then Node.EndByte else -1;
            R.Visit(Node, Ctx);
          end;
        for var I := Node.ChildCount - 1 downto 0 do
          Stack.Push(Node.Child(I));
      end;
    finally
      ts_tree_delete(Tree);
    end;

    // the edits, all at once, from the end back; two that overlap: none. Two at one
    // place (an insert after one node and before the next) in the order they were
    // proposed, as Python's sort keeps them: by index last, as the messages below
    var Proposed := Ctx.FEdits.ToArray;
    var EditOrder: TArray<Integer>;
    SetLength(EditOrder, Length(Proposed));
    for var I := 0 to High(EditOrder) do
      EditOrder[I] := I;
    TArray.Sort<Integer>(EditOrder, TComparer<Integer>.Construct(
      function(const A, B: Integer): Integer
      begin
        Result := Proposed[A].StartByte - Proposed[B].StartByte;
        if Result = 0 then
          Result := Proposed[A].EndByte - Proposed[B].EndByte;
        if Result = 0 then
          Result := A - B;
      end));
    SetLength(Edits, Length(Proposed));
    for var I := 0 to High(EditOrder) do
      Edits[I] := Proposed[EditOrder[I]];
    var Overlap := False;
    for var I := 1 to High(Edits) do
      if Edits[I].StartByte < Edits[I - 1].EndByte then
      begin
        Overlap := True;
        var M: TMessage;
        M.Level := 'error';
        M.Line  := 1;
        for var K := 0 to Edits[I].StartByte - 1 do
          if Source[K] = 10 then
            Inc(M.Line);
        M.Col  := 1;
        M.Text := Format('two edits overlap (%s, %s): neither applied to this file',
                         [Edits[I - 1].Rule, Edits[I].Rule]);
        M.Rule := 'engine';
        Ctx.FMessages.Add(M);
        Break;
      end;
    Output := Copy(Source);
    if Overlap then
      Edits := nil
    else
      for var I := High(Edits) downto 0 do
        Output := Copy(Output, 0, Edits[I].StartByte) + Edits[I].Bytes +
                  Copy(Output, Edits[I].EndByte, Length(Output) - Edits[I].EndByte);

    // by line and column; two at one place in the order they were reported, as
    // Python's sort keeps them (TArray.Sort alone may swap them): so the indexes
    // are sorted, with the index last
    var All := Ctx.FMessages.ToArray;
    var Order: TArray<Integer>;
    SetLength(Order, Length(All));
    for var I := 0 to High(Order) do
      Order[I] := I;
    TArray.Sort<Integer>(Order, TComparer<Integer>.Construct(
      function(const A, B: Integer): Integer
      begin
        Result := All[A].Line - All[B].Line;
        if Result = 0 then
          Result := All[A].Col - All[B].Col;
        if Result = 0 then
          Result := A - B;
      end));
    SetLength(Result, Length(All));
    for var I := 0 to High(Order) do
      Result[I] := All[Order[I]];
  finally
    Stack.Free;
    Wanted.Free;
    Ctx.Free;
    ts_parser_delete(Parser);
    if not TEncoding.IsStandardEncoding(Encoding) then
      Encoding.Free;                    // the Windows-1252 one is made for this file
  end;
end;

function Newlines(const Bytes: TBytes; StartByte, EndByte: Integer): Integer;
begin
  Result := 0;
  for var I := StartByte to EndByte - 1 do
    if Bytes[I] = 10 then
      Inc(Result);
end;

// each line an edit's text adds, ended by `   {$LINE Origin}`: numbered with the line it comes
// from (not on a line holding a // comment, where the directive would be comment)
function MarkAdded(const Text: TBytes; Origin: Integer; Encoding: TEncoding): TBytes;
begin
  const Mark = Encoding.GetBytes(Format('   {$LINE %d}', [Origin]));
  Result := nil;
  var PieceStart := 0;
  for var K := 0 to High(Text) do
    if Text[K] = 10 then
    begin
      var Comment := False;
      for var J := PieceStart to K - 2 do
        if (Text[J] = Ord('/')) and (Text[J + 1] = Ord('/')) then
          Comment := True;
      var PieceEnd := K;                              // before a CR, if the break is CR LF
      if (K > PieceStart) and (Text[K - 1] = 13) then
        PieceEnd := K - 1;
      Result := Result + Copy(Text, PieceStart, PieceEnd - PieceStart);
      if not Comment then
        Result := Result + Mark;
      Result := Result + Copy(Text, PieceEnd, K + 1 - PieceEnd);
      PieceStart := K + 1;
    end;
  Result := Result + Copy(Text, PieceStart, Length(Text) - PieceStart);
end;

// two edits at one place (two derived methods after one uses clause) leave two directives
// side by side: only the last counts, so it alone is kept
function DropShadowed(const Bytes: TBytes): TBytes;
const
  Lead: array[0..9] of Byte = (32, 32, 32, Ord('{'), Ord('$'), Ord('L'), Ord('I'), Ord('N'), Ord('E'), 32);

  function LeadAt(At: Integer): Boolean;
  begin
    if At + Length(Lead) > Length(Bytes) then
      Exit( False );
    for var I := 0 to High(Lead) do
      if Bytes[At + I] <> Lead[I] then
        Exit( False );
    Exit( True );
  end;

begin
  SetLength(Result, Length(Bytes));
  var N := 0;
  var I := 0;
  while I < Length(Bytes) do
  begin
    if LeadAt(I) then
    begin
      var J := I + Length(Lead);
      while (J < Length(Bytes)) and (Bytes[J] in [Ord('0')..Ord('9')]) do
        Inc(J);
      if (J > I + Length(Lead)) and (J < Length(Bytes)) and (Bytes[J] = Ord('}')) and LeadAt(J + 1) then
      begin
        I := J + 1;                                   // this one is shadowed by the next
        Continue;
      end;
    end;
    Result[N] := Bytes[I];
    Inc(N);
    Inc(I);
  end;
  SetLength(Result, N);
end;

function WithLines(const Source: TBytes; const Edits: TArray<TEdit>; const FileName: string): TBytes;
begin
  var Encoding := SourceEncoding(Source);
  try
    // a name in quotes, which ends at the first quote ('' isn't one), in the file's encoding
    var Name := FileName;
    if Name.Contains('''') or Name.Contains('}') or
       (Encoding.GetString(Encoding.GetBytes(Name)) <> Name) then
      Name := '';
    // the file's own line break
    var LineBreak: TBytes := [10];
    for var K := 1 to High(Source) do
      if (Source[K - 1] = 13) and (Source[K] = 10) then
      begin
        LineBreak := [13, 10];
        Break;
      end;
    Result := Copy(Source);
    for var I := High(Edits) downto 0 do
    begin
      const E = Edits[I];
      var Text := E.Bytes;
      // none when nothing but blanks follows: after end., where the footnotes went, dcc
      // would warn of text after it, W1011
      var Blank := True;
      for var K := E.EndByte to High(Source) do
        Blank := Blank and (Source[K] in [9..13, 32]);     // Python's bytes.strip
      if (Newlines(Text, 0, Length(Text)) <> Newlines(Source, E.StartByte, E.EndByte)) and
         not Blank then
      begin
        // each line the edit adds: numbered with its origin's line
        if Newlines(Text, 0, Length(Text)) > Newlines(Source, E.StartByte, E.EndByte) then
        begin
          var From := E.StartByte;
          if E.Origin >= 0 then
            From := E.Origin;
          Text := MarkAdded(Text, Newlines(Source, 0, From) + 1, Encoding);
        end;
        // the text after the edit's last line break: blanks only, its indent, when it ends
        // where a line starts
        var LastBreak := -1;
        for var K := 0 to High(Text) do
          if Text[K] = 10 then
            LastBreak := K;
        const Tail = Copy(Text, LastBreak + 1, Length(Text) - LastBreak - 1);
        var TailBlank := True;
        for var B in Tail do
          TailBlank := TailBlank and (B in [9..13, 32]);
        if (LastBreak >= 0) and TailBlank then
          // a line of its own, so the code is left as it was; the next line is the
          // source's at the edit's end
          Text := Text + Encoding.GetBytes(Format('{$LINE %d}', [Newlines(Source, 0, E.EndByte) + 1])) +
                  LineBreak + Tail
        else
          // after the code, on the edit's last line: from the line after the edit's end
          Text := Text + Encoding.GetBytes(Format('   {$LINE %d}', [Newlines(Source, 0, E.EndByte) + 2]));
      end;
      Result := Copy(Result, 0, E.StartByte) + Text +
                Copy(Result, E.EndByte, Length(Result) - E.EndByte);
    end;
    Result := DropShadowed(Result);
    if Name <> '' then
    begin
      // a line of its own before everything but a UTF-8 BOM: line 1 is then 1, of the file named
      var At := 0;
      if (Length(Source) >= 3) and (Source[0] = $EF) and (Source[1] = $BB) and (Source[2] = $BF) then
        At := 3;
      Result := Copy(Result, 0, At) + Encoding.GetBytes(Format('{$LINE 1 ''%s''}', [Name])) +
                LineBreak + Copy(Result, At, Length(Result) - At);
    end;
  finally
    if not TEncoding.IsStandardEncoding(Encoding) then
      Encoding.Free;
  end;
end;

end.
