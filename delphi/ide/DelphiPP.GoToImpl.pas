unit DelphiPP.GoToImpl;

{ Go to implementation in the Delphi IDE's editor: on a call through an interface,
  `x.DoSomething()`, each class's method that implements it, as Zed has it through
  delphipp's language server (..\DelphiPP.Impl.pas, the same index). Ctrl+click goes
  to the interface; Ctrl+Alt+click on the method's name, or Go to Implementation on
  the editor's right-click menu (after Find Declaration), goes to the class: straight
  there when there is one, a menu to choose from when there are more. Wished for by
  a Delphi developer, passed on by the user (20 Nov): "In delphi it's so much harder
  to navigate to the implementation of an interface, and it's one of the reasons
  people don't use them as much as they could/should."

  The index is the active project's: the .pas files in its folder and below, and
  those in each folder of its search path (the active configuration and platform's),
  read in the background when the editor is first clicked in, and again when the
  project or its search path changes. Any file, in any editor: the open file's own
  text is read as the editor has it. Nothing here may raise into the editor. }

interface

procedure Register;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Types, System.Math, System.IOUtils,
  Vcl.Controls, Vcl.Menus, Vcl.ActnList, Vcl.Forms,
  ToolsAPI, ToolsAPI.Editor, DCCStrs,
  DelphiPP.Impl;

const
  MenuCategory = 'DelphiPP.GoToImplementation';

type
  TAskKind = (akImplementation, akDeclaration);

  TGoToImpl = class(TNTACodeEditorNotifier)
  private
    FMenu    : TPopupMenu;
    FActions : TActionList;
    FTargets : TArray<TImplTarget>;
    FIndexKey: string;                // what the index was built from: the project and its path
    FTaken   : Boolean;               // a Ctrl+Alt mouse-down taken: its mouse-up too
    procedure OnMouseDown(const Editor: TWinControl; Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer; var Handled: Boolean);
    procedure OnMouseUp(const Editor: TWinControl; Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer; var Handled: Boolean);
    procedure OnExecute(Sender: TObject);
    procedure OnFindDeclaration(Sender: TObject);
    procedure OnUpdate(Sender: TObject);
    procedure OnItem(Sender: TObject);
    procedure EnsureIndex(const FileName: string);
    procedure Ask(const View: IOTAEditView; Pos: TOTAEditPos; const At: TPoint; Kind: TAskKind);
    procedure ShowMenu(const At: TPoint; const Notes: TArray<string>);
  protected
    function AllowedEvents: TCodeEditorEvents; override;
  public
    constructor Create;
    destructor Destroy; override;
  end;

var
  Notifier: TGoToImpl;
  NotifierIndex: Integer = -1;
  MenuAdded: Boolean;

// the buffer's text: the editor gives it as UTF-8
function BufferText(const Buffer: IOTAEditBuffer): TBytes;
const
  Chunk = 64 * 1024;
begin
  var Reader := Buffer.CreateReader;
  var Pos    := 0;
  repeat
    SetLength(Result, Pos + Chunk);
    var Got := Reader.GetText(Pos, PAnsiChar(@Result[Pos]), Chunk);
    Inc(Pos, Got);
    SetLength(Result, Pos);
    if Got < Chunk then
      Break;
  until False;
end;

// a search path entry's $(Platform), $(Config) and environment variables ($(BDS) ...);
// '' when one can't be expanded: the entry is left out
function Expand(const S, Plat, Conf: string): string;
begin
  Result := S;
  var I := Result.IndexOf('$(');
  while I >= 0 do
  begin
    const J = Result.IndexOf(')', I);
    if J < 0 then
      Exit( '' );
    const Name = Result.Substring(I + 2, J - I - 2);
    var V: string;
    if SameText(Name, 'Platform') then
      V := Plat
    else if SameText(Name, 'Config') then
      V := Conf
    else
      V := GetEnvironmentVariable(Name);
    if V = '' then
      Exit( '' );
    Result := Result.Remove(I, J - I + 1).Insert(I, V);
    I := Result.IndexOf('$(', I + Length(V));
  end;
end;

// each folder of a search path (';' between), relative ones from Dir, macros expanded
function PathFolders(const Search, Dir, Plat, Conf: string): TArray<string>;
begin
  Result := nil;
  for var E in Search.Split([';']) do
  begin
    var S := Expand(E.Trim, Plat, Conf);
    if S = '' then
      Continue;
    try
      if TPath.IsRelativePath(S) then
        S := TPath.Combine(Dir, S);
      Result := Result + [ExcludeTrailingPathDelimiter(TPath.GetFullPath(S))];
    except
      // not a path
    end;
  end;
end;

// the repository a file is in: the nearest folder above it with .git (or .hg, .svn); else the
// file's own folder. A unit opened on its own, with no project (user, 20 Nov: Spring4D's
// Spring.Container.Builder.pas in Delphi 13, "No implementation found (16 units read)": its
// folder alone, not Spring.Collections, where IList<T> is)
function RepoRoot(const FileName: string): string;
begin
  Result := ExtractFileDir(FileName);
  var D := Result;
  for var I := 1 to 32 do
  begin
    if DirectoryExists(TPath.Combine(D, '.git')) or FileExists(TPath.Combine(D, '.git')) or
       DirectoryExists(TPath.Combine(D, '.hg')) or DirectoryExists(TPath.Combine(D, '.svn')) then
      Exit( D );
    const Up = ExtractFileDir(D);
    if (Up = '') or (Up = D) then
      Break;
    D := Up;
  end;
end;

// the IDE's library path for a platform (Tools > Options > Language > Delphi > Library): where a
// library installed for every project is, as Spring4D often is
function LibraryPath(const Plat: string): string;
begin
  Result := '';
  try
    const Base = (BorlandIDEServices as IOTAServices).GetBaseRegistryKey;
    var Key: HKEY;
    if RegOpenKeyEx(HKEY_CURRENT_USER, PChar(Base + '\Library\' + Plat), 0, KEY_READ, Key) <> ERROR_SUCCESS then
      Exit;
    try
      var Size: DWORD := 0;
      var Kind: DWORD := 0;
      if (RegQueryValueEx(Key, 'Search Path', nil, @Kind, nil, @Size) = ERROR_SUCCESS) and (Size > 0) then
      begin
        SetLength(Result, Size div SizeOf(Char));
        if RegQueryValueEx(Key, 'Search Path', nil, @Kind, PByte(PChar(Result)), @Size) = ERROR_SUCCESS then
          Result := PChar(Result)
        else
          Result := '';
      end;
    finally
      RegCloseKey(Key);
    end;
  except
    Result := '';
  end;
end;

// what to index for a file: the active project's folder and the file's repository, with their
// subfolders (Deep); the project's search path and the IDE's library path (Flat). The key: what
// it was built from, to read it again when that changes
function IndexScope(const FileName: string; out Deep, Flat: TArray<string>): string;
begin
  Deep := [RepoRoot(FileName)];
  Flat := nil;
  var Plat := {$IFDEF WIN64} 'Win64' {$ELSE} 'Win32' {$ENDIF};
  var Conf := 'Debug';
  const Project = GetActiveProject;
  if Project <> nil then
  begin
    const Dir = ExtractFilePath(Project.FileName);
    if not SameText(ExcludeTrailingPathDelimiter(Dir), Deep[0]) then
      Deep := Deep + [Dir];
    var Search := '';
    try
      const Configs = Project.ProjectOptions as IOTAProjectOptionsConfigurations;
      if Configs.ActivePlatformName <> '' then
        Plat := Configs.ActivePlatformName;
      Conf := Configs.ActiveConfigurationName;
      var C := Configs.ActiveConfiguration;
      if (C <> nil) and (C.PlatformConfiguration[Plat] <> nil) then
        C := C.PlatformConfiguration[Plat];
      if C <> nil then
        Search := C.GetValue(sUnitSearchPath, True);
    except
      // the folders alone
    end;
    Flat := PathFolders(Search, Dir, Plat, Conf);
  end;
  Flat := Flat + PathFolders(LibraryPath(Plat), ExtractFilePath(FileName), Plat, Conf);
  Result := string.Join(';', Deep) + '|' + string.Join(';', Flat);
end;

procedure GoToTarget(const T: TImplTarget);
begin
  if not (BorlandIDEServices as IOTAActionServices).OpenFile(T.Path) then
    Exit;
  const View = (BorlandIDEServices as IOTAEditorServices).TopView;
  if View = nil then
    Exit;
  var P: TOTAEditPos;
  P.Col  := T.Col + 1;
  P.Line := T.Line;
  View.CursorPos := P;
  View.Center(T.Line, P.Col);
  View.Paint;
end;

{ TGoToImpl }

constructor TGoToImpl.Create;
begin
  inherited Create;
  FMenu    := TPopupMenu.Create(nil);
  FActions := TActionList.Create(nil);
  FMenu.AutoHotkeys := maManual;      // no underlined letters added (user, 20 Nov, the first menu)
  const A  = TAction.Create(FActions);
  A.ActionList := FActions;
  A.Caption    := 'Go to Implementation';
  A.Hint       := 'The classes'' methods that implement this interface method (Ctrl+Alt+click)';
  A.Category   := MenuCategory;
  A.OnExecute  := OnExecute;
  A.OnUpdate   := OnUpdate;
  // the IDE's own Find Declaration needs the project to know where each unit is (user, 20 Nov:
  // "i think you are being generous to think the ide will find declaration")
  const D  = TAction.Create(FActions);
  D.ActionList := FActions;
  D.Caption    := 'Find Declaration (delphipp)';
  D.Hint       := 'Where this name is declared, from delphipp''s index';
  D.Category   := MenuCategory;
  D.OnExecute  := OnFindDeclaration;
  D.OnUpdate   := OnUpdate;
  OnEditorMouseDownEx := OnMouseDown;
  OnEditorMouseUpEx   := OnMouseUp;
end;

destructor TGoToImpl.Destroy;
begin
  FActions.Free;
  FMenu.Free;
  inherited;
end;

function TGoToImpl.AllowedEvents: TCodeEditorEvents;
begin
  Exit( [cevMouseEvents] );
end;

procedure TGoToImpl.EnsureIndex(const FileName: string);
begin
  if FileName = '' then
    Exit;
  var Deep, Flat: TArray<string>;
  const Key = IndexScope(FileName, Deep, Flat);
  if Key = FIndexKey then
    Exit;
  FIndexKey := Key;
  IndexFolders(Deep, Flat);
end;

procedure TGoToImpl.Ask(const View: IOTAEditView; Pos: TOTAEditPos; const At: TPoint; Kind: TAskKind);
begin
  FTargets := nil;
  if (View = nil) or (View.Buffer = nil) then
    Exit;
  const FileName = View.Buffer.FileName;
  EnsureIndex(FileName);
  const Text = TEncoding.UTF8.GetString(BufferText(View.Buffer));
  // the editor's column (tabs expanded) as a character of the line
  var CP: TOTACharPos;
  View.ConvertPos(True, Pos, CP);
  const Lines = Text.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
  if (CP.Line < 1) or (CP.Line > Length(Lines)) then
    Exit;
  const LineBytes = TEncoding.UTF8.GetBytes(Lines[CP.Line - 1]);
  const Ch = Length(TEncoding.UTF8.GetString(LineBytes, 0, Min(Max(CP.CharIndex, 0), Length(LineBytes))));
  var Notes: TArray<string> := nil;
  const Was = Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    // the first time, the index is still being read: a second or so for Spring4D's 367 units
    if Kind = akDeclaration then
    begin
      FTargets := Definitions(FileName, Text, CP.Line - 1, Ch, 20000);
      if FTargets = nil then
        Notes := [Format('No declaration found (%d units read)', [IndexedCount])];
    end
    else
    begin
      FTargets := Implementations(FileName, Text, CP.Line - 1, Ch, 20000);
      if FTargets = nil then
      begin
        // not a method called through an interface, or none implements it: its declaration
        FTargets := Definitions(FileName, Text, CP.Line - 1, Ch, 0);
        Notes := [Format('No implementation found (%d units read)', [IndexedCount])];
        if FTargets <> nil then
          Notes := Notes + ['Its declaration:'];
      end;
    end;
  finally
    Screen.Cursor := Was;
  end;
  if (Length(FTargets) = 1) and (Notes = nil) then
    GoToTarget(FTargets[0])
  else
    ShowMenu(At, Notes);
end;

procedure TGoToImpl.ShowMenu(const At: TPoint; const Notes: TArray<string>);
begin
  FMenu.Items.Clear;
  // a note is an item that does nothing: enabled, so it reads as text, not greyed (user, 20 Nov:
  // "text could be white")
  for var S in Notes do
  begin
    const Item = TMenuItem.Create(FMenu);
    Item.Caption := S.Replace('&', '&&');
    Item.Tag     := -1;
    FMenu.Items.Add(Item);
  end;
  for var I := 0 to High(FTargets) do
    begin
      const Item = TMenuItem.Create(FMenu);
      // after a tab, right-aligned as a shortcut is
      Item.Caption := FTargets[I].Name.Replace('&', '&&') + #9 +
                      ExtractFileName(FTargets[I].Path) + ' ' + IntToStr(FTargets[I].Line);
      Item.Tag     := I;
      Item.OnClick := OnItem;
      FMenu.Items.Add(Item);
    end;
  FMenu.Popup(At.X, At.Y);
end;

procedure TGoToImpl.OnItem(Sender: TObject);
begin
  try
    const I = (Sender as TMenuItem).Tag;
    if (I >= 0) and (I <= High(FTargets)) then
      GoToTarget(FTargets[I]);
  except
  end;
end;

procedure TGoToImpl.OnMouseDown(const Editor: TWinControl; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer; var Handled: Boolean);
begin
  try
    FTaken := False;
    if Button <> mbLeft then
      Exit;
    const Services = BorlandIDEServices as INTACodeEditorServices;
    var View := Services.GetViewForEditor(Editor);
    if (View = nil) or (View.Buffer = nil) then
      Exit;
    if Shift * [ssCtrl, ssAlt, ssShift] <> [ssCtrl, ssAlt] then
    begin
      EnsureIndex(View.Buffer.FileName);          // read early, so the first ask is quick
      Exit;
    end;
    const State = Services.EditorState[Editor];
    var Col, Visible: Integer;
    if not State.PointToCharacterPos(Point(X, Y), Col, Visible) then
      Exit;
    var P: TOTAEditPos;
    P.Col  := Col;
    P.Line := State.LineState[Visible].LogicalLineNum;
    var At := Editor.ClientToScreen(Point(X, Y + 16));
    Handled := True;
    FTaken  := True;
    // after the editor's event returns: a menu inside it would be shown mid-click
    TThread.ForceQueue(nil,
      procedure
      begin
        try
          Ask(View, P, At, akImplementation);
        except
        end;
      end);
  except
    // the editor goes on whatever happens here
  end;
end;

procedure TGoToImpl.OnMouseUp(const Editor: TWinControl; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer; var Handled: Boolean);
begin
  if FTaken and (Button = mbLeft) then
  begin
    Handled := True;                              // not a Ctrl+click's find declaration too
    FTaken  := False;
  end;
end;

procedure TGoToImpl.OnUpdate(Sender: TObject);
begin
  try
    (Sender as TAction).Enabled := (BorlandIDEServices as IOTAEditorServices).TopView <> nil;
  except
  end;
end;

procedure TGoToImpl.OnExecute(Sender: TObject);
begin
  try
    const View = (BorlandIDEServices as IOTAEditorServices).TopView;
    if View <> nil then
      Ask(View, View.CursorPos, Mouse.CursorPos, akImplementation);
  except
  end;
end;

procedure TGoToImpl.OnFindDeclaration(Sender: TObject);
begin
  try
    const View = (BorlandIDEServices as IOTAEditorServices).TopView;
    if View <> nil then
      Ask(View, View.CursorPos, Mouse.CursorPos, akDeclaration);
  except
  end;
end;

{ Register }

procedure Register;
begin
  Notifier := TGoToImpl.Create;
  NotifierIndex := (BorlandIDEServices as INTACodeEditorServices).AddEditorEventsNotifier(Notifier);
  try
    (BorlandIDEServices as IOTAEditorServices).GetEditorLocalMenu
      .RegisterActionList(Notifier.FActions, MenuCategory, cEdMenuCatIdentifier);
    MenuAdded := True;
  except
    // Ctrl+Alt+click alone
  end;
end;

initialization

finalization
  // the package unloaded: the menu's actions and the notifier go before the index does
  if MenuAdded then
  try
    (BorlandIDEServices as IOTAEditorServices).GetEditorLocalMenu.UnregisterActionList(MenuCategory);
  except
  end;
  if NotifierIndex >= 0 then
    (BorlandIDEServices as INTACodeEditorServices).RemoveEditorEventsNotifier(NotifierIndex);

end.
