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
  // are written but switched off there). footnotes and derive came 11 Nov and weren't
  // here till 12 Nov (user: "[derive] doesn't have any rewrite indicator onscreen")
  ShownRules = 'assert-message,uses-merge,case-of,auto-property,double-quotes,footnotes,derive';

type
  TMark = (mkEdit, mkInsert, mkError, mkWarning, mkHint);   // mkInsert: text added at Col1

  // a stretch of one line to underline, in the editor's columns (from 1; Col2 past the end)
  TSpan = record
    Col1, Col2 : Integer;
    Mark       : TMark;
    Hover      : string;      // shown with the mouse over it: the text a rule writes, or its message
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
    Stops : TArray<Integer>;                          // the editor's tab stops, as columns
    // TabStops is the editor's option, as '2' or '9 17'
    constructor Create(const AText: TBytes; const FileName: string; const TabStops: string = '');
    destructor Destroy; override;
    function HoverAt(Line, Col: Integer): string;     // '' where nothing is marked
    function Expand(const LineText: string): string;  // its tabs as the spaces the editor shows
  end;

implementation

uses
  DelphiPP.Engine, DelphiPP.Rules, DelphiPP.Shown;

type
  TAddSpan = reference to procedure(Line, Col1, Col2: Integer; Mark: TMark; const Hover: string);

const
  HoverLines = 30;            // a longer rewrite is cut, with "..."

// text for a hover: its line breaks the editor's, cut after HoverLines
function HoverText(const Bytes: TBytes): string;
begin
  Result := TEncoding.UTF8.GetString(Bytes).Replace(#13#10, #10).Replace(#10, sLineBreak);
  const Lines = Result.Split([sLineBreak]);
  if Length(Lines) > HoverLines then
    Result := string.Join(sLineBreak, Copy(Lines, 0, HoverLines)) + sLineBreak + '...';
end;

// inside its group: the node the rule was visiting holds the edit
function InGroup(const E: TEdit): Boolean;
begin
  Exit( (E.GroupEnd > E.GroupStart) and (E.StartByte >= E.GroupStart) and
        (E.EndByte <= E.GroupEnd) );
end;

// what one visit of a rule wrote in the node it visited, when it made more than one edit
// there: the node's text with them all applied, so case-of's hover is the whole if chain,
// not one arm's piece (user, 12 Nov: "now shows only each line's translation .. not the
// whole case statement as a single"). '' when the edit is alone in its group
function GroupHover(const Text: TBytes; const Edits: TArray<TEdit>; const E: TEdit): string;
begin
  Result := '';
  if not InGroup(E) then
    Exit;
  var Count := 0;
  var Built: TBytes := nil;
  var At := E.GroupStart;
  for var G in Edits do                       // in source order, as RunWithEdits gives them
    if (G.Rule = E.Rule) and (G.GroupStart = E.GroupStart) and (G.GroupEnd = E.GroupEnd) and
       InGroup(G) then
    begin
      Inc(Count);
      Built := Built + Copy(Text, At, G.StartByte - At) + G.Bytes;
      At := G.EndByte;
    end;
  // one edit is enough: two uses clauses merged are one, `;` to `uses` as `,`, and its hover is
  // the clause merged, not the `,` (user, 13 Nov: "the uses hover is saying almost nothing")
  if Count = 0 then
    Exit;
  Built := Built + Copy(Text, At, E.GroupEnd - At);
  Exit( E.Rule + ' writes this as:' + sLineBreak + HoverText(Built) );
end;

// what a rule writes, as the hover says it
function EditHover(const E: TEdit; Insert: Boolean): string;
begin
  var New := TEncoding.UTF8.GetString(E.Bytes).Replace(#13#10, #10).Replace(#10, sLineBreak);
  const Lines = New.Split([sLineBreak]);
  if Length(Lines) > HoverLines then
    New := string.Join(sLineBreak, Copy(Lines, 0, HoverLines)) + sLineBreak + '...';
  if Insert then
    Exit( E.Rule + ' adds:' + sLineBreak + New );
  if New = '' then
    Exit( E.Rule + ' removes this' );
  Exit( E.Rule + ' writes this as:' + sLineBreak + New );
end;

{ TAnalysis }

// A tab goes to the next tab stop. The option is read as Delphi's help describes it, but not
// yet seen on a file with tabs in the IDE (a guess, 7 Nov): one number N is a stop every N
// columns; several (9 17) are the stops, and past the last they go on at its interval
function TAnalysis.Expand(const LineText: string): string;
begin
  Result := '';
  for var Ch in LineText do
    if Ch <> #9 then
      Result := Result + Ch
    else
    begin
      const Col = Length(Result) + 1;               // the column the tab is in
      var Next := 0;
      if Length(Stops) = 1 then
        Next := ((Col - 1) div Stops[0] + 1) * Stops[0] + 1
      else
      begin
        for var S in Stops do
          if S > Col then
          begin
            Next := S;
            Break;
          end;
        if Next = 0 then
        begin
          const Last = Stops[High(Stops)];
          const Step = Last - Stops[High(Stops) - 1];
          Next := Last + ((Col - Last) div Step + 1) * Step;
        end;
      end;
      Result := Result + StringOfChar(' ', Next - Col);
    end;
end;

function TAnalysis.HoverAt(Line, Col: Integer): string;
begin
  Result := '';
  var List: TArray<TSpan>;
  if not Spans.TryGetValue(Line, List) then
    Exit;
  for var S in List do
    // an insertion's cell, and the one before it: the caret is drawn between them
    if (Col >= S.Col1 - Ord(S.Mark = mkInsert)) and (Col < S.Col2) and
       not Result.Contains(S.Hover) then
      Result := if Result = '' then S.Hover else Result + sLineBreak + sLineBreak + S.Hover;
end;

constructor TAnalysis.Create(const AText: TBytes; const FileName: string; const TabStops: string);
begin
  inherited Create;
  Text  := AText;
  // stops that rise, or a stop every 8 columns
  for var Part in TabStops.Split([' ', ','], TStringSplitOptions.ExcludeEmpty) do
  begin
    const N = StrToIntDef(Part, 0);
    if (N > 0) and ((Stops = nil) or (N > Stops[High(Stops)])) then
      Stops := Stops + [N];
  end;
  if Stops = nil then
    Stops := [8];
  Spans := TDictionary<Integer, TArray<TSpan>>.Create;
  Notes := TDictionary<Integer, TArray<TNote>>.Create;

  // where each line starts, by byte
  var Starts: TArray<Integer> := [0];
  for var I := 0 to High(Text) do
    if Text[I] = 10 then
      Starts := Starts + [I + 1];

  // a byte offset as (line from 1, the editor's column from 1): the characters before it
  // on its line, counted as the editor counts them (UTF-16, a tab to its tab stop)
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
    Exit( 1 + Length(Expand(TEncoding.UTF8.GetString(Text, S, Offset - S))) );
  end;
  // the end of a line's text, by byte, before its CR LF
  var LineEnd: TFunc<Integer, Integer> := function(Line: Integer): Integer
  begin
    Result := if Line < Length(Starts) then Starts[Line] - 1 else Length(Text);
    while (Result > Starts[Line - 1]) and (Text[Result - 1] in [10, 13]) do
      Dec(Result);
  end;

  var Add: TAddSpan := procedure(Line, Col1, Col2: Integer; Mark: TMark; const Hover: string)
  begin
    var S: TSpan;
    S.Col1  := Col1;
    S.Col2  := if Col2 > Col1 then Col2 else Col1 + 1;  // an insertion: one cell
    S.Mark  := Mark;
    S.Hover := Hover;
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
      Messages := RunWithEdits(Text, Rules, FileName, Output, Edits);
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
      const Group = GroupHover(Text, Edits, E);
      // what it changes, less what it leaves as it was at either end: derive's replacing of
      // `[Derive(ToString)]   // comment` with the comment is the attribute's removal, and its
      // hover what derive adds for it, the helper's declaration (user, 13 Nov: "the triangle on
      // [Derive] shows two sets of text"). A group keeps its edits whole: its hover is the node
      var EStart := E.StartByte;
      var EEnd := E.EndByte;
      var Written := E.Bytes;
      var Hover := Group;
      if Group = '' then
      begin
        ChangedPart(Text, E, EStart, EEnd, Written);
        if (EEnd > EStart) and Blank(Written, 0, Length(Written)) then
          while (EEnd > EStart) and (Text[EEnd - 1] in [9, 32]) do     // the blanks it takes after it
            Dec(EEnd);
        var Changed := E;
        Changed.Bytes := Written;
        Hover := EditHover(Changed, EEnd = EStart);
        var More: string;
        if FirstRelated(Edits, E, More) then
          if Blank(Written, 0, Length(Written)) then
            Hover := E.Rule + ' removes this, and adds:' + sLineBreak + HoverText(TEncoding.UTF8.GetBytes(More))
          else
            Hover := Hover + sLineBreak + sLineBreak + 'and adds:' + sLineBreak +
                     HoverText(TEncoding.UTF8.GetBytes(More));
      end;
      const L1 = LineOf(EStart);
      const L2 = LineOf(EEnd);
      if EStart = EEnd then
      begin
        // text added, not changed: marked at the point it goes in, or, a line of its own above a
        // declaration (footnotes' ///), at the name it declares: TMood's, though it goes above
        // [Derive(ToString)], so the two hovers aren't one (user, 13 Nov, as in Zed)
        var NameStart, NameEnd: Integer;
        if (Group = '') and DeclaredName(Text, EStart, Written, NameStart, NameEnd) then
        begin
          const L = LineOf(NameStart);
          Add(L, ColOf(L, NameStart), ColOf(L, NameEnd), mkInsert, Hover);
        end
        else
        begin
          const C = ColOf(L1, EStart);
          Add(L1, C, C, mkInsert, Hover);
        end;
        Continue;
      end;
      for var L := L1 to L2 do
      begin
        // a line inside the range: from its first character, not its indent
        var B1 := if L = L1 then EStart else Starts[L - 1];
        if L > L1 then
          while (B1 < LineEnd(L)) and (Text[B1] in [9, 32]) do
            Inc(B1);
        var B2 := if L = L2 then EEnd else LineEnd(L);
        // not under a // comment at the end of the line: the rule only moves it
        var InQuote := False;
        for var B := Starts[L - 1] to B2 - 2 do
          if Text[B] = Ord('''') then
            InQuote := not InQuote
          else if not InQuote and (Text[B] = Ord('/')) and (Text[B + 1] = Ord('/')) then
          begin
            if B >= B1 then
            begin
              B2 := B;
              while (B2 > B1) and (Text[B2 - 1] in [9, 32]) do
                Dec(B2);
            end;
            Break;
          end;
        if B2 > B1 then
          Add(L, ColOf(L, B1), ColOf(L, B2), mkEdit, Hover);
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
      Add(M.Line, ColOf(M.Line, B1), ColOf(M.Line, B2), Mark, M.Rule + ': ' + M.Text);
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
