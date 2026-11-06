unit DelphiPP.Marks;

{ What the IDE package shows of a file: the rules run over its text, and their
  edits and messages as stretches of lines to underline, in the editor's lines
  and columns, and the messages' text for the end of their lines. Apart from
  the IDE (no ToolsAPI), so it can be tested on its own: MarksTest.dpr. }

interface

uses
  System.SysUtils, System.Generics.Collections;

const
  // the rules the pre-build event runs: the Python side's ALL (with and with-try
  // are written but switched off there)
  ShownRules = 'assert-message,uses-merge,case-of,auto-property,double-quotes';

type
  TMark = (mkEdit, mkInsert, mkError, mkWarning, mkHint);   // mkInsert: text added at Col1

  // a stretch of one line to underline, in the editor's columns (from 1; Col2 past the end)
  TSpan = record
    Col1, Col2 : Integer;
    Mark       : TMark;
  end;

  // a message, written after the end of its line
  TNote = record
    Text : string;
    Mark : TMark;
  end;

  // what the rules make of one file's text
  TAnalysis = class
    Text  : TBytes;
    Spans : TDictionary<Integer, TArray<TSpan>>;    // by line, from 1
    Notes : TDictionary<Integer, TArray<TNote>>;
    Shape : string;                                   // the spans and notes, to tell a change
    constructor Create(const AText: TBytes);
    destructor Destroy; override;
  end;

implementation

uses
  DelphiPP.Engine, DelphiPP.Rules;

{ TAnalysis }

constructor TAnalysis.Create(const AText: TBytes);
begin
  inherited Create;
  Text  := AText;
  Spans := TDictionary<Integer, TArray<TSpan>>.Create;
  Notes := TDictionary<Integer, TArray<TNote>>.Create;

  // where each line starts, by byte
  var Starts: TArray<Integer> := [0];
  for var I := 0 to High(Text) do
    if Text[I] = 10 then
      Starts := Starts + [I + 1];

  // a byte offset as (line from 1, the editor's column from 1): the characters before it
  // on its line, counted as the editor counts them (UTF-16; a tab as one, for now)
  var LineOf: TFunc<Integer, Integer> := function(Offset: Integer): Integer
  begin
    var Lo := 0;
    var Hi := High(Starts);
    while Lo < Hi do
    begin
      var Mid := (Lo + Hi + 1) div 2;
      if Starts[Mid] <= Offset then Lo := Mid else Hi := Mid - 1;
    end;
    Exit( Lo + 1 );
  end;
  var ColOf: TFunc<Integer, Integer, Integer> := function(Line, Offset: Integer): Integer
  begin
    const S = Starts[Line - 1];
    Exit( 1 + Length(TEncoding.UTF8.GetString(Text, S, Offset - S)) );
  end;
  // the end of a line's text, by byte, before its CR LF
  var LineEnd: TFunc<Integer, Integer> := function(Line: Integer): Integer
  begin
    Result := if Line < Length(Starts) then Starts[Line] - 1 else Length(Text);
    while (Result > Starts[Line - 1]) and (Text[Result - 1] in [10, 13]) do
      Dec(Result);
  end;

  var Add: TProc<Integer, Integer, Integer, TMark> := procedure(Line, Col1, Col2: Integer; Mark: TMark)
  begin
    var S: TSpan;
    S.Col1 := Col1;
    S.Col2 := if Col2 > Col1 then Col2 else Col1 + 1;   // an insertion: one cell
    S.Mark := Mark;
    var List: TArray<TSpan>;
    Spans.TryGetValue(Line, List);
    Spans.AddOrSetValue(Line, List + [S]);
    Shape := Shape + Format('%d:%d-%d:%d;', [Line, S.Col1, S.Col2, Ord(Mark)]);
  end;

  var AddNote: TProc<Integer, string, TMark> := procedure(Line: Integer; NoteText: string; Mark: TMark)
  begin
    var N: TNote;
    N.Text := NoteText;
    N.Mark := Mark;
    var List: TArray<TNote>;
    Notes.TryGetValue(Line, List);
    Notes.AddOrSetValue(Line, List + [N]);
    Shape := Shape + Format('%d:%s;', [Line, N.Text]);
  end;

  const Rules = RulesNamed(ShownRules);
  try
    var Output: TBytes;
    var Edits: TArray<TEdit>;
    var Messages: TArray<TMessage>;
    try
      Messages := RunWithEdits(Text, Rules, '', Output, Edits);
    except
      // a rule that fails on this text (half typed, say): said, and nothing else shown,
      // rather than the marks of the text before
      on E: Exception do
      begin
        AddNote(1, 'delphipp: a rule failed on this text: ' + E.Message, mkError);
        Exit;
      end;
    end;

    // each edit, line by line over the lines it spans
    for var E in Edits do
    begin
      const L1 = LineOf(E.StartByte);
      const L2 = LineOf(E.EndByte);
      if E.StartByte = E.EndByte then
      begin
        // text added, not changed: marked at the point it goes in
        const C = ColOf(L1, E.StartByte);
        Add(L1, C, C, mkInsert);
        Continue;
      end;
      for var L := L1 to L2 do
      begin
        // a line inside the range: from its first character, not its indent
        var B1 := if L = L1 then E.StartByte else Starts[L - 1];
        if L > L1 then
          while (B1 < LineEnd(L)) and (Text[B1] in [9, 32]) do
            Inc(B1);
        const B2 = if L = L2 then E.EndByte else LineEnd(L);
        Add(L, ColOf(L, B1), ColOf(L, B2), mkEdit);
      end;
    end;

    // each message: underlined from its column to the next space, its text after the line
    for var M in Messages do
    begin
      const Mark = if M.Level = 'error' then mkError
                   else if M.Level = 'warning' then mkWarning
                   else mkHint;
      if M.Line > Length(Starts) then
        Continue;
      var B1 := Starts[M.Line - 1] + M.Col - 1;
      var B2 := B1;
      const Stop = LineEnd(M.Line);
      while (B2 < Stop) and not (Text[B2] in [9, 32]) do
        Inc(B2);
      Add(M.Line, ColOf(M.Line, B1), ColOf(M.Line, B2), Mark);
      AddNote(M.Line, M.Rule + ': ' + M.Text, Mark);
    end;
  finally
    for var R in Rules do
      R.Free;
  end;
end;

destructor TAnalysis.Destroy;
begin
  Notes.Free;
  Spans.Free;
  inherited;
end;

end.
