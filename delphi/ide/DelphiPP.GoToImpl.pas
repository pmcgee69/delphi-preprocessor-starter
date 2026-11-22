unit DelphiPP.GoToImpl;

{ Go to implementation in the Delphi IDE's editor: on a call through an interface,
  `x.DoSomething()`, each class's method that implements it, as Zed has it through
  delphipp's language server (..\DelphiPP.Impl.pas, the same index). Ctrl+click goes
  to the interface; Ctrl+Shift+click on the method's name, or Go to Implementation on
  the editor's right-click menu (after Find Declaration), goes to the class: straight
  there when there is one, a menu to choose from when there are more. Wished for by
  a Delphi developer, passed on by the user (20 Nov): "In delphi it's so much harder
  to navigate to the implementation of an interface, and it's one of the reasons
  people don't use them as much as they could/should." (Ctrl+Alt+click, the first
  way, is gone: the user, 21 Nov, "delete ^Alt-click".)

  Find References (delphipp), on the same menu: every use of the name, listed in the
  Messages view, where a double-click opens it.

  The index is the active project's: the .pas and .dpr files in its folder and below, and
  those in each folder of its search path (the active configuration and platform's),
  read in the background when the editor is first clicked in, and again when the
  project or its search path changes. Any file, in any editor: the open file's own
  text is read as the editor has it. Nothing here may raise into the editor. }

interface

procedure Register;

implementation

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types, System.Math,
  System.IOUtils, System.Generics.Collections,
  Vcl.Controls, Vcl.Menus, Vcl.ActnList, Vcl.Forms, Vcl.ExtCtrls,
  ToolsAPI, ToolsAPI.Editor, DCCStrs,
  DelphiPP.Impl, DelphiPP.IDE;

const
  MenuCategory = 'DelphiPP.GoToImplementation';
  DeclCategory = 'DelphiPP.FindDeclaration';
  TypeCategory = 'DelphiPP.GoToTypeDefinition';
  RefsCategory = 'DelphiPP.FindReferences';
  RefsGroup    = 'delphipp: References';

type
  TAskKind = (akImplementation, akDeclaration, akTypeDefinition, akReferences);

  TGoToImpl = class(TNTACodeEditorNotifier)
  private
    FMenu    : TPopupMenu;
    FActions : TActionList;
    FDeclActions: TActionList;
    FTypeActions: TActionList;
    FRefsActions: TActionList;
    FRefsAction : TAction;
    // find references on a budget: where the last stopped, to go on from (the user, 21 Nov: "a
    // time budget like 0.5sec .. and then just add a list item of '...' to the results")
    FRefsKey    : string;             // the file and the caret it was asked at
    FRefsNext   : Integer;            // the unit to go on from; -1 when every one was read
    FRefsCount  : Integer;            // found so far
    FRefsFirst  : Integer;            // for Query: the unit to start from
    FRefsMore   : TRefsMore;          // from Query: how far it went
    FTargets : TArray<TImplTarget>;
    FIndexKey: string;                // what the index was built from: the project and its path
    FTaken   : Boolean;               // a Ctrl+Shift mouse-down taken: its mouse-up too
    // the answer, held until the mouse button is up: a menu shown mid-click
    FWait    : TTimer;
    FAt      : TPoint;
    FPrefix  : string;                // before each item's name: 'No implementation: its declaration, '
    FMessage : string;                // nothing found: said in a hint, not a menu
    FMessageAt: TPoint;               // the mouse when it was said
    FFromMenu: Boolean;               // asked from the editor's menu: the popup's first item lit
    // the hover: a name's declaration, its line as written, after the mouse rests on it (user,
    // 20 Nov: the IDE's own shows "..." with no project, "it could be showing type there")
    FHint      : TCodeHint;
    FHintText  : string;              // shown, '' when hidden
    FHover     : TTimer;              // the rest before asking; then, the mouse leaving
    FHoverEd   : TWinControl;
    FHoverPos  : TOTAEditPos;
    FHoverAt   : TPoint;              // on the screen, below the pointer
    FSpanLine, FSpan1, FSpan2: Integer; // the name the hint is for: its line, its columns
    procedure OnWait(Sender: TObject);
    procedure OnMouseMove(const Editor: TWinControl; Shift: TShiftState; X, Y: Integer);
    procedure OnKeyDown(const Editor: TWinControl; Key: Word; Shift: TShiftState; var Handled: Boolean);
    procedure OnHover(Sender: TObject);
    procedure HideHover;
    procedure OnMouseDown(const Editor: TWinControl; Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer; var Handled: Boolean);
    procedure OnMouseUp(const Editor: TWinControl; Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer; var Handled: Boolean);
    procedure OnExecute(Sender: TObject);
    procedure OnFindDeclaration(Sender: TObject);
    procedure OnUpdateImplementation(Sender: TObject);
    procedure OnUpdateDeclaration(Sender: TObject);
    procedure OnTypeDefinition(Sender: TObject);
    procedure OnUpdateTypeDefinition(Sender: TObject);
    procedure OnFindReferences(Sender: TObject);
    procedure OnUpdateReferences(Sender: TObject);
    function RefsKey(const View: IOTAEditView): string;
    procedure UpdateFor(A: TAction; Kind: TAskKind);
    procedure OnItem(Sender: TObject);
    procedure EnsureIndex(const FileName: string);
    function Query(const View: IOTAEditView; Pos: TOTAEditPos; Kind: TAskKind;
      WaitMs: Cardinal): TArray<TImplTarget>;
    procedure Ask(const View: IOTAEditView; Pos: TOTAEditPos; const At: TPoint; Kind: TAskKind);
    procedure ShowMenu(const At: TPoint);
    procedure ShowMessageHint(const At: TPoint; const Text: string);
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
  TypeAdded: Boolean;
  RefsAdded: Boolean;

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

// a file's line (from 1) and column (from 1), shown in the middle of its editor. Position counts
// the file's own lines; CursorPos, used before, landed a few lines off, differently each time
// (user, 20 Nov: TSortedList<T>.Add at 1758 landed "1760 ... repeat same -> 1755"): folded
// regions, it seems
procedure ShowPlace(const Path: string; Line, Col: Integer);
begin
  if not (BorlandIDEServices as IOTAActionServices).OpenFile(Path) then
    Exit;
  const View = (BorlandIDEServices as IOTAEditorServices).TopView;
  if View = nil then
    Exit;
  View.Position.Move(Line, Max(Col, 1));
  const At = View.CursorPos;
  View.Center(At.Line, At.Col);
  View.Paint;
  // the whole editor painted again: after a jump, lines were shown where others are, until each
  // was clicked (user, 20 Nov: "when you click on lines, they 'reveal' they are actually
  // different lines than first displayed")
  try
    (BorlandIDEServices as INTACodeEditorServices).InvalidateTopEditor;
  except
  end;
end;

{ the IDE's back and forward arrows (user, 20 Nov: "can we also get the back and forward arrows in
  the ide (like a browser) working for gotodef, and back to where you started?") }

type
  IDelphiPPPlace = interface
    ['{6F3B2A14-8C55-4E0B-9D7A-1C2E4B5A6D70}']
    function PlaceKey: string;
  end;

  THistoryPlace = class(TNotifierObject, IOTAHistoryItem, IDelphiPPPlace)
  private
    FPath: string;
    FLine, FCol: Integer;
  public
    constructor Create(const Path: string; Line, Col: Integer);
    procedure Execute;
    function GetItemCaption: string;
    function IsEqual(const Item: IOTAHistoryItem): Boolean;
    function PlaceKey: string;
  end;

var
  // ours in the IDE's history: taken back out when the package unloads, so the IDE never
  // holds an object whose code has gone
  Places: TList<IOTAHistoryItem>;

constructor THistoryPlace.Create(const Path: string; Line, Col: Integer);
begin
  inherited Create;
  FPath := Path;
  FLine := Line;
  FCol  := Col;
end;

procedure THistoryPlace.Execute;
begin
  // after the IDE's back or forward menu has gone, as a menu item's jump (OnItem)
  const Path = FPath;
  const Line = FLine;
  const Col  = FCol;
  TThread.ForceQueue(nil,
    procedure
    begin
      try
        ShowPlace(Path, Line, Col);
      except
      end;
    end);
end;

function THistoryPlace.GetItemCaption: string;
begin
  Result := ExtractFileName(FPath) + ' ' + IntToStr(FLine);
end;

function THistoryPlace.IsEqual(const Item: IOTAHistoryItem): Boolean;
begin
  var P: IDelphiPPPlace;
  Result := Supports(Item, IDelphiPPPlace, P) and (P.PlaceKey = PlaceKey);
end;

function THistoryPlace.PlaceKey: string;
begin
  Result := FPath.ToLower + '|' + IntToStr(FLine);
end;

// jump to T, the place left and the place reached put in the IDE's history
procedure GoToTarget(const T: TImplTarget);
begin
  var Here: IOTAHistoryItem := nil;
  const View = (BorlandIDEServices as IOTAEditorServices).TopView;
  if (View <> nil) and (View.Buffer <> nil) then
    Here := THistoryPlace.Create(View.Buffer.FileName, View.Position.Row, View.Position.Column);
  const There: IOTAHistoryItem = THistoryPlace.Create(T.Path, T.Line, T.Col + 1);
  ShowPlace(T.Path, T.Line, T.Col + 1);
  try
    var History: IOTAHistoryServices;
    if not Supports(BorlandIDEServices, IOTAHistoryServices, History) then
      Exit;
    if Here = nil then
      Here := There;
    History.AddHistoryItem(Here, There);
    Places.Add(Here);
    Places.Add(There);
    // a long session: the oldest out, from the IDE's history too
    while Places.Count > 400 do
    begin
      History.RemoveHistoryItem(Places[0]);
      Places.Delete(0);
    end;
  except
    // the jump without the history
  end;
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
  A.Hint       := 'The classes'' methods that implement this interface method (Ctrl+Shift+click)';
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
  // where the name's type is declared: IList<T> for fInspectors (user, 20 Nov: "can we have goto
  // type definition for the ide?")
  FTypeActions := TActionList.Create(nil);
  const Y  = TAction.Create(FTypeActions);
  Y.ActionList := FTypeActions;
  Y.Caption    := 'Go to Type Definition (delphipp)';
  Y.Hint       := 'Where this name''s type is declared, from delphipp''s index';
  Y.Category   := TypeCategory;
  Y.OnExecute  := OnTypeDefinition;
  Y.OnUpdate   := OnUpdateTypeDefinition;
  // every use of the name, in the Messages view (user, 21 Nov: "start with find references")
  FRefsActions := TActionList.Create(nil);
  const R  = TAction.Create(FRefsActions);
  R.ActionList := FRefsActions;
  R.Caption    := 'Find References (delphipp)';
  R.Hint       := 'Every use of this name, from delphipp''s index, in the Messages view';
  R.Category   := RefsCategory;
  R.OnExecute  := OnFindReferences;
  R.OnUpdate   := OnUpdateReferences;
  FRefsAction  := R;
  FRefsNext    := -1;
  FHint  := TCodeHint.Create(nil);
  FHover := TTimer.Create(nil);
  FHover.Enabled := False;
  FHover.OnTimer := OnHover;
  OnEditorMouseDownEx := OnMouseDown;
  OnEditorMouseUpEx   := OnMouseUp;
  OnEditorMouseMove   := OnMouseMove;
  OnEditorKeyDown     := OnKeyDown;
end;

destructor TGoToImpl.Destroy;
begin
  FHover.Free;
  FHint.Free;
  FWait.Free;
  FRefsActions.Free;
  FTypeActions.Free;
  FDeclActions.Free;
  FActions.Free;
  FMenu.Free;
  inherited;
end;

procedure TGoToImpl.OnWait(Sender: TObject);
begin
  try
    // the mouse button up first (Ctrl+Alt+click also had to wait for Alt, whose release closes a
    // popup menu: user, 20 Nov, "try ^shift-click", and 21 Nov, "delete ^Alt-click")
    if (GetAsyncKeyState(VK_LBUTTON) < 0) or (GetAsyncKeyState(VK_RBUTTON) < 0) then
      Exit;                           // still held: look again in 30 ms
    FWait.Enabled := False;
    if FTargets = nil then
      ShowMessageHint(FAt, FMessage)
    else if (Length(FTargets) = 1) and (FPrefix = '') then
      GoToTarget(FTargets[0])
    else
      ShowMenu(FAt);
  except
    FWait.Enabled := False;
  end;
end;

function TGoToImpl.AllowedEvents: TCodeEditorEvents;
begin
  Exit( [cevMouseEvents, cevKeyboardEvents] );
end;

procedure TGoToImpl.HideHover;
begin
  FHover.Enabled := False;
  if FHintText <> '' then
  begin
    FHint.ReleaseHandle;
    FHintText := '';
  end;
end;

procedure TGoToImpl.OnMouseMove(const Editor: TWinControl; Shift: TShiftState; X, Y: Integer);
begin
  try
    const Services = BorlandIDEServices as INTACodeEditorServices;
    const View = Services.GetViewForEditor(Editor);
    if (View = nil) or (View.Buffer = nil) then
      Exit;
    // a .dpps file has the rules' hovers (DelphiPP.IDE): not two hints at once
    const Low = View.Buffer.FileName.ToLower;
    if Low.EndsWith('.dpps') or Low.EndsWith('.dpps.pas') then
      Exit;
    const State = Services.EditorState[Editor];
    var Col, Visible: Integer;
    if not State.PointToCharacterPos(Point(X, Y), Col, Visible) then
    begin
      HideHover;
      Exit;
    end;
    const Line = State.LineState[Visible].LogicalLineNum;
    if (FHintText <> '') and (Line = FSpanLine) and (Col >= FSpan1) and (Col < FSpan2) then
      Exit;                           // still over the name its hint is for
    if (FHintText <> '') and (FSpanLine = -1) and
       (Abs(Mouse.CursorPos.X - FMessageAt.X) + Abs(Mouse.CursorPos.Y - FMessageAt.Y) < 6) then
      Exit;                           // a message by the cursor: until the mouse really moves
    HideHover;
    if Shift * [ssCtrl, ssAlt, ssShift] <> [] then
      Exit;                           // a Ctrl+click, the IDE's underline: no hint over it
    FHoverEd := Editor;
    FHoverPos.Col  := Col;
    FHoverPos.Line := Line;
    FHoverAt := Editor.ClientToScreen(Point(X, Y + 20));
    // the name under the pointer, in the editor's columns: identifier characters either side
    const Text = State.LineState[Visible].Text;
    var A := Col;
    var B := Col;
    while (A > 1) and (A - 1 <= Text.Length) and CharInSet(Text[A - 1], ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
      Dec(A);
    while (B <= Text.Length) and CharInSet(Text[B], ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
      Inc(B);
    if B = A then
      Exit;                           // not over a name
    FSpanLine := Line;
    FSpan1 := A;
    FSpan2 := B;
    FHover.Interval := 600;
    FHover.Enabled  := True;
  except
    // the editor goes on whatever happens here
  end;
end;

procedure TGoToImpl.OnKeyDown(const Editor: TWinControl; Key: Word; Shift: TShiftState;
  var Handled: Boolean);
begin
  HideHover;
end;

// the declaration's line as written, and where it is: from the editor's text for the open file
function DeclarationHint(const T: TImplTarget; const View: IOTAEditView): string;
begin
  Result := '';
  var Text: string;
  if SameText(T.Path, View.Buffer.FileName) then
    Text := TEncoding.UTF8.GetString(BufferText(View.Buffer))
  else
    Text := TFile.ReadAllText(T.Path);
  const Lines = Text.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
  if (T.Line < 1) or (T.Line > Length(Lines)) then
    Exit;
  Result := Lines[T.Line - 1].Trim + sLineBreak +
            T.Name + '  -  ' + ExtractFileName(T.Path) + ' ' + IntToStr(T.Line);
end;

procedure TGoToImpl.OnHover(Sender: TObject);
begin
  try
    if FHintText <> '' then
    begin
      // shown: watching for the mouse leaving the editor
      if FindVCLWindow(Mouse.CursorPos) <> FHoverEd then
        HideHover;
      Exit;
    end;
    FHover.Enabled := False;
    if FindVCLWindow(Mouse.CursorPos) <> FHoverEd then
      Exit;
    if IndexedCount = 0 then
      Exit;                           // still reading the units: nothing to say yet, no waiting
    const View = (BorlandIDEServices as INTACodeEditorServices).GetViewForEditor(FHoverEd);
    if (View = nil) or (View.Buffer = nil) then
      Exit;
    const Found = Query(View, FHoverPos, akDeclaration, 0);
    if Length(Found) <> 1 then
      Exit;
    const Text = DeclarationHint(Found[0], View);
    if Text = '' then
      Exit;
    var R := FHint.CalcHintRect(Screen.Width div 2, Text, nil);
    R.Offset(FHoverAt.X, FHoverAt.Y);
    FHint.ActivateHint(R, Text);
    FHintText := Text;
    FHover.Interval := 250;
    FHover.Enabled  := True;
  except
    HideHover;
  end;
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
  case Kind of
    akDeclaration:    Result := Definitions(FileName, Text, CP.Line - 1, Ch, WaitMs);
    akTypeDefinition: Result := TypeDefinitions(FileName, Text, CP.Line - 1, Ch, WaitMs);
    akReferences:
    begin
      // the other files open in the editor, as it has them, not as saved
      const Open = TDictionary<string, string>.Create;
      try
        var Buffers: IOTAEditBufferIterator;
        if (BorlandIDEServices as IOTAEditorServices).GetEditBufferIterator(Buffers) then
          for var I := 0 to Buffers.Count - 1 do
          try
            const B = Buffers.EditBuffers[I];
            if (B <> nil) and B.IsModified then
              Open.AddOrSetValue(B.FileName.ToLower, TEncoding.UTF8.GetString(BufferText(B)));
          except
            // that one as saved
          end;
        // half a second, from FRefsFirst: OnFindReferences goes on from FRefsMore.Next
        Result := References(FileName, Text, CP.Line - 1, Ch, True,
          function(P: string): string
          begin
            if not Open.TryGetValue(P.ToLower, Result) then
              Result := '';
          end, WaitMs, 500, FRefsFirst, FRefsMore);
      finally
        Open.Free;
      end;
    end;
  else
    Result := Implementations(FileName, Text, CP.Line - 1, Ch, WaitMs);
  end;
end;

procedure TGoToImpl.Ask(const View: IOTAEditView; Pos: TOTAEditPos; const At: TPoint; Kind: TAskKind);
begin
  FTargets := nil;
  if (View = nil) or (View.Buffer = nil) then
    Exit;
  EnsureIndex(View.Buffer.FileName);
  FPrefix  := '';
  FMessage := '';
  const Was = Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    // the first time, the index is still being read: a second or so for Spring4D's 367 units
    FTargets := Query(View, Pos, Kind, 20000);
    if FTargets = nil then
    begin
      if Kind = akDeclaration then
        FMessage := Format('No declaration found (%d units read)', [IndexedCount])
      else if Kind = akTypeDefinition then
        FMessage := Format('No type found (%d units read)', [IndexedCount])
      else
      begin
        // not a method called through an interface, or none implements it: its declaration, as
        // one item that says so (two lines of notes above it lit up and did nothing: user,
        // 20 Nov, "the first 2 lines do nothing but stil highlight")
        FTargets := Query(View, Pos, akDeclaration, 0);
        if FTargets <> nil then
          FPrefix := 'No implementation: its declaration, '
        else
          FMessage := Format('No implementation or declaration found (%d units read)', [IndexedCount]);
      end;
    end;
  finally
    Screen.Cursor := Was;
  end;
  // jump, or show the menu, once the keys and the mouse button are let go (OnWait)
  FAt := At;
  FWait.Enabled := True;
end;

// nothing to go to: said in a hint by the cursor, not a menu with nothing in it
procedure TGoToImpl.ShowMessageHint(const At: TPoint; const Text: string);
begin
  HideHover;
  if Text = '' then
    Exit;
  var R := FHint.CalcHintRect(Screen.Width div 2, Text, nil);
  R.Offset(At.X, At.Y);
  FHint.ActivateHint(R, Text);
  FHintText := Text;
  FSpanLine := -1;                    // no name: the mouse moving away hides it
  FMessageAt := Mouse.CursorPos;
  FHoverEd := FindVCLWindow(FMessageAt);
  FHover.Interval := 250;
  FHover.Enabled  := True;
end;

// a menu item's text with room after it: the IDE's menus draw larger than they measure, and
// the end was cut off, even in one piece (user, 20 Nov: "Spring.Container.Buil",
// "Spring.Collections.Lists.pas 19")
function Padded(const S: string): string;
begin
  Result := S + StringOfChar(' ', Length(S) div 4 + 2);
end;

procedure TGoToImpl.ShowMenu(const At: TPoint);
begin
  FMenu.Items.Clear;
  for var I := 0 to High(FTargets) do
  begin
    const Item = TMenuItem.Create(FMenu);
    // in one piece: after a tab, as a shortcut is, it was cut off (user, 20 Nov: the
    // declaration's unit shown as "Spring.Container.Build")
    Item.Caption := Padded((FPrefix + FTargets[I].Name + '  -  ' + ExtractFileName(FTargets[I].Path) +
                            ' ' + IntToStr(FTargets[I].Line)).Replace('&', '&&'));
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
  // from the editor's menu, the mouse is over the popup but lights nothing (user, 20 Nov: "line 3
  // isn't highlighted until you then move"): the first item lit, for the arrows and Enter
  if FFromMenu then
    PostMessage(PopupList.Window, WM_KEYDOWN, VK_DOWN, 0);
  HideHover;
  FMenu.Popup(At.X, At.Y);
end;

procedure TGoToImpl.OnItem(Sender: TObject);
begin
  try
    const I = (Sender as TMenuItem).Tag;
    if (I < 0) or (I > High(FTargets)) then
      Exit;
    // after the menu has gone: it puts back what was under it as it closes, over the editor
    // that has scrolled meanwhile (user, 20 Nov: "wtf line numbers?????", the same lines twice)
    var T := FTargets[I];
    TThread.ForceQueue(nil,
      procedure
      begin
        try
          GoToTarget(T);
        except
        end;
      end);
  except
  end;
end;

procedure TGoToImpl.OnMouseDown(const Editor: TWinControl; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer; var Handled: Boolean);
begin
  try
    FTaken := False;
    FFromMenu := False;
    HideHover;
    if Button <> mbLeft then
      Exit;
    const Services = BorlandIDEServices as INTACodeEditorServices;
    var View := Services.GetViewForEditor(Editor);
    if (View = nil) or (View.Buffer = nil) then
      Exit;
    const Mods = Shift * [ssCtrl, ssAlt, ssShift];
    if Mods <> [ssCtrl, ssShift] then
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
    Handled  := True;               // not the IDE's: no selection extended, no Ctrl+click
    FTaken   := True;
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
    begin
      FFromMenu := True;
      Ask(View, View.CursorPos, CaretPoint(View), akImplementation);
    end;
  except
  end;
end;

procedure TGoToImpl.OnFindDeclaration(Sender: TObject);
begin
  try
    const View = (BorlandIDEServices as IOTAEditorServices).TopView;
    if View <> nil then
    begin
      FFromMenu := True;
      Ask(View, View.CursorPos, CaretPoint(View), akDeclaration);
    end;
  except
  end;
end;

procedure TGoToImpl.OnTypeDefinition(Sender: TObject);
begin
  try
    const View = (BorlandIDEServices as IOTAEditorServices).TopView;
    if View <> nil then
    begin
      FFromMenu := True;
      Ask(View, View.CursorPos, CaretPoint(View), akTypeDefinition);
    end;
  except
  end;
end;

procedure TGoToImpl.OnUpdateTypeDefinition(Sender: TObject);
begin
  UpdateFor(Sender as TAction, akTypeDefinition);
end;

function TGoToImpl.RefsKey(const View: IOTAEditView): string;
begin
  Result := Format('%s|%d|%d', [View.Buffer.FileName.ToLower, View.CursorPos.Line, View.CursorPos.Col]);
end;

// every use of the name at the caret, in the Messages view, a tab of its own: half a second's
// worth, then a last line saying how far it got; asked again at the same caret (the menu item
// is then Find More References), the next half second's are added below
procedure TGoToImpl.OnFindReferences(Sender: TObject);
begin
  try
    const View = (BorlandIDEServices as IOTAEditorServices).TopView;
    if (View = nil) or (View.Buffer = nil) then
      Exit;
    EnsureIndex(View.Buffer.FileName);
    const Key = RefsKey(View);
    const GoOn = (Key = FRefsKey) and (FRefsNext > 0);
    FRefsFirst := if GoOn then FRefsNext else 0;
    var Found: TArray<TImplTarget>;
    const Was = Screen.Cursor;
    Screen.Cursor := crHourGlass;
    try
      Found := Query(View, View.CursorPos, akReferences, 20000);
    finally
      Screen.Cursor := Was;
    end;
    const More = FRefsMore;
    FRefsKey  := Key;
    FRefsNext := More.Next;
    const Messages = BorlandIDEServices as IOTAMessageServices;
    var Group := Messages.GetGroup(RefsGroup);
    if Group = nil then
      Group := Messages.AddMessageGroup(RefsGroup);
    if not GoOn then
    begin
      Messages.ClearMessageGroup(Group);
      FRefsCount := 0;
    end;
    Inc(FRefsCount, Length(Found));
    if More.Common then
      Messages.AddTitleMessage('A name every unit uses (Integer, string, TObject ...): its uses aren''t listed', Group)
    else if GoOn then
      Messages.AddTitleMessage(Format('%d more (%d in all)', [Length(Found), FRefsCount]), Group)
    else if Found = nil then
      Messages.AddTitleMessage(Format('No references found (%d units read)', [More.Read]), Group)
    else
      Messages.AddTitleMessage(Format('%d references', [Length(Found)]), Group);
    for var T in Found do
    begin
      var Ref: Pointer;
      Messages.AddToolMessage(T.Path, T.Name, 'delphipp', T.Line, T.Col + 1, nil, Ref, Group);
    end;
    if More.Next >= 0 then
      Messages.AddTitleMessage(Format('... %d of %d units read in half a second: right-click here, ' +
        'Find More References (delphipp), for the rest', [More.Read, More.Total]), Group);
    Messages.ShowMessageView(Group);
  except
    // the editor goes on whatever happens here
  end;
end;

// Find More References at the caret where the last stopped short; greyed where there's nothing
// declared to find
procedure TGoToImpl.OnUpdateReferences(Sender: TObject);
begin
  try
    const View = (BorlandIDEServices as IOTAEditorServices).TopView;
    if (View <> nil) and (View.Buffer <> nil) and (FRefsNext > 0) and (RefsKey(View) = FRefsKey) then
      FRefsAction.Caption := 'Find More References (delphipp)'
    else
      FRefsAction.Caption := 'Find References (delphipp)';
  except
  end;
  UpdateFor(Sender as TAction, akDeclaration);
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
    Menu.RegisterActionList(Notifier.FTypeActions, TypeCategory, cEdMenuCatIdentifier);
    TypeAdded := True;
    Menu.RegisterActionList(Notifier.FRefsActions, RefsCategory, cEdMenuCatIdentifier);
    RefsAdded := True;
  except
    // Ctrl+Shift+click alone
  end;
end;

initialization
  Places := TList<IOTAHistoryItem>.Create;

finalization
  // our places out of the IDE's history first: its back arrow mustn't call code that's gone
  try
    var History: IOTAHistoryServices;
    if Supports(BorlandIDEServices, IOTAHistoryServices, History) then
      for var P in Places do
        History.RemoveHistoryItem(P);
  except
  end;
  Places.Free;
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
  if TypeAdded then
  try
    (BorlandIDEServices as IOTAEditorServices).GetEditorLocalMenu.UnregisterActionList(TypeCategory);
  except
  end;
  if RefsAdded then
  try
    (BorlandIDEServices as IOTAEditorServices).GetEditorLocalMenu.UnregisterActionList(RefsCategory);
  except
  end;
  if NotifierIndex >= 0 then
    (BorlandIDEServices as INTACodeEditorServices).RemoveEditorEventsNotifier(NotifierIndex);

end.
