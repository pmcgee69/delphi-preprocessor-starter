program delphipp;

{ The command line, as the Python side's python -m delphipp.

    delphipp FILE_OR_FOLDER...            report what the rules find
    delphipp -o OUT FILE_OR_FOLDER...     also write each file, rewritten, under OUT
    delphipp --rules with ...             only the rules named (comma-separated)
    delphipp --list                       the rules there are

  Exit status 1 when a rule reports an error. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.IOUtils, System.Types, System.Generics.Collections,
  DelphiPP.Engine in 'DelphiPP.Engine.pas',
  DelphiPP.Rules in 'DelphiPP.Rules.pas',
  DelphiPP.Rule.WithStatement in 'DelphiPP.Rule.WithStatement.pas',
  DelphiPP.Rule.AssertMessage in 'DelphiPP.Rule.AssertMessage.pas';

function IsDelphi(const Path: string): Boolean;
begin
  const Ext = ExtractFileExt(Path).ToLower;
  Exit( (Ext = '.pas') or (Ext = '.dpr') or (Ext = '.dpk') or (Ext = '.inc') );
end;

var
  Paths   : TArray<string>;
  OutDir  : string;
  Names   : string;
  List    : Boolean;

begin
  try
    var I := 1;
    while I <= ParamCount do
    begin
      const A = ParamStr(I);
      if (A = '-o') or (A = '--out') then begin Inc(I); OutDir := ParamStr(I); end
      else if A = '--rules' then begin Inc(I); Names := ParamStr(I); end
      else if A = '--list' then List := True
      else Paths := Paths + [A];
      Inc(I);
    end;

    const Rules = RulesNamed(Names);
    try
      if List then
      begin
        for var R in Rules do
          Writeln(R.Name.PadRight(16), ' ', R.Description);
        Exit;
      end;
      if Length(Paths) = 0 then
        raise Exception.Create('give a file or a folder (or --list)');

      var Files, Errors, Changed: Integer;
      Files := 0; Errors := 0; Changed := 0;
      for var P in Paths do
      begin
        var Found: TArray<string>;
        var Root := ExtractFilePath(P);
        if TDirectory.Exists(P) then
        begin
          Root := IncludeTrailingPathDelimiter(P);
          for var F in TDirectory.GetFiles(P, '*', TSearchOption.soAllDirectories) do
            if IsDelphi(F) then
              Found := Found + [F];
          TArray.Sort<string>(Found);
        end
        else
          Found := [P];
        for var F in Found do
        begin
          Inc(Files);
          const Source = TFile.ReadAllBytes(F);
          var Output: TBytes;
          for var M in Run(Source, Rules, F, Output) do
          begin
            // the path with Windows' separators, as the Python side prints it
            Writeln(F.Replace('/', '\'), ':', M.ToString);
            if M.Level = 'error' then
              Inc(Errors);
          end;
          if (Length(Output) <> Length(Source)) or not CompareMem(Pointer(Output), Pointer(Source), Length(Source)) then
            Inc(Changed);
          if OutDir <> '' then
          begin
            const Dest = TPath.Combine(OutDir, ExtractRelativePath(Root, F));
            ForceDirectories(ExtractFilePath(Dest));
            TFile.WriteAllBytes(Dest, Output);
          end;
        end;
      end;
      Writeln(ErrOutput, Format('%d files, %d changed, %d errors', [Files, Changed, Errors]));
      if Errors > 0 then
        ExitCode := 1;
    finally
      for var R in Rules do
        R.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, 'delphipp: ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
