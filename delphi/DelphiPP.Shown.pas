unit DelphiPP.Shown;

{ Where an editor shows a rule's edit, and what it says of it: shared by Zed's language server
  (DelphiPP.Lsp) and the IDE package (ide\DelphiPP.Marks), so the two show the same (user, 13 Nov:
  the IDE's [Derive] hover "shows two sets of text", as Zed's did). Byte offsets into the text the
  rules ran on; the Python side's lsp.py has the same, for its server. }

interface

uses
  System.SysUtils, DelphiPP.Engine;

type
  TPiece = record
    A, B: Integer;
  end;

function LineEndByte(const Raw: TBytes; Offset: Integer): Integer;
function IsWordByte(B: Byte): Boolean;
function WordEnd(const Raw: TBytes; Offset: Integer): Integer;
function Blank(const Raw: TBytes; StartByte, EndByte: Integer): Boolean;
// a line of its own, Text, put in at Start above a declaration: the name it declares, [A, B)
function DeclaredName(const Raw: TBytes; Start: Integer; const Text: TBytes; out A, B: Integer): Boolean;
procedure InsertionRange(const Raw: TBytes; Start: Integer; const Text: TBytes; out A, B: Integer);
procedure ChangedPart(const Raw: TBytes; const E: TEdit; out A, B: Integer; out Written: TBytes);
function CodePieces(const Raw: TBytes; Start, Stop: Integer): TArray<TPiece>;
// what the rule writes next from E's place (an edit whose origin E's start is): derive's helper
// declaration, from the attribute it removes. False when there is none
function FirstRelated(const Edits: TArray<TEdit>; const E: TEdit; out Text: string): Boolean;

implementation

uses
  System.Math, System.Character;

function LineEndByte(const Raw: TBytes; Offset: Integer): Integer;
begin
  for var I := Max(0, Offset) to High(Raw) do
    if Raw[I] = 10 then
      Exit( I );
  Exit( Length(Raw) );
end;

// a byte as Python's chr(b).isalnum() sees it, or '_'
function IsWordByte(B: Byte): Boolean;
begin
  const C = Char(B);
  Exit( (B = Ord('_')) or C.IsLetterOrDigit or C.IsNumber );
end;

// A squiggle needs some width: the word at a message's or an insertion's place
function WordEnd(const Raw: TBytes; Offset: Integer): Integer;
begin
  const Stop = LineEndByte(Raw, Offset);
  var I := Offset;
  while (I < Stop) and IsWordByte(Raw[I]) do
    Inc(I);
  if I > Offset then
    Exit( I );
  Exit( Min(Offset + 1, Stop) );
end;

// blanks only, as Python's bytes.strip() sees them
function Blank(const Raw: TBytes; StartByte, EndByte: Integer): Boolean;
begin
  for var I := StartByte to EndByte - 1 do
    if not (Raw[I] in [9..13, 32]) then
      Exit( False );
  Exit( True );
end;

// the first byte that isn't blank in [StartByte, EndByte), or EndByte
function FirstNonBlank(const Raw: TBytes; StartByte, EndByte: Integer): Integer;
begin
  Result := StartByte;
  while (Result < EndByte) and (Raw[Result] in [9..13, 32]) do
    Inc(Result);
end;

// a declaration's words before its name: `function Greeting`, `class procedure P`, `const C`
function BeforeName(const Word: string): Boolean;
const
  Words: array[0..11] of string = ('class', 'function', 'procedure', 'constructor', 'destructor',
    'operator', 'property', 'type', 'const', 'var', 'threadvar', 'resourcestring');
begin
  for var W in Words do
    if SameText(W, Word) then
      Exit( True );
  Exit( False );
end;

// An insertion's squiggle, [A, B). A line of its own, put above a declaration (footnotes' ///):
// the name it declares, past attribute lines and `function` and the like, so hovering TMood shows
// TMood's /// though it goes above [Derive(ToString)] (user, 13 Nov: "i'd actually prefer if just
// tmood, tgreeting and greeting were the underlines"). Lines of its own after a line's end
// (derive's helper, its ToString after `implementation`): that line's last word, or its last
// character, not a zero-width squiggle shown on the last letter (user, 13 Nov: "TMoodHelper.ToString
// only hovers on the last letter 'n' of 'implementation'"). Else the word at its place. As the
// Python side's insertion_range
function DeclaredName(const Raw: TBytes; Start: Integer; const Text: TBytes; out A, B: Integer): Boolean;
begin
  Result := False;
  var LineStart := Start;
  while (LineStart > 0) and (Raw[LineStart - 1] <> 10) do
    Dec(LineStart);
  var LastBreak := -1;
  for var I := 0 to High(Text) do
    if Text[I] = 10 then
      LastBreak := I;
  if (LastBreak >= 0) and Blank(Raw, LineStart, Start) and Blank(Text, LastBreak + 1, Length(Text)) then
  begin
    var Stop := LineEndByte(Raw, Start);
    var First := FirstNonBlank(Raw, Start, Stop);
    while (First < Stop) and (Raw[First] = Ord('[')) and (Stop < Length(Raw)) do
    begin
      Stop := LineEndByte(Raw, Stop + 1);
      var From := Stop;
      while (From > 0) and (Raw[From - 1] <> 10) do
        Dec(From);
      First := FirstNonBlank(Raw, From, Stop);
    end;
    var At := First;
    while At < Stop do
    begin
      var WordStop := At;
      while (WordStop < Stop) and IsWordByte(Raw[WordStop]) do
        Inc(WordStop);
      if WordStop = At then
        Break;
      if not BeforeName(TEncoding.UTF8.GetString(Raw, At, WordStop - At)) then
      begin
        A := At;
        B := WordStop;
        Exit( True );
      end;
      At := FirstNonBlank(Raw, WordStop, Stop);
    end;
  end;
end;

procedure InsertionRange(const Raw: TBytes; Start: Integer; const Text: TBytes; out A, B: Integer);
begin
  if DeclaredName(Raw, Start, Text, A, B) then
    Exit;
  var LineStart := Start;
  while (LineStart > 0) and (Raw[LineStart - 1] <> 10) do
    Dec(LineStart);
  if (Length(Text) > 0) and (Text[0] in [10, 13]) and Blank(Raw, Start, LineEndByte(Raw, Start)) then
  begin
    B := Start;
    while (B > LineStart) and (Raw[B - 1] in [9, 13, 32]) do
      Dec(B);
    A := B;
    while (A > LineStart) and IsWordByte(Raw[A - 1]) do
      Dec(A);
    if (A = B) and (B > LineStart) then
      A := B - 1;
    if A < B then
      Exit;
  end;
  A := Start;
  B := WordEnd(Raw, Start);
end;

// An edit less what it leaves as it was, at both ends: derive's replacing of
// `[Derive(ToString)]   // comment` with `// comment` is the attribute's removal. Whole UTF-8
// characters only. As the Python side's changed_part
procedure ChangedPart(const Raw: TBytes; const E: TEdit; out A, B: Integer; out Written: TBytes);
begin
  const OldLen = E.EndByte - E.StartByte;
  const NewLen = Length(E.Bytes);
  var P := 0;
  while (P < OldLen) and (P < NewLen) and (Raw[E.StartByte + P] = E.Bytes[P]) do
    Inc(P);
  while (P > 0) and (P < NewLen) and ((E.Bytes[P] and $C0) = $80) do
    Dec(P);
  var Q := 0;
  while (Q < OldLen - P) and (Q < NewLen - P) and (Raw[E.EndByte - 1 - Q] = E.Bytes[NewLen - 1 - Q]) do
    Inc(Q);
  while (Q > 0) and ((E.Bytes[NewLen - Q] and $C0) = $80) do
    Dec(Q);
  A := E.StartByte + P;
  B := E.EndByte - Q;
  Written := Copy(E.Bytes, P, NewLen - Q - P);
end;

// [Start, Stop) less its comments: the stretches of code between them, each without the blanks
// after it. A squiggle is one stretch, so a rewritten case's is two, `case X of` and the arms, not
// one over the comment between (user, 13 Nov: "it would be good if case underline excluded the
// comment on that line"). As the Python side's code_pieces
function CodePieces(const Raw: TBytes; Start, Stop: Integer): TArray<TPiece>;
var
  At: Integer;     // the piece's start, or -1 between pieces

  procedure Close(J: Integer);
  begin
    if At < 0 then
      Exit;
    while (J > At) and (Raw[J - 1] in [9, 10, 13, 32]) do
      Dec(J);
    var P: TPiece;
    P.A := At;
    P.B := J;
    Result := Result + [P];
    At := -1;
  end;

  function Starts(I: Integer; const S: string): Boolean;
  begin
    Result := I + Length(S) <= Length(Raw);
    for var K := 1 to Length(S) do
      Result := Result and (Raw[I + K - 1] = Ord(S[K]));
  end;

  function Find(I: Integer; const S: string): Integer;
  begin
    while I < Length(Raw) do
    begin
      if Starts(I, S) then
        Exit( I );
      Inc(I);
    end;
    Exit( -1 );
  end;

begin
  Result := nil;
  At := -1;
  var I := Start;
  while I < Stop do
  begin
    const C = Raw[I];
    if Starts(I, '//') then
    begin
      Close(I);
      I := Min(LineEndByte(Raw, I), Stop);
    end
    else if (C = Ord('{')) or Starts(I, '(*') then
    begin
      Close(I);
      const Brace = C = Ord('{');
      const Found = Find(I, if Brace then '}' else '*)');
      if Found < 0 then
        I := Stop
      else
        I := Min(Found + (if Brace then 1 else 2), Stop);
    end
    else if C = Ord('''') then
    begin
      if At < 0 then
        At := I;
      Inc(I);
      while (I < Stop) and (Raw[I] <> 10) do     // to its closing quote; '' is a quote in it
      begin
        if Raw[I] = Ord('''') then
        begin
          if (I + 1 < Stop) and (Raw[I + 1] = Ord('''')) then
          begin
            Inc(I, 2);
            Continue;
          end;
          Inc(I);
          Break;
        end;
        Inc(I);
      end;
    end
    else
    begin
      if (At < 0) and not (C in [9, 10, 13, 32]) then
        At := I;
      Inc(I);
    end;
  end;
  Close(Stop);
  if Length(Result) = 0 then
  begin
    var P: TPiece;
    P.A := Start;
    P.B := Stop;
    Result := [P];
  end;
end;

function FirstRelated(const Edits: TArray<TEdit>; const E: TEdit; out Text: string): Boolean;
begin
  for var O in Edits do
    if ((O.StartByte <> E.StartByte) or (O.EndByte <> E.EndByte)) and (O.Rule = E.Rule) and
       (O.Origin >= 0) and (O.Origin = E.StartByte) then
    begin
      Text := TEncoding.UTF8.GetString(O.Bytes).Trim;
      Exit( True );
    end;
  Text := '';
  Exit( False );
end;

end.
