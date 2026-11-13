program delphipp;

{ The command line, as the Python side's python -m delphipp.

    delphipp FILE_OR_FOLDER...            report what the rules find
    delphipp -o OUT FILE_OR_FOLDER...     also write each file, rewritten, under OUT
    delphipp --rules with ...             only the rules named (comma-separated)
    delphipp --list                       the rules there are
    delphipp --tree FILE                  the file's tree: the kinds of node a rule can ask for
    delphipp X.dpps                       write X.pas beside it, rewritten
    delphipp X.dpps.pas                   the same, from a source the IDE highlights
    delphipp --msbuild ...                messages as MSBuild reads them, for the IDE
    delphipp --lsp                        a language server on stdin and stdout, for Zed
    delphipp --build FILE [--run] [--win32]   rewrite FILE in a folder of its own, compile it
                                          with dcc64 (dcc32), and run the program
    delphipp --diff FILE                  what the rules change in FILE, as a diff

  Exit status 1 when a rule reports an error.

  A .dpps file is Delphi source the rules rewrite before dcc sees it: the .pas beside it is
  written from it, so a project's pre-build event can run this and the IDE builds the .pas as
  usual (..\examples\ide\). Its header may name it `unit X.dpps;`; X.pas is written with
  `unit X;`, and with dcc's $LINE directives, so dcc's own messages name X.dpps and its lines.
  With --msbuild, an error or warning is `file(line,col): warning DPPS-rule: text`, which
  MSBuild's Exec, and so the IDE's Messages pane, lists; a hint is printed plain. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.IOUtils, System.Types, System.Generics.Collections,
  System.RegularExpressions,
  DelphiPP.Engine,
  DelphiPP.Build,
  DelphiPP.Lsp,
  DelphiPP.Rules;     // the rules: dcc finds their units here, beside this file

function IsDelphi(const Path: string): Boolean;
begin
  const Ext = ExtractFileExt(Path).ToLower;
  Exit( (Ext = '.pas') or (Ext = '.dpr') or (Ext = '.dpk') or (Ext = '.inc') or (Ext = '.dpps') );
end;

// The name of the .pas a source is written to: X.pas for X.dpps or X.dpps.pas, else ''
function Generated(const Path: string): string;
const
  Suffixes: TArray<string> = ['.dpps.pas', '.dpps'];
begin
  const Name = ExtractFileName(Path);
  for var Suffix in Suffixes do
    if Name.ToLower.EndsWith(Suffix) then
      Exit( Name.Substring(0, Name.Length - Suffix.Length) + '.pas' );
  Exit( '' );
end;

// A message as a line: ours, or MSBuild's canonical form (its Exec reads `error` and `warning`;
// a hint has no category there, so it stays ours)
function Shown(const F: string; const M: TMessage; MSBuild: Boolean): string;
begin
  if MSBuild and ((M.Level = 'error') or (M.Level = 'warning')) then
    Exit( Format('%s(%d,%d): %s DPPS-%s: %s', [TPath.GetFullPath(F), M.Line, M.Col, M.Level, M.Rule, M.Text]) );
  // the path with Windows' separators, as the Python side prints it
  Exit( F.Replace('/', '\') + ':' + M.ToString );
end;

function SameBytes(const A, B: TBytes): Boolean;
begin
  Exit( (Length(A) = Length(B)) and CompareMem(Pointer(A), Pointer(B), Length(A)) );
end;

var
  Paths   : TArray<string>;
  OutDir  : string;
  Names   : string;
  List    : Boolean;
  TreeOf  : string;
  MSBuild : Boolean;
  Compile : Boolean;
  RunIt   : Boolean;
  Win32   : Boolean;
  Diffs   : Boolean;

begin
  MSBuild := False; Compile := False; RunIt := False; Win32 := False; Diffs := False;
  try
    var I := 1;
    while I <= ParamCount do
    begin
      const A = ParamStr(I);
      if (A = '-o') or (A = '--out') then begin Inc(I); OutDir := ParamStr(I); end
      else if A = '--rules' then begin Inc(I); Names := ParamStr(I); end
      else if A = '--list' then List := True
      else if A = '--tree' then begin Inc(I); TreeOf := ParamStr(I); end
      else if A = '--msbuild' then MSBuild := True
      else if A = '--build' then Compile := True
      else if A = '--run' then RunIt := True
      else if A = '--win32' then Win32 := True
      else if A = '--diff' then Diffs := True
      else if A = '--lsp' then
      begin
        // the editor's: nothing else from the command line applies
        Serve;
        Exit;
      end
      else Paths := Paths + [A];
      Inc(I);
    end;

    if TreeOf <> '' then
    begin
      Write(TreeText(TFile.ReadAllBytes(TreeOf)));
      Exit;
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
      if Compile or Diffs then
      begin
        if Length(Paths) <> 1 then
          raise Exception.Create('--build and --diff take one file');
        if Compile then
          ExitCode := Build(Paths[0], Rules, RunIt, Win32)
        else
          ExitCode := Diff(Paths[0], Rules);
        Exit;
      end;

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
          var Edits: TArray<TEdit>;
          var Failed := False;
          for var M in RunWithEdits(Source, Rules, F, Output, Edits) do
          begin
            Writeln(Shown(F, M, MSBuild));
            if M.Level = 'error' then
            begin
              Inc(Errors);
              Failed := True;
            end;
          end;
          if not SameBytes(Output, Source) then
            Inc(Changed);
          const Name = Generated(F);
          if Name <> '' then
          begin
            // a rule's error: no .pas, the last good one stays, so nothing half rewritten is
            // left for the IDE to open or Code Insight to read (the user, 6 Nov, found one)
            if not Failed then
            begin
              // its .pas, beside it or under OUT, written only when it differs, so the IDE
              // doesn't see a change on disk where there is none. Its {$LINE}s put dcc's
              // messages on this file and its lines, where the rules moved them
              const Pas = Unsuffixed(WithLines(Source, Edits, TPath.GetFullPath(F)));
              var Dir := OutDir;
              if Dir = '' then
                Dir := ExtractFilePath(TPath.GetFullPath(F));
              ForceDirectories(Dir);
              const Dest = TPath.Combine(Dir, Name);
              if not TFile.Exists(Dest) or not SameBytes(TFile.ReadAllBytes(Dest), Pas) then
                TFile.WriteAllBytes(Dest, Pas);
            end;
          end
          else if OutDir <> '' then
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
