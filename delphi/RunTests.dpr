program RunTests;

{ The tests, the same ones as the Python side's: ..\tests\cases\<rule>\<name>.pas
  run through that rule alone.

    <name>.pas        the input
    <name>.out.pas    the output expected, when the rule changes the file
                      (none: the output must be the input, byte for byte)
    <name>.diag       the messages expected (none: no messages)

    RunTests [CASES FOLDER] [--update]

  With no folder, the repository's tests\cases, found up from the exe.
  --update writes the expected files from what the rules do now (then read the
  diff!). A rule in both languages must pass in both. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.IOUtils, System.Types, System.Generics.Collections,
  DelphiPP.Engine in 'DelphiPP.Engine.pas',
  DelphiPP.Rules in 'DelphiPP.Rules.pas',
  DelphiPP.Rule.WithStatement in 'DelphiPP.Rule.WithStatement.pas',
  DelphiPP.Rule.AssertMessage in 'DelphiPP.Rule.AssertMessage.pas';

function Same(const A, B: TBytes): Boolean;
begin
  Exit( (Length(A) = Length(B)) and CompareMem(Pointer(A), Pointer(B), Length(A)) );
end;

var
  Cases  : string;
  Update : Boolean;

begin
  // the repository's tests\cases: up from the exe (delphi\bin, or delphi\bin\win32)
  var Dir := ExcludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  while (Dir <> '') and not TDirectory.Exists(TPath.Combine(Dir, 'tests\cases')) and
        (ExtractFileDir(Dir) <> Dir) do
    Dir := ExtractFileDir(Dir);
  Cases  := TPath.Combine(Dir, 'tests\cases');
  Update := False;
  for var I := 1 to ParamCount do
    if ParamStr(I) = '--update' then Update := True
    else Cases := ParamStr(I);

  var Total, Failed: Integer;
  Total := 0; Failed := 0;
  var Folders := TDirectory.GetDirectories(Cases);
  TArray.Sort<string>(Folders);
  for var Folder in Folders do
  begin
    const Rules = RulesNamed(ExtractFileName(Folder));
    try
      var Inputs := TDirectory.GetFiles(Folder, '*.pas');
      TArray.Sort<string>(Inputs);
      for var F in Inputs do
      begin
        if F.EndsWith('.out.pas', True) then
          Continue;
        Inc(Total);
        const Source = TFile.ReadAllBytes(F);
        var Output: TBytes;
        var Diag := '';
        for var M in Run(Source, Rules, F, Output) do
          Diag := Diag + M.ToString + #10;
        const OutFile  = ChangeFileExt(F, '.out.pas');
        const DiagFile = ChangeFileExt(F, '.diag');
        if Update then
        begin
          if not Same(Output, Source) then TFile.WriteAllBytes(OutFile, Output)
          else if TFile.Exists(OutFile) then TFile.Delete(OutFile);
          if Diag <> '' then TFile.WriteAllBytes(DiagFile, TEncoding.UTF8.GetBytes(Diag))
          else if TFile.Exists(DiagFile) then TFile.Delete(DiagFile);
        end;
        var Expected := Source;
        if TFile.Exists(OutFile) then
          Expected := TFile.ReadAllBytes(OutFile);
        var ExpectedDiag := '';
        if TFile.Exists(DiagFile) then
          ExpectedDiag := TEncoding.UTF8.GetString(TFile.ReadAllBytes(DiagFile));
        var Problems := '';
        if not Same(Output, Expected) then
          Problems := Problems + #13#10'      the output differs from ' +
            (if TFile.Exists(OutFile) then ExtractFileName(OutFile) else 'the input');
        if Diag <> ExpectedDiag then
          Problems := Problems + #13#10'      the messages differ from ' +
            (if TFile.Exists(DiagFile) then ExtractFileName(DiagFile) else 'none');
        if Problems <> '' then
          Inc(Failed);
        Writeln((if Problems = '' then 'ok  ' else 'FAIL'), '  ',
                ExtractFileName(Folder), '/', ExtractFileName(F), Problems);
      end;
    finally
      for var R in Rules do
        R.Free;
    end;
  end;
  if Failed = 0 then
    Writeln('all passed')
  else
  begin
    Writeln(Failed, ' of ', Total, ' failed');
    ExitCode := 1;
  end;
end.
