unit DelphiPP.Lsp;

{ A language server: the rules' findings in your editor as you type, as the Python side's
  delphipp.lsp, with nothing but this program (delphipp --lsp). Zed's extension starts it.

  What a rule reports shows as a diagnostic. What a rule would rewrite shows too, with the new
  text in the message, and a code action applies a rule's rewrites to the file. Nothing is
  changed until you ask. JSON-RPC over stdin and stdout.

  Navigation (implementation, definition, type definition, references) is DelfNav's: this
  server is DelfNav.Lsp's TNavServer with the rules added, DelfNav from the submodule
  ..\DelfNav (the user, 22 Nov: delphipp uses DelfNav).

  Two threads, as in Python: this one reads the editor's messages; a worker runs the rules on a
  file once its edits have paused, newest text only. Positions are LSP's: lines, and columns in
  UTF-16 units, which is what a Delphi string counts. }

interface

// serve on stdin and stdout until the editor says exit, or closes stdin
procedure Serve;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Math, System.Character, System.IOUtils,
  System.JSON, System.SyncObjs, System.Generics.Collections, System.Generics.Defaults,
  DelphiPP.Engine, DelphiPP.Rules, DelphiPP.Hover, DelfNav.Index, DelfNav.Lsp;

const
  Pause = 200;    // milliseconds after the last edit before running the rules

function Severity(const Level: string): Integer;
begin
  if Level = 'error' then Exit( 1 );
  if Level = 'warning' then Exit( 2 );
  if Level = 'hint' then Exit( 4 );
  Exit( 3 );
end;

{ Positions: LSP's lines and UTF-16 columns, from byte offsets }

type
  TPositions = class
    Raw   : TBytes;
    Starts: TArray<Integer>;   // the byte each line starts at
    constructor Create(const ARaw: TBytes);
    function StartOf(Line: Integer): Integer;
    function OfLineCol(Line, Col: Integer): TJSONObject;
    function OfByte(Offset: Integer): TJSONObject;
    function Range(StartByte, EndByte: Integer): TJSONObject;
  end;

constructor TPositions.Create(const ARaw: TBytes);
begin
  Raw := ARaw;
  var L := TList<Integer>.Create;
  try
    L.Add(0);
    for var I := 0 to High(Raw) do
      if Raw[I] = 10 then
        L.Add(I + 1);
    Starts := L.ToArray;
  finally
    L.Free;
  end;
end;

function TPositions.StartOf(Line: Integer): Integer;
begin
  Exit( Starts[Max(0, Min(Line, High(Starts)))] );
end;

function TPositions.OfLineCol(Line, Col: Integer): TJSONObject;
begin
  const Start = StartOf(Line);
  const Count = Max(0, Min(Col, Length(Raw) - Start));
  var Units := 0;
  if Count > 0 then
    Units := TEncoding.UTF8.GetString(Raw, Start, Count).Length;
  Result := TJSONObject.Create;
  Result.AddPair('line', Num(Line));
  Result.AddPair('character', Num(Units));
end;

function TPositions.OfByte(Offset: Integer): TJSONObject;
begin
  var Lo := 0;
  var Hi := High(Starts);
  while Lo < Hi do
  begin
    const Mid = (Lo + Hi + 1) div 2;
    if Starts[Mid] <= Offset then
      Lo := Mid
    else
      Hi := Mid - 1;
  end;
  Exit( OfLineCol(Lo, Offset - Starts[Lo]) );
end;

function TPositions.Range(StartByte, EndByte: Integer): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('start', OfByte(StartByte));
  Result.AddPair('end', OfByte(EndByte));
end;

function WouldWrite(const Rule, NewText: string): string;
begin
  var Shown := NewText.Trim;
  if Shown = '' then
    Shown := '(remove this)';
  Exit( Rule + ' would write:'#10 + Shown );
end;

function Diagnostic(Range: TJSONObject; Sev: Integer; const Source, Message: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('range', Range);
  Result.AddPair('severity', Num(Sev));
  Result.AddPair('source', Source);
  Result.AddPair('message', Message);
end;

type
  // a rule's edits from one visit to a node
  TGroup = record
    Rule       : string;
    Start, Stop: Integer;
    Edits      : TList<TEdit>;
  end;

// The rules over one text: the diagnostics, and each rule's edits as LSP text edits,
// rule: [edit, ...], in the order the rules first made one
procedure Analyse(const Text, FileName: string; out Found: TJSONArray; out Actions: TJSONObject);
begin
  const Raw = TEncoding.UTF8.GetBytes(Text);
  var Positions := TPositions.Create(Raw);
  var Groups := TList<TGroup>.Create;
  Found   := TJSONArray.Create;
  Actions := TJSONObject.Create;
  try
    try
      var Output: TBytes;
      var Edits: TArray<TEdit>;
      var Messages: TArray<TMessage>;
      var Rules := AllRules;
      try
        Messages := RunWithEdits(Raw, Rules, FileName, Output, Edits);
      finally
        for var R in Rules do
          R.Free;
      end;

      for var M in Messages do
      begin
        const Row = M.Line - 1;
        const Col = M.Col - 1;
        const At  = Positions.StartOf(Row) + Col;
        var Range := TJSONObject.Create;
        Range.AddPair('start', Positions.OfLineCol(Row, Col));
        Range.AddPair('end', Positions.OfByte(WordEnd(Raw, At)));
        Found.AddElement(Diagnostic(Range, Severity(M.Level), M.Rule, M.Text));
      end;

      for var EditIndex := 0 to High(Edits) do
      begin
        const E = Edits[EditIndex];
        const NewText = TEncoding.UTF8.GetString(E.Bytes);
        var List := Actions.GetValue(E.Rule) as TJSONArray;
        if List = nil then
        begin
          List := TJSONArray.Create;
          Actions.AddPair(E.Rule, List);
        end;
        var Edit := TJSONObject.Create;
        Edit.AddPair('range', Positions.Range(E.StartByte, E.EndByte));
        Edit.AddPair('newText', NewText);
        List.AddElement(Edit);

        if E.GroupStart >= 0 then
        begin
          var Index := -1;
          for var K := 0 to Groups.Count - 1 do
            if (Groups[K].Rule = E.Rule) and (Groups[K].Start = E.GroupStart) and
               (Groups[K].Stop = E.GroupEnd) then
              Index := K;
          if Index < 0 then
          begin
            var G: TGroup;
            G.Rule  := E.Rule;
            G.Start := E.GroupStart;
            G.Stop  := E.GroupEnd;
            G.Edits := TList<TEdit>.Create;
            Groups.Add(G);
            Index := Groups.Count - 1;
          end;
          Groups[Index].Edits.Add(E);
          Continue;
        end;
        // derive's helper declaration: the [Derive] attribute's hover has it (user, 13 Nov: "the
        // end marker is not needed")
        if InAnothersHover(Edits, EditIndex) then
          Continue;
        var A, B: Integer;
        var Written: TBytes;
        ChangedPart(Raw, E, A, B, Written);
        if B > A then
        begin
          if Blank(Written, 0, Length(Written)) then
            while (B > A) and (Raw[B - 1] in [9, 32]) do     // the blanks it takes after it
              Dec(B);
        end
        else
          InsertionRange(Raw, A, Written, A, B);
        const Body = TEncoding.UTF8.GetString(Written).Trim;
        // what the rule writes next from here: derive's helper declaration, from the attribute it
        // removes; its ToString has a squiggle of its own where it goes (user, 13 Nov: "[Derive]
        // hover ... nothing shows TMoodHelper", "derive is still not showing just the declaration")
        var More: string;
        var Message: string;
        const Related = FirstRelated(Edits, E, More);
        if Related and (Body = '') then
          Message := E.Rule + ' would remove this, and write:'#10 + More
        else if Related then
          Message := E.Rule + ' would write:'#10 + Body + #10#10'and:'#10 + More
        else
          Message := WouldWrite(E.Rule, TEncoding.UTF8.GetString(Written));
        Found.AddElement(Diagnostic(Positions.Range(A, B), 3, E.Rule, Message));
      end;

      // a rule's edits from one visit (a case-of's, one an arm) as one diagnostic over the
      // node, whose message is the node as rewritten: the whole if chain, as the IDE's hover
      for var G in Groups do
      begin
        var Whole: TBytes;
        var At := G.Start;
        for var E in G.Edits do     // in source order, as RunWithEdits gives them
        begin
          Whole := Whole + Copy(Raw, At, E.StartByte - At) + E.Bytes;
          At := E.EndByte;
        end;
        Whole := Whole + Copy(Raw, At, G.Stop - At);
        const Message = WouldWrite(G.Rule, TEncoding.UTF8.GetString(Whole));
        for var Piece in CodePieces(Raw, G.Start, G.Stop) do
          Found.AddElement(Diagnostic(Positions.Range(Piece.A, Piece.B), 3, G.Rule, Message));
      end;
    except
      FreeAndNil(Found);
      FreeAndNil(Actions);
      raise;
    end;
  finally
    for var G in Groups do
      G.Edits.Free;
    Groups.Free;
    Positions.Free;
  end;
end;

{ The server: DelfNav's navigation server (TNavServer), and the rules beside it }

type
  TPending = record
    Text: string;
    When: UInt64;
  end;

  TServer = class(TNavServer)
  private
    FWake   : TEvent;
    FPending: TDictionary<string, TPending>;           // FLock, as FActions and FExiting
    FActions: TObjectDictionary<string, TJSONObject>;
    FExiting: Boolean;
    procedure Work;
    function CodeActions(const Uri: string): TJSONArray;
  protected
    function Name: string; override;
    procedure Capabilities(Caps: TJSONObject); override;
    procedure Opened(const Uri, Text: string); override;
    procedure Closed(const Uri: string); override;
    function HandleOther(const Method: string; Id: TJSONValue; Params: TJSONObject): Boolean; override;
    procedure Starting; override;
    procedure Stopping; override;
  public
    constructor Create;
  end;

constructor TServer.Create;
begin
  inherited Create;
  FWake    := TEvent.Create(nil, False, False, '');    // auto-reset: a wake is never lost
  FPending := TDictionary<string, TPending>.Create;
  FActions := TObjectDictionary<string, TJSONObject>.Create([doOwnsValues]);
end;

function TServer.Name: string;
begin
  Exit( 'delphipp' );
end;

procedure TServer.Capabilities(Caps: TJSONObject);
begin
  inherited;     // navigation's: implementation, definition, declaration, type definition, references
  Caps.AddPair('codeActionProvider', TJSONBool.Create(True));
end;

procedure TServer.Opened(const Uri, Text: string);
begin
  // the rules only on .dpps, the preprocessor's own files; a .pas gets navigation alone
  // (the user, 21 Nov: "prob just dpps for now")
  if not SameText(ExtractFileExt(PathOf(Uri)), '.dpps') then
    Exit;
  var P: TPending;
  P.Text := Text;
  P.When := GetTickCount64;
  FLock.Enter;
  try
    FPending.AddOrSetValue(Uri, P);
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TServer.Closed(const Uri: string);
begin
  FLock.Enter;
  try
    FPending.Remove(Uri);
    FActions.Remove(Uri);
  finally
    FLock.Leave;
  end;
  var P := TJSONObject.Create;
  P.AddPair('uri', Uri);
  P.AddPair('diagnostics', TJSONArray.Create);
  Notify('textDocument/publishDiagnostics', P);
end;

function TServer.HandleOther(const Method: string; Id: TJSONValue; Params: TJSONObject): Boolean;
begin
  if Method = 'textDocument/codeAction' then
  begin
    Reply(Id, CodeActions(Params.GetValue<string>('textDocument.uri')));
    Exit( True );
  end;
  Exit( False );
end;

procedure TServer.Starting;
begin
  TThread.CreateAnonymousThread(procedure begin Work; end).Start;
end;

procedure TServer.Stopping;
begin
  FLock.Enter;
  try
    FExiting := True;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
  // the worker may be in the middle of a file: the process ends with it, as Python's daemon
end;

// the worker: the file whose edits paused first, its newest text, then the next
procedure TServer.Work;
begin
  while True do
  begin
    var Uri := '';
    var Text := '';
    var Wait: Cardinal := INFINITE;
    FLock.Enter;
    try
      if FExiting then
        Exit;
      if FPending.Count > 0 then
      begin
        var First: UInt64 := High(UInt64);
        for var Pair in FPending do
          if Pair.Value.When < First then
          begin
            First := Pair.Value.When;
            Uri   := Pair.Key;
          end;
        const Tick = GetTickCount64;
        if First + Pause > Tick then
          Wait := Cardinal(First + Pause - Tick)
        else
        begin
          Text := FPending[Uri].Text;
          FPending.Remove(Uri);
          Wait := 0;
        end;
      end;
    finally
      FLock.Leave;
    end;
    if Wait <> 0 then
    begin
      FWake.WaitFor(Wait);
      Continue;
    end;

    var Found: TJSONArray;
    var Actions: TJSONObject;
    try
      // the path, not the uri: assert-message writes the file's name into the code
      Analyse(Text.Replace(#13#10, #10), PathOf(Uri), Found, Actions);
    except
      // a rule being written may well fail: the editor hears why
      on E: Exception do
      begin
        const Why = Format('the rules failed on %s: %s: %s', [Uri, E.ClassName, E.Message]);
        Say(1, Why);
        Log(1, Why);
        Continue;
      end;
    end;
    var Stale: Boolean;
    FLock.Enter;
    try
      Stale := FPending.ContainsKey(Uri);
      if not Stale then
        FActions.AddOrSetValue(Uri, Actions);
    finally
      FLock.Leave;
    end;
    if Stale then
    begin
      Actions.Free;
      Found.Free;
    end
    else
    begin
      var Params := TJSONObject.Create;
      Params.AddPair('uri', Uri);
      Params.AddPair('diagnostics', Found);
      Notify('textDocument/publishDiagnostics', Params);
    end;
  end;
end;

function TServer.CodeActions(const Uri: string): TJSONArray;

  function Action(const Title, Kind: string; Edits: TJSONArray): TJSONObject;
  begin
    var Changes := TJSONObject.Create;
    Changes.AddPair(Uri, Edits);
    var Edit := TJSONObject.Create;
    Edit.AddPair('changes', Changes);
    Result := TJSONObject.Create;
    Result.AddPair('title', Title);
    Result.AddPair('kind', Kind);
    Result.AddPair('edit', Edit);
  end;

begin
  Result := TJSONArray.Create;
  FLock.Enter;
  try
    var ByRule: TJSONObject;
    if not FActions.TryGetValue(Uri, ByRule) then
      Exit;
    var Names: TArray<string>;
    for var Pair in ByRule do
      Names := Names + [Pair.JsonString.Value];
    TArray.Sort<string>(Names, TStringComparer.Ordinal);
    for var Name in Names do
    begin
      const Edits = ByRule.GetValue(Name) as TJSONArray;
      var S := '';
      if Edits.Count <> 1 then
        S := 's';
      Result.AddElement(Action(Format('Apply %s to this file (%d edit%s)', [Name, Edits.Count, S]),
                               'quickfix', TJSONArray(Edits.Clone)));
    end;
    if ByRule.Count > 1 then
    begin
      var Every := TJSONArray.Create;
      for var Pair in ByRule do     // in the order the rules first made an edit, as Python's
        for var E in TJSONArray(Pair.JsonValue) do
          Every.AddElement(TJSONValue(E.Clone));
      Result.AddElement(Action(Format('Apply every rule to this file (%d edits)', [Every.Count]),
                               'source', Every));
    end;
  finally
    FLock.Leave;
  end;
end;

procedure Serve;
begin
  var Server := TServer.Create;
  // stdout is the protocol's: a rule's Writeln goes to stderr, the editor's log
  TTextRec(Output).Handle := TTextRec(ErrOutput).Handle;
  Server.Run;
  // not freed: the worker thread may still hold it, and the process is ending
end;

end.
