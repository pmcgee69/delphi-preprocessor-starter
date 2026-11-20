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
  Vcl.Controls, Vcl.Menus, Vcl.ActnList, Vcl.Forms, Vcl.ExtCtrls,
  ToolsAPI, ToolsAPI.Editor, DCCStrs,
  DelphiPP.Impl;

const
  MenuCategory = 'DelphiPP.GoToImplementation';
  DeclCategory = 'DelphiPP.FindDeclaration';

type
  TAskKind = (akImplementation, akDeclaration);

  TGoToImpl = class(TNTACodeEditorNotifier)
  private
    FMenu    : TPopupMenu;
    FActions : TActionList;
    FDeclActions: TActionList;
    FTargets : TArray<TImplTarget>;
    FIndexKey: string;                // what the index was built from: the project and its path
    FTaken   : Boolean;               // a Ctrl+Alt mouse-down taken: its mouse-up too
    // the answer, held until Ctrl, Alt and the mouse button are up: Alt let go opens the IDE's
    // main menu, which closed the popup as it opened (user, 20 Nov: "the same dialog flickers
    // ghost-like only for a small part of a second, no text visible")
    FWait    : TTimer;
    FAt      : TPoint;
    FNotes   : TArray<string>;
    procedure OnWait(Sender: TObject);
    procedure OnMouseDown(const Editor: TWinControl; Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer; var Handled: Boolean);
    procedure OnMouseUp(const Editor: TWinControl; Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer; var Handled: Boolean);
    procedure OnExecute(Sender: TObject);
    procedure OnFindDeclaration(Sender: TObject);
    procedure OnUpdateImplementation(Sender: TObject);
    procedure OnUpdateDeclaration(Sender: TObject);
    procedure UpdateFor(A: TAction; Kind: TAskKind);
    procedure OnItem(Sender: TObject);
    procedure EnsureIndex(const FileName: string);
    function Query(const View: IOTAEditView; Pos: TOTAEditPos; Kind: TAskKind;
      WaitMs: Cardinal): TArray<TImplTarget>;
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
  DeclAdded: Boolean;

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

// what to index for a file, as the IDE sees it: the active project's folder, with its
// subfolders (Deep), and its search path, the file's own folder and the IDE's library path
// (Flat). With no project, the file's repository instead of the project's folder: a file opened
// on its own (user, 20 Nov: "i dunno if we should be assuming repos 'tho ... the ide works with
// projects, right?"). The key: what it was built from, to read it again when that changes
function IndexScope(const FileName: string; out Deep, Flat: TArray<string>): string;
begin
  Deep := nil;
  Flat := [ExcludeTrailingPathDelimiter(ExtractFilePath(FileName))];
  var Plat := {$IFDEF WIN64} 'Win64' {$ELSE} 'Win32' {$ENDIF};
  var Conf := 'Debug';
  const Project = GetActiveProject;
  if Project = nil then
    Deep := [RepoRoot(FileName)]
  else
  begin
    const Dir = ExtractFilePath(Project.FileName);
    Deep := [Dir];
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
    Flat := Flat + PathFolders(Search, Dir, Plat, Conf);
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
  FWait := TTimer.Create(nil);
  FWait.Enabled  := False;
  FWait.Interval := 30;
  FWait.OnTimer  := OnWait;
  const A  = TAction.Create(FActions);
  A.ActionList := FActions;
  A.Caption    := 'Go to Implementation';
  A.Hint       := 'The classes'' methods that implement this interface method (Ctrl+Alt+click)';
  A.Category   := MenuCategory;
  A.OnExecute  := OnExecute;
  A.OnUpdate   := OnUpdateImplementation;
  // the IDE's own Find Declaration needs the project to know where each unit is (user, 20 Nov:
  // "i think you are being generous to think the ide will find declaration"). Its own list and
  // category: a second action in the first list wasn't shown ("there is no other FD listed")
  FDeclActions := TActionList.Create(nil);
  const D  = TAction.Create(FDeclActions);
  D.ActionList := FDeclActions;
  D.Caption    := 'Find Declaration (delphipp)';
  D.Hint       := 'Where this name is declared, from delphipp''s index';
  D.Category   := DeclCategory;
  D.OnExecute  := OnFindDeclaration;
  D.OnUpdate   := OnUpdateDeclaration;
  OnEditorMouseDownEx := OnMouseDown;
  OnEditorMouseUpEx   := OnMouseUp;
end;

destructor TGoToImpl.Destroy;
begin
  FWait.Free;
  FDeclActions.Free;
  FActions.Free;
  FMenu.Free;
  inherited;
end;

procedure TGoToImpl.OnWait(Sender: TObject);
begin
  try
    // the mouse button only: Alt is disarmed at the click (OnMouseDown), so the menu shows with
    // the keys still held (user, 20 Nov: "still no popup until release keys")
    if (GetAsyncKeyState(VK_LBUTTON) < 0) or (GetAsyncKeyState(VK_RBUTTON) < 0) then
      Exit;                           // still held: look again in 30 ms
    FWait.Enabled := False;
    if (Length(FTargets) = 1) and (FNotes = nil) then
      GoToTarget(FTargets[0])
    else
      ShowMenu(FAt, FNotes);
  except
    FWait.Enabled := False;
  end;
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

// the implementations, or the declaration, of the name at Pos in the view's file as the editor
// has it; waiting up to WaitMs for the index
function TGoToImpl.Query(const View: IOTAEditView; Pos: TOTAEditPos; Kind: TAskKind;
  WaitMs: Cardinal): TArray<TImplTarget>;
begin
  Result := nil;
  if (View = nil) or (View.Buffer = nil) then
    Exit;
  const FileName = View.Buffer.FileName;
  const Text = TEncoding.UTF8.GetString(BufferText(View.Buffer));
  // the editor's column (tabs expanded) as a character of the line
  var CP: TOTACharPos;
  View.ConvertPos(True, Pos, CP);
  const Lines = Text.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
  if (CP.Line < 1) or (CP.Line > Length(Lines)) then
    Exit;
  const LineBytes = TEncoding.UTF8.GetBytes(Lines[CP.Line - 1]);
  const Ch = Length(TEncoding.UTF8.GetString(LineBytes, 0, Min(Max(CP.CharIndex, 0), Length(LineBytes))));
  if Kind = akDeclaration then
    Result := Definitions(FileName, Text, CP.Line - 1, Ch, WaitMs)
  else
    Result := Implementations(FileName, Text, CP.Line - 1, Ch, WaitMs);
end;

procedure TGoToImpl.Ask(const View: IOTAEditView; Pos: TOTAEditPos; const At: TPoint; Kind: TAskKind);
begin
  FTargets := nil;
  if (View = nil) or (View.Buffer = nil) then
    Exit;
  EnsureIndex(View.Buffer.FileName);
  var Notes: TArray<string> := nil;
  const Was = Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    // the first time, the index is still being read: a second or so for Spring4D's 367 units
    FTargets := Query(View, Pos, Kind, 20000);
    if FTargets = nil then
    begin
      if Kind = akDeclaration then
        Notes := [Format('No declaration found (%d units read)', [IndexedCount])]
      else
      begin
        // not a method called through an interface, or none implements it: its declaration
        FTargets := Query(View, Pos, akDeclaration, 0);
        Notes := [Format('No implementation found (%d units read)', [IndexedCount])];
        if FTargets <> nil then
          Notes := Notes + ['Its declaration:'];
      end;
    end;
  finally
    Screen.Cursor := Was;
  end;
  // jump, or show the menu, once the mouse button is let go (OnWait)
  FAt    := At;
  FNotes := Notes;
  FWait.Enabled := True;
end;

// a menu item's text with room after it: the IDE's menus draw larger than they measure, and
// the end was cut off, even in one piece (user, 20 Nov: "Spring.Container.Buil",
// "Spring.Collections.Lists.pas 19")
function Padded(const S: string): string;
begin
  Result := S + StringOfChar(' ', Length(S) div 4 + 2);
end;

procedure TGoToImpl.ShowMenu(const At: TPoint; const Notes: TArray<string>);
begin
  FMenu.Items.Clear;
  // a note is an item that does nothing: enabled, so it reads as text, not greyed (user, 20 Nov:
  // "text could be white")
  for var S in Notes do
  begin
    const Item = TMenuItem.Create(FMenu);
    Item.Caption := Padded(S.Replace('&', '&&'));
    Item.Tag     := -1;
    FMenu.Items.Add(Item);
  end;
  for var I := 0 to High(FTargets) do
  begin
    const Item = TMenuItem.Create(FMenu);
    // in one piece: after a tab, as a shortcut is, it was cut off (user, 20 Nov: the
    // declaration's unit shown as "Spring.Container.Build")
    Item.Caption := Padded((FTargets[I].Name + '  -  ' + ExtractFileName(FTargets[I].Path) + ' ' +
                            IntToStr(FTargets[I].Line)).Replace('&', '&&'));
    Item.Tag     := I;
    Item.OnClick := OnItem;
    FMenu.Items.Add(Item);
  end;
  // themed as the IDE's own menus, so that it is measured as it is drawn
  try
    var Theming: IOTAIDEThemingServices;
    if Supports(BorlandIDEServices, IOTAIDEThemingServices, Theming) and Theming.IDEThemingEnabled then
      Theming.ApplyTheme(FMenu);
  except
    // unthemed
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
    // Alt let go with no key pressed since it went down opens the IDE's main menu, closing ours
    // as it opens: an unassigned key (VK $E8, as AutoHotkey's menu mask) pressed now disarms that
    keybd_event($E8, 0, 0, 0);
    keybd_event($E8, 0, KEYEVENTF_KEYUP, 0);
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

// greyed when there is nothing to go to at the cursor: asked as the editor's menu is built, in a
// few milliseconds; enabled while the units are still being read, when it can't tell (user,
// 20 Nov, Go to Implementation on fInspectors: "maybe should just gray out the option?")
procedure TGoToImpl.UpdateFor(A: TAction; Kind: TAskKind);
begin
  try
    const View = (BorlandIDEServices as IOTAEditorServices).TopView;
    if (View = nil) or (View.Buffer = nil) then
    begin
      A.Enabled := False;
      Exit;
    end;
    EnsureIndex(View.Buffer.FileName);
    if IndexedCount = 0 then
      A.Enabled := True
    else
      A.Enabled := Query(View, View.CursorPos, Kind, 0) <> nil;
  except
    A.Enabled := True;
  end;
end;

procedure TGoToImpl.OnUpdateImplementation(Sender: TObject);
begin
  UpdateFor(Sender as TAction, akImplementation);
end;

procedure TGoToImpl.OnUpdateDeclaration(Sender: TObject);
begin
  UpdateFor(Sender as TAction, akDeclaration);
end;

// just below the caret's character, on the screen: a menu asked for from the editor's own menu
// opens there, not where that menu's item was (user, 20 Nov: "a little displaced")
function CaretPoint(const View: IOTAEditView): TPoint;
begin
  Result := Mouse.CursorPos;
  try
    const Services = BorlandIDEServices as INTACodeEditorServices;
    const Editor = Services.GetEditorForView(View);
    if Editor = nil then
      Exit;
    const State = Services.EditorState[Editor];
    const LineState = State.LogicalLineState[View.CursorPos.Line];
    if LineState = nil then
      Exit;
    const R = State.GetCharacterPosPx(View.CursorPos.Col, LineState.EditorLineNum);
    Result := Editor.ClientToScreen(Point(R.Left, R.Bottom + 2));
  except
    // where the mouse is
  end;
end;

procedure TGoToImpl.OnExecute(Sender: TObject);
begin
  try
    const View = (BorlandIDEServices as IOTAEditorServices).TopView;
    if View <> nil then
      Ask(View, View.CursorPos, CaretPoint(View), akImplementation);
  except
  end;
end;

procedure TGoToImpl.OnFindDeclaration(Sender: TObject);
begin
  try
    const View = (BorlandIDEServices as IOTAEditorServices).TopView;
    if View <> nil then
      Ask(View, View.CursorPos, CaretPoint(View), akDeclaration);
  except
  end;
end;

{ Register }

procedure Register;
begin
  Notifier := TGoToImpl.Create;
  NotifierIndex := (BorlandIDEServices as INTACodeEditorServices).AddEditorEventsNotifier(Notifier);
  try
    const Menu = (BorlandIDEServices as IOTAEditorServices).GetEditorLocalMenu;
    Menu.RegisterActionList(Notifier.FActions, MenuCategory, cEdMenuCatIdentifier);
    MenuAdded := True;
    Menu.RegisterActionList(Notifier.FDeclActions, DeclCategory, cEdMenuCatIdentifier);
    DeclAdded := True;
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
  if DeclAdded then
  try
    (BorlandIDEServices as IOTAEditorServices).GetEditorLocalMenu.UnregisterActionList(DeclCategory);
  except
  end;
  if NotifierIndex >= 0 then
    (BorlandIDEServices as INTACodeEditorServices).RemoveEditorEventsNotifier(NotifierIndex);

end.
