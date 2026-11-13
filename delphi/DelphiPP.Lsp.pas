unit DelphiPP.Lsp;

{ A language server: the rules' findings in your editor as you type, as the Python side's
  delphipp.lsp, with nothing but this program (delphipp --lsp). Zed's extension starts it.

  What a rule reports shows as a diagnostic. What a rule would rewrite shows too, with the new
  text in the message, and a code action applies a rule's rewrites to the file. Nothing is
  changed until you ask. JSON-RPC over stdin and stdout.

  Two threads, as in Python: this one reads the editor's messages; a worker runs the rules on a
  file once its edits have paused, newest text only. Positions are LSP's: lines, and columns in
  UTF-16 units, which is what a Delphi string counts. }

interface

// serve on stdin and stdout until the editor says exit, or closes stdin
procedure Serve;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Math, System.Character,
  System.JSON, System.SyncObjs, System.Generics.Collections, System.Generics.Defaults,
  DelphiPP.Engine, DelphiPP.Rules;

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

function LineEndByte(const Raw: TBytes; Offset: Integer): Integer;
begin
  for var I := Max(0, Offset) to High(Raw) do
    if Raw[I] = 10 then
      Exit( I );
  Exit( Length(Raw) );
end;

// a byte as Python's chr(b).isalnum() sees it, or '_'
function IsWordByte(B: Byte): Boolean;
begin
  const C = Char(B);
  Exit( (B = Ord('_')) or C.IsLetterOrDigit or C.IsNumber );
end;

// A squiggle needs some width: the word at a message's or an insertion's place
function WordEnd(const Raw: TBytes; Offset: Integer): Integer;
begin
  const Stop = LineEndByte(Raw, Offset);
  var I := Offset;
  while (I < Stop) and IsWordByte(Raw[I]) do
    Inc(I);
  if I > Offset then
    Exit( I );
  Exit( Min(Offset + 1, Stop) );
end;

// blanks only, as Python's bytes.strip() sees them
function Blank(const Raw: TBytes; StartByte, EndByte: Integer): Boolean;
begin
  for var I := StartByte to EndByte - 1 do
    if not (Raw[I] in [9..13, 32]) then
      Exit( False );
  Exit( True );
end;

// the first byte that isn't blank in [StartByte, EndByte), or EndByte
function FirstNonBlank(const Raw: TBytes; StartByte, EndByte: Integer): Integer;
begin
  Result := StartByte;
  while (Result < EndByte) and (Raw[Result] in [9..13, 32]) do
    Inc(Result);
end;

// An insertion's squiggle. A line of its own, put above a line (footnotes' ///): that line, and
// on past attribute lines to the declaration under them, so hovering the declaration shows it
// (user, 13 Nov: "i don't get any /// for tmood", over [Derive(ToString)]). Else the word at its
// place. As the Python side's insertion_end
function InsertionEnd(const Raw: TBytes; Start: Integer; const Text: TBytes): Integer;
begin
  var LineStart := Start;
  while (LineStart > 0) and (Raw[LineStart - 1] <> 10) do
    Dec(LineStart);
  var LastBreak := -1;
  for var I := 0 to High(Text) do
    if Text[I] = 10 then
      LastBreak := I;
  if (LastBreak >= 0) and Blank(Raw, LineStart, Start) and Blank(Text, LastBreak + 1, Length(Text)) then
  begin
    var Stop := LineEndByte(Raw, Start);
    var First := FirstNonBlank(Raw, Start, Stop);
    while (First < Stop) and (Raw[First] = Ord('[')) and (Stop < Length(Raw)) do
    begin
      const NextStart = Stop + 1;
      Stop := LineEndByte(Raw, NextStart);
      First := FirstNonBlank(Raw, NextStart, Stop);
    end;
    if (Stop > Start) and (Raw[Stop - 1] = 13) then
      Dec(Stop);
    if Stop > Start then
      Exit( Stop );
  end;
  Exit( WordEnd(Raw, Start) );
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

      for var E in Edits do
      begin
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
        var Stop := E.EndByte;
        if Stop <= E.StartByte then
          Stop := InsertionEnd(Raw, E.StartByte, E.Bytes);
        Found.AddElement(Diagnostic(Positions.Range(E.StartByte, Stop), 3, E.Rule, WouldWrite(E.Rule, NewText)));
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
        Found.AddElement(Diagnostic(Positions.Range(G.Start, G.Stop), 3, G.Rule,
                                    WouldWrite(G.Rule, TEncoding.UTF8.GetString(Whole))));
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

{ The protocol: Content-Length framed JSON on the standard handles }

type
  TPending = record
    Text: string;
    When: UInt64;
  end;

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
    FExiting  : Boolean;
    function NextByte(out B: Byte): Boolean;
    function ReadLine(out Line: string): Boolean;
    function ReadMessage: TJSONObject;
    procedure Send(Msg: TJSONObject);
    procedure Reply(Id: TJSONValue; Value: TJSONValue);
    procedure Notify(const Method: string; Params: TJSONObject);
    procedure Want(const Uri, Text: string);
    procedure Work;
    function CodeActions(const Uri: string): TJSONArray;
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
    FPending.AddOrSetValue(Uri, P);
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
    var Caps := TJSONObject.Create;
    Caps.AddPair('textDocumentSync', Sync);
    Caps.AddPair('codeActionProvider', TJSONBool.Create(True));
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
  else if Method = 'textDocument/didClose' then
  begin
    const Uri = Params.GetValue<string>('textDocument.uri');
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
  end
  else if Method = 'textDocument/codeAction' then
    Reply(Id, CodeActions(Params.GetValue<string>('textDocument.uri')))
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
