program NavSweep;

{ DelphiPP.Impl, the index behind go to definition, implementation and find references (in Zed
  and in the IDE), over a repository as an editor would ask it: Go to Definition and Go to
  Implementation on identifiers spread through its units, Find References on a tenth of them.
  Counts answers and failures, and times each kind. Run over the user's corpus of 42 Delphi
  repositories (21 Nov), no failures; it found the slow references fixed then.

    bin\NavSweep.exe <folder> [identifiers, default 300] [every reference answer, into this file]

  One line out: repo, units, index seconds, then per kind: asked, answered, failed, mean ms,
  max ms (and where). }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Diagnostics, System.Generics.Collections,
  System.Math, TreeSitter.Api, DelphiPP.Impl;

type
  TSpot = record
    Path: string;
    Line, Ch: Integer;
  end;

var
  Dump: TStringList;

type
  TKind = record
    Asked, Answered, Failed: Integer;
    Total, Max: Double;
    MaxAt: string;
    procedure Add(Ms: Double; Got: Boolean; const At: string);
  end;

procedure TKind.Add(Ms: Double; Got: Boolean; const At: string);
begin
  Inc(Asked);
  if Got then
    Inc(Answered);
  Total := Total + Ms;
  if Ms > Max then
  begin
    Max := Ms;
    MaxAt := At;
  end;
end;

function Report(const Name: string; const K: TKind): string;
begin
  Result := Format('%s %d/%d', [Name, K.Answered, K.Asked]);
  if K.Failed > 0 then
    Result := Result + Format(' FAILED %d', [K.Failed]);
  if K.Asked > 0 then
    Result := Result + Format(' mean %.0f max %.0f ms (%s)', [K.Total / K.Asked, K.Max, K.MaxAt]);
end;

// every identifier in a file: its line and UTF-16 column, from 0
procedure Spots(const Path: string; Into: TList<TSpot>);
begin
  const Text = TFile.ReadAllText(Path);
  const Src = TEncoding.UTF8.GetBytes(Text);
  const Lines = Text.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
  const P = ts_parser_new;
  try
    ts_parser_set_language(P, tree_sitter_delphi13);
    const T = ts_parser_parse_string(P, nil, PByte(Src), Length(Src));
    try
      var Stack := TStack<TSNode>.Create;
      try
        Stack.Push(ts_tree_root_node(T));
        while Stack.Count > 0 do
        begin
          const N = Stack.Pop;
          const C = ts_node_child_count(N);
          if C = 0 then
          begin
            if string(AnsiString(ts_node_type(N))) = 'identifier' then
            begin
              const Pt = ts_node_start_point(N);
              if Integer(Pt.Row) <= High(Lines) then
              begin
                const LB = TEncoding.UTF8.GetBytes(Lines[Pt.Row]);
                var S: TSpot;
                S.Path := Path;
                S.Line := Pt.Row;
                S.Ch := Length(TEncoding.UTF8.GetString(LB, 0, Min(Integer(Pt.Column), Length(LB))));
                Into.Add(S);
              end;
            end;
          end
          else
            for var I := C - 1 downto 0 do
              Stack.Push(ts_node_child(N, I));
        end;
      finally
        Stack.Free;
      end;
    finally
      ts_tree_delete(T);
    end;
  finally
    ts_parser_delete(P);
  end;
end;

begin
  try
    const Root = ExcludeTrailingPathDelimiter(ParamStr(1));
    const Want = StrToIntDef(ParamStr(2), 300);
    // a third argument: every reference answer, one line per site, into that file
    Dump := nil;
    if ParamStr(3) <> '' then
      Dump := TStringList.Create;
    var W := TStopwatch.StartNew;
    IndexFolder(Root);
    var Dummy := Definitions('', '', 0, 0, 600000);  // waits for the index
    const IndexS = W.Elapsed.TotalSeconds;
    const Units = IndexedCount;
    var Files := TDirectory.GetFiles(Root, '*.pas', TSearchOption.soAllDirectories);
    TArray.Sort<string>(Files);
    // the same files each run: every k-th, then each one's identifiers, every m-th
    const All = TList<TSpot>.Create;
    try
      const Step = System.Math.Max(1, Length(Files) div 60);
      var I := 0;
      while I < Length(Files) do
      begin
        try
          Spots(Files[I], All);
        except
        end;
        Inc(I, Step);
      end;
      var Defs, Impls, Refs: TKind;
      Defs := Default(TKind); Impls := Default(TKind); Refs := Default(TKind);
      const Every = System.Math.Max(1, All.Count div Want);
      var J := 0;
      var N := 0;
      while J < All.Count do
      begin
        const S = All[J];
        var Text: string;
        try
          Text := TFile.ReadAllText(S.Path);
        except
          Inc(J, Every);
          Continue;
        end;
        const At = Format('%s:%d', [ExtractFileName(S.Path), S.Line + 1]);
        var Q: TStopwatch;
        try
          Q := TStopwatch.StartNew;
          const D = Definitions(S.Path, Text, S.Line, S.Ch, 600000);
          Defs.Add(Q.Elapsed.TotalMilliseconds, D <> nil, At);
        except
          Inc(Defs.Failed);
        end;
        try
          Q := TStopwatch.StartNew;
          const M = Implementations(S.Path, Text, S.Line, S.Ch, 600000);
          Impls.Add(Q.Elapsed.TotalMilliseconds, M <> nil, At);
        except
          Inc(Impls.Failed);
        end;
        if N mod 10 = 0 then
        try
          Q := TStopwatch.StartNew;
          const R = References(S.Path, Text, S.Line, S.Ch, True, nil, 600000);
          Refs.Add(Q.Elapsed.TotalMilliseconds, R <> nil, At);
          if Dump <> nil then
          begin
            var Lines: TArray<string> := nil;
            for var X in R do
              Lines := Lines + [Format('%s:%d:%d', [X.Path, X.Line, X.Col])];
            TArray.Sort<string>(Lines);
            Dump.Add(Format('%s:%d:%d  %d  %s', [S.Path, S.Line, S.Ch, Length(R), string.Join(' ', Lines)]));
          end;
        except
          Inc(Refs.Failed);
        end;
        Inc(N);
        Inc(J, Every);
      end;
      Writeln(Format('%s | %d units, index %.1f s | %s | %s | %s',
        [ExtractFileName(Root), Units, IndexS, Report('def', Defs), Report('impl', Impls), Report('refs', Refs)]));
      if Dump <> nil then
        Dump.SaveToFile(ParamStr(3), TEncoding.UTF8);
    finally
      All.Free;
    end;
  except
    on E: Exception do
      Writeln(ExtractFileName(ParamStr(1)), ' | CRASH ', E.ClassName, ': ', E.Message);
  end;
end.
