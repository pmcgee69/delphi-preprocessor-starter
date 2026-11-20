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
    procedure OnUpdate(Sender: TObject);
    procedure OnItem(Sender: TObject);
    procedure EnsureIndex(const FileName: string);
    procedure Ask(const View: IOTAEditView; Pos: TOTAEditPos; const At: TPoint);
    procedure ShowMenu(const At: TPoint);
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

// the active project's folder (Deep) and search path (Flat); '' when there is no project
function ProjectFolders(out Deep, Flat: TArray<string>): string;
begin
  Deep := nil;
  Flat := nil;
  const Project = GetActiveProject;
  if Project = nil then
    Exit( '' );
  const Dir = ExtractFilePath(Project.FileName);
  Deep := [Dir];
  var Search := '';
  var Plat := '';
  var Conf := '';
  try
    const Configs = Project.ProjectOptions as IOTAProjectOptionsConfigurations;
    Plat := Configs.ActivePlatformName;
    Conf := Configs.ActiveConfigurationName;
    var C := Configs.ActiveConfiguration;
    if (C <> nil) and (Plat <> '') and (C.PlatformConfiguration[Plat] <> nil) then
      C := C.PlatformConfiguration[Plat];
    if C <> nil then
      Search := C.GetValue(sUnitSearchPath, True);
  except
    // the folder alone
  end;
  for var E in Search.Split([';']) do
  begin
    var S := Expand(E.Trim, Plat, Conf);
    if S = '' then
      Continue;
    try
      if TPath.IsRelativePath(S) then
        S := TPath.Combine(Dir, S);
      Flat := Flat + [ExcludeTrailingPathDelimiter(TPath.GetFullPath(S))];
    except
      // not a path
    end;
  end;
  Result := Project.FileName + '|' + string.Join(';', Flat);
end;

procedure GoToTarget(const T: TImplTarget);
begin
  if not (BorlandIDEServices as IOTAActionServices).OpenFile(T.Path) then
    Exit;
  const View = (BorlandIDEServices as IOTAEditorServices).TopView;
  if View = nil then
    Exit;
  var P: TOTAEditPos;
  P.Col  := 1;
  P.Line := T.Line;
  View.CursorPos := P;
  View.Center(T.Line, 1);
  View.Paint;
end;

{ TGoToImpl }

constructor TGoToImpl.Create;
begin
  inherited Create;
  FMenu    := TPopupMenu.Create(nil);
  FActions := TActionList.Create(nil);
  const A  = TAction.Create(FActions);
  A.ActionList := FActions;
  A.Caption    := 'Go to Implementation';
  A.Hint       := 'The classes'' methods that implement this interface method (Ctrl+Alt+click)';
  A.Category   := MenuCategory;
  A.OnExecute  := OnExecute;
  A.OnUpdate   := OnUpdate;
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
  var Deep, Flat: TArray<string>;
  var Key := ProjectFolders(Deep, Flat);
  if Key = '' then
  begin
    // no project: the file's folder
    Deep := [ExtractFilePath(FileName)];
    Key  := '|' + Deep[0];
  end;
  if Key = FIndexKey then
    Exit;
  FIndexKey := Key;
  IndexFolders(Deep, Flat);
end;

procedure TGoToImpl.Ask(const View: IOTAEditView; Pos: TOTAEditPos; const At: TPoint);
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
  const Was = Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    // the first time, the index is still being read: a second or so for Spring4D's 367 units
    FTargets := Implementations(FileName, Text, CP.Line - 1, Ch, 20000);
  finally
    Screen.Cursor := Was;
  end;
  if Length(FTargets) = 1 then
    GoToTarget(FTargets[0])
  else
    ShowMenu(At);
end;

procedure TGoToImpl.ShowMenu(const At: TPoint);
begin
  FMenu.Items.Clear;
  if FTargets = nil then
  begin
    const Item = TMenuItem.Create(FMenu);
    Item.Caption := Format('No implementation found (%d units read)', [IndexedCount]);
    Item.Enabled := False;
    FMenu.Items.Add(Item);
    const Why = TMenuItem.Create(FMenu);
    Why.Caption := 'Put the cursor on a method called through an interface: x.DoSomething';
    Why.Enabled := False;
    FMenu.Items.Add(Why);
  end
  else
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
          Ask(View, P, At);
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
      Ask(View, View.CursorPos, Mouse.CursorPos);
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
