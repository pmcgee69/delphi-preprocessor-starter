unit DelphiPP.IDE;

{ The rules in the Delphi IDE's editor, as Zed shows them: in an open .dpps file
  (or .dpps.pas), what a rule would change is underlined, and a rule's error,
  warning or hint is underlined where it is, with its text after the end of the
  line. The rules run inside the IDE, on the editor's own text, each time it
  changes: the same engine and rules as delphipp.exe (..\DelphiPP.Engine.pas),
  the ones the Python side's ALL lists, so what is shown is what the pre-build
  event will do.

  Installing it also adds dpps to the extensions the editor reads as Delphi, so
  a .dpps file is highlighted (the registry step in examples\ide\README.md).

  Through the ToolsAPI's editor events (ToolsAPI.Editor.pas): BeginPaint reads
  the buffer and runs the rules when its text has changed; PaintLine draws on
  each line when it has been painted. Nothing here may raise into the editor:
  every event is guarded. }

interface

procedure Register;

implementation

uses
  System.SysUtils, System.Types, System.Classes, System.Generics.Collections,
  Vcl.Controls, Vcl.Graphics,
  ToolsAPI, ToolsAPI.Editor,
  DelphiPP.Marks;

const
  EditColor    = TColor($C0A000);   // teal: a rule changes this
  ErrorColor   = TColor($3030E0);   // red
  WarningColor = TColor($00A0F0);   // amber
  HintColor    = TColor($A0A0A0);   // grey

type
  TRulesNotifier = class(TNTACodeEditorNotifier)
  private
    FFiles: TObjectDictionary<string, TAnalysis>;     // by file name, lower case
    procedure OnBeginPaint(const Editor: TWinControl; const ForceFullRepaint: Boolean);
    procedure OnPaintLine(const Rect: TRect; const Stage: TPaintLineStage;
      const BeforeEvent: Boolean; var AllowDefaultPainting: Boolean;
      const Context: INTACodeEditorPaintContext);
  protected
    function AllowedEvents: TCodeEditorEvents; override;
    function AllowedLineStages: TPaintLineStages; override;
  public
    constructor Create;
    destructor Destroy; override;
  end;

var
  NotifierIndex: Integer = -1;

function Shown(const FileName: string): Boolean;
begin
  const Low = FileName.ToLower;
  Exit( Low.EndsWith('.dpps') or Low.EndsWith('.dpps.pas') );
end;

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

{ TRulesNotifier }

constructor TRulesNotifier.Create;
begin
  inherited Create;
  FFiles := TObjectDictionary<string, TAnalysis>.Create([doOwnsValues]);
  OnEditorBeginPaint := OnBeginPaint;
  OnEditorPaintLine  := OnPaintLine;
end;

destructor TRulesNotifier.Destroy;
begin
  FFiles.Free;
  inherited;
end;

function TRulesNotifier.AllowedEvents: TCodeEditorEvents;
begin
  Exit( [cevBeginEndPaintEvents, cevPaintLineEvents] );
end;

function TRulesNotifier.AllowedLineStages: TPaintLineStages;
begin
  Exit( [plsEndPaint] );
end;

procedure TRulesNotifier.OnBeginPaint(const Editor: TWinControl; const ForceFullRepaint: Boolean);
begin
  try
    const Services = BorlandIDEServices as INTACodeEditorServices;
    const View = Services.GetViewForEditor(Editor);
    if (View = nil) or (View.Buffer = nil) or not Shown(View.Buffer.FileName) then
      Exit;
    const Key  = View.Buffer.FileName.ToLower;
    const Text = BufferText(View.Buffer);
    var Old: TAnalysis;
    if FFiles.TryGetValue(Key, Old) and (Length(Old.Text) = Length(Text)) and
       CompareMem(Pointer(Old.Text), Pointer(Text), Length(Text)) then
      Exit;                                         // unchanged since the rules last ran
    const OldShape = if Old <> nil then Old.Shape else '';
    const New = TAnalysis.Create(Text);
    FFiles.AddOrSetValue(Key, New);
    // a change on one line can move marks on others (an edit over several lines): the
    // whole editor again, once, when what is shown has changed
    if New.Shape <> OldShape then
      Services.InvalidateEditor(Editor);
  except
    // the editor must go on painting whatever happens here
  end;
end;

procedure TRulesNotifier.OnPaintLine(const Rect: TRect; const Stage: TPaintLineStage;
  const BeforeEvent: Boolean; var AllowDefaultPainting: Boolean;
  const Context: INTACodeEditorPaintContext);
begin
  if Stage <> plsEndPaint then
    Exit;
  try
    var A: TAnalysis;
    if not Shown(Context.FileName) or not FFiles.TryGetValue(Context.FileName.ToLower, A) then
      Exit;
    const Line = Context.LogicalLineNum;
    var Spans: TArray<TSpan>;
    var Notes: TArray<TNote>;
    A.Spans.TryGetValue(Line, Spans);
    A.Notes.TryGetValue(Line, Notes);
    if (Spans = nil) and (Notes = nil) then
      Exit;

    const Canvas = Context.Canvas;
    const State  = Context.EditorState;
    const Cell   = Context.CellSize;
    const Visible = Context.EditorLineNum;
    const PenColor = Canvas.Pen.Color;
    const PenStyle = Canvas.Pen.Style;
    const PenWidth = Canvas.Pen.Width;
    const BrushStyle = Canvas.Brush.Style;
    const FontColor = Canvas.Font.Color;
    const FontStyle = Canvas.Font.Style;
    try
      for var S in Spans do
      begin
        const R = State.GetCharacterPosPx(S.Col1, Visible);
        const X1 = R.Left;
        const X2 = R.Left + (S.Col2 - S.Col1) * Cell.cx;
        const Y  = R.Bottom - 1;
        Canvas.Pen.Width := 1;
        case S.Mark of
          mkEdit:
            begin
              // a dotted line: a rule changes this
              Canvas.Pen.Color := EditColor;
              var X := X1;
              while X < X2 do
              begin
                Canvas.MoveTo(X, Y);
                Canvas.LineTo(X + 2, Y);
                Inc(X, 4);
              end;
            end;
        else
          begin
            // a wave: a rule's message
            Canvas.Pen.Color := if S.Mark = mkError then ErrorColor
                                else if S.Mark = mkWarning then WarningColor
                                else HintColor;
            Canvas.MoveTo(X1, Y);
            var X := X1;
            var Up := True;
            while X < X2 do
            begin
              Inc(X, 2);
              Canvas.LineTo(X, if Up then Y - 2 else Y);
              Up := not Up;
            end;
          end;
        end;
      end;

      if Notes <> nil then
      begin
        // the messages, after the end of the line's text
        const LineText = Context.LineState.Text;
        const R = State.GetCharacterPosPx(Length(LineText.TrimRight) + 4, Visible);
        var X := R.Left;
        Canvas.Brush.Style := bsClear;
        Canvas.Font.Style  := [fsItalic];
        for var N in Notes do
        begin
          Canvas.Font.Color := if N.Mark = mkError then ErrorColor
                               else if N.Mark = mkWarning then WarningColor
                               else HintColor;
          Canvas.TextOut(X, R.Top, N.Text);
          Inc(X, Canvas.TextWidth(N.Text) + 3 * Cell.cx);
        end;
      end;
    finally
      Canvas.Pen.Color   := PenColor;
      Canvas.Pen.Style   := PenStyle;
      Canvas.Pen.Width   := PenWidth;
      Canvas.Brush.Style := BrushStyle;
      Canvas.Font.Color  := FontColor;
      Canvas.Font.Style  := FontStyle;
    end;
  except
    // as above
  end;
end;

{ Register }

procedure AddDppsExtension;
begin
  try
    const Options = (BorlandIDEServices as IOTAEditorServices).GetEditOptions('Borland.EditOptions.Pascal');
    if Options = nil then
      Exit;
    const Exts = Options.Extensions;
    if not (';' + Exts.ToLower + ';').Contains(';dpps;') then
      Options.Extensions := Exts + ';dpps';
  except
    // only highlighting: the rules are shown without it
  end;
end;

procedure Register;
begin
  AddDppsExtension;
  NotifierIndex := (BorlandIDEServices as INTACodeEditorServices)
                     .AddEditorEventsNotifier(TRulesNotifier.Create);
end;

initialization

finalization
  // the package unloaded (uninstalled, or the IDE closing): the editor stops calling it
  if NotifierIndex >= 0 then
    (BorlandIDEServices as INTACodeEditorServices).RemoveEditorEventsNotifier(NotifierIndex);

end.
