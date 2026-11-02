program CaseBasic;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes;

const
  sWorld = 'world';

function Greet(const s: string): Integer;
begin
  if (s = 'hello') or (s = 'hi') then
    Result := 1
  else if s = sWorld then
    begin Result := 3; end
  else
    begin
      Writeln('  (no match for ', s, ')');
      Result := 0
    end;
end;

function Kind(const x: TObject): string;
begin
  Result := '?';
  if x.ClassType = TStringList then
    Result := 'a string list'
  else if x.ClassType = TList then
    Result := 'a list';
end;

function Day(d: Integer): string;
begin
  case d of            // an ordinal case: left alone
    1 : Result := 'Mon';
  else
    Result := '-';
  end;
end;

begin
  Writeln(Greet('hi'), ' ', Greet('world'), ' ', Greet('bye'));
  var L := TStringList.Create;
  Writeln(Kind(L), ', ', Day(1));
  L.Free;
end.
