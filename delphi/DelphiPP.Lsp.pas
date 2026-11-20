unit DelphiPP.Lsp;

{ A language server: the rules' findings in your editor as you type, as the Python side's
  delphipp.lsp, with nothing but this program (delphipp --lsp). Zed's extension starts it.

  What a rule reports shows as a diagnostic. What a rule would rewrite shows too, with the new
  text in the message, and a code action applies a rule's rewrites to the file. Nothing is
  changed until you ask. JSON-RPC over stdin and stdout.

  Go to implementation (textDocument/implementation): on a call on an interface, x.DoSomething,
  every class's method that implements it, across the workspace's units (DelphiPP.Impl).

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
  DelphiPP.Engine, DelphiPP.Rules, DelphiPP.Hover, DelphiPP.Impl;

const
  Pause = 200;    // milliseconds after the last edit before running the rules

function Severity(const Level: string): Integer;
begin
  if Level = 'error' then Exit( 1 );
  if Level = 'warning' then Exit( 2 );
  if Level = 'hint' then Exit( 4 );
  Exit( 3 );
end;

function Num(N: Integer): TJSONNumber;
begin
  Exit( TJSONNumber.Create(N) );
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

// file:///D:/a%20b/X.dpr -> D:\a b\X.dpr; file://server/share/X.dpr -> \\server\share\X.dpr
function PathOf(const Uri: string): string;
begin
  var S := Uri;
  if S.StartsWith('file:', True) then
    S := S.Substring(5);
  var Host := '';
  if S.StartsWith('//') then
  begin
    S := S.Substring(2);
    const Slash = S.IndexOf('/');
    if Slash < 0 then
    begin
      Host := S;
      S := '';
    end
    else
    begin
      Host := S.Substring(0, Slash);
      S := S.Substring(Slash);
    end;
  end;
  // percent escapes are UTF-8 bytes
  var Bytes: TBytes;
  var I := 0;
  while I < S.Length do
  begin
    const C = S.Chars[I];
    var Code: Integer;
    if (C = '%') and (I + 2 < S.Length) and TryStrToInt('$' + S.Substring(I + 1, 2), Code) then
    begin
      Bytes := Bytes + [Byte(Code)];
      Inc(I, 3);
    end
    else
    begin
      Bytes := Bytes + TEncoding.UTF8.GetBytes(string(C));
      Inc(I);
    end;
  end;
  var Path := TEncoding.UTF8.GetString(Bytes);
  // /D:/x or /D|/x is a drive's
  if (Path.Length >= 3) and (Path.Chars[0] = '/') and Path.Chars[1].IsLetter and
     ((Path.Chars[2] = ':') or (Path.Chars[2] = '|')) then
    Path := Path.Chars[1] + ':' + Path.Substring(3);
  if (Host <> '') and not SameText(Host, 'localhost') then
    Path := '//' + Host + Path;
  Exit( Path.Replace('/', PathDelim) );
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

// D:\a b\X.pas -> file:///D:/a%20b/X.pas; \\server\share\X.pas -> file://server/share/X.pas
function UriOf(const Path: string): string;
begin
  var S := Path.Replace('\', '/');
  var Prefix := 'file:///';
  if S.StartsWith('//') then
  begin
    Prefix := 'file:';
  end;
  Result := Prefix;
  for var B in TEncoding.UTF8.GetBytes(S) do
    if CharInSet(Char(B), ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~', '/', ':']) then
      Result := Result + Char(B)
    else
      Result := Result + '%' + IntToHex(B, 2);
end;

{ The protocol: Content-Length framed JSON on the standard handles }

type
  TPending = record
    Text: string;
    When: UInt64;
  end;

  // DelphiPP.Impl's queries: Implementations, Definitions, TypeDefinitions
  TFinder = function(const Path, Text: string; Line, Character: Integer;
    WaitMs: Cardinal): TArray<TImplTarget>;

  TServer = class
  private
    FIn, FOut : THandle;
    FBuffer   : array[0..65535] of Byte;
    FHave, FAt: Integer;
    FWriteLock: TCriticalSection;
    FLock     : TCriticalSection;     // FPending, FActions, FExiting
    FWake     : TEvent;
    FPending  : TDictionary<string, TPending>;
    FActions  : TObjectDictionary<string, TJSONObject>;
    FTexts    : TDictionary<string, string>;   // each open file's newest text, for queries
    FExiting  : Boolean;
    // the last find references, when it stopped on its budget: asked again at the same place,
    // it goes on from there and answers all found so far (requests come one at a time)
    FRefsKey  : string;
    FRefsSoFar: TArray<TImplTarget>;
    FRefsNext : Integer;
    function NextByte(out B: Byte): Boolean;
    function ReadLine(out Line: string): Boolean;
    function ReadMessage: TJSONObject;
    procedure Send(Msg: TJSONObject);
    procedure Reply(Id: TJSONValue; Value: TJSONValue);
    procedure Notify(const Method: string; Params: TJSONObject);
    procedure Want(const Uri, Text: string);
    procedure Work;
    function CodeActions(const Uri: string): TJSONArray;
    function LocationsAt(Params: TJSONObject; Find: TFinder): TJSONArray;
    procedure Handle(Msg: TJSONObject);
  public
    constructor Create;
    procedure Run;
  end;

constructor TServer.Create;
begin
  FIn  := GetStdHandle(STD_INPUT_HANDLE);
  FOut := GetStdHandle(STD_OUTPUT_HANDLE);
  FWriteLock := TCriticalSection.Create;
  FLock      := TCriticalSection.Create;
  FWake      := TEvent.Create(nil, False, False, '');    // auto-reset: a wake is never lost
  FPending   := TDictionary<string, TPending>.Create;
  FActions   := TObjectDictionary<string, TJSONObject>.Create([doOwnsValues]);
  FTexts     := TDictionary<string, string>.Create;
end;

function TServer.NextByte(out B: Byte): Boolean;
begin
  if FAt >= FHave then
  begin
    var Got: DWORD := 0;
    // a closed pipe is the end of input, as a read of nothing is
    if not ReadFile(FIn, FBuffer, SizeOf(FBuffer), Got, nil) or (Got = 0) then
      Exit( False );
    FHave := Got;
    FAt   := 0;
  end;
  B := FBuffer[FAt];
  Inc(FAt);
  Exit( True );
end;

// a header line, without its CR LF; False at the end of input
function TServer.ReadLine(out Line: string): Boolean;
begin
  var Bytes: TBytes;
  var B: Byte;
  var Any := False;
  while NextByte(B) do
  begin
    Any := True;
    if B = 10 then
      Break;
    Bytes := Bytes + [B];
  end;
  Line := TEncoding.ASCII.GetString(Bytes).Trim;
  Exit( Any );
end;

// the next message, or nil at the end of input
function TServer.ReadMessage: TJSONObject;
begin
  var Size := -1;
  var Line: string;
  repeat
    if not ReadLine(Line) then
      Exit( nil );
    const Colon = Line.IndexOf(':');
    if (Colon > 0) and SameText(Line.Substring(0, Colon).Trim, 'Content-Length') then
      Size := StrToIntDef(Line.Substring(Colon + 1).Trim, -1);
  until Line = '';
  if Size < 0 then
    Exit( TJSONObject.Create );     // no body: nothing to do, read on
  var Body: TBytes;
  SetLength(Body, Size);
  for var I := 0 to Size - 1 do
    if not NextByte(Body[I]) then
      Exit( nil );
  const Value = TJSONObject.ParseJSONValue(Body, 0, True);
  if Value is TJSONObject then
    Exit( TJSONObject(Value) );
  Value.Free;
  Exit( TJSONObject.Create );
end;

// takes Msg and frees it
procedure TServer.Send(Msg: TJSONObject);
begin
  try
    const Body = TEncoding.UTF8.GetBytes(Msg.ToJSON);
    const Head = TEncoding.ASCII.GetBytes(Format('Content-Length: %d'#13#10#13#10, [Length(Body)]));
    const All = Head + Body;
    FWriteLock.Enter;
    try
      var Done := 0;
      while Done < Length(All) do
      begin
        var Wrote: DWORD := 0;
        if not WriteFile(FOut, All[Done], Length(All) - Done, Wrote, nil) then
          Exit;     // the editor has gone
        Inc(Done, Wrote);
      end;
    finally
      FWriteLock.Leave;
    end;
  finally
    Msg.Free;
  end;
end;

procedure TServer.Reply(Id: TJSONValue; Value: TJSONValue);
begin
  if Id = nil then
  begin
    Value.Free;     // a notification wants no reply
    Exit;
  end;
  var Msg := TJSONObject.Create;
  Msg.AddPair('jsonrpc', '2.0');
  Msg.AddPair('id', TJSONValue(Id.Clone));
  Msg.AddPair('result', Value);
  Send(Msg);
end;

procedure TServer.Notify(const Method: string; Params: TJSONObject);
begin
  var Msg := TJSONObject.Create;
  Msg.AddPair('jsonrpc', '2.0');
  Msg.AddPair('method', Method);
  Msg.AddPair('params', Params);
  Send(Msg);
end;

procedure TServer.Want(const Uri, Text: string);
begin
  var P: TPending;
  P.Text := Text;
  P.When := GetTickCount64;
  FLock.Enter;
  try
    // the rules only on .dpps, the preprocessor's own files; a .pas gets navigation alone
    // (the user, 21 Nov: "prob just dpps for now")
    if SameText(ExtractFileExt(PathOf(Uri)), '.dpps') then
      FPending.AddOrSetValue(Uri, P);
    FTexts.AddOrSetValue(Uri, Text);
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
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
        var Shown := TJSONObject.Create;
        Shown.AddPair('type', Num(1));
        Shown.AddPair('message', Why);
        Notify('window/showMessage', Shown);
        var Logged := TJSONObject.Create;
        Logged.AddPair('type', Num(1));
        Logged.AddPair('message', Why);
        Notify('window/logMessage', Logged);
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

// textDocument/implementation: a Location for each implementing method, none when the name
// under the cursor isn't a call on an interface; textDocument/definition (and declaration):
// where the name is declared; textDocument/typeDefinition: where its type is
function TServer.LocationsAt(Params: TJSONObject; Find: TFinder): TJSONArray;
begin
  Result := TJSONArray.Create;
  const Uri = Params.GetValue<string>('textDocument.uri');
  var Text: string;
  FLock.Enter;
  try
    if not FTexts.TryGetValue(Uri, Text) then
      Text := '';
  finally
    FLock.Leave;
  end;
  const Path = PathOf(Uri);
  if (Text = '') and FileExists(Path) then
    Text := TFile.ReadAllText(Path);
  const Line = Params.GetValue<Integer>('position.line');
  const Character = Params.GetValue<Integer>('position.character');
  var Targets: TArray<TImplTarget>;
  if Assigned(Find) then
    Targets := Find(Path, Text, Line, Character, 30000)
  else
  begin
    // textDocument/references: the other files open in the editor as it has them
    var Open := TDictionary<string, string>.Create;
    FLock.Enter;
    try
      for var Pair in FTexts do
        Open.AddOrSetValue(PathOf(Pair.Key).ToLower, Pair.Value);
    finally
      FLock.Leave;
    end;
    try
      var Decl := False;
      if Params.GetValue('context') is TJSONObject then
        Params.TryGetValue<Boolean>('context.includeDeclaration', Decl);
      // half a second at a time (the user, 21 Nov: "a time budget like 0.5sec"); the same
      // place asked again goes on where it stopped
      const Key = Format('%s|%d|%d|%s', [Uri, Line, Character, BoolToStr(Decl)]);
      var First := 0;
      var SoFar: TArray<TImplTarget> := nil;
      if (Key = FRefsKey) and (FRefsNext > 0) then
      begin
        First := FRefsNext;
        SoFar := FRefsSoFar;
      end;
      var More: TRefsMore;
      Targets := SoFar + References(Path, Text, Line, Character, Decl,
        function(P: string): string
        begin
          if not Open.TryGetValue(P.ToLower, Result) then
            Result := '';
        end, 30000, 500, First, More);
      FRefsKey   := Key;
      FRefsSoFar := Targets;
      FRefsNext  := More.Next;
      var Say := '';
      if More.Common then
        Say := 'delphipp: a name every unit uses (Integer, string, TObject ...): its uses aren''t listed'
      else if More.Next >= 0 then
        Say := Format('delphipp: %d found so far, %d of %d units read: Find All References again for more',
          [Length(Targets), More.Read, More.Total]);
      if Say <> '' then
      begin
        var Shown := TJSONObject.Create;
        Shown.AddPair('type', Num(3));
        Shown.AddPair('message', Say);
        Notify('window/showMessage', Shown);
      end;
    finally
      Open.Free;
    end;
  end;
  for var T in Targets do
  begin
    var At := TJSONObject.Create;
    At.AddPair('line', Num(T.Line - 1));
    At.AddPair('character', Num(T.Col));
    var Upto := TJSONObject.Create;
    Upto.AddPair('line', Num(T.Line - 1));
    Upto.AddPair('character', Num(T.Col + T.Len));
    var Range := TJSONObject.Create;
    Range.AddPair('start', At);
    Range.AddPair('end', Upto);
    var L := TJSONObject.Create;
    L.AddPair('uri', UriOf(T.Path));
    L.AddPair('range', Range);
    Result.AddElement(L);
  end;
end;

procedure TServer.Handle(Msg: TJSONObject);
begin
  const MethodValue = Msg.GetValue('method');
  if MethodValue = nil then
    Exit;     // a reply to us: we ask nothing
  const Method = MethodValue.Value;
  var Id := Msg.GetValue('id');
  if Id is TJSONNull then
    Id := nil;
  // params may be missing, or null (as a shutdown's often is): either is no params
  var Params: TJSONObject;
  if Msg.GetValue('params') is TJSONObject then
    Params := TJSONObject(Msg.GetValue('params'))
  else
  begin
    Msg.RemovePair('params').Free;
    Params := TJSONObject.Create;
    Msg.AddPair('params', Params);
  end;

  if Method = 'initialize' then
  begin
    var Sync := TJSONObject.Create;
    Sync.AddPair('openClose', TJSONBool.Create(True));
    Sync.AddPair('change', Num(1));
    Sync.AddPair('save', TJSONObject.Create);    // didSave: the index reads that file again
    var Caps := TJSONObject.Create;
    Caps.AddPair('textDocumentSync', Sync);
    Caps.AddPair('codeActionProvider', TJSONBool.Create(True));
    Caps.AddPair('implementationProvider', TJSONBool.Create(True));
    Caps.AddPair('definitionProvider', TJSONBool.Create(True));
    Caps.AddPair('declarationProvider', TJSONBool.Create(True));
    Caps.AddPair('typeDefinitionProvider', TJSONBool.Create(True));
    Caps.AddPair('referencesProvider', TJSONBool.Create(True));
    // the workspace's units, indexed in the background for go to implementation
    var Root := '';
    if Params.GetValue('rootUri') is TJSONString then
      Root := PathOf(Params.GetValue<string>('rootUri'))
    else if (Params.GetValue('workspaceFolders') is TJSONArray) and
            (TJSONArray(Params.GetValue('workspaceFolders')).Count > 0) then
      Root := PathOf(TJSONArray(Params.GetValue('workspaceFolders')).Items[0].GetValue<string>('uri'));
    if (Root <> '') and DirectoryExists(Root) then
      IndexFolder(Root);
    var Info := TJSONObject.Create;
    Info.AddPair('name', 'delphipp');
    var R := TJSONObject.Create;
    R.AddPair('capabilities', Caps);
    R.AddPair('serverInfo', Info);
    Reply(Id, R);
  end
  else if Method = 'shutdown' then
    Reply(Id, TJSONNull.Create)
  else if Method = 'textDocument/didOpen' then
    Want(Params.GetValue<string>('textDocument.uri'), Params.GetValue<string>('textDocument.text'))
  else if Method = 'textDocument/didChange' then
  begin
    const Changes = Params.GetValue('contentChanges') as TJSONArray;
    Want(Params.GetValue<string>('textDocument.uri'),
         Changes.Items[Changes.Count - 1].GetValue<string>('text'));
  end
  else if Method = 'textDocument/didSave' then
    Reindex(PathOf(Params.GetValue<string>('textDocument.uri')))
  else if Method = 'textDocument/didClose' then
  begin
    const Uri = Params.GetValue<string>('textDocument.uri');
    FLock.Enter;
    try
      FPending.Remove(Uri);
      FActions.Remove(Uri);
      FTexts.Remove(Uri);
    finally
      FLock.Leave;
    end;
    var P := TJSONObject.Create;
    P.AddPair('uri', Uri);
    P.AddPair('diagnostics', TJSONArray.Create);
    Notify('textDocument/publishDiagnostics', P);
    // closed unsaved, its edits may be in the index: as saved again
    Reindex(PathOf(Uri));
  end
  else if Method = 'textDocument/codeAction' then
    Reply(Id, CodeActions(Params.GetValue<string>('textDocument.uri')))
  else if Method = 'textDocument/implementation' then
    Reply(Id, LocationsAt(Params, Implementations))
  else if (Method = 'textDocument/definition') or (Method = 'textDocument/declaration') then
    Reply(Id, LocationsAt(Params, Definitions))
  else if Method = 'textDocument/typeDefinition' then
    Reply(Id, LocationsAt(Params, TypeDefinitions))
  else if Method = 'textDocument/references' then
    Reply(Id, LocationsAt(Params, nil))
  else if Id <> nil then
  begin
    var Err := TJSONObject.Create;
    Err.AddPair('code', Num(-32601));
    Err.AddPair('message', 'no ' + Method);
    var Msg2 := TJSONObject.Create;
    Msg2.AddPair('jsonrpc', '2.0');
    Msg2.AddPair('id', TJSONValue(Id.Clone));
    Msg2.AddPair('error', Err);
    Send(Msg2);
  end;
end;

procedure TServer.Run;
begin
  TThread.CreateAnonymousThread(procedure begin Work; end).Start;
  while True do
  begin
    const Msg = ReadMessage;
    if Msg = nil then
      Break;
    try
      const Method = Msg.GetValue('method');
      if (Method <> nil) and (Method.Value = 'exit') then
        Break;
      try
        Handle(Msg);
      except
        // a message we can't read is logged and skipped, not the end of the server
        on E: Exception do
        begin
          var P := TJSONObject.Create;
          P.AddPair('type', Num(1));
          P.AddPair('message', Format('delphipp: %s: %s', [E.ClassName, E.Message]));
          Notify('window/logMessage', P);
        end;
      end;
    finally
      Msg.Free;
    end;
  end;
  FLock.Enter;
  try
    FExiting := True;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
  // the worker may be in the middle of a file: the process ends with it, as Python's daemon
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
