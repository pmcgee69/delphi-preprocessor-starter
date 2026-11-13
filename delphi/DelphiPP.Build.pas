unit DelphiPP.Build;

{ The rules, then dcc: does a rewrite really compile? As the Python side's python -m delphipp.build,
  with nothing but this program: Zed's tasks run it (user, 13 Nov: "switch the tasks to delphipp").

    delphipp --build FILE [--run] [--win32]   rewrite FILE into a folder of its own and compile it
    delphipp --diff FILE                      what the rules change in FILE, as a unified diff

  FILE itself is never written. The rewrite has dcc's LINE directives (WithLines, as the IDE's pre-build
  event writes a .dpps's .pas), so dcc's messages name FILE and its lines, not the copy's. }

interface

uses
  System.SysUtils, DelphiPP.Engine;

// rewrite and compile FileName; with Run, run the program it made. The exit status: 1 for a
// rule's error or dcc's refusal, else 0, or the program's own
function Build(const FileName: string; const Rules: TArray<TRule>; Run, Win32: Boolean): Integer;

// the rules' messages, and what they change in FileName; 1 for a rule's error, else 0
function Diff(const FileName: string; const Rules: TArray<TRule>): Integer;

// A source's `unit X.dpps;` is, in X.pas, `unit X;` (after a UTF-8 BOM too, which the IDE may
// write, and the {$LINE} naming the source)
function Unsuffixed(const Source: TBytes): TBytes;

implementation

uses
  Winapi.Windows, System.Classes, System.IOUtils, System.Hash, System.Math,
  System.StrUtils, System.RegularExpressions, System.Generics.Collections;

// Matched on the bytes seen as Latin-1, one char each, so a match's place is its place in the
// bytes, and those are cut: nothing is decoded and written back.
function Unsuffixed(const Source: TBytes): TBytes;
const
  Space  = '[ \t\r\n\f\v]';
  Header = '(?im)^((?:\xEF\xBB\xBF)?(?:\{\$LINE [^}]*\})?' + Space + '*(?:unit|program|library)' + Space + '+)' +
           '([A-Za-z0-9_.]+?)\.dpps(' + Space + '*;)';
  Dpps   = Length('.dpps');
begin
  var Latin1 := '';
  SetLength(Latin1, Length(Source));
  for var I := 0 to High(Source) do
    Latin1[I + 1] := Char(Source[I]);
  const M = TRegEx.Match(Latin1, Header);
  if not M.Success then
    Exit( Source );
  const Cut = M.Groups[3].Index - 1 - Dpps;     // 0-based: the byte of the '.'
  Result := Copy(Source, 0, Cut) + Copy(Source, Cut + Dpps, MaxInt);
end;

// what the console shows is UTF-8: a diff of a source with é in it shows é
procedure Utf8Console;
begin
  SetConsoleOutputCP(CP_UTF8);
  SetTextCodePage(Output, CP_UTF8);
  SetTextCodePage(ErrOutput, CP_UTF8);
end;

// the rules' messages, as dcc's are written: FILE(12) Warning: text [rule]; True for an error
function Report(const FileName: string; const Messages: TArray<TMessage>): Boolean;
begin
  Result := False;
  for var M in Messages do
  begin
    Writeln(Format('%s(%d) %s: %s [%s]',
                   [FileName, M.Line, UpperCase(M.Level.Substring(0, 1)) + M.Level.Substring(1),
                    M.Text, M.Rule]));
    Result := Result or (M.Level = 'error');
  end;
end;

{ The diff }

type
  TOp = record
    Kind: Char;           // ' ' the same, '-' the source's only, '+' the output's only
    A, B: Integer;        // the line in each, 0-based, where the op is
  end;

  // lines an edit touched: [A0, A1) of the source's, [B0, B1) of the output's
  TRegion = record
    A0, A1, B0, B1: Integer;
  end;

// the line breaks in Bytes[StartByte, EndByte): the line, 0-based, that EndByte is on
function Breaks(const Bytes: TBytes; StartByte, EndByte: Integer): Integer;
begin
  Result := 0;
  for var I := StartByte to EndByte - 1 do
    if Bytes[I] = 10 then
      Inc(Result);
end;

// the text's lines, without their breaks, as Python's splitlines (no last empty one)
function LinesOf(const Bytes: TBytes; Encoding: TEncoding): TArray<string>;
begin
  Result := Encoding.GetString(Bytes).Split([#10]);
  if (Length(Result) > 0) and (Result[High(Result)] = '') then
    SetLength(Result, Length(Result) - 1);
  for var I := 0 to High(Result) do
    if Result[I].EndsWith(#13) then
      Result[I] := Result[I].Substring(0, Result[I].Length - 1);
end;

// the shortest edit of A[A0..A1) into B[B0..B1), Myers' way: only the lines an edit touched are
// given, so these are a few lines, not the file
procedure Shortest(const A, B: TArray<string>; A0, A1, B0, B1: Integer; Ops: TList<TOp>);

  procedure Add(Kind: Char; I, J: Integer; Into: TList<TOp>);
  begin
    var Op: TOp;
    Op.Kind := Kind;
    Op.A := I;
    Op.B := J;
    Into.Add(Op);
  end;

begin
  const N = A1 - A0;
  const M = B1 - B0;
  const Max = N + M;
  if Max = 0 then
    Exit;
  var V: TArray<Integer>;
  SetLength(V, 2 * Max + 2);
  var Trace := TList<TArray<Integer>>.Create;
  try
    var Done := False;
    for var D := 0 to Max do
    begin
      Trace.Add(Copy(V));
      var K := -D;
      while K <= D do
      begin
        var X: Integer;
        if (K = -D) or ((K <> D) and (V[Max + K - 1] < V[Max + K + 1])) then
          X := V[Max + K + 1]
        else
          X := V[Max + K - 1] + 1;
        var Y := X - K;
        while (X < N) and (Y < M) and (A[A0 + X] = B[B0 + Y]) do
        begin
          Inc(X);
          Inc(Y);
        end;
        V[Max + K] := X;
        if (X >= N) and (Y >= M) then
        begin
          Done := True;
          Break;
        end;
        Inc(K, 2);
      end;
      if Done then
        Break;
    end;
    // back from the end, through each step's V: the ops, last first
    var Back := TList<TOp>.Create;
    try
      var X := N;
      var Y := M;
      for var D := Trace.Count - 1 downto 0 do
      begin
        const W = Trace[D];
        const K = X - Y;
        var PrevK: Integer;
        if (K = -D) or ((K <> D) and (W[Max + K - 1] < W[Max + K + 1])) then
          PrevK := K + 1
        else
          PrevK := K - 1;
        const PrevX = W[Max + PrevK];
        const PrevY = PrevX - PrevK;
        while (X > PrevX) and (Y > PrevY) do
        begin
          Dec(X);
          Dec(Y);
          Add(' ', A0 + X, B0 + Y, Back);
        end;
        if D > 0 then
          if X = PrevX then
            Add('+', A0 + X, B0 + PrevY, Back)
          else
            Add('-', A0 + PrevX, B0 + Y, Back);
        X := PrevX;
        Y := PrevY;
      end;
      for var I := Back.Count - 1 downto 0 do
        Ops.Add(Back[I]);
    finally
      Back.Free;
    end;
  finally
    Trace.Free;
  end;
end;

// difflib's: "3,2" for lines 3 and 4, "3" for line 3 alone, "2,0" for none after line 2
function Range(Start, Count: Integer): string;
begin
  if Count = 1 then
    Exit( IntToStr(Start + 1) );
  if Count = 0 then
    Exit( Format('%d,0', [Start]) );
  Exit( Format('%d,%d', [Start + 1, Count]) );
end;

// the unified diff of Source and Output, Python's difflib.unified_diff's shape, 3 lines around each
// change. Only the lines the edits touch are compared: the rest is the same by construction
procedure ShowDiff(const FileName: string; const Source, Rewritten: TBytes; const Edits: TArray<TEdit>);
const
  Context = 3;
begin
  var Encoding := SourceEncoding(Source);
  var A, B: TArray<string>;
  try
    A := LinesOf(Source, Encoding);
    B := LinesOf(Rewritten, Encoding);
  finally
    if not TEncoding.IsStandardEncoding(Encoding) then
      Encoding.Free;
  end;

  // each edit's lines: in the source, from its start's line to its end's; in the output, the same
  // from where the earlier edits moved it to. Edits sharing a line are one region
  var Regions := TList<TRegion>.Create;
  var Ops := TList<TOp>.Create;
  try
    const Same = (Length(Source) = Length(Rewritten)) and
                 CompareMem(Pointer(Source), Pointer(Rewritten), Length(Source));
    if (Length(Edits) = 0) and not Same then
    begin
      // changed, but with no edits to say where (they overlapped): the whole file
      var R: TRegion;
      R.A0 := 0; R.A1 := Length(A); R.B0 := 0; R.B1 := Length(B);
      Regions.Add(R);
    end;
    var Shift := 0;     // the output's bytes ahead of the source's, after the edits passed
    for var E in Edits do
    begin
      var R: TRegion;
      R.A0 := Breaks(Source, 0, E.StartByte);
      R.A1 := Min(Breaks(Source, 0, E.EndByte) + 1, Length(A));
      const OutStart = E.StartByte + Shift;
      const OutEnd = OutStart + Length(E.Bytes);
      R.B0 := Breaks(Rewritten, 0, OutStart);
      R.B1 := Min(Breaks(Rewritten, 0, OutEnd) + 1, Length(B));
      Inc(Shift, Length(E.Bytes) - (E.EndByte - E.StartByte));
      if (Regions.Count > 0) and (R.A0 < Regions.Last.A1) then
      begin
        var Last := Regions.Last;
        Last.A1 := Max(Last.A1, R.A1);
        Last.B1 := Max(Last.B1, R.B1);
        Regions[Regions.Count - 1] := Last;
      end
      else
        Regions.Add(R);
    end;

    // every line as an op: the same between the regions, Myers' within each
    var I := 0;
    var J := 0;
    for var R in Regions do
    begin
      while I < R.A0 do
      begin
        var Op: TOp;
        Op.Kind := ' '; Op.A := I; Op.B := J;
        Ops.Add(Op);
        Inc(I); Inc(J);
      end;
      Shortest(A, B, R.A0, R.A1, R.B0, R.B1, Ops);
      I := R.A1;
      J := R.B1;
    end;
    while (I < Length(A)) and (J < Length(B)) do
    begin
      var Op: TOp;
      Op.Kind := ' '; Op.A := I; Op.B := J;
      Ops.Add(Op);
      Inc(I); Inc(J);
    end;

    // in each run of changes, the source's lines before the output's, as difflib shows them
    var Run := 0;
    while Run < Ops.Count do
    begin
      if Ops[Run].Kind = ' ' then
      begin
        Inc(Run);
        Continue;
      end;
      var Stop := Run;
      while (Stop < Ops.Count) and (Ops[Stop].Kind <> ' ') do
        Inc(Stop);
      var Sorted: TArray<TOp>;
      for var Kind in ['-', '+'] do
        for var P := Run to Stop - 1 do
          if Ops[P].Kind = Kind then
            Sorted := Sorted + [Ops[P]];
      for var P := 0 to High(Sorted) do
        Ops[Run + P] := Sorted[P];
      Run := Stop;
    end;

    // a run of lines added (or removed) alone, whose first line is the same as the line after
    // it, may as well be a line later: it is, as far as it goes, so a block added with a blank
    // line around it is shown as difflib shows it, the blank before it kept
    var At := 0;
    while At < Ops.Count do
    begin
      const Kind = Ops[At].Kind;
      if Kind = ' ' then
      begin
        Inc(At);
        Continue;
      end;
      var Stop := At;
      while (Stop < Ops.Count) and (Ops[Stop].Kind = Kind) do
        Inc(Stop);
      // [At, Stop) all Kind, and an unchanged line after them: slide while their first matches it
      while (Stop < Ops.Count) and (Ops[Stop].Kind = ' ') and
            (((Kind = '+') and (B[Ops[At].B] = B[Ops[Stop].B])) or
             ((Kind = '-') and (A[Ops[At].A] = A[Ops[Stop].A]))) do
      begin
        var Kept := Ops[At];
        Kept.Kind := ' ';
        if Kind = '+' then
          Kept.A := Ops[Stop].A
        else
          Kept.B := Ops[Stop].B;
        for var P := At + 1 to Stop do
        begin
          var Op := Ops[P];
          Op.Kind := Kind;
          if Kind = '+' then
          begin
            Op.A := Ops[Stop].A + 1;
            Op.B := Ops[At].B + (P - At);
          end
          else
          begin
            Op.A := Ops[At].A + (P - At);
            Op.B := Ops[Stop].B + 1;
          end;
          Ops[P] := Op;
        end;
        Ops[At] := Kept;
        Inc(At);
        Inc(Stop);
      end;
      At := Stop;
    end;

    // the hunks: changes with no more than 2 * Context same lines between them are one
    var First := True;
    var K := 0;
    while K < Ops.Count do
    begin
      if Ops[K].Kind = ' ' then
      begin
        Inc(K);
        Continue;
      end;
      var Last := K;     // the hunk's last change
      var Probe := K + 1;
      while Probe < Ops.Count do
      begin
        if Ops[Probe].Kind <> ' ' then
          Last := Probe
        else if Probe - Last > 2 * Context then
          Break;
        Inc(Probe);
      end;
      const From = Max(0, K - Context);
      const Upto = Min(Ops.Count - 1, Last + Context);
      if First then
      begin
        Writeln('--- ', FileName);
        Writeln('+++ after the rules');
        First := False;
      end;
      var CountA := 0;
      var CountB := 0;
      for var P := From to Upto do
      begin
        if Ops[P].Kind <> '+' then Inc(CountA);
        if Ops[P].Kind <> '-' then Inc(CountB);
      end;
      Writeln(Format('@@ -%s +%s @@', [Range(Ops[From].A, CountA), Range(Ops[From].B, CountB)]));
      for var P := From to Upto do
        case Ops[P].Kind of
          ' ': Writeln(' ', A[Ops[P].A]);
          '-': Writeln('-', A[Ops[P].A]);
          '+': Writeln('+', B[Ops[P].B]);
        end;
      K := Upto + 1;
    end;
  finally
    Ops.Free;
    Regions.Free;
  end;
end;

function Diff(const FileName: string; const Rules: TArray<TRule>): Integer;
begin
  Utf8Console;
  const Source = TFile.ReadAllBytes(FileName);
  var Rewritten: TBytes;
  var Edits: TArray<TEdit>;
  const Failed = Report(FileName, RunWithEdits(Source, Rules, FileName, Rewritten, Edits));
  ShowDiff(FileName, Source, Rewritten, Edits);
  Exit( IfThen(Failed, 1, 0) );
end;

{ The compile }

function Quoted(const S: string): string;
begin
  if S.Contains(' ') then
    Exit( '"' + S + '"' );
  Exit( S );
end;

// run a command line, its output and errors captured; its exit status
function Captured(const CommandLine: string; out Text: string): Cardinal;
begin
  var Security: TSecurityAttributes;
  Security.nLength := SizeOf(Security);
  Security.lpSecurityDescriptor := nil;
  Security.bInheritHandle := True;
  var ReadEnd, WriteEnd: THandle;
  if not CreatePipe(ReadEnd, WriteEnd, @Security, 0) then
    RaiseLastOSError;
  SetHandleInformation(ReadEnd, HANDLE_FLAG_INHERIT, 0);
  const Nul = CreateFile('NUL', GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, @Security,
                         OPEN_EXISTING, 0, 0);
  var Startup: TStartupInfo;
  FillChar(Startup, SizeOf(Startup), 0);
  Startup.cb := SizeOf(Startup);
  Startup.dwFlags := STARTF_USESTDHANDLES;
  Startup.hStdInput := Nul;
  Startup.hStdOutput := WriteEnd;
  Startup.hStdError := WriteEnd;
  var Process: TProcessInformation;
  var Command := CommandLine;
  UniqueString(Command);
  const Started = CreateProcess(nil, PChar(Command), nil, nil, True, CREATE_NO_WINDOW, nil, nil,
                                Startup, Process);
  const Why = GetLastError;
  CloseHandle(WriteEnd);
  CloseHandle(Nul);
  if not Started then
  begin
    CloseHandle(ReadEnd);
    raise Exception.CreateFmt('can''t run %s: %s', [CommandLine, SysErrorMessage(Why)]);
  end;
  var All := TBytesStream.Create;
  try
    var Buffer: array[0..4095] of Byte;
    var Got: DWORD;
    while ReadFile(ReadEnd, Buffer, SizeOf(Buffer), Got, nil) and (Got > 0) do
      All.WriteBuffer(Buffer, Got);
    WaitForSingleObject(Process.hProcess, INFINITE);
    GetExitCodeProcess(Process.hProcess, Result);
    Text := TEncoding.Default.GetString(All.Bytes, 0, All.Size);
  finally
    All.Free;
    CloseHandle(ReadEnd);
    CloseHandle(Process.hThread);
    CloseHandle(Process.hProcess);
  end;
end;

// run a program in this console, its input none; its exit status
function Ran(const Exe: string): Cardinal;
begin
  var Security: TSecurityAttributes;
  Security.nLength := SizeOf(Security);
  Security.lpSecurityDescriptor := nil;
  Security.bInheritHandle := True;
  const Nul = CreateFile('NUL', GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, @Security,
                         OPEN_EXISTING, 0, 0);
  var Startup: TStartupInfo;
  FillChar(Startup, SizeOf(Startup), 0);
  Startup.cb := SizeOf(Startup);
  Startup.dwFlags := STARTF_USESTDHANDLES;
  Startup.hStdInput := Nul;
  Startup.hStdOutput := GetStdHandle(STD_OUTPUT_HANDLE);
  Startup.hStdError := GetStdHandle(STD_ERROR_HANDLE);
  var Process: TProcessInformation;
  var Command := Quoted(Exe);
  UniqueString(Command);
  if not CreateProcess(nil, PChar(Command), nil, nil, True, 0, nil, nil, Startup, Process) then
  begin
    const Why = GetLastError;
    CloseHandle(Nul);
    raise Exception.CreateFmt('can''t run %s: %s', [Exe, SysErrorMessage(Why)]);
  end;
  CloseHandle(Nul);
  WaitForSingleObject(Process.hProcess, INFINITE);
  GetExitCodeProcess(Process.hProcess, Result);
  CloseHandle(Process.hThread);
  CloseHandle(Process.hProcess);
end;

// Short, as past about 127 characters of path dcc64's messages lose their line numbers: one
// folder for each folder of sources, so their compiled units are kept between builds
function OutFolder(const FileName: string; Win32: Boolean): string;
begin
  const Dir = ExtractFileDir(TPath.GetFullPath(FileName)).ToLower;
  Result := TPath.Combine(TPath.GetTempPath, 'dpp' + THashSHA1.GetHashString(Dir).Substring(0, 10));
  if Win32 then
    Result := TPath.Combine(Result, 'win32');     // its compiled units are its own
  ForceDirectories(Result);
end;

function Build(const FileName: string; const Rules: TArray<TRule>; Run, Win32: Boolean): Integer;
const
  // dcc's: FILE(12) Error: E2003 text
  Located = '^(.+?)\((\d+)\) (Hint|Warning|Error|Fatal): (.*)$';
begin
  Utf8Console;
  const Full = TPath.GetFullPath(FileName);
  const Source = TFile.ReadAllBytes(Full);
  var Rewritten: TBytes;
  var Edits: TArray<TEdit>;
  if Report(FileName, RunWithEdits(Source, Rules, Full, Rewritten, Edits)) then
    Exit( 1 );

  // the name dcc is given: X.dpr for a program, X.pas for a unit; a .dpps's as the IDE's
  // pre-build event writes it (user, 12 Nov: Hello.dpr copied to Hello.dpps, "not seeing the
  // same in task:spawn")
  const Folder = OutFolder(Full, Win32);
  var Name := ExtractFileName(Full);
  var Program_ := SameText(ExtractFileExt(Name), '.dpr');
  // the lines, not the name: past about 127 characters of path dcc64 cuts its messages short
  // ("TourBroken.dpr(6Error:"), so dcc names the short copy, and its messages are shown as
  // FileName's below
  var Text := WithLines(Source, Edits, '');
  const Low = Name.ToLower;
  if Low.EndsWith('.dpps') or Low.EndsWith('.dpps.pas') then
  begin
    var Latin1 := '';
    SetLength(Latin1, Length(Rewritten));
    for var I := 0 to High(Rewritten) do
      Latin1[I + 1] := Char(Rewritten[I]);
    Program_ := TRegEx.IsMatch(Latin1, '(?im)^\s*(program|library)\b');
    var Stem := Name.Substring(0, Name.Length - IfThen(Low.EndsWith('.dpps.pas'), 9, 5));
    Name := Stem + IfThen(Program_, '.dpr', '.pas');
    Text := Unsuffixed(Text);
  end;
  const Target = TPath.Combine(Folder, Name);
  TFile.WriteAllBytes(Target, Text);

  const Compiler = IfThen(Win32, 'dcc32', 'dcc64');
  const SourceDir = ExtractFileDir(Full);
  var Said: string;
  var Status: Cardinal;
  try
    Status := Captured(string.Join(' ', [Compiler, '-Q', Quoted('-E' + Folder), Quoted('-NU' + Folder),
                                         '-NSSystem;Winapi', Quoted('-U' + SourceDir),
                                         Quoted('-I' + SourceDir), Quoted(Target)]), Said);
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.Message);
      Writeln(ErrOutput, Compiler, ' isn''t on the PATH: RAD Studio''s bin folder must be');
      Exit( 1 );
    end;
  end;
  // dcc's located messages, and its errors that name no line; its banner and counts left out
  for var Line in Said.Split([#10]) do
  begin
    const S = Line.Trim;
    const M = TRegEx.Match(S, Located);
    if M.Success then
    begin
      // a {$LINE} names FileName already; a message on the copy (no {$LINE}: a name it can't
      // hold) is on FileName's line too, so it is shown as FileName's
      var Where := M.Groups[1].Value;
      if SameText(ExtractFileName(Where), Name) and SameText(ExtractFileDir(Where), Folder) then
        Where := FileName;
      Writeln(Format('%s(%s) %s: %s', [Where, M.Groups[2].Value, M.Groups[3].Value, M.Groups[4].Value]));
    end
    else if S.Contains('Fatal:') or S.Contains('Error:') then
      Writeln(S);
  end;
  if Status <> 0 then
  begin
    Writeln(ErrOutput, Compiler, ' refused it');
    Exit( 1 );
  end;
  Writeln('compiled: ', Target);
  if Run and Program_ then
  begin
    Flush(Output);      // ours first, then the program's
    Exit( Integer(Ran(ChangeFileExt(Target, '.exe'))) );
  end;
  Exit( 0 );
end;

end.
