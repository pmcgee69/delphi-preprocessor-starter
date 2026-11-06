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
  end;

  // what a rule sees while it runs on one file
  TContext = class
  private
    FSource   : TBytes;
    FFileName : string;
    FEncoding : TEncoding;    // the file's own: for text read, and text a rule inserts
    FMessages : TList<TMessage>;
    FEdits    : TList<TEdit>;
    procedure AddEdit(StartByte, EndByte: Integer; const Text: string);
  public
    Rule: string;             // the rule now running, for its messages and edits
    constructor Create(const Source: TBytes; const FileName: string; Encoding: TEncoding);
    destructor Destroy; override;
    function Text(const Node: TNode): string;
    procedure Report(const Node: TNode; const Text: string; const Level: string = 'warning');
    procedure Replace(const Node: TNode; const Text: string);
    procedure InsertBefore(const Node: TNode; const Text: string);
    procedure InsertAfter(const Node: TNode; const Text: string);
    property FileName: string read FFileName;
  end;

  TRule = class
  public
    function Name: string; virtual; abstract;
    function Kinds: TArray<string>; virtual; abstract;
    function Description: string; virtual; abstract;
    procedure Visit(const Node: TNode; Ctx: TContext); virtual; abstract;
  end;

// run the rules over one file's bytes: its messages, and the output in Output
function Run(const Source: TBytes; const Rules: TArray<TRule>; const FileName: string;
             out Output: TBytes): TArray<TMessage>;

// as Run, and the edits applied, in source order, for a tool to show or map lines
// through (an editor underlining what the rules change): none if they overlapped
function RunWithEdits(const Source: TBytes; const Rules: TArray<TRule>; const FileName: string;
                      out Output: TBytes; out Edits: TArray<TEdit>): TArray<TMessage>;

// the file's tree as text, a node a line, indented by depth: each node's Kind
// (what a rule's Kinds lists), its line, and a leaf's text. The first step of
// writing a rule: find the kind of node it is about (delphipp --tree FILE)
function TreeText(const Source: TBytes): string;

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

procedure TContext.AddEdit(StartByte, EndByte: Integer; const Text: string);
var
  E: TEdit;
begin
  E.StartByte := StartByte;
  E.EndByte   := EndByte;
  E.Bytes     := FEncoding.GetBytes(Text);
  E.Rule      := Rule;
  FEdits.Add(E);
end;

procedure TContext.Replace(const Node: TNode; const Text: string);
begin
  AddEdit(Node.StartByte, Node.EndByte, Text);
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
            Ctx.Rule := R.Name;
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

end.
