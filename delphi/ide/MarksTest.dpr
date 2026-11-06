program MarksTest;

{ What the IDE package would show of a file, as text: each line with a mark,
  the stretches underlined beneath it (. a rule changes this, ^ adds text here,
  ~ a message), and
  the messages after it. The package's TAnalysis, without the IDE.

    MarksTest FILE
    MarksTest FILE LINE COL     what the mouse there would show
    MarksTest --tabs=STOPS ...  with the editor's tab stops, as '2' or '9 17' (default 8):
                                lines are printed with their tabs as spaces }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.IOUtils,
  DelphiPP.Marks;

begin
  try
    var Args: TArray<string>;
    var Tabs := '';
    for var I := 1 to ParamCount do
      if ParamStr(I).StartsWith('--tabs=') then
        Tabs := ParamStr(I).Substring(7)
      else
        Args := Args + [ParamStr(I)];
    const Text  = TFile.ReadAllBytes(Args[0]);
    const Lines = TEncoding.UTF8.GetString(Text).Split([#10]);
    const A = TAnalysis.Create(Text, Args[0], Tabs);
    try
      if Length(Args) >= 3 then
      begin
        Writeln(A.HoverAt(Args[1].ToInteger, Args[2].ToInteger));
        Exit;
      end;
      for var L := 1 to Length(Lines) do
      begin
        var Spans: TArray<TSpan>;
        var Notes: TArray<TNote>;
        A.Spans.TryGetValue(L, Spans);
        A.Notes.TryGetValue(L, Notes);
        if (Spans = nil) and (Notes = nil) then
          Continue;
        const Line = A.Expand(Lines[L - 1].TrimRight);
        Writeln(Format('%4d  %s', [L, Line]));
        var Under := StringOfChar(' ', Length(Line) + 1);
        for var S in Spans do
          for var C := S.Col1 to S.Col2 - 1 do
          begin
            while Length(Under) < C do
              Under := Under + ' ';
            Under[C] := if S.Mark = mkEdit then '.' else if S.Mark = mkInsert then '^' else '~';
          end;
        Writeln('      ', Under.TrimRight);
        for var N in Notes do
          Writeln('      -> ', N.Text);
      end;
    finally
      A.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, 'MarksTest: ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
